-- HamingwaysDPSmate v0.0.5
-- Group/Raid DPS meter for WoW 1.12 (Turtle WoW)
-- Main window: all players sorted by damage, pet damage merged into owner.
-- Detail window: click a player bar to see their spell breakdown.
-- Tracks Current (this fight) and Overall (all fights) segments.

HamingwaysDPSmateDB = HamingwaysDPSmateDB or {}

-- ============================================================================
-- DATA
-- data[0] = overall, data[1] = current
-- data[seg][playerName] = {
--   _sum   = total damage,
--   _time  = accumulated fight seconds (frozen when out of combat),
--   _start = GetTime() when fight started for this player (nil out of combat),
--   ["SpellName"] = damage,  -- per-spell breakdown
-- }
-- classes[name] = CLASS string (for color) or ownerName (for pets)
-- ============================================================================
local data = { [0]={}, [1]={} }
local classes   = {}                 -- name -> CLASS or owner name
local tracking   = true
local segment    = 1                  -- 1=current, 0=overall
local playerName = nil
local inCombat    = false
local isBossFight      = false             -- true only when in combat vs worldboss target
local currentFightName = nil               -- target name captured at PLAYER_REGEN_DISABLED
local combatStart = nil               -- GetTime() when current fight started

-- Valid group units for name->unit lookup
local validUnits = { ["player"]=true }
for i=1,4  do validUnits["party"..i]    = true end
for i=1,40 do validUnits["raid"..i]     = true end
local validPets  = { ["pet"]=true }
for i=1,4  do validPets["partypet"..i]  = true end
for i=1,40 do validPets["raidpet"..i]   = true end

local CLASSES = {
    WARRIOR=true, MAGE=true, ROGUE=true, DRUID=true, HUNTER=true,
    SHAMAN=true, PRIEST=true, WARLOCK=true, PALADIN=true,
}

-- ============================================================================
-- HELPERS
-- ============================================================================
local function round(n, p)
    p = p or 0
    local m = 1
    for i=1,p do m=m*10 end
    return floor(n*m+0.5)/m
end

local unit_cache = {}
local function UnitByName(name)
    if unit_cache[name] and UnitName(unit_cache[name]) == name then
        return unit_cache[name]
    end
    for u in pairs(validUnits) do
        if UnitName(u) == name then unit_cache[name]=u; return u end
    end
    for u in pairs(validPets) do
        if UnitName(u) == name then unit_cache[name]=u; return u end
    end
end

local function ScanName(name)
    if not name then return nil end
    -- already known
    if classes[name] then
        return CLASSES[classes[name]] and "PLAYER" or "PET"
    end
    -- scan players
    for u in pairs(validUnits) do
        if UnitExists(u) and UnitName(u) == name then
            if UnitIsPlayer(u) then
                local _, c = UnitClass(u)
                classes[name] = c
                return "PLAYER"
            end
        end
    end
    -- detect SuperWoW pet "(Owner)" suffix
    local _, _, owner = string.find(name, "%((.+)%)")
    if owner and ScanName(owner) == "PLAYER" then
        classes[name] = owner
        return "PET"
    end
    -- scan pet units
    for u in pairs(validPets) do
        if UnitExists(u) and UnitName(u) == name then
            if     strsub(u,1,9) == "partypet" then
                classes[name] = UnitName("party"..strsub(u,10))
            elseif strsub(u,1,7) == "raidpet" then
                classes[name] = UnitName("raid"..strsub(u,8))
            else
                classes[name] = UnitName("player")
            end
            return "PET"
        end
    end
    return nil
end

local function ResetSegment(seg)
    for k in pairs(data[seg]) do data[seg][k] = nil end
    -- restart timer for new segment if in combat
    if inCombat then
        combatStart = GetTime()
    end
end

local function ResetAll()
    ResetSegment(0); ResetSegment(1)
end

-- ============================================================================
-- FIGHT HISTORY
-- ============================================================================
local MAX_HISTORY    = 15
local bossHistory    = {}  -- last 15 worldboss (skull) fights
local generalHistory = {}  -- last 15 fights of any kind
local historyView    = nil -- nil=live, integer index into active history list
local histCat        = "boss"  -- "boss" or "all": which list dropdown shows
local fightSaved     = false

local function DeepCopy(t)
    local r = {}
    for k, v in pairs(t) do
        if type(v) == "table" then r[k] = DeepCopy(v)
        else r[k] = v end
    end
    return r
end

local function GetActiveHistory()
    return histCat == "boss" and bossHistory or generalHistory
end

local function AppendToHistory(list, label)
    local hasData = false
    for k in pairs(data[1]) do hasData = true; break end
    if not hasData then return end
    -- snapshot classes for all players in this fight
    local classSnap = {}
    for name in pairs(data[1]) do
        if classes[name] then classSnap[name] = classes[name] end
    end
    for i = math.min(table.getn(list), MAX_HISTORY - 1), 1, -1 do
        list[i+1] = list[i]
    end
    list[1] = { label=label, snapshot=DeepCopy(data[1]), classes=classSnap }
end

local function SaveFight(label, isBoss)
    AppendToHistory(generalHistory, label)
    if isBoss then AppendToHistory(bossHistory, label) end
    HamingwaysDPSmateDB.bossHistory    = bossHistory
    HamingwaysDPSmateDB.generalHistory = generalHistory
    -- persist class table so colors survive across sessions
    HamingwaysDPSmateDB.classes = HamingwaysDPSmateDB.classes or {}
    for name, cls in pairs(classes) do
        HamingwaysDPSmateDB.classes[name] = cls
    end
end

-- ============================================================================
-- ADD HIT
-- Called from parsers with identified source, spellname, value.
-- Merges pet damage into owner (_sum). Spell stored as "Pet: spell" under owner.
-- ============================================================================
local function AddHit(source, spell, value, isCrit)
    if not tracking then return end
    if not source or not value or value <= 0 then return end

    local utype = ScanName(source)
    if not utype then return end

    -- resolve pet -> owner
    local resolvedSource = source
    local resolvedSpell  = spell
    if utype == "PET" then
        local owner = classes[source]
        if not owner then return end
        resolvedSource = owner
        resolvedSpell  = "Pet: " .. spell
        ScanName(owner)
    end

    -- reset current segment on first hit of new fight
    for seg = 0, 1 do
        local entry = data[seg]
        if not entry[resolvedSource] then
            -- Always start the timer from the first hit, even outside combat.
            -- In combat we use combatStart so all players share the same baseline.
            local startT = (inCombat and combatStart) and combatStart or GetTime()
            entry[resolvedSource] = { _sum=0, _time=0, _start=startT }
        end
        local e = entry[resolvedSource]
        -- ensure timer is running:
        -- in combat: use shared combatStart baseline
        -- out of combat but timer frozen: restart from now (e.g. party member
        --   keeps hitting training dummy after fight ends)
        if inCombat and combatStart and not e._start then
            e._start = combatStart
        elseif not inCombat and not e._start then
            e._start = GetTime()
        end
        e._sum = (e._sum or 0) + value
        -- per-spell hit/crit stats
        if not e[resolvedSpell] then
            e[resolvedSpell] = { sum=0, count=0, min=999999, max=0, csum=0, ccount=0, cmin=999999, cmax=0 }
        end
        local sd = e[resolvedSpell]
        if isCrit then
            sd.csum   = sd.csum + value
            sd.ccount = sd.ccount + 1
            if value < sd.cmin then sd.cmin = value end
            if value > sd.cmax then sd.cmax = value end
        else
            sd.sum   = sd.sum + value
            sd.count = sd.count + 1
            if value < sd.min then sd.min = value end
            if value > sd.max then sd.max = value end
        end
    end
end

-- ============================================================================
-- PATTERN MATCHING
-- ============================================================================
local patterns = {}
local petPatterns = {}

local sanitize_cache = {}
local function sanitize(pat)
    if not pat then return nil end
    if sanitize_cache[pat] then return sanitize_cache[pat] end
    local r = pat
    r = gsub(r, "([%+%-%*%(%)%?%[%]%^])", "%%%1")
    r = gsub(r, "%d%$", "")
    r = gsub(r, "(%%%a)", "(%1+)")
    r = gsub(r, "%%s%+", ".+")
    r = gsub(r, "%(%.%+%)%(%%d%+%)", "(.-)(%%d+)")
    sanitize_cache[pat] = r
    return r
end

local function addPat(list, gs, fn)
    if not gs then return end
    local pat = sanitize(gs)
    if not pat then return end
    local n = table.getn(list) + 1
    list[n] = { pat=pat, fn=fn }
end

local absorb_pat, resist_pat

local function stripTrailers(s)
    if absorb_pat then s = gsub(s, absorb_pat, "") end
    if resist_pat then s = gsub(s, resist_pat, "") end
    return s
end

local function tryMatch(list, msg)
    msg = stripTrailers(msg)
    for _, p in ipairs(list) do
        local res, _, a1, a2, a3, a4, a5 = string.find(msg, p.pat)
        if res then
            p.fn(a1, a2, a3, a4, a5)
            return true
        end
    end
end

