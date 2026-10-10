--!strict
--!native
--!optimize 2

export type BranchType = "Conditional" | "Default"
export type EqualityOperator = "Not" | "Equals" | "Greater" | "Less" | "GreaterOrEquals" | "LessOrEquals"
export type Method = "Read" | "Allocate" | "None"

export type Operation = {
	Method: Method,
	Bytes: number,
	Counts: number,
	Variable: string?,
}

export type BlockData = {
	Unique: string,
	Parent: Block?,
	Indent: number,
	Cursor: number,
	Unsafe: boolean,
	Content: { string },
	Operation: Operation,
	Variables: { [string]: boolean },
	OperationOffset: number,
}

local DEFAULT_UNIQUE = "BLOCK_START"
local ARRAY_UNIQUE = "ARRAY_START"

local Operators: { [EqualityOperator]: string } = table.freeze({
	Not = "~=",
	Equals = "==",
	Greater = ">",
	Less = "<",
	GreaterOrEquals = ">=",
	LessOrEquals = "<=",
})

-- Precomputed indentation table eliminating `string.rep` heap allocations on every emitted line.
local INDENTS: { [number]: string } = table.freeze({
	[0] = "",
	[1] = "\t",
	[2] = "\t\t",
	[3] = "\t\t\t",
	[4] = "\t\t\t\t",
	[5] = "\t\t\t\t\t",
	[6] = "\t\t\t\t\t\t",
	[7] = "\t\t\t\t\t\t\t",
	[8] = "\t\t\t\t\t\t\t\t",
})

local function getIndent(level: number): string
	local cached = INDENTS[level]
	if cached ~= nil then
		return cached
	end
	return string.rep("\t", math.max(level, 0))
end

local Block = {}
Block.__index = Block

export type Block = typeof(setmetatable({} :: BlockData, Block))

function Block.new(Parent: Block?, Unique: string?): Block
	local Indent = if Parent then Parent.Indent + 1 else 1
	return setmetatable({
		Unique = Unique or DEFAULT_UNIQUE,
		Parent = Parent,
		Indent = Indent,
		Cursor = 1,
		Unsafe = false,
		Content = table.create(64),
		Operation = {
			Method = "None",
			Bytes = 0,
			Counts = 0,
			Variable = nil,
		},
		Variables = {},
		OperationOffset = 0,
	}, Block)
end

function Block.DisableOperationOptimisations(self: Block): Block
	self.Unsafe = true
	return self
end
-- Method alias for standard spelling conventions
Block.DisableOperationOptimizations = Block.DisableOperationOptimisations

function Block._operation(self: Block, Method: Method, Bytes: number): string
	local Operation = self.Operation
	if Operation.Method ~= "None" and Operation.Method ~= Method then
		error(`Block cannot execute both '{Operation.Method}' and '{Method}' within the same coalescing scope`)
	end

	if self.Unsafe then
		local Counts = Operation.Counts
		local Variable = `OFFSET_{Counts}`

		Operation.Counts += 1
		self:Line(`local {Variable} = {Method}({Bytes})`)

		return Variable
	end

	local Offset = Operation.Bytes
	Operation.Bytes += Bytes
	Operation.Method = Method

	if self.Unique ~= DEFAULT_UNIQUE then
		self:Comment(`{Method} {Bytes}`)
		local OperationOffset = `OPERATION_OFFSET_{self.OperationOffset}`
		self.OperationOffset += 1
		self:Line(`local {OperationOffset} = {self.Unique}`)
		self:Line(`{self.Unique} += {Bytes}`)
		return OperationOffset
	end

	return `{self.Unique} + {Offset}`
end

function Block.Read(self: Block, Bytes: number): string
	return self:_operation("Read", Bytes)
end

function Block.Allocate(self: Block, Bytes: number): string
	return self:_operation("Allocate", Bytes)
end

function Block._lineFront(self: Block, Text: string, Indent: number?): Block
	local indentLevel = Indent or self.Indent
	table.insert(self.Content, self.Cursor, `{getIndent(indentLevel)}{Text}\n`)
	return self
end

function Block._appendOperations(self: Block): Block
	local Operation = self.Operation
	if Operation.Method == "None" then
		return self
	end

	local Variable = Operation.Variable
	local Multiplier = if Variable then ` * {Variable}` else ""
	local Append = `local {self.Unique} = {Operation.Method}({Operation.Bytes}{Multiplier})`
	local targetIndent = if self.Unique ~= DEFAULT_UNIQUE then self.Indent - 1 else self.Indent

	-- Emitted in reverse order into `self.Cursor` so the comment precedes the allocation statement.
	self:_lineFront(Append, targetIndent)
	self:_lineFront(`-- {Operation.Method} BLOCK: {Operation.Bytes} bytes`, targetIndent)

	-- Prevent duplicate header emissions if `_appendOperations` is called multiple times.
	Operation.Method = "None"

	return self
end

function Block.Declare(self: Block, Variable: string, Initialize: boolean?): string
	-- Fast path: Ignore property or index accesses (e.g. `Vector.X`, `Character.Root`, `t[k]`)
	if string.find(Variable, "[%.%[]") ~= nil then
		return Variable
	end

	-- Search for an existing declaration up the block hierarchy
	local current: Block? = self
	while current ~= nil do
		if current.Variables[Variable] then
			return Variable
		end
		current = current.Parent
	end

	-- Mark as declared within the current scope
	self.Variables[Variable] = true

	if Initialize then
		self:Line(`local {Variable}`)
	end

	return `local {Variable}`
end

function Block.EmptyDeclare(self: Block, Variable: string)
	self.Variables[Variable] = true
end

function Block.Advance(self: Block, Offset: number): Block
	self.Cursor += Offset
	return self
