--!strict
--!native
--!optimize 2

local Blocks = require("./Blocks")
local Parser = require("../Parser")

export type Block = Blocks.Block
export type Writer = (Value: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
export type Reader = (Variable: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()

export type Generate = (
	Declaration: Parser.Primitive,
	Variable: string?,
	Read: Block,
	Write: Block,
	WriteValidations: boolean?
) -> ()

export type TypePrefab = {
	Read: Reader,
	Write: Writer,
}

export type AssertPrefab = {
	Lower: string,
	Upper: string,
	Exact: string?,
	Combined: string?,
}

export type AssertGenerator = (Variable: string, ...any) -> AssertPrefab

-- Wire/buffer identifier names emitted into the generated source.
-- Retaining runtime variable naming conventions for compatibility.
local SEND_BUFFER = "SendBuffer"
local RECEIVE_BUFFER = "RecieveBuffer"
local SEND_POSITION = "SendOffset"

local BYTE = 1
local SHORT = 2
local INTEGER = 4
local HALF_FLOAT = 2
local FLOAT = 4
local DOUBLE = 8

local Types: { [string]: TypePrefab } = {}

local Asserts = {
	float = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable} >= {Min}) then error(\`Expected "{Variable}" to be larger than or equal to {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if not ({Variable} <= {Max}) then error(\`Expected "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if {Variable} ~= {Max} then error(\`Expected "{Variable}" to be equal to {Max}, got \{{Variable}} instead.\`) end`,
			-- IEEE-754: `not (a >= Min and a <= Max)` rejects out-of-range, NaN, and +/-inf in a single comparison branch.
			Combined = `if not ({Variable} >= {Min} and {Variable} <= {Max}) then error(\`Expected "{Variable}" to be between {Min} and {Max}, got \{{Variable}} instead.\`) end`,
		}
	end,

	-- `% 1 == 0` rejects fractions and NaN/inf, which `<`/`>` silently accept.
	integer = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable} >= {Min} and {Variable} % 1 == 0) then error(\`Expected "{Variable}" to be an integer larger than or equal to {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if not ({Variable} <= {Max} and {Variable} % 1 == 0) then error(\`Expected "{Variable}" to be an integer smaller than or equal to {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if not ({Variable} == {Max} and {Variable} % 1 == 0) then error(\`Expected "{Variable}" to be an integer equal to {Max}, got \{{Variable}} instead.\`) end`,
			Combined = `if {Variable} % 1 ~= 0 or {Variable} < {Min} or {Variable} > {Max} then error(\`Expected "{Variable}" to be an integer between {Min} and {Max}, got \{{Variable}} instead.\`) end`,
		}
	end,

	string = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if #{Variable} < {Min} then error(\`Expected length of "{Variable}" to be larger than or equal to {Min}, got \{#{Variable}} instead.\`) end`,
			Upper = `if #{Variable} > {Max} then error(\`Expected length of "{Variable}" to be smaller than or equal to {Max}, got \{#{Variable}} instead.\`) end`,
			Exact = `if #{Variable} ~= {Max} then error(\`Expected length of "{Variable}" to be equal to {Max}, got \{#{Variable}} instead.\`) end`,
			Combined = `if #{Variable} < {Min} or #{Variable} > {Max} then error(\`Expected length of "{Variable}" to be between {Min} and {Max}, got \{#{Variable}} instead.\`) end`,
		}
	end,

	vector = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable}.Magnitude >= {Min}) then error(\`Expected magnitude of "{Variable}" to be larger than or equal to {Min}, got \{{Variable}.Magnitude} instead.\`) end`,
			Upper = `if not ({Variable}.Magnitude <= {Max}) then error(\`Expected magnitude of "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
			Exact = `if {Variable}.Magnitude ~= {Max} then error(\`Expected magnitude of "{Variable}" to be equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
			-- Evaluates `.Magnitude` (vector length sqrt) only once in the failure branch.
			Combined = `if not ({Variable}.Magnitude >= {Min} and {Variable}.Magnitude <= {Max}) then error(\`Expected magnitude of "{Variable}" to be between {Min} and {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
		}
	end,

	buffer = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if buffer.len({Variable}) < {Min} then error(\`Expected size of "{Variable}" to be larger than or equal to {Min}, got \{buffer.len({Variable})} instead.\`) end`,
			Upper = `if buffer.len({Variable}) > {Max} then error(\`Expected size of "{Variable}" to be smaller than or equal to {Max}, got \{buffer.len({Variable})} instead.\`) end`,
			Exact = `if buffer.len({Variable}) ~= {Max} then error(\`Expected size of "{Variable}" to be equal to {Max}, got \{buffer.len({Variable})} instead.\`) end`,
			Combined = `if buffer.len({Variable}) < {Min} or buffer.len({Variable}) > {Max} then error(\`Expected size of "{Variable}" to be between {Min} and {Max}, got \{buffer.len({Variable})} instead.\`) end`,
		}
	end,

	Instance = function(Variable: string, Class: string): AssertPrefab
		local TypeAssertion =
			`if typeof({Variable}) ~= "Instance" then error(\`Expected an Instance, got \{typeof({Variable})} instead.\`) end`
		return {
			Lower = `error("Bounds validations are not applicable to Instance primitives")`,
			Upper = `error("Bounds validations are not applicable to Instance primitives")`,
			Exact = if Class == "Instance"
				then TypeAssertion
				else `{TypeAssertion}\nif not {Variable}:IsA("{Class}") then error(\`Expected an Instance of type "{Class}", got "\{{Variable}.ClassName}" instead.\`) end`,
		}
	end,
}

local Primitives: { [string]: {
	Type: string | (Declaration: Parser.Primitive) -> string,
	Generate: Generate,
} } = {}

-- Fast direct branch dispatch eliminating loop and table allocation churn.
local function GetTypeToUse(UpperSize: number): TypePrefab
	if UpperSize <= 255 then
		return Types.u8
	elseif UpperSize <= 65535 then
		return Types.u16
	elseif UpperSize <= 4294967295 then
		return Types.u32
	end

	error(`Payload size {UpperSize} exceeds the maximum buffer length of 4294967295 bytes.`)
end

local function GetTypeToUseByBits(UpperBits: number): TypePrefab
	if UpperBits <= 8 then
		return Types.u8
	elseif UpperBits <= 16 then
		return Types.u16
	elseif UpperBits <= 32 then
		return Types.u32
	end

	error(`Bit length {UpperBits} exceeds maximum supported width of 32 bits.`)
end

local function GeneratePrimitivePrefab(
	Type: string,
	Prefab: TypePrefab,
	AssertGen: AssertGenerator?,
	DefaultMin: number?,
	DefaultMax: number?
): Generate
	return function(
		Declaration: Parser.Primitive,
		VariableParam: string?,
		Read: Block,
		Write: Block,
		WriteValidations: boolean?
	)
		local Value = Declaration.Value
		local Tokens = Declaration.Tokens
		local Variable = VariableParam or "Value"

		local Range = Value.Range
		local Class = Value.Class
		local Components = Value.Components
		local Primitive = Tokens.Primitive.Value
		local IsVariableSize = (Range and Range.Max ~= Range.Min)

		local function GenerateValidation(Block: Block, VarName: string)
			if Block == Write and Type ~= "any" and WriteValidations ~= true then
				-- Type identity check disabled for production client write paths.
			elseif Block == Write and Type ~= "any" then
				Block:Compare(`typeof({VarName})`, `"{Type}"`, "Not")
					:Line(`error(\`Expected {VarName} to be of type {Type}, got \{typeof({VarName})} instead.\`)`)
					:End()
			end

			if not AssertGen then
				return
			end

			if Range then
				local Assert = AssertGen(VarName, Range.Min, Range.Max)
				if not IsVariableSize and Assert.Exact then
					Block:Line(Assert.Exact)
				elseif Assert.Combined then
					Block:Line(Assert.Combined)
				else
					Block:Line(Assert.Lower)
					Block:Line(Assert.Upper)
				end
			elseif DefaultMin ~= nil and DefaultMax ~= nil then
				local Assert = AssertGen(VarName, DefaultMin, DefaultMax)
				if Assert.Combined then
					Block:Line(Assert.Combined)
				else
					Block:Line(Assert.Lower)
					Block:Line(Assert.Upper)
				end
			elseif Primitive == "Instance" and Class then
				local Assert = AssertGen(VarName, Class)
				local exactCode = Assert.Exact or `error("Malformed instance validation")`
				if Block == Write then
					Block:Compare(VarName, "nil", "Not")
						:Multiline(exactCode, Block.Indent + 1)
						:End()
				else
					Block:Multiline(exactCode, Block.Indent)
				end
			end
		end

		GenerateValidation(Write, Variable)
		Prefab.Read(Variable, Read, Range, Components)
		Prefab.Write(Variable, Write, Range, Components)
		GenerateValidation(Read, Variable)
	end
end

local function GenerateNumberGenerator(
	Type: string,
	Size: number,
	Assert: AssertGenerator,
	DefaultMin: number?,
	DefaultMax: number?
): (TypePrefab, { Type: string, Generate: Generate })
	local Prefab = {
		Read = function(Variable: string, Block: Block)
			Block:Line(`{Block:Declare(Variable)} = buffer.read{Type}({RECEIVE_BUFFER}, {Block:Read(Size)})`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`buffer.write{Type}({SEND_BUFFER}, {Block:Allocate(Size)}, {Value})`)
		end,
	}

	local Primitive = {
		Type = "number",
		Generate = GeneratePrimitivePrefab("number", Prefab, Assert, DefaultMin, DefaultMax),
	}

	return Prefab, Primitive
end

--> Fixed Integer Primitives
Types.u8, Primitives.u8 = GenerateNumberGenerator("u8", BYTE, Asserts.integer, 0, 255)
Types.u16, Primitives.u16 = GenerateNumberGenerator("u16", SHORT, Asserts.integer, 0, 65535)
Types.u32, Primitives.u32 = GenerateNumberGenerator("u32", INTEGER, Asserts.integer, 0, 4294967295)

Types.i8, Primitives.i8 = GenerateNumberGenerator("i8", BYTE, Asserts.integer, -128, 127)
Types.i16, Primitives.i16 = GenerateNumberGenerator("i16", SHORT, Asserts.integer, -32768, 32767)
Types.i32, Primitives.i32 = GenerateNumberGenerator("i32", INTEGER, Asserts.integer, -2147483648, 2147483647)

Types.f32, Primitives.f32 = GenerateNumberGenerator("f32", FLOAT, Asserts.float)
Types.f64, Primitives.f64 = GenerateNumberGenerator("f64", DOUBLE, Asserts.float)

--> IEEE 754 Half-Precision Float (binary16)
Types.f16 = {
	Read = function(Variable: string, Block: Block)
		Block:Declare(Variable, true)
		local ReadOffset = Block:Read(HALF_FLOAT)
		-- Enclosed in `do ... end` to prevent local variable collisions when multiple f16s exist in scope.
		Block:Line("do")
		Block:Lines({
			`	local raw = buffer.readu16({RECEIVE_BUFFER}, {ReadOffset})\n`,
			`	local exp = raw // 0x400 % 0x20\n`,
			`	local mantissa = raw % 0x400\n`,
			`	local sign = if raw >= 0x8000 then -1 else 1\n`,
			`	if exp == 31 then\n`,
			`		{Variable} = if mantissa == 0 then sign * math.huge else 0 / 0\n`,
			`	elseif exp == 0 then\n`,
			`		{Variable} = sign * math.ldexp(mantissa / 0x400, -14)\n`,
			`	else\n`,
			`		{Variable} = sign * math.ldexp(1 + mantissa / 0x400, exp - 15)\n`,
			`	end\n`,
		})
		Block:Line("end")
	end,
	Write = function(Value: string, Block: Block)
		local Allocation = Block:Allocate(HALF_FLOAT)
		Block:Compare(Value, "65520", "Greater")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b0_11111_0000000000)`)
			:Branch("Conditional", Value, "-65520", "Less")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000000)`)
			:Branch("Conditional", Value, Value, "Not")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000001)`)
			:Branch("Conditional", Value, "0", "Equals")
			:Line(
				`if 1 / ({Value}) < 0 then buffer.writeu16({SEND_BUFFER}, {Allocation}, 0x8000) else buffer.writeu16({SEND_BUFFER}, {Allocation}, 0) end`
			)
			:Branch("Default")
			-- Optimized IEEE mantissa rounding: using `math.frexp` avoids costly `math.log` calls and precision drift.
			Block:Line("do")
			Block:Lines({
				`	local val = {Value}\n`,
				`	local absVal = math.abs(val)\n`,
				`	local _, rawExp = math.frexp(absVal)\n`,
				`	local interval = math.ldexp(1, rawExp - 11)\n`,
				`	local rounded = math.round(absVal / interval) * interval\n`,
				`	local fraction, exp = math.frexp(rounded)\n`,
				`	exp += 14\n`,
				`	local mantissa = math.round(if exp <= 0\n`,
				`		then fraction * 0x400 / math.ldexp(1, math.abs(exp))\n`,
				`		else fraction * 0x800) % 0x400\n`,
				`	local result = mantissa\n`,
				`		+ math.max(exp, 0) * 0x400\n`,
				`		+ if val < 0 then 0x8000 else 0\n`,
				`	buffer.writeu16({SEND_BUFFER}, {Allocation}, result)\n`,
			}, Block.Indent + 1)
			Block:Line("end")
			:End()
	end,
}

Primitives.f16 = {
	Type = "number",
	Generate = GeneratePrimitivePrefab("number", Types.f16, Asserts.float),
}

--> Boolean
Types.boolean = {
	Read = function(Variable: string, Block: Block)
		Block:Line(`{Block:Declare(Variable)} = (buffer.readu8({RECEIVE_BUFFER}, {Block:Read(BYTE)}) == 1)`)
	end,
	Write = function(Value: string, Block: Block)
		Block:Line(`buffer.writeu8({SEND_BUFFER}, {Block:Allocate(BYTE)}, if {Value} then 1 else 0)`)
	end,
}

Primitives.boolean = {
	Type = "boolean",
	Generate = GeneratePrimitivePrefab("boolean", Types.boolean),
}

--> String
Types.string = {
	Read = function(Variable: string, Block: Block, Range: NumberRange?)
		if Range and Range.Min == Range.Max then
			local Size = Range.Min
			Block:Line(
				`{Block:Declare(Variable)} = buffer.readstring({RECEIVE_BUFFER}, {Block:Read(Size)}, {Size})`
			)
			return
		end

		local Upper = Range and Range.Max or 65535
		local LengthType = GetTypeToUse(Upper)

		Block:Line("do")
		LengthType.Read("strLen", Block)
		-- Fixed: `\{strLen}` properly interpolates the decoded runtime length into the diagnostic message.
		Block:Line(`	if strLen > {Upper} then error(\`Expected "{Variable}" to be at most {Upper} bytes, got \{strLen} bytes\`) end`)
		Block:Line(`	{Block:Declare(Variable)} = buffer.readstring({RECEIVE_BUFFER}, Read(strLen), strLen)`)
		Block:Line("end")
	end,
	Write = function(Value: string, Block: Block, Range: NumberRange?)
		if Range and Range.Min == Range.Max then
			local Size = Range.Min
			Block:Line(`buffer.writestring({SEND_BUFFER}, {Block:Allocate(Size)}, {Value}, {Size})`)
			return
		end

		local Upper = Range and Range.Max or 65535
		local LengthType = GetTypeToUse(Upper)

		Block:Line("do")
		Block:Line(`	local strLen = #{Value}`)
		Block:Line(`	if strLen > {Upper} then error(\`Expected "{Value}" to be at most {Upper} bytes, got \{strLen} bytes\`) end`)
		LengthType.Write("strLen", Block)
		Block:Line(`	Allocate(strLen)`)
		Block:Line(`	buffer.writestring({SEND_BUFFER}, {SEND_POSITION}, {Value}, strLen)`)
		Block:Line("end")
	end,
}