local function buildPatterns()
    patterns = {}
    petPatterns = {}

    -- ---- PLAYER (self vs other) ----
    addPat(patterns, SPELLLOGSELFOTHER, function(spell, _, dmg)
        AddHit(playerName, spell, tonumber(dmg), false)
    end)
    addPat(patterns, SPELLLOGCRITSELFOTHER, function(spell, _, dmg)
        AddHit(playerName, spell, tonumber(dmg), true)
    end)
    addPat(patterns, SPELLLOGSCHOOLSELFOTHER, function(spell, _, dmg)
        AddHit(playerName, spell, tonumber(dmg), false)
    end)
    addPat(patterns, SPELLLOGCRITSCHOOLSELFOTHER, function(spell, _, dmg)
        AddHit(playerName, spell, tonumber(dmg), true)
    end)
    addPat(patterns, COMBATHITSELFOTHER, function(_, dmg)
        AddHit(playerName, "Auto Attack", tonumber(dmg), false)
    end)
    addPat(patterns, COMBATHITCRITSELFOTHER, function(_, dmg)
        AddHit(playerName, "Auto Attack", tonumber(dmg), true)
    end)
    addPat(patterns, COMBATHITSCHOOLSELFOTHER, function(_, dmg)
        AddHit(playerName, "Auto Attack", tonumber(dmg), false)
    end)
    addPat(patterns, COMBATHITCRITSCHOOLSELFOTHER, function(_, dmg)
        AddHit(playerName, "Auto Attack", tonumber(dmg), true)
    end)
    addPat(patterns, PERIODICAURADAMAGESELFOTHER, function(_, dmg, _, spell)
        AddHit(playerName, spell, tonumber(dmg), false)
    end)

    -- ---- OTHER/PET (other vs other) ----
    -- Spells FIRST (more specific, has source+spellname)
    addPat(petPatterns, SPELLLOGOTHEROTHER, function(src, spell, _, dmg)
        AddHit(src, spell, tonumber(dmg), false)
    end)
    addPat(petPatterns, SPELLLOGCRITOTHEROTHER, function(src, spell, _, dmg)
        AddHit(src, spell, tonumber(dmg), true)
    end)
    addPat(petPatterns, SPELLLOGSCHOOLOTHEROTHER, function(src, spell, _, dmg)
        AddHit(src, spell, tonumber(dmg), false)
    end)
    addPat(petPatterns, SPELLLOGCRITSCHOOLOTHEROTHER, function(src, spell, _, dmg)
        AddHit(src, spell, tonumber(dmg), true)
    end)
    -- Periodic
    addPat(petPatterns, PERIODICAURADAMAGEOTHEROTHER, function(_, dmg, _, src, spell)
        AddHit(src, spell .. " (DoT)", tonumber(dmg), false)
    end)
    -- Melee AFTER spells
    addPat(petPatterns, COMBATHITOTHEROTHER, function(src, _, dmg)
        AddHit(src, "Auto Attack", tonumber(dmg), false)
    end)
    addPat(petPatterns, COMBATHITCRITOTHEROTHER, function(src, _, dmg)
        AddHit(src, "Auto Attack", tonumber(dmg), true)
    end)
    addPat(petPatterns, COMBATHITSCHOOLOTHEROTHER, function(src, _, dmg)
        AddHit(src, "Auto Attack", tonumber(dmg), false)
    end)
    addPat(petPatterns, COMBATHITCRITSCHOOLOTHEROTHER, function(src, _, dmg)
        AddHit(src, "Auto Attack", tonumber(dmg), true)
    end)

    absorb_pat = ABSORB_TRAILER and sanitize(ABSORB_TRAILER) or nil
    resist_pat = RESIST_TRAILER  and sanitize(RESIST_TRAILER)  or nil
end

-- ============================================================================
-- WINDOWS
-- ============================================================================
local WIN_W        = 220
local ROW_H        = 15
local TITLE_H      = 16
local TOOL_H       = 14
local barFillAlpha  = 0.35   -- bar class-colour fill opacity (user-adjustable)
local currentFontFace = "Fonts\\FRIZQT__.TTF"  -- updated by ApplySettings
local currentFontSize = 10                      -- updated by ApplySettings

-- Available font faces for the cycle button
local HDPS_FONTS = {
    { name="WoW Default",  file="Fonts\\FRIZQT__.TTF" },
    { name="Arial Narrow", file="Fonts\\ARIALN.TTF"   },
    { name="Skurri",       file="Fonts\\skurri.ttf"   },
}

-- Registry of eagerly-created FontStrings that should receive font updates
local hdpsFontStrings = {}
local function reg(fs)
    hdpsFontStrings[table.getn(hdpsFontStrings)+1] = fs
    return fs
end

-- Forward declarations (defined later, after all frames exist)
local GetSettings
local ApplySettings

local function classColor(name, histClasses)
    local cls = (histClasses and histClasses[name]) or classes[name]
    if cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls] then
        local c = RAID_CLASS_COLORS[cls]
        return c.r, c.g, c.b
    end
    return 0.7, 0.7, 0.7
end

-- ============================================================================
-- DETAIL WINDOW
-- ============================================================================
local detailWin = CreateFrame("Frame", "HamingwaysDPSmateDetail", UIParent)
detailWin:SetWidth(220)
detailWin:SetHeight(80)
detailWin:SetPoint("TOPLEFT", UIParent, "CENTER", 414, 0)  -- fixed on show
detailWin:SetMovable(true)
detailWin:EnableMouse(true)
detailWin:RegisterForDrag("LeftButton")
detailWin:SetScript("OnDragStart", function() detailWin:StartMoving() end)
detailWin:SetScript("OnDragStop",  function() detailWin:StopMovingOrSizing() end)
detailWin:SetFrameStrata("HIGH")
detailWin:Hide()

local detailBg = detailWin:CreateTexture(nil, "BACKGROUND")
detailBg:SetAllPoints(detailWin)
detailBg:SetTexture(0, 0, 0, 0.80)

local detailTitleTex = detailWin:CreateTexture(nil, "BACKGROUND")
detailTitleTex:SetHeight(TITLE_H)
detailTitleTex:SetPoint("TOPLEFT",  detailWin, "TOPLEFT",  0, 0)
detailTitleTex:SetPoint("TOPRIGHT", detailWin, "TOPRIGHT", 0, 0)
detailTitleTex:SetTexture(0.15, 0.08, 0, 0.95)

local detailTitleText = detailWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
detailTitleText:SetPoint("TOPLEFT", detailWin, "TOPLEFT", 4, -2)
detailTitleText:SetText("|cFFFFAA00Detail|r")

local detailCloseBtn = CreateFrame("Button", nil, detailWin)
detailCloseBtn:SetWidth(18)
detailCloseBtn:SetHeight(TITLE_H)
detailCloseBtn:SetPoint("TOPRIGHT", detailWin, "TOPRIGHT", -2, -1)
local detailCloseTxt = detailCloseBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
detailCloseTxt:SetAllPoints(detailCloseBtn)
detailCloseTxt:SetText("|cFFFF4444X|r")

local detailRows = {}
local detailSubject = nil

detailCloseBtn:SetScript("OnClick",  function() detailSubject = nil; detailWin:Hide() end)
detailCloseBtn:SetScript("OnEnter",  function() detailCloseTxt:SetText("|cFFFFFF44X|r") end)
detailCloseBtn:SetScript("OnLeave",  function() detailCloseTxt:SetText("|cFFFF4444X|r") end)

local DETAIL_VAL_W = 75  -- right column width for value+pct

-- ============================================================================
-- CUSTOM SPELL TOOLTIP (styled like the addon)
-- ============================================================================
local TT_TITLE_H = 16
local TT_LINE_H  = 13
local TT_PAD     = 4

local hdpsTooltip = CreateFrame("Frame", "HamingwaysDPSmateTooltip", UIParent)
hdpsTooltip:SetWidth(220)   -- updated dynamically on show
hdpsTooltip:SetHeight(100)
hdpsTooltip:SetFrameStrata("TOOLTIP")
hdpsTooltip:Hide()

local ttBg = hdpsTooltip:CreateTexture(nil, "BACKGROUND")
ttBg:SetAllPoints(hdpsTooltip)
ttBg:SetTexture(0, 0, 0, 0.85)

local ttTitleTex = hdpsTooltip:CreateTexture(nil, "BACKGROUND")
ttTitleTex:SetHeight(TT_TITLE_H)
ttTitleTex:SetPoint("TOPLEFT",  hdpsTooltip, "TOPLEFT",  0, 0)
ttTitleTex:SetPoint("TOPRIGHT", hdpsTooltip, "TOPRIGHT", 0, 0)
ttTitleTex:SetTexture(0.15, 0.08, 0, 0.95)

local ttTitle = reg(hdpsTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
ttTitle:SetPoint("TOPLEFT",  hdpsTooltip, "TOPLEFT",  TT_PAD, -2)
ttTitle:SetPoint("TOPRIGHT", hdpsTooltip, "TOPRIGHT", -TT_PAD, -2)
ttTitle:SetJustifyH("CENTER")

-- Pre-create left+right FontString pairs for each line
-- Column split and widths are updated dynamically in ShowHDPSTooltip.
local MAX_TT_LINES = 14
local ttLineLeft  = {}
local ttLineRight = {}
for i = 1, MAX_TT_LINES do
    local y = -TT_TITLE_H - (i-1)*TT_LINE_H - 3
    local lf = reg(hdpsTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    lf:SetWidth(100)  -- placeholder, set on show
    lf:SetPoint("TOPLEFT", hdpsTooltip, "TOPLEFT", TT_PAD, y)
    lf:SetJustifyH("LEFT")
    local rf = reg(hdpsTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    rf:SetWidth(100)  -- placeholder, set on show
    rf:SetPoint("TOPLEFT", hdpsTooltip, "TOPLEFT", TT_PAD, y)  -- x updated on show
    rf:SetJustifyH("LEFT")
    ttLineLeft[i]  = lf
    ttLineRight[i] = rf
end

local function ShowHDPSTooltip(sd, spellName)
    if not sd then hdpsTooltip:Hide(); return end

    -- match detail window width
    local w = detailWin:GetWidth()
    local col = math.floor(w / 2)
    hdpsTooltip:SetWidth(w)
    for i = 1, MAX_TT_LINES do
        ttLineLeft[i]:SetText("")
        ttLineLeft[i]:SetWidth(col - TT_PAD)
        ttLineRight[i]:SetText("")
        ttLineRight[i]:SetWidth(col - TT_PAD)
        ttLineRight[i]:SetPoint("TOPLEFT", hdpsTooltip, "TOPLEFT", col, -TT_TITLE_H - (i-1)*TT_LINE_H - 3)
    end

    ttTitle:SetText("|cFFFFAA00" .. (spellName or "?") .. "|r")

    local n = 0
    local function addLine(l, r)
        n = n + 1
        ttLineLeft[n]:SetText(l or "")
        ttLineRight[n]:SetText(r or "")
    end

    local totalHits = sd.count + sd.ccount
    local critPct   = totalHits > 0 and string.format("%.1f", sd.ccount / totalHits * 100) or "0.0"

    addLine("|cFFCCCCCCNon-Crit|r", "|cFFFFCC00Crit|r")
    addLine("", "")
    addLine("Hits: |cFFFFFFFF" .. sd.count  .. "|r",
            "Hits: |cFFFFFFFF" .. sd.ccount .. "|r")
    addLine("Min:  |cFFFFFFFF" .. (sd.count  > 0 and sd.min  or 0) .. "|r",
            "Min:  |cFFFFFFFF" .. (sd.ccount > 0 and sd.cmin or 0) .. "|r")
    addLine("Max:  |cFFFFFFFF" .. (sd.count  > 0 and sd.max  or 0) .. "|r",
            "Max:  |cFFFFFFFF" .. (sd.ccount > 0 and sd.cmax or 0) .. "|r")
    addLine("Avg:  |cFFFFFFFF" .. (sd.count  > 0 and string.format("%.1f", sd.sum  / sd.count)  or "0") .. "|r",
            "Avg:  |cFFFFFFFF" .. (sd.ccount > 0 and string.format("%.1f", sd.csum / sd.ccount) or "0") .. "|r")
    addLine("", "")
    addLine("Crit%: |cFFFFCC00" .. critPct .. "%|r", "")
    addLine("Total: |cFFFFFFFF" .. (sd.sum + sd.csum) .. "|r", "")

    local h = TT_TITLE_H + n * TT_LINE_H + TT_PAD * 2
    hdpsTooltip:SetHeight(h)
    hdpsTooltip:ClearAllPoints()
    hdpsTooltip:SetPoint("BOTTOMLEFT", detailWin, "TOPLEFT", 0, 4)
    hdpsTooltip:Show()
end

local function HideHDPSTooltip()
    hdpsTooltip:Hide()
end

local function getOrCreateDetailRow(i)
    if not detailRows[i] then
        local row = CreateFrame("Frame", nil, detailWin)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT",  detailWin, "TOPLEFT",  0, -TITLE_H - (i-1)*ROW_H)
        row:SetPoint("TOPRIGHT", detailWin, "TOPRIGHT", 0, -TITLE_H - (i-1)*ROW_H)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        if math.mod(i,2)==0 then bg:SetTexture(0.10,0.10,0.10,0.5)
        else                      bg:SetTexture(0.05,0.05,0.05,0.5) end

        -- ShaguDPS-style: both strings span full row, no SetWidth limit
        local nameT = reg(row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
        nameT:SetPoint("TOPLEFT",     row, "TOPLEFT",     4, 0)
        nameT:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
        nameT:SetJustifyH("LEFT")
        nameT:SetFont(currentFontFace, currentFontSize)

        local valT = reg(row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
        valT:SetPoint("TOPLEFT",     row, "TOPLEFT",     4, 0)
        valT:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
        valT:SetJustifyH("RIGHT")
        valT:SetFont(currentFontFace, currentFontSize)

        row.nameT = nameT
        row.valT  = valT

        row:EnableMouse(true)
        row:SetScript("OnEnter", function()
            ShowHDPSTooltip(this.spellData, this.spellName)
        end)
        row:SetScript("OnLeave", function()
            HideHDPSTooltip()
        end)

        detailRows[i] = row
    end
    return detailRows[i]
end

local function UpdateDetailWindow()
    for _, r in ipairs(detailRows) do r:Hide() end
    if not detailSubject then return end
    local activeHist = GetActiveHistory()
    local viewSeg = historyView and activeHist[historyView] and activeHist[historyView].snapshot or data[segment]
    local entry = viewSeg[detailSubject]
    if not entry then detailWin:Hide(); return end

    detailTitleText:SetText("|cFFFFAA00" .. detailSubject .. "|r")

    -- separate player spells from pet spells
    local playerSpells = {}
    local petSpells    = {}
    local petTotal     = 0
    for k, v in pairs(entry) do
        if type(v)=="table" then
            local t = (v.sum or 0) + (v.csum or 0)
            if string.sub(k, 1, 4) == "Pet:" then
                local n = table.getn(petSpells)+1
                petSpells[n] = { name=string.sub(k,6), total=t, sd=v }
                petTotal = petTotal + t
            else
                local n = table.getn(playerSpells)+1
                playerSpells[n] = { name=k, total=t, sd=v }
            end
        end
    end
    table.sort(playerSpells, function(a,b) return a.total > b.total end)
    table.sort(petSpells,    function(a,b) return a.total > b.total end)

    local total = entry._sum or 0
    local active = entry._start and (GetTime() - entry._start) or 0
    local t = math.max(1, (entry._time or 0) + active)
    local dps = string.format("%.1f", total / t)

    -- header row: DPS left, Total right
    local hdr = getOrCreateDetailRow(1)
    hdr.nameT:SetText("|cFF88FFFF" .. dps .. " dps|r")
    hdr.valT:SetText("|cFF88FFFFTotal: " .. total .. "|r")
    hdr.spellData = nil
    hdr.spellName = nil
    hdr:Show()

    local row_i = 2

    -- player spells
    for _, sp in ipairs(playerSpells) do
        local row = getOrCreateDetailRow(row_i)
        local pct = total > 0 and string.format("%.1f", sp.total/total*100) or "0.0"
        row.nameT:SetText("|cFFFFFFFF" .. sp.name .. "|r")
        row.valT:SetText("|cFFFFFFFF" .. sp.total .. "|r |cFF888888" .. pct .. "%|r")
        row.spellData = sp.sd
        row.spellName = sp.name
        row:Show()
        row_i = row_i + 1
    end

    -- pet summary + details
    if table.getn(petSpells) > 0 then
        local petRow = getOrCreateDetailRow(row_i)
        local pct = total > 0 and string.format("%.1f", petTotal/total*100) or "0.0"
        petRow.nameT:SetText("|cFFFFCC44Pet (total)|r")
        petRow.valT:SetText("|cFFFFCC44" .. petTotal .. "|r |cFF888888" .. pct .. "%|r")
        petRow.spellData = nil
        petRow.spellName = nil
        petRow:Show()
        row_i = row_i + 1

        for _, sp in ipairs(petSpells) do
            local row = getOrCreateDetailRow(row_i)
            local pct2 = total > 0 and string.format("%.1f", sp.total/total*100) or "0.0"
            row.nameT:SetText("|cFFAAAAAA  " .. sp.name .. "|r")
            row.valT:SetText("|cFFCCCCCC" .. sp.total .. "|r |cFF666666" .. pct2 .. "%|r")
            row.spellData = sp.sd
            row.spellName = sp.name
            row:Show()
            row_i = row_i + 1
        end
    end

    detailWin:ClearAllPoints()
    detailWin:SetPoint("TOPLEFT", "HamingwaysDPSmateMain", "TOPRIGHT", 4, 0)
    local h = TITLE_H + (row_i - 1) * ROW_H + 4
    if h < 50 then h = 50 end
    detailWin:SetHeight(h)
    detailWin:Show()
end

-- ============================================================================
-- MAIN WINDOW
-- ============================================================================
local mainWin = CreateFrame("Frame", "HamingwaysDPSmateMain", UIParent)
mainWin:SetWidth(WIN_W)
mainWin:SetHeight(110)
mainWin:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
mainWin:SetMovable(true)
mainWin:SetResizable(true)
mainWin:SetMinResize(150, 60)
mainWin:EnableMouse(true)
mainWin:RegisterForDrag("LeftButton")
mainWin:SetScript("OnDragStart", function() mainWin:StartMoving() end)
mainWin:SetScript("OnDragStop",  function() mainWin:StopMovingOrSizing() end)
mainWin:SetFrameStrata("MEDIUM")

-- Chrome container: all title/toolbar/bg elements live here and fade together.
local chromeFrame = CreateFrame("Frame", nil, mainWin)
chromeFrame:SetAllPoints(mainWin)

local mainBg = chromeFrame:CreateTexture(nil, "BACKGROUND")
mainBg:SetAllPoints(mainWin)
mainBg:SetTexture(0, 0, 0, 0.80)

-- Title bar
local titleTex = chromeFrame:CreateTexture(nil, "BACKGROUND")
titleTex:SetHeight(TITLE_H)
titleTex:SetPoint("TOPLEFT",  mainWin, "TOPLEFT",  0, 0)
titleTex:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", 0, 0)
titleTex:SetTexture(0.15, 0.08, 0, 0.95)

local titleText = chromeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titleText:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 4, -2)
titleText:SetText("|cFFABD473Hamingway's |r|cFFFFFF00DPSmate|r")

-- [Current]/[Overall] toggle (toolbar row 1, left side)
local segBtn = CreateFrame("Button", nil, chromeFrame)
segBtn:SetWidth(75)
segBtn:SetHeight(TOOL_H)
segBtn:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 4, -TITLE_H - 1)
local segBtnText = segBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
segBtnText:SetAllPoints(segBtn)
segBtnText:SetJustifyH("LEFT")
segBtnText:SetText("|cFF88FFFF[Current]|r")

-- [All]/[Self] view toggle (toolbar row 1, after seg button)
local viewBtn = CreateFrame("Button", nil, chromeFrame)
viewBtn:SetWidth(50)
viewBtn:SetHeight(TOOL_H)
viewBtn:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 82, -TITLE_H - 1)
local viewBtnText = viewBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
viewBtnText:SetAllPoints(viewBtn)
viewBtnText:SetJustifyH("LEFT")
viewBtnText:SetText("|cFFAAAAAA[All]|r")

-- Reset button
local resetBtn = CreateFrame("Button", nil, chromeFrame)
resetBtn:SetWidth(45)
resetBtn:SetHeight(TITLE_H)
resetBtn:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", -2, -1)
local resetBtnText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
resetBtnText:SetAllPoints(resetBtn)
resetBtnText:SetJustifyH("RIGHT")
resetBtnText:SetText("|cFFFF4444Reset|r")

-- Toolbar (covers two rows: segBtn row + trackBtn/sortBtn row)
local toolbarTex = chromeFrame:CreateTexture(nil, "BACKGROUND")
toolbarTex:SetHeight(TOOL_H + TOOL_H)
toolbarTex:SetPoint("TOPLEFT",  mainWin, "TOPLEFT",  0, -TITLE_H)
toolbarTex:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", 0, -TITLE_H)
toolbarTex:SetTexture(0.10, 0.06, 0, 0.95)

local trackBtn = CreateFrame("Button", nil, chromeFrame)
trackBtn:SetWidth(90)
trackBtn:SetHeight(TOOL_H)
trackBtn:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 4, -TITLE_H - TOOL_H - 1)
local trackBtnText = trackBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
trackBtnText:SetAllPoints(trackBtn)
trackBtnText:SetJustifyH("LEFT")

local sortMode = "dps"  -- "dps" or "dmg"
local viewMode = "all"   -- "all" or "self"
local sortBtn = CreateFrame("Button", nil, chromeFrame)
sortBtn:SetWidth(55)
sortBtn:SetHeight(TOOL_H)
sortBtn:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", -2, -TITLE_H - TOOL_H - 1)
local sortBtnText = sortBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
sortBtnText:SetAllPoints(sortBtn)
sortBtnText:SetJustifyH("RIGHT")
sortBtnText:SetText("|cFFAAAAFF[by DPS]|r")

-- History browser button (toolbar row 2, centre)
local histBtn = CreateFrame("Button", nil, chromeFrame)
histBtn:SetWidth(60)
histBtn:SetHeight(TOOL_H)
histBtn:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 96, -TITLE_H - TOOL_H - 1)
local histBtnText = histBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
histBtnText:SetAllPoints(histBtn)
histBtnText:SetJustifyH("LEFT")
histBtnText:SetText("|cFF888888[Hist]|r")

