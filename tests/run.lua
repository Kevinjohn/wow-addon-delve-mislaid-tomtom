-- Behaviour harness: loads MislaidCuriosityTomTom.lua under a stubbed WoW API
-- and a stubbed TomTom, then drives it through the vignette lifecycle:
--   * nothing happens outside a Delve,
--   * in a Delve, only vignettes whose GUID carries a Mislaid Curiosity ID get
--     a waypoint, whether the client has info for them (named) or not
--     (mystery); other IDs, dead ones, and ones without a position do not,
--   * waypoints are created silently with the configured clear distance
--     (5 yards by default, `/mct distance <n>`), and a pin TomTom dropped at
--     that distance is not re-added while the curiosity is still there,
--   * a curiosity counts as collected when flagged dead, or when it vanishes
--     between consecutive scans while you were near it (within 40 yards of
--     its last position, or your pin had cleared on it, or it was named);
--     one that vanishes while you are far is "missing": still known,
--     waypoint kept, revived on return,
--   * a /reload whose first scan sees an empty list counts nothing, while a
--     real login always starts a fresh run,
--   * two curiosities at identical coordinates share one waypoint,
--   * a pre-existing foreign waypoint is deferred to, never removed, and
--     replaced by ours once the player deletes it,
--   * the crazy arrow is pointed at the nearest waypoint only when idle, and
--     without a player position only a lone waypoint is chosen,
--   * `/mct id add|remove` extends and shrinks the ID set,
--   * the run lives in per-character saved variables, is tied to one
--     instance, and resets on a new one,
--   * without TomTom it loads, warns once at login, and only counts,
--   * a rise in the companion's friendship standing prints the gain as a
--     share of the level, handles level-up and max level, and stays quiet
--     for gains under 0.05%, when turned off, or without companion data;
--     the shown gains add up on the counter for the run; Delver's Journey
--     (the major faction with the journey reward track) is tracked the same
--     way, with its own chat line and run total,
--   * the Blizzard Settings panel gets one tick box per setting and a
--     distance drop-down, all live, and its absence is harmless.
--
-- Run from the repo root:  luajit tests/run.lua   (any Lua >= 5.1 works)

