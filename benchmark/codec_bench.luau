-- Real codec benchmark (kept outside production execution paths).
-- Exercises the actual generated serializers through buffer round-trips:
-- per-data-type encode/decode throughput, bytes per value, and an end-to-end
-- event test (Fire -> flush -> dispatch) against the real dispatch path.
--
-- Usage: lune run benchmark/codec_bench
--
-- Notes, read before quoting numbers:
-- - This runs on Lune, not in Roblox. It measures codec CPU and byte layout,
--   not transport, replication, compression on the wire, or client/server
--   frame cost.
-- - Encode reps include a fresh output buffer per op; decode reps re-read one
--   shared buffer. Timings are medians over adaptive repetitions targeting
--   ~100ms per direction (min 1k, max 2M reps) after warmup.
-- - f32/f16 round-trips are inherently lossy, so those cases use exactly
--   representable values plus explicit special-value checks (inf, NaN, -0).

local luau = require("@lune/luau")

local Parser = require("../src/Parser")
local Generator = require("../src/Generator")

---- Schema ----

local SCHEMA = table.concat({
	'option ClientOutput = "client"',
	'option ServerOutput = "server"',
	'option RemoteScope = "CODECBENCH"',
	"export type U8 = u8",
	"export type U16 = u16",
	"export type U32 = u32",
	"export type I8 = i8",
	"export type I16 = i16",
	"export type I32 = i32",
	"export type F16 = f16",
	"export type F32 = f32",
	"export type F64 = f64",
	"export type Flag = boolean",
	"export type Text = string",
	"export type Raw = buffer",
	"export type Ranged = u8(0..10)",
	"export type Str5 = string(0..5)",
	'export enum Palette = { "Red", "Green", "Blue" }',
	"export type Bytes4 = u8[4]",
	"export type DynList = u8[]",
	"export type SparseList = u8?[1..8]",
	"export type MaybeU8 = u8?",
	"export type Holey = u8?[3]",
	"export type Nested = u8[][]",
	"export map Lookup = { [string]: u8 }",
	"export struct Point { X: f32, Y: f32, Z: f32 }",
	"export struct Player { Id: u32, Name: string, Score: u16? }",
	"event Ping { From: Client, Type: Reliable, Call: SingleSync, Data: Point }",
	"event Tick { From: Server, Type: Unreliable, Call: SingleSync, Data: U8 }",
}, "\n")

---- Roblox stubs (load the generated module under Lune) ----

local Fired: { { Channel: string, Player: any, Buffer: buffer, Instances: { any } } } = {}
local ReliableHandler: ((any, buffer, { any }) -> ())? = nil
local UnreliableHandler: ((any, buffer, { any }) -> ())? = nil
local ClientReliableHandler: ((buffer, { any }) -> ())? = nil
local ClientUnreliableHandler: ((buffer, { any }) -> ())? = nil
local HeartbeatCallbacks: { () -> () } = {}
local IsClientMode = false

local SharedReliable: any = nil
local SharedUnreliable: any = nil

local function makeRemote(Channel: string)
	return {
		FireClient = function(_self: any, Player: any, Buffer: buffer, Instances: { any })
			table.insert(Fired, { Channel = Channel, Player = Player, Buffer = Buffer, Instances = Instances })
		end,
		FireServer = function(_self: any, Buffer: buffer, Instances: { any })
			table.insert(Fired, { Channel = Channel, Player = nil, Buffer = Buffer, Instances = Instances })
		end,
		OnServerEvent = {
			Connect = function(_self: any, Handler: (any, buffer, { any }) -> ())
				if Channel == "Reliable" then
					ReliableHandler = Handler
				else
					UnreliableHandler = Handler
				end
			end,
		},
		OnClientEvent = {
			Connect = function(_self: any, Handler: (buffer, { any }) -> ())
				if Channel == "Reliable" then
					ClientReliableHandler = Handler
				else
					ClientUnreliableHandler = Handler
				end
			end,
		},
		Name = "",
		Parent = nil :: any,
	}
end

SharedReliable = makeRemote("Reliable")
SharedUnreliable = makeRemote("Unreliable")

local FakeReplicatedStorage = {
	FindFirstChild = function(_self: any, Name: string)
		if string.find(Name, "UNRELIABLE", 1, true) then
			return nil -- server creates its own side first
		end
		return nil
	end,
	WaitForChild = function(_self: any, Name: string)
		if string.find(Name, "UNRELIABLE", 1, true) then
			return SharedUnreliable
		end
		return SharedReliable
	end,
}

-- NOTE: luau.load sandboxes globals (a chunk only sees standard libs), so the
-- stubs must live on this chunk's environment table itself, not merely _G.
local ENV: any = getfenv()