-- History dropdown panel (shown below mainWin on click)
local HIST_ROW_H   = TOOL_H
local HIST_MAX_ROW = MAX_HISTORY + 2  -- category toggle + "Live" row + up to 15 fight rows
local histDropdown = CreateFrame("Frame", "HamingwaysDPSmateHistDrop", UIParent)
-- Forward declarations needed because OnClick closures reference these before definition
local RefreshHistDropdown
local UpdateHistBtn
histDropdown:SetFrameStrata("DIALOG")
histDropdown:SetWidth(WIN_W)
histDropdown:SetHeight(1)
histDropdown:Hide()

local histDropBg = histDropdown:CreateTexture(nil, "BACKGROUND")
histDropBg:SetAllPoints(histDropdown)
histDropBg:SetTexture(0, 0, 0, 0.92)

-- Close button (top-right of dropdown)
local histDropClose = CreateFrame("Button", nil, histDropdown)
histDropClose:SetWidth(18)
histDropClose:SetHeight(HIST_ROW_H)
histDropClose:SetPoint("TOPRIGHT", histDropdown, "TOPRIGHT", -2, -1)
histDropClose:SetFrameLevel(histDropdown:GetFrameLevel() + 5)
local histDropCloseTxt = histDropClose:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
histDropCloseTxt:SetAllPoints(histDropClose)
histDropCloseTxt:SetText("|cFFFF4444X|r")
histDropClose:SetScript("OnClick", function() histDropdown:Hide() end)
histDropClose:SetScript("OnEnter", function() histDropCloseTxt:SetText("|cFFFFFF44X|r") end)
histDropClose:SetScript("OnLeave", function() histDropCloseTxt:SetText("|cFFFF4444X|r") end)

local histDropBtnRows = {}
for i = 1, HIST_MAX_ROW do
    local row = CreateFrame("Button", nil, histDropdown)
    row:SetHeight(HIST_ROW_H)
    row:SetPoint("TOPLEFT",  histDropdown, "TOPLEFT",  0, -(i-1)*HIST_ROW_H)
    row:SetPoint("TOPRIGHT", histDropdown, "TOPRIGHT", 0, -(i-1)*HIST_ROW_H)
    local rowBg = row:CreateTexture(nil, "BACKGROUND")
    rowBg:SetAllPoints(row)
    if math.mod(i,2)==0 then rowBg:SetTexture(0.12,0.12,0.12,0.85)
    else                      rowBg:SetTexture(0.06,0.06,0.06,0.85) end
    row.isEven = (math.mod(i,2)==0)
    row.rowBg  = rowBg
    local rowText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rowText:SetPoint("TOPLEFT",     row, "TOPLEFT",     4, 0)
    rowText:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
    rowText:SetJustifyH("LEFT")
    row.rowText = rowText
    row:SetScript("OnEnter", function() this.rowBg:SetTexture(0.25, 0.15, 0, 0.9) end)
    row:SetScript("OnLeave", function()
        if this.isEven then this.rowBg:SetTexture(0.12,0.12,0.12,0.85)
        else                 this.rowBg:SetTexture(0.06,0.06,0.06,0.85) end
    end)
    row:SetScript("OnClick", function()
        if this.isCatToggle then
            histCat = histCat == "boss" and "all" or "boss"
            historyView = nil
            UpdateHistBtn()
            RefreshHistDropdown()
            return
        end
        historyView = this.histIdx
        histDropdown:Hide()
        UpdateHistBtn()
        detailSubject = nil
        HamingwaysDPSmate_UpdateWindow()
    end)
    row:Hide()
    histDropBtnRows[i] = row
end

RefreshHistDropdown = function()
    local activeList = GetActiveHistory()
    local n = table.getn(activeList)
    histDropdown:SetWidth(mainWin:GetWidth())
    histDropdown:SetHeight((2 + n) * HIST_ROW_H + 2)
    histDropdown:ClearAllPoints()
    histDropdown:SetPoint("TOPLEFT", mainWin, "BOTTOMLEFT", 0, -2)
    for i = 1, HIST_MAX_ROW do histDropBtnRows[i]:Hide() end
    -- row 1: category toggle
    local r0 = histDropBtnRows[1]
    r0.isCatToggle = true
    r0.histIdx = nil
    if histCat == "boss" then
        r0.rowText:SetText("|cFFFF8800>> Boss <<|r  |cFFAAAAAA[All]|r")
    else
        r0.rowText:SetText("|cFFAAAAAA[Boss]|r  |cFFFFFFFF>> All <<|r")
    end
    r0:Show()
    -- row 2: Live
    local r1 = histDropBtnRows[2]
    r1.isCatToggle = false
    r1.histIdx = nil
    r1.rowText:SetText(historyView == nil and "|cFF44FF44>> Live <<|r" or "|cFFAAAAAA[Live]|r")
    r1:Show()
    -- rows 3..n+2: history entries newest first
    for i = 1, n do
        local row = histDropBtnRows[i + 2]
        local mark = (historyView == i) and "|cFFFFAA00>|r " or "  "
        row.isCatToggle = false
        row.histIdx = i
        row.rowText:SetText(mark .. "|cFFFFFFFF" .. i .. ". " .. activeList[i].label .. "|r")
        row:Show()
    end
    histDropdown:Show()
end

UpdateHistBtn = function()
    local activeList = GetActiveHistory()
    if historyView == nil then
        local catLabel = histCat == "boss" and "B" or "A"
        histBtnText:SetText("|cFF888888[Hist:" .. catLabel .. "]|r")
    elseif activeList[historyView] then
        histBtnText:SetText("|cFFFFAA00[#" .. historyView .. "]|r")
    end
end

local function UpdateTrackBtn()
    if tracking then
        trackBtnText:SetText("|cFF44FF44[Tracking ON]|r")
    else
        trackBtnText:SetText("|cFFFF4444[Tracking OFF]|r")
    end
end
UpdateTrackBtn()

local ROWS_OFFSET = TITLE_H + TOOL_H + TOOL_H

-- Permanent bar background: always visible, never fades
local barsBg = CreateFrame("Frame", nil, mainWin)
barsBg:SetPoint("TOPLEFT",  mainWin, "TOPLEFT",  0, -ROWS_OFFSET)
barsBg:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", 0, -ROWS_OFFSET)
barsBg:SetHeight(1)
local barsBgTex = barsBg:CreateTexture(nil, "BACKGROUND")
barsBgTex:SetAllPoints(barsBg)
barsBgTex:SetTexture(0, 0, 0, 0.70)

-- Player bars
local bars = {}
local preferredHeight = 110  -- user's drag-resize preferred height (controls maxBars)
local isSizing = false

-- Resize handle (bottom-right corner, like ShaguDPS)
local resizeBtn = CreateFrame("Frame", nil, mainWin)
resizeBtn:SetWidth(10)
resizeBtn:SetHeight(10)
resizeBtn:SetPoint("BOTTOMRIGHT", mainWin, "BOTTOMRIGHT", -2, 2)
resizeBtn:EnableMouse(true)
resizeBtn:SetFrameLevel(50)
resizeBtn:SetScript("OnMouseDown", function()
    isSizing = true
    mainWin:StartSizing("BOTTOMRIGHT")
end)
resizeBtn:SetScript("OnMouseUp", function()
    isSizing = false
    mainWin:StopMovingOrSizing()
    WIN_W = mainWin:GetWidth()
    preferredHeight = mainWin:GetHeight()
    HamingwaysDPSmate_UpdateWindow()
end)

-- ============================================================================
-- CHROME FADE (fades title/toolbar when mouse leaves the window)
-- ============================================================================
local chromeAlpha = 1

local function IsMouseOverMain()
    local x, y = GetCursorPosition()
    local s = UIParent:GetScale()
    if s and s > 0 then x, y = x/s, y/s end
    local l = mainWin:GetLeft()
    local r = mainWin:GetRight()
    local b = mainWin:GetBottom()
    local t = mainWin:GetTop()
    if not l then return false end
    return x >= l and x <= r and y >= b and y <= t
end

mainWin:SetScript("OnUpdate", function()
    local elapsed = arg1 or 0
    local target = (isSizing or IsMouseOverMain()) and 1 or 0
    local speed  = target == 1 and 5 or 1.5
    if chromeAlpha < target then
        chromeAlpha = math.min(chromeAlpha + elapsed * speed, 1)
    elseif chromeAlpha > target then
        chromeAlpha = math.max(chromeAlpha - elapsed * speed, 0)
    end
    chromeFrame:SetAlpha(chromeAlpha)
end)

local function getOrCreateBar(i)
    if not bars[i] then
        local bar = CreateFrame("Button", nil, mainWin)
        bar:SetHeight(ROW_H)
        bar:SetPoint("TOPLEFT",  mainWin, "TOPLEFT",  0, -ROWS_OFFSET - (i-1)*ROW_H)
        bar:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", 0, -ROWS_OFFSET - (i-1)*ROW_H)

        local stripe = bar:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(bar)
        bar.isEven = (math.mod(i,2)==0)
        if bar.isEven then stripe:SetTexture(0.10,0.10,0.10,0.6)
        else               stripe:SetTexture(0.05,0.05,0.05,0.6) end
        bar.stripe = stripe

        local fill = bar:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("LEFT",   bar, "LEFT",   0, 0)
        fill:SetPoint("TOP",    bar, "TOP",    0, 0)
        fill:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
        fill:SetWidth(1)

        -- ShaguDPS-style: both strings span full bar width, no SetWidth limit
        local nameT = reg(bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
        nameT:SetPoint("TOPLEFT",     bar, "TOPLEFT",     4, 0)
        nameT:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -4, 0)
        nameT:SetJustifyH("LEFT")
        nameT:SetFont(currentFontFace, currentFontSize)

        local valT = reg(bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
        valT:SetPoint("TOPLEFT",     bar, "TOPLEFT",     4, 0)
        valT:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -4, 0)
        valT:SetJustifyH("RIGHT")
        valT:SetFont(currentFontFace, currentFontSize)

        bar.fill  = fill
        bar.nameT = nameT
        bar.valT  = valT
        bars[i]   = bar
    end
    return bars[i]
end

