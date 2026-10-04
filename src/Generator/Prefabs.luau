--!native
--!optimize 2

local Blocks = require("./Blocks")
local Parser = require("../Parser")

type Block = Blocks.Block
type Writer = (Value: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
type Reader = (Variable: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
type Generate = (
	Declaration: Parser.Primitive,
	Variable: string?,
	Read: Block,
	Write: Block,
	WriteValidations: boolean?
) -> ()

type TypePrefab = {
	Read: Reader,
	Write: Writer,
}

type AssertPrefab = {
	Lower: string,
	Upper: string,
	Exact: string?,
	Combined: string?,
}

type AssertGenerator = (Variable: string, ...any) -> AssertPrefab

local SEND_BUFFER = "SendBuffer"
local RECIEVE_BUFFER = "RecieveBuffer"
local SEND_POSITION = "SendOffset"

local BYTE = 1
local SHORT = 2
local INTEGER = 4
local HALF_FLOAT = 2
local FLOAT = 4
local DOUBLE = 8

local Types = {}
local Asserts = {
	float = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable} >= {Min}) then error(\`Expected "{Variable}" to be larger than or equal to {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if not ({Variable} <= {Max}) then error(\`Expected "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if {Variable} ~= {Max} then error(\`Expected "{Variable}" to be equal to {Max}, got \{{Variable}\} instead.\`) end`,
		}
	end,

	-- `% 1 == 0` rejects fractions and NaN/inf, which `<`/`>` silently accept;
	-- writing 1.5 or 0/0 into an integer slot truncates and corrupts every
	-- later value in the batch.
	integer = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable} >= {Min} and {Variable} % 1 == 0) then error(\`Expected "{Variable}" to be an integer larger than or equal to {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if not ({Variable} <= {Max} and {Variable} % 1 == 0) then error(\`Expected "{Variable}" to be an integer smaller than or equal to {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if not ({Variable} == {Max} and {Variable} % 1 == 0) then error(\`Expected "{Variable}" to be an integer equal to {Max}, got \{{Variable}} instead.\`) end`,
			-- One branch and one error site instead of three. This roughly halves
			-- the guard code emitted per numeric field, which matters because it
			-- is emitted per declaration on both sides of the wire.
			Combined = `if {Variable} % 1 ~= 0 or {Variable} < {Min} or {Variable} > {Max} then error(\`Expected "{Variable}" to be an integer between {Min} and {Max}, got \{{Variable}} instead.\`) end`,
		}
	end,

	string = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if #{Variable} < {Min} then error(\`Expected length of "{Variable}" to be larger than or equal to {Min}, got \{#{Variable}} instead.\`) end`,
			Upper = `if #{Variable} > {Max} then error(\`Expected length of "{Variable}" to be smaller than or equal to  {Max}, got \{#{Variable}} instead.\`) end`,
			Exact = `if #{Variable} ~= {Max} then error(\`Expected length of "{Variable}" to equal to {Max}, got \{#{Variable}} instead.\`) end`,
		}
	end,

	vector = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if not ({Variable}.Magnitude >= {Min}) then error(\`Expected magnitude of "{Variable}" to be larger than or equal to {Min}, got \{{Variable}.Magnitude} instead.\`) end`,
			Upper = `if not ({Variable}.Magnitude <= {Max}) then error(\`Expected magnitude of "{Variable}" to be smaller than or equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
			Exact = `if {Variable}.Magnitude ~= {Max} then error(\`Expected magnitude of "{Variable}" to equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
		}
	end,

	buffer = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if buffer.len({Variable}) < {Min} then error(\`Expected size of "{Variable}" to be larger than or equal to {Min}, got \{buffer.len({Variable})} instead.\`) end`,
			Upper = `if buffer.len({Variable}) > {Max} then error(\`Expected size of "{Variable}" to be smaller than or equal to {Max}, got \{buffer.len({Variable})} instead.\`) end`,
			Exact = `if buffer.len({Variable}) ~= {Max} then error(\`Expected size of "{Variable}" to equal to {Max}, got \{buffer.len({Variable})} instead.\`) end`,
		}
	end,

	Instance = function(Variable: string, Class: string): AssertPrefab
		local TypeAssertion =
			`if typeof({Variable}) ~= "Instance" then error(\`Expected an Instance, got \{typeof({Variable})} instead.\`) end`
		return {
			Lower = `error("Something has gone wrong")`,
			Upper = `error("Something has gone wrong")`,
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

local NumberTypeBounds = {
	{ Bits = 8, Maximum = 255, Type = "u8" },
	{ Bits = 16, Maximum = 65535, Type = "u16" },
	{ Bits = 32, Maximum = 4294967295, Type = "u32" },
}

local function GetTypeToUse(UpperSize: number): TypePrefab
	for _, NumberType in NumberTypeBounds do
		if NumberType.Maximum >= UpperSize then
			return Types[NumberType.Type]
		end
	end

	error("Value is too large to be written to a buffer.")
end

local function GetTypeToUseByBits(UpperBits: number): TypePrefab
	for _, NumberType in NumberTypeBounds do
		if NumberType.Bits >= UpperBits then
			return Types[NumberType.Type]
		end
	end

	error("Value is too large to be written to a buffer.")
end

local function GeneratePrimitivePrefab(
	Type: string,
	Prefab: TypePrefab,
	AssertGenerator: AssertGenerator?,
	DefaultMin: number?,
	DefaultMax: number?
): Generate
	return function(
		Declaration: Parser.Primitive,
		Variable: string?,
		Read: Block,
		Write: Block,
		WriteValidations: boolean?
	)
		local Value = Declaration.Value
		local Tokens = Declaration.Tokens
		local Variable = Variable or "Value"

		local Range = Value.Range
		local Class = Value.Class
		local Components = Value.Components
		local Primitive = Tokens.Primitive.Value
		local IsVariableSize = (Range and Range.Max ~= Range.Min)

		local function GenerateValidation(Block: Block, Variable: string)
			if Block == Write and Type ~= "any" and WriteValidations ~= true then
				-- type identity is a debugging aid only
			elseif Block == Write and Type ~= "any" then
				Block:Compare(`typeof({Variable})`, `"{Type}"`, "Not")
					:Line(`error(\`Expected {Variable} to be of type {Type}, got \{type({Variable})} instead.\`)`)
					:End()
			end

			if not AssertGenerator then
				return
			end

			if Range then
				local Assert = AssertGenerator(Variable, Range.Min, Range.Max)
				if not IsVariableSize and Assert.Exact then
					Block:Line(Assert.Exact)
				elseif Assert.Combined then
					Block:Line(Assert.Combined)
				else
					Block:Line(Assert.Lower)
					Block:Line(Assert.Upper)
				end
			elseif DefaultMin and DefaultMax then
				local Assert = AssertGenerator(Variable, DefaultMin, DefaultMax)
				Block:Line(Assert.Combined or Assert.Lower)
			elseif Primitive == "Instance" and Class then
				local Assert = AssertGenerator(Variable, Class)
				if Block == Write then
					Block:Compare(Variable, "nil", "Not"):Multiline(Assert.Exact, Block.Indent + 1):End()
				else
					Block:Multiline(Assert.Exact, Block.Indent)
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
			Block:Line(`{Block:Declare(Variable)} = buffer.read{Type}({RECIEVE_BUFFER}, {Block:Read(Size)})`)
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

-- Values a primitive can represent even when the schema declares no range.
-- Without these `buffer.writeu8(300, 1.5)` keeps the low bits and shifts every
-- later value in the batch, so they are emitted regardless of WriteValidations.
--> Numbers
Types.u8, Primitives.u8 = GenerateNumberGenerator("u8", BYTE, Asserts.integer, 0, 255)
Types.u16, Primitives.u16 = GenerateNumberGenerator("u16", SHORT, Asserts.integer, 0, 65535)
Types.u32, Primitives.u32 =
	GenerateNumberGenerator("u32", INTEGER, Asserts.integer, 0, 4294967295)

Types.i8, Primitives.i8 = GenerateNumberGenerator("i8", BYTE, Asserts.integer, -128, 127)
Types.i16, Primitives.i16 = GenerateNumberGenerator("i16", SHORT, Asserts.integer, -32768, 32767)
Types.i32, Primitives.i32 =
	GenerateNumberGenerator("i32", INTEGER, Asserts.integer, -2147483648, 2147483647)

Types.f32, Primitives.f32 = GenerateNumberGenerator("f32", FLOAT, Asserts.float)
Types.f64, Primitives.f64 = GenerateNumberGenerator("f64", DOUBLE, Asserts.float)

Types.f16 = {
	Read = function(Variable: string, Block: Block)
		Types.u16.Read("f16Encoded", Block)
		Block:Declare(Variable, true)
		Block:Lines({
			`local f16Exponent = f16Encoded // 0x400 % 0x20\n`,
			`local f16Mantissa = f16Encoded % 0x400\n`,
			`local f16Sign = if f16Encoded >= 0x8000 then -1 else 1\n`,
			`if f16Exponent == 31 then\n`,
			`	-- a zero mantissa is infinity, any other mantissa is NaN\n`,
			`	{Variable} = if f16Mantissa == 0 then f16Sign * math.huge else 0 / 0\n`,
			`elseif f16Exponent == 0 then\n`,
			`	-- zero or subnormal, value is mantissa * 2^-24\n`,
			`	{Variable} = f16Sign * math.ldexp(f16Mantissa / 0x400, -14)\n`,
			`else\n`,
			`	{Variable} = f16Sign * math.ldexp(1 + f16Mantissa / 0x400, f16Exponent - 15)\n`,
			`end\n`,
		})
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
				`if 1 / {Value} < 0 then buffer.writeu16({SEND_BUFFER}, {Allocation}, 0x8000) else buffer.writeu16({SEND_BUFFER}, {Allocation}, 0) end`
			)
			:Branch("Default")
			:Line(`local float = {Value}`)
			:Lines({
				"local Abosulte = math.abs(float)\n",
				"local Interval = math.ldexp(1, math.floor(math.log(Abosulte, 2)) - 10)\n",
				"local RoundedValue = math.round(Abosulte / Interval) * Interval\n",
				"local Fraction, Exponent = math.frexp(RoundedValue)\n",
				"Exponent += 14\n",
				"local Mantissa = math.round(if Exponent <= 0\n",
				"	then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent))\n",
				"	else Fraction * 0x800) % 0x400\n",
				"local Result = Mantissa\n",
				"	+ math.max(Exponent, 0) * 0x400\n",
				"	+ if float < 0 then 0x8000 else 0\n",
			}, Block.Indent + 1)
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, Result)`)
			:End()
	end,
}

Primitives.f16 = {
	Type = "number",
	Generate = GeneratePrimitivePrefab("number", Types.f16, Asserts.float),
}

--> Boolean
do
	Types.boolean = {
		Read = function(Variable: string, Block: Block)
			Block:Line(`{Block:Declare(Variable)} = (buffer.readu8({RECIEVE_BUFFER}, {Block:Read(BYTE)}) == 1)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`buffer.writeu8({SEND_BUFFER}, {Block:Allocate(BYTE)}, {Value} and 1 or 0)`)
		end,
	}

	Primitives.boolean = {
		Type = "boolean",
		Generate = GeneratePrimitivePrefab("boolean", Types.boolean),
	}