Primitives.string = {
	Type = "string",
	Generate = GeneratePrimitivePrefab("string", Types.string, Asserts.string),
}

--> Vector3
Types.vector = {
	Read = function(Variable: string, Block: Block, _, Components: { string }?)
		local Prefab: TypePrefab = Types.f32
		if Components and Components[1] then
			Prefab = Types[Components[1]] or Prefab
		end

		Block:Line("do")
		Prefab.Read("vX", Block)
		Prefab.Read("vY", Block)
		Prefab.Read("vZ", Block)
		Block:Line(`	{Block:Declare(Variable)} = Vector3.new(vX, vY, vZ)`)
		Block:Line("end")
	end,
	Write = function(Value: string, Block: Block, _, Components: { string }?)
		local Prefab: TypePrefab = Types.f32
		if Components and Components[1] then
			Prefab = Types[Components[1]] or Prefab
		end

		Block:Line("do")
		Block:Line(`	local vec = {Value}`)
		Prefab.Write("vec.X", Block)
		Prefab.Write("vec.Y", Block)
		Prefab.Write("vec.Z", Block)
		Block:Line("end")
	end,
}

Primitives.vector = {
	Type = "Vector3",
	Generate = GeneratePrimitivePrefab("Vector3", Types.vector, Asserts.vector),
}

