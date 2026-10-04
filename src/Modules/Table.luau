return {
	Merge = function(...: { any }): { any }
		local Tables = { ... }
		local Allocate = 0

		for _, Table in Tables do
			Allocate += #Table
		end

		local Index = 1
		local Merged = table.create(Allocate)

		for _, Table in Tables do
			table.move(Table, 1, #Table, Index, Merged)
			Index += #Table
		end

		return Merged
	end,
	DeepClone = function(Table: { [any]: any }, OpaqueKeys: { [any]: boolean }?): { [any]: any }
		local Cache = {}

		local function Clone(Original)
			-- Fast path: only tables need cloning or cycle detection.
			if type(Original) ~= "table" then
				return Original
			end

			local Cached = Cache[Original]
			if Cached ~= nil then
				return Cached
			end

			-- Keys are never cloned: AST tables use string and number keys,
			-- and preserving key identity keeps shared references intact.
			local Copy = {}
			Cache[Original] = Copy

			for Key, Value in Original do
				-- Opaque keys (such as Scope back-pointers) are shared by
				-- reference: cloning them would copy the whole scope graph
				-- reachable from every node.
				if OpaqueKeys and OpaqueKeys[Key] then
					Copy[Key] = Value
				else
					Copy[Key] = Clone(Value)
				end
			end

			return Copy
		end

		return Clone(Table)
	end,
}