local failures, checks = {}, 0
local function check(ok, label)
	checks = checks + 1
	if not ok then
		failures[#failures + 1] = label
		io.write("FAIL  ", label, "\n")
	end
end

local function guid(id, spawn)
	return ("Vignette-0-4234-2601-11946-%d-%s"):format(id, spawn)
end
local CURIO = 5482
local NAMED = { name = "Mislaid Curiosity", atlasName = "VignetteLoot", isDead = false }
local DEAD = { name = "Mislaid Curiosity", atlasName = "VignetteLoot", isDead = true }

-- ---------------------------------------------------------------- WoW stubs
local world = {
	difficultyID = 0,   -- 208 = Delves
	instanceID = 100,
	uiMapID = 2269,
	player = { 0.5, 0.5 }, -- nil = position unknown
	vignettes = {},     -- ordered list of GUIDs
	info = {},          -- guid -> VignetteInfo table, or nil for "mystery"
	position = {},      -- guid -> {x, y}, or nil for "no position yet"
}
local chat = {}

_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) chat[#chat + 1] = msg end }
_G.GetInstanceInfo = function()
	return "Earthcrawl Mines", "scenario", world.difficultyID, "Delve", 5, 0, false, world.instanceID
end
_G.C_Map = {
	GetBestMapForUnit = function() return world.uiMapID end,
	GetMapWorldSize = function() return 1000, 1000 end, -- 0.01 map units = 10 yards
	GetPlayerMapPosition = function()
		if not world.player then return nil end
		return { GetXY = function() return world.player[1], world.player[2] end }
	end,
}
_G.C_Timer = { After = function(_, fn) fn() end } -- run scheduled scans immediately
-- Companion friendship reputation (Blizzard_DelvesCompanionConfiguration path).
local companion = { standing = 26200, reactionThreshold = 22000, nextThreshold = 66500, level = 7 }
_G.C_DelvesUI = { GetFactionForCompanion = function() return 2640 end }
_G.C_GossipInfo = {
	GetFriendshipReputationRanks = function() return { currentLevel = companion.level, maxLevel = 15 } end,
	GetFriendshipReputation = function()
		return { name = "Valeera Sanguinar", standing = companion.standing,
			reactionThreshold = companion.reactionThreshold, nextThreshold = companion.nextThreshold }
	end,
}
-- Delver's Journey: a major faction flagged as the journey reward track.
local journey = { level = 12, earned = 2000, threshold = 5000, maxLevel = 60, unlocked = true }
_G.LE_EXPANSION_LEVEL_CURRENT = 11
_G.C_MajorFactions = {
	GetMajorFactionIDs = function(expansion) check(expansion == 11, "major factions asked for the current expansion"); return { 2600, 2644 } end,
	ShouldUseJourneyRewardTrack = function(id) return id == 2644 end,
	ShouldDisplayMajorFactionAsJourney = function(id) return id == 2644 end,
	GetMajorFactionData = function(id)
		if id == 2600 then return { name = "Council of Dornogal", isUnlocked = true, renownLevel = 3, maxLevel = 25, renownReputationEarned = 1, renownLevelThreshold = 2500 } end
		return { name = "Delver's Journey", isUnlocked = journey.unlocked, renownLevel = journey.level, maxLevel = journey.maxLevel,
			renownReputationEarned = journey.earned, renownLevelThreshold = journey.threshold }
	end,
}
_G.BreakUpLargeNumbers = function(n)
	local s = tostring(n)
	repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end
_G.SlashCmdList = {}
_G.C_VignetteInfo = {
	GetVignettes = function()
		local copy = {}
		for i, g in ipairs(world.vignettes) do copy[i] = g end
		return copy
	end,
	GetVignetteInfo = function(g) return world.info[g] end,
	GetVignettePosition = function(g, uiMapID)
		check(uiMapID == world.uiMapID, "GetVignettePosition called with the player's uiMapID")
		local p = world.position[g]
		if not p then return nil end
		return { GetXY = function() return p[1], p[2] end }
	end,
}
-- Frames: any method not modelled here is a no-op.
local function widget()
	local w = { events = {}, shown = false, scripts = {} }
	function w:RegisterEvent(e) self.events[e] = true end
	function w:UnregisterEvent(e) self.events[e] = nil end
	function w:SetScript(name, fn)
		self.scripts[name] = fn
		if name == "OnEvent" then self.handler = fn end
	end
	function w:Show() self.shown = true end
	function w:Hide() self.shown = false end
	function w:SetText(t) self.textValue = t end
	function w:GetPoint() return "TOPLEFT", nil, "BOTTOMLEFT", 40, -50 end
	function w:CreateFontString() return widget() end
	return setmetatable(w, { __index = function() return function() end end })
end
_G.UIParent = widget()
_G.CreateFrame = function() return widget() end

-- TomTom stub: keyed like the real one (map/x/y/title), returns the existing
-- uid on a duplicate, records the opts, and models the crazy arrow.
local tomtom = { byKey = {}, adds = 0, arrow = nil, lastOpts = nil, profile = { arrow = { arrival = 10 } } }
_G.TomTom = tomtom
local function key(m, x, y, title) return ("%d:%.4f:%.4f:%s"):format(m, x, y, title or "") end
function tomtom:AddWaypoint(m, x, y, opts)
	local k = key(m, x, y, opts.title)
	if self.byKey[k] then return self.byKey[k] end
	self.adds = self.adds + 1
	self.lastOpts = opts
	local uid = { m, x, y, title = opts.title, from = opts.from, key = k }
	self.byKey[k] = uid
	return uid
end
function tomtom:WaypointExists(m, x, y, title) return self.byKey[key(m, x, y, title)] ~= nil end
function tomtom:IsValidWaypoint(uid) return self.byKey[uid.key] == uid end
function tomtom:RemoveWaypoint(uid) self.byKey[uid.key] = nil end
function tomtom:IsCrazyArrowEmpty() return self.arrow == nil end
function tomtom:SetCrazyArrow(uid, dist, title)
	check(dist == 10 and title == uid.title, "SetCrazyArrow gets the profile arrival distance and the title")
	self.arrow = uid
end
local function liveCount()
	local n = 0
	for _ in pairs(tomtom.byKey) do n = n + 1 end
	return n
end
-- Blizzard Settings panel stub: records proxy settings by variable name so a
-- test can flip a box (setValue) and read what the panel would show (getValue).
local settings = { proxies = {}, checkboxes = 0, dropdowns = 0, choices = nil, categories = {} }
_G.Settings = {
	VarType = { Boolean = "boolean", Number = "number", String = "string" },
	Default = { True = true, False = false },
	RegisterVerticalLayoutCategory = function(name) local c = { name = name }; settings.categories[#settings.categories + 1] = c; return c end,
	RegisterProxySetting = function(category, variable, varType, name, default, getValue, setValue)
		assert(category and variable and varType and name and getValue and setValue, "proxy setting arguments")
		assert(settings.proxies[variable] == nil, "duplicate setting variable " .. variable)
		local p = { name = name, varType = varType, default = default, get = getValue, set = setValue }
		settings.proxies[variable] = p
		return p
	end,
	CreateCheckbox = function(_, setting) assert(setting.varType == "boolean"); settings.checkboxes = settings.checkboxes + 1 end,
	CreateControlTextContainer = function()
		return { data = {}, Add = function(self, value, label) self.data[#self.data + 1] = { value = value, label = label } end,
			GetData = function(self) return self.data end }
	end,
	CreateDropdown = function(_, setting, options)
		assert(setting.varType == "number" and type(options) == "function")
		settings.dropdowns = settings.dropdowns + 1
		settings.choices = options()
	end,
	RegisterAddOnCategory = function(c) c.registered = true end,
}

-- ---------------------------------------------------------------- load addon
local ns, frame, tracked, foreign, counter, db, cdb
local function load()
	-- A real /reload drops TomTom's non-persistent waypoints and the arrow.
	tomtom.byKey, tomtom.arrow = {}, nil
	settings.proxies, settings.checkboxes, settings.dropdowns = {}, 0, 0
	ns = {}
	assert(loadfile("MislaidCuriosityTomTom.lua"))("MislaidCuriosityTomTom", ns)
	frame = ns.frame
	frame.handler(frame, "ADDON_LOADED", "MislaidCuriosityTomTom")
	tracked, foreign, counter = ns.GetTracked(), ns.GetForeign(), ns.GetCounterFrame()
	db, cdb = _G.MislaidCuriosityTomTomDB, _G.MislaidCuriosityTomTomCharDB
end
local function fire(event, ...) frame.handler(frame, event, ...) end
-- Counter text up to the companion suffix ("Curiosities 3 / 11"); full()
-- is the whole line.
local function full() return tostring(counter.text.textValue) end
local function text() return (full():gsub("   .*$", "")) end

do
	local probe = {}
	assert(loadfile("MislaidCuriosityTomTom.lua"))("MislaidCuriosityTomTom", probe)
	probe.frame.handler(probe.frame, "ADDON_LOADED", "SomeOtherAddon")
	check(_G.MislaidCuriosityTomTomDB == nil, "ignores ADDON_LOADED for other addons")
	check(probe.VignetteID(guid(CURIO, "0000A6B4C3")) == CURIO, "vignette ID parsed from the GUID")
	check(probe.VignetteID("Creature-0-1-2-3-4-5") == nil, "non-vignette GUID yields no ID")
end
load()
check(db.enabled == true and db.quiet == false and db.counter == true and type(db.ids) == "table"
	and db.counterPos.point == "TOP" and db.counterPos.relativePoint == "TOP", "account settings get defaults")
check(cdb.run.active == false and db.run == nil, "the run lives in per-character saved variables")
check(counter.shown == false, "counter frame created hidden")
check(frame.events.VIGNETTES_UPDATED and frame.events.VIGNETTE_MINIMAP_UPDATED
	and frame.events.PLAYER_ENTERING_WORLD and frame.events.ZONE_CHANGED_NEW_AREA
	and not frame.events.ADDON_LOADED, "registers the vignette and zone events after load")
check(type(SlashCmdList.MISLAIDCURIOSITYTOMTOM) == "function" and SLASH_MISLAIDCURIOSITYTOMTOM1 == "/mct",
	"registers the /mct slash command")

-- ------------------------------------------------------- outside a Delve
local far = guid(CURIO, "AAAA")   -- mystery: no info
world.vignettes = { far }
world.position[far] = { 0.25, 0.75 }
fire("VIGNETTES_UPDATED")
check(liveCount() == 0 and next(tracked) == nil and counter.shown == false and cdb.run.active == false,
	"nothing happens outside a Delve")

-- ------------------------------------------------------------ in a Delve
local near = guid(CURIO, "BBBB")  -- named, close
local dead = guid(CURIO, "CCCC")  -- named, already looted
local nopos = guid(CURIO, "DDDD") -- mystery, no position yet
local boss = guid(5555, "EEEE")   -- some other vignette, named
local other = guid(4444, "FFFF")  -- some other mystery vignette
world.difficultyID = 208
world.vignettes = { far, near, dead, nopos, boss, other }
world.position[near] = { 0.52, 0.51 }
world.position[dead] = { 0.2, 0.2 }
world.position[boss] = { 0.1, 0.1 }
world.position[other] = { 0.9, 0.1 }
world.info[near] = NAMED
world.info[dead] = DEAD
world.info[boss] = { name = "Nemesis", atlasName = "VignetteKillElite", isDead = false }
fire("PLAYER_ENTERING_WORLD")
check(cdb.run.active and cdb.run.instanceID == 100, "entering a Delve starts a run tied to the instance")
check(tracked[far] and tracked[near], "curiosity ID marked whether mystery or named")
check(tracked[dead] == nil and tracked[nopos] == nil and tracked[boss] == nil and tracked[other] == nil,
	"dead, position-less and other-ID vignettes not marked")
check(liveCount() == 2 and tomtom.adds == 2, "exactly two waypoints (got " .. liveCount() .. ")")
local o = tomtom.lastOpts
check(o.title == "Mislaid Curiosity" and o.from == "Mislaid Curiosity TomTom" and o.persistent == false
	and o.crazy == false and o.cleardistance == 5 and o.silent == true, "waypoint options: 5-yard clear, silent")
for _, uid in pairs(tomtom.byKey) do
	check(uid[1] == world.uiMapID, "waypoint uses the Delve map")
end
check(tomtom.arrow == tracked[near], "idle arrow pointed at the nearest curiosity")
check(chat[#chat]:find("Mislaid Curiosity spotted, waypoint set at", 1, true) ~= nil, "announces in chat")
check(counter.shown and text() == "Curiosities 1 / 4",
	"counter: dead counts as collected, no-position counts as known (got " .. text() .. ")")
check(cdb.run.known[far] == "seen" and cdb.run.known[near] == "seen" and cdb.run.known[dead] == "gone",
	"run states: seen, seen, gone")
check(cdb.run.pos[far][1] == 0.25 and cdb.run.pos[nopos] == nil, "last known positions recorded when available")

-- Repeated events do not duplicate waypoints or counts.
fire("VIGNETTE_MINIMAP_UPDATED", near, true)
fire("VIGNETTES_UPDATED")
check(liveCount() == 2 and tomtom.adds == 2 and text() == "Curiosities 1 / 4", "re-scans change nothing")

-- A vignette with no position yet gets marked once the position appears, and
-- an arrow the player is already using is left alone.
tomtom.arrow = { title = "Player's own" }
world.position[nopos] = { 0.5, 0.49 }
fire("VIGNETTES_UPDATED")
check(tracked[nopos] and liveCount() == 3, "late position gets its waypoint")
check(tomtom.arrow.title == "Player's own", "busy arrow is not stolen")
tomtom.arrow = nil

-- A mystery curiosity dropping out of the list is missing, not collected.
world.vignettes = { near, dead, nopos, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[far] == "missing" and tracked[far] and liveCount() == 3 and text() == "Curiosities 1 / 4",
	"far curiosity vanishing is missing: waypoint kept, not counted (got " .. text() .. ")")
world.vignettes = { far, near, dead, nopos, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[far] == "seen" and tracked[far] and tomtom.adds == 3, "missing curiosity revived without a new waypoint")

-- A named curiosity vanishing between consecutive scans is looted.
world.vignettes = { far, dead, nopos, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[near] == "gone" and tracked[near] == nil and liveCount() == 2 and text() == "Curiosities 2 / 4",
	"near curiosity vanishing counts as collected and drops its waypoint (got " .. text() .. ")")

-- Turning dead counts once; vanishing afterwards does not count again.
world.info[nopos] = DEAD
fire("VIGNETTES_UPDATED")
check(tracked[nopos] == nil and liveCount() == 1 and text() == "Curiosities 3 / 4", "dead curiosity counted and unmarked")
world.vignettes = { far, dead, boss, other }
fire("VIGNETTES_UPDATED")
check(text() == "Curiosities 3 / 4", "a dead curiosity vanishing is not counted twice")

-- /reload mid-run: fresh load, same saved variables, empty first scan.
load()
world.vignettes = {}
fire("PLAYER_ENTERING_WORLD", false, true)
check(cdb.run.active and text() == "Curiosities 3 / 4" and counter.shown,
	"empty first scan after /reload counts nothing (got " .. text() .. ")")
check(cdb.run.known[far] == "missing", "known curiosities are missing until the list repopulates")
world.vignettes = { far, dead, boss, other }
fire("VIGNETTES_UPDATED")
check(text() == "Curiosities 3 / 4" and cdb.run.known[far] == "seen", "list repopulating restores states")
check(tracked[far] and tomtom.adds == 4 and liveCount() == 1, "waypoint re-created after /reload")

-- Two curiosities at the same spot share one waypoint until both are gone.
local twinA, twinB = guid(CURIO, "2222"), guid(CURIO, "3333")
world.vignettes = { far, boss, other, twinA, twinB }
world.position[twinA] = { 0.4, 0.4 }
world.position[twinB] = { 0.4, 0.4 }
world.info[twinA] = NAMED
world.info[twinB] = NAMED
fire("VIGNETTES_UPDATED")
check(tracked[twinA] and tracked[twinA] == tracked[twinB] and tomtom.adds == 5 and liveCount() == 2,
	"identical coordinates share one waypoint")
world.vignettes = { far, boss, other, twinB }
fire("VIGNETTES_UPDATED")
check(tracked[twinA] == nil and tomtom:IsValidWaypoint(tracked[twinB]) and liveCount() == 2,
	"shared waypoint survives the first twin being looted")
world.vignettes = { far, boss, other }
fire("VIGNETTES_UPDATED")
check(tracked[twinB] == nil and liveCount() == 1 and text() == "Curiosities 5 / 6", "shared waypoint removed once both are gone")

-- A waypoint someone else already set at that spot is deferred to, never
-- removed, and replaced by ours once the player deletes it.
local shared = guid(CURIO, "1111")
world.vignettes = { far, boss, other, shared }
world.position[shared] = { 0.3, 0.3 }
world.info[shared] = NAMED
local mine = tomtom:AddWaypoint(world.uiMapID, 0.3, 0.3, { title = "Mislaid Curiosity", from = "Someone" })
tomtom.arrow = nil
fire("VIGNETTES_UPDATED")
check(foreign[shared] and tracked[shared] == nil and tomtom.adds == 6, "existing waypoint at the spot is not claimed")
check(tomtom.arrow == nil, "no arrow change when nothing was added")
tomtom:RemoveWaypoint(mine)
fire("VIGNETTES_UPDATED")
check(foreign[shared] == nil and tracked[shared] and tomtom.adds == 7, "ours replaces a deleted foreign waypoint")
world.info[shared] = nil -- back to a mystery vignette
fire("VIGNETTES_UPDATED")
world.vignettes = { far, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[shared] == "gone" and tracked[shared] == nil, "once named, a later vanish still counts")

-- An unnamed curiosity vanishing while the player is within 40 yards counts.
local close = guid(CURIO, "4444")
world.vignettes = { far, boss, other, close }
world.position[close] = { 0.52, 0.48 } -- ~28 yards from the player at 0.5,0.5
fire("VIGNETTES_UPDATED")
check(cdb.run.known[close] == "seen" and tracked[close], "unnamed nearby curiosity marked")
world.vignettes = { far, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[close] == "gone" and tracked[close] == nil and text() == "Curiosities 7 / 8",
	"unnamed curiosity vanishing nearby counts as collected (got " .. text() .. ")")

-- A pin TomTom dropped on arrival means we were there, even if far now.
local walked = guid(CURIO, "5555")
world.vignettes = { far, boss, other, walked }
world.position[walked] = { 0.9, 0.9 }
fire("VIGNETTES_UPDATED")
tomtom.byKey[tracked[walked].key] = nil -- TomTom cleared it at the clear distance
fire("VIGNETTES_UPDATED")
world.vignettes = { far, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[walked] == "gone" and text() == "Curiosities 8 / 9",
	"vanishing after the pin cleared counts as collected (got " .. text() .. ")")

-- Unknown player position and no other evidence: missing, not collected.
local unsure = guid(CURIO, "6666")
world.vignettes = { far, boss, other, unsure }
world.position[unsure] = { 0.5, 0.5 }
fire("VIGNETTES_UPDATED")
world.player = nil
world.vignettes = { far, boss, other }
fire("VIGNETTES_UPDATED")
check(cdb.run.known[unsure] == "missing" and text() == "Curiosities 8 / 10", "no position evidence: missing (got " .. text() .. ")")
world.player = { 0.5, 0.5 }
ns.SlashHandler("counter reset")
check(text() == "Curiosities 0 / 1" and tracked[far] and tracked[unsure] == nil,
	"/mct counter reset forgets the run and drops waypoints of forgotten curiosities (got " .. text() .. ")")

-- Unknown player position: only a lone waypoint gets the idle arrow.
world.player = nil
tomtom.arrow = nil
world.vignettes = { far, boss, other, twinA }
world.position[twinA] = { 0.6, 0.6 }
ns.SlashHandler("clear")
fire("VIGNETTES_UPDATED")
check(liveCount() == 2 and tomtom.arrow == nil, "two candidates and no player position: arrow left alone")
world.vignettes = { boss, other, twinA }
ns.SlashHandler("counter reset")
ns.SlashHandler("clear")
fire("VIGNETTES_UPDATED")
check(liveCount() == 1 and tomtom.arrow == tracked[twinA], "lone candidate and no player position: arrow set")
world.player = { 0.5, 0.5 }
tomtom.arrow = nil

-- /mct id add makes another ID count; /mct id remove drops it from the run.
world.vignettes = { boss, other, twinA }
ns.SlashHandler("id add 4444")
fire("VIGNETTES_UPDATED")
check(db.ids[4444] == true and tracked[other] and text() == "Curiosities 0 / 2", "/mct id add marks that ID (got " .. text() .. ")")
ns.SlashHandler("id remove 4444")
check(db.ids[4444] == nil and tracked[other] == nil and text() == "Curiosities 0 / 1", "/mct id remove unmarks and forgets it")
ns.SlashHandler("id")
check(chat[#chat]:find("5482", 1, true) and chat[#chat]:find("6699", 1, true), "/mct id lists the built-in IDs")

-- /mct id remove of an ID with a collected curiosity keeps the count honest.
world.vignettes = { boss, twinA }
world.info[other] = DEAD
ns.SlashHandler("id add 4444")
world.vignettes = { boss, other, twinA }
fire("VIGNETTES_UPDATED")
check(text() == "Curiosities 1 / 2", "added ID's dead curiosity counts (got " .. text() .. ")")
ns.SlashHandler("id remove 4444")
check(text() == "Curiosities 0 / 1", "removing the ID also un-counts its collected curiosity (got " .. text() .. ")")
world.info[other] = nil

-- /mct off clears waypoints but keeps the run; /mct on re-marks.
cdb.run.collected = 3
ns.SlashHandler("off")
check(liveCount() == 0 and next(tracked) == nil and counter.shown == false and cdb.run.active,
	"/mct off removes waypoints and hides the counter but keeps the run")
ns.SlashHandler("on")
fire("VIGNETTES_UPDATED")
check(tracked[twinA] and liveCount() == 1 and counter.shown and text() == "Curiosities 3 / 1",
	"/mct on re-marks and keeps the run's numbers (got " .. text() .. ")")
cdb.run.collected = 0

-- A real login inside the same Delve map starts a fresh run.
cdb.run.collected = 2
fire("PLAYER_ENTERING_WORLD", true, false)
check(cdb.run.active and cdb.run.collected == 0 and text() == "Curiosities 0 / 1",
	"initial login inside a Delve starts over (got " .. text() .. ")")

-- Leaving the Delve ends the run; a different instance starts a fresh one.
world.difficultyID = 0
fire("ZONE_CHANGED_NEW_AREA")
check(liveCount() == 0 and next(tracked) == nil and counter.shown == false and cdb.run.active == false,
	"leaving the Delve clears waypoints, hides the counter, ends the run")
ns.SlashHandler("")
check(chat[#chat - 3]:find("last run:", 1, true) ~= nil, "status calls a finished run the last run")
world.difficultyID = 208
world.instanceID = 200
fire("PLAYER_ENTERING_WORLD")
fire("VIGNETTES_UPDATED")
check(cdb.run.instanceID == 200 and text() == "Curiosities 0 / 1" and tracked[twinA], "new instance starts a fresh run")

-- Counter commands and drag.
ns.SlashHandler("counter off")
check(db.counter == false and counter.shown == false, "/mct counter off hides it")
ns.SlashHandler("counter on")
check(db.counter == true and counter.shown == true, "/mct counter on shows it")
counter.scripts.OnDragStop(counter)
check(db.counterPos.point == "TOPLEFT" and db.counterPos.relativePoint == "BOTTOMLEFT"
	and db.counterPos.x == 40 and db.counterPos.y == -50, "dragging saves point and relative point")

-- Quiet mode, status, debug, usage.
ns.SlashHandler("quiet on")
ns.SlashHandler("clear")
local before = #chat
fire("VIGNETTES_UPDATED")
check(liveCount() == 1 and #chat == before, "quiet suppresses the spotted line")
local beforeDebug = #chat
ns.SlashHandler("debug")
local sawTracked = false
for i = beforeDebug + 1, #chat do
	if chat[i]:find("id " .. CURIO, 1, true) and chat[i]:find("tracked", 1, true) then sawTracked = true end
end
check(sawTracked, "debug lists the vignette ID and tracking")
ns.SlashHandler("")
check(chat[#chat]:find("usage:", 1, true) ~= nil, "bare /mct prints usage")
check(chat[#chat - 3]:find("1 waypoint(s) active", 1, true) ~= nil, "status counts live waypoints")

-- TomTom missing: one warning at login, status says so, counting continues.
ns.SlashHandler("clear")
_G.TomTom = nil
before = #chat
fire("PLAYER_ENTERING_WORLD")
fire("PLAYER_ENTERING_WORLD")
check(#chat == before + 1 and chat[#chat]:find("TomTom is not installed", 1, true) ~= nil,
	"missing TomTom is reported once per session")
ns.SlashHandler("")
check(chat[#chat - 1]:find("TomTom is not installed", 1, true) ~= nil, "status reports missing TomTom")
ns.SlashHandler("clear")
world.vignettes = { boss, other, twinA, twinB }
world.position[twinB] = { 0.7, 0.7 }
fire("VIGNETTES_UPDATED")
check(counter.shown and text() == "Curiosities 0 / 2", "counter still counts without TomTom (got " .. text() .. ")")
_G.TomTom = tomtom

-- TomTom drops the pin at the clear distance: not re-added while the
-- curiosity is still there.
world.vignettes = { boss, other, twinA, twinB }
fire("VIGNETTES_UPDATED")
local pinned = tracked[twinA]
local addsBefore = tomtom.adds
tomtom.byKey[pinned.key] = nil
fire("VIGNETTES_UPDATED")
check(tracked[twinA] == pinned and tomtom.adds == addsBefore, "pin dropped at clear distance is not re-added")

-- /mct distance changes the option for new pins.
ns.SlashHandler("distance 12")
check(db.cleardistance == 12, "/mct distance persists")
ns.SlashHandler("distance x")
check(db.cleardistance == 12 and chat[#chat - 3]:find("usage: /mct distance", 1, true) ~= nil, "bad distance is rejected")
ns.SlashHandler("distance 0")
ns.SlashHandler("clear")
fire("VIGNETTES_UPDATED")
check(tomtom.lastOpts.cleardistance == 0 and tracked[twinA], "new pins use the new distance")
ns.SlashHandler("distance 5")

-- Companion experience line.
fire("PLAYER_ENTERING_WORLD") -- primes the last-known standing
before = #chat
fire("UPDATE_FACTION")
check(#chat == before, "unchanged standing prints nothing")
companion.standing = companion.standing + 4500
fire("UPDATE_FACTION")
check(chat[#chat] == "|cff33ff99Mislaid Curiosity TomTom:|r Valeera: +10.1%, 8 more to level up.",
	"gain printed as a percentage with the count to level (got " .. chat[#chat] .. ")")
check(full() == text() .. "   +10.1%   Journey +0.0%", "counter shows the run's companion gain, no name (got " .. full() .. ")")
ns.SlashHandler("xp off")
check(db.counterxp == false and full() == text(), "/mct xp off drops the suffix (got " .. full() .. ")")
ns.SlashHandler("xp on")
companion.standing = companion.standing + 18 -- kill credit: would round to +0.0%
before = #chat
fire("UPDATE_FACTION")
check(#chat == before, "gains that round to 0.0% print nothing")
companion.standing = 63000 -- 3,500 short of the next level
fire("UPDATE_FACTION")
companion.standing = 65000 -- +2,000: one more of those levels up
fire("UPDATE_FACTION")
check(chat[#chat]:find("Valeera: +4.5%, one more levels up.", 1, true) ~= nil, "singular wording near the level (got " .. chat[#chat] .. ")")
before = #chat
fire("UPDATE_FACTION")
check(#chat == before, "same standing again prints nothing")
companion.standing = 67000
companion.reactionThreshold, companion.nextThreshold, companion.level = 66500, 111000, 8
fire("UPDATE_FACTION")
check(chat[#chat]:find("Valeera: level up! Level 8, 1.1% in.", 1, true) ~= nil, "level up reported (got " .. chat[#chat] .. ")")
companion.standing, companion.reactionThreshold, companion.nextThreshold, companion.level = 500000, 480000, nil, 15
fire("UPDATE_FACTION")
check(chat[#chat]:find("level up! Level 15, the maximum.", 1, true) ~= nil, "max level reached (got " .. chat[#chat] .. ")")
companion.standing = 500100
fire("UPDATE_FACTION")
check(chat[#chat]:find("already at max level 15", 1, true) ~= nil, "gain at max level")
ns.SlashHandler("companion off")
check(db.companion == false, "/mct companion off persists")
companion.standing = 500200
before = #chat
fire("UPDATE_FACTION")
check(#chat == before, "companion line suppressed when off")
ns.SlashHandler("companion on")
ns.SlashHandler("")
check(chat[#chat - 1]:find("Valeera is level 15, the maximum.", 1, true) ~= nil, "status shows companion progress")
check(cdb.run.xp > 190 and cdb.run.xp < 191 and full():find("   +190.5%", 1, true) ~= nil,
	"run total sums every shown gain, level-ups included (got " .. full() .. ")")
check(chat[#chat - 2]:find("xp on counter on (+190.5% / journey +0.0% this run)", 1, true) ~= nil, "status shows the run totals")
companion.standing = 500300
before = #chat
fire("UPDATE_FACTION")
check(#chat == before + 1 and cdb.run.xp < 191, "gains at max level are reported but add nothing")
ns.SlashHandler("companion off")
db.counterxp = true
ns.SlashHandler("counter reset")
check(cdb.run.xp == 0 and full():find("   +0.0%", 1, true) ~= nil, "counter reset clears the run total")
ns.SlashHandler("companion on")

-- Delver's Journey progress, tracked the same way.
before = #chat
journey.earned = 2500
fire("UPDATE_FACTION")
check(chat[#chat] == "|cff33ff99Mislaid Curiosity TomTom:|r Journey: +10.0%, 5 more to level up.",
	"journey gain printed as a percentage (got " .. chat[#chat] .. ")")
check(full():find("Journey +10.0%", 1, true) ~= nil, "counter shows the run's journey gain (got " .. full() .. ")")
journey.earned = 2501
before = #chat
fire("UPDATE_FACTION")
check(#chat == before and cdb.run.journey == 10, "tiny journey gains print nothing and add nothing")
journey.level, journey.earned = 13, 200
fire("MAJOR_FACTION_RENOWN_LEVEL_CHANGED", 2644, 13, 12)
check(chat[#chat]:find("Journey: level up! Level 13, 4.0% in.", 1, true) ~= nil, "journey level up reported (got " .. chat[#chat] .. ")")
check(cdb.run.journey > 63.9 and cdb.run.journey < 64.1, "level up adds the rest of the old level and the way into the new")
ns.SlashHandler("journey off")
journey.earned = 1200
before = #chat
fire("UPDATE_FACTION")
check(db.journey == false and #chat == before and cdb.run.journey > 83.9, "/mct journey off silences the line, total still counts")
ns.SlashHandler("journey on")
journey.level, journey.earned = 60, 0
fire("UPDATE_FACTION")
check(chat[#chat]:find("Journey: level up! Level 60, the maximum.", 1, true) ~= nil, "journey max level (got " .. chat[#chat] .. ")")
journey.level, journey.earned = 12, 2000
fire("UPDATE_FACTION")
ns.SlashHandler("")
check(chat[#chat - 1]:find("Journey is level 12, 40.0% through it (2,000 / 5,000).", 1, true) ~= nil, "status shows journey progress (got " .. chat[#chat - 1] .. ")")
ns.SlashHandler("debug")
local sawJourney = false
for i = math.max(1, #chat - 40), #chat do
	if chat[i]:find("journey faction 2644; major factions: 2600 'Council of Dornogal', 2644 'Delver's Journey'", 1, true) then sawJourney = true end
end
check(sawJourney, "debug names the journey faction and the candidates")
do
	local saved = _G.C_MajorFactions
	_G.C_MajorFactions = nil
	ns.SlashHandler("")
	check(chat[#chat - 1]:find("Delver's Journey progress unavailable", 1, true) ~= nil, "no major faction API: status says so, no error")
	_G.C_MajorFactions = saved
end

-- Options panel: one tick box per setting, a drop-down for the distance, all
-- reading and writing the saved table live.
local function proxy(key) return settings.proxies["MislaidCuriosityTomTom_" .. key] end
check(settings.categories[#settings.categories].name == "Mislaid Curiosity TomTom"
	and settings.categories[#settings.categories].registered, "options category registered under AddOns")
check(settings.checkboxes == 6 and settings.dropdowns == 1, "six tick boxes and one drop-down")
check(#settings.choices == 3 and settings.choices[1].value == 0 and settings.choices[2].value == 5
	and settings.choices[3].value == 10 and settings.choices[1].label:find("Off", 1, true) == 1,
	"drop-down offers off, 5 and 10 yards")
for _, key in ipairs({ "enabled", "companion", "journey", "counter", "counterxp" }) do
	check(proxy(key) and proxy(key).get() == true, "tick box '" .. key .. "' present and on")
end
check(db.quiet == true and proxy("announce").get() == false, "announce box mirrors quiet (still on from above)")
ns.SlashHandler("quiet off")
check(proxy("announce").get() == true, "/mct quiet off ticks the announce box")
proxy("announce").set(false)
check(db.quiet == true and proxy("announce").get() == false, "unticking the chat announcement sets quiet")
ns.SlashHandler("quiet off")
check(proxy("announce").get() == true, "/mct quiet off re-ticks the box")
proxy("companion").set(false)
companion.standing = 500400
before = #chat
fire("UPDATE_FACTION")
check(db.companion == false and #chat == before, "unticking the companion line silences it")
proxy("companion").set(true)
proxy("counterxp").set(false)
check(db.counterxp == false and full() == text(), "unticking counter XP drops the suffix live")
proxy("counterxp").set(true)
check(full():find("   +", 1, true) ~= nil, "ticking it back restores the suffix")
proxy("counter").set(false)
check(db.counter == false and counter.shown == false, "unticking the counter hides it live")
proxy("counter").set(true)
check(counter.shown == true, "ticking the counter shows it again")
proxy("enabled").set(false)
check(db.enabled == false and counter.shown == false and liveCount() == 0, "unticking the addon clears waypoints and hides the counter")
proxy("enabled").set(true)
check(counter.shown == true, "ticking the addon back restores the counter")
check(proxy("cleardistance").get() == 5, "drop-down reads the clear distance")
proxy("cleardistance").set(10)
check(db.cleardistance == 10, "drop-down writes the chosen distance")
ns.SlashHandler("distance 5")
check(proxy("cleardistance").get() == 5, "/mct distance updates the drop-down's value")
do
	local saved = _G.Settings
	_G.Settings = nil
	before = #chat
	load()
	check(#chat == before and db.enabled == true, "no Settings API: loads quietly, /mct still works")
	_G.Settings = saved
	load()
	check(proxy("enabled") ~= nil, "panel registered again after a /reload")
	world.difficultyID = 208
	fire("PLAYER_ENTERING_WORLD")
end
_G.C_DelvesUI = nil
companion.standing = 500300
fire("UPDATE_FACTION")
ns.SlashHandler("")
check(chat[#chat - 1]:find("companion progress unavailable", 1, true) ~= nil, "no companion API: status says so, no error")

io.write(("%d checks, %d failures\n"):format(checks, #failures))
if #failures > 0 then
	os.exit(1)
end