ENV.game = {
	GetService = function(_self: any, Name: string)
		if Name == "Players" then
			return {
				PlayerRemoving = {
					Connect = function(_self: any, _Handler: (any) -> ()) end,
				},
				GetPlayers = function(_self: any)
					return {}
				end,
			}
		elseif Name == "ReplicatedStorage" then
			return FakeReplicatedStorage
		elseif Name == "RunService" then
			return {
				IsServer = function(_self: any)
					return not IsClientMode
				end,
				IsClient = function(_self: any)
					return IsClientMode
				end,
				IsRunning = function(_self: any)
					return true
				end,
				Heartbeat = {
					Connect = function(_self: any, Handler: () -> ())
						table.insert(HeartbeatCallbacks, Handler)
					end,
				},
			}
		end
		error(`unexpected service {Name}`)
	end,
}
ENV.Instance = {
	new = function(_class: string)
		-- The server module loads first and creates both remotes; the client
		-- module then finds them through WaitForChild. Hand out the shared
		-- pair in creation order (Reliable, then Unreliable).
		if SharedReliable.Created ~= true then
			SharedReliable.Created = true
			return SharedReliable
		end
		return SharedUnreliable
	end,
}

---- Generate + load ----

local Tree = Parser.new(nil, "codec_bench.blink"):Parse(SCHEMA)
local ServerSource = Generator.Generate("Server", Tree)
local ClientSource = Generator.Generate("Client", Tree)
-- luau.load sandboxes globals, so hand each chunk this file's environment
-- (which carries the game/Instance stubs above).
local ServerReturns = luau.load(ServerSource, { env = getfenv() })() :: any
assert(ReliableHandler ~= nil, "server receive handler was never connected")
-- Same schema identity, so both halves share remote names. The single-instance
-- guard is per process, not per deployment: clear it for the second load.
_G._BLINK["CODECBENCH"] = nil
IsClientMode = true
local ClientReturns = luau.load(ClientSource, { env = getfenv() })() :: any
IsClientMode = false
assert(ClientReliableHandler ~= nil, "client receive handler was never connected")
local Returns = ServerReturns

---- Helpers ----

local function deepEqual(A: any, B: any): boolean
	if type(A) ~= type(B) then
		return false
	end
	if type(A) == "number" then
		if A ~= A and B ~= B then
			return true -- NaN equals NaN here
		end
		return A == B
	elseif type(A) == "table" then
		for Key, Value in A do
			if not deepEqual(Value, (B :: any)[Key]) then
				return false
			end
		end
		for Key, Value in B do
			if not deepEqual(Value, (A :: any)[Key]) then
				return false
			end
		end
		return true
	elseif type(A) == "buffer" then
		if buffer.len(A) ~= buffer.len(B) then
			return false
		end
		return buffer.readstring(A, 0, buffer.len(A)) == buffer.readstring(B, 0, buffer.len(B))
	end
	return A == B
end

local MIN_REPS = 1000
local MAX_REPS = 2000000
local WARMUP = 200

local function measure(Fn: () -> ()): number
	for _ = 1, WARMUP do
		Fn()
	end
	-- Grow repetitions until the sample clears clock granularity (~5ms) so
	-- sub-microsecond ops still time honestly instead of hitting a floor.
	local Reps = MIN_REPS
	while true do
		local Start = os.clock()
		for _ = 1, Reps do
			Fn()
		end
		local Elapsed = os.clock() - Start
		if Elapsed >= 0.005 or Reps >= MAX_REPS then
			if Elapsed <= 0 then
				return -1
			end
			return Elapsed * 1e9 / Reps
		end
		Reps = math.min(Reps * 10, MAX_REPS)
	end
end

local function kilobytes(Text: string): buffer
	local Length = #Text
	local Buffer = buffer.create(Length)
	buffer.writestring(Buffer, 0, Text)
	return Buffer
end

---- Cases: export name, label, values ----

type Case = {
	Export: string,
	Label: string,
	Values: { any },
}

