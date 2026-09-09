-- Mislaid Curiosity TomTom
--
-- While you are inside a Delve, sets a TomTom waypoint for every Mislaid
-- Curiosity the client knows about, removes it once the curiosity is looted,
-- and shows a small "collected / known" counter for the run. Nothing happens
-- outside Delves.
--
-- "Looted" is evidence-based: the vignette is flagged dead, or it vanishes
-- while you are near it (within NEAR_YARDS of its last known spot, or after
-- TomTom already dropped your pin on it, or while it was named). A vignette
-- that merely drops out of the client's list (out of range, or the list not
-- yet populated after a /reload) is "missing": still known, waypoint kept,
-- not counted.
--
-- How it works: curiosities are "vignettes". Far away they are "mystery"
-- vignettes -- C_VignetteInfo.GetVignetteInfo returns nothing for them, but
-- C_VignetteInfo.GetVignettePosition still returns a position. Close up they
-- become ordinary vignettes with a name. Either way the vignette's GUID carries
-- its Vignette.db2 ID, so we match on known curiosity IDs and hand the
-- position to TomTom.

local addonName, ns = ...

local ADDON_TITLE = "Mislaid Curiosity TomTom"
local WAYPOINT_TITLE = "Mislaid Curiosity"
-- "Delves" difficulty; read from the client when it exposes it, 208 otherwise
-- (warcraft.wiki.gg/wiki/DifficultyID).
local DELVE_DIFFICULTY_ID = (DifficultyUtil and DifficultyUtil.ID and DifficultyUtil.ID.Delves) or 208
local SCAN_DELAY = 0.2 -- seconds; vignette events come in bursts
local NEAR_YARDS = 40  -- vanishing within this distance of you counts as looted

-- Vignette.db2 IDs that are a Mislaid Curiosity. 5482 is the unnamed marker
-- Delves actually send to the client (confirmed in-game, Gnarldor Isle,
-- 12.1.0); 6699 is the row named "Mislaid Curiosity" in the data tables,
-- kept in case a Delve uses it. Extra IDs: `/mct id add <n>`.
local CURIOSITY_IDS = {
    [5482] = true,
    [6699] = true,
}

local DEFAULTS = {
    enabled = true,  -- master switch
    quiet = false,   -- suppress the "spotted" chat line
    counter = true,  -- show the on-screen counter inside Delves
    counterxp = true, -- ... and on it, this run's companion and Delver's Journey gains as a % of a level
    companion = true, -- after a companion experience gain, say what % it was and how many more to level
    journey = true,   -- the same for Delver's Journey progress
    nemesis = true,   -- paint "groups remaining" in white over the Delve tracker's widget icon
    cleardistance = 5, -- yards from a curiosity at which TomTom drops its pin; 0 = keep until looted
    ids = {},        -- extra vignette IDs, [id] = true
    counterPos = { point = "TOP", relativePoint = "TOP", x = 0, y = -120 },
}

-- Per-character saved variables: the current Delve run, kept so a /reload
-- mid-run keeps the numbers. known = [guid] = "seen" | "missing" | "gone";
-- pos = [guid] = { x, y } last known map position; collected = number of
-- "gone"; xp and journey = companion experience and Delver's Journey progress
-- gained during the run, each as a percentage of a level (gains too small to
-- show as 0.1% are left out, so kill credit does not creep in); instanceID is the instance map ID, a sanity check only
-- (copies of the same Delve share it), so a saved run is also ended on any
-- real login: it survives a /reload and nothing else.
local CHAR_DEFAULTS = {
    run = { active = false, instanceID = 0, known = {}, pos = {}, collected = 0, xp = 0, journey = 0 },
}

local db, cdb
local warnedNoTomTom = false
-- GUIDs present in the previous scan of this session. A vignette only counts
-- as looted when it vanishes from one scan to the next, so an empty list on
-- the first scan after a /reload cannot count anything.
local lastPresent = {}
-- Session evidence of having been close to a curiosity: it was named at last
-- sight, or TomTom dropped our pin on it (clear distance reached).
local named, reached = {}, {}
-- Delver's Journey major faction ID, found once per session.
local journeyFactionID
-- Widget frame -> our overlay font string (weak keys: frames may be released).
local overlays = setmetatable({}, { __mode = "k" })
local widgetScanPending = false
-- vignetteGUID -> TomTom waypoint uid we created. Once TomTom drops a pin at
-- the clear distance the entry stays (uid no longer valid), so the pin is not
-- re-added while you loot.
local tracked = {}
-- vignetteGUID -> { uiMapID, x, y } where a waypoint by someone else already
-- sat at the curiosity's spot; we defer to it and never remove it.
local foreign = {}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON_TITLE .. ":|r " .. msg)
end

local NO_TOMTOM = "TomTom is not installed or is disabled. Waypoints need it; the counter still works."

-- Called on entering the world: TomTom is a soft dependency, so its absence
-- is reported once per session instead of failing to load.
local function CheckTomTom()
    if TomTom or warnedNoTomTom then
        return
    end
    warnedNoTomTom = true
    Print(NO_TOMTOM)
end