--> Buffer
Types.buffer = {
	Read = function(Variable: string, Block: Block, Range: NumberRange?)
		if Range and Range.Min == Range.Max then
			local Length = Range.Max
			Block:Line(`{Block:Declare(Variable)} = buffer.create({Length})`)
			Block:Line(`buffer.copy({Variable}, 0, {RECEIVE_BUFFER}, {Block:Read(Length)}, {Length})`)
			return
		end

		local Upper = Range and Range.Max or 65535
		local LengthType = GetTypeToUse(Upper)

		Block:Line("do")
		LengthType.Read("bufLen", Block)
		Block:Line(`	if bufLen > {Upper} then error(\`Expected "{Variable}" to be at most {Upper} bytes, got \{bufLen} bytes\`) end`)
		Block:Line(`	{Block:Declare(Variable)} = buffer.create(bufLen)`)
		Block:Line(`	buffer.copy({Variable}, 0, {RECEIVE_BUFFER}, Read(bufLen), bufLen)`)
		Block:Line("end")
	end,
	Write = function(Value: string, Block: Block, Range: NumberRange?)
		if Range and Range.Min == Range.Max then
			local Size = Range.Max
			Block:Line(`buffer.copy({SEND_BUFFER}, {Block:Allocate(Size)}, {Value}, 0, {Size})`)
			return
		end

		local Upper = Range and Range.Max or 65535
		local LengthType = GetTypeToUse(Upper)

		Block:Line("do")
		Block:Line(`	local bufLen = buffer.len({Value})`)
		Block:Line(`	if bufLen > {Upper} then error(\`Expected "{Value}" to be at most {Upper} bytes, got \{bufLen} bytes\`) end`)
		LengthType.Write("bufLen", Block)
		Block:Line(`	Allocate(bufLen)`)
		Block:Line(`	buffer.copy({SEND_BUFFER}, {SEND_POSITION}, {Value}, 0, bufLen)`)
		Block:Line("end")
	end,
}