end

function Block.Line(self: Block, Text: string, Indent: number?): Block
	local indentLevel = Indent or self.Indent
	table.insert(self.Content, `{getIndent(indentLevel)}{Text}\n`)
	return self
end

function Block.Comment(self: Block, Content: string, Indent: number?): Block
	self:Line(`-- {Content}`, Indent)
	return self
end

function Block.Lines(self: Block, Lines: { string }, Indent: number?): Block
	local indentLevel = Indent or 0

	-- Fast path: when no additional indentation is applied, move lines directly
	if indentLevel == 0 then
		local lineCount = #Lines
		if lineCount > 0 then
			table.move(Lines, 1, lineCount, #self.Content + 1, self.Content)
		end
		return self
	end

	local indentation = getIndent(indentLevel)
	for _, line in Lines do
		table.insert(self.Content, `{indentation}{line}`)
	end

	return self
end

function Block.Multiline(self: Block, Content: string, Indent: number?): Block
	local indentStr = getIndent(Indent or 0)
	local lines = string.split(Content, "\n")
	local count = #lines

	-- Trim trailing empty entry caused by trailing `\n` in multiline blocks
	if count > 0 and lines[count] == "" then
		count -= 1
	end

	for i = 1, count do
		table.insert(self.Content, `{indentStr}{lines[i]}\n`)
	end

	return self
end

function Block.Loop(self: Block, Counter: string, Length: string): Block
	local Loop = Block.new(self, `{ARRAY_UNIQUE}_{self.Indent}`)
	local loopHeader = if string.find(Counter, "=") ~= nil
		then `for {Counter}, {Length} do`
		else `for {Counter} = 1, {Length} do`

	Loop:Line(loopHeader, Loop.Indent - 1)
	Loop.Operation.Variable = Length
	return Loop
end

function Block.While(self: Block, Condition: string): Block
	self:Line(`while ({Condition}) do`)
	return Block.new(self)
end

function Block.Iterator(self: Block, Key: string, Value: string, Iterator: string): Block
	self:Line(`for {Key}, {Value} in {Iterator} do`)
	return Block.new(self)
end

function Block.Compare(self: Block, Left: string, Right: string, Operator: EqualityOperator): Block
	local op = Operators[Operator] or "=="
	self:Line(`if {Left} {op} {Right} then`)
	return Block.new(self)
end

function Block.Branch(
	self: Block,
	Branch: BranchType,
	Left: string?,
	Right: string?,
	Operator: EqualityOperator?
): Block
	local Parent = self.Parent
	assert(Parent ~= nil, "Cannot branch the root level block.")

	-- Push completed branch content to parent
	self:_appendOperations()
	Parent:Lines(self.Content)

	-- Create subsequent branch header
	if Branch == "Conditional" then
		local op = if Operator and Operators[Operator] then Operators[Operator] else "=="
		Parent:Line(`elseif {Left} {op} {Right} then`)
	else
		Parent:Line("else")
	end

	return Block.new(Parent)
end

function Block.Return(self: Block, Return: string): Block
	self:Line(`return {Return}`)
	return self
end

function Block.End(self: Block): Block
	self:_appendOperations()

	local Parent = self.Parent
	if Parent ~= nil then
		Parent:Lines(self.Content)
		Parent:Line("end")
		return Parent
	end

	self:Line("end", 0)
	return self
end

function Block.Wrap(self: Block, Front: string, Back: string): Block
	local count = #self.Content
	if count == 0 then
		return self
	end

	self.Content[1] = `{Front}{self.Content[1]}`

	local last = self.Content[count]
	-- Remove only the trailing newline rather than regex-stripping all internal newlines
	if string.sub(last, -1) == "\n" then
		self.Content[count] = `{string.sub(last, 1, -2)}{Back}\n`
	else
		self.Content[count] = `{last}{Back}`
	end

	return self
end

-- Builds and flattens the block's content into a final Luau code string.
function Block.Build(self: Block): string
	return table.concat(self.Content)
end

-- Function Block Specialization

local Function = {}
Function.__index = Function
setmetatable(Function, Block)

function Function.new(
	Name: string,
	Arguments: string,
	Return: string?,
	IsInlined: boolean?,
	Localised: boolean?,
	Parent: Block?
): Block
	local block = Block.new(Parent)
	setmetatable(block, Function)

	local Suffix = if Return then `: {Return}` else ""
	local indentLevel = if Parent then Parent.Indent else 0

	-- Ensure operation headers are inserted beneath the function header
	block:Advance(1)

	if IsInlined then
		block:Line(`{Name} = function({Arguments}){Suffix}`, indentLevel)
	elseif Localised then
		block:Line(`local function {Name}({Arguments}){Suffix}`, indentLevel)
	else
		block:Line(`function {Name}({Arguments}){Suffix}`, indentLevel)
	end

	return block
end

-- Connection Block Specialization

local Connection = {}
Connection.__index = Connection
setmetatable(Connection, Block)

function Connection.new(Signal: string, Arguments: string, Parent: Block?): Block
	local block = Block.new(Parent)
	setmetatable(block, Connection)

	local indentLevel = if Parent then Parent.Indent else 0
	block:Advance(1)
	block:Line(`{Signal}:Connect(function({Arguments})`, indentLevel)
	return block
end

function Connection.End(self: Block): Block
	-- Fixed: Operation coalescing was omitted in original Connection.End
	self:_appendOperations()

	local Parent = self.Parent
	if Parent ~= nil then
		Parent:Lines(self.Content)
		Parent:Line("end)", Parent.Indent)
		return Parent
	end

	self:Line("end)", 0)
	return self
end

return table.freeze({
	Block = Block.new,
	Function = Function.new,
	Connection = Connection.new,
})
