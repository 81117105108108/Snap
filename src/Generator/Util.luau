local Parser = require("../Parser")
local StringParser = require("../Modules/String")

type Scope = Parser.Scope

local function GetScopePrefix(ReferenceScope: Scope?, Dots: boolean?, CurrentScope: Scope): string
	local Prefix = ""
	local WorkingScope: Scope? = ReferenceScope or CurrentScope
	while WorkingScope and WorkingScope.Name.Value ~= "" do
		Prefix = `{WorkingScope.Name.Value}{Dots and "." or "_"}` .. Prefix
		WorkingScope = WorkingScope.Parent
	end

	return Prefix
end

local function GetScopeIndent(CurrentScope: Scope): number
	return math.max(#string.split(GetScopePrefix(nil, true, CurrentScope), "."), 1)
end

local function GetTypesPath(Name: string, Write: boolean, CurrentScope: Scope): string
	return `SerdesFunctions.{GetScopePrefix(nil, false, CurrentScope)}{Write and "Write" or "Read"}{Name}`
end

local function GetExportName(Name: string, CurrentScope: Scope): string
	return `{GetScopePrefix(nil, false, CurrentScope)}{Name}`
end

local function GenerateEnumLiterals(Variants: { string }, Separator: string?): string
	local Literals = {}
	for _, EnumItem in Variants do
		table.insert(Literals, `"{StringParser.Escape(EnumItem)}"`)
	end
	return `{table.concat(Literals, Separator or " | ")}`
end

--- Returns whether `Identifier` can be emitted verbatim after a `.` in Luau.
local function IsValidIdentifier(Identifier: string): boolean
	return StringParser.IsValidIdentifier(Identifier)
end

local function FormatKey(Key: string): string
	if not IsValidIdentifier(Key) then
		return `["{StringParser.Escape(Key)}"]`
	end
	return Key
end

local function FormatIndex(Index: string): string
	if not IsValidIdentifier(Index) then
		return `["{StringParser.Escape(Index)}"]`
	end
	return `.{Index}`
end

return {
	GetPath = GetTypesPath,
	GetExportName = GetExportName,
	GetScopePrefix = GetScopePrefix,
	GetScopeIndent = GetScopeIndent,
	GenerateEnumLiterals = GenerateEnumLiterals,
	EscapeString = StringParser.Escape,
	IsValidIdentifier = IsValidIdentifier,
	FormatKey = FormatKey,
	FormatIndex = FormatIndex,
}
