--!strict
--!native
--!optimize 2

--- Shared string/identifier policy for anything that reaches generated code.
--- Both the parser (to reject bad names with a real diagnostic) and the
--- generator (to quote them safely) must agree, so this lives in one place.

local String = {}

---- Constants ----

-- Words the generated Luau cannot use as a bare identifier. `export`, `type`
-- and `typeof` are contextual keywords in Luau, but generated modules emit
-- `export type X = ...` headers, so treating them as reserved is safer than
-- letting the target compiler produce the diagnostic.
local RESERVED: { [string]: true } = {
	["and"] = true,
	["break"] = true,
	["continue"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["export"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["type"] = true,
	["typeof"] = true,
	["until"] = true,
	["while"] = true,
}

---- Functions ----

--- Returns whether `Identifier` is a reserved word in generated Luau.
function String.IsReserved(Identifier: string): boolean
	return RESERVED[Identifier] == true
end

--- Returns whether `Identifier` can be emitted verbatim after a `.` in Luau.
function String.IsValidIdentifier(Identifier: string): boolean
	if RESERVED[Identifier] then
		return false
	end

	-- Underscores are legal in Luau identifiers, including leading ones.
	return Identifier:match("^[%a_][%w_]*$") ~= nil
end

--- Escapes `Value` so it can be placed inside a double-quoted Luau literal.
function String.Escape(Value: string): string
	return string.gsub(Value, "[%c\\\"%z\1-\31]", function(Character)
		if Character == "\\" then
			return "\\\\"
		elseif Character == "\"" then
			return "\\\""
		elseif Character == "\n" then
			return "\\n"
		elseif Character == "\r" then
			return "\\r"
		elseif Character == "\t" then
			return "\\t"
		end

		return string.format("\\%d", string.byte(Character))
	end)
end

return String