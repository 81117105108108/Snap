local fs = require("@lune/fs")
local log = require("./log")

-- Version helper for larvae.toml. Only understands the single shape the build
-- uses: VERSION = "x.y.z" inside [defines]. Anything else is left untouched.

local function definesRegion(contents: string): (number?, number?)
	-- Anchor to line starts: the header comments mention [defines] and must
	-- never match.
	local headerStart = string.find(contents, "^%[defines%]") or string.find(contents, "\n%[defines%]")
	if not headerStart then
		return nil, nil
	end
	local regionStart = if string.sub(contents, headerStart, headerStart) == "\n"
		then headerStart + 1
		else headerStart

	local tail = string.sub(contents, regionStart)
	local nextSection = string.find(tail, "\n%[", 1)
	local regionEnd = if nextSection then regionStart + nextSection - 1 else #contents
	return regionStart, regionEnd
end

local function read_version(config_path: string): string
	local contents = fs.readFile(config_path)
	local regionStart, regionEnd = definesRegion(contents)
	if regionStart and regionEnd then
		local version = string.match(string.sub(contents, regionStart, regionEnd), 'VERSION%s*=%s*"([^"]+)"')
		if version then
			return version
		end
	end

	return "?"
end

local function write_version(config_path: string, version: string)
	local contents = fs.readFile(config_path)
	local regionStart, regionEnd = definesRegion(contents)
	assert(regionStart ~= nil and regionEnd ~= nil, `[defines] section is missing in {config_path}`)

	local region = string.sub(contents, regionStart :: number, regionEnd :: number)
	local replaced, count =
		string.gsub(region, '(VERSION%s*=%s*")[^"]+(")', `%1{version}%2`, 1)
	assert(count == 1, `[defines] VERSION is missing in {config_path}`)

	fs.writeFile(
		config_path,
		string.sub(contents, 1, (regionStart :: number) - 1) .. replaced .. string.sub(contents, (regionEnd :: number) + 1)
	)
	log(`Updated larvae config version to {version}`)
end

return table.freeze({
	read_from = read_version,
	write_to = write_version,
})