local function InDelve()
    local _, _, difficultyID = GetInstanceInfo()
    return difficultyID == DELVE_DIFFICULTY_ID
end

-- GUID layout: Vignette-0-<server>-<instance>-<zoneUID>-<vignetteID>-<spawnUID>
local function VignetteID(guid)
    local id = guid:match("^Vignette%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return tonumber(id)
end

local function IsCuriosityID(guid)
    local id = VignetteID(guid)
    return id ~= nil and (CURIOSITY_IDS[id] or db.ids[id]) == true
end

local function IsDead(guid)
    local info = C_VignetteInfo.GetVignetteInfo(guid)
    return info ~= nil and info.isDead == true
end

-- ---------------------------------------------------------------- companion

-- The Delve companion's level is a friendship reputation: the same path
-- Blizzard_DelvesCompanionConfiguration uses. Returns nil when the client
-- cannot say.
local function CompanionProgress()
    if not (C_DelvesUI and C_DelvesUI.GetFactionForCompanion and C_GossipInfo) then
        return nil
    end
    local factionID = C_DelvesUI.GetFactionForCompanion(nil)
    if not factionID or factionID == 0 then
        return nil
    end
    local ranks = C_GossipInfo.GetFriendshipReputationRanks(factionID)
    local rep = C_GossipInfo.GetFriendshipReputation(factionID)
    if not ranks or not rep or not rep.standing then
        return nil
    end
    local floor = rep.reactionThreshold or 0
    local name = rep.name or "Companion"
    return {
        name = name:match("^(%S+)") or name, -- first name only: "Valeera"
        level = ranks.currentLevel or 0,
        maxLevel = ranks.maxLevel or 0,
        into = rep.standing - floor,
        span = rep.nextThreshold and (rep.nextThreshold - floor) or nil, -- nil at max level
    }
end

-- Delver's Journey is a "major faction" shown as a journey with the Delve
-- reward track (Blizzard_Journeys reads it the same way). Same shape as
-- CompanionProgress; nil when the client cannot say.
local function FindJourneyFaction()
    if not (C_MajorFactions and C_MajorFactions.GetMajorFactionIDs and C_MajorFactions.GetMajorFactionData) then
        return nil
    end
    local ids = C_MajorFactions.GetMajorFactionIDs(LE_EXPANSION_LEVEL_CURRENT) or {}
    local fallback
    for _, id in ipairs(ids) do
        if C_MajorFactions.ShouldUseJourneyRewardTrack and C_MajorFactions.ShouldUseJourneyRewardTrack(id) then
            return id
        end
        if not fallback and C_MajorFactions.ShouldDisplayMajorFactionAsJourney
                and C_MajorFactions.ShouldDisplayMajorFactionAsJourney(id) then
            fallback = id
        end
    end
    return fallback
end

local function JourneyProgress()
    journeyFactionID = journeyFactionID or FindJourneyFaction()
    if not journeyFactionID or not (C_MajorFactions and C_MajorFactions.GetMajorFactionData) then
        return nil
    end
    local data = C_MajorFactions.GetMajorFactionData(journeyFactionID)
    if not data or data.isUnlocked == false or not data.renownLevelThreshold then
        return nil
    end
    local atMax = data.maxLevel and data.maxLevel > 0 and data.renownLevel >= data.maxLevel
    return {
        name = "Journey",
        level = data.renownLevel or 0,
        maxLevel = data.maxLevel or 0,
        into = data.renownReputationEarned or 0,
        span = (not atMax) and data.renownLevelThreshold or nil,
    }
end

local function Thousands(n)
    if BreakUpLargeNumbers then
        return BreakUpLargeNumbers(n)
    end
    return tostring(n)
end

local RefreshCounter -- defined with the counter below

-- The two progress tracks, each read on UPDATE_FACTION and compared with
-- the previous reading: setting = the chat line's switch, run = the run
-- total's key, last = the previous reading.
local TRACKS = {
    { setting = "companion", run = "xp", read = CompanionProgress, what = "companion progress" },
    { setting = "journey", run = "journey", read = JourneyProgress, what = "Delver's Journey progress" },
}

-- Adds a gain to the run's running total (the counter shows it) when a run
-- is active. Level-ups count the rest of the old level plus the way into
-- the new one.
local function RecordRunGain(track, pct)
    if cdb.run.active and pct >= 0.05 then
        cdb.run[track.run] = cdb.run[track.run] + pct
        RefreshCounter()
    end
end

-- If the track's progress rose, add it to the run and (when its chat line
-- is on) say what the gain was worth as a share of the level and how many
-- more like it reach the next level.
local function CheckTrack(track)
    local now = track.read()
    local before = track.last
    track.last = now
    if not now or not before then
        return
    end
    local say = db[track.setting]
    if now.level ~= before.level then
        if now.level < before.level then
            return
        end
        local rest = before.span and 100 * (before.span - before.into) / before.span or 0
        if now.span then
            RecordRunGain(track, rest + 100 * now.into / now.span)
            if say then
                Print(("%s: level up! Level %d, %.1f%% in."):format(now.name, now.level, 100 * now.into / now.span))
            end
        else
            RecordRunGain(track, rest)
            if say then
                Print(("%s: level up! Level %d, the maximum."):format(now.name, now.level))
            end
        end
        return
    end
    local gain = now.into - before.into
    if gain <= 0 then
        return
    end
    if not now.span then
        if say then
            Print(("%s: already at max level %d."):format(now.name, now.level))
        end
        return
    end
    local pct = 100 * gain / now.span
    if pct < 0.05 then
        return -- would print as +0.0%: kill credit, walk-overs; not worth a line
    end
    RecordRunGain(track, pct)
    if not say then
        return
    end
    local more = math.ceil((now.span - now.into) / gain)
    if more <= 1 then
        Print(("%s: +%.1f%%, one more levels up."):format(now.name, pct))
    else
        Print(("%s: +%.1f%%, %d more to level up."):format(now.name, pct, more))
    end
