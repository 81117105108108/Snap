-- Non-interactive regression tests for the compiler front-end.
-- Covers defects fixed during the improvement pass; run from test/ via:
--   lune run Regression
-- No prompts, no Network folder, no Roblox environment required.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Error = require("../src/Modules/Error")
local Lexer = require("../src/Lexer")
local Parser = require("../src/Parser")
local Settings = require("../src/Settings")

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

print(`\n{Passed} passed, {Failed} failed.`)
if Failed > 0 then
	process.exit(1)
end