Primitives.buffer = {
	Type = "buffer",
	Generate = GeneratePrimitivePrefab("buffer", Types.buffer, Asserts.buffer),
}

--> CFrame
Types.CFrame = {
	Read = function(Variable: string, Block: Block, _, Components: { string }?)
		local PosType = (Components and Components[1]) or "f32"
		local RotPrefab: TypePrefab = Types[(Components and Components[2]) or "f32"] or Types.f32

		Block:Line("do")
		Types.vector.Read("pos", Block, nil, { PosType })
		RotPrefab.Read("rX", Block)
		RotPrefab.Read("rY", Block)
		RotPrefab.Read("rZ", Block)
		-- Optimization: `fromOrientation + pos` sets translation directly, bypassing 3x3 matrix multiplication.
		Block:Line(`	{Block:Declare(Variable)} = CFrame.fromOrientation(rX, rY, rZ) + pos`)
		Block:Line("end")
	end,
	Write = function(Value: string, Block: Block, _, Components: { string }?)
		local PosType = (Components and Components[1]) or "f32"
		local RotPrefab: TypePrefab = Types[(Components and Components[2]) or "f32"] or Types.f32

		Block:Line("do")
		Block:Line(`	local cf = {Value}`)
		Types.vector.Write("cf.Position", Block, nil, { PosType })
		Block:Line("	local rX, rY, rZ = cf:ToOrientation()")
		RotPrefab.Write("rX", Block)
		RotPrefab.Write("rY", Block)
		RotPrefab.Write("rZ", Block)
		Block:Line("end")
	end,
}