function HamingwaysDPSmate_UpdateWindow()
    local activeHist = GetActiveHistory()
    local histEntry = historyView and activeHist[historyView]
    local seg = histEntry and histEntry.snapshot or data[segment]
    local histClasses = histEntry and histEntry.classes or nil

    local players = {}
    for name, entry in pairs(seg) do
        if type(entry) == "table" then
            local n = table.getn(players)+1
            players[n] = {
                name   = name,
                total  = entry._sum   or 0,
                _time  = entry._time  or 0,
                _start = entry._start,
            }
        end
    end
    -- filter by view mode
    if viewMode == "self" and playerName then
        local filtered = {}
        for _, p in ipairs(players) do
            if p.name == playerName then
                local n = table.getn(filtered) + 1
                filtered[n] = p
            end
        end
        players = filtered
    end

    -- compute dps for each player first
    for _, p in ipairs(players) do
        local active = p._start and (GetTime() - p._start) or 0
        local t = math.max(1, p._time + active)
        p.dps = round(p.total / t, 1)
    end

    if sortMode == "dps" then
        table.sort(players, function(a,b) return a.dps > b.dps end)
    else
        table.sort(players, function(a,b) return a.total > b.total end)
    end

    local best     = table.getn(players) > 0 and players[1].total or 0
    local grandTotal = 0
    for _, p in ipairs(players) do
        grandTotal = grandTotal + p.total
    end

    -- how many rows fit based on user's preferred height
    local maxBars = math.floor((preferredHeight - ROWS_OFFSET) / ROW_H)
    if maxBars < 1 then maxBars = 1 end

    -- always use actual frame width so bars are correct after /reload
    WIN_W = mainWin:GetWidth()

    for _, b in ipairs(bars) do b:Hide() end

    for i, p in ipairs(players) do
        if i > maxBars then break end
        local bar = getOrCreateBar(i)
        local r, g, b = classColor(p.name, histClasses)
        local pct = grandTotal > 0 and string.format("%.1f", p.total/grandTotal*100) or "0.0"
        local dps = p.dps

        local fillW = best > 0 and math.floor(p.total/best * WIN_W) or 1
        if fillW < 1 then fillW = 1 end
        bar.fill:SetWidth(fillW)
        bar.fill:SetTexture(r, g, b, barFillAlpha)

        bar.nameT:SetTextColor(r, g, b)
        bar.nameT:SetText(i .. ". " .. p.name)
        if sortMode == "dps" then
            bar.valT:SetText("|cFFFFFFFF" .. string.format("%.1f", dps) .. "|r |cFFAAAAAAdps " .. pct .. "%|r")
        else
            bar.valT:SetText("|cFFFFFFFF" .. p.total .. "|r |cFFAAAAAAdmg " .. pct .. "%|r")
        end
        bar.unit = p.name

        bar:SetScript("OnClick", function()
            if detailSubject == this.unit and detailWin:IsShown() then
                detailWin:Hide()
                detailSubject = nil
            else
                detailSubject = this.unit
                UpdateDetailWindow()
            end
        end)
        bar:Show()
    end

    -- barsBg covers only actual shown bars - empty space below fades with chrome
    local shownCount = math.min(table.getn(players), maxBars)
    local barsH = math.max(1, shownCount) * ROW_H
    barsBg:SetHeight(barsH)
    if not isSizing then
        mainWin:SetHeight(preferredHeight)
    end

    if historyView and activeHist[historyView] then
        titleText:SetText("|cFFFFAA00HDPS|r |cFFFF8800[" .. activeHist[historyView].label .. "]|r")
    else
        titleText:SetText("|cFFFFAA00HamingwaysDPSmate|r")
    end

    UpdateDetailWindow()
end

-- ============================================================================
-- CONFIRM RESET DIALOG
-- ============================================================================
local pendingReset = nil
StaticPopupDialogs["HDPS_CONFIRM_RESET"] = {
    text = "HamingwaysDPSmate\nAre you sure you want to reset?",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function()
        if pendingReset then pendingReset() end
        pendingReset = nil
    end,
    OnCancel = function()
        pendingReset = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- ============================================================================
-- BUTTON HANDLERS
-- ============================================================================
segBtn:SetScript("OnClick", function()
    if segment == 1 then
        segment = 0
        segBtnText:SetText("|cFFFFCC44[Overall]|r")
    else
        segment = 1
        segBtnText:SetText("|cFF88FFFF[Current]|r")
    end
    detailSubject = nil
    HamingwaysDPSmate_UpdateWindow()
end)

viewBtn:SetScript("OnClick", function()
    if viewMode == "all" then
        viewMode = "self"
        viewBtnText:SetText("|cFF88FF88[Self]|r")
    else
        viewMode = "all"
        viewBtnText:SetText("|cFFAAAAAA[All]|r")
    end
    detailSubject = nil
    HamingwaysDPSmate_UpdateWindow()
end)

histBtn:SetScript("OnClick", function()
    if histDropdown:IsShown() then
        histDropdown:Hide()
    else
        RefreshHistDropdown()
    end
end)

resetBtn:SetScript("OnClick", function()
    if segment == 1 then
        pendingReset = function()
            SaveFight("Reset " .. date("%H:%M"), false)
            historyView = nil
            UpdateHistBtn()
            ResetSegment(1)
            detailSubject = nil
            HamingwaysDPSmate_UpdateWindow()
        end
    else
        pendingReset = function()
            SaveFight("Reset All " .. date("%H:%M"), false)
            historyView = nil
            UpdateHistBtn()
            ResetAll()
            detailSubject = nil
            HamingwaysDPSmate_UpdateWindow()
        end
    end
    StaticPopup_Show("HDPS_CONFIRM_RESET")
end)
resetBtn:SetScript("OnEnter", function() resetBtnText:SetText("|cFFFFFF44Reset|r") end)
resetBtn:SetScript("OnLeave", function() resetBtnText:SetText("|cFFFF4444Reset|r") end)

trackBtn:SetScript("OnClick", function()
    tracking = not tracking
    if not tracking then
        -- freeze timers as if leaving combat
        local now = GetTime()
        for s=0,1 do
            for _, entry in pairs(data[s]) do
                if type(entry)=="table" and entry._start then
                    entry._time  = (entry._time or 0) + (now - entry._start)
                    entry._start = nil
                end
            end
        end
    end
    UpdateTrackBtn()
    HamingwaysDPSmate_UpdateWindow()
end)

sortBtn:SetScript("OnClick", function()
    if sortMode == "dps" then
        sortMode = "dmg"
        sortBtnText:SetText("|cFFFFFFAA[by DMG]|r")
    else
        sortMode = "dps"
        sortBtnText:SetText("|cFFAAAAFF[by DPS]|r")
    end
    HamingwaysDPSmate_UpdateWindow()
end)

-- ============================================================================
-- EVENTS
-- ============================================================================
local eventFrame = CreateFrame("Frame", "HamingwaysDPSmateEvents")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_DIED")
-- Self
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE")
-- Pet
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_PET_HITS")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PET_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
-- Party + their pets
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_PARTY_HITS")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PARTY_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE")
-- Friendly players (same zone, not in group)
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE")

local nextRefresh = 0
eventFrame:SetScript("OnUpdate", function()
    if GetTime() < nextRefresh then return end
    nextRefresh = GetTime() + 1
    HamingwaysDPSmate_UpdateWindow()
end)

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "HamingwaysDPSmate" then
        playerName = UnitName("player")
        -- restore fight history from SavedVariables
        if HamingwaysDPSmateDB.bossHistory then
            bossHistory = HamingwaysDPSmateDB.bossHistory
        end
        if HamingwaysDPSmateDB.generalHistory then
            generalHistory = HamingwaysDPSmateDB.generalHistory
        end
        -- restore class table so history colors survive a restart
        if HamingwaysDPSmateDB.classes then
            for name, cls in pairs(HamingwaysDPSmateDB.classes) do
                if not classes[name] then classes[name] = cls end
            end
        end
        buildPatterns()
        -- apply all display settings from SavedVariables
        local applyOk, applyErr = pcall(ApplySettings)
        if not applyOk then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF4444HDPS ApplySettings error:|r " .. tostring(applyErr))
        end
        -- after /reload while in combat, PLAYER_REGEN_DISABLED won't re-fire
        if UnitAffectingCombat("player") then
            inCombat = true
            combatStart = GetTime()
        end
        HamingwaysDPSmate_UpdateWindow()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00HamingwaysDPSmate|r v0.0.4 loaded. /hdps")

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- New combat: check target classification to decide if this is a boss fight
        local cls = UnitClassification("target")
        isBossFight = (cls == "worldboss")
        currentFightName = UnitName("target") or "Unknown"
        fightSaved = false
        inCombat = true
        combatStart = GetTime()
        ResetSegment(1)
        -- restart overall timers
        for name, e in pairs(data[0]) do
            if type(e) == "table" and not e._start then
                e._start = combatStart
            end
        end
        HamingwaysDPSmate_UpdateWindow()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Left combat: freeze all timers
        local now = GetTime()
        local wasBoss = isBossFight
        inCombat = false
        isBossFight = false
        combatStart = nil
        for s = 0, 1 do
            for name, e in pairs(data[s]) do
                if type(e) == "table" and e._start then
                    e._time = (e._time or 0) + (now - e._start)
                    e._start = nil
                end
            end
        end
        if not fightSaved then
            local lbl = (currentFightName or UnitName("target") or "Fight") .. "  " .. date("%H:%M")
            SaveFight(lbl, wasBoss)
            UpdateHistBtn()
        end
        fightSaved = false
        currentFightName = nil
        HamingwaysDPSmate_UpdateWindow()

    elseif event == "UNIT_DIED" then
        -- Target died: freeze current segment timer (overall keeps running)
        if arg1 == "target" then
            local now = GetTime()
            for name, e in pairs(data[1]) do
                if type(e) == "table" and e._start then
                    e._time = (e._time or 0) + (now - e._start)
                    e._start = nil
                end
            end
            if not fightSaved then
                local lbl = (currentFightName or UnitName("target") or "Unknown") .. "  " .. date("%H:%M")
                SaveFight(lbl, isBossFight)
                fightSaved = true
                UpdateHistBtn()
            end
            HamingwaysDPSmate_UpdateWindow()
        end

    elseif event == "CHAT_MSG_COMBAT_SELF_HITS"
        or event == "CHAT_MSG_SPELL_SELF_DAMAGE"
        or event == "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE"
    then
        if arg1 then tryMatch(patterns, arg1) end

    elseif event == "CHAT_MSG_COMBAT_PET_HITS"
        or event == "CHAT_MSG_SPELL_PET_DAMAGE"
        or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE"
        or event == "CHAT_MSG_COMBAT_PARTY_HITS"
        or event == "CHAT_MSG_SPELL_PARTY_DAMAGE"
        or event == "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE"
        or event == "CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS"
        or event == "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE"
    then
        if arg1 then tryMatch(petPatterns, arg1) end
    end
