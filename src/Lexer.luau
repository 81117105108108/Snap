--!strict
--!native
--!optimize 2
-- High-performance, single-pass character-dispatch lexer for IDL & schema syntax.
-- Zero closure churn per token, deterministic memory usage, accurate source spans.

local Error = require("./Modules/Error")
local Settings = require("./Settings")

--- All token kinds that can be produced by the lexer.
--- Includes punctuation, literals, identifiers, keywords, trivia, and EOF.
export type Types =
	| "Comma"
	| "OpenParentheses"
	| "CloseParentheses"
	| "OpenBraces"
	| "CloseBraces"
	| "OpenBrackets"
	| "CloseBrackets"
	| "Merge"
	| "String"
	| "Boolean"
	| "Number"
	| "Array"
	| "Range"
	| "Optional"
	| "Class"
	| "Component"
	| "OpenChevrons"
	| "CloseChevrons"
	| "Assign"
	| "FieldAssign"
	| "Keyword"
	| "Primitive"
	| "Identifier"
	| "Import"
	| "As"
	| "Whitespace"
	| "Comment"
	| "Unknown"
	| "EndOfFile"

--- Reserved declaration keywords recognized by the lexer.
export type Keywords = "type" | "enum" | "struct" | "event" | "function"
--- Controls whether the lexer produces parser-oriented values or preserves source text for syntax highlighting.
export type Mode = "Parsing" | "Highlighting"

--- Represents a single lexical token and its inclusive source span.
--- `Value` depends on the lexer mode: highlighting preserves source text where appropriate,
--- while parsing may normalize values such as booleans and quoted strings.
export type Token = {
	Type: Types,
	Value: any, -- string when highlighting; unquoted string or boolean when parsing
	Start: number,
	End: number,
	Line: number?,
	Column: number?,
}

-- ASCII Byte Constants (eliminates string comparisons in hot loops)
local BYTE_TAB = 9
local BYTE_LF = 10
local BYTE_CR = 13
local BYTE_SPACE = 32
local BYTE_QUOTE_D = 34 -- "
local BYTE_QUOTE_S = 39 -- '
local BYTE_LPAREN = 40 -- (
local BYTE_RPAREN = 41 -- )
local BYTE_COMMA = 44 -- ,
local BYTE_MINUS = 45 -- -
local BYTE_DOT = 46 -- .
local BYTE_COLON = 58 -- :
local BYTE_LT = 60 -- <
local BYTE_EQUAL = 61 -- =
local BYTE_GT = 62 -- >
local BYTE_QUESTION = 63 -- ?
local BYTE_LBRACKET = 91 -- [
local BYTE_BACKSLASH = 92 -- \
local BYTE_RBRACKET = 93 -- ]
local BYTE_UNDERSCORE = 95 -- _
local BYTE_LBRACE = 123 -- {
local BYTE_RBRACE = 125 -- }

local BYTE_0 = 48
local BYTE_9 = 57
local BYTE_A_UPPER = 65
local BYTE_Z_UPPER = 90
local BYTE_A_LOWER = 97
local BYTE_Z_LOWER = 122

-- Defensive lookup supporting both correct spelling and the Settings.Primtives typo
local KEYWORDS_MAP: { [string]: boolean } = Settings.Keywords or {}
local PRIMITIVES_MAP: { [string]: boolean } = Settings.Primitives or (Settings :: any).Primtives or {}

local BOOLEANS_MAP: { [string]: boolean } = {
	["true"] = true,
	["false"] = true,
}

--- High-performance single-pass lexer for the project IDL/schema syntax.
---
--- The lexer supports two modes:
--- - `Parsing`: skips trivia and returns normalized token values.
--- - `Highlighting`: emits whitespace/comments and preserves display-oriented token text.
local Lexer = {}
Lexer.__index = Lexer

--- Mutable lexer state.
--- Instances retain the source string, source length, active mode, and current byte cursor.
export type Lexer = typeof(setmetatable(
	{} :: {
		Mode: Mode,
		Size: number,
		Source: string,
		Cursor: number,
	},
	Lexer
))

--- Returns whether an ASCII byte can begin an identifier.
--- Valid starting characters are `A-Z`, `a-z`, and `_`.
local function isAlphaOrUnderscore(byte: number): boolean
	return (byte >= BYTE_A_LOWER and byte <= BYTE_Z_LOWER)
		or (byte >= BYTE_A_UPPER and byte <= BYTE_Z_UPPER)
		or byte == BYTE_UNDERSCORE
end

--- Returns whether an ASCII byte can continue an identifier.
--- Valid continuation characters are letters, digits, and `_`.
local function isAlphaNumericOrUnderscore(byte: number): boolean
	return (byte >= BYTE_A_LOWER and byte <= BYTE_Z_LOWER)
		or (byte >= BYTE_A_UPPER and byte <= BYTE_Z_UPPER)
		or (byte >= BYTE_0 and byte <= BYTE_9)
		or byte == BYTE_UNDERSCORE