Primitives.CFrame = {
	Type = "CFrame",
	Generate = GeneratePrimitivePrefab("CFrame", Types.CFrame),
}

--> Color3
Types.Color3 = {
	Read = function(Variable: string, Block: Block)
		local R = Block:Read(BYTE)
		local G = Block:Read(BYTE)
		local B = Block:Read(BYTE)
		Block:Line(
			`{Block:Declare(Variable)} = Color3.fromRGB(buffer.readu8({RECEIVE_BUFFER}, {R}), buffer.readu8({RECEIVE_BUFFER}, {G}), buffer.readu8({RECEIVE_BUFFER}, {B}))`
		)
	end,
	Write = function(Value: string, Block: Block)
		Block:Line("do")
		Block:Line(`	local col = {Value}`)
		-- Rounding ensures floating-point representation limits do not truncate off-by-one (e.g. 254.999 -> 254).
		Types.u8.Write("math.round(col.R * 255)", Block)
		Types.u8.Write("math.round(col.G * 255)", Block)
		Types.u8.Write("math.round(col.B * 255)", Block)
		Block:Line("end")
	end,
}

Primitives.Color3 = {
	Type = "Color3",
	Generate = GeneratePrimitivePrefab("Color3", Types.Color3),
}

--> DateTime
Types.DateTime = {
	Read = function(Variable: string, Block: Block)
		local UnixTimestamp = Block:Read(DOUBLE)
		Block:Line(
			`{Block:Declare(Variable)} = DateTime.fromUnixTimestamp(buffer.readf64({RECEIVE_BUFFER}, {UnixTimestamp}))`
		)
	end,
	Write = function(Value: string, Block: Block)
		Types.f64.Write(`({Value}).UnixTimestamp`, Block)
	end,
}