end

local function CheckTracks()
    for _, track in ipairs(TRACKS) do
        CheckTrack(track)
    end
end

-- Called on entering the world: the first reading each track is measured
-- against.
local function PrimeTracks()
    for _, track in ipairs(TRACKS) do
        track.last = track.read()
    end
end

local function TrackStatus(track)
    local c = track.read()
    if not c then
        return track.what .. " unavailable."
    end
    if not c.span then
        return ("%s is level %d, the maximum."):format(c.name, c.level)
    end
    return ("%s is level %d, %.1f%% through it (%s / %s)."):format(
        c.name, c.level, 100 * c.into / c.span, Thousands(c.into), Thousands(c.span))
end

-- ------------------------------------------------------------ widget overlay

-- The Delve tracker shows affixes as UI widget icons whose only readable
-- state is a mouse-over tooltip such as "Enemy groups remaining: 1 / 4".
-- Each widget frame carries widgetID and widgetType; the widget's data comes
-- from the type's visualization-info function (registered in Blizzard's
-- UIWidgetManager), and the tooltip mixin also keeps the text on the frame or
-- one of its children. Whichever yields "n / m", n is painted over the icon
-- in white.
local WIDGET_SCAN_DELAY = 0.5

local function TooltipRemaining(tooltip)
    if type(tooltip) ~= "string" then
        return nil
    end
    local last
    for n in tooltip:gmatch("(%d+)%s*/%s*%d+") do
        last = n
    end
    return last
end

-- First "n / m" found in any string inside a (nested) table, depth-limited.
local function RatioInTable(t, depth)
    if type(t) ~= "table" or depth > 3 then
        return nil
    end
    for _, v in pairs(t) do
        if type(v) == "string" then
            local n = TooltipRemaining(v)
            if n then
                return n, v
            end
        elseif type(v) == "table" then
            local n, text = RatioInTable(v, depth + 1)
            if n then
                return n, text
            end
        end
    end
    return nil
end

local function WidgetInfo(frame)
    local registry = UIWidgetManager and UIWidgetManager.widgetVisTypeInfo
    local typeInfo = registry and registry[frame.widgetType]
    if typeInfo and type(typeInfo.visInfoDataFunction) == "function" then
        local ok, info = pcall(typeInfo.visInfoDataFunction, frame.widgetID)
        if ok then
            return info
        end
    end
    return nil
end