end)

-- forward declaration so ctxItems closure can reference settingsFrame
local settingsFrame

-- ============================================================================
-- REPORT DPS TO CHAT
-- Iterates current view (live or history) and sends sorted list to a channel.
-- ============================================================================
local function ReportDPS(channel, whisperTarget)
    local activeHist = GetActiveHistory()
    local histEntry  = historyView and activeHist[historyView]
    local seg        = histEntry and histEntry.snapshot or data[segment]

    local players = {}
    for name, entry in pairs(seg) do
        if type(entry) == "table" then
            local active = entry._start and (GetTime() - entry._start) or 0
            local t      = math.max(1, (entry._time or 0) + active)
            local dps    = round((entry._sum or 0) / t, 1)
            local n      = table.getn(players) + 1
            players[n]   = { name=name, total=(entry._sum or 0), dps=dps }
        end
    end

    if table.getn(players) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00HDPS:|r No data to report.")
        return
    end

    if sortMode == "dps" then
        table.sort(players, function(a,b) return a.dps > b.dps end)
    else
        table.sort(players, function(a,b) return a.total > b.total end)
    end

    local grandTotal = 0
    for _, p in ipairs(players) do grandTotal = grandTotal + p.total end

    local segLabel = segment == 1 and "Current" or "Overall"
    if histEntry then segLabel = histEntry.label end
    SendChatMessage("[DPS] " .. segLabel .. ":", channel, nil, whisperTarget)

    for i, p in ipairs(players) do
        if i > 8 then break end
        local pct  = grandTotal > 0 and string.format("%.1f", p.total / grandTotal * 100) or "0.0"
        local line
        if sortMode == "dps" then
            line = i .. ". " .. p.name .. " " .. string.format("%.1f", p.dps) .. " dps (" .. pct .. "%)"
        else
            line = i .. ". " .. p.name .. " " .. p.total .. " dmg (" .. pct .. "%)"
        end
        SendChatMessage(line, channel, nil, whisperTarget)
    end
end

-- ============================================================================
-- RIGHT-CLICK CONTEXT MENU  (shown when right-clicking the title bar)
-- ============================================================================
local CTX_ROW_H = 16
local ctxMenu = CreateFrame("Frame", "HamingwaysDPSmateCtxMenu", UIParent)
ctxMenu:SetFrameStrata("FULLSCREEN_DIALOG")
ctxMenu:SetWidth(130)
ctxMenu:SetHeight(1)
ctxMenu:Hide()

local ctxBg = ctxMenu:CreateTexture(nil, "BACKGROUND")
ctxBg:SetAllPoints(ctxMenu)
ctxBg:SetTexture(0, 0, 0, 0.92)

local ctxBorder = ctxMenu:CreateTexture(nil, "OVERLAY")
ctxBorder:SetAllPoints(ctxMenu)
ctxBorder:SetTexture(0.25, 0.14, 0, 0.9)

local ctxItems = {
    { label="|cFFFFCC88[Say]|r",           fn=function() ReportDPS("SAY") end },
    { label="|cFF88DDFF[Guild]|r",         fn=function() ReportDPS("GUILD") end },
    { label="|cFF88FF88[Party]|r",         fn=function() ReportDPS("PARTY") end },
    { label="|cFFFF8844[Raid]|r",          fn=function() ReportDPS("RAID") end },
    { label="|cFFAAFFAA[Whisper Target]|r",fn=function()
        local t = UnitName("target")
        if t and UnitIsPlayer("target") then
            ReportDPS("WHISPER", t)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00HDPS:|r Target a player first.")
        end
    end },
    { label="|cFFCCCCFF[Settings]|r",      fn=function()
        if settingsFrame:IsShown() then settingsFrame:Hide()
        else settingsFrame:Show() end
    end },
}

local ctxBtns = {}
for i, item in ipairs(ctxItems) do
    local btn = CreateFrame("Button", nil, ctxMenu)
    btn:SetHeight(CTX_ROW_H)
    btn:SetPoint("TOPLEFT",  ctxMenu, "TOPLEFT",  0, -(i-1)*CTX_ROW_H)
    btn:SetPoint("TOPRIGHT", ctxMenu, "TOPRIGHT", 0, -(i-1)*CTX_ROW_H)
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    if math.mod(i,2)==0 then bg:SetTexture(0.12,0.08,0,0.80)
    else                      bg:SetTexture(0.08,0.04,0,0.80) end
    btn.bg = bg
    btn.isEven = (math.mod(i,2)==0)
    local txt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txt:SetPoint("LEFT", btn, "LEFT", 6, 0)
    txt:SetText(item.label)
    btn:SetScript("OnEnter", function() this.bg:SetTexture(0.35, 0.20, 0, 0.95) end)
    btn:SetScript("OnLeave", function()
        if this.isEven then this.bg:SetTexture(0.12,0.08,0,0.80)
        else                 this.bg:SetTexture(0.08,0.04,0,0.80) end
    end)
    local fn = item.fn  -- capture
    btn:SetScript("OnClick", function()
        ctxMenu:Hide()
        fn()
    end)
    ctxBtns[i] = btn
end
ctxMenu:SetHeight(table.getn(ctxItems) * CTX_ROW_H + 2)

-- Dismiss overlay: catches clicks outside the menu to close it
local ctxDismiss = CreateFrame("Frame", nil, UIParent)
ctxDismiss:SetAllPoints(UIParent)
ctxDismiss:SetFrameStrata("FULLSCREEN")
ctxDismiss:EnableMouse(true)
ctxDismiss:Hide()
ctxDismiss:SetScript("OnMouseDown", function() ctxMenu:Hide(); ctxDismiss:Hide() end)

-- Hide context menu when clicking anywhere else
ctxMenu:SetScript("OnHide", function() ctxDismiss:Hide() end)

local function ShowCtxMenu()
    local x, y = GetCursorPosition()
    local s = UIParent:GetScale()
    if s and s > 0 then x, y = x/s, y/s end
    ctxMenu:ClearAllPoints()
    ctxMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    ctxDismiss:Show()
    ctxMenu:Show()
end

-- trigger from right-click anywhere on the main window title bar
mainWin:SetScript("OnMouseDown", function()
    if arg1 == "RightButton" then
        local cx, cy = GetCursorPosition()
        local s = UIParent:GetScale()
        if s and s > 0 then cx, cy = cx/s, cy/s end
        local t = mainWin:GetTop()
        if t and cy >= t - TITLE_H and cy <= t then
            ShowCtxMenu()
        end
    end
end)

-- ============================================================================
-- SETTINGS FRAME
-- Uses only simple Button+FontString (same as the rest of the addon).
-- NO OptionsSliderTemplate, NO UIPanelButtonTemplate, NO EditBox, NO SetScale.
-- ============================================================================
local CFG_W       = 280
local CFG_H       = 420
local CFG_TITLE_H = 16
local CFG_TAB_H   = 14

-- Default settings  (scale removed - SetScale(0) crashes WoW 1.12)
local HDPS_DEFAULTS = { barAlpha=35, rowHeight=15, fontSize=10, bgAlpha=80, fontFace=1 }

GetSettings = function()
    HamingwaysDPSmateDB.settings = HamingwaysDPSmateDB.settings or {}
    local s = HamingwaysDPSmateDB.settings
    if not s.barAlpha  then s.barAlpha  = HDPS_DEFAULTS.barAlpha  end
    if not s.rowHeight then s.rowHeight = HDPS_DEFAULTS.rowHeight end
    if not s.fontSize  then s.fontSize  = HDPS_DEFAULTS.fontSize  end
    if not s.bgAlpha   then s.bgAlpha   = HDPS_DEFAULTS.bgAlpha   end
    if not s.fontFace  then s.fontFace  = HDPS_DEFAULTS.fontFace  end
    return s
end

ApplySettings = function()
    local sv = GetSettings()

    -- row height
    if ROW_H ~= sv.rowHeight then
        ROW_H = sv.rowHeight
        for _, b in ipairs(bars) do b:Hide() end
        bars = {}
        for _, r in ipairs(detailRows) do r:Hide() end
        detailRows = {}
    end

    -- bar fill opacity
    barFillAlpha = sv.barAlpha / 100

    -- background opacity
    local bgA = sv.bgAlpha / 100
    mainBg:SetTexture(0, 0, 0, bgA)
    detailBg:SetTexture(0, 0, 0, math.min(bgA + 0.05, 1))
    ttBg:SetTexture(0, 0, 0, math.min(bgA + 0.05, 1))

    -- font face + size
    local face = (HDPS_FONTS[sv.fontFace] or HDPS_FONTS[1]).file
    local sz   = sv.fontSize
    if face ~= currentFontFace or sz ~= currentFontSize then
        currentFontFace = face
        currentFontSize = sz
        for _, fs in ipairs(hdpsFontStrings) do
            fs:SetFont(currentFontFace, currentFontSize)
        end
        for _, b in ipairs(bars) do b:Hide() end
        bars = {}
        for _, r in ipairs(detailRows) do r:Hide() end
        detailRows = {}
    end

    HamingwaysDPSmate_UpdateWindow()
end

settingsFrame = CreateFrame("Frame", "HamingwaysDPSmateSettings", UIParent)
settingsFrame:SetWidth(CFG_W)
settingsFrame:SetHeight(CFG_H)
settingsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
settingsFrame:SetFrameStrata("DIALOG")
settingsFrame:Hide()
settingsFrame:SetMovable(true)
settingsFrame:EnableMouse(true)
settingsFrame:RegisterForDrag("LeftButton")
settingsFrame:SetScript("OnDragStart", function() settingsFrame:StartMoving() end)
settingsFrame:SetScript("OnDragStop",  function() settingsFrame:StopMovingOrSizing() end)

local cfgBg = settingsFrame:CreateTexture(nil, "BACKGROUND")
cfgBg:SetAllPoints(settingsFrame)
cfgBg:SetTexture(0, 0, 0, 0.92)

-- Title bar
local cfgTitleTex = settingsFrame:CreateTexture(nil, "BACKGROUND")
cfgTitleTex:SetHeight(CFG_TITLE_H)
cfgTitleTex:SetPoint("TOPLEFT",  settingsFrame, "TOPLEFT",  0, 0)
cfgTitleTex:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", 0, 0)
cfgTitleTex:SetTexture(0.15, 0.08, 0, 0.95)