local CASES: { Case } = {
	{ Export = "U8", Label = "u8", Values = { 0, 127, 255 } },
	{ Export = "U16", Label = "u16", Values = { 0, 1000, 65535 } },
	{ Export = "U32", Label = "u32", Values = { 0, 100000, 4294967295 } },
	{ Export = "I8", Label = "i8", Values = { -128, 0, 127 } },
	{ Export = "I16", Label = "i16", Values = { -32768, 0, 32767 } },
	{ Export = "I32", Label = "i32", Values = { -2147483648, 0, 2147483647 } },
	{ Export = "F32", Label = "f32", Values = { 0, 0.5, -3.25, 100000 } },
	{ Export = "F64", Label = "f64", Values = { 0, 0.1, -1e10, 3.141592653589793 } },
	{ Export = "F16", Label = "f16", Values = { 0, 0.5, -2, 65504, 0.00006103515625 } },
	{ Export = "Flag", Label = "boolean", Values = { true, false } },
	{ Export = "Text", Label = "string", Values = { "", "hello", string.rep("x", 1000) } },
	{ Export = "Raw", Label = "buffer", Values = { buffer.create(0), kilobytes("0123456789abcdef"), kilobytes(string.rep("y", 1024)) } },
	{ Export = "Ranged", Label = "u8(0..10)", Values = { 0, 5, 10 } },
	{ Export = "Str5", Label = "string(0..5)", Values = { "", "hi", "12345" } },
	{ Export = "Palette", Label = "enum x3", Values = { "Red", "Green", "Blue" } },
	{ Export = "Bytes4", Label = "u8[4]", Values = { { 1, 2, 3, 4 }, { 255, 0, 128, 64 } } },
	{ Export = "DynList", Label = "u8[]", Values = { {}, table.create(64, 7) } },
	{ Export = "SparseList", Label = "u8?[1..8] sparse", Values = { { [2] = 20, [5] = 50 }, { 1, 2, 3 } } },
	{ Export = "MaybeU8", Label = "u8?", Values = { 42, nil } },
	{ Export = "Holey", Label = "u8?[3] hole", Values = { { [1] = 10, [3] = 30 }, { 1, 2, 3 } } },
	{ Export = "Nested", Label = "u8[][]", Values = { { { 1, 2 }, { 3 } }, {} } },
	{ Export = "Lookup", Label = "map str->u8", Values = { { a = 1, b = 2 }, { health = 100, ammo = 30, level = 7 } } },
	{ Export = "Point", Label = "struct f32x3", Values = { { X = 1.5, Y = -2.25, Z = 100 } } },
	{ Export = "Player", Label = "struct+opt", Values = { { Id = 7, Name = "Bubba", Score = 9000 }, { Id = 8, Name = "", Score = nil } } },
}

local function valueLabel(Value: any): string
	if Value == nil then
		return "nil"
	end
	local Kind = type(Value)
	if Kind == "string" then
		return if #Value > 12 then `"{#Value}B str"` else `"{Value}"`
	elseif Kind == "buffer" then
		return `{buffer.len(Value)}B buf`
	elseif Kind == "table" then
		return "table"
	elseif Kind == "number" then
		return tostring(Value)
	end
	return tostring(Value)
end

---- Run codec cases ----

print(string.format("%-22s %-12s %13s %13s %7s  %s", "export (type)", "value", "encode ns/op", "decode ns/op", "bytes", "ok"))
local CodecFailures = 0
for _, Case in CASES do
	local Codec = Returns[Case.Export]
	assert(Codec ~= nil and Codec.Read ~= nil and Codec.Write ~= nil, `missing codec {Case.Export}`)
	for _, Value in Case.Values do
		local WriteOk, First = pcall(Codec.Write, Value)
		local Status = "?"
		local EncodeNs = -1
		local DecodeNs = -1
		local Bytes = -1
		if WriteOk then
			Bytes = buffer.len(First)
			EncodeNs = measure(function()
				Codec.Write(Value)
			end)
			DecodeNs = measure(function()
				Codec.Read(First)
			end)
			local ReadOk, Back = pcall(Codec.Read, First)
			Status = if ReadOk and deepEqual(Back, Value) then "yes" else "NO"
			if Status ~= "yes" then
				CodecFailures += 1
			end
		else
			Status = "WRITE-ERR"
			CodecFailures += 1
		end
		local function cell(Ns: number): string
			return if Ns < 0 then "      <1ns?" else string.format("%13.1f", Ns)
		end
		local BytesCell = if Bytes >= 0 then string.format("%7d", Bytes) else "      ?"
		print(string.format(
			"%-22s %-12s %13s %13s %7s  %s",
			Case.Export .. " (" .. Case.Label .. ")",
			valueLabel(Value),
			cell(EncodeNs),
			cell(DecodeNs),
			BytesCell,
			Status
		))
	end
end

---- f16 special values (exact checks, not timing) ----

do
	local Codec = Returns.F16
	local Checks = {
		{ Name = "inf round-trips", Value = math.huge, Test = function(Back: number)
			return Back == math.huge
		end },
		{ Name = "-inf round-trips", Value = -math.huge, Test = function(Back: number)
			return Back == -math.huge
		end },
		{ Name = "NaN round-trips", Value = 0 / 0, Test = function(Back: number)
			return Back ~= Back
		end },
		{ Name = "-0.0 preserved", Value = -0.0, Test = function(Back: number)
			return Back == 0 and 1 / Back == -math.huge
		end },
	}
	for _, Check in Checks do
		local Ok, Back = pcall(Codec.Write, Check.Value)
		local Pass = false
		if Ok then
			local Ok2, Decoded = pcall(Codec.Read, Back)
			Pass = Ok2 and (Check.Test :: any)(Decoded)
		end
		print(`f16 {Check.Name}: {if Pass then "yes" else "NO"} `)
		if not Pass then
			CodecFailures += 1
		end
	end