end

--- Returns whether an ASCII byte is a decimal digit (`0-9`).
local function isDigit(byte: number): boolean
	return byte >= BYTE_0 and byte <= BYTE_9
end

--- Emits a lexer diagnostic when the error subsystem is available.
--- This helper is intentionally tolerant of a missing or partially initialized error module.
local function emitUnexpectedError(source: string, startPos: number, endPos: number, message: string)
	if Error and Error.new and Error.LexerUnexpectedToken then
		Error.new(Error.LexerUnexpectedToken, source, message)
			:Primary({ Start = startPos, End = endPos }, message)
			:Emit()
	end
end

--- Creates a new lexer.
--- @param Source Optional source text. Defaults to an empty string.
--- @param Mode Optional lexer mode. Defaults to `"Parsing"`.
--- @return A new lexer positioned at the first byte of the source.
function Lexer.new(Source: string?, Mode: Mode?): Lexer
	local src = Source or ""
	return setmetatable({
		Size = #src,
		Mode = Mode or "Parsing",
		Source = src,
		Cursor = 1,
	}, Lexer)
end

--- Replaces the current source and resets the lexer to the beginning.
--- @param Source New source text to tokenize.
function Lexer.Initialize(self: Lexer, Source: string)
	self.Source = Source
	self.Size = #Source
	self.Cursor = 1
end

--- Resets the current cursor without changing the source.
--- @param Cursor Optional 1-based byte position. Defaults to `1`.
function Lexer.Reset(self: Lexer, Cursor: number?)
	self.Cursor = Cursor or 1
end

--- Converts a 1-based byte position into a 1-based line and column.
--- Positions are clamped to the valid source range plus the logical EOF position.
--- @param Position 1-based byte position in the current source.
--- @return The corresponding line number and column number.
function Lexer.GetLineAndColumn(self: Lexer, Position: number): (number, number)
	local line = 1
	local lineStart = 1
	local source = self.Source
	local target = math.clamp(Position, 1, self.Size + 1)

	for i = 1, target - 1 do
		if string.byte(source, i) == BYTE_LF then
			line += 1
			lineStart = i + 1
		end
	end

	return line, (target - lineStart) + 1
end

--- Returns the next token without advancing `self.Cursor`.
--- @return The token that would be returned by `GetNextToken`.
function Lexer.PeekToken(self: Lexer): Token
	return self:GetNextToken(true)
end

--- Tokenizes from the current cursor through EOF.
--- The returned array always ends with an `EndOfFile` token.
--- @return All tokens from the current position through EOF.
function Lexer.Tokenize(self: Lexer): { Token }
	local tokens: { Token } = {}
	while true do
		local token = self:GetNextToken(false)
		table.insert(tokens, token)
		if token.Type == "EndOfFile" then
			break
		end
	end
	return tokens
end