local cfgTitleText = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
cfgTitleText:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 6, -2)
cfgTitleText:SetText("|cFFABD473Hamingway's |r|cFFFFFF00DPSmate|r|cFFCCCCCC - Settings|r")

-- Close button
local cfgCloseBtn = CreateFrame("Button", nil, settingsFrame)
cfgCloseBtn:SetWidth(18)
cfgCloseBtn:SetHeight(CFG_TITLE_H)
cfgCloseBtn:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -2, -1)
local cfgCloseTxt = cfgCloseBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
cfgCloseTxt:SetAllPoints(cfgCloseBtn)
cfgCloseTxt:SetText("|cFFFF4444X|r")
cfgCloseBtn:SetScript("OnClick",  function() settingsFrame:Hide() end)
cfgCloseBtn:SetScript("OnEnter",  function() cfgCloseTxt:SetText("|cFFFFFF44X|r") end)
cfgCloseBtn:SetScript("OnLeave",  function() cfgCloseTxt:SetText("|cFFFF4444X|r") end)

-- Tab toolbar row
local cfgTabTex = settingsFrame:CreateTexture(nil, "BACKGROUND")
cfgTabTex:SetHeight(CFG_TAB_H + 2)
cfgTabTex:SetPoint("TOPLEFT",  settingsFrame, "TOPLEFT",  0, -CFG_TITLE_H)
cfgTabTex:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", 0, -CFG_TITLE_H)
cfgTabTex:SetTexture(0.10, 0.06, 0, 0.95)

local tabAboutBtn = CreateFrame("Button", nil, settingsFrame)
tabAboutBtn:SetWidth(70)
tabAboutBtn:SetHeight(CFG_TAB_H)
tabAboutBtn:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 4, -CFG_TITLE_H - 1)
local tabAboutBg = tabAboutBtn:CreateTexture(nil, "BACKGROUND")
tabAboutBg:SetAllPoints(tabAboutBtn)
tabAboutBg:SetTexture(0.10, 0.06, 0, 0.80)
local tabAboutTxt = tabAboutBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tabAboutTxt:SetAllPoints(tabAboutBtn)
tabAboutTxt:SetJustifyH("LEFT")
tabAboutBtn:SetScript("OnEnter", function() tabAboutBg:SetTexture(0.22, 0.13, 0, 0.90) end)
tabAboutBtn:SetScript("OnLeave", function()
    if aboutPanel:IsShown() then tabAboutBg:SetTexture(0.30, 0.18, 0, 0.90)
    else tabAboutBg:SetTexture(0.10, 0.06, 0, 0.80) end
end)

local tabDisplayBtn = CreateFrame("Button", nil, settingsFrame)
tabDisplayBtn:SetWidth(80)
tabDisplayBtn:SetHeight(CFG_TAB_H)
tabDisplayBtn:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 78, -CFG_TITLE_H - 1)
local tabDisplayBg = tabDisplayBtn:CreateTexture(nil, "BACKGROUND")
tabDisplayBg:SetAllPoints(tabDisplayBtn)
tabDisplayBg:SetTexture(0.10, 0.06, 0, 0.80)
local tabDisplayTxt = tabDisplayBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tabDisplayTxt:SetAllPoints(tabDisplayBtn)
tabDisplayTxt:SetJustifyH("LEFT")
tabDisplayBtn:SetScript("OnEnter", function() tabDisplayBg:SetTexture(0.22, 0.13, 0, 0.90) end)
tabDisplayBtn:SetScript("OnLeave", function()
    if displayPanel:IsShown() then tabDisplayBg:SetTexture(0.30, 0.18, 0, 0.90)
    else tabDisplayBg:SetTexture(0.10, 0.06, 0, 0.80) end
end)

local CFG_PANEL_Y = -(CFG_TITLE_H + CFG_TAB_H + 4)

-- -----------------------------------------------------------------------
-- ABOUT PANEL
-- -----------------------------------------------------------------------
local aboutPanel = CreateFrame("Frame", nil, settingsFrame)
aboutPanel:SetPoint("TOPLEFT",     settingsFrame, "TOPLEFT",     0, CFG_PANEL_Y)
aboutPanel:SetPoint("BOTTOMRIGHT", settingsFrame, "BOTTOMRIGHT", 0, 0)
settingsFrame.aboutPanel = aboutPanel

local portrait = aboutPanel:CreateTexture(nil, "ARTWORK")
portrait:SetWidth(120)
portrait:SetHeight(120)
portrait:SetPoint("TOP", aboutPanel, "TOP", 0, -6)
portrait:SetTexture("Interface\\AddOns\\HamingwaysDPSmate\\images\\Hamingway.tga")

-- One FontString per line to avoid WoW 1.12 multi-line truncation
local greetText = aboutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
greetText:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -132)
greetText:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -132)
greetText:SetJustifyH("CENTER")
greetText:SetText("|cFFFFD100Great tae meet ya!|r")

local aboutLine1 = aboutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
aboutLine1:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -150)
aboutLine1:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -150)
aboutLine1:SetJustifyH("CENTER")
aboutLine1:SetText("|cFFCCCCCCHamingwaysDPSmate v0.0.5|r")

local aboutLine2 = aboutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
aboutLine2:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -163)
aboutLine2:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -163)
aboutLine2:SetJustifyH("CENTER")
aboutLine2:SetText("|cFFCCCCCCA lightweight DPS meter for WoW 1.12 / Turtle WoW.|r")

local aboutLine3 = aboutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
aboutLine3:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -180)
aboutLine3:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -180)
aboutLine3:SetJustifyH("CENTER")
aboutLine3:SetText("|cFFCCCCCCMade by Hamingway|r")

local sepA1 = aboutPanel:CreateTexture(nil, "ARTWORK")
sepA1:SetHeight(1)
sepA1:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -198)
sepA1:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -198)
sepA1:SetTexture(0.4, 0.2, 0, 0.85)

local coffeeLabel = aboutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
coffeeLabel:SetPoint("TOPLEFT", aboutPanel, "TOPLEFT", 6, -206)
coffeeLabel:SetText("|cFFFFD100Buy me a coffee?|r")

local coffeeBox = CreateFrame("EditBox", nil, aboutPanel)
coffeeBox:SetFont("Fonts\\FRIZQT__.TTF", 10)
coffeeBox:SetAutoFocus(false)
coffeeBox:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -220)
coffeeBox:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -220)
coffeeBox:SetHeight(18)
coffeeBox:SetText("https://buymeacoffee.com/x1ndlmeister")
coffeeBox:SetScript("OnEscapePressed",   function() coffeeBox:ClearFocus() end)
coffeeBox:SetScript("OnEnterPressed",    function() coffeeBox:ClearFocus() end)
coffeeBox:SetScript("OnEditFocusGained", function() coffeeBox:HighlightText() end)
coffeeBox:SetScript("OnChar", function()
    coffeeBox:SetText("https://buymeacoffee.com/x1ndlmeister")
    coffeeBox:HighlightText()
end)
local coffeeBoxBg = aboutPanel:CreateTexture(nil, "BACKGROUND")
coffeeBoxBg:SetPoint("TOPLEFT",     aboutPanel, "TOPLEFT",   4, -218)
coffeeBoxBg:SetPoint("BOTTOMRIGHT", aboutPanel, "TOPRIGHT", -4, -240)
coffeeBoxBg:SetTexture(0, 0, 0, 0.5)

local sepA2 = aboutPanel:CreateTexture(nil, "ARTWORK")
sepA2:SetHeight(1)
sepA2:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -246)
sepA2:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -246)
sepA2:SetTexture(0.4, 0.2, 0, 0.85)

local hunterLabel = aboutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hunterLabel:SetPoint("TOPLEFT", aboutPanel, "TOPLEFT", 6, -254)
hunterLabel:SetText("|cFFFFD100Check my Hunter addon too!|r")

local hunterBox = CreateFrame("EditBox", nil, aboutPanel)
hunterBox:SetFont("Fonts\\FRIZQT__.TTF", 9)
hunterBox:SetAutoFocus(false)
hunterBox:SetPoint("TOPLEFT",  aboutPanel, "TOPLEFT",  6, -268)
hunterBox:SetPoint("TOPRIGHT", aboutPanel, "TOPRIGHT", -6, -268)
hunterBox:SetHeight(18)
hunterBox:SetText("https://github.com/x1ndlmeister-create/HamingwaysHunterTools")
hunterBox:SetScript("OnEscapePressed",   function() hunterBox:ClearFocus() end)
hunterBox:SetScript("OnEnterPressed",    function() hunterBox:ClearFocus() end)
hunterBox:SetScript("OnEditFocusGained", function() hunterBox:HighlightText() end)
hunterBox:SetScript("OnChar", function()
    hunterBox:SetText("https://github.com/x1ndlmeister-create/HamingwaysHunterTools")
    hunterBox:HighlightText()
end)
local hunterBoxBg = aboutPanel:CreateTexture(nil, "BACKGROUND")
hunterBoxBg:SetPoint("TOPLEFT",     aboutPanel, "TOPLEFT",   4, -266)
hunterBoxBg:SetPoint("BOTTOMRIGHT", aboutPanel, "TOPRIGHT", -4, -288)
hunterBoxBg:SetTexture(0, 0, 0, 0.5)

-- -----------------------------------------------------------------------
-- DISPLAY PANEL
-- Uses only CreateFrame("Button") + CreateFontString - no templates.
-- -----------------------------------------------------------------------
local displayPanel = CreateFrame("Frame", nil, settingsFrame)
displayPanel:SetPoint("TOPLEFT",     settingsFrame, "TOPLEFT",     0, CFG_PANEL_Y)
displayPanel:SetPoint("BOTTOMRIGHT", settingsFrame, "BOTTOMRIGHT", 0, 0)
displayPanel:Hide()
settingsFrame.displayPanel = displayPanel

