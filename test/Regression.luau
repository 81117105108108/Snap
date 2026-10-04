-- Non-interactive regression tests for the compiler front-end.
-- Covers defects fixed during the improvement pass; run from test/ via:
--   lune run Regression
-- No prompts, no Network folder, no Roblox environment required.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Error = require("../src/Modules/Error")
local Generator = require("../src/Generator")
local Lexer = require("../src/Lexer")
local Parser = require("../src/Parser")
local Settings = require("../src/Settings")
local StringParser = require("../src/Modules/String")

local Passed = 0
local Failed = 0

local function Check(Name: string, Condition: boolean, Detail: string?)
	if Condition then
		Passed += 1
		print(`[PASS] {Name}`)
	else
		Failed += 1
		print(`[FAIL] {Name}{Detail and `: {Detail}` or ""}`)
	end
end

local function Parse(Source: string): Parser.Body
	return Parser.new("./", "regression.blink"):Parse(Source)
end

local function Rejects(Name: string, Source: string)
	local Ok = pcall(Parse, Source)
	Check(Name, Ok == false, "expected the parser to reject this")
end

local function FindDeclaration(Declarations: { Parser.Declaration }, Name: string): Parser.Declaration?
	for _, Declaration in Declarations do
		if Declaration.Name == Name then
			return Declaration
		end
	end
	return nil
end

local function ContainsGeneric(Node: any): boolean
	if type(Node) ~= "table" then
		return false
	end
	if Node.Type == "Generic" then
		return true
	end
	if type(Node.Value) == "table" then
		if Node.Value.Of ~= nil and ContainsGeneric(Node.Value.Of) then
			return true
		end
		if type(Node.Value.Values) == "table" then
			for _, Child in Node.Value.Values do
				if ContainsGeneric(Child) then
					return true
				end
			end
		end
	end
	return false
end

-- 1. Settings exposes correctly spelled primitives table
do
	local Primitives: any = (Settings :: any).Primitives
	Check("Settings.Primitives exists", Primitives ~= nil)
	Check("Settings.Primitives has u8", Primitives ~= nil and Primitives.u8 ~= nil)
	Check("Settings.Primitives has vector", Primitives ~= nil and Primitives.vector ~= nil)
end

-- 2. Lexer modes behave as documented
do
	local Highlighting = Lexer.new(nil, "Highlighting")
	Check("Lexer.new mode stored", (Highlighting :: any).Mode == "Highlighting")
	Check("Lexer.new source defaults empty", (Highlighting :: any).Source == "")

	local Source = 'type A = u8 -- comment'
	local SeenWhitespace = false
	local SeenComment = false
	local Highlight = Lexer.new(Source, "Highlighting")
	while true do
		local Token = Highlight:GetNextToken()
		if Token.Type == "EndOfFile" then
			break
		end
		if Token.Type == "Whitespace" then
			SeenWhitespace = true
		end
		if Token.Type == "Comment" then
			SeenComment = true
		end
	end
	Check("Highlighting emits whitespace", SeenWhitespace)
	Check("Highlighting emits comments", SeenComment)

	local ParsingSeenTrivia = false
	local Parsing = Lexer.new(Source, "Parsing")
	while true do
		local Token = Parsing:GetNextToken()
		if Token.Type == "EndOfFile" then
			break
		end
		if Token.Type == "Whitespace" or Token.Type == "Comment" then
			ParsingSeenTrivia = true
		end
	end
	Check("Parsing skips trivia", not ParsingSeenTrivia)
end

-- 3. Type aliases do not mutate the referenced declaration
do
	local Ast = Parse("type A = u8(0..10)\ntype B = A(5..6)\nstruct S { F: B, G: A }")
	local Declarations = Ast.Value.Declarations
	local A = FindDeclaration(Declarations, "A") :: any
	local B = FindDeclaration(Declarations, "B") :: any
	local S = FindDeclaration(Declarations, "S") :: any
	Check("Alias keeps original range", A ~= nil and A.Value.Range.Min == 0 and A.Value.Range.Max == 10)
	Check("Alias gets narrowed range", B ~= nil and B.Value.Range.Min == 5 and B.Value.Range.Max == 6)
	local F, G
	for _, Field: any in (S :: any).Value.Values do
		if Field.Name == "F" then
			F = Field
		elseif Field.Name == "G" then
			G = Field
		end
	end
	Check(
		"Alias use sites keep ranges",
		F ~= nil and G ~= nil and F.Value.Range.Max == 6 and G.Value.Range.Max == 10
	)
