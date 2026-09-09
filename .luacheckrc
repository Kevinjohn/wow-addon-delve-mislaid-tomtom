std = "lua51"
max_line_length = false
self = false

exclude_files = {
	".luacheckrc",
	"tests/*.lua", -- plain Lua, run outside the WoW sandbox
}

-- The standard addon header is `local addonName, ns = ...`; OnEvent handlers
-- take a `self` they don't always use.
ignore = { "212/self" }

-- Globals this addon defines: its saved-variables table and the slash-command
-- registration globals (SlashCmdList is mutated, the SLASH_* names are set).
globals = {
	"MislaidCuriosityTomTomDB",
	"MislaidCuriosityTomTomCharDB",
	"SlashCmdList",
	"SLASH_MISLAIDCURIOSITYTOMTOM1",
	"SLASH_MISLAIDCURIOSITYTOMTOM2",
}

read_globals = {
	-- Frames and chat
	"CreateFrame",
	"UIParent",
	"DEFAULT_CHAT_FRAME",

	-- Instance / map / vignette / timer APIs
	"GetInstanceInfo",
	"DifficultyUtil",
	"C_Map",
	"C_VignetteInfo",
	"C_Timer",
	"Enum",

	-- Provided by the TomTom addon (an optional dependency in the .toc)
	"TomTom",
}