end

--> String
do
	Types.string = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			--> Fixed size string
			if Range and Range.Min == Range.Max then
				Block:Line(
					`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, {Block:Read(Range.Min)}, {Range.Min})`
				)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthType = GetTypeToUse(Upper)

			LengthType.Read("Length", Block)
			Block:Line(`if Length > {Upper} then error(\`Expected "{Variable}" to be at most {Upper} bytes, got Length bytes\`) end`)
			Block:Line(`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.writestring({SEND_BUFFER}, {Block:Allocate(Range.Min)}, {Value}, {Range.Min})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthType = GetTypeToUse(Upper)

			Block:Line(`local Length = #{Value}`)
			Block:Line(`if Length > {Upper} then error(\`Expected "{Value}" to be at most {Upper} bytes, got Length bytes\`) end`)
			LengthType.Write("Length", Block)
			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.writestring({SEND_BUFFER}, {SEND_POSITION}, {Value}, Length)`)
		end,
	}

	Primitives.string = {
		Type = "string",
		Generate = GeneratePrimitivePrefab("string", Types.string, Asserts.string),
	}
end

--> Vector
do
	Types.vector = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Prefab.Read("X", Block)
			Prefab.Read("Y", Block)
			Prefab.Read("Z", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector3.new(X, Y, Z)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Block:Line(`local Vector = {Value}`)
			Prefab.Write("Vector.X", Block)
			Prefab.Write("Vector.Y", Block)
			Prefab.Write("Vector.Z", Block)
		end,
	}

	Primitives.vector = {
		Type = "Vector3",
		Generate = GeneratePrimitivePrefab("Vector3", Types.vector, Asserts.vector),
	}
end

--> Buffer
do
	Types.buffer = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				local Length = Range.Max
				Block:Line(`{Block:Declare(Variable)} = buffer.create({Length})`)
				Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, {Block:Read(Length)}, {Length})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthType = GetTypeToUse(Upper)
			LengthType.Read("Length", Block)
			Block:Line(`if Length > {Upper} then error(\`Expected "{Variable}" to be at most {Upper} bytes, got Length bytes\`) end`)
			Block:Line(`{Block:Declare(Variable)} = buffer.create(Length)`)
			Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.copy({SEND_BUFFER}, {Block:Allocate(Range.Max)}, {Value}, 0, {Range.Max})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthType = GetTypeToUse(Upper)
			Block:Line(`local Length = buffer.len({Value})`)
			Block:Line(`if Length > {Upper} then error(\`Expected "{Value}" to be at most {Upper} bytes, got Length bytes\`) end`)
			LengthType.Write("Length", Block)
			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.copy({SEND_BUFFER}, {SEND_POSITION}, {Value}, 0, Length)`)
		end,
	}

	Primitives.buffer = {
		Type = "buffer",
		Generate = GeneratePrimitivePrefab("buffer", Types.buffer, Asserts.buffer),
	}
end

--> CFrame
do
	Types.CFrame = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			-- documented as `CFrame<position, rotation>`
			local Position = (Components and Components[1]) or "f32"
			local Rotation: TypePrefab = Types[(Components and Components[2]) or "f32"] or Types.f32

			Types.vector.Read("Position", Block, nil, { Position })
			Rotation.Read("rX", Block)
			Rotation.Read("rY", Block)
			Rotation.Read("rZ", Block)
			Block:Line(`{Block:Declare(Variable)} = CFrame.new(Position) * CFrame.fromOrientation(rX, rY, rZ)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Position = (Components and Components[1]) or "f32"
			local Rotation: TypePrefab = Types[(Components and Components[2]) or "f32"] or Types.f32

			Types.vector.Write(`{Value}.Position`, Block, nil, { Position })
			Block:Line(`local rX, rY, rZ = {Value}:ToOrientation()`)
			Rotation.Write("rX", Block)
			Rotation.Write("rY", Block)
			Rotation.Write("rZ", Block)
		end,
	}

	Primitives.CFrame = {
		Type = "CFrame",
		Generate = GeneratePrimitivePrefab("CFrame", Types.CFrame),
	}