end

---- End-to-end event test: Fire -> flush -> dispatch ----
-- Reliable direction is client->server (batched, flushed on heartbeat);
-- unreliable is server->client (sent immediately per call). Both directions
-- run through the real generated code: serializer, batcher, handshake
-- prologue, dispatcher, and listener.

local function roundTripReliable(MakeValue: () -> any, Count: number): (number, number, number, number, boolean)
	local Received: { any } = {}
	ServerReturns.Ping.On(function(_From: any, Value: any)
		table.insert(Received, Value)
	end)

	local Values: { any } = {}
	for _ = 1, Count do
		table.insert(Values, MakeValue())
	end

	table.clear(Fired)
	local Start = os.clock()
	for _, Value in Values do
		ClientReturns.Ping.Fire(Value)
	end
	local FireNs = (os.clock() - Start) * 1e9 / Count

	Start = os.clock()
	for _, Flush in HeartbeatCallbacks do
		Flush()
	end
	local FlushMs = (os.clock() - Start) * 1000
	local FlushedBytes = 0
	local Batches = 0
	for _, Entry in Fired do
		if Entry.Channel == "Reliable" then
			FlushedBytes += buffer.len(Entry.Buffer)
			Batches += 1
		end
	end

	table.clear(Received)
	Start = os.clock()
	for _, Entry in Fired do
		if Entry.Channel == "Reliable" then
			(ReliableHandler :: any)({ Name = "BenchPlayer" }, Entry.Buffer, Entry.Instances)
		end
	end
	local DispatchNs = (os.clock() - Start) * 1e9 / Count

	local Ok = #Received == Count
	if Ok then
		for Index, Value in Values do
			if not deepEqual(Received[Index], Value) then
				Ok = false
				break
			end
		end
	end
	return FireNs, FlushMs, FlushedBytes / Count, DispatchNs, Ok
end

local function roundTripUnreliable(MakeValue: () -> any, Count: number): (number, number, number, boolean)
	local Player = { Name = "BenchPlayer" }
	local Received: { any } = {}
	ClientReturns.Tick.On(function(Value: any)
		table.insert(Received, Value)
	end)

	local Values: { any } = {}
	for _ = 1, Count do
		table.insert(Values, MakeValue())
	end

	table.clear(Fired)
	local Start = os.clock()
	for _, Value in Values do
		ServerReturns.Tick.Fire(Player, Value)
	end
	local FireNs = (os.clock() - Start) * 1e9 / Count
	local WireBytes = 0
	for _, Entry in Fired do
		WireBytes += buffer.len(Entry.Buffer)
	end

	table.clear(Received)
	Start = os.clock()
	for _, Entry in Fired do
		(ClientUnreliableHandler :: any)(Entry.Buffer, Entry.Instances)
	end
	local DispatchNs = (os.clock() - Start) * 1e9 / Count

	local Ok = #Received == Count
	if Ok then
		for Index, Value in Values do
			if not deepEqual(Received[Index], Value) then
				Ok = false
				break
			end
		end
	end
	return FireNs, WireBytes / Count, DispatchNs, Ok
end

print("\n-- events (20000 msgs, 1 player) --")
do
	local Index = 0
	local FireNs, FlushMs, BytesPerEvent, DispatchNs, Ok = roundTripReliable(function()
		Index += 1
		return { X = Index % 100 + 0.5, Y = -(Index % 50), Z = Index }
	end, 20000)
	print(
		`Ping reliable client->server: fire {string.format("%.0f", FireNs)} ns/ev, flush {string.format(
			"%.1f",
			FlushMs
		)} ms total, {string.format("%.1f", BytesPerEvent)} B/ev on the wire, dispatch {string.format(
			"%.0f",
			DispatchNs
		)} ns/ev, integrity: {if Ok then "yes" else "NO"} `
	)
	if not Ok then
		CodecFailures += 1
	end
end
do
	local Index = 0
	local FireNs, BytesPerEvent, DispatchNs, Ok = roundTripUnreliable(function()
		Index = (Index + 1) % 256
		return Index
	end, 20000)
	print(
		`Tick unreliable server->client: fire+send {string.format("%.0f", FireNs)} ns/ev, {string.format(
			"%.1f",
			BytesPerEvent
		)} B/ev on the wire, dispatch {string.format("%.0f", DispatchNs)} ns/ev, integrity: {if Ok then "yes" else "NO"} `
	)
	if not Ok then
		CodecFailures += 1
	end
end

print(`\ncodec failures: {CodecFailures}`)
if CodecFailures > 0 then
	error("codec benchmark found mismatches")
end
