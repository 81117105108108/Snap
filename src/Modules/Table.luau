--!strict
--!native
--!optimize 2

export type OpaqueKeys = { [any]: boolean }

--[=[
	Internal recursive cloning worker.
	Kept at file scope to eliminate closure allocation churn across calls.
]=]
local function deepCloneInternal(
	node: any,
	cache: { [any]: any },
	opaqueKeys: OpaqueKeys?
): any
	if type(node) ~= "table" then
		return node
	end

	local cached = cache[node]
	if cached ~= nil then
		return cached
	end

	-- Fast path: `table.clone` performs a single C-level allocation matching the
	-- exact hash and array capacity of the source, copying metatables and primitives.
	-- This eliminates repeated table resizing/rehashing during property population.
	local copy = table.clone(node)
	cache[node] = copy

	if opaqueKeys ~= nil then
		for key, value in node do
			-- Opaque keys (e.g. Scope/Parent back-pointers) and primitive values
			-- are already copied by reference/value via `table.clone`. We only
			-- mutate nested tables that are not designated opaque.
			if type(value) == "table" and not opaqueKeys[key] then
				copy[key] = deepCloneInternal(value, cache, opaqueKeys)
			end
		end
	else
		for key, value in node do
			if type(value) == "table" then
				copy[key] = deepCloneInternal(value, cache, nil)
			end
		end
	end

	return copy
end

--[=[
	Recursively clones tables with cycle/DAG protection and optional opaque keys.
	Generic signature preserves the exact caller type without downcasting to `any`.
]=]
local function deepClone<T>(value: T, opaqueKeys: OpaqueKeys?): T
	if type(value) ~= "table" then
		return value
	end

	local cache: { [any]: any } = {}
	return (deepCloneInternal(value, cache, opaqueKeys) :: any) :: T
end

--[=[
	Concatenates multiple arrays into a single contiguous array.
	Specialized for 0, 1, and 2 arguments to eliminate vararg `{ ... }` heap allocations.
]=]
local function merge<T>(...: { T }): { T }
	local count = select("#", ...)

	if count == 0 then
		return {}
	end

	if count == 1 then
		local first = ...
		return if first ~= nil then table.clone(first) else {}
	end

	-- Fast path: 2-table merges (the vast majority of operations) avoid packing `...` into a table.
	if count == 2 then
		local a, b = ...
		local lenA = if a ~= nil then #a else 0
		local lenB = if b ~= nil then #b else 0
		local merged = table.create(lenA + lenB) :: { T }

		if lenA > 0 then
			table.move(a :: { T }, 1, lenA, 1, merged)
		end
		if lenB > 0 then
			table.move(b :: { T }, 1, lenB, lenA + 1, merged)
		end

		return merged
	end

	-- N-table fallback
	local tables = { ... }
	local totalLen = 0

	for i = 1, count do
		local t = tables[i]
		if t ~= nil then
			totalLen += #t
		end
	end

	local merged = table.create(totalLen) :: { T }
	local offset = 1

	for i = 1, count do
		local t = tables[i]
		if t ~= nil then
			local len = #t
			if len > 0 then
				table.move(t :: { T }, 1, len, offset, merged)
				offset += len
			end
		end
	end

	return merged
end

local TableUtil = table.freeze({
	Merge = merge,
	DeepClone = deepClone,
})

return TableUtil
