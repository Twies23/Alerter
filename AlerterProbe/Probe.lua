-- AlerterProbe / Probe.lua -----------------------------------------------------
-- A throwaway capability probe for verifying what an addon can actually SEE about
-- enemy (trash) casts in 12.1. It does not alert on anything -- it just captures
-- each hostile-NPC cast and records every field the Alerter design leans on, so
-- we can turn the CAPABILITIES.md rows from untested into fact.
--
-- For each enemy cast it logs:
--   * source: NPC id + name (parsed from GUID)
--   * spell: id + name, sub-event (START vs SUCCESS)
--   * target resolution (B1-B5): is there a destGUID? is it ME / a party member /
--     some player / an NPC / nothing? and HOW we learned it (clog dest, aura, or
--     the caster nameplate's target)
--   * interruptible (A4/F3): read from the caster's nameplate UnitCastingInfo,
--     since the combat log has no interruptible field at cast start
--   * cast time (A3), channel vs cast (A5)
--   * secret-value flags (D1/D3): whether key reads came back secret in combat
--   * volume (G1): casts captured and a rolling casts/sec
--
-- Slash: /aprobe  (toggle window) | casts [n] | targeted | all | clear | copy |
--        boss  (enumerate boss-mod globals, E1/E2) | help
--------------------------------------------------------------------------------

local ADDON, P = ...
_G.AlerterProbe = P

--------------------------------------------------------------------------------
-- Constants / safe helpers
--------------------------------------------------------------------------------
local NPC     = COMBATLOG_OBJECT_TYPE_NPC       or 0x00000800
local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040
-- Robust bitwise AND: prefer the classic `bit` lib, fall back to bit32 or a pure
-- Lua implementation so a missing library can never silently break the filter.
local band = (bit and bit.band) or (bit32 and bit32.band) or function(a, b)
    local r, m = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
end

-- Diagnostic counters (surfaced in the window header) so we can see exactly where
-- events are dropping: total CLEU seen -> cast events -> hostile-NPC filtered.
local diag = { cleu = 0, cast = 0, npc = 0, err = nil }

local issecret = issecretvalue or issecret
local function IsSecret(v)
    if not issecret then return false end
    local ok, s = pcall(issecret, v)
    return ok and s or false
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and n then return n end
    end
    return "spell:" .. tostring(id)
end

local playerGUID  -- resolved at login

-- Parse the numeric NPC id out of a "Creature-0-...-<npcID>-<spawn>" GUID.
local function NpcID(guid)
    if not guid then return nil end
    local id = guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return id and tonumber(id) or nil
end

local function GuidKind(guid)
    if not guid or guid == "" then return "none" end
    return (guid:match("^(%a+)") or "?")
end

--------------------------------------------------------------------------------
-- Live nameplate map: GUID -> unit token. Lets us read the caster's cast bar
-- (for the interruptible flag + a target-of-caster candidate) from the combat
-- log source, which CLEU alone can't give us.
--------------------------------------------------------------------------------
local plateOf = {}   -- guid -> "nameplateN"

local function OnPlateAdded(unit)
    local g = UnitGUID(unit)
    if g then plateOf[g] = unit end
end
local function OnPlateRemoved(unit)
    local g = UnitGUID(unit)
    if g then plateOf[g] = nil end
    -- also sweep any stale token pointing at this unit
    for guid, u in pairs(plateOf) do if u == unit then plateOf[guid] = nil end end
end

-- Read the caster's current cast off its nameplate: interruptible + duration +
-- channel flag, each with a secret check. Returns a small table or nil.
local function ReadCasterBar(guid)
    local unit = plateOf[guid]
    if not unit then return nil end
    local name, _, _, startMs, endMs, _, _, notInterruptible, spellId = UnitCastingInfo(unit)
    local channel = false
    if not name then
        name, _, _, startMs, endMs, _, notInterruptible, spellId = UnitChannelInfo(unit)
        channel = name ~= nil
    end
    if not name then return { unit = unit } end   -- unit known but no cast read
    local dur
    if startMs and endMs and not IsSecret(startMs) and not IsSecret(endMs) then
        dur = (endMs - startMs) / 1000
    end
    return {
        unit          = unit,
        channel       = channel,
        castTime      = dur,
        castTimeSecret= IsSecret(startMs) or IsSecret(endMs),
        interruptible = (notInterruptible ~= nil) and (not notInterruptible) or nil,
        interruptSecret = IsSecret(notInterruptible),
    }
end

-- Candidate B3: who is the caster targeting? nameplate target token.
local function CasterTargetGUID(guid)
    local unit = plateOf[guid]
    if not unit then return nil end
    local ok, tg = pcall(UnitGUID, unit .. "target")
    if ok then return tg end
    return nil
end

--------------------------------------------------------------------------------
-- Target classification (B1-B5)
--------------------------------------------------------------------------------
local function ClassifyTarget(guid)
    if not guid or guid == "" then return "none", "grey" end
    if guid == playerGUID then return "ME", "me" end
    for i = 1, 4 do
        if UnitGUID("party" .. i) == guid then return "party" .. i, "party" end
    end
    local kind = GuidKind(guid)
    if kind == "Player" then return "player", "party" end
    return kind, "npc"   -- Creature / Vehicle / Pet / ...
end

--------------------------------------------------------------------------------
-- Capture buffer (persisted so a /reload keeps the sample for export)
--------------------------------------------------------------------------------
local MAX = 800
local rows = {}          -- newest last
local total = 0
local rate  = { }        -- rolling timestamps for casts/sec

local function pushRow(r)
    rows[#rows + 1] = r
    if #rows > MAX then table.remove(rows, 1) end
    total = total + 1
    local now = GetTime()
    rate[#rate + 1] = now
    -- drop samples older than 1s
    while rate[1] and now - rate[1] > 1 do table.remove(rate, 1) end
    if AlerterProbeDB then AlerterProbeDB.rows = rows; AlerterProbeDB.total = total end
end

--------------------------------------------------------------------------------
-- Combat log capture -- hostile NPC SPELL_CAST_START / SPELL_CAST_SUCCESS
--------------------------------------------------------------------------------
local WATCH = { SPELL_CAST_START = "START", SPELL_CAST_SUCCESS = "SUCC" }

local function OnCombatLog()
    diag.cleu = diag.cleu + 1
    local t, sub, _, sguid, sname, sflags, _, dguid, dname, dflags = CombatLogGetCurrentEventInfo()
    local tag = WATCH[sub]
    if not tag then return end
    diag.cast = diag.cast + 1
    if not (sflags and band(sflags, NPC) > 0 and band(sflags, HOSTILE) > 0) then return end
    diag.npc = diag.npc + 1

    local spellId, spellName = select(12, CombatLogGetCurrentEventInfo())

    local bar   = ReadCasterBar(sguid)
    -- Target: prefer the combat-log dest; fall back to the caster's nameplate target.
    local tgtGuid, how = dguid, "clog"
    if (not tgtGuid or tgtGuid == "") then
        local ct = CasterTargetGUID(sguid)
        if ct and ct ~= "" then tgtGuid, how = ct, "plateTgt" end
    end
    local tgtLabel, tgtColor = ClassifyTarget(tgtGuid)

    pushRow({
        clock   = date("%H:%M:%S"),
        gt      = GetTime(),
        tag     = tag,
        npcId   = NpcID(sguid),
        srcName = sname or "?",
        spellId = spellId,
        spellNm = spellName or SpellName(spellId),
        dur     = bar and bar.castTime,
        durSec  = bar and bar.castTimeSecret,
        channel = bar and bar.channel,
        kick    = bar and bar.interruptible,   -- true/false/nil(unknown)
        kickSec = bar and bar.interruptSecret,
        haveBar = bar ~= nil,
        plate   = bar and bar.unit,
        tgtGuid = tgtGuid,
        tgtName = dname,
        tgtLbl  = tgtLabel,
        tgtCol  = tgtColor,
        tgtHow  = (tgtGuid and tgtGuid ~= "") and how or "none",
        combat  = InCombatLockdown(),
    })
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------
local COL = {
    me    = "|cffe0685a", party = "|cffe0a03a", npc = "|cff7f8c99",
    grey  = "|cff5a6a76", head  = "|cffffffff", accent = "|cff0cd29f",
    dim   = "|cff9fb0be", warn  = "|cffe0a03a",
}
local R = "|r"

local function kickText(r)
    if r.kickSec then return COL.warn .. "?sec" .. R end
    if r.kick == true then return COL.accent .. "KICK" .. R end
    if r.kick == false then return COL.grey .. "no" .. R end
    if not r.haveBar then return COL.grey .. "noplate" .. R end
    return COL.grey .. "?" .. R
end

local function durText(r)
    if r.durSec then return COL.warn .. "sec" .. R end
    if r.dur then return string.format("%.1fs", r.dur) end
    return "-"
end

-- One compact display line for the window.
local function lineFor(r)
    local col = COL[r.tgtCol] or COL.grey
    return string.format(
        "%s%s%s %s%-5s%s %s#%s %s%-22s%s %s ct:%s %s %stgt:%s%s%s(%s)",
        COL.grey, r.clock, R,
        (r.tag == "START") and COL.dim or COL.grey, r.tag, R,
        COL.grey, tostring(r.npcId or "?"),
        COL.head, (r.spellNm or "?"):sub(1, 22), R,
        R, durText(r),
        kickText(r),
        R, col, r.tgtLbl, R, r.tgtHow
    )
end

-- Full TSV row for export (all the raw fields, nothing colored).
local function tsvFor(r)
    return table.concat({
        r.clock, r.tag, tostring(r.npcId or ""), r.srcName or "",
        tostring(r.spellId or ""), r.spellNm or "",
        r.dur and string.format("%.2f", r.dur) or (r.durSec and "SECRET" or ""),
        r.channel and "channel" or "cast",
        (r.kick == true and "yes") or (r.kick == false and "no")
            or (r.kickSec and "SECRET") or (r.haveBar and "unknown" or "noplate"),
        r.tgtLbl or "", r.tgtHow or "", r.tgtName or "", r.tgtGuid or "",
        r.combat and "combat" or "ooc",
    }, "\t")
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------
local win, lines, headFS, frozen = nil, {}, nil, false
local LINES = 26
local filterTargeted = false

local function Refresh()
    if not (win and win:IsShown()) or frozen then return end
    local shown, n = {}, 0
    for i = #rows, 1, -1 do
        local r = rows[i]
        if (not filterTargeted) or (r.tgtCol == "me" or r.tgtCol == "party") then
            n = n + 1
            shown[n] = lineFor(r)
            if n >= LINES then break end
        end
    end
    for i = 1, LINES do lines[i]:SetText(shown[i] or "") end
    headFS:SetText(string.format(
        "%scaptured %d%s  %s%.0f/s%s  %sshown:%s%s  %s  %s%s  %scleu:%d cast:%d npc:%d%s%s",
        COL.accent, total, R,
        COL.dim, #rate, R,
        COL.grey, R, (filterTargeted and (COL.party .. "targeted-only" .. R) or "all"),
        frozen and (COL.warn .. "FROZEN" .. R) or "",
        InCombatLockdown() and (COL.dim .. "in-combat" .. R) or (COL.grey .. "ooc" .. R), "",
        COL.dim, diag.cleu, diag.cast, diag.npc, R,
        diag.err and ("  " .. COL.me .. "ERR:" .. diag.err:sub(1, 60) .. R) or ""
    ))
end

local function MakeButton(parent, label, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 70, 20); b:SetText(label); b:SetScript("OnClick", onClick)
    return b
end

local copyBox
local function ShowCopy()
    if not copyBox then
        local f = CreateFrame("Frame", "AlerterProbeCopy", UIParent, "BackdropTemplate")
        f:SetSize(560, 400); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        f:SetBackdropColor(0.05, 0.07, 0.09, 0.97); f:SetBackdropBorderColor(0, 0, 0, 1)
        f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
        local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 10, -30); sf:SetPoint("BOTTOMRIGHT", -30, 34)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal); eb:SetWidth(510)
        eb:SetAutoFocus(false); eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb); f.eb = eb
        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", 12, -12); hint:SetText("Ctrl+A then Ctrl+C to copy. TSV: clock, tag, npc, src, spellID, spell, cast, type, kick, tgt, how, tgtName, tgtGUID, combat")
        MakeButton(f, "Close", 70, function() f:Hide() end):SetPoint("BOTTOMRIGHT", -10, 8)
        copyBox = f
    end
    local out = { "clock\ttag\tnpcID\tsource\tspellID\tspell\tcastTime\ttype\tkick\ttarget\thow\ttgtName\ttgtGUID\tcombat" }
    for _, r in ipairs(rows) do out[#out + 1] = tsvFor(r) end
    copyBox.eb:SetText(table.concat(out, "\n"))
    copyBox:Show(); copyBox.eb:HighlightText(); copyBox.eb:SetFocus()
end

local function BuildWindow()
    if win then return end
    win = CreateFrame("Frame", "AlerterProbeWindow", UIParent, "BackdropTemplate")
    win:SetSize(720, 470); win:SetPoint("CENTER", 0, 120); win:SetFrameStrata("DIALOG")
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    win:SetBackdropColor(0.04, 0.055, 0.07, 0.96); win:SetBackdropBorderColor(0, 0, 0, 1)
    win:EnableMouse(true); win:SetMovable(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10); title:SetText(COL.accent .. "Alerter Probe" .. R .. COL.grey .. "  enemy trash casts" .. R)

    headFS = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headFS:SetPoint("TOPLEFT", 12, -30)

    -- buttons across the top-right
    local x = -10
    local bClose = MakeButton(win, "Close", 60, function() win:Hide() end); bClose:SetPoint("TOPRIGHT", x, -8); x = x - 64
    local bCopy  = MakeButton(win, "Copy",  60, ShowCopy);                   bCopy:SetPoint("TOPRIGHT", x, -8);  x = x - 64
    local bClear = MakeButton(win, "Clear", 60, function() wipe(rows); total = 0; Refresh() end); bClear:SetPoint("TOPRIGHT", x, -8); x = x - 64
    local bFreeze= MakeButton(win, "Freeze",60, function(self) frozen = not frozen; self:SetText(frozen and "Resume" or "Freeze"); Refresh() end); bFreeze:SetPoint("TOPRIGHT", x, -8); x = x - 64
    local bFilt  = MakeButton(win, "Targeted", 76, function(self) filterTargeted = not filterTargeted; self:SetText(filterTargeted and "Show all" or "Targeted"); Refresh() end); bFilt:SetPoint("TOPRIGHT", x, -8)

    local body = CreateFrame("Frame", nil, win)
    body:SetPoint("TOPLEFT", 12, -50); body:SetPoint("BOTTOMRIGHT", -12, 12)
    for i = 1, LINES do
        local fs = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 0, -(i - 1) * 15); fs:SetJustifyH("LEFT")
        fs:SetFont("Fonts\\ARIALN.TTF", 12, "")
        lines[i] = fs
    end

    win:SetScript("OnUpdate", function(self, dt)
        self._t = (self._t or 0) + dt
        if self._t > 0.15 then self._t = 0; Refresh() end
    end)