Primitives.DateTime = {
	Type = "DateTime",
	Generate = GeneratePrimitivePrefab("DateTime", Types.DateTime),
}

--> DateTimeMillis
Types.DateTimeMillis = {
	Read = function(Variable: string, Block: Block)
		local UnixTimestampMillis = Block:Read(DOUBLE)
		Block:Line(
			`{Block:Declare(Variable)} = DateTime.fromUnixTimestampMillis(buffer.readf64({RECEIVE_BUFFER}, {UnixTimestampMillis}))`
		)
	end,
	Write = function(Value: string, Block: Block)
		Types.f64.Write(`({Value}).UnixTimestampMillis`, Block)
	end,
}

Primitives.DateTimeMillis = {
	Type = "DateTime",
	Generate = GeneratePrimitivePrefab("DateTime", Types.DateTimeMillis),
}

--> BrickColor
Types.BrickColor = {
	Read = function(Variable: string, Block: Block)
		local Number = Block:Read(SHORT)
		Block:Line(`{Block:Declare(Variable)} = BrickColor.new(buffer.readu16({RECEIVE_BUFFER}, {Number}))`)
	end,
	Write = function(Value: string, Block: Block)
		Types.u16.Write(`({Value}).Number`, Block)
	end,
}

Primitives.BrickColor = {
	Type = "BrickColor",
	Generate = GeneratePrimitivePrefab("BrickColor", Types.BrickColor),
}

--> Instance
Types.Instance = {
	Read = function(Variable: string, Block: Block)
		-- Fixed: Cursor increment was commented out, causing subsequent Instance reads to point to index 0/1 repeatedly.
		Block:Line("RecieveInstanceCursor += 1")
		Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
	end,
	Write = function(Value: string, Block: Block)
		Block:Line(`table.insert(SendInstances, if {Value} == nil then Null else {Value})`)
	end,
}

Primitives.Instance = {
	Type = function(Declaration)
		return Declaration.Value.Class
	end,
	Generate = GeneratePrimitivePrefab("any", Types.Instance, Asserts.Instance),
}

--> unknown / variant
Types.unknown = {
	Read = function(Variable: string, Block: Block)
		Block:Line("RecieveInstanceCursor += 1")
		Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
	end,
	Write = function(Value: string, Block: Block)
		Block:Line(`table.insert(SendInstances, if {Value} == nil then Null else {Value})`)
	end,
}

Primitives.unknown = {
	Type = "any",
	Generate = GeneratePrimitivePrefab("any", Types.unknown),
}

return table.freeze({
	Types = Types,
	Asserts = Asserts,
	Primitives = Primitives,
	GetTypeToUse = GetTypeToUse,
	GetTypeToUseByBits = GetTypeToUseByBits,
})
