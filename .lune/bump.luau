local larvae_version = require("./libs/larvae_version")
local pesde_version = require("./libs/pesde_version")
local stdio = require("@lune/stdio")

local PESDE_CONFIG = "pesde.toml"
local LARVAE_CONFIG = "larvae.toml"

local curr_version = larvae_version.read_from(LARVAE_CONFIG)
local new_version = stdio.prompt("text" :: "text", `What version is being built? (Current version is {curr_version})`)
larvae_version.write_to(LARVAE_CONFIG, new_version)
pesde_version.write_to(PESDE_CONFIG, new_version)
