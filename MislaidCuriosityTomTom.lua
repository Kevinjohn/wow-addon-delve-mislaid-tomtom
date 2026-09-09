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
    cleardistance = 5, -- yards from a curiosity at which TomTom drops its pin; 0 = keep until looted
    ids = {},        -- extra vignette IDs, [id] = true
    counterPos = { point = "TOP", relativePoint = "TOP", x = 0, y = -120 },
}

-- Per-character saved variables: the current Delve run, kept so a /reload
-- mid-run keeps the numbers. known = [guid] = "seen" | "missing" | "gone";
-- pos = [guid] = { x, y } last known map position; collected = number of
-- "gone"; instanceID is the instance map ID, a sanity check only (copies of
-- the same Delve share it), so a saved run is also ended on any real login:
-- it survives a /reload and nothing else.
local CHAR_DEFAULTS = {
    run = { active = false, instanceID = 0, known = {}, pos = {}, collected = 0 },
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

-- ------------------------------------------------------------------ counter

local counterFrame

local function CountKnown()
    local n = 0
    for _ in pairs(cdb.run.known) do
        n = n + 1
    end
    return n
end

local function RefreshCounter()
    if not counterFrame then
        return
    end
    if db.enabled and db.counter and cdb.run.active then
        counterFrame.text:SetText(("Curiosities %d / %d"):format(cdb.run.collected, CountKnown()))
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
    cdb.run = { active = true, instanceID = CurrentInstanceID(), known = {}, pos = {}, collected = 0 }
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
end

local function Debug()
    local name, instanceType, difficultyID = GetInstanceInfo()
    local uiMapID = C_Map.GetBestMapForUnit("player")
    Print(("instance '%s' type %s difficulty %s, uiMapID %s, in Delve %s, TomTom %s."):format(
        tostring(name), tostring(instanceType), tostring(difficultyID), tostring(uiMapID),
        tostring(InDelve()), tostring(TomTom ~= nil)))
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

local USAGE = "usage: /mct on|off, /mct counter [on|off|reset], /mct distance <yards>, /mct quiet [on|off], /mct clear, /mct scan, /mct debug, /mct id [add|remove <n>]"

local function SlashHandler(msg)
    local cmd, arg, value = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)%s*(%S*)")
    if cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Scan()
        Status()
    elseif cmd == "counter" then
        CounterCommand(arg)
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
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("VIGNETTES_UPDATED")
        self:RegisterEvent("VIGNETTE_MINIMAP_UPDATED")
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        CheckTomTom()
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
ns.frame = frame