end

--> Color3
do
	Types.Color3 = {
		Read = function(Variable: string, Block: Block)
			local R = Block:Read(BYTE)
			local G = Block:Read(BYTE)
			local B = Block:Read(BYTE)
			Block:Line(
				`{Block:Declare(Variable)} = Color3.fromRGB(buffer.readu8({RECIEVE_BUFFER}, {R}), buffer.readu8({RECIEVE_BUFFER}, {G}), buffer.readu8({RECIEVE_BUFFER}, {B}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Color = {Value}`)
			Types.u8.Write("Color.R * 255", Block)
			Types.u8.Write("Color.G * 255", Block)
			Types.u8.Write("Color.B * 255", Block)
		end,
	}

	Primitives.Color3 = {
		Type = "Color3",
		Generate = GeneratePrimitivePrefab("Color3", Types.Color3),
	}
end

--> DateTime
do
	Types.DateTime = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestamp = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestamp(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestamp}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTime = {Value}`)
			Types.f64.Write(`DateTime.UnixTimestamp`, Block)
		end,
	}

	Primitives.DateTime = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTime),
	}
end

--> DateTimeMillis
do
	Types.DateTimeMillis = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestampMillis = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestampMillis(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestampMillis}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTimeMillis = {Value}`)
			Types.f64.Write(`DateTimeMillis.UnixTimestampMillis`, Block)
		end,
	}

	Primitives.DateTimeMillis = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTimeMillis),
	}
end

--> BrickColor
do
	Types.BrickColor = {
		Read = function(Variable: string, Block: Block)
			local Number = Block:Read(SHORT)
			Block:Line(`{Block:Declare(Variable)} = BrickColor.new(buffer.readu16({RECIEVE_BUFFER}, {Number}))`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local BrickColor = {Value}`)
			Types.u16.Write("BrickColor.Number", Block)
		end,
	}

	Primitives.BrickColor = {
		Type = "BrickColor",
		Generate = GeneratePrimitivePrefab("BrickColor", Types.BrickColor),
	}
end

--> Instance
do
	Types.Instance = {
		Read = function(Variable: string, Block: Block)
			--Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, {Value} or Null)`)
		end,
	}

	Primitives.Instance = {
		Type = function(Declaration)
			return Declaration.Value.Class
		end,
		Generate = GeneratePrimitivePrefab("any", Types.Instance, Asserts.Instance),
	}
end

--> unknown
do
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
end

return {
	Types = Types,
	Asserts = Asserts,
	Primitives = Primitives,
	GetTypeToUse = GetTypeToUse,
	GetTypeToUseByBits = GetTypeToUseByBits,
}