end

local function Toggle()
    BuildWindow()
    if win:IsShown() then win:Hide() else win:Show(); Refresh() end
end

--------------------------------------------------------------------------------
-- Chat dumps / boss-mod probe
--------------------------------------------------------------------------------
local function pr(msg) print(COL.accent .. "AProbe|r " .. msg) end

local function DumpCasts(n)
    n = tonumber(n) or 15
    local start = math.max(1, #rows - n + 1)
    pr(string.format("last %d of %d captured:", math.min(n, #rows), total))
    for i = start, #rows do print("  " .. lineFor(rows[i])) end
end

local function ProbeBoss()
    pr("boss-mod source probe (E1/E2):")
    local function chk(name, v) print(string.format("  %-26s %s", name, v and (COL.accent .. "present" .. R) or (COL.grey .. "nil" .. R))) end
    chk("BigWigs (global)", _G.BigWigs)
    chk("BigWigsLoader", _G.BigWigsLoader)
    chk("DBM (global)", _G.DBM)
    chk("C_EncounterJournal", _G.C_EncounterJournal)
    chk("C_EncounterInfo", _G.C_EncounterInfo)
    chk("C_AddOns.IsAddOnLoaded BigWigs",
        C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("BigWigs"))
    -- scan for any built-in boss/encounter mod namespace
    local hits = {}
    for k in pairs(_G) do
        if type(k) == "string" and (k:find("BossMod") or k:find("EncounterMod") or k == "C_BossMod") then
            hits[#hits + 1] = k
        end
    end
    pr("globals matching Boss/EncounterMod: " .. (next(hits) and table.concat(hits, ", ") or COL.grey .. "none" .. R))
end

--------------------------------------------------------------------------------
-- Events + slash
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local ok, err = pcall(OnCombatLog)
        if not ok then
            diag.err = tostring(err)
            if not P._errShown then
                P._errShown = true
                pr("|cffe0685aCLEU handler error:|r " .. diag.err)
            end
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        OnPlateAdded(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnPlateRemoved(arg1)
    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
    elseif event == "ADDON_LOADED" and arg1 == ADDON then
        AlerterProbeDB = AlerterProbeDB or {}
        -- start each session fresh; the SV is only so a mid-session /reload keeps data
        rows = {}; total = 0
        pr("loaded. |cffffffff/aprobe|r to open. Enable enemy nameplates for interrupt + target reads.")
        pr(("diag: band=%s NPC=0x%x HOSTILE=0x%x issecret=%s")
            :format((bit and bit.band) and "bit" or (bit32 and "bit32" or "purelua"),
                    NPC, HOSTILE, issecret and "yes" or "no"))
    end
end)

SLASH_APROBE1 = "/aprobe"
SlashCmdList.APROBE = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "show" or cmd == "toggle" then Toggle()
    elseif cmd == "casts" then DumpCasts(rest)
    elseif cmd == "targeted" then filterTargeted = true; Toggle()
    elseif cmd == "all" then filterTargeted = false; Refresh()
    elseif cmd == "clear" then wipe(rows); total = 0; Refresh(); pr("cleared.")
    elseif cmd == "copy" then ShowCopy()
    elseif cmd == "boss" then ProbeBoss()
    else
        pr("commands: |cffffffffshow|r toggle window · |cffffffffcasts [n]|r dump to chat · "
            .. "|cfffffffftargeted|r players-only · |cffffffffall|r · |cffffffffclear|r · "
            .. "|cffffffffcopy|r export TSV · |cffffffffboss|r boss-mod probe")
    end
end