-- Generic +/- row.  Returns the value label so caller can refresh it on Open/Reset.
local function MakeAdjRow(parent, yOff, label, minV, maxV, stepV, getVal, applyVal)
    local nameLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yOff)
    nameLbl:SetText("|cFFAAAAAA" .. label .. ":|r")

    local valLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valLbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 150, yOff)
    valLbl:SetWidth(40)
    valLbl:SetJustifyH("LEFT")
    valLbl:SetText("|cFFFFFFFF" .. tostring(getVal()) .. "|r")

    local btnM = CreateFrame("Button", nil, parent)
    btnM:SetWidth(20)
    btnM:SetHeight(14)
    btnM:SetPoint("TOPLEFT", parent, "TOPLEFT", 125, yOff + 1)
    local txtM = btnM:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txtM:SetAllPoints(btnM)
    txtM:SetJustifyH("CENTER")
    txtM:SetText("|cFFFFAAAA<|r")
    btnM:SetScript("OnEnter", function() txtM:SetText("|cFFFFFF44<|r") end)
    btnM:SetScript("OnLeave", function() txtM:SetText("|cFFFFAAAA<|r") end)
    btnM:SetScript("OnClick", function()
        local nv = math.max(minV, getVal() - stepV)
        applyVal(nv)
        valLbl:SetText("|cFFFFFFFF" .. tostring(nv) .. "|r")
    end)

    local btnP = CreateFrame("Button", nil, parent)
    btnP:SetWidth(20)
    btnP:SetHeight(14)
    btnP:SetPoint("TOPLEFT", parent, "TOPLEFT", 196, yOff + 1)
    local txtP = btnP:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txtP:SetAllPoints(btnP)
    txtP:SetJustifyH("CENTER")
    txtP:SetText("|cFFAAAAFF>|r")
    btnP:SetScript("OnEnter", function() txtP:SetText("|cFFFFFF44>|r") end)
    btnP:SetScript("OnLeave", function() txtP:SetText("|cFFAAAAFF>|r") end)
    btnP:SetScript("OnClick", function()
        local nv = math.min(maxV, getVal() + stepV)
        applyVal(nv)
        valLbl:SetText("|cFFFFFFFF" .. tostring(nv) .. "|r")
    end)

    return valLbl
end

local dispY = -8

local barAlphaValLbl = MakeAdjRow(displayPanel, dispY, "Bar Opacity %", 10, 100, 5,
    function() return GetSettings().barAlpha end,
    function(v) GetSettings().barAlpha = v; barFillAlpha = v / 100; HamingwaysDPSmate_UpdateWindow() end)
dispY = dispY - 20

local bgAlphaValLbl = MakeAdjRow(displayPanel, dispY, "Background Opacity %", 20, 100, 5,
    function() return GetSettings().bgAlpha end,
    function(v)
        GetSettings().bgAlpha = v
        local a = v / 100
        mainBg:SetTexture(0, 0, 0, a)
        detailBg:SetTexture(0, 0, 0, math.min(a + 0.05, 1))
        ttBg:SetTexture(0, 0, 0, math.min(a + 0.05, 1))
    end)
dispY = dispY - 20

local rowHtValLbl = MakeAdjRow(displayPanel, dispY, "Row Height px", 10, 22, 1,
    function() return GetSettings().rowHeight end,
    function(v)
        GetSettings().rowHeight = v
        if ROW_H ~= v then
            ROW_H = v
            for _, b in ipairs(bars) do b:Hide() end; bars = {}
            for _, r in ipairs(detailRows) do r:Hide() end; detailRows = {}
            HamingwaysDPSmate_UpdateWindow()
        end
    end)
dispY = dispY - 20

local fontSzValLbl = MakeAdjRow(displayPanel, dispY, "Font Size pt", 7, 16, 1,
    function() return GetSettings().fontSize end,
    function(v)
        GetSettings().fontSize = v
        if currentFontSize ~= v then
            currentFontSize = v
            for _, fs in ipairs(hdpsFontStrings) do fs:SetFont(currentFontFace, currentFontSize) end
            for _, b in ipairs(bars) do b:Hide() end; bars = {}
            for _, r in ipairs(detailRows) do r:Hide() end; detailRows = {}
            HamingwaysDPSmate_UpdateWindow()
        end
    end)
dispY = dispY - 24

-- Font face cycle
local fontFaceLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
fontFaceLbl:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 8, dispY)
fontFaceLbl:SetText("|cFFAAAAAA Font Face:|r")

local fontFaceNameLbl = displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
fontFaceNameLbl:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 95, dispY)
fontFaceNameLbl:SetWidth(120)
fontFaceNameLbl:SetText("|cFFFFFFFF" .. (HDPS_FONTS[1] and HDPS_FONTS[1].name or "Default") .. "|r")

local function RefreshFontFaceLabel()
    local sv = GetSettings()
    local info = HDPS_FONTS[sv.fontFace] or HDPS_FONTS[1]
    fontFaceNameLbl:SetText("|cFFFFFFFF" .. info.name .. "|r")
end

dispY = dispY - 18

local ffPrev = CreateFrame("Button", nil, displayPanel)
ffPrev:SetWidth(20)
ffPrev:SetHeight(14)
ffPrev:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 8, dispY)
local ffPrevTxt = ffPrev:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
ffPrevTxt:SetAllPoints(ffPrev)
ffPrevTxt:SetJustifyH("CENTER")
ffPrevTxt:SetText("|cFFFFAAAA<|r")
ffPrev:SetScript("OnEnter", function() ffPrevTxt:SetText("|cFFFFFF44<|r") end)
ffPrev:SetScript("OnLeave", function() ffPrevTxt:SetText("|cFFFFAAAA<|r") end)
ffPrev:SetScript("OnClick", function()
    local sv = GetSettings()
    local n = table.getn(HDPS_FONTS)
    sv.fontFace = sv.fontFace - 1
    if sv.fontFace < 1 then sv.fontFace = n end
    currentFontFace = (HDPS_FONTS[sv.fontFace] or HDPS_FONTS[1]).file
    RefreshFontFaceLabel()
    for _, fs in ipairs(hdpsFontStrings) do fs:SetFont(currentFontFace, currentFontSize) end
    for _, b in ipairs(bars) do b:Hide() end; bars = {}
    for _, r in ipairs(detailRows) do r:Hide() end; detailRows = {}
    HamingwaysDPSmate_UpdateWindow()
end)

local ffNext = CreateFrame("Button", nil, displayPanel)
ffNext:SetWidth(20)
ffNext:SetHeight(14)
ffNext:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 34, dispY)
local ffNextTxt = ffNext:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
ffNextTxt:SetAllPoints(ffNext)
ffNextTxt:SetJustifyH("CENTER")
ffNextTxt:SetText("|cFFAAAAFF>|r")
ffNext:SetScript("OnEnter", function() ffNextTxt:SetText("|cFFFFFF44>|r") end)
ffNext:SetScript("OnLeave", function() ffNextTxt:SetText("|cFFAAAAFF>|r") end)
ffNext:SetScript("OnClick", function()
    local sv = GetSettings()
    sv.fontFace = math.mod(sv.fontFace, table.getn(HDPS_FONTS)) + 1
    currentFontFace = (HDPS_FONTS[sv.fontFace] or HDPS_FONTS[1]).file
    RefreshFontFaceLabel()
    for _, fs in ipairs(hdpsFontStrings) do fs:SetFont(currentFontFace, currentFontSize) end
    for _, b in ipairs(bars) do b:Hide() end; bars = {}
    for _, r in ipairs(detailRows) do r:Hide() end; detailRows = {}
    HamingwaysDPSmate_UpdateWindow()
end)

dispY = dispY - 24

-- Reset Defaults
local rstBtn = CreateFrame("Button", nil, displayPanel)
rstBtn:SetWidth(110)
rstBtn:SetHeight(14)
rstBtn:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 8, dispY)
local rstTxt = rstBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rstTxt:SetAllPoints(rstBtn)
rstTxt:SetJustifyH("LEFT")
rstTxt:SetText("|cFFFF8844[Reset Defaults]|r")
rstBtn:SetScript("OnEnter", function() rstTxt:SetText("|cFFFFFF44[Reset Defaults]|r") end)
rstBtn:SetScript("OnLeave", function() rstTxt:SetText("|cFFFF8844[Reset Defaults]|r") end)
rstBtn:SetScript("OnClick", function()
    local s = GetSettings()
    for k, v in pairs(HDPS_DEFAULTS) do s[k] = v end
    barAlphaValLbl:SetText("|cFFFFFFFF" .. s.barAlpha  .. "|r")
    bgAlphaValLbl:SetText("|cFFFFFFFF" .. s.bgAlpha   .. "|r")
    rowHtValLbl:SetText(  "|cFFFFFFFF" .. s.rowHeight .. "|r")
    fontSzValLbl:SetText( "|cFFFFFFFF" .. s.fontSize  .. "|r")
    RefreshFontFaceLabel()
    ApplySettings()
end)

-- Tab switching
local function SetCfgTab(which)
    if which == "about" then
        tabAboutTxt:SetText("|cFFFFFF00[About]|r")
        tabAboutBg:SetTexture(0.30, 0.18, 0, 0.90)
        tabDisplayTxt:SetText("|cFFAAAAAA[Display]|r")
        tabDisplayBg:SetTexture(0.10, 0.06, 0, 0.80)
        aboutPanel:Show()
        displayPanel:Hide()
    else
        tabAboutTxt:SetText("|cFFAAAAAA[About]|r")
        tabAboutBg:SetTexture(0.10, 0.06, 0, 0.80)
        tabDisplayTxt:SetText("|cFFFFFF00[Display]|r")
        tabDisplayBg:SetTexture(0.30, 0.18, 0, 0.90)
        aboutPanel:Hide()
        displayPanel:Show()
    end
end

tabAboutBtn:SetScript("OnClick",   function() SetCfgTab("about") end)
tabDisplayBtn:SetScript("OnClick", function() SetCfgTab("display") end)

settingsFrame:SetScript("OnShow", function()
    local sv = GetSettings()
    barAlphaValLbl:SetText("|cFFFFFFFF" .. sv.barAlpha  .. "|r")
    bgAlphaValLbl:SetText("|cFFFFFFFF" .. sv.bgAlpha   .. "|r")
    rowHtValLbl:SetText(  "|cFFFFFFFF" .. sv.rowHeight .. "|r")
    fontSzValLbl:SetText( "|cFFFFFFFF" .. sv.fontSize  .. "|r")
    RefreshFontFaceLabel()
    SetCfgTab("about")
end)

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================
SLASH_HDPS1 = "/hdps"
SlashCmdList["HDPS"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reset" then
        ResetAll()
        HamingwaysDPSmate_UpdateWindow()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00HDPS:|r All data reset.")
    elseif msg == "resetcurrent" then
        ResetSegment(1)
        HamingwaysDPSmate_UpdateWindow()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00HDPS:|r Current reset.")
    elseif msg == "show" then
        mainWin:Show()
    elseif msg == "hide" then
        mainWin:Hide()
        detailWin:Hide()
    elseif msg == "settings" or msg == "config" or msg == "options" then
        if settingsFrame:IsShown() then settingsFrame:Hide()
        else settingsFrame:Show() end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00HamingwaysDPSmate:|r /hdps reset | resetcurrent | show | hide | settings")
    end
end