--- Scans and returns the next token.
---
--- In parsing mode, whitespace and comments are skipped. In highlighting mode,
--- they are emitted as tokens. The scanner uses an iterative dispatch loop to
--- avoid recursive trivia skipping and unnecessary closure allocation.
---
--- @param DontAdvanceCursor If true, leaves `self.Cursor` unchanged.
--- @param StartAt Optional 1-based byte position to scan from instead of `self.Cursor`.
--- @return The next token, or `EndOfFile` when no source remains.
function Lexer.GetNextToken(self: Lexer, DontAdvanceCursor: boolean?, StartAt: number?): Token
	local source = self.Source
	local size = self.Size
	local isHighlighting = (self.Mode == "Highlighting")
	local cursor = StartAt or self.Cursor

	-- Loop replaces recursive GetNextToken calls: skips whitespace/comments in O(1) stack space
	while cursor <= size do
		local byte = string.byte(source, cursor)
		if byte == BYTE_SPACE or byte == BYTE_TAB or byte == BYTE_LF or byte == BYTE_CR then
			local _, wsEnd = string.find(source, "^[ \t\r\n]+", cursor)
			wsEnd = wsEnd or cursor

			if isHighlighting then
				local text = string.sub(source, cursor, wsEnd)
				local token: Token = {
					Type = "Whitespace",
					Value = text,
					Start = cursor,
					End = wsEnd,
				}
				if not DontAdvanceCursor then
					self.Cursor = wsEnd + 1
				end
				return token
			else
				cursor = wsEnd + 1
				if not DontAdvanceCursor then
					self.Cursor = cursor
				end
				continue
			end
		end

		if byte == BYTE_MINUS and cursor < size and string.byte(source, cursor + 1) == BYTE_MINUS then
			local commentStart = cursor
			local commentEnd: number

			-- Check for block comment: --[(=*)[
			local eq = string.match(source, "^%-%-%[(=*)%[", cursor)
			if eq ~= nil then
				local closePattern = "]" .. eq .. "]"
				local _, closeEnd = string.find(source, closePattern, cursor + 4 + #eq, true)
				if closeEnd ~= nil then
					commentEnd = closeEnd
				else
					commentEnd = size -- Unclosed block comment spans to EOF
				end
			else
				-- Single line comment: scan to newline or EOF
				local _, newlinePos = string.find(source, "\n", cursor + 2, true)
				if newlinePos ~= nil then
					commentEnd = newlinePos
				else
					commentEnd = size
				end
			end

			if isHighlighting then
				local text = string.sub(source, commentStart, commentEnd)
				local token: Token = {
					Type = "Comment",
					Value = text,
					Start = commentStart,
					End = commentEnd,
				}
				if not DontAdvanceCursor then
					self.Cursor = commentEnd + 1
				end
				return token
			else
				cursor = commentEnd + 1
				if not DontAdvanceCursor then
					self.Cursor = cursor
				end
				continue
			end
		end

		if byte == BYTE_QUOTE_D or byte == BYTE_QUOTE_S then
			local quoteByte = byte
			local strStart = cursor
			local i = cursor + 1
			local closed = false

			while i <= size do
				local b = string.byte(source, i)
				if b == BYTE_BACKSLASH then
					i += 2 -- Skip escaped character
				elseif b == quoteByte then
					closed = true
					break
				elseif b == BYTE_LF then
					-- Stop at newline to avoid swallowing the file on unclosed strings
					break
				else
					i += 1
				end
			end

			local strEnd = if closed then i else math.min(i, size)
			local rawText = string.sub(source, strStart, strEnd)
			local innerText = if closed
				then string.sub(source, strStart + 1, strEnd - 1)
				else string.sub(source, strStart + 1, strEnd)

			if not closed and not isHighlighting then
				emitUnexpectedError(source, strStart, strEnd, "Unclosed string literal")
			end

			local token: Token = {
				Type = "String",
				Value = if isHighlighting then rawText else innerText,
				Start = strStart,
				End = strEnd,
			}
			if not DontAdvanceCursor then
				self.Cursor = strEnd + 1
			end
			return token
		end

		if byte == BYTE_EQUAL then
			local token: Token = { Type = "Assign", Value = "=", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_COLON then
			local token: Token = { Type = "FieldAssign", Value = ":", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_LBRACE then
			local token: Token = { Type = "OpenBraces", Value = "{", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_RBRACE then
			local token: Token = { Type = "CloseBraces", Value = "}", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_LT then
			local token: Token = { Type = "OpenChevrons", Value = "<", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_GT then
			local token: Token = { Type = "CloseChevrons", Value = ">", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_COMMA then
			local token: Token = { Type = "Comma", Value = ",", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_QUESTION then
			local token: Token = { Type = "Optional", Value = "?", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_RPAREN then
			local token: Token = { Type = "CloseParentheses", Value = ")", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		elseif byte == BYTE_RBRACKET then
			local token: Token = { Type = "CloseBrackets", Value = "]", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		end

		if byte == BYTE_DOT then
			if cursor < size and string.byte(source, cursor + 1) == BYTE_DOT then
				local token: Token = { Type = "Merge", Value = "..", Start = cursor, End = cursor + 1 }
				if not DontAdvanceCursor then
					self.Cursor = cursor + 2
				end
				return token
			elseif cursor < size and isDigit(string.byte(source, cursor + 1)) then
				local match = string.match(source, "^%.%d+[eE][%+%-]?%d+", cursor)
					or string.match(source, "^%.%d+", cursor)
				if match then
					local tokEnd = cursor + #match - 1
					local token: Token = { Type = "Number", Value = match, Start = cursor, End = tokEnd }
					if not DontAdvanceCursor then
						self.Cursor = tokEnd + 1
					end
					return token
				end
			end
		end

		if byte == BYTE_LPAREN then
			-- Most specific range constraints checked first
			local rangeMatch = string.match(source, "^%(%-?%d*%.?%d+%.%.%-?%d*%.?%d+%)", cursor) -- (1..10)
				or string.match(source, "^%(%-?%d*%.?%d+%.%.%)", cursor) -- (1..)
				or string.match(source, "^%(%.%.%-?%d*%.?%d+%)", cursor) -- (..10)
				or string.match(source, "^%(%-?%d*%.?%d+%)", cursor) -- (10)

			if rangeMatch then
				local tokEnd = cursor + #rangeMatch - 1
				local token: Token = { Type = "Range", Value = rangeMatch, Start = cursor, End = tokEnd }
				if not DontAdvanceCursor then
					self.Cursor = tokEnd + 1
				end
				return token
			end

			local classMatch = string.match(source, "^%(%a[%w_]*%)", cursor)
			if classMatch then
				local tokEnd = cursor + #classMatch - 1
				local token: Token = { Type = "Class", Value = classMatch, Start = cursor, End = tokEnd }
				if not DontAdvanceCursor then
					self.Cursor = tokEnd + 1
				end
				return token
			end

			local token: Token = { Type = "OpenParentheses", Value = "(", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		end

		if byte == BYTE_LBRACKET then
			local arrayMatch = string.match(source, "^%[%]", cursor) -- []
				or string.match(source, "^%[%-?%d*%.?%d+%.%.%-?%d*%.?%d+%]", cursor) -- [1..10]
				or string.match(source, "^%[%-?%d*%.?%d+%.%.%]", cursor) -- [1..]
				or string.match(source, "^%[%.%.%-?%d*%.?%d+%]", cursor) -- [..10]
				or string.match(source, "^%[%-?%d*%.?%d+%]", cursor) -- [10]

			if arrayMatch then
				local tokEnd = cursor + #arrayMatch - 1
				local token: Token = { Type = "Array", Value = arrayMatch, Start = cursor, End = tokEnd }
				if not DontAdvanceCursor then
					self.Cursor = tokEnd + 1
				end
				return token
			end

			local token: Token = { Type = "OpenBrackets", Value = "[", Start = cursor, End = cursor }
			if not DontAdvanceCursor then
				self.Cursor = cursor + 1
			end
			return token
		end

		-----------------------------------------------------------------------
		-- 8. Number Literals (Standalone integers, floats, hex, negatives)
		-----------------------------------------------------------------------
		local isNegativeNumber = (byte == BYTE_MINUS)
			and (cursor < size)
			and (isDigit(string.byte(source, cursor + 1)) or (string.byte(source, cursor + 1) == BYTE_DOT and cursor + 2 <= size and isDigit(string.byte(source, cursor + 2))))

		if isDigit(byte) or isNegativeNumber then
			-- Hex check (0x... or -0x...)
			local numMatch = string.match(source, "^%-?0[xX][%da-fA-F]+", cursor)
				or string.match(source, "^%-?%d*%.?%d+[eE][%+%-]?%d+", cursor)
				or string.match(source, "^%-?%d*%.?%d+", cursor)

			if numMatch then
				local tokEnd = cursor + #numMatch - 1
				local token: Token = { Type = "Number", Value = numMatch, Start = cursor, End = tokEnd }
				if not DontAdvanceCursor then
					self.Cursor = tokEnd + 1
				end
				return token
			end
		end

		if isAlphaOrUnderscore(byte) then
			local idStart = cursor
			local i = cursor + 1

			while i <= size and isAlphaNumericOrUnderscore(string.byte(source, i)) do
				i += 1
			end

			-- Check for qualified / dotted path segments: `MyModule.SubModule.Type`
			-- Specifically avoids swallowing `..` (Merge) or `.1` (Numbers)
			local isDotted = false
			while i + 1 <= size and string.byte(source, i) == BYTE_DOT and isAlphaOrUnderscore(string.byte(source, i + 1)) do
				isDotted = true
				i += 2
				while i <= size and isAlphaNumericOrUnderscore(string.byte(source, i)) do
					i += 1
				end
			end

			local text = string.sub(source, idStart, i - 1)
			local tokEnd = i - 1
			local tokenType: Types = "Identifier"
			local tokenValue: any = text

			if not isDotted then
				if text == "import" then
					tokenType = "Import"
				elseif text == "as" then
					tokenType = "As"
				elseif KEYWORDS_MAP[text] then
					tokenType = "Keyword"
				elseif PRIMITIVES_MAP[text] then
					tokenType = "Primitive"
				elseif BOOLEANS_MAP[text] then
					tokenType = "Boolean"
					tokenValue = if isHighlighting then text else (text == "true")
				end
			end

			local token: Token = {
				Type = tokenType,
				Value = tokenValue,
				Start = idStart,
				End = tokEnd,
			}
			if not DontAdvanceCursor then
				self.Cursor = tokEnd + 1
			end
			return token
		end

		if not isHighlighting then
			emitUnexpectedError(source, cursor, cursor, "Unexpected token")
		end

		local symbol = string.sub(source, cursor, cursor)
		local token: Token = {
			Type = "Unknown",
			Value = symbol,
			Start = cursor,
			End = cursor,
		}
		if not DontAdvanceCursor then
			self.Cursor = cursor + 1
		end
		return token
	end

	local eofPos = math.max(1, size)
	return {
		Type = "EndOfFile",
		Value = "",
		Start = eofPos,
		End = eofPos,
	}
end

return Lexer
