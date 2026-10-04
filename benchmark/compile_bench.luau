-- Reproducible compiler benchmark (kept outside production execution paths).
-- Measures parse + codegen for representative workloads with warmup and repeats.
--
-- Usage: lune run benchmark/compile_bench [path-to-blink-file] [iterations]
-- Default workload: test/Sources/Test.blink (real-world schema with imports).
-- Also always benchmarks an in-memory synthetic schema (no I/O) and reports
-- heap size via collectgarbage("count").

local fs = require("@lune/fs")

local Parser = require("../src/Parser")
local Generator = require("../src/Generator")

local Args = { ... }
local RequestedFile = if #Args >= 1 and fs.isFile(Args[1]) then Args[1] else "test/Sources/Test.blink"
local ITERATIONS = tonumber(Args[#Args]) or 30
local WARMUP = 3

local function median(List: { number }): number
	local Copy = table.clone(List)
	table.sort(Copy)
	local N = #Copy
	if N == 0 then
		return 0
	end
	if N % 2 == 1 then
		return Copy[(N + 1) // 2]
	end
	return (Copy[N // 2] + Copy[N // 2 + 1]) / 2
end

local function syntheticSource(Declarations: number): string
	local Parts = {
		'option ClientOutput = "client"',
		'option ServerOutput = "server"',
		"struct Shared {\n\tId: u32,\n\tName: string,\n}",
	}
	for Index = 1, Declarations do
		table.insert(
			Parts,
			string.format(
				"struct Struct%d {\n\tFieldA: u8(0..%d),\n\tFieldB: string,\n\tFieldC: Color3?,\n\tFieldD: Shared[],\n}",
				Index,
				Index % 200
			)
		)
		table.insert(
			Parts,
			string.format(
				"event Event%d {\n\tfrom: Server,\n\ttype: Reliable,\n\tcall: SingleSync,\n\tdata: Struct%d,\n}",
				Index,
				Index
			)
		)
		table.insert(
			Parts,
			string.format(
				"function Function%d {\n\tyield: Coroutine,\n\tdata: Struct%d,\n\treturn: u8,\n}",
				Index,
				Index
			)
		)
	end
	return table.concat(Parts, "\n")
end

local function runWorkload(Name: string, Source: string, Directory: string, FileName: string)
	-- Warmup (JIT, caches)
	for _ = 1, WARMUP do
		local ParserInstance = Parser.new(Directory, FileName)
		local Ast = ParserInstance:Parse(Source)
		Generator.Generate("Server", Ast)
		Generator.Generate("Client", Ast)
	end

	-- lune's collectgarbage only supports "count"; no forced collection available.
	local HeapBefore = collectgarbage("count")

	local ParseTimes = {}
	local GenerateTimes = {}
	local TotalTimes = {}
	local LastServer, LastClient

	for _ = 1, ITERATIONS do
		local TotalStart = os.clock()

		local ParseStart = os.clock()
		local ParserInstance = Parser.new(Directory, FileName)
		local Ast = ParserInstance:Parse(Source)
		table.insert(ParseTimes, os.clock() - ParseStart)

		local GenerateStart = os.clock()
		LastServer = Generator.Generate("Server", Ast)
		LastClient = Generator.Generate("Client", Ast)
		table.insert(GenerateTimes, os.clock() - GenerateStart)

		table.insert(TotalTimes, os.clock() - TotalStart)
	end

	local HeapAfter = collectgarbage("count")

	print(`== {Name} ({#Source} bytes source, {ITERATIONS} iterations, {WARMUP} warmup)`)
	print(`   parse    median {string.format("%.3f", median(ParseTimes) * 1000)} ms`)
	print(`   generate median {string.format("%.3f", median(GenerateTimes) * 1000)} ms`)
	print(`   total    median {string.format("%.3f", median(TotalTimes) * 1000)} ms`)
	print(`   heap     before {string.format("%.1f", HeapBefore)} KB | after {string.format("%.1f", HeapAfter)} KB`)
	print(`   output   server {LastServer and #LastServer or 0} B, client {LastClient and #LastClient or 0} B`)
end

local FilePath = RequestedFile
if fs.isFile(FilePath) then
	local Source = fs.readFile(FilePath)
	local Directory = string.match(FilePath, "^(.*[/\\])") or "./"
	runWorkload(FilePath, Source, Directory, string.match(FilePath, "([^/\\]+)$") :: string)
end

runWorkload("synthetic-60", syntheticSource(60), "./", "synthetic.blink")
