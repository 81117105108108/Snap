local fs = require("@lune/fs")
local log = require("./libs/log")
local process = require("@lune/process")

type Archs = | "aarch64" | "x86_64"

type Platforms = | "macos" | "linux" | "windows"

local EXE_NAME = "blink"

local RELEASE_DIR = "release"
local PLUGIN_SOURCE_DIR = `plugin/src`
local PLUGIN_RELEASE_DIR = `{RELEASE_DIR}/plugin`

local CLI_PATH = "src/CLI/init.luau"
local BUNDLE_PATH = `{RELEASE_DIR}/blink.luau`
local PESDE_RELEASE_PATH = `{RELEASE_DIR}/blink_pesde.luau`

local LARVAE_CONFIG = "larvae.toml"
local PLUGIN_ROJO_CONFIG = "build/plugin.project.json"

-- The build needs larvae 0.9+ (see rokit.toml). An older larvae earlier on PATH
-- (for example a cargo install shadowing the rokit link) would produce a
-- subtly different bundle, so fail loudly instead.
local function assertLarvaeVersion()
	local version_result = process.exec("larvae", { "--version" })
	assert(version_result.ok, version_result.stderr)
	local major, minor = string.match(version_result.stdout, "larvae (%d+)%.(%d+)%.%d+")
	local ok = major ~= nil and (tonumber(major) or 0) > 0 or (major == "0" and (tonumber(minor) or 0) >= 9)
	assert(ok, `larvae 0.9+ is required (run rokit install), found: {string.gsub(version_result.stdout, "%s+", "")}`)
end

-- larvae `defines` only folds bare globals (and only through `process`, not
-- `bundle`), while the compiler reads its release flags through _G so that
-- --!strict stays quiet about unknown globals. Fold the two accesses
-- explicitly so release bundles behave exactly like the old darklua
-- inject_global_value output. The patterns anchor the full name: other _G
-- uses (WATCH_THREAD, _G._BLINK) are runtime state and must never match.
local function foldReleaseFlags(Text: string, Version: string): string
	local Folded = string.gsub(Text, "_G%.RELEASE", "true")
	Folded = string.gsub(Folded, "_G%.VERSION", `"{Version}"`)
	return Folded
end

-- Single source of truth for the release stamp: [defines] VERSION in larvae.toml.
-- The header is anchored to a line start so the file's own comments (which
-- mention [defines]) can never match.
local function readBundleVersion(): string
	local Config = fs.readFile(LARVAE_CONFIG)
	local Section = string.match(Config, "\n%[defines%]([^%[]*)") or string.match(Config, "^%[defines%]([^%[]*)")
	assert(Section ~= nil, "larvae.toml [defines] is missing")
	local Version = string.match(Section, 'VERSION%s*=%s*"([^"]+)"')
	assert(Version ~= nil, "larvae.toml [defines] VERSION is missing")
	return Version
end

local function bundle(Entry: string, Out: string, Profile: string?)
	local Arguments = { "bundle", "--config", LARVAE_CONFIG, "--entry", Entry, "--out", Out }
	if Profile then
		table.insert(Arguments, "--profile")
		table.insert(Arguments, Profile)
	end

	local bundle_result = process.exec("larvae", Arguments)
	assert(bundle_result.ok, bundle_result.stderr)

	fs.writeFile(Out, foldReleaseFlags(fs.readFile(Out), readBundleVersion()))
end

local function build_executable(platform: Platforms, arch: Archs)
	local target = `{platform}-{arch}`
	local exe_name = `{EXE_NAME}{platform == "windows" and ".exe" or ""}`
	local exe_path = `{RELEASE_DIR}/{exe_name}`
	local build_result = process.exec("lune", {
		"build",
		BUNDLE_PATH,
		"--output",
		exe_path,
		"--target",
		target,
	}, { stdio = "forward" })
	assert(build_result.ok, build_result.stderr)

	local archive_result: process.ExecResult
	if platform == "windows" then
		archive_result = process.exec("tar", {
			"-czvf",
			`{RELEASE_DIR}/blink-{target}.tar.gz`,
			"-C",
			RELEASE_DIR,
			exe_name,
		}, { stdio = "forward" })
	else
		archive_result = process.exec("tar", {
			"-cJvf",
			`{RELEASE_DIR}/blink-{target}.tar.xz`,
			"-C",
			RELEASE_DIR,
			exe_name,
		}, { stdio = "forward" })
	end

	assert(archive_result.ok, archive_result.stderr)

	fs.removeFile(exe_path)
	log(`Built executable for {target}`)
end

local function build_pesde()
	bundle("./" .. CLI_PATH, "./" .. PESDE_RELEASE_PATH)
	log("Build pesde source")
end

local function build_executables()
	bundle("./" .. CLI_PATH, "./" .. BUNDLE_PATH)
	log("Bundled CLI source code")

	build_executable("macos", "x86_64")
	build_executable("macos", "aarch64")
	build_executable("linux", "x86_64")
	build_executable("linux", "aarch64")
	build_executable("windows", "x86_64")

	fs.removeFile(BUNDLE_PATH)
end

local function build_studio_plugin()
	fs.writeDir(PLUGIN_RELEASE_DIR)

	for _, filename in fs.readDir(PLUGIN_SOURCE_DIR) do
		if string.split(filename, ".")[2] == "rbxmx" then
			fs.copy(`{PLUGIN_SOURCE_DIR}/{filename}`, `{PLUGIN_RELEASE_DIR}/{filename}`)
		end
	end

	bundle("./" .. PLUGIN_SOURCE_DIR .. "/init.server.luau", "./" .. PLUGIN_RELEASE_DIR .. "/init.server.luau", "plugin")

	local rojo_result = process.exec("rojo", {
		"build",
		PLUGIN_ROJO_CONFIG,
		"--output",
		`{RELEASE_DIR}/blink-plugin.rbxm`,
	})
	assert(rojo_result.ok, rojo_result.stderr)

	log("Built studio plugin")
	fs.removeDir(PLUGIN_RELEASE_DIR)
end

do
	if fs.isDir(RELEASE_DIR) then
		fs.removeDir(RELEASE_DIR)
	end
	fs.writeDir(RELEASE_DIR)
end

local start = os.clock()
assertLarvaeVersion()
build_pesde()
build_executables()
build_studio_plugin()

local elapsed = (os.clock() - start)
print(string.format("Finished build in %.2f seconds", elapsed))
