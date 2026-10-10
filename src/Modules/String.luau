--!strict
--!native
--!optimize 2

local RESERVED: { [string]: true } = table.freeze({
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
})

-- Precomputed lookup table for direct C-level replacement via `string.gsub`.
-- Covers backslash, double quote, ASCII control characters (0-31), and DEL (127).
local ESCAPE_MAP: { [string]: string } = {
	["\\"] = "\\\\",
	["\""] = "\\\"",
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\v"] = "\\v",
}

for byte = 0, 31 do
	local char = string.char(byte)
	if ESCAPE_MAP[char] == nil then
		-- Decimal escapes MUST be padded to 3 digits (`\%03d`). If emitted as `\%d`,
		-- an escape sequence like `\0` followed immediately by a digit (e.g. "5")
		-- produces `\05`, which the Luau lexer greedily parses as byte 5 (ENQ)
		-- rather than byte 0 followed by character "5".
		ESCAPE_MAP[char] = string.format("\\%03d", byte)
	end
end

ESCAPE_MAP[string.char(127)] = "\\127"
table.freeze(ESCAPE_MAP)

--- Returns whether `identifier` is a reserved word in generated Luau.
local function isReserved(identifier: string): boolean
	return RESERVED[identifier] == true
end

--- Returns whether `identifier` can be emitted verbatim after a `.` in Luau.
local function isValidIdentifier(identifier: string): boolean
	local firstByte = string.byte(identifier, 1)
	if firstByte == nil then
		return false
	end

	-- Fast path: Identifiers must start with [a-zA-Z_].
	-- ASCII ranges: [A-Z] = 65..90, [_] = 95, [a-z] = 97..122.
	-- Immediate rejection of numbers, punctuation, spaces, and UTF-8 bytes in 1 CPU check.
	local isStartValid = (firstByte >= 97 and firstByte <= 122)
		or (firstByte >= 65 and firstByte <= 90)
		or firstByte == 95

	if not isStartValid then
		return false
	end

	if RESERVED[identifier] then
		return false
	end

	-- Single-character identifiers starting with [a-zA-Z_] are guaranteed valid
	-- without running the pattern matcher (no reserved keyword has length 1).
	if #identifier == 1 then
		return true
	end

	-- `string.find` returns numeric registers.
	-- `string.match` allocates a brand-new substring on the heap for every match.
	return string.find(identifier, "^[%a_][%w_]*$") ~= nil
end

--- Escapes `value` so it can be safely placed inside a double-quoted Luau literal.
local function escape(value: string): string
	-- Passing `ESCAPE_MAP` directly into `string.gsub` executes entirely inside C/native code,
	-- eliminating Luau function closure allocations, string.byte calls, and string.format calls.
	-- Parentheses truncate the second return value (`count`) from `string.gsub`.
	return (string.gsub(value, "[\\\"%c%z]", ESCAPE_MAP))
end

--- Wraps and escapes `value` as a complete double-quoted Luau string literal.
local function quote(value: string): string
	return `"{escape(value)}"`
end

local String = table.freeze({
	RESERVED = RESERVED,
	IsReserved = isReserved,
	IsValidIdentifier = isValidIdentifier,
	Escape = escape,
	Quote = quote,
})

return String