end

-- 4. Component aliases are isolated as well
do
	local Ast = Parse("type V = vector<i16>\ntype W = V\ntype C = CFrame<f32, f16>")
	local V = FindDeclaration(Ast.Value.Declarations, "V") :: any
	local W = FindDeclaration(Ast.Value.Declarations, "W") :: any
	Check(
		"Component alias preserved",
		V ~= nil and W ~= nil and #V.Value.Components == 1 and #W.Value.Components == 1
	)
end

-- 5. Option lists longer than the known option count still parse
do
	local Lines = { 'option ClientOutput = "c"', 'option ServerOutput = "s"' }
	for Index = 1, 14 do
		table.insert(Lines, `option SyncValidation = {Index % 2 == 0}`)
	end
	table.insert(Lines, "type A = u8")
	local Ok, Ast = pcall(Parse, table.concat(Lines, "\n"))
	Check("Long option lists parse", Ok == true)
	if Ok then
		Check("Last option wins", (Ast :: Parser.Body).Value.Options.SyncValidation == true)
	end
end

-- 6. Unknown options still error
do
	local Ok = pcall(Parse, 'option ClientOutput = "c"\noption Nope = true\ntype A = u8')
	Check("Unknown option errors", Ok == false)
end

-- 7. Error slices spanning empty lines do not crash
do
	local Ok, Slices = pcall(function()
		return Error.new(1001, "a\n\nb", "message"):Slice({ Start = 1, End = 4 })
	end)
	Check("Slice over empty lines", Ok == true and #Slices >= 2)
	local OkLabel = pcall(function()
		Error.new(1001, "a\n\nb", "message"):Primary({ Start = 1, End = 4 }, "here"):Emit()
	end)
	Check("Label over empty lines errors normally", OkLabel == false)
end

-- 8. Generic instantiation substitutes every placeholder
do
	local Ast = Parse("map GenericMap<K, V> = {[K]: V}\nstruct S { M: GenericMap<string, u8> }")
	local S = FindDeclaration(Ast.Value.Declarations, "S") :: any
	local M = S ~= nil and S.Value.Values[1] or nil
	Check("Generic map instantiates", M ~= nil and M.Type == "Map")
	if M ~= nil then
		Check("Generic key substituted", M.Value.Values[1].Type == "Primitive")
		Check("Generic value substituted", M.Value.Values[2].Type == "Primitive")
	end
	Check("No leftover generics", not ContainsGeneric(Ast.Value.Declarations))
end

-- 9. Struct merge of a generic instantiation
do
	local Ast = Parse("struct a { foo: u8 }\nstruct c<A, B> { x: A, y: B }\nstruct d { ..a, ..c<u8, string> }")
	local D = FindDeclaration(Ast.Value.Declarations, "d") :: any
	local Fields: { [string]: boolean } = {}
	if D ~= nil then
		for _, Field: any in D.Value.Values do
			Fields[Field.Name] = true
		end
	end
	Check("Merged generic fields present", Fields.foo == true and Fields.x == true and Fields.y == true)
	Check("Merged tree has no generics", not ContainsGeneric(D))
end

-- 10. Real fixture with imports and nested generics parses
do
	local Base = fs.isDir("./Sources") and "./Sources/" or "test/Sources/"
	local Source = fs.readFile(`{Base}Import.blink`)
	local Ok, Ast = pcall(function()
		return Parser.new(Base, "Import.blink"):Parse(Source)
	end)
	Check("Import.blink parses", Ok == true)
	if Ok then
		Check("Import yields declarations", #(Ast :: Parser.Body).Value.Declarations > 0)
	end
end

-- 11. Duplicate generic parameters are rejected
do
	local Ok = pcall(Parse, 'option ClientOutput = "c"\noption ServerOutput = "s"\nmap M<T, T> = {[T]: T}')
	Check("Duplicate generic params error", Ok == false)
end

-- 12. Single-quoted imports resolve like double-quoted ones
do
	local Base = fs.isDir("./Sources") and "./Sources/" or "test/Sources/"
	local Ok, Ast = pcall(function()
		return Parser.new(Base, "single.blink"):Parse(`import './Indexers'\ntype A = u8`)
	end)
	Check("Single-quoted import parses", Ok == true)
	if Ok then
		Check("Single-quoted import yields declarations", #(Ast :: Parser.Body).Value.Declarations > 0)
	end
end

-- 13. Bare output filenames resolve next to the definition file, never to root
do
	local Compile = require("../src/CLI/Utility/Compile")
	local Dir = "./.tmp-reg/"
	pcall(function()
		fs.removeDir(Dir)
	end)
	fs.writeDir(Dir)
	fs.writeFile(
		`{Dir}Reg.blink`,
		'option ClientOutput = "RegClient"\noption ServerOutput = "RegServer"\ntype A = u8'
	)
	local Ok, Err = pcall(function()
		Compile.Compile(`{Dir}Reg.blink`, {
			Debug = false,
			Silent = true,
			Compact = false,
			YesToEverything = true,
			OutputAbstractSyntaxTree = false,
		})
	end)
	Check("Bare output names compile", Ok == true, not Ok and tostring(Err) or nil)
	Check("Client written beside definition", fs.isFile(`{Dir}RegClient.luau`))
	Check("Server written beside definition", fs.isFile(`{Dir}RegServer.luau`))
	pcall(function()
		fs.removeDir(Dir)
	end)
end

-- 14. Path classification covers UNC roots and drive letters
do
	local PathParser = require("../src/Modules/Path")
	Check("UNC path is absolute", PathParser.PathType("\\\\server\\share\\file.blink") == "absolute")
	Check("Drive path is absolute", PathParser.PathType("C:/dir/file.blink") == "absolute")
	Check("Slash path is absolute", PathParser.PathType("/dir/file.blink") == "absolute")
	Check("Bare file is relative", PathParser.PathType("file.blink") == "relative")
	Check("Dotted relative stays relative", PathParser.PathType("./dir/file.blink") == "relative")
end

-- 15. Every error code resolves to a name; unknown codes still error
do
	local Codes = {
		Error.LexerUnexpectedToken,
		Error.ParserUnexpectedEndOfFile,
		Error.ParserUnexpectedToken,
		Error.ParserUnknownOption,
		Error.ParserUnexpectedSymbol,
		Error.ParserExpectedExtraToken,
		Error.AnalyzeReferenceInvalidType,
		Error.AnalyzeInvalidOptionalType,
		Error.AnalyzeNestedMap,
		Error.AnalyzeDuplicateField,
		Error.AnalyzeReservedIdentifier,
		Error.AnalyzeNestedScope,
		Error.AnalyzeUnknownReference,
		Error.AnalyzeInvalidRangeType,
		Error.AnalyzeInvalidRange,
		Error.AnalyzeDuplicateDeclaration,
		Error.AnalyzeDuplicateTypeGeneric,
		Error.AnalyzeInvalidGenerics,
		Error.AnalyzeInvalidExport,
		Error.AnalyzeUnknownImport,
		Error.AnalyzeErrorWhileImporting,
		Error.AnalyzeOptionAfterStart,
	}
	local AllNamed = true
	for _, Code in Codes do
		local Ok, Name = pcall(Error.GetNameFromCode, Code)
		if not Ok or type(Name) ~= "string" or #Name == 0 then
			AllNamed = false
		end
	end
	Check("All error codes resolve", AllNamed)
	Check("Unknown error code errors", pcall(Error.GetNameFromCode, -1) == false)
end

-- 16. Malformed ranges and blocks are rejected at parse time
do
	Rejects("Inverted integer range", 'option ClientOutput = "a"\ntype A = u8(10..1)')
	Rejects("Inverted float range", 'option ClientOutput = "a"\ntype A = f64(1.5..-1.5)')

	local Ok, Ast = pcall(Parse, 'option ClientOutput = "a"\ntype A = u8(0..10)')
	Check("Ordered range accepted", Ok == true)
	if Ok then
		local Declaration = FindDeclaration((Ast :: Parser.Body).Value.Declarations, "A")
		local Range = (Declaration :: any).Value.Range
		Check("Ordered range kept verbatim", Range ~= nil and Range.Min == 0 and Range.Max == 10)
	end
end

-- 17. A stray closing brace no longer swallows the rest of the file
do
	Rejects("Stray top-level closing brace", 'option ClientOutput = "a"\ntype A = u8\n}\ntype B = u8')

	local Ok, Ast = pcall(Parse, 'option ClientOutput = "a"\nscope Foo {\ntype A = u8\n}\ntype B = u8')
	Check("Closed scope accepted", Ok == true)
	if Ok then
		local Declarations = (Ast :: Parser.Body).Value.Declarations
		Check("Declarations after a scope survive", FindDeclaration(Declarations, "B") ~= nil)
	end
end

-- 18. Unclosed blocks are reported instead of being accepted
do
	Rejects("Unclosed scope", 'option ClientOutput = "a"\nscope Foo {\ntype A = u8')
	Rejects("Unclosed struct", 'option ClientOutput = "a"\nstruct Foo {\nA: u8')
	Rejects("Unterminated block comment", 'option ClientOutput = "a"\n--[[[\ntype A = u8')

	local Ok = pcall(Parse, 'option ClientOutput = "a"\n--[[ ok ]]\ntype A = u8\n-- trailing')
	Check("Closed and line comments accepted", Ok == true)
end

-- 19. Reserved words are rejected as declaration names, not emitted as Luau
do
	Rejects("Event named after a keyword", 'option ClientOutput = "a"\nevent end {\n}')
	Rejects("Function named after a keyword", 'option ClientOutput = "a"\nfunction type()')
	Rejects("Struct named after a keyword", 'option ClientOutput = "a"\nstruct local {\nA: u8\n}')

	local Ok = pcall(
		Parse,
		'option ClientOutput = "a"\nevent Fire {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync\n}'
	)
	Check("Ordinary event name accepted", Ok == true)
end

-- 20. Keyword and underscore struct fields survive code generation
do
	local Tree = Parse('option ClientOutput = "a"\noption ServerOutput = "b"\nstruct Weird {\n["end"]: u8,\n["_local"]: u8,\n["normal"]: u8\n}\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: Weird\n}')
	local Server = Generator.Generate("Server", Tree)
	local Client = Generator.Generate("Client", Tree)

	Check("Keyword field emitted as a bracketed key", string.find(Server, `["end"]`, 1, true) ~= nil)
	Check("Keyword field never emitted after a dot", string.find(Server, ".end", 1, true) == nil)
	Check("Underscore field emitted verbatim", string.find(Server, "_local", 1, true) ~= nil)
	Check("Ordinary field emitted after a dot", string.find(Server, ".normal", 1, true) ~= nil)
	Check("Generator wraps serializer writes", string.find(Server, "Serialize(", 1, true) ~= nil)
	Check("Generator wraps export reads", string.find(Server, "ExportRead(", 1, true) ~= nil)
	Check("Generator wraps export writes", string.find(Server, "ExportWrite(", 1, true) ~= nil)

	local function Identity(Code: string): (number?, number?)
		local Version = string.match(Code, "local PROTOCOL_VERSION = (%d+)")
		local Schema = string.match(Code, "local SCHEMA_ID = (%d+)")
		return (Version and tonumber(Version)), (Schema and tonumber(Schema))
	end

	local ServerVersion, ServerSchema = Identity(Server)
	local ClientVersion, ClientSchema = Identity(Client)
	Check("Both halves declare the same protocol version", ServerVersion ~= nil and ServerVersion == ClientVersion)
	Check("Both halves declare the same schema id", ServerSchema ~= nil and ServerSchema == ClientSchema)

	local Other = Generator.Generate("Server", Parse('option ClientOutput = "a"\noption ServerOutput = "b"\nstruct Different {\nA: u8\n}\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: Different\n}'))
	local _, OtherSchema = Identity(Other)
	Check("A different schema yields a different id", OtherSchema ~= nil and OtherSchema ~= ServerSchema)
end

-- 20b. Export tables close over locals in a per-export closure, because table
-- fields cannot see each other while their own table is being constructed.
-- (A wrapper referencing a field name resolves to a nil global, so every
-- export call would fail at runtime.)
do
	local Tree = Parse('option ClientOutput = "a"\noption ServerOutput = "b"\nexport type E = u8\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: E\n}')
	local ExportServer = Generator.Generate("Server", Tree)
	Check("Export bodies close over locals in a closure", string.find(ExportServer, "= (function()", 1, true) ~= nil)
	Check("Export closures return their table", string.find(ExportServer, "end)(),", 1, true) ~= nil)
	Check("Export inner functions are locals", string.find(ExportServer, "local function E_Read", 1, true) ~= nil)
end

-- 21. Shared identifier and string policy
do
	Check("Escape leaves plain text alone", StringParser.Escape("abc") == "abc")
	Check("Escape quotes", StringParser.Escape('a"b') == 'a\\"b')
	Check("Escape backslashes", StringParser.Escape("a\\b") == "a\\\\b")
	Check("Escape newlines", StringParser.Escape("a\nb") == "a\\nb")
	Check("Escape tabs", StringParser.Escape("a\tb") == "a\\tb")

	Check("Plain identifier is valid", StringParser.IsValidIdentifier("Foo"))
	Check("Leading underscore is valid", StringParser.IsValidIdentifier("_Foo"))
	Check("Trailing underscore is valid", StringParser.IsValidIdentifier("Foo_"))
	Check("Leading digit is invalid", not StringParser.IsValidIdentifier("1Foo"))
	Check("Keyword identifier is invalid", not StringParser.IsValidIdentifier("end"))
	Check("Capitalised keyword is still valid", StringParser.IsValidIdentifier("End"))

	local Util = require("../src/Generator/Util")
	Check("FormatKey brackets a keyword", Util.FormatKey("type") == '["type"]')
	Check("FormatIndex brackets a keyword", Util.FormatIndex("end") == '["end"]')
	Check("FormatIndex keeps an underscore-prefixed name dotted", Util.FormatIndex("_local") == "._local")
	Check("FormatIndex keeps an ordinary name dotted", Util.FormatIndex("normal") == ".normal")
end

-- 22. Wire-level guards are emitted into generated code
local function Generate(Source: string, Context: "Server" | "Client"): string
	return Generator.Generate(Context, Parse(Source))
end

do
	local Ranged = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: u8(0..10)\n}',
		"Server"
	)
	Check("Integer writes reject fractions", string.find(Ranged, "% 1 ~= 0", 1, true) ~= nil)
	Check("Ranged writes emit both bounds in one guard", string.find(Ranged, "< 0 or", 1, true) ~= nil)
	Check("Ranged writes emit the upper bound", string.find(Ranged, "> 10 then", 1, true) ~= nil)

	local Bare = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: u8\n}',
		"Server"
	)
	Check(
		"Unranged u8 still guards its representable range",
		string.find(Bare, "an integer between 0 and 255", 1, true) ~= nil
	)

	local Text = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: string\n}',
		"Server"
	)
	Check("Variable strings check their length prefix", string.find(Text, "if Length > 65535 then error", 1, true) ~= nil)

	local Mapped = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: map { [string]: u8 }\n}',
		"Server"
	)
	Check(
		"Maps guard their entry count",
		string.find(Mapped, "A map cannot hold more than 65535 entries", 1, true) ~= nil
	)

	local Half = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: f16\n}',
		"Client"
	)
	Check("f16 masks its exponent field", string.find(Half, "f16Exponent = f16Encoded // 0x400 % 0x20", 1, true) ~= nil)
	Check("f16 decodes infinities by mantissa", string.find(Half, "f16Sign * math.huge", 1, true) ~= nil)
	Check("f16 decodes subnormals via ldexp", string.find(Half, "math.ldexp(f16Mantissa / 0x400, -14)", 1, true) ~= nil)

	local Optionals = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: u8?[1..3]\n}',
		"Client"
	)
	Check("Variable arrays assign by index", string.find(Optionals, "Value[Index] =", 1, true) ~= nil)
	Check(
		"Array results are never compacted by table.insert",
		string.find(Optionals, "table.insert(Value", 1, true) == nil
	)

	-- The write side (sender's module) carries the length logic.
	local OptionalsWrite = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: u8?[1..3]\n}',
		"Server"
	)
	Check(
		"Optional variable arrays scan for their true length",
		string.find(OptionalsWrite, "SparseLength_", 1, true) ~= nil
	)

	local Fixed = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: (u8?)[3]\n}',
		"Server"
	)
	Check("Fixed arrays reject over-long input", string.find(Fixed, "to hold at most 3 entries", 1, true) ~= nil)

	local Dense = Generate(
		'option ClientOutput = "a"\noption ServerOutput = "b"\nevent Ping {\nFrom: Server,\nType: Reliable,\nCall: SingleAsync,\nData: u8[1..3]\n}',
		"Server"
	)
	Check("Dense variable arrays keep the cheap length", string.find(Dense, "SparseLength_", 1, true) == nil)
end

-- 23. A schema that cannot fit in a single-byte id is rejected at compile time
do
	local Parts = { 'option ClientOutput = "a"', 'option ServerOutput = "b"' }
	for Index = 1, 300 do
		table.insert(Parts, "event Ping" .. Index .. " {From: Server, Type: Reliable, Call: SingleAsync}")
	end

	local Source = table.concat(Parts, "\n")
	local Ok = pcall(function()
		Generator.Generate("Server", Parse(Source))
	end)
	Check("Too many events for a byte id is rejected", Ok == false)
end

print(`\n{Passed} passed, {Failed} failed.`)
if Failed > 0 then
	process.exit(1)
end