-- Every tooltip string the tooltip mixin keeps on the frame or any
-- descendant (the Delves header widget holds its affix icons as children,
-- each with its own tooltip).
local function FrameTooltips(frame, depth, out)
    out = out or {}
    if type(frame.tooltip) == "string" and frame.tooltip ~= "" then
        out[#out + 1] = frame.tooltip
    end
    if depth < 5 and frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            FrameTooltips(child, depth + 1, out)
        end
    end
    return out
end

-- Descendant frame set up for this spell (UIWidgetBaseSpellTemplate keeps
-- spellID on itself), so the number can sit on the right icon.
local function SpellChild(frame, spellID, depth)
    if frame.spellID == spellID then
        return frame
    end
    if depth < 5 and frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            local found = SpellChild(child, spellID, depth + 1)
            if found then
                return found
            end
        end
    end
    return nil
end

local function SpellDescription(spellID)
    if C_Spell and C_Spell.GetSpellDescription then
        return C_Spell.GetSpellDescription(spellID)
    end
    return nil
end

-- Returns the remaining count, the text it came from, and the frame to
-- paint on (the affix icon when it can be found, else the widget), or nil.
-- Sources, in order: the widget's own data, its affix spells' live
-- descriptions, and any tooltip text kept on the frame or its descendants.
local function WidgetRemaining(frame)
    local info = WidgetInfo(frame)
    local n, text = RatioInTable(info, 0)
    if n then
        return n, text, frame
    end
    if info and type(info.spells) == "table" then
        for _, spell in ipairs(info.spells) do
            local description = spell.spellID and SpellDescription(spell.spellID)
            n = TooltipRemaining(description)
            if n then
                return n, description, SpellChild(frame, spell.spellID, 0) or frame
            end
        end
    end
    for _, tooltip in ipairs(FrameTooltips(frame, 0)) do
        n = TooltipRemaining(tooltip)
        if n then
            return n, tooltip, frame
        end
    end
    return nil
end

-- Every live UI widget frame, from the widget manager's registry of widget
-- containers (each container keeps widgetFrames[widgetID]). Never
-- EnumerateFrames: with a busy UI that exceeds the script time limit.
local function CollectContainers(t, depth, out)
    if type(t) ~= "table" or depth > 2 then
        return
    end
    if type(t.widgetFrames) == "table" then
        out[t] = true
        return
    end
    for k, v in pairs(t) do
        if type(k) == "table" and type(k.widgetFrames) == "table" then
            out[k] = true
        elseif type(v) == "table" then
            CollectContainers(v, depth + 1, out)
        end
    end
end

local function WidgetFrames()
    local list = {}
    local registry = UIWidgetManager and UIWidgetManager.registeredWidgetContainers
    local containers = {}
    CollectContainers(registry, 0, containers)
    for container in pairs(containers) do
        for _, frame in pairs(container.widgetFrames) do
            if type(frame) == "table" and frame.widgetID and frame.widgetType then
                list[#list + 1] = frame
            end
        end
    end
    return list
end

local function OverlayFor(frame)
    local text = overlays[frame]
    if not text then
        text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        text:SetPoint("CENTER", frame, "CENTER", 0, 0)
        text:SetTextColor(1, 1, 1)
        text:SetShadowColor(0, 0, 0, 1)
        text:SetShadowOffset(1, -1)
        overlays[frame] = text
    end
    return text
end

local function UpdateWidgetOverlays()
    local show = db.enabled and db.nemesis and InDelve()
    if not show then
        for _, text in pairs(overlays) do
            text:Hide()
        end
        return
    end
    local painted = {}
    for _, frame in ipairs(WidgetFrames()) do
        local remaining, _, target = WidgetRemaining(frame)
        if remaining then
            local text = OverlayFor(target)
            text:SetText(remaining)
            text:Show()
            painted[target] = true
        end
    end
    for target, text in pairs(overlays) do
        if not painted[target] then
            text:Hide()
        end
    end
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n", " / "))
end

local function DebugWidgets()
    local frames = WidgetFrames()
    local registry = UIWidgetManager and UIWidgetManager.registeredWidgetContainers
    Print(("%d widget frame(s) (widget registry %s):"):format(#frames, registry and "present" or "missing"))
    for _, frame in ipairs(frames) do
        local info = WidgetInfo(frame)
        local n, text = WidgetRemaining(frame)
        local tooltips = FrameTooltips(frame, 0)
        local infoKeys = {}
        if info then
            for k in pairs(info) do
                infoKeys[#infoKeys + 1] = tostring(k)
            end
            table.sort(infoKeys)
        end
        Print(("  widget %s type %s shown %s | remaining %s | %d tooltip(s) | info keys: %s"):format(
            tostring(frame.widgetID), tostring(frame.widgetType), frame:IsShown() and "yes" or "no",
            tostring(n), #tooltips, info and table.concat(infoKeys, ",") or "none"))
        if text then
            Print("    from: " .. Plain(text):sub(1, 120))
        end
        if info and type(info.spells) == "table" then
            for i, spell in ipairs(info.spells) do
                Print(("    spell %d: id %s | tooltip '%s' | description '%s'"):format(
                    i, tostring(spell.spellID), Plain(spell.tooltip or ""):sub(1, 60),
                    Plain(spell.spellID and SpellDescription(spell.spellID) or ""):sub(1, 90)))
            end
        end
        for i = 1, math.min(#tooltips, 6) do
            Print(("    tooltip %d: %s"):format(i, Plain(tooltips[i]):sub(1, 120)))
        end
    end
end

local function ScheduleWidgetScan()
    if widgetScanPending then
        return
    end
    widgetScanPending = true
    C_Timer.After(WIDGET_SCAN_DELAY, function()
        widgetScanPending = false
        UpdateWidgetOverlays()
    end)
end

-- ------------------------------------------------------------------ counter

local counterFrame

local function CountKnown()
    local n = 0
    for _ in pairs(cdb.run.known) do
        n = n + 1
    end
    return n
end

-- "Curiosities 3 / 11", plus "+12.3%   Journey +2.1%" (companion experience
-- and Delver's Journey progress gained this run, each as a share of a level)
-- when that is turned on.
local function CounterText()
    local text = ("Curiosities %d / %d"):format(cdb.run.collected, CountKnown())
    if not db.counterxp then
        return text
    end
    return ("%s   +%.1f%%   Journey +%.1f%%"):format(text, cdb.run.xp, cdb.run.journey)
end

function RefreshCounter()
    if not counterFrame then
        return
    end
    if db.enabled and db.counter and cdb.run.active then
        counterFrame.text:SetText(CounterText())
        counterFrame:SetWidth(math.max(150, (counterFrame.text:GetStringWidth() or 0) + 24))
        counterFrame:Show()
    else
        counterFrame:Hide()
    end
end

local function CurrentInstanceID()
    local instanceID = select(8, GetInstanceInfo())
    return instanceID or 0
end

local function StartRun()
    cdb.run = { active = true, instanceID = CurrentInstanceID(), known = {}, pos = {}, collected = 0, xp = 0, journey = 0 }
    lastPresent, named, reached = {}, {}, {}
end

local function EndRun()
    cdb.run.active = false
    lastPresent, named, reached = {}, {}, {}
end

-- Yards between the player and a map position, or nil if the client cannot
-- say (no player map position, or no world size for this map).
local function YardsFromPlayer(uiMapID, x, y)
    local here = C_Map.GetPlayerMapPosition(uiMapID, "player")
    if not here then
        return nil
    end
    local width, height = C_Map.GetMapWorldSize(uiMapID)
    if not width or not height then
        return nil
    end
    local px, py = here:GetXY()
    local dx, dy = (x - px) * width, (y - py) * height
    return math.sqrt(dx * dx + dy * dy)
end

local function WasNear(uiMapID, guid)
    if named[guid] or reached[guid] then
        return true
    end
    local pos = cdb.run.pos[guid]
    if not pos or not uiMapID then
        return false
    end
    local yards = YardsFromPlayer(uiMapID, pos[1], pos[2])
    return yards ~= nil and yards <= NEAR_YARDS
end

-- Folds this scan into the run. New curiosity GUIDs become known. A known
-- one is "gone" (collected) when it is flagged dead, or when it vanishes
-- between two consecutive scans while you were near it. Any other absence
-- is "missing": still known, and revived if it comes back.
local function UpdateRun(guids, uiMapID)
    local run = cdb.run
    local present = {}
    for _, guid in ipairs(guids) do
        present[guid] = true
        if IsCuriosityID(guid) then
            local state = run.known[guid]
            if IsDead(guid) then
                if state ~= "gone" then
                    run.collected = run.collected + 1
                end
                run.known[guid] = "gone"
            elseif state ~= "gone" then
                run.known[guid] = "seen"
                if C_VignetteInfo.GetVignetteInfo(guid) then
                    named[guid] = true
                end
                local pos = uiMapID and C_VignetteInfo.GetVignettePosition(guid, uiMapID)
                if pos then
                    local x, y = pos:GetXY()
                    run.pos[guid] = { x, y }
                end
                local uid = tracked[guid]
                if uid and TomTom and not TomTom:IsValidWaypoint(uid) then
                    reached[guid] = true -- TomTom dropped the pin: we got there
                end
            end
        end
    end
    for guid, state in pairs(run.known) do
        if not IsCuriosityID(guid) then
            run.known[guid] = nil -- ID removed via /mct id remove
            run.pos[guid] = nil
            if state == "gone" then
                run.collected = run.collected - 1
            end
        elseif not present[guid] and state == "seen" then
            if lastPresent[guid] and WasNear(uiMapID, guid) then
                run.known[guid] = "gone"
                run.collected = run.collected + 1
            else
                run.known[guid] = "missing"
            end
        end
    end
    lastPresent = present
end

local function SaveCounterPos()
    local point, _, relativePoint, x, y = counterFrame:GetPoint(1)
    db.counterPos = {
        point = point or "TOP",
        relativePoint = relativePoint or point or "TOP",
        x = x or 0,
        y = y or 0,
    }
end

local function CreateCounter()
    local f = CreateFrame("Frame", "MislaidCuriosityTomTomCounter", UIParent, "BackdropTemplate")
    f:SetSize(150, 26)
    f:SetPoint(db.counterPos.point, UIParent, db.counterPos.relativePoint, db.counterPos.x, db.counterPos.y)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.6)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveCounterPos()
    end)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.text:SetPoint("CENTER")
    f:Hide()
    return f
end

-- ---------------------------------------------------------------- waypoints

-- Two curiosities at identical coordinates share one waypoint, so a uid is
-- only removed from TomTom once no tracked vignette refers to it.
local function RemoveTracked(guid)
    local uid = tracked[guid]
    tracked[guid] = nil
    if not uid then
        return
    end
    for _, other in pairs(tracked) do
        if other == uid then
            return
        end
    end
    if TomTom and TomTom:IsValidWaypoint(uid) then
        TomTom:RemoveWaypoint(uid)
    end
end

local function OurWaypointAt(uiMapID, x, y)
    for _, uid in pairs(tracked) do
        if uid and uid[1] == uiMapID and uid[2] == x and uid[3] == y then
            return uid
        end
    end
    return nil
end

local function ClearAll()
    for guid in pairs(tracked) do
        RemoveTracked(guid)
    end
    for guid in pairs(foreign) do
        foreign[guid] = nil
    end
end

local function LiveWaypoints()
    local live, listed = {}, {}
    for _, uid in pairs(tracked) do
        if uid and not listed[uid] and TomTom and TomTom:IsValidWaypoint(uid) then
            listed[uid] = true
            live[#live + 1] = uid
        end
    end
    return live
end

-- Point the TomTom arrow at the nearest of our waypoints, but only if the
-- arrow is idle: never steal it from a waypoint the player chose. Without a
-- player position "nearest" is unknowable, so then only a lone waypoint is
-- chosen.
local function PointArrow(uiMapID)
    if not TomTom:IsCrazyArrowEmpty() then
        return
    end
    local live = LiveWaypoints()
    local best
    local here = C_Map.GetPlayerMapPosition(uiMapID, "player")
    if here then
        local px, py = here:GetXY()
        local bestDist
        for _, uid in ipairs(live) do
            local dx, dy = uid[2] - px, uid[3] - py
            local dist = dx * dx + dy * dy
            if not bestDist or dist < bestDist then
                best, bestDist = uid, dist
            end
        end
    elseif #live == 1 then
        best = live[1]
    end
    if best then
        TomTom:SetCrazyArrow(best, TomTom.profile.arrow.arrival, best.title)
    end
end

-- Waypoints follow the run state: a "gone" curiosity loses its waypoint, a
-- "missing" one keeps it (it is probably just out of range), and one that is
-- present without a waypoint gets one as soon as it has a position.
local function UpdateWaypoints()
    local uiMapID = C_Map.GetBestMapForUnit("player")
    if not uiMapID then
        return
    end

    local run = cdb.run
    local added = 0
    for guid in pairs(tracked) do
        if run.known[guid] == nil or run.known[guid] == "gone" then
            RemoveTracked(guid)
        end
    end
    for guid, state in pairs(run.known) do
        -- A foreign waypoint we deferred to may have been removed since.
        local spot = foreign[guid]
        if spot and not TomTom:WaypointExists(spot[1], spot[2], spot[3], WAYPOINT_TITLE) then
            foreign[guid] = nil
        end
        if tracked[guid] == nil and foreign[guid] == nil and state == "seen" and lastPresent[guid] then
            local pos = C_VignetteInfo.GetVignettePosition(guid, uiMapID)
            if pos then
                local x, y = pos:GetXY()
                local shared = OurWaypointAt(uiMapID, x, y)
                if shared then
                    tracked[guid] = shared -- same spot as another curiosity
                elseif TomTom:WaypointExists(uiMapID, x, y, WAYPOINT_TITLE) then
                    foreign[guid] = { uiMapID, x, y } -- someone else's; leave it alone
                else
                    local uid = TomTom:AddWaypoint(uiMapID, x, y, {
                        title = WAYPOINT_TITLE,
                        from = ADDON_TITLE,
                        persistent = false,
                        minimap = true,
                        world = true,
                        crazy = false,
                        cleardistance = db.cleardistance, -- 0 keeps the pin until looted
                        silent = true, -- we print our own line, subject to /mct quiet
                    })
                    if uid then
                        tracked[guid] = uid
                        added = added + 1
                        if not db.quiet then
                            Print(("%s spotted, waypoint set at %.1f, %.1f."):format(
                                WAYPOINT_TITLE, x * 100, y * 100))
                        end
                    end
                end
            end
        end
    end

    if added > 0 then
        PointArrow(uiMapID)
    end
end

local function Scan()
    if not InDelve() then
        if cdb.run.active then
            EndRun()
        end
        ClearAll()
        RefreshCounter()
        ScheduleWidgetScan()
        return
    end
    if not db.enabled then
        -- Switched off mid-run: drop the waypoints, keep the run's numbers.
        ClearAll()
        RefreshCounter()
        return
    end
    if not cdb.run.active or cdb.run.instanceID ~= CurrentInstanceID() then
        StartRun()
    end
    UpdateRun(C_VignetteInfo.GetVignettes(), C_Map.GetBestMapForUnit("player"))
    RefreshCounter()
    if TomTom then
        UpdateWaypoints()
    end
    ScheduleWidgetScan()
end

local pending = false
local function ScheduleScan()
    if pending then
        return
    end
    pending = true
    C_Timer.After(SCAN_DELAY, function()
        pending = false
        Scan()
    end)
end

-- ------------------------------------------------------------------ commands

local function OnOff(value)
    return value and "on" or "off"
end

local function Status()
    local run = ("%s run: %d collected of %d known."):format(
        cdb.run.active and "this" or "last", cdb.run.collected, CountKnown())
    if not TomTom then
        Print(("enabled %s, counter %s, quiet %s, %s %s"):format(
            OnOff(db.enabled), OnOff(db.counter), OnOff(db.quiet), run, NO_TOMTOM))
        return
    end
    Print(("enabled %s, counter %s, quiet %s, pins clear at %d yards, %d waypoint(s) active, %s"):format(
        OnOff(db.enabled), OnOff(db.counter), OnOff(db.quiet), db.cleardistance, #LiveWaypoints(), run))
    Print(("companion line %s, journey line %s, xp on counter %s (+%.1f%% / journey +%.1f%% this run), nemesis number %s."):format(
        OnOff(db.companion), OnOff(db.journey), OnOff(db.counterxp), cdb.run.xp, cdb.run.journey, OnOff(db.nemesis)))
    Print(TrackStatus(TRACKS[1]) .. " " .. TrackStatus(TRACKS[2]))
end

local function Debug()
    local name, instanceType, difficultyID = GetInstanceInfo()
    local uiMapID = C_Map.GetBestMapForUnit("player")
    Print(("instance '%s' type %s difficulty %s, uiMapID %s, in Delve %s, TomTom %s."):format(
        tostring(name), tostring(instanceType), tostring(difficultyID), tostring(uiMapID),
        tostring(InDelve()), tostring(TomTom ~= nil)))
    local ids = C_MajorFactions and C_MajorFactions.GetMajorFactionIDs
        and C_MajorFactions.GetMajorFactionIDs(LE_EXPANSION_LEVEL_CURRENT) or {}
    local list = {}
    for i, id in ipairs(ids) do
        local data = C_MajorFactions.GetMajorFactionData(id)
        list[i] = ("%d '%s'"):format(id, data and data.name or "?")
    end
    Print(("journey faction %s; major factions: %s"):format(tostring(journeyFactionID or FindJourneyFaction()),
        #list > 0 and table.concat(list, ", ") or "none"))
    local guids = C_VignetteInfo.GetVignettes()
    Print(("%d vignette(s):"):format(#guids))
    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        local pos = uiMapID and C_VignetteInfo.GetVignettePosition(guid, uiMapID)
        local where = "no position"
        if pos then
            local x, y = pos:GetXY()
            where = ("%.1f, %.1f"):format(x * 100, y * 100)
        end
        local what = "mystery (no info)"
        if info then
            what = ("%s [%s]%s"):format(tostring(info.name), tostring(info.atlasName),
                info.isDead and " dead" or "")
        end
        Print(("  id %s | %s | %s%s"):format(tostring(VignetteID(guid)), what, where,
            tracked[guid] and " | tracked" or (foreign[guid] and " | foreign waypoint" or "")))
    end
    DebugWidgets()
end

local function IdCommand(arg, value)
    local id = tonumber(value)
    if arg == "add" and id then
        db.ids[id] = true
        Print(("vignette ID %d added."):format(id))
    elseif arg == "remove" and id then
        db.ids[id] = nil
        Print(("vignette ID %d removed."):format(id))
    else
        local list = {}
        for known in pairs(CURIOSITY_IDS) do
            list[#list + 1] = tostring(known)
        end
        for extra in pairs(db.ids) do
            list[#list + 1] = tostring(extra) .. " (added)"
        end
        table.sort(list)
        Print("vignette IDs treated as Mislaid Curiosity: " .. table.concat(list, ", "))
    end
    Scan()
end

local function CounterCommand(arg)
    if arg == "on" or arg == "off" then
        db.counter = (arg == "on")
    elseif arg == "reset" then
        if cdb.run.active then
            StartRun()
        end
        Print("run counter reset.")
    else
        db.counter = not db.counter
    end
    Scan()
    Status()
end

local USAGE = "usage: /mct on|off, /mct counter [on|off|reset], /mct xp [on|off], /mct companion [on|off], /mct journey [on|off], /mct nemesis [on|off], /mct distance <yards>, /mct quiet [on|off], /mct clear, /mct scan, /mct debug, /mct id [add|remove <n>]"

local TOGGLES = { companion = "companion", journey = "journey", nemesis = "nemesis", xp = "counterxp" }

local function SlashHandler(msg)
    local cmd, arg, value = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)%s*(%S*)")
    if cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Scan()
        Status()
    elseif cmd == "counter" then
        CounterCommand(arg)
    elseif TOGGLES[cmd] then
        local key = TOGGLES[cmd]
        if arg == "on" or arg == "off" then
            db[key] = (arg == "on")
        else
            db[key] = not db[key]
        end
        if cmd == "nemesis" then
            UpdateWidgetOverlays()
        elseif cmd == "xp" then
            RefreshCounter()
        end
        Status()
    elseif cmd == "distance" then
        local yards = tonumber(arg)
        if yards and yards >= 0 then
            db.cleardistance = math.floor(yards)
            Print(("pins now clear at %d yards (applies to new pins)."):format(db.cleardistance))
        else
            Print("usage: /mct distance <yards>, 0 keeps pins until looted.")
        end
        Status()
    elseif cmd == "quiet" then
        if arg == "on" or arg == "off" then
            db.quiet = (arg == "on")
        else
            db.quiet = not db.quiet
        end
        Status()
    elseif cmd == "clear" then
        ClearAll()
        Status()
    elseif cmd == "scan" then
        Scan()
        Status()
    elseif cmd == "debug" then
        Debug()
    elseif cmd == "id" then
        IdCommand(arg, value)
    else
        Status()
        Print(USAGE)
    end
end

-- ------------------------------------------------------------------- options

-- Esc > Options > AddOns > Mislaid Curiosity TomTom: one tick box per
-- setting and a drop-down for the clear distance, all changing live. Proxy
-- settings read and write our saved table directly, so the panel and /mct
-- always agree. Missing or changed Blizzard API: the panel is skipped and
-- /mct still works.
local OPTIONS = {
    { key = "enabled", label = "Set TomTom waypoints",
      tooltip = "Set a TomTom waypoint for every Mislaid Curiosity in a Delve. Off removes the waypoints and hides the counter.",
      apply = function() Scan() end },
    { key = "announce", label = "Announce found curiosities",
      tooltip = "Say in chat when a curiosity is found: where it is and that a waypoint was set." },
    { key = "companion", label = "Announce companion XP",
      tooltip = "Say in chat when your companion gains experience: what it was worth as a percentage of the level, and how many more like it reach the next." },
    { key = "journey", label = "Announce Journey progress",
      tooltip = "Say in chat when your Delver's Journey progresses: what it was worth as a percentage of the level, and how many more like it reach the next." },
    { key = "counter", label = "Show the run counter",
      tooltip = "The movable \"Curiosities collected / known\" box shown inside Delves.",
      apply = function() RefreshCounter() end },
    { key = "counterxp", label = "Counter shows run totals",
      tooltip = "Adds \"+12.3%   Journey +2.1%\": companion experience and Delver's Journey progress gained this run, each as a share of a level.",
      apply = function() RefreshCounter() end },
    { key = "nemesis", label = "Groups remaining on tracker",
      tooltip = "Paint the Nemesis Influence \"enemy groups remaining\" number on its Delve tracker icon, so no mouse-over is needed.",
      apply = function() UpdateWidgetOverlays() end },
}

-- "announce" is the panel's view of the stored `quiet` flag.
local function GetOption(key)
    if key == "announce" then
        return not db.quiet
    end
    return db[key] == true
end

local function DefaultOption(key)
    if key == "announce" then
        return not DEFAULTS.quiet
    end
    return DEFAULTS[key] == true
end

local function SetOption(key, value)
    if key == "announce" then
        db.quiet = not value
    else
        db[key] = value and true or false
    end
end

local function RegisterOptions()
    local category = Settings.RegisterVerticalLayoutCategory(ADDON_TITLE)
    for _, o in ipairs(OPTIONS) do
        local setting = Settings.RegisterProxySetting(category, "MislaidCuriosityTomTom_" .. o.key,
            Settings.VarType.Boolean, o.label, DefaultOption(o.key) and Settings.Default.True or Settings.Default.False,
            function() return GetOption(o.key) end,
            function(value)
                SetOption(o.key, value)
                if o.apply then
                    o.apply()
                end
            end)
        Settings.CreateCheckbox(category, setting, o.tooltip)
    end
    local distance = Settings.RegisterProxySetting(category, "MislaidCuriosityTomTom_cleardistance",
        Settings.VarType.Number, "Pin clear distance", DEFAULTS.cleardistance,
        function() return db.cleardistance end,
        function(value) db.cleardistance = math.floor(value) end)
    local function DistanceChoices()
        local container = Settings.CreateControlTextContainer()
        container:Add(0, "Off (keep until looted)")
        container:Add(5, "5 yards")
        container:Add(10, "10 yards")
        return container:GetData()
    end
    Settings.CreateDropdown(category, distance, DistanceChoices,
        "TomTom drops a curiosity's pin when you get this close. Off keeps the pin until the curiosity is looted. Applies to new pins; /mct distance <yards> allows any number.")
    Settings.RegisterAddOnCategory(category)
end

local function SetupOptions()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
            and Settings.CreateCheckbox and Settings.CreateDropdown and Settings.CreateControlTextContainer
            and Settings.RegisterAddOnCategory and Settings.VarType and Settings.Default) then
        return
    end
    local ok, err = pcall(RegisterOptions)
    if not ok then
        Print("options panel unavailable (" .. tostring(err) .. "); /mct still works.")
    end
end

-- -------------------------------------------------------------------- events

local function CopyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            CopyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then
            return
        end
        MislaidCuriosityTomTomDB = MislaidCuriosityTomTomDB or {}
        db = MislaidCuriosityTomTomDB
        CopyDefaults(db, DEFAULTS)
        MislaidCuriosityTomTomCharDB = MislaidCuriosityTomTomCharDB or {}
        cdb = MislaidCuriosityTomTomCharDB
        CopyDefaults(cdb, CHAR_DEFAULTS)
        counterFrame = CreateCounter()
        SetupOptions()
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("VIGNETTES_UPDATED")
        self:RegisterEvent("VIGNETTE_MINIMAP_UPDATED")
        self:RegisterEvent("UPDATE_FACTION")
        self:RegisterEvent("MAJOR_FACTION_RENOWN_LEVEL_CHANGED")
        self:RegisterEvent("UPDATE_UI_WIDGET")
        return
    end
    if event == "UPDATE_FACTION" or event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
        CheckTracks()
        return
    end
    if event == "UPDATE_UI_WIDGET" then
        ScheduleWidgetScan()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        CheckTomTom()
        PrimeTracks()
        -- (isInitialLogin, isReloadingUi): a saved run survives a /reload
        -- only. A real login inside a Delve starts over, since the instance
        -- map ID cannot tell one copy of a Delve from another.
        if arg1 and not arg2 then
            EndRun()
        end
    end
    ScheduleScan()
end)

SLASH_MISLAIDCURIOSITYTOMTOM1 = "/mct"
SLASH_MISLAIDCURIOSITYTOMTOM2 = "/mislaidcuriosity"
SlashCmdList.MISLAIDCURIOSITYTOMTOM = SlashHandler

-- Exposed for tests/run.lua only.
ns.Scan = Scan
ns.ClearAll = ClearAll
ns.VignetteID = VignetteID
ns.SlashHandler = SlashHandler
ns.GetTracked = function() return tracked end
ns.GetForeign = function() return foreign end
ns.GetCounterFrame = function() return counterFrame end
ns.GetOverlays = function() return overlays end
ns.TooltipRemaining = TooltipRemaining
ns.WidgetRemaining = WidgetRemaining
ns.frame = frame
