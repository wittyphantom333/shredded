--[[
    Shredded - Feral Druid Combat Tracker
    Version 1.0.0 - Midnight Update 
    
    Tracks: 
    - Timer Bars: DoTs (Rip, Rake, Thrash, Moonfire), maintained buffs
    - Proc Icons: Procs (Clearcasting, Bloodtalons, Ravage, Apex Predator, etc.)
    - Resources: Energy, Combo Points
]]

local addonName, Shredded = ...

-- Saved Variables
ShreddedSettings = ShreddedSettings or {}

-- Addon state (must be global/file-level for cross-function access)
local addonInitialized = false
local barMove = 0

-- Performance: throttle update rates
local lastFullUpdate = 0
local lastAuraRefresh = 0
local UPDATE_INTERVAL = 0.1      -- 100ms for UI updates (10 FPS is plenty)
local AURA_REFRESH_INTERVAL = 0.2 -- 200ms for aura polling
local isDirty = true              -- Flag to force update when something changes

-- Ticker references (replaces OnUpdate for better performance)
local mainTicker = nil
local pollTicker = nil

-- Local references for performance
local GetTime = GetTime
local UnitGUID = UnitGUID
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local GetShapeshiftForm = GetShapeshiftForm
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame
local UIParent = UIParent
local pairs = pairs
local floor = math.floor
local wipe = wipe
local tContains = tContains

-- Safe number extraction (handles WoW "secret" values)
-- Uses multiple extraction methods as fallback chain
local function SafeNumber(val, default)
    if val == nil then return default or 0 end
    -- Method 1: Direct tonumber (works for real numbers)
    local result = tonumber(val)
    if result then return result end
    -- Method 2: string.format extraction (works for secret values per Midnight API)
    local ok, formatted = pcall(string.format, "%.3f", val)
    if ok then
        result = tonumber(formatted)
        if result then return result end
    end
    -- Method 3: tostring chain (fallback)
    result = tonumber(tostring(val))
    if result then return result end
    return default or 0
end

-- Check if a value is a secret (can't be compared in Lua)
local function IsSecretValue(val)
    if val == nil then return false end
    -- Try a simple comparison - if it errors or returns false unexpectedly, it's secret
    local ok, result = pcall(function() return val == val end)
    if not ok then return true end
    -- Also check if we can extract a number
    local num = tonumber(val)
    return num == nil and type(val) ~= "string" and type(val) ~= "boolean"
end

-- Debug output
function ShreddedO(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00Shredded:|r " .. tostring(text))
end

-- Verbose debug mode (toggle with /shredded verbose)
Shredded_VerboseDebug = false
local lastVerboseTime = 0

local function ShreddedV(text)
    if Shredded_VerboseDebug then
        local now = GetTime()
        if now - lastVerboseTime > 0.5 then -- Throttle to avoid spam
            ShreddedO("[V] " .. tostring(text))
            lastVerboseTime = now
        end
    end
end

-- Modern API helper for spell info
local function GetSpellName(spellId)
    if not spellId then return nil end
    local spellInfo = C_Spell.GetSpellInfo(spellId)
    return spellInfo and spellInfo.name
end

local function GetSpellTexture(spellId)
    if not spellId then return nil end
    local spellInfo = C_Spell.GetSpellInfo(spellId)
    return spellInfo and spellInfo.iconID
end

-- Helper to extract numeric value from potentially secret data
-- Must be defined early since it's used throughout
local function ExtractNumber(func)
    local ok, result = pcall(func)
    if ok and result and type(result) == "number" then
        return result
    end
    return nil
end

-- Check if player knows a spell
local function PlayerKnowsSpell(spellId)
    if not spellId or type(spellId) ~= "number" then return false end
    -- IsSpellKnown checks if spell is in spellbook
    if IsSpellKnown(spellId) then return true end
    -- Also check if it's a buff/passive we might get
    if IsPlayerSpell(spellId) then return true end
    return false
end

-- ===========================================
-- SPELL DEFINITIONS - All Possible Feral Spells
-- ===========================================

-- Source types for tooltip display
local SOURCE_TYPES = {
    CORE = "Core Ability",
    CLASS_TALENT = "Class Talent",
    SPEC_TALENT = "Feral Talent",
    SPEC_ABILITY = "Feral Ability",
    HERO_CLAW = "Hero: Druid of the Claw",
    HERO_WILD = "Hero: Wildstalker",
    HERO_MOON = "Hero: Keeper of the Grove",
    RESOURCE = "Resource",
}

-- Master list of ALL possible Feral spells (with metadata)
-- Includes source info for tooltips and availability checking
local SPELL_DATABASE = {
    -- ===== RESOURCES (always tracked) =====
    { key = "ENERGY", id = "Energy", type = "resource", core = true, 
      source = SOURCE_TYPES.RESOURCE, tooltip = "Primary resource for Feral abilities" },
    { key = "COMBO", id = "Combo", type = "resource", core = true,
      source = SOURCE_TYPES.RESOURCE, tooltip = "Combo Points - spent on finishers" },
    
    -- ===== CORE ABILITIES (always available) =====
    { key = "TIGERS_FURY", id = 5217, type = "buff", core = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Feral Tier 1 - Instant energy and damage boost" },
    { key = "THRASH", id = 106830, type = "debuff", core = true,
      source = SOURCE_TYPES.CORE, tooltip = "Class ability (level 11) - AoE bleed" },
    
    -- ===== CLASS TALENTS =====
    { key = "RAKE", id = 155722, altIds = {1822, 163505}, type = "debuff", core = true,
      source = SOURCE_TYPES.CLASS_TALENT, tooltip = "Class Tier 1 - Bleed and slow (auto for Feral)" },
    { key = "RIP", id = 1079, type = "debuff", core = true,
      source = SOURCE_TYPES.CLASS_TALENT, tooltip = "Class Tier 3 - Powerful finisher bleed" },
    
    -- ===== FERAL SPEC ABILITIES =====
    { key = "PREDATORY_SWIFTNESS", id = 69369, altIds = {69369, 16974}, type = "buff", core = true, isProc = true,
      source = SOURCE_TYPES.SPEC_ABILITY, tooltip = "Feral (level 30) - Free instant heal after finisher" },
    { key = "CLEARCASTING", id = 135700, talentId = 16864, altIds = {135700, 16870, 16864}, type = "buff", isProc = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Omen of Clarity (Tier 2) - Free ability proc" },
      
    -- ===== FERAL SPEC TALENTS =====
    { key = "PRIMAL_WRATH", id = 285381, type = "debuff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 2 - AoE Rip application" },
    { key = "SABERTOOTH", id = 202031, type = "debuff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 4 - Ferocious Bite extends Rip (debuff on target)" },
    { key = "SUDDEN_AMBUSH", id = 391974, talentId = 384667, altIds = {391974, 384667}, type = "buff", isProc = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 6 - Stealth ability proc" },
    { key = "MOMENT_OF_CLARITY", id = 155577, talentId = 155577, type = "buff", isPassive = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 6 - Passive: Clearcasting has 2 charges (NOT a proc)" },
    { key = "BERSERK", id = 106951, talentId = 106951, type = "buff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 6 - Major cooldown, reduced costs" },
    { key = "WILD_SLASHES", id = 390864, type = "buff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 7 - Enhanced Swipe/Thrash" },
    { key = "SOUL_OF_THE_FOREST", id = 114107, type = "buff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 7 - Finisher energy refund" },
    { key = "CARNIVOROUS_INSTINCT", id = 390902, type = "buff", isPassive = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 8 - Tiger's Fury damage bonus (passive)" },
    { key = "FRANTIC_MOMENTUM", id = 391876, talentId = 391875, type = "buff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 8 - Haste during Berserk" },
    { key = "APEX_PREDATOR", id = 391882, talentId = 391881, type = "buff", isProc = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 9 - Free Ferocious Bite proc" },
    { key = "FERAL_FRENZY", id = 274837, talentId = 274837, altIds = {274838, 274839}, type = "debuff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Choice node - Single target burst bleed",
      overriddenBy = 1243807 },  -- Hidden when Frantic Frenzy overrides it
    { key = "FRANTIC_FRENZY", id = 1243807, debuffId = 1244079, talentId = 1243807, altIds = {1243807, 1244079}, displayName = "Frantic Frenzy", type = "debuff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Choice node - AoE burst bleed",
      detectViaOverride = 274837 },  -- Detected via GetOverrideSpell(274837)
    { key = "INCARNATION", id = 102543, type = "buff", isCooldown = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 9 - Avatar of Ashamane (replaces Berserk)" },
    { key = "CONVOKE", id = 391528, talentId = 391528, type = "buff", isCooldown = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 9 - Convoke the Spirits" },
    { key = "MOONFIRE_CAT", id = 155625, talentId = 155580, type = "debuff",
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 10 - Lunar Inspiration Moonfire" },
    { key = "BLOODTALONS", id = 145152, talentId = 319439, type = "buff", isProc = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 10 - Empowered bleed procs" },
    { key = "CIRCLE_OF_LIFE", id = 400320, type = "buff", isPassive = true,
      source = SOURCE_TYPES.SPEC_TALENT, tooltip = "Tier 10 - DoT duration changes (passive)" },
      
    -- ===== HERO TALENTS: Druid of the Claw =====
    { key = "RAVAGE", id = 441585, altIds = {441585, 441591, 441583}, type = "buff", isProc = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Row 1 - Empowered Shred ability (proc)" },
    { key = "DREADFUL_WOUND", id = 451177, altIds = {451177, 391356, 441583, 441590}, displayName = "Dreadful Wound", type = "debuff", core = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Ravage debuff on target" },
    { key = "INFECTED_WOUNDS", id = 58180, altIds = {58180, 48484}, displayName = "Infected Wounds", type = "debuff", core = true,
      source = SOURCE_TYPES.CLASS_TALENT, tooltip = "Healing reduction/slow on target" },
    { key = "KILLING_STRIKES", id = 441825, altIds = {441825, 441824}, displayName = "Killing Strikes", type = "buff", isProc = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Ravage proc - increased crit damage" },
    { key = "SAVAGE_FURY", id = 449646, altIds = {449646, 449645}, displayName = "Savage Fury", type = "buff", isProc = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Druid of the Claw - empowered attacks" },
    { key = "COILED_TO_SPRING", id = 449651, altIds = {449651, 449650, 449537}, displayName = "Coiled to Spring", type = "buff", isProc = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Druid of the Claw - next ability empowered" },
    { key = "BESTIAL_STRENGTH", id = 441841, type = "buff", isPassive = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Row 2 - Damage increase (passive)" },
    { key = "WILDSHAPE_MASTERY", id = 441678, type = "buff", isPassive = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Row 3 - Improved shapeshifting (passive)" },
    { key = "EMPOWERED_SHAPESHIFTING", id = 441689, type = "buff", isPassive = true,
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Row 4 - Stats in forms (passive)" },
    { key = "CLAW_RAMPAGE", id = 441835, type = "buff",
      source = SOURCE_TYPES.HERO_CLAW, tooltip = "Row 5 - Ravage enhancement" },
      
    -- ===== HERO TALENTS: Wildstalker =====
    { key = "THRIVING_GROWTH", id = 439528, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 1 - HoT/DoT synergy" },
    { key = "STRATEGIC_INFUSION", id = 439890, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 2 - Proc enhancement" },
    { key = "WILDSTALKER_POWER", id = 439926, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 2 - Damage bonus" },
    { key = "LETHAL_PRESERVATION", id = 455461, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 3 - Survival + damage" },
    { key = "BURSTING_GROWTH", id = 440120, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 3 - DoT spread" },
    { key = "BOND_WITH_NATURE", id = 439929, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 3 - Healing increase" },
    { key = "RESILIENT_FLOURISHING", id = 439880, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 4 - Bleed enhancement" },
    { key = "ROOT_NETWORK", id = 439882, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 4 - Target linking" },
    { key = "TWIN_SPROUTS", id = 440117, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 4 - Double applications" },
    { key = "VIGOROUS_CREEPERS", id = 440119, type = "buff",
      source = SOURCE_TYPES.HERO_WILD, tooltip = "Row 5 - Ultimate enhancement" },
}

-- Active spell tracking (populated dynamically)
local SPELL_IDS = {}
Shredded_ACTIVE_SPELLS = {} -- Spells the player currently has (global for debug)
local ACTIVE_SPELLS = Shredded_ACTIVE_SPELLS

-- Spell names (populated on load) - made global for debugging
Shredded_SPELL_NAMES = {}
Shredded_SPELL_ICONS = {}
local SPELL_NAMES = Shredded_SPELL_NAMES
local SPELL_ICONS = Shredded_SPELL_ICONS

-- Reverse lookup: spellId -> spellKey (for CLEU tracking and UNIT_AURA)
Shredded_SPELL_ID_TO_KEY = {}
local SPELL_ID_TO_KEY = Shredded_SPELL_ID_TO_KEY

-- Forward declaration for name lookup builder
local SPELL_NAME_TO_KEY = {}
local function BuildSpellNameLookup()
    wipe(SPELL_NAME_TO_KEY)
    for key, name in pairs(SPELL_NAMES) do
        if type(name) == "string" then
            SPELL_NAME_TO_KEY[name] = key
        end
    end
end

-- Scan and populate active spells based on what player knows
local function ScanPlayerSpells()
    wipe(SPELL_IDS)
    wipe(ACTIVE_SPELLS)
    wipe(SPELL_NAMES)
    wipe(SPELL_ICONS)
    wipe(SPELL_ID_TO_KEY)  -- Also clear reverse lookup
    
    local count = 0
    for _, spellData in ipairs(SPELL_DATABASE) do
        local key = spellData.key
        local id = spellData.id
        
        -- Resources always included
        if spellData.type == "resource" then
            SPELL_IDS[key] = id
            SPELL_NAMES[key] = id
            ACTIVE_SPELLS[key] = spellData
            count = count + 1
        elseif type(id) == "number" then
            -- Check if player has this spell (core = always, talent = check)
            local shouldInclude = false
            if spellData.core then
                shouldInclude = true
            elseif spellData.displayName then
                -- Has hardcoded display name - include it (spell info available even if API fails)
                shouldInclude = true
            else
                -- For talents, check if spell exists and player knows related ability
                local spellName = GetSpellName(id)
                if spellName then
                    -- Spell exists in game, include it (will only show if buff/debuff is active)
                    shouldInclude = true
                end
                -- Also check alternate IDs
                if not shouldInclude and spellData.altIds then
                    for _, altId in ipairs(spellData.altIds) do
                        local altName = GetSpellName(altId)
                        if altName then
                            shouldInclude = true
                            break
                        end
                    end
                end
            end
            
            if shouldInclude then
                local spellName = spellData.displayName or GetSpellName(id)
                -- Try alternate IDs for name/icon if primary fails
                if not spellName and spellData.altIds then
                    for _, altId in ipairs(spellData.altIds) do
                        spellName = GetSpellName(altId)
                        if spellName then break end
                    end
                end
                
                if spellName then
                    SPELL_IDS[key] = id
                    SPELL_NAMES[key] = spellName
                    ACTIVE_SPELLS[key] = spellData
                    SPELL_ID_TO_KEY[id] = key  -- Reverse lookup for CLEU
                    
                    -- Also add alternate IDs to reverse lookup
                    if spellData.altIds then
                        for _, altId in ipairs(spellData.altIds) do
                            SPELL_ID_TO_KEY[altId] = key
                        end
                    end
                    
                    local texture = GetSpellTexture(id)
                    -- Try alternate IDs for icon if primary fails
                    if not texture and spellData.altIds then
                        for _, altId in ipairs(spellData.altIds) do
                            texture = GetSpellTexture(altId)
                            if texture then break end
                        end
                    end
                    if texture then
                        SPELL_ICONS[key] = texture
                    end
                    count = count + 1
                end
            end
        end
    end
    
    -- Manual icon assignments for resources
    SPELL_ICONS["ENERGY"] = 7549437 -- Ability_Druid_Catform icon ID
    SPELL_ICONS["COMBO"] = 5905217 -- Combo point icon
    
    -- FORCE icon assignments for all proc icons that may have API issues
    -- These are set unconditionally to ensure procs always have visible icons
    -- Druid of the Claw hero talents (TWW)
    SPELL_ICONS["RAVAGE"] = SPELL_ICONS["RAVAGE"] or 5927625  -- inv_ability_movespeedbuff (ravage icon)
    SPELL_ICONS["SAVAGE_FURY"] = 236159  -- ability_druid_kingofthejungle
    SPELL_ICONS["KILLING_STRIKES"] = 236159  -- Same icon as Savage Fury (they share in-game)
    SPELL_ICONS["COILED_TO_SPRING"] = 132142  -- ability_druid_supriseattack
    
    -- Core/Spec procs
    SPELL_ICONS["PREDATORY_SWIFTNESS"] = SPELL_ICONS["PREDATORY_SWIFTNESS"] or 132252  -- spell_nature_ravenform (free heal proc)
    SPELL_ICONS["CLEARCASTING"] = SPELL_ICONS["CLEARCASTING"] or 136170  -- spell_shadow_manaburn (omen of clarity)
    
    -- Spec talent procs
    SPELL_ICONS["SUDDEN_AMBUSH"] = SPELL_ICONS["SUDDEN_AMBUSH"] or 132167  -- ability_hunter_catlikereflexes
    SPELL_ICONS["BLOODTALONS"] = SPELL_ICONS["BLOODTALONS"] or 1033474  -- spell_druid_bloodythrash
    SPELL_ICONS["APEX_PREDATOR"] = SPELL_ICONS["APEX_PREDATOR"] or 132139  -- ability_druid_primaltenacity
    
    -- Major Cooldowns (show when ready, show CD when used)
    SPELL_ICONS["INCARNATION"] = SPELL_ICONS["INCARNATION"] or 571586  -- Ability_Druid_IncarnAshaman
    SPELL_ICONS["CONVOKE"] = SPELL_ICONS["CONVOKE"] or 3565445  -- Ability_Ardenweald_Druid
    
    return count
end

-- Forward declaration for spellbook scanner (defined later after SPELL_DATABASE)
local ScanSpellbook

-- Ensure all proc/cooldown spell IDs are in SPELL_ID_TO_KEY for UNIT_AURA tracking
local function EnsureProcIDsRegistered()
    for _, key in ipairs(ShreddedCooldownSpells) do
        local meta = Shredded_SpellMeta[key]
        if meta then
            -- Add primary ID
            if meta.id and type(meta.id) == "number" then
                SPELL_ID_TO_KEY[meta.id] = key
            end
            -- Add talent ID
            if meta.talentId and type(meta.talentId) == "number" then
                SPELL_ID_TO_KEY[meta.talentId] = key
            end
            -- Add alternate IDs
            if meta.altIds then
                for _, altId in ipairs(meta.altIds) do
                    if type(altId) == "number" then
                        SPELL_ID_TO_KEY[altId] = key
                    end
                end
            end
        end
    end
end

-- Initialize spell data
local function InitSpellData()
    if ScanSpellbook then ScanSpellbook() end  -- Scan what spells player knows
    local foundCount = ScanPlayerSpells()
    BuildSpellNameLookup()  -- Build name->key lookup for name matching
    EnsureProcIDsRegistered()  -- Make sure all proc IDs are registered for UNIT_AURA
    ShreddedO("Found " .. foundCount .. " trackable abilities")
end

-- Rescan spells (call after talent change)
function Shredded_RescanSpells()
    if ScanSpellbook then ScanSpellbook() end  -- Rescan what spells player knows
    local count = ScanPlayerSpells()
    BuildSpellNameLookup()  -- Rebuild name lookup
    EnsureProcIDsRegistered()  -- Re-register proc IDs
    ShreddedO("Rescanned: " .. count .. " abilities found")
    -- Rebuild bar order for new spells
    if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
    exportBarOrder()
    Shredded_Refresh()
end

-- Create debug window with copyable text
local debugFrame = nil
local function ShowDebugWindow(text)
    if not debugFrame then
        debugFrame = CreateFrame("Frame", "ShreddedDebugFrame", UIParent, "BackdropTemplate")
        debugFrame:SetSize(500, 400)
        debugFrame:SetPoint("CENTER")
        debugFrame:SetMovable(true)
        debugFrame:EnableMouse(true)
        debugFrame:RegisterForDrag("LeftButton")
        debugFrame:SetScript("OnDragStart", debugFrame.StartMoving)
        debugFrame:SetScript("OnDragStop", debugFrame.StopMovingOrSizing)
        debugFrame:SetFrameStrata("DIALOG")
        debugFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 }
        })
        
        -- Title
        local title = debugFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -12)
        title:SetText("Shredded Debug - Select All & Copy")
        
        -- Scroll frame
        local scrollFrame = CreateFrame("ScrollFrame", "ShreddedDebugScroll", debugFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 12, -40)
        scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
        
        -- Edit box (multiline, copyable)
        local editBox = CreateFrame("EditBox", "ShreddedDebugEditBox", scrollFrame)
        editBox:SetMultiLine(true)
        editBox:SetFontObject(GameFontHighlightSmall)
        editBox:SetWidth(440)
        editBox:SetAutoFocus(false)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        scrollFrame:SetScrollChild(editBox)
        
        debugFrame.editBox = editBox
        
        -- Close button
        local closeBtn = CreateFrame("Button", nil, debugFrame, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -5, -5)
        
        -- Select All button
        local selectBtn = CreateFrame("Button", nil, debugFrame, "UIPanelButtonTemplate")
        selectBtn:SetSize(100, 22)
        selectBtn:SetPoint("BOTTOM", 0, 10)
        selectBtn:SetText("Select All")
        selectBtn:SetScript("OnClick", function()
            debugFrame.editBox:SetFocus()
            debugFrame.editBox:HighlightText()
        end)
    end
    
    -- Handle secret values - try to set text, fallback to error message
    local success = pcall(function()
        debugFrame.editBox:SetText(text or "No data")
    end)
    if not success then
        debugFrame.editBox:SetText("Cannot display debug data in combat (secret values)")
    end
    debugFrame:Show()
end

-- Expose for options file
function Shredded_ShowDebugPopup(text)
    ShowDebugWindow(text)
end

-- Debug function (uses global timers)
function Shredded_Debug()
    local lines = {}
    local function addLine(text)
        table.insert(lines, tostring(text))
    end
    
    local ok, err = pcall(function()
        addLine("=== Shredded Debug (Midnight API) ===")
        
        local count = 0
        for key, data in pairs(ACTIVE_SPELLS) do
            count = count + 1
        end
        addLine("Active spells tracked: " .. count)
        
        -- Helper: convert secret to number via string
        local function toNum(val)
            return tonumber(tostring(val)) or 0
        end
        
        -- Show spell icons we're looking for (for icon-based matching)
        addLine("--- Spell Icons for Matching ---")
        local iconCount = 0
        for key, icon in pairs(SPELL_ICONS) do
            if type(icon) == "number" then
                iconCount = iconCount + 1
                if iconCount <= 5 then
                    addLine(key .. " -> " .. icon)
                end
            end
        end
        if iconCount > 5 then
            addLine("... and " .. (iconCount - 5) .. " more icons")
        end
        
        -- Show spell names we're looking for (for name-based matching)
        addLine("--- Spell Names for Matching ---")
        local nameCount = 0
        for key, name in pairs(SPELL_NAMES) do
            if type(name) == "string" then
                nameCount = nameCount + 1
                if nameCount <= 10 then  -- Limit output
                    addLine(key .. " -> \"" .. name .. "\"")
                end
            end
        end
        if nameCount > 10 then
            addLine("... and " .. (nameCount - 10) .. " more")
        end
        
        -- Show spells detected from spellbook scan
        addLine("")
        addLine("--- Known Spells (from Spellbook) ---")
        local knownCount = 0
        for spellId in pairs(Shredded_KnownSpellIDs) do
            knownCount = knownCount + 1
        end
        addLine("Total known spell IDs: " .. knownCount)
        
        -- Show which of our tracked spells are available
        addLine("")
        addLine("--- Spell Availability Check ---")
        for _, key in ipairs(ShreddedCooldownSpells) do
            local hasIt = Shredded_PlayerHasSpell(key)
            local meta = Shredded_SpellMeta[key]
            local info = ""
            if meta then
                local id = meta.id
                local talentId = meta.talentId
                info = "id=" .. tostring(id)
                if talentId then info = info .. " talent=" .. tostring(talentId) end
                info = info .. " src=" .. tostring(meta.source)
                -- Show API check results
                if type(id) == "number" then
                    local ips = IsPlayerSpell(id) and "Y" or "N"
                    local isk = IsSpellKnown(id) and "Y" or "N"
                    info = info .. " IPS=" .. ips .. " ISK=" .. isk
                end
                if talentId and type(talentId) == "number" then
                    local ips = IsPlayerSpell(talentId) and "Y" or "N"
                    local isk = IsSpellKnown(talentId) and "Y" or "N"
                    info = info .. " TalIPS=" .. ips .. " TalISK=" .. isk
                end
            end
            addLine(key .. ": " .. (hasIt and "YES" or "no") .. " (" .. info .. ")")
        end
    
        addLine("")
        addLine("--- Active Auras (Shredded_auraRawData) ---")
        local auraCount = 0
        for key, data in pairs(Shredded_auraRawData) do
            auraCount = auraCount + 1
            local src = data.fromSelfTrack and " [SELF]" or (data.fromCLEU and " [CLEU]" or " [API]")
            local remaining = data.expirationTime and (data.expirationTime - GetTime()) or 0
            addLine(key .. ": " .. string.format("%.1f", remaining) .. "s" .. src)
        end
        if auraCount == 0 then
            addLine("No auras currently active")
        end
        
        addLine("--- Self-Tracking (captured timings) ---")
        local selfPlayerCount = 0
        for key, data in pairs(Shredded_selfTrack.player) do
            selfPlayerCount = selfPlayerCount + 1
            local remaining = data.expirationTime - GetTime()
            local src = data.fromAPI and "[API]" or (data.fromBase and "[BASE]" or "[?]")
            addLine("Player " .. key .. ": " .. string.format("%.1f", remaining) .. "s " .. src)
        end
        local selfTargetCount = 0
        for key, data in pairs(Shredded_selfTrack.target) do
            selfTargetCount = selfTargetCount + 1
            local remaining = data.expirationTime - GetTime()
            local src = data.fromAPI and "[API]" or (data.fromBase and "[BASE]" or "[?]")
            addLine("Target " .. key .. ": " .. string.format("%.1f", remaining) .. "s " .. src)
        end
        if selfPlayerCount == 0 and selfTargetCount == 0 then
            addLine("No self-tracked auras")
        end
        
        addLine("--- Timer States (1=active, 0=inactive) ---")
        for key, val in pairs(Shredded_timers) do
            if key ~= "ENERGY" and key ~= "COMBO" then
                addLine(key .. ": " .. tostring(val))
            end
        end
    
        addLine("--- Test Direct Aura Lookup ---")
        local tfId = SPELL_IDS["TIGERS_FURY"]
        addLine("TF Spell ID: " .. tostring(tfId))
    
        -- Test direct lookup
        if tfId then
            local auraData = C_UnitAuras.GetPlayerAuraBySpellID(tfId)
            addLine("Direct lookup: " .. tostring(auraData ~= nil))
            if auraData then
                addLine("  Has expirationTime: " .. tostring(auraData.expirationTime ~= nil))
                addLine("  Has duration: " .. tostring(auraData.duration ~= nil))
            end
        end
    
        -- List all player buffs we can see
        addLine("--- All Player Buffs ---")
        local buffCount = 0
        for i = 1, 40 do
            local auraData = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not auraData then break end
            buffCount = buffCount + 1
            -- Safely extract data - all fields might be secret
            local spellId = Shredded_ToNum(auraData.spellId)
            local name = "[secret]"
            local icon = "[secret]"
            pcall(function() 
                local n = auraData.name
                if n and not issecretvalue(n) then
                    name = tostring(n)
                end
            end)
            pcall(function()
                local ic = auraData.icon
                if ic and not issecretvalue(ic) then
                    icon = tostring(ic)
                end
            end)
            pcall(function() addLine(i .. ": " .. name .. " (ID:" .. spellId .. ") icon:" .. icon) end)
        end
        addLine("Total buffs found: " .. buffCount)
        
        -- List all target debuffs
        addLine("--- Target Debuffs ---")
        local debuffCount = 0
        for i = 1, 40 do
            local auraData = C_UnitAuras.GetAuraDataByIndex("target", i, "HARMFUL")
            if not auraData then break end
            debuffCount = debuffCount + 1
            -- Safely extract data - all fields might be secret
            local spellId = Shredded_ToNum(auraData.spellId)
            local name = "[secret]"
            local source = "[secret]"
            pcall(function() 
                local n = auraData.name
                if n and not issecretvalue(n) then
                    name = tostring(n)
                end
            end)
            pcall(function() 
                local s = auraData.sourceUnit
                if s and not issecretvalue(s) then
                    source = tostring(s)
                end
            end)
            pcall(function() addLine(i .. ": " .. name .. " (ID:" .. spellId .. ") from " .. source) end)
        end
        addLine("Total debuffs found: " .. debuffCount)
    
        -- Debug bar order (wrap in pcall since barOrder is local)
        addLine("--- Bar Order ---")
        local barOrderOk = pcall(function()
            if ShreddedSettings and ShreddedSettings["barorder"] then
                for frame, spell in pairs(ShreddedSettings["barorder"]) do
                    local hasAura = Shredded_auraRawData[spell] and "ACTIVE" or "inactive"
                    addLine(frame .. " -> " .. tostring(spell) .. " (" .. hasAura .. ")")
                end
            else
                addLine("barorder not found in settings")
            end
        end)
        if not barOrderOk then addLine("Error reading bar order") end
    
        -- Check baron settings
        addLine("--- Baron Settings ---")
        if ShreddedSettings and ShreddedSettings["baron"] then
            addLine("TIGERS_FURY baron: " .. tostring(ShreddedSettings["baron"]["TIGERS_FURY"]))
            addLine("ENERGY baron: " .. tostring(ShreddedSettings["baron"]["ENERGY"]))
            addLine("catbarson: " .. tostring(ShreddedSettings["catbarson"]))
        else
            addLine("Baron settings not found")
        end
        
        -- Check actual bar visibility
        addLine("--- Bar Visibility ---")
        for i = 1, 5 do
            local frameName = "ShreddedBar" .. i
            local mainFrame = ShreddedBarList[frameName]
            local barFrame = ShreddedBarBarList[frameName]
            
            local isShown = "?"
            local barVal = "?"
            local spell = "?"
            
            pcall(function() isShown = mainFrame and mainFrame:IsShown() and "yes" or "no" end)
            pcall(function() 
                local v = barFrame and barFrame:GetValue() or 0
                barVal = tostring(tonumber(tostring(v)) or 0)
            end)
            pcall(function() spell = tostring(ShreddedSettings["barorder"][frameName] or "none") end)
            
            addLine(frameName .. ": " .. spell .. " shown=" .. isShown .. " val=" .. barVal)
        end
    
        -- Also test Energy
        addLine("--- Energy Test ---")
        local form = GetShapeshiftForm()
        addLine("Current Form: " .. tostring(form) .. " (2=Cat)")
    
        -- Show cached values
        addLine("Cached Energy: " .. Shredded_cachedEnergy)
        addLine("Cached Combo: " .. Shredded_cachedCombo)
        
        -- Test SetTimerDuration availability
        addLine("--- API Test ---")
        local testBar = ShreddedBarBarList["ShreddedBar1"]
        if testBar then
            addLine("StatusBar exists: yes")
            addLine("Has SetTimerDuration: " .. tostring(testBar.SetTimerDuration ~= nil))
            addLine("Has GetTimerDuration: " .. tostring(testBar.GetTimerDuration ~= nil))
        else
            addLine("No test bar available")
        end
        
        -- Test Cooldown frame
        local testCd = ShreddedBarCooldownList["ShreddedBar1"]
        if testCd then
            addLine("Cooldown frame exists: yes")
            addLine("Has SetCooldownFromExpirationTime: " .. tostring(testCd.SetCooldownFromExpirationTime ~= nil))
            addLine("Has SetCooldown: " .. tostring(testCd.SetCooldown ~= nil))
        else
            addLine("No cooldown frame available (created at load)")
        end
    
    end) -- end pcall
    
    if not ok then
        table.insert(lines, "ERROR: " .. tostring(err))
    end
    
    -- Sanitize lines array - remove any nil/secret values that snuck in
    local safeLines = {}
    for i, line in ipairs(lines) do
        if line ~= nil and not issecretvalue(line) then
            table.insert(safeLines, tostring(line))
        else
            table.insert(safeLines, "[line " .. i .. " was secret/nil]")
        end
    end
    
    -- Show in copyable window (always show, even on error)
    ShowDebugWindow(table.concat(safeLines, "\n"))
end

-- ===========================================
-- TRACKING DATA
-- ===========================================

-- Timers store expiration times (made global for debugging)
Shredded_timers = {}
Shredded_durations = {}
Shredded_fTimes = {}
Shredded_floorTimes = {}
local timers = Shredded_timers
local durations = Shredded_durations
local procs = {}
local floorTimes = Shredded_floorTimes
local fTimes = Shredded_fTimes

-- CLEU-based aura tracking (Midnight workaround for secret aura IDs)
-- This tracks auras via Combat Log events where spell IDs are NOT secret
Shredded_cleuAuras = {
    player = {},  -- [spellKey] = { applied = time, duration = estimate }
    target = {},  -- [spellKey] = { applied = time, duration = estimate }
}

-- Self-tracking system: capture timings when first applied, track ourselves
-- This works because we can read aura data at application time (before combat locks it)
Shredded_selfTrack = {
    player = {},  -- [spellKey] = { startTime, duration, expirationTime, lastSeen }
    target = {},  -- [spellKey] = { startTime, duration, expirationTime, lastSeen }
}

-- Pre-combat cached durations (learned from API when readable)
-- Used for estimation during combat when API returns secrets
Shredded_cachedDurations = {
    player = {},  -- [spellKey] = last known duration
    target = {},  -- [spellKey] = last known duration
}

-- Target GUID tracking for debuff cache invalidation
Shredded_lastTargetGUID = nil

-- Hidden cooldown frame for decoding secret duration objects (Midnight API workaround)
-- This trick comes from CooldownCompanion: secret duration objects can be passed to
-- SetCooldownFromDurationObject(), then GetCooldownTimes() returns readable milliseconds!
local secretDecoderFrame = CreateFrame("Frame", "ShreddedSecretDecoder", UIParent)
secretDecoderFrame:SetSize(1, 1)
secretDecoderFrame:Hide()
local secretDecoderCooldown = CreateFrame("Cooldown", "ShreddedSecretDecoderCooldown", secretDecoderFrame, "CooldownFrameTemplate")
secretDecoderCooldown:SetAllPoints()
secretDecoderCooldown:SetDrawEdge(false)
secretDecoderCooldown:SetDrawSwipe(false)
secretDecoderCooldown:SetHideCountdownNumbers(true)

-- Function to decode a secret duration object into milliseconds
-- Returns: durationMs (number) or nil if decoding fails
-- Function to decode a secret duration object into timing info
-- Returns: remainingMs, durationMs (both in milliseconds) or nil if decoding fails
-- GetCooldownTimes() returns startTime and duration
-- For aura durations via SetCooldownFromDurationObject, values are in MILLISECONDS
-- Returns: remainingSec, durationSec (both in seconds) or nil if decoding fails
local function DecodeDurationObject(durationObj)
    if not durationObj then return nil, nil end
    local ok = pcall(function()
        secretDecoderCooldown:SetCooldownFromDurationObject(durationObj)
    end)
    if not ok then return nil, nil end
    
    local startTimeMs, durationMs = secretDecoderCooldown:GetCooldownTimes()
    
    -- GetCooldownTimes returns milliseconds for aura durations
    if durationMs and durationMs > 0 then
        local nowMs = GetTime() * 1000
        local expirationMs = startTimeMs + durationMs
        local remainingMs = expirationMs - nowMs
        
        if remainingMs > 0 then
            return remainingMs / 1000, durationMs / 1000
        end
    end
    return nil, nil
end

-- ===========================================
-- CDM VIEWER-BASED AURA TRACKING
-- ===========================================
-- Instead of caching auraInstanceIDs and matching by duration, we read directly
-- from Blizzard's Cooldown Manager (CDM) viewer frames. These frames run untainted
-- code that stores auraInstanceID and auraDataUnit as plain readable properties,
-- even during combat when spell IDs are secret.
--
-- This approach comes from CooldownCompanion and eliminates all guesswork:
-- no duration matching, no glow hints, no pending procs, no cache invalidation.

-- Viewer frame names (Blizzard CDM globals)
-- Order matters: Essential/Utility first, BuffIcon/BuffBar LAST so they WIN
-- (BuffIcon/BuffBar have auraInstanceID; Essential/Utility do NOT)
local VIEWER_NAMES = {
    "EssentialCooldownViewer",  -- Tracks spell cooldowns - does NOT have auraInstanceID
    "UtilityCooldownViewer",    -- Tracks spell cooldowns - does NOT have auraInstanceID
    "BuffIconCooldownViewer",   -- Tracks aura durations (buffs) - HAS auraInstanceID
    "BuffBarCooldownViewer",    -- Tracks aura durations (buffs/debuffs) - HAS auraInstanceID
}

-- Viewer names that support auraInstanceID (for preference checking)
local BUFF_VIEWER_NAMES = {
    ["BuffIconCooldownViewer"] = true,
    ["BuffBarCooldownViewer"] = true,
}

-- Map: spellID → Blizzard CDM viewer child frame
Shredded_viewerAuraFrames = {}

-- Helper: check if a viewer child is from a buff viewer (has auraInstanceID support)
local function IsBuffViewerChild(child)
    if not child then return false end
    local parent = child:GetParent()
    if not parent then return false end
    local name = parent:GetName()
    return name and BUFF_VIEWER_NAMES[name] or false
end

-- Ensure CDM viewer frames are shown (with alpha=0 so they're invisible)
-- Blizzard only populates cooldownInfo/auraInstanceID on children when the viewer is shown.
-- CooldownCompanion uses the same technique: SetAlpha(0) instead of Hide().
local viewersHooked = false
local function EnsureViewersShown()
    -- Don't try to Show() protected frames during combat (would cause taint)
    if InCombatLockdown() then return end
    
    for _, name in ipairs(VIEWER_NAMES) do
        local viewer = _G[name]
        if viewer then
            -- Show with alpha=0 (invisible but active)
            if not viewer:IsShown() then
                pcall(function()
                    viewer:SetAlpha(0)
                    viewer:Show()
                end)
                ShreddedV("CDM viewer " .. name .. " was hidden - showing with alpha=0")
            end
            
            -- Hook OnHide to re-show (only hook once)
            if not viewersHooked then
                pcall(function()
                    viewer:HookScript("OnHide", function(self)
                        -- Re-show with alpha=0 after a tiny delay (avoid re-entrance and combat)
                        C_Timer.After(0.1, function()
                            if not InCombatLockdown() and not self:IsShown() then
                                pcall(function()
                                    self:SetAlpha(0)
                                    self:Show()
                                end)
                                ShreddedV("CDM viewer re-shown after hide: " .. (self:GetName() or "?"))
                                -- Rebuild map after viewers get repopulated
                                C_Timer.After(1, function()
                                    if BuildViewerAuraMap then BuildViewerAuraMap() end
                                end)
                            end
                        end)
                    end)
                end)
            end
        end
    end
    viewersHooked = true
end

-- Build mapping from spellID → CDM viewer child frame
-- Viewer children have .cooldownInfo with spellID, overrideSpellID, overrideTooltipSpellID
-- BuffIcon/BuffBar children also have .auraInstanceID and .auraDataUnit when an aura is active
local BuildViewerAuraMap  -- forward declaration
function Shredded_RebuildViewerMap()
    if BuildViewerAuraMap then BuildViewerAuraMap() end
end
BuildViewerAuraMap = function()
    -- Ensure viewers are shown (with alpha=0) so Blizzard populates cooldownInfo
    EnsureViewersShown()
    
    wipe(Shredded_viewerAuraFrames)
    local viewerCounts = {}
    local childrenWithInfo = 0
    
    for _, name in ipairs(VIEWER_NAMES) do
        local viewer = _G[name]
        viewerCounts[name] = 0
        if viewer then
            local children = {viewer:GetChildren()}
            viewerCounts[name] = #children
            for _, child in pairs(children) do
                if child.cooldownInfo then
                    childrenWithInfo = childrenWithInfo + 1
                    local isBuff = BUFF_VIEWER_NAMES[name] or false
                    local function MapId(id)
                        if not id then return end
                        local existing = Shredded_viewerAuraFrames[id]
                        -- Always map if no existing, or if we're a buff viewer replacing a non-buff viewer
                        if not existing or isBuff or not IsBuffViewerChild(existing) then
                            Shredded_viewerAuraFrames[id] = child
                        end
                    end
                    MapId(child.cooldownInfo.spellID)
                    MapId(child.cooldownInfo.overrideSpellID)
                    MapId(child.cooldownInfo.overrideTooltipSpellID)
                end
            end
        end
    end
    
    -- API-based fallback: if no viewer children had cooldownInfo, use C_CooldownViewer API
    -- to build a spellID → viewer child lookup by matching cooldownInfo data to children
    if childrenWithInfo == 0 then
        ShreddedV("No viewer children have cooldownInfo - trying C_CooldownViewer API fallback")
        -- CDM categories: 0=Essential, 1=Utility, 2=TrackedBuff(Icon), 3=TrackedBar
        local CATEGORY_TO_VIEWER = {
            [0] = "EssentialCooldownViewer",
            [1] = "UtilityCooldownViewer",
            [2] = "BuffIconCooldownViewer",
            [3] = "BuffBarCooldownViewer",
        }
        for cat = 0, 3 do
            local ok, cdIds = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, cat, true)
            if ok and cdIds then
                local viewerName = CATEGORY_TO_VIEWER[cat]
                local isBuff = BUFF_VIEWER_NAMES[viewerName] or false
                ShreddedV("  Category " .. cat .. " (" .. viewerName .. "): " .. #cdIds .. " cooldowns")
                for _, cdID in ipairs(cdIds) do
                    local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if ok2 and info then
                        -- Find the viewer child for this cooldown by matching layoutIndex or cooldownID
                        local viewer = _G[viewerName]
                        local matchedChild = nil
                        if viewer then
                            for _, child in pairs({viewer:GetChildren()}) do
                                -- Match by cooldownInfo if available, or by being a non-decoration frame
                                if child.cooldownInfo and child.cooldownInfo.spellID == info.spellID then
                                    matchedChild = child
                                    break
                                end
                            end
                        end
                        -- Even without a matched child frame, store the API info for detection
                        -- We'll create a synthetic entry with the info we have
                        if not matchedChild and viewer then
                            -- Find any active child we can use - try to match by properties
                            for _, child in pairs({viewer:GetChildren()}) do
                                if child.Cooldown and child.layoutIndex then
                                    -- Can't reliably match without cooldownInfo, but store what we can
                                    matchedChild = child
                                    break
                                end
                            end
                        end
                        -- Map spellIDs from API data (even without a matched child, track the info)
                        local function ApiMapId(id)
                            if not id then return end
                            if matchedChild then
                                local existing = Shredded_viewerAuraFrames[id]
                                if not existing or isBuff or not IsBuffViewerChild(existing) then
                                    Shredded_viewerAuraFrames[id] = matchedChild
                                end
                            end
                        end
                        ApiMapId(info.spellID)
                        ApiMapId(info.overrideSpellID)
                        ApiMapId(info.overrideTooltipSpellID)
                        -- Also map linked spell IDs
                        if info.linkedSpellIDs then
                            for _, linkedId in ipairs(info.linkedSpellIDs) do
                                ApiMapId(linkedId)
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Resolve ability → aura spell ID mapping via Blizzard API
    -- (e.g., ability "Shred" might have a different buff ID for "Clearcasting")
    for _, spellData in ipairs(SPELL_DATABASE) do
        local id = spellData.id
        if id and not Shredded_viewerAuraFrames[id] then
            -- Try talentId (CDM often tracks by talent ID, not buff ID)
            if spellData.talentId and Shredded_viewerAuraFrames[spellData.talentId] then
                Shredded_viewerAuraFrames[id] = Shredded_viewerAuraFrames[spellData.talentId]
            end
            -- Try GetCooldownAuraBySpellID (maps ability → buff ID)
            if not Shredded_viewerAuraFrames[id] then
                local ok, auraId = pcall(C_UnitAuras.GetCooldownAuraBySpellID, id)
                if ok and auraId and auraId ~= 0 and auraId ~= id and Shredded_viewerAuraFrames[auraId] then
                    Shredded_viewerAuraFrames[id] = Shredded_viewerAuraFrames[auraId]
                end
            end
            -- Try GetBaseSpell
            if not Shredded_viewerAuraFrames[id] then
                local ok2, baseId = pcall(C_Spell.GetBaseSpell, id)
                if ok2 and baseId and baseId ~= id and Shredded_viewerAuraFrames[baseId] then
                    Shredded_viewerAuraFrames[id] = Shredded_viewerAuraFrames[baseId]
                end
            end
        end
        -- Bidirectional altId mapping:
        -- 1. If primary has a mapping, propagate to unmapped altIds
        -- 2. If any altId has a mapping, propagate back to primary and to other altIds
        if spellData.altIds then
            -- First pass: find best mapped child (prefer buff viewers)
            local bestChild = Shredded_viewerAuraFrames[id]
            if not bestChild then
                for _, altId in ipairs(spellData.altIds) do
                    local altChild = Shredded_viewerAuraFrames[altId]
                    if altChild then
                        if not bestChild or (IsBuffViewerChild(altChild) and not IsBuffViewerChild(bestChild)) then
                            bestChild = altChild
                        end
                    end
                end
            end
            -- Also try API resolution on altIds
            if not bestChild then
                for _, altId in ipairs(spellData.altIds) do
                    local ok, auraId = pcall(C_UnitAuras.GetCooldownAuraBySpellID, altId)
                    if ok and auraId and auraId ~= 0 and Shredded_viewerAuraFrames[auraId] then
                        bestChild = Shredded_viewerAuraFrames[auraId]
                        break
                    end
                end
            end
            -- Second pass: propagate bestChild to primary and all altIds
            if bestChild then
                if not Shredded_viewerAuraFrames[id] or
                   (IsBuffViewerChild(bestChild) and not IsBuffViewerChild(Shredded_viewerAuraFrames[id])) then
                    Shredded_viewerAuraFrames[id] = bestChild
                end
                for _, altId in ipairs(spellData.altIds) do
                    if not Shredded_viewerAuraFrames[altId] then
                        Shredded_viewerAuraFrames[altId] = bestChild
                    end
                end
            end
        end
    end
    
    -- Log summary
    local total = 0
    local buffCount = 0
    for id, child in pairs(Shredded_viewerAuraFrames) do
        total = total + 1
        if IsBuffViewerChild(child) then buffCount = buffCount + 1 end
    end
    ShreddedV("CDM Viewer map built: " .. total .. " IDs mapped (" .. buffCount .. " from buff viewers)")
    for name, cnt in pairs(viewerCounts) do
        ShreddedV("  " .. name .. ": " .. cnt .. " children")
    end
    
    -- Log which of OUR tracked spells got mapped
    local mappedCount = 0
    for _, spellData in ipairs(SPELL_DATABASE) do
        local id = spellData.id
        local child = Shredded_viewerAuraFrames[id]
        if child then
            mappedCount = mappedCount + 1
            local parentName = child:GetParent() and child:GetParent():GetName() or "?"
            local isBuff = IsBuffViewerChild(child)
            ShreddedV("  " .. spellData.key .. " (" .. id .. ") -> " .. parentName .. (isBuff and " [BUFF]" or " [CD]"))
        end
    end
    
    -- Retry logic: if no children had cooldownInfo, CDM may still be loading
    Shredded_viewerMapRetries = (Shredded_viewerMapRetries or 0)
    if total == 0 and Shredded_viewerMapRetries < 5 then
        Shredded_viewerMapRetries = Shredded_viewerMapRetries + 1
        local delay = Shredded_viewerMapRetries * 2  -- 2s, 4s, 6s, 8s, 10s
        ShreddedV("CDM map empty - retry #" .. Shredded_viewerMapRetries .. " in " .. delay .. "s")
        C_Timer.After(delay, BuildViewerAuraMap)
    elseif total > 0 then
        Shredded_viewerMapRetries = 0  -- Reset on success
    end
end

-- Known base durations for auras (pandemic can extend, but these are baselines)
local BASE_DURATIONS = {
    -- Buffs
    TIGERS_FURY = 15,      -- Can be extended by talents
    BERSERK = 20,
    INCARNATION = 30,
    BLOODTALONS = 30,
    CLEARCASTING = 15,
    PREDATORY_SWIFTNESS = 12,
    SUDDEN_AMBUSH = 15,
    APEX_PREDATOR = 15,
    RAVAGE = 20,           -- Ravage proc buff
    -- Hero talent procs (Druid of the Claw)
    KILLING_STRIKES = 10,  -- Ravage crit damage buff
    SAVAGE_FURY = 6,       -- Empowered attacks
    COILED_TO_SPRING = 15, -- Next ability empowered
    -- Debuffs (on target)
    RIP = 24,              -- 5 CP base, pandemic can extend to ~33.6
    RAKE = 15,             -- Pandemic can extend to ~21
    THRASH = 15,
    MOONFIRE_CAT = 16,
    FERAL_FRENZY = 6,
    FRANTIC_FRENZY = 6,     -- Replaces Feral Frenzy
    PRIMAL_WRATH = 4,      -- Short duration AoE RIP
    DREADFUL_WOUND = 10,   -- Ravage debuff on target
    INFECTED_WOUNDS = 12,  -- Healing reduction/slow on target
}

-- Spells to track (populated dynamically from SPELL_DATABASE)
ShreddedCatSpells = {}

-- Proc Icons Spells - ONLY procs (isProc=true buffs that alert you to use an ability)
-- These show when ACTIVE - "Use this ability NOW!"
-- Order here determines default priority order
ShreddedCooldownSpells = {
    -- PROCS - These are buffs that proc and need immediate action
    "CLEARCASTING",       -- Omen of Clarity - free ability! (Moment of Clarity just adds charges)
    "PREDATORY_SWIFTNESS", -- Free heal available!
    "BLOODTALONS",        -- Empowered bleeds ready!
    "SUDDEN_AMBUSH",      -- Stealth ability available!
    "APEX_PREDATOR",      -- Free Bite available!
    "RAVAGE",             -- Empowered Shred available! (Hero: Druid of the Claw)
    "KILLING_STRIKES",    -- Ravage crit damage proc!
    "SAVAGE_FURY",        -- Empowered attacks proc!
    "COILED_TO_SPRING",   -- Next ability empowered!
    -- MAJOR COOLDOWNS - Show when active
    "INCARNATION",        -- Avatar of Ashamane active!
    "CONVOKE",            -- Convoke the Spirits channeling!
}

-- ===========================================
-- PROC LOGGING SYSTEM
-- Captures buff/proc spell IDs as they appear during combat
-- ===========================================
Shredded_ProcLog = {}  -- { name = spellName, id = spellId, time = GetTime(), overlay = bool }
Shredded_ProcLogMax = 50  -- Keep last 50 entries
Shredded_CombatLogEnabled = false  -- Toggle for real-time chat output
Shredded_LastProcState = {}  -- Track previous state to detect changes

local function LogProc(name, spellId, hasOverlay)
    -- Only log if we have readable values
    if not name or not spellId then return end
    if type(spellId) ~= "number" then return end
    
    -- Add to log
    table.insert(Shredded_ProcLog, 1, {
        name = name,
        id = spellId,
        time = GetTime(),
        overlay = hasOverlay or false
    })
    
    -- Trim old entries
    while #Shredded_ProcLog > Shredded_ProcLogMax do
        table.remove(Shredded_ProcLog)
    end
end

-- Scan current buffs and log any with overlays or proc-like names
local function ScanAndLogProcs()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        
        -- Try to extract readable values
        local name, spellId
        pcall(function()
            name = aura.name
            spellId = aura.spellId
        end)
        
        if name and spellId and type(spellId) == "number" then
            -- Check if this has an overlay (proc indicator)
            local hasOverlay = false
            pcall(function()
                hasOverlay = C_SpellActivationOverlay.IsSpellOverlayed(spellId)
            end)
            
            -- Log if it has overlay OR matches common proc keywords
            local lowerName = string.lower(name)
            local isProcLike = hasOverlay or 
                string.find(lowerName, "fury") or
                string.find(lowerName, "strike") or
                string.find(lowerName, "spring") or
                string.find(lowerName, "clear") or
                string.find(lowerName, "swift") or
                string.find(lowerName, "ravage") or
                string.find(lowerName, "ambush") or
                string.find(lowerName, "apex") or
                string.find(lowerName, "blood") or
                string.find(lowerName, "moment") or
                string.find(lowerName, "predator")
            
            if isProcLike then
                LogProc(name, spellId, hasOverlay)
            end
        end
    end
end

-- Global lookup table for spell metadata (populated from SPELL_DATABASE)
Shredded_SpellMeta = {}

-- Cache of all spell IDs the player knows (from spellbook scan)
Shredded_KnownSpellIDs = {}

-- Scan the player's spellbook and build a list of all known spell IDs
-- Assigns to forward-declared local ScanSpellbook
ScanSpellbook = function()
    wipe(Shredded_KnownSpellIDs)
    
    -- Scan all spellbook tabs
    local numTabs = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for tab = 1, numTabs do
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(tab)
        if skillLineInfo then
            local offset = skillLineInfo.itemIndexOffset
            local numSpells = skillLineInfo.numSpellBookItems
            
            for i = 1, numSpells do
                local slotIndex = offset + i
                local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(slotIndex, Enum.SpellBookSpellBank.Player)
                if spellBookItemInfo and spellBookItemInfo.spellID then
                    Shredded_KnownSpellIDs[spellBookItemInfo.spellID] = true
                    
                    -- Also check for override spells (some talents override base spells)
                    local overrideSpellID = C_Spell.GetOverrideSpell(spellBookItemInfo.spellID)
                    if overrideSpellID and overrideSpellID ~= spellBookItemInfo.spellID then
                        Shredded_KnownSpellIDs[overrideSpellID] = true
                    end
                end
            end
        end
    end
    
    -- Also scan passive spells and talents
    -- Check specific talent IDs from our database
    for _, data in ipairs(SPELL_DATABASE) do
        local checkIds = {}
        if data.id and type(data.id) == "number" then
            table.insert(checkIds, data.id)
        end
        if data.talentId and type(data.talentId) == "number" then
            table.insert(checkIds, data.talentId)
        end
        
        for _, spellId in ipairs(checkIds) do
            if IsSpellKnown(spellId) or IsPlayerSpell(spellId) then
                Shredded_KnownSpellIDs[spellId] = true
            end
        end
    end
    
    return Shredded_KnownSpellIDs
end

-- Detect which hero talent tree the player has selected
-- Returns "CLAW", "WILD", or nil if unknown
function Shredded_DetectHeroTree()
    -- Check for spells that indicate each tree
    -- Druid of the Claw: Bestial Strength (441841), Wildshape Mastery (441678)
    -- Wildstalker: Thriving Growth (439528), Bond with Nature (439929)
    if IsPlayerSpell(441841) or IsPlayerSpell(441678) or IsPlayerSpell(441689) then return "CLAW" end
    if IsPlayerSpell(439528) or IsPlayerSpell(439929) or IsPlayerSpell(439926) then return "WILD" end
    return nil  -- Can't detect
end
local DetectHeroTree = Shredded_DetectHeroTree  -- Local alias for internal use

-- Check if player has a spell available (knows/can use it)
function Shredded_PlayerHasSpell(spellKey)
    local meta = Shredded_SpellMeta[spellKey]
    if not meta then return false end
    
    -- Resources always available
    if meta.type == "resource" then return true end
    
    -- Core abilities always available for Feral
    if meta.core then return true end
    
    -- Legacy/Removed spells are never available
    if meta.source == "Removed" then return false end
    
    -- Check if this spell is overridden by another spell via GetOverrideSpell
    -- This handles choice node talents like Feral Frenzy -> Frantic Frenzy
    if meta.overriddenBy and C_Spell and C_Spell.GetOverrideSpell then
        local override = C_Spell.GetOverrideSpell(meta.id)
        if override == meta.overriddenBy then
            return false  -- Hide this spell, it's been overridden
        end
    end
    
    -- Check if this spell should be detected via override of another spell
    -- e.g., Frantic Frenzy is detected when GetOverrideSpell(274837) returns our id
    if meta.detectViaOverride and C_Spell and C_Spell.GetOverrideSpell then
        local override = C_Spell.GetOverrideSpell(meta.detectViaOverride)
        if override == meta.id then
            return true  -- Override matches, player has this spell
        end
    end
    
    -- Check if this spell is replaced by another that the player has
    -- Use a flag to prevent infinite recursion when checking replacement
    if meta.replacedBy and not meta._checkingReplacement then
        local replacementMeta = Shredded_SpellMeta[meta.replacedBy]
        if replacementMeta then
            -- Temporarily mark to prevent recursion
            meta._checkingReplacement = true
            -- Use full detection logic for replacement spell
            local hasReplacement = Shredded_PlayerHasSpell(meta.replacedBy)
            meta._checkingReplacement = nil
            
            if hasReplacement then
                return false  -- Hide this spell, player has the upgrade
            end
        end
    end
    
    -- Check if we're a Feral druid
    local _, _, classId = UnitClass("player")
    local specId = GetSpecialization and GetSpecialization() or 0
    local isFeral = (classId == 11 and specId == 2)
    
    if not isFeral then return false end
    
    local source = meta.source
    
    -- For Feral Spec Talents and Abilities: check IsPlayerSpell first
    if source == SOURCE_TYPES.SPEC_TALENT or source == SOURCE_TYPES.SPEC_ABILITY then
        -- Baseline/core abilities - always available to Feral
        if meta.core then
            return true
        end
        
        -- For PROCS: strict checking - only show if we can confirm the talent
        if meta.isProc then
            -- Check talentId if available
            if meta.talentId and type(meta.talentId) == "number" then
                if IsPlayerSpell(meta.talentId) then return true end
                if IsSpellKnown(meta.talentId) then return true end
            end
            -- Also check buff ID for procs - some talent systems register the buff
            if meta.id and type(meta.id) == "number" then
                if IsPlayerSpell(meta.id) then return true end
            end
            -- Check altIds
            if meta.altIds then
                for _, altId in ipairs(meta.altIds) do
                    if IsPlayerSpell(altId) or IsSpellKnown(altId) then return true end
                end
            end
            -- Could NOT confirm player has this proc talent - don't include
            return false
        end
        
        -- For non-proc cooldowns (like CONVOKE, INCARNATION) - strict checking
        -- ONLY use IsPlayerSpell - don't trust Shredded_KnownSpellIDs cache
        if meta.isCooldown then
            -- Must have the talent/spell - strict IsPlayerSpell check only
            if meta.talentId and type(meta.talentId) == "number" then
                if IsPlayerSpell(meta.talentId) then return true end
            end
            -- Also check primary ID if no talentId
            if not meta.talentId and meta.id and type(meta.id) == "number" then
                if IsPlayerSpell(meta.id) then return true end
            end
            -- isCooldown but player doesn't have it - not available
            return false
        end
        
        -- If there's a talentId, ONLY check that (not the buff ID)
        if meta.talentId and type(meta.talentId) == "number" then
            if IsPlayerSpell(meta.talentId) then return true end
            if IsSpellKnown(meta.talentId) then return true end
            if Shredded_KnownSpellIDs and Shredded_KnownSpellIDs[meta.talentId] then return true end
            -- Has talentId but player doesn't have it - NOT available
            return false
        end
        
        -- No talentId - check the primary ID
        local spellId = meta.id
        if spellId and type(spellId) == "number" then
            if IsPlayerSpell(spellId) then return true end
            if IsSpellKnown(spellId) then return true end
        end
        -- Check alternate IDs
        if meta.altIds then
            for _, altId in ipairs(meta.altIds) do
                if IsPlayerSpell(altId) then return true end
                if IsSpellKnown(altId) then return true end
            end
        end
        -- Also check if spell exists and is in spellbook cache
        if meta.id and Shredded_KnownSpellIDs and Shredded_KnownSpellIDs[meta.id] then return true end
        if meta.altIds then
            for _, altId in ipairs(meta.altIds) do
                if Shredded_KnownSpellIDs and Shredded_KnownSpellIDs[altId] then return true end
            end
        end
        -- Not detected - assume NOT available (user hasn't taken this talent)
        return false
    end
    
    -- Class talents - always available to Feral druids (base kit)
    if source == SOURCE_TYPES.CLASS_TALENT then
        return true
    end
    
    -- Hero Talents - check which tree is active
    if source == SOURCE_TYPES.HERO_CLAW or source == SOURCE_TYPES.HERO_WILD then
        local heroTree = DetectHeroTree()
        
        -- MUST be able to detect tree - if not, don't show hero talent procs
        if not heroTree then
            return false
        end
        
        -- Wrong tree = not available
        if source == SOURCE_TYPES.HERO_CLAW and heroTree ~= "CLAW" then return false end
        if source == SOURCE_TYPES.HERO_WILD and heroTree ~= "WILD" then return false end
        
        -- Right tree - player has this hero talent spec
        -- For procs, we trust that if they have the tree, they have the proc
        -- (hero talent procs are core to the tree, not optional)
        if meta.isProc then
            return true
        end
        
        -- For non-proc hero talents, check if player has the specific spell
        local spellId = meta.talentId or meta.id
        if spellId and type(spellId) == "number" then
            if IsPlayerSpell(spellId) then return true end
            if IsSpellKnown(spellId) then return true end
        end
        
        -- Also check altIds for hero talents
        if meta.altIds then
            for _, altId in ipairs(meta.altIds) do
                if IsPlayerSpell(altId) or IsSpellKnown(altId) then return true end
            end
        end
        
        -- Right tree, assume they have hero talent features
        return true
    end
    
    -- Default: try API check
    local spellId = meta.talentId or meta.id
    if spellId and type(spellId) == "number" then
        if IsPlayerSpell(spellId) then return true end
        if IsSpellKnown(spellId) then return true end
    end
    
    return false
end

-- Rescan spells when talents change
function Shredded_RescanSpellbook()
    ScanSpellbook()
    -- Rebuild cooldown and bar displays with new spell knowledge
    if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
    if exportBarOrder then exportBarOrder() end
    if Shredded_Refresh then Shredded_Refresh() end
end

-- Get spell metadata for UI display
function Shredded_GetSpellInfo(spellKey)
    return Shredded_SpellMeta[spellKey]
end

-- Populate global spell metadata lookup
local function BuildSpellMetaLookup()
    wipe(Shredded_SpellMeta)
    for _, data in ipairs(SPELL_DATABASE) do
        Shredded_SpellMeta[data.key] = data
    end
end

-- Build the cat spells list from database
local function BuildCatSpellsList()
    -- First populate metadata lookup
    BuildSpellMetaLookup()
    
    wipe(ShreddedCatSpells)
    -- Add in preferred order: buffs first, then debuffs, then resources
    -- EXCLUDE: procs (isProc), passives (isPassive), major cooldowns (isCooldown)
    -- Those go to Proc Icons (ShreddedCooldownSpells), not Timer Bars
    local buffs, debuffs, resources = {}, {}, {}
    
    for _, data in ipairs(SPELL_DATABASE) do
        -- Skip procs, passives, and cooldowns - they're handled by Proc Icons
        local skipForBars = data.isProc or data.isPassive or data.isCooldown
        
        if data.type == "buff" and not skipForBars then
            -- Regular buffs (Tiger's Fury, Berserk, etc.) go to Timer Bars
            table.insert(buffs, data.key)
        elseif data.type == "debuff" then
            table.insert(debuffs, data.key)
        elseif data.type == "resource" then
            table.insert(resources, data.key)
        end
    end
    
    for _, key in ipairs(buffs) do table.insert(ShreddedCatSpells, key) end
    for _, key in ipairs(debuffs) do table.insert(ShreddedCatSpells, key) end
    for _, key in ipairs(resources) do table.insert(ShreddedCatSpells, key) end
end

-- Initialize timers for all possible spells
local function InitTimers()
    -- Initialize all spells from database
    for _, data in ipairs(SPELL_DATABASE) do
        local key = data.key
        timers[key] = 0
        durations[key] = 30 -- default
        procs[key] = 0
    end
    
    -- Set specific durations
    -- Resources
    durations["ENERGY"] = 100
    durations["COMBO"] = 5
    
    -- Core buffs/debuffs
    durations["TIGERS_FURY"] = 20
    durations["RIP"] = 24
    durations["RAKE"] = 15
    durations["THRASH"] = 15
    
    -- Procs
    durations["CLEARCASTING"] = 15
    durations["PREDATORY_SWIFTNESS"] = 12
    durations["BLOODTALONS"] = 30
    durations["SUDDEN_AMBUSH"] = 15
    durations["APEX_PREDATOR"] = 15
    
    -- Major cooldowns
    durations["BERSERK"] = 20
    durations["INCARNATION"] = 30
    durations["CONVOKE"] = 4  -- Channel duration
    
    -- Feral talents
    durations["MOONFIRE_CAT"] = 16
    durations["FERAL_FRENZY"] = 6
    durations["FRANTIC_FRENZY"] = 6  -- Replaces Feral Frenzy
    durations["PRIMAL_WRATH"] = 4
    durations["SABERTOOTH"] = 0  -- Passive
    durations["WILD_SLASHES"] = 0  -- Passive
    durations["SOUL_OF_THE_FOREST"] = 0  -- Instant
    durations["FRANTIC_MOMENTUM"] = 6
    durations["CARNIVOROUS_INSTINCT"] = 0  -- Passive
    
    -- Hero: Druid of the Claw
    durations["RAVAGE"] = 20  -- Ravage proc buff duration
    durations["DREADFUL_WOUND"] = 10  -- Ravage debuff on target
    durations["INFECTED_WOUNDS"] = 12  -- Healing reduction/slow
    durations["KILLING_STRIKES"] = 6  -- Crit damage proc
    durations["SAVAGE_FURY"] = 6  -- Empowered attacks proc
    durations["COILED_TO_SPRING"] = 15  -- Next ability empowered
    durations["CLAW_RAMPAGE"] = 10
    durations["BESTIAL_STRENGTH"] = 0  -- Passive
    durations["EMPOWERED_SHAPESHIFTING"] = 0  -- Passive
    durations["STRIKE_FOR_THE_HEART"] = 6
    durations["WILDPOWER_SURGE"] = 6
    durations["AGGRAVATE_WOUNDS"] = 0  -- Passive
    
    -- Hero: Wildstalker
    durations["THRIVING_GROWTH"] = 0  -- Passive
    durations["STRATEGIC_INFUSION"] = 12
    durations["BURSTING_GROWTH"] = 0  -- Passive
    durations["VIGOROUS_CREEPERS"] = 0  -- Passive
    durations["BOND_WITH_NATURE"] = 0  -- Passive
    durations["ROOT_NETWORK"] = 0  -- Passive
    durations["ENTANGLING_VORTEX"] = 8
    durations["RESILIENT_FLOURISHING"] = 0  -- Passive
    durations["FLOWER_WALK"] = 3
    durations["HARMONIOUS_CONSTITUTION"] = 0  -- Passive
end

-- ===========================================
-- FRAME LISTS
-- ===========================================

ShreddedCooldownList = {}
ShreddedBarList = {}
ShreddedCooldownTextList = {}
ShreddedCooldownTextureList = {}
ShreddedBarTextList = {}
ShreddedBarSecsList = {}
ShreddedBarIconList = {}
ShreddedBarIconTextureList = {}
ShreddedBarBarList = {}
ShreddedBarCooldownList = {} -- Cooldown frames for secret value countdown display

-- Track which bars have active timers set (to avoid resetting SetTimerDuration every frame)
local activeTimers = {}
ShreddedBarState = {}
ShreddedCooldownState = {}

local barOrder = {}
Shredded_barOrder = barOrder  -- Global reference for debug/test
local lastBarOrder = {}
-- barMove is declared at file top

-- ===========================================
-- DEFAULT SETTINGS
-- ===========================================

function ShreddedDefaultSettings()
    wipe(ShreddedSettings)
    
    ShreddedSettings["version"] = 30000
    ShreddedSettings["cooldownorder"] = {}
    ShreddedSettings["cooldowntime"] = {}
    ShreddedSettings["offcolor"] = {1, 0, 0}
    ShreddedSettings["oncolor"] = {0, 1, 0}
    ShreddedSettings["barorder"] = {}
    ShreddedSettings["baron"] = {}
    ShreddedSettings["bartime"] = {}
    ShreddedSettings["barheight"] = 18
    ShreddedSettings["barwidth"] = 150
    ShreddedSettings["cooldownsize"] = 40
    ShreddedSettings["cooldownfont"] = 24
    ShreddedSettings["cooldownalpha"] = 0.85
    ShreddedSettings["cooldownrestalpha"] = 0  -- Opacity when proc is NOT active (0 = hidden)
    ShreddedSettings["barfont"] = 11
    ShreddedSettings["bargrowth"] = "up"
    ShreddedSettings["catbarson"] = true
    ShreddedSettings["cooldownson"] = true
    ShreddedSettings["cooldownloc"] = {500, 500}
    ShreddedSettings["barloc"] = {500, 400}
    ShreddedSettings["cooldownlayout"] = {width = 4, height = 3}
    ShreddedSettings["barbackalpha"] = 0.4
    ShreddedSettings["baralpha"] = 0.9
    ShreddedSettings["barcombat"] = true
    ShreddedSettings["barscale"] = true
    ShreddedSettings["barlength"] = 30
    ShreddedSettings["barlock"] = false
    ShreddedSettings["barzero"] = true
    ShreddedSettings["cooldowncombat"] = false  -- Show cooldowns even outside combat
    ShreddedSettings["barcolor"] = {}
    ShreddedSettings["bartexture"] = [[Interface\Addons\Shredded\bars\BantoBar.tga]]
    ShreddedSettings["bartexturename"] = "BantoBar"
    
    -- Set cooldown priority order (lower number = higher priority = shows first)
    -- cooldownon[spell] = true/false (enabled)
    -- cooldownpriority[spell] = number (sort order, lower = first)
    ShreddedSettings["cooldownon"] = {}
    ShreddedSettings["cooldownpriority"] = {}
    for idx, key in ipairs(ShreddedCooldownSpells) do
        ShreddedSettings["cooldownon"][key] = true  -- Default all on
        ShreddedSettings["cooldownpriority"][key] = idx  -- Default priority = list order
    end
    
    -- Set cooldown thresholds (when to show "falling off" warnings)
    for _, key in ipairs(ShreddedCatSpells) do
        ShreddedSettings["cooldowntime"][key] = 5  -- Show icon when < 5 sec remaining
        ShreddedSettings["bartime"][key] = 30
    end
    
    -- Set bar order and priority
    -- barpriority[spell] = number (sort order, lower = first)
    ShreddedSettings["barpriority"] = {}
    local prioritySpells = {
        "TIGERS_FURY",      -- 1
        "CLEARCASTING",     -- 2
        "BLOODTALONS",      -- 3
        "RIP",              -- 4
        "RAKE",             -- 5
        "THRASH",           -- 6
        "MOONFIRE_CAT",     -- 7
        "BERSERK",          -- 8
        "INCARNATION",      -- 9
        "DREADFUL_WOUND",   -- 10 (Ravage debuff)
        "INFECTED_WOUNDS",  -- 11
        "FERAL_FRENZY",     -- 12
        "FRANTIC_FRENZY",   -- 13
        "ENERGY",           -- 14
        "COMBO",            -- 15
    }
    
    for i, key in ipairs(prioritySpells) do
        ShreddedSettings["barorder"]["ShreddedBar" .. i] = key
        ShreddedSettings["baron"][key] = true
        ShreddedSettings["barpriority"][key] = i
    end
    
    -- Set priority for remaining spells (append after priority list)
    local nextPriority = #prioritySpells + 1
    for _, key in ipairs(ShreddedCatSpells) do
        if ShreddedSettings["baron"][key] == nil then
            ShreddedSettings["baron"][key] = false -- disabled by default
        end
    end
    
    -- Set bar colors
    ShreddedSettings["barcolor"]["TIGERS_FURY"] = {1, 0.8, 0}
    ShreddedSettings["barcolor"]["BERSERK"] = {1, 0, 0.5}
    ShreddedSettings["barcolor"]["BLOODTALONS"] = {0.8, 0.2, 0.2}
    ShreddedSettings["barcolor"]["CLEARCASTING"] = {0, 1, 0}
    ShreddedSettings["barcolor"]["PREDATORY_SWIFTNESS"] = {0.4, 1, 0.4}
    ShreddedSettings["barcolor"]["SUDDEN_AMBUSH"] = {0.6, 0, 0.8}
    ShreddedSettings["barcolor"]["APEX_PREDATOR"] = {1, 0.4, 0}
    ShreddedSettings["barcolor"]["RIP"] = {1, 0, 0}
    ShreddedSettings["barcolor"]["RAKE"] = {1, 0.3, 0.3}
    ShreddedSettings["barcolor"]["THRASH"] = {0.8, 0.4, 0}
    ShreddedSettings["barcolor"]["MOONFIRE_CAT"] = {0.4, 0.4, 1}
    ShreddedSettings["barcolor"]["FERAL_FRENZY"] = {1, 0.5, 0}
    ShreddedSettings["barcolor"]["FRANTIC_FRENZY"] = {1, 0.6, 0.1}  -- Similar to Feral Frenzy
    ShreddedSettings["barcolor"]["DREADFUL_WOUND"] = {0.8, 0.2, 0.6}  -- Ravage debuff
    ShreddedSettings["barcolor"]["INFECTED_WOUNDS"] = {0.5, 0.8, 0.3}  -- Green-ish
    ShreddedSettings["barcolor"]["FRENZIED_ASSAULT"] = {0.9, 0.3, 0.5}
    ShreddedSettings["barcolor"]["PRIMAL_WRATH"] = {0.8, 0.1, 0.1}
    ShreddedSettings["barcolor"]["RAVAGE"] = {0.7, 0.2, 0.9}  -- Purple for Ravage buff
    ShreddedSettings["barcolor"]["CLAW_RAMPAGE"] = {0.8, 0.3, 0.8}
    ShreddedSettings["barcolor"]["INCARNATION"] = {1, 0.1, 0.6}
    ShreddedSettings["barcolor"]["ENERGY"] = {0, 0.8, 1}
    ShreddedSettings["barcolor"]["COMBO"] = {1, 1, 0}
    ShreddedSettings["barcolor"]["font"] = {1, 1, 1}
    
    exportBarOrder()
end

function exportBarOrder()
    wipe(barOrder)
    
    -- Build list of enabled spells that the player actually HAS
    local enabledSpells = {}
    
    -- Get the spell list
    local spellList = {}
    if ShreddedCatSpells and #ShreddedCatSpells > 0 then
        spellList = ShreddedCatSpells
    end
    
    for _, key in ipairs(spellList) do
        -- Must be enabled in settings AND player must have the spell
        local isEnabled = ShreddedSettings["baron"][key]
        local hasSpell = Shredded_PlayerHasSpell(key)
        
        if isEnabled and hasSpell then
            local priority = ShreddedSettings["barpriority"] and ShreddedSettings["barpriority"][key] or 99
            table.insert(enabledSpells, { key = key, priority = priority })
        end
    end
    
    -- Sort by priority (lower = first)
    table.sort(enabledSpells, function(a, b) return a.priority < b.priority end)
    
    -- Assign to frames and update barorder setting
    wipe(ShreddedSettings["barorder"])
    for i, data in ipairs(enabledSpells) do
        local frameName = "ShreddedBar" .. i
        barOrder[frameName] = data.key
        ShreddedSettings["barorder"][frameName] = data.key
    end
end

-- ===========================================
-- AURA SCANNING (Direct spell ID lookup to avoid secret values)
-- ===========================================

-- Convert potentially secret value to number - no comparisons!
-- Made global for debug access
function Shredded_ToNum(val)
    if val == nil then return 0 end
    -- Try multiple extraction methods
    local result = tonumber(tostring(val))
    if result then return result end
    -- Try format
    local ok, formatted = pcall(string.format, "%f", val)
    if ok then
        result = tonumber(formatted)
        if result then return result end
    end
    return 0
end
local ToNum = Shredded_ToNum

-- Convert secret value to string for comparison (secrets can be concatenated!)
local function SecretToString(val)
    if val == nil then return "" end
    local ok, result = pcall(string.format, "%s", val)
    if ok then return result end
    return ""
end

-- Store raw aura data (expirationTime is secret in combat)
-- Made global for debug access
Shredded_auraRawData = {}
local auraRawData = Shredded_auraRawData

-- Find aura by iterating and matching NAME (spellId is secret in combat!)
-- Name is ALSO secret - we use table lookup trick to compare
local function FindAuraByName(unit, filter, targetName)
    if not targetName then return nil end
    for i = 1, 40 do
        local data = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
        if not data then break end
        -- Secret value trick: table keys can be secret, lookup by known key works!
        local matched = false
        pcall(function()
            local lookup = {}
            lookup[data.name] = true  -- Index by secret name
            matched = lookup[targetName]  -- Lookup by known name
        end)
        if matched then
            return data, i
        end
    end
    return nil
end

local function FindPlayerAura(spellKey)
    local spellId = SPELL_IDS[spellKey]
    
    -- For procs not in SPELL_IDS, get ID from metadata
    if not spellId or type(spellId) ~= "number" then
        local meta = Shredded_SpellMeta[spellKey]
        if meta and meta.id then
            spellId = meta.id
        else
            return nil
        end
    end
    
    local now = GetTime()
    
    -- Build list of IDs to check (primary + alternates)
    local idsToCheck = {spellId}
    local spellData = ACTIVE_SPELLS[spellKey] or Shredded_SpellMeta[spellKey]
    if spellData and spellData.altIds then
        for _, altId in ipairs(spellData.altIds) do
            table.insert(idsToCheck, altId)
        end
    end
    
    -- PRIORITY 1: CDM Viewer-based lookup (works in combat with secret values!)
    -- Blizzard's CDM viewer frames store auraInstanceID as a plain readable property
    -- KEY: If viewerInstId is non-nil, the aura IS active. Timing extraction is best-effort.
    -- NOTE: Only BuffIcon/BuffBar viewers support auraInstanceID; Essential/Utility do NOT.
    for _, checkId in ipairs(idsToCheck) do
        local viewerFrame = Shredded_viewerAuraFrames[checkId]
        if viewerFrame then
            -- Check auraInstanceID (only populated by BuffIcon/BuffBar viewers)
            local viewerInstId = viewerFrame.auraInstanceID
            if viewerInstId then
                local unit = viewerFrame.auraDataUnit or "player"
                if unit == "player" then
                    -- Aura IS active (viewerInstId non-nil proves it)
                    -- Try to get timing (best-effort, not required for detection)
                    local remainingSec, totalDurationSec = nil, nil
                    local ok, durationObj = pcall(C_UnitAuras.GetAuraDuration, unit, viewerInstId)
                    if ok and durationObj then
                        remainingSec, totalDurationSec = DecodeDurationObject(durationObj)
                    end
                    -- If decode failed, try the viewer's Cooldown widget
                    if not remainingSec and viewerFrame.Cooldown then
                        local startMs, durMs = viewerFrame.Cooldown:GetCooldownTimes()
                        pcall(function()
                            if durMs and durMs > 0 then
                                local endMs = startMs + durMs
                                if endMs > now * 1000 then
                                    remainingSec = (endMs - now * 1000) / 1000
                                    totalDurationSec = durMs / 1000
                                end
                            end
                        end)
                    end
                    -- Populate auraRawData with whatever timing we got
                    local duration = totalDurationSec or BASE_DURATIONS[spellKey] or 15
                    local expTime = remainingSec and (now + remainingSec) or (now + duration)
                    auraRawData[spellKey] = {
                        duration = duration,
                        expirationTime = expTime,
                        exists = true,
                        source = remainingSec and "CDM_viewer" or "CDM_active"
                    }
                    return { spellId = checkId, auraInstanceID = viewerInstId }
                end
            end
            -- NOTE: Do NOT use Cooldown widget as fallback detection.
            -- Cooldown:GetCooldownTimes() retains stale data from previously-active
            -- procs, causing false positives. Only auraInstanceID is reliable.
        end
    end
    
    -- PRIORITY 2: Direct API lookup (fallback — works out of combat, partial in combat)
    -- Only check the primary spell ID here, NOT altIds.
    -- altIds contain talent/ability IDs (e.g. 16864 Omen of Clarity) that return
    -- passive auras ALWAYS active on the player, causing false positives.
    do
        local auraData = nil
        pcall(function()
            auraData = C_UnitAuras.GetPlayerAuraBySpellID(spellId)
        end)
        if auraData then
            -- Aura exists! Try to get timing (best-effort)
            local duration = nil
            local expirationTime = nil
            local gotTiming = false
            
            -- Try direct numeric extraction (works out of combat)
            pcall(function()
                local d = auraData.duration
                local e = auraData.expirationTime
                local test = e - now
                if test > -1000 and test < 10000 then
                    duration = d
                    expirationTime = e
                    gotTiming = true
                end
            end)
            
            -- Try GetAuraDuration with decoder (auraInstanceID may be secret here)
            if not gotTiming then
                local instId = nil
                pcall(function() instId = auraData.auraInstanceID end)
                if instId then
                    pcall(function()
                        local durationObj = C_UnitAuras.GetAuraDuration("player", instId)
                        if durationObj then
                            local remainingSec, totalDurationSec = DecodeDurationObject(durationObj)
                            if remainingSec and remainingSec > 0 then
                                duration = totalDurationSec or BASE_DURATIONS[spellKey] or 15
                                expirationTime = now + remainingSec
                                gotTiming = true
                            end
                        end
                    end)
                end
            end
            
            -- Even without timing, the aura IS active — use estimated duration
            if not gotTiming then
                duration = BASE_DURATIONS[spellKey] or 15
                expirationTime = now + duration
            end
            
            auraRawData[spellKey] = {
                duration = duration,
                expirationTime = expirationTime,
                exists = true,
                source = gotTiming and "API" or "estimated"
            }
            return auraData
        end
    end
    
    -- Not found - preserve test data if in test mode
    if Shredded_TestMode and auraRawData[spellKey] and auraRawData[spellKey].source == "TEST" then
        return { spellId = spellId, testMode = true }
    end
    
    auraRawData[spellKey] = nil
    return nil
end

local function FindTargetDebuff(spellKey)
    local spellId = SPELL_IDS[spellKey]
    
    -- Fallback to spell database if SPELL_IDS not populated (API failure during scan)
    if not spellId or type(spellId) ~= "number" then
        local meta = Shredded_SpellMeta[spellKey]
        if meta and meta.id and type(meta.id) == "number" then
            spellId = meta.id
        else
            return nil
        end
    end
    
    local now = GetTime()
    local selfData = Shredded_selfTrack.target[spellKey]
    local inCombat = InCombatLockdown()
    
    -- Check if target exists
    if not UnitExists("target") then
        if not (Shredded_TestMode and auraRawData[spellKey] and auraRawData[spellKey].source == "TEST") then
            auraRawData[spellKey] = nil
        end
        return nil
    end
    
    -- Check for target change - invalidate tracking for different target
    local currentTargetGUID = UnitGUID("target")
    if currentTargetGUID ~= Shredded_lastTargetGUID then
        if selfData and selfData.targetGUID and selfData.targetGUID ~= currentTargetGUID then
            Shredded_selfTrack.target[spellKey] = nil
            selfData = nil
        end
    end
    
    -- Build list of IDs to check (primary + debuffId + alternates)
    local idsToCheck = {spellId}
    local spellData = ACTIVE_SPELLS[spellKey] or Shredded_SpellMeta[spellKey]
    if spellData and spellData.debuffId and spellData.debuffId ~= spellId then
        table.insert(idsToCheck, spellData.debuffId)
    end
    if spellData and spellData.altIds then
        for _, altId in ipairs(spellData.altIds) do
            table.insert(idsToCheck, altId)
        end
    end
    
    -- PRIORITY 1: CDM Viewer-based lookup (works in combat with secret values!)
    -- KEY: If viewerInstId is non-nil, the aura IS active. Timing is best-effort.
    for _, checkId in ipairs(idsToCheck) do
        local viewerFrame = Shredded_viewerAuraFrames[checkId]
        if viewerFrame then
            local viewerInstId = viewerFrame.auraInstanceID
            if viewerInstId then
                local unit = viewerFrame.auraDataUnit or "target"
                if unit == "target" then
                    -- Aura IS active — try timing (best-effort)
                    local remainingSec, totalDurationSec = nil, nil
                    local ok, durationObj = pcall(C_UnitAuras.GetAuraDuration, unit, viewerInstId)
                    if ok and durationObj then
                        remainingSec, totalDurationSec = DecodeDurationObject(durationObj)
                    end
                    if not remainingSec and viewerFrame.Cooldown then
                        local startMs, durMs = viewerFrame.Cooldown:GetCooldownTimes()
                        pcall(function()
                            if durMs and durMs > 0 then
                                local endMs = startMs + durMs
                                if endMs > now * 1000 then
                                    remainingSec = (endMs - now * 1000) / 1000
                                    totalDurationSec = durMs / 1000
                                end
                            end
                        end)
                    end
                    local duration = totalDurationSec or BASE_DURATIONS[spellKey] or 15
                    local expTime = remainingSec and (now + remainingSec) or (now + duration)
                    auraRawData[spellKey] = {
                        duration = duration,
                        expirationTime = expTime,
                        exists = true,
                        source = remainingSec and "CDM_viewer" or "CDM_active"
                    }
                    Shredded_selfTrack.target[spellKey] = {
                        startTime = expTime - duration,
                        duration = duration,
                        expirationTime = expTime,
                        lastSeen = now,
                        targetGUID = currentTargetGUID,
                        fromAPI = true
                    }
                    return { spellId = checkId, auraInstanceID = viewerInstId }
                end
            end
            -- NOTE: Do NOT use Cooldown widget as fallback detection.
            -- Cooldown:GetCooldownTimes() retains stale data from previously-active
            -- debuffs, causing false positives. Only auraInstanceID is reliable.
        end
    end
    
    -- PRIORITY 2: Self-tracked data from spellcast events (secondary debuffs)
    if selfData and selfData.expirationTime then
        if selfData.expirationTime > now then
            auraRawData[spellKey] = {
                duration = selfData.duration,
                expirationTime = selfData.expirationTime,
                exists = true,
                source = "tracked"
            }
            return { spellId = spellId, selfTracked = true }
        else
            Shredded_selfTrack.target[spellKey] = nil
        end
    end
    
    -- PRIORITY 3: Direct API lookup (works better out of combat)
    local auraData = nil
    local function CheckDebuff(aura)
        if not aura then return end
        local auraSpellId = nil
        pcall(function()
            auraSpellId = tonumber(string.format("%d", aura.spellId))
        end)
        local isPlayerSource = false
        local sourceUnknown = false
        pcall(function()
            local src = aura.sourceUnit
            local fromPet = aura.isFromPlayerOrPlayerPet
            if src == "player" or fromPet == true then
                isPlayerSource = true
            elseif src == nil and fromPet == nil then
                sourceUnknown = true
            end
        end)
        if auraSpellId then
            for _, checkId in ipairs(idsToCheck) do
                if auraSpellId == checkId then
                    if isPlayerSource or sourceUnknown then
                        auraData = aura
                        return true
                    end
                end
            end
        end
    end
    AuraUtil.ForEachAura("target", "HARMFUL", nil, CheckDebuff, true)
    
    if auraData then
        local duration = nil
        local expirationTime = nil
        local gotTiming = false
        
        pcall(function()
            local d = auraData.duration
            local e = auraData.expirationTime
            local test = e - now
            if test > -1000 and test < 10000 then
                duration = d
                expirationTime = e
                gotTiming = true
            end
        end)
        
        if not gotTiming and auraData.auraInstanceID then
            pcall(function()
                local durationObj = C_UnitAuras.GetAuraDuration("target", auraData.auraInstanceID)
                if durationObj then
                    local remainingSec, totalDurationSec = DecodeDurationObject(durationObj)
                    if remainingSec and remainingSec > 0 then
                        duration = totalDurationSec or BASE_DURATIONS[spellKey] or 15
                        expirationTime = now + remainingSec
                        gotTiming = true
                    end
                end
            end)
        end
        
        if not gotTiming then
            duration = BASE_DURATIONS[spellKey] or 15
            expirationTime = now + duration
        end
        
        Shredded_selfTrack.target[spellKey] = {
            startTime = expirationTime - duration,
            duration = duration,
            expirationTime = expirationTime,
            lastSeen = now,
            targetGUID = currentTargetGUID,
            fromAPI = gotTiming
        }
        auraRawData[spellKey] = {
            duration = duration,
            expirationTime = expirationTime,
            exists = true,
            source = gotTiming and "API" or "estimated"
        }
        return auraData
    end
    
    -- Combat fallback - trust tracking if API fails
    if inCombat and selfData and selfData.expirationTime and selfData.expirationTime > now then
        auraRawData[spellKey] = {
            duration = selfData.duration,
            expirationTime = selfData.expirationTime,
            exists = true,
            source = "combat_fallback"
        }
        return { spellId = spellId, selfTracked = true }
    end
    
    -- Not found
    if Shredded_TestMode and auraRawData[spellKey] and auraRawData[spellKey].source == "TEST" then
        return { spellId = spellId, testMode = true }
    end
    auraRawData[spellKey] = nil
    Shredded_selfTrack.target[spellKey] = nil
    return nil
end

local function UpdatePlayerBuff(spellKey)
    local aura = FindPlayerAura(spellKey)
    if aura then
        -- Store that aura is active (don't try to read secret values)
        timers[spellKey] = 1 -- Just mark as active
        ShreddedV("Buff FOUND: " .. spellKey)
        return true
    end
    timers[spellKey] = 0
    -- Preserve test data if in test mode
    if not (Shredded_TestMode and auraRawData[spellKey] and auraRawData[spellKey].source == "TEST") then
        auraRawData[spellKey] = nil
    end
    return false
end

local function UpdateTargetDebuff(spellKey)
    local aura = FindTargetDebuff(spellKey)
    if aura then
        -- Store that aura is active (don't try to read secret values)
        timers[spellKey] = 1 -- Just mark as active
        ShreddedV("Debuff FOUND: " .. spellKey)
        return true
    end
    timers[spellKey] = 0
    -- Preserve test data if in test mode
    if not (Shredded_TestMode and auraRawData[spellKey] and auraRawData[spellKey].source == "TEST") then
        auraRawData[spellKey] = nil
    end
    return false
end

-- ===========================================
-- RESOURCE TRACKING
-- ===========================================

-- Cache for energy/combo since direct API returns secret values
-- Made global for debug access
Shredded_cachedEnergy = 0
Shredded_cachedMaxEnergy = 100
Shredded_cachedCombo = 0
Shredded_cachedMaxCombo = 5

-- Store raw (potentially secret) values for passing to UI
Shredded_rawEnergy = 0
Shredded_rawMaxEnergy = 100

local function UpdateEnergy()
    -- Store raw energy for StatusBar (accepts secret values via SetValue)
    Shredded_rawEnergy = UnitPower("player", 3)
    Shredded_rawMaxEnergy = UnitPowerMax("player", 3)
    
    -- Try to extract numeric values for caching/comparison
    -- string.format is allowed with secret values per Midnight API
    -- Cache max energy (usually doesn't change, so cache aggressively)
    local maxExtracted = false
    pcall(function()
        local m = UnitPowerMax("player", 3)
        local formatted = string.format("%d", m)
        local num = tonumber(formatted)
        if num and num > 0 then
            Shredded_cachedMaxEnergy = num
            maxExtracted = true
        end
    end)
    
    -- Cache current energy - try multiple extraction methods
    local energyExtracted = false
    pcall(function()
        local e = UnitPower("player", 3)
        local formatted = string.format("%d", e)
        local num = tonumber(formatted)
        if num then
            Shredded_cachedEnergy = num
            energyExtracted = true
        end
    end)
    
    -- If extraction failed in combat, keep using last cached value
    -- (the raw value will still work for SetValue display)
    
    -- For timers table, use cached max (we'll handle display differently)
    timers["ENERGY"] = Shredded_rawEnergy  -- Pass raw to bar
    durations["ENERGY"] = Shredded_cachedMaxEnergy
end

local function UpdateComboPoints()
    -- Store raw combo points for direct UI pass-through
    local rawCombo = UnitPower("player", 4)
    local rawMaxCombo = UnitPowerMax("player", 4)
    
    -- Combo points CAN usually be extracted
    pcall(function()
        local c = UnitPower("player", 4)
        local m = UnitPowerMax("player", 4)
        local cNum = tonumber(string.format("%d", c))
        local mNum = tonumber(string.format("%d", m))
        if cNum then Shredded_cachedCombo = cNum end
        if mNum and mNum > 0 then Shredded_cachedMaxCombo = mNum end
    end)
    
    timers["COMBO"] = rawCombo  -- Pass raw for SetValue
    durations["COMBO"] = Shredded_cachedMaxCombo
end

-- ===========================================
-- COOLDOWN TRACKING (removed - now handled by aura system)
-- ===========================================

local function UpdateCooldowns()
    -- Tiger's Fury and Berserk are now tracked as buffs via the aura system
    -- No separate cooldown tracking needed
end

-- ===========================================
-- TIMER PROCESSING
-- ===========================================

local function Timerize()
    wipe(floorTimes)
    wipe(fTimes)
    
    for key, active in pairs(timers) do
        if key == "ENERGY" or key == "COMBO" then
            -- Resources use their direct values
            floorTimes[key] = SafeNumber(active, 0)
            fTimes[key] = SafeNumber(active, 0)
        else
            -- For auras, just mark if active (1) or not (0)
            -- Actual timer display will use SetTimerDuration with raw values
            if active ~= 0 and auraRawData[key] then
                floorTimes[key] = 1 -- Active
                fTimes[key] = 1
            else
                floorTimes[key] = 0
                fTimes[key] = 0
            end
        end
    end
end

-- ===========================================
-- AURA REFRESH
-- ===========================================

local function RefreshAllAuras()
    -- Dynamically update all active spells based on type
    for key, data in pairs(ACTIVE_SPELLS) do
        if data.type == "buff" then
            UpdatePlayerBuff(key)
        elseif data.type == "debuff" then
            UpdateTargetDebuff(key)
        end
        -- Resources are updated separately (UpdateEnergy, UpdateComboPoints)
    end
    
    -- ALSO scan all Cooldown/Proc spells - they may not be in ACTIVE_SPELLS
    -- if GetSpellName() returned secret values during ScanPlayerSpells()
    for _, key in ipairs(ShreddedCooldownSpells) do
        local meta = Shredded_SpellMeta[key]
        if meta and meta.type == "buff" and (meta.isProc or meta.isCooldown) then
            -- Only scan if not already scanned via ACTIVE_SPELLS
            if not ACTIVE_SPELLS[key] then
                UpdatePlayerBuff(key)
            end
        end
    end
    
    -- Always check secondary debuffs that may not be in ACTIVE_SPELLS
    -- These are applied as side effects of other abilities
    local secondaryDebuffs = {"DREADFUL_WOUND", "INFECTED_WOUNDS"}
    for _, key in ipairs(secondaryDebuffs) do
        if not ACTIVE_SPELLS[key] then
            UpdateTargetDebuff(key)
        end
    end
end

-- ===========================================
-- EVENT HANDLING
-- ===========================================

-- Use anonymous frame (no name) to avoid protected function errors in Midnight
local mainFrame = CreateFrame("Frame", nil, UIParent)
mainFrame:SetSize(1, 1)
mainFrame:SetPoint("CENTER")

-- Use C_Timer based initialization (Midnight-safe - no events at all)
-- EventRegistry may internally call Frame:RegisterEvent which is protected
local function InitializeAddon()
    BuildCatSpellsList()
    InitSpellData()
    InitTimers()
    CheckVersion()
    Shredded_LoadFrames()
    Shredded_Refresh()
    Shredded_SetupOptions()
    ShreddedO("Shredded 1.0 loaded! /shredded move, /shredded debug, /shredded reset")
    
    -- Mark addon as fully initialized
    addonInitialized = true
    
    -- Delayed player setup
    C_Timer.After(1, function()
        ScanPlayerSpells()
        Shredded_CooldownPersonality()
        Shredded_BarPersonality()
    end)
end

-- State tracking for polling
local lastTargetGUID = nil
local lastInCombat = false
local lastTalentConfig = nil

-- Helper functions for aura processing (defined at module level for reuse)
local function ProcessAuraData(auraData, source, unit)
    if not auraData then return end
    
    local trackTable = (unit == "player") and Shredded_selfTrack.player or Shredded_selfTrack.target
    local now = GetTime()
    
    local spellIdNum = nil
    local auraDuration = nil
    local auraExpTime = nil
    local auraInstanceID = nil
    
    pcall(function()
        spellIdNum = tonumber(string.format("%d", auraData.spellId))
        auraDuration = tonumber(string.format("%.2f", auraData.duration))
        auraExpTime = tonumber(string.format("%.2f", auraData.expirationTime))
        auraInstanceID = auraData.auraInstanceID
    end)
    
    if spellIdNum and spellIdNum > 0 then
        for key, id in pairs(SPELL_IDS) do
            if id == spellIdNum then
                local finalDuration = auraDuration
                local finalExpTime = auraExpTime
                
                if not finalDuration or finalDuration <= 0 then
                    finalDuration = BASE_DURATIONS[key] or 15
                end
                if not finalExpTime or finalExpTime <= now then
                    finalExpTime = now + finalDuration
                end
                
                trackTable[key] = {
                    startTime = finalExpTime - finalDuration,
                    duration = finalDuration,
                    expirationTime = finalExpTime,
                    lastSeen = now,
                    auraInstanceID = auraInstanceID,
                    fromEvent = true
                }
                ShreddedO(source .. ": " .. key .. " on " .. unit .. " dur=" .. tostring(finalDuration) .. " exp=" .. tostring(finalExpTime))
                break
            end
        end
    end
end

local function RefreshByInstanceID(auraInstanceID, source, unit)
    local trackTable = (unit == "player") and Shredded_selfTrack.player or Shredded_selfTrack.target
    local now = GetTime()
    
    local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
    if auraData then
        ProcessAuraData(auraData, source, unit)
        return true
    end
    
    for key, data in pairs(trackTable) do
        if data.auraInstanceID == auraInstanceID then
            local baseDur = BASE_DURATIONS[key] or data.duration or 15
            trackTable[key] = {
                startTime = now,
                duration = baseDur,
                expirationTime = now + baseDur,
                lastSeen = now,
                auraInstanceID = auraInstanceID,
                fromRefresh = true
            }
            ShreddedO(source .. " (refresh): " .. key .. " on " .. unit .. " dur=" .. tostring(baseDur))
            return true
        end
    end
    return false
end

-- Initialize polling system using C_Timer.NewTicker (NOT OnUpdate - much lower CPU)
local function StartPolling()
    local pollInterval = 0.2  -- Poll every 200ms
    local pollDebugOnce = true
    local cdDebugOnce = true
    
    -- Cooldown tracking data (moved from StartCooldownTracking)
    local COOLDOWN_TO_BUFF = {
        [5217] = { key = "TIGERS_FURY", duration = 15 },
        [106951] = { key = "BERSERK", duration = 20 },
        [102543] = { key = "INCARNATION", duration = 30 },
    }
    local ABILITY_TO_DEBUFF = {
        [1079] = { key = "RIP", duration = 24 },
        [1822] = { key = "RAKE", duration = 15 },
        [106830] = { key = "THRASH", duration = 15 },
        [155625] = { key = "MOONFIRE_CAT", duration = 16 },
    }
    local lastCdStart = {}
    local prevComboCD = 0
    local prevEnergyCD = 0
    local prevGCDStart = 0
    
    -- Helper to extract cooldown values
    -- Returns start, duration, status - handles secret values gracefully
    local function GetCDStartTime(spellId)
        -- Try new Duration Object API first (Midnight-safe)
        local durationObj = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(spellId)
        if durationObj then
            -- Duration objects have readable fields
            local ok, start, dur = pcall(function()
                return durationObj.startTime, durationObj.duration
            end)
            if ok and start then
                local numStart = tonumber(string.format("%.3f", start))
                local numDur = tonumber(string.format("%.3f", dur))
                if numStart then
                    return numStart, numDur, "duration_obj"
                end
            end
        end
        
        -- Fall back to legacy API
        local cdInfo = C_Spell.GetSpellCooldown(spellId)
        if not cdInfo then 
            return nil, nil, "no_cdInfo"
        end
        
        -- Try to extract via string.format -> tonumber
        -- If value is secret, tonumber will return nil
        local numStart, numDur
        local ok = pcall(function()
            local strStart = string.format("%.3f", cdInfo.startTime)
            local strDur = string.format("%.3f", cdInfo.duration)
            numStart = tonumber(strStart)
            numDur = tonumber(strDur)
        end)
        
        if not ok or not numStart then
            return nil, nil, "secret"
        end
        
        return numStart, numDur, "ok"
    end
    
    -- Cancel existing ticker if any
    if pollTicker then
        pollTicker:Cancel()
        pollTicker = nil
    end
    
    -- Use C_Timer.NewTicker instead of OnUpdate - only fires at interval, no per-frame overhead
    pollTicker = C_Timer.NewTicker(pollInterval, function()
        local now = GetTime()
        
        -- Debug once per session
        if pollDebugOnce then
            pollDebugOnce = false
            print("|cFF00FF00Shredded:|r Poll ticker running (200ms interval)")
        end
        
        -- Poll target change
        local currentTargetGUID = UnitGUID("target")
        if currentTargetGUID ~= lastTargetGUID then
            lastTargetGUID = currentTargetGUID
            Shredded_lastTargetGUID = currentTargetGUID  -- Update global for FindTargetDebuff
            wipe(Shredded_cleuAuras.target)
            wipe(Shredded_selfTrack.target)
            isDirty = true  -- Force UI update
        end
        
        -- Poll combat state
        local inCombat = InCombatLockdown()
        if inCombat ~= lastInCombat then
            if inCombat then
                -- Entered combat
                lastBarOrder = barOrder
                Shredded_BarPersonality()
            else
                -- Left combat - clear stale data
                wipe(Shredded_cleuAuras.player)
                wipe(Shredded_cleuAuras.target)
            end
            lastInCombat = inCombat
            isDirty = true  -- Force UI update
        end
        
        -- NOTE: Energy, Combo, and Aura polling is now done in main ticker (throttled)
        -- This polling loop only handles state changes that trigger dirty flag
        
        -- =====================================================
        -- COOLDOWN-BASED TRACKING (integrated into main poll)
        -- =====================================================
        local cdOk, cdErr = pcall(function()
            local form = 0
            pcall(function() form = GetShapeshiftForm() end)
            
            -- Debug form check once per combat (use separate flag)
            if cdDebugOnce then
                cdDebugOnce = false
                -- Removed spam print, only show on first load
            end
            
            -- DISABLE form check for now - track in any form
            -- if form ~= 2 then return end
            
            -- Check buff cooldowns (Tiger's Fury, Berserk, etc)
            for spellId, buffInfo in pairs(COOLDOWN_TO_BUFF) do
                local startTime, duration, status = GetCDStartTime(spellId)
                local prevStart = lastCdStart[spellId] or 0
                
                if startTime and startTime > 0 and duration and duration > 1.5 then
                    -- Detect NEW cooldown start
                    if startTime > prevStart + 0.5 then
                        local key = buffInfo.key
                        local dur = buffInfo.duration
                        Shredded_selfTrack.player[key] = {
                            startTime = now,
                            duration = dur,
                            expirationTime = now + dur,
                            lastSeen = now,
                            fromCooldown = true
                        }
                        print("|cFF00FF00Shredded:|r CD BUFF: " .. key .. " dur=" .. dur .. " (start=" .. startTime .. " prev=" .. prevStart .. ")")
                    end
                    lastCdStart[spellId] = startTime
                elseif startTime == 0 then
                    lastCdStart[spellId] = 0
                end
            end
            
            -- Check debuff casts via combo/energy tracking
            local targetGUID = UnitGUID("target")
            if targetGUID then
                local comboPoints, energy = 0, 0
                pcall(function()
                    local cpRaw = UnitPower("player", 4)  -- Combo Points
                    local enRaw = UnitPower("player", 3)  -- Energy
                    comboPoints = tonumber(string.format("%d", cpRaw or 0)) or 0
                    energy = tonumber(string.format("%d", enRaw or 0)) or 0
                end)
                
                -- Detect GCD
                local gcdStart, gcdDuration
                for _, testSpellId in ipairs({5221, 1822, 5176, 8921}) do
                    local s, d = GetCDStartTime(testSpellId)
                    if s and s > 0 and d and d > 0 and d < 2.0 then
                        gcdStart, gcdDuration = s, d
                        break
                    end
                end
                
                local newGCD = gcdStart and gcdStart > prevGCDStart + 0.3
                
                if newGCD then
                    prevGCDStart = gcdStart
                    
                    local comboDiff = prevComboCD - comboPoints
                    
                    -- Finisher detection (Rip) - combo points spent
                    if comboDiff >= 1 and prevComboCD >= 1 then
                        local key = "RIP"
                        local dur = 24
                        local existing = Shredded_selfTrack.target[key]
                        local extraTime = 0
                        if existing and existing.expirationTime then
                            local remaining = existing.expirationTime - now
                            if remaining > 0 then extraTime = math.min(remaining, dur * 0.3) end
                        end
                        Shredded_selfTrack.target[key] = {
                            startTime = now, duration = dur + extraTime,
                            expirationTime = now + dur + extraTime,
                            lastSeen = now, targetGUID = targetGUID, fromCast = true
                        }
                        print("|cFF00FF00Shredded:|r DETECTED: RIP (combo spent: " .. comboDiff .. ")")
                    end
                end
                
                prevComboCD = comboPoints
                prevEnergyCD = energy
            end
        end)
        
        if not cdOk then
            print("|cFFFF0000Shredded CD Error:|r " .. tostring(cdErr))
        end
    end)
end

-- Poll auras by iterating through all auras on a unit
-- OPTIMIZED: Only check spells relevant to unit type
function PollAuras(unit)
    local trackTable = (unit == "player") and Shredded_selfTrack.player or Shredded_selfTrack.target
    local cacheTable = (unit == "player") and Shredded_cachedDurations.player or Shredded_cachedDurations.target
    local now = GetTime()
    local foundAuras = {}
    local inCombat = InCombatLockdown()
    local isPlayerUnit = (unit == "player")
    
    -- Direct spell ID lookup - fastest method
    for key, spellId in pairs(SPELL_IDS) do
        if type(spellId) == "number" then
            -- Skip spells not relevant to this unit type
            local spellData = ACTIVE_SPELLS[key]
            if spellData then
                local isBuff = (spellData.type == "buff")
                local isDebuff = (spellData.type == "debuff")
                
                -- Only check buffs on player, debuffs on target
                if (isPlayerUnit and isBuff) or (not isPlayerUnit and isDebuff) then
                    local auraData = nil
                    if isPlayerUnit then
                        -- Wrap in pcall for combat secret value protection
                        pcall(function()
                            auraData = C_UnitAuras.GetPlayerAuraBySpellID(spellId)
                        end)
                        -- Also check alternate IDs
                        if not auraData and spellData.altIds then
                            for _, altId in ipairs(spellData.altIds) do
                                pcall(function()
                                    if not auraData then
                                        auraData = C_UnitAuras.GetPlayerAuraBySpellID(altId)
                                    end
                                end)
                                if auraData then break end
                            end
                        end
                    else
                        -- Build list of spell IDs to check (include debuffId for spells like Frantic Frenzy)
                        local idsToCheck = {spellId}
                        if spellData.debuffId and spellData.debuffId ~= spellId then
                            table.insert(idsToCheck, spellData.debuffId)
                        end
                        if spellData.altIds then
                            for _, altId in ipairs(spellData.altIds) do
                                table.insert(idsToCheck, altId)
                            end
                        end
                        
                        -- For debuffs on target, iterate using modern API
                        local function CheckDebuff(aura)
                            if not aura then return end
                            -- Extract spellId safely (may be secret value)
                            local auraSpellId = nil
                            local isPlayerSource = false
                            pcall(function()
                                auraSpellId = tonumber(string.format("%d", aura.spellId))
                                isPlayerSource = (aura.sourceUnit == "player") or aura.isFromPlayerOrPlayerPet
                            end)
                            -- Check against all possible spell IDs
                            if auraSpellId and isPlayerSource then
                                for _, checkId in ipairs(idsToCheck) do
                                    if auraSpellId == checkId then
                                        auraData = aura
                                        return true  -- Stop iteration
                                    end
                                end
                            end
                        end
                        AuraUtil.ForEachAura(unit, "HARMFUL", nil, CheckDebuff, true)
                        
                        -- Fallback to spell name lookup
                        if not auraData then
                            local spellName = SPELL_NAMES[key]
                            if spellName then
                                local tempAura = C_UnitAuras.GetAuraDataBySpellName(unit, spellName, "HARMFUL")
                                if tempAura then
                                    local isPlayerSource = false
                                    pcall(function()
                                        isPlayerSource = (tempAura.sourceUnit == "player") or tempAura.isFromPlayerOrPlayerPet
                                    end)
                                    if isPlayerSource then
                                        auraData = tempAura
                                    end
                                end
                            end
                        end
                    end
                    
                    if auraData then
                        foundAuras[key] = true
                        
                        local existing = trackTable[key]
                        local auraDuration, auraExpTime
                        
                        -- Single pcall for both extractions
                        pcall(function()
                            auraDuration = tonumber(string.format("%.2f", auraData.duration))
                            auraExpTime = tonumber(string.format("%.2f", auraData.expirationTime))
                        end)
                        
                        -- Cache readable durations
                        if auraDuration and auraDuration > 0 then
                            cacheTable[key] = auraDuration
                        end
                        
                        -- Only update if needed
                        local needsUpdate = not existing 
                            or not existing.expirationTime
                            or (auraExpTime and math.abs(auraExpTime - existing.expirationTime) > 0.5)
                        
                        if needsUpdate then
                            local finalDuration = auraDuration or cacheTable[key] or BASE_DURATIONS[key] or 15
                            local finalExpTime = auraExpTime
                            
                            if not finalExpTime or finalExpTime <= now then
                                if existing and existing.expirationTime and existing.expirationTime > now then
                                    finalExpTime = existing.expirationTime
                                else
                                    finalExpTime = now + finalDuration
                                end
                            end
                            
                            trackTable[key] = {
                                startTime = finalExpTime - finalDuration,
                                duration = finalDuration,
                                expirationTime = finalExpTime,
                                lastSeen = now,
                                fromDirectLookup = true
                            }
                        elseif existing then
                            existing.lastSeen = now
                        end
                    end
                end
            end
        end
    end
    
    -- REMOVED: ForEachAura iteration - too expensive, direct lookup above is sufficient
    -- The event handler (UNIT_SPELLCAST_SUCCEEDED) catches new applications
    
    -- Clear expired auras from tracking
    for key, data in pairs(trackTable) do
        if not foundAuras[key] then
            -- Aura not found - check if we should clear it
            if data.expirationTime and data.expirationTime < now then
                -- Definitely expired
                trackTable[key] = nil
            elseif not inCombat and data.lastSeen and (now - data.lastSeen) > 0.5 then
                -- Out of combat and not seen recently - clear
                trackTable[key] = nil
            end
            -- In combat with no expiration data - keep tracking (may be secret)
        end
    end
    
    -- Note: RefreshAllAuras is called by main OnUpdate, not needed here
end

-- Initialize addon immediately (called at file load time)
C_Timer.After(0, function()
    InitializeAddon()
    StartPolling()
    StartEventHandler()  -- Start event monitoring for aura/spell updates
    -- Step 1: Ensure CDM viewers are shown (alpha=0) so Blizzard populates children
    EnsureViewersShown()
    -- Step 2: Wait for Blizzard to populate cooldownInfo on viewer children (needs ~1s)
    C_Timer.After(1, function()
        BuildViewerAuraMap()
    end)
end)

-- Event Handler - uses standard WoW events for tracking
function StartEventHandler()
    local eventFrame = CreateFrame("Frame")
    
    -- Register standard events
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")  -- Spell casts
    eventFrame:RegisterEvent("UNIT_AURA")                 -- Aura changes
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")     -- Target change
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")     -- Enter combat
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")      -- Leave combat
    eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")     -- Cooldown changes
    eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")  -- Proc glow shown
    eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")  -- Proc glow hidden
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")  -- Spec change - rebuild viewer map
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")  -- Login/reload/instance - rebuild viewer map
    eventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")  -- CDM spell override change
    
    eventFrame:SetScript("OnEvent", function(self, event, ...)
        local now = GetTime()
        
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, castGUID, spellId = ...
            if unit ~= "player" then return end
            
            -- Track secondary debuffs from parent ability casts
            -- These debuffs are applied as side effects, not directly cast
            local targetGUID = UnitGUID("target")
            if targetGUID then
                -- DREADFUL_WOUND: Applied by Ravage (empowered Shred)
                -- Ravage spell IDs: 441585, 441591, or Shred (5221/6785) when Ravage buff is active
                local isRavageCast = (spellId == 441585 or spellId == 441591 or spellId == 6785)
                if not isRavageCast and (spellId == 5221 or spellId == 6785) then
                    -- Check if Ravage buff is active (empowering Shred)
                    local ravageActive = Shredded_selfTrack.player["RAVAGE"] 
                        and Shredded_selfTrack.player["RAVAGE"].expirationTime 
                        and Shredded_selfTrack.player["RAVAGE"].expirationTime > now
                    if ravageActive then
                        isRavageCast = true
                    end
                end
                
                if isRavageCast then
                    local dwDuration = BASE_DURATIONS["DREADFUL_WOUND"] or 10
                    Shredded_selfTrack.target["DREADFUL_WOUND"] = {
                        startTime = now,
                        duration = dwDuration,
                        expirationTime = now + dwDuration,
                        lastSeen = now,
                        targetGUID = targetGUID,
                        fromSpellcast = true
                    }
                    ShreddedV("SECONDARY DEBUFF: DREADFUL_WOUND from Ravage")
                    isDirty = true
                end
                
                -- INFECTED_WOUNDS: Applied by many melee attacks
                -- Spell IDs: Rake (1822), Shred (5221, 6785), Maim (22570), Mangle (33917), 
                -- Ravage variants (441585, 441591), Brutal Slash (202028), Thrash (106830)
                local appliesInfectedWounds = (spellId == 1822 or spellId == 5221 or spellId == 6785 
                    or spellId == 22570 or spellId == 33917 or spellId == 441585 or spellId == 441591
                    or spellId == 202028 or spellId == 106830)
                if appliesInfectedWounds then
                    local iwDuration = BASE_DURATIONS["INFECTED_WOUNDS"] or 12
                    -- Infected Wounds refreshes on application
                    Shredded_selfTrack.target["INFECTED_WOUNDS"] = {
                        startTime = now,
                        duration = iwDuration,
                        expirationTime = now + iwDuration,
                        lastSeen = now,
                        targetGUID = targetGUID,
                        fromSpellcast = true
                    }
                    ShreddedV("SECONDARY DEBUFF: INFECTED_WOUNDS")
                    isDirty = true
                end
            end
            
            -- Look up spell key from ID
            local spellKey = SPELL_ID_TO_KEY[spellId]
            if not spellKey then return end
            
            local spellData = ACTIVE_SPELLS[spellKey]
            if not spellData then return end
            
            -- For buff spells we cast, start tracking immediately
            if spellData.type == "buff" then
                local duration = Shredded_cachedDurations.player[spellKey] or BASE_DURATIONS[spellKey] or 15
                Shredded_selfTrack.player[spellKey] = {
                    startTime = now,
                    duration = duration,
                    expirationTime = now + duration,
                    lastSeen = now,
                    fromSpellcast = true
                }
                ShreddedV("CAST BUFF: " .. spellKey .. " dur=" .. duration)
                isDirty = true  -- Force immediate UI update
            elseif spellData.type == "debuff" then
                -- For debuff spells, apply to current target
                local targetGUID = UnitGUID("target")
                if targetGUID then
                    local duration = Shredded_cachedDurations.target[spellKey] or BASE_DURATIONS[spellKey] or 15
                    
                    -- Check for pandemic (refresh)
                    local existingData = Shredded_selfTrack.target[spellKey]
                    local expirationTime = now + duration
                    
                    if existingData and existingData.expirationTime and existingData.targetGUID == targetGUID then
                        local remaining = existingData.expirationTime - now
                        if remaining > 0 then
                            local pandemicBonus = math.min(remaining, duration * 0.3)
                            expirationTime = now + duration + pandemicBonus
                        end
                    end
                    
                    Shredded_selfTrack.target[spellKey] = {
                        startTime = now,
                        duration = expirationTime - now,
                        expirationTime = expirationTime,
                        lastSeen = now,
                        targetGUID = targetGUID,
                        fromSpellcast = true
                    }
                    ShreddedV("CAST DEBUFF: " .. spellKey .. " dur=" .. (expirationTime - now))
                    isDirty = true  -- Force immediate UI update
                end
            end
            
        elseif event == "UNIT_AURA" then
            local unit = ...
            if unit == "player" or unit == "target" then
                isDirty = true  -- Mark for update; FindPlayerAura/FindTargetDebuff will query CDM viewers
            end
            
        elseif event == "PLAYER_TARGET_CHANGED" then
            -- Clear target tracking on target change
            local newTargetGUID = UnitGUID("target")
            if newTargetGUID ~= Shredded_lastTargetGUID then
                Shredded_lastTargetGUID = newTargetGUID
                wipe(Shredded_selfTrack.target)
                wipe(Shredded_cleuAuras.target)
                isDirty = true
            end
            
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Left combat - clear CLEU data, rebuild viewer map
            wipe(Shredded_cleuAuras.player)
            wipe(Shredded_cleuAuras.target)
            BuildViewerAuraMap()  -- Rebuild in case CDM layout changed
            isDirty = true
            
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            -- Spec changed - rebuild viewer map after a short delay
            C_Timer.After(0.5, function()
                BuildViewerAuraMap()
                ShreddedV("Spec changed - viewer map rebuilt")
            end)
            isDirty = true
            
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- Login/reload/instance change - ensure viewers shown, rebuild after CDM populates
            EnsureViewersShown()
            C_Timer.After(1, function()
                BuildViewerAuraMap()
                ShreddedV("PLAYER_ENTERING_WORLD - viewer map rebuilt")
            end)
            isDirty = true
            
        elseif event == "SPELL_UPDATE_COOLDOWN" then
            isDirty = true
            
        elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
            -- Just log for debugging - CDM handles the actual aura tracking
            local glowSpellId = ...
            ShreddedV("Proc GLOW_SHOW: " .. tostring(glowSpellId))
            if glowSpellId and type(glowSpellId) == "number" then
                local spellName = C_Spell.GetSpellName(glowSpellId)
                LogProc(spellName or ("Unknown_" .. glowSpellId), glowSpellId, true)
            end
            isDirty = true
            
        elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
            ShreddedV("Proc GLOW_HIDE: " .. tostring(...))
            isDirty = true
            
        elseif event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
            -- A CDM viewer child's spell was overridden (e.g. Eclipse transform)
            -- Do an incremental map update like CooldownCompanion does
            local baseSpellID, overrideSpellID = ...
            if baseSpellID then
                local child = Shredded_viewerAuraFrames[baseSpellID]
                if child and overrideSpellID then
                    Shredded_viewerAuraFrames[overrideSpellID] = child
                end
            end
            isDirty = true
        end
    end)
    
    -- Register for CDM layout changes to rebuild viewer map
    pcall(function()
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            C_Timer.After(0.2, function()
                BuildViewerAuraMap()
                ShreddedV("CDM layout changed - viewer map rebuilt")
            end)
        end, "Shredded_CDM_Watcher")
    end)
end

-- ===========================================
-- DRUID CHECK
-- ===========================================

local function CheckIfDruid()
    local _, class = UnitClass("player")
    if class ~= "DRUID" then
        -- Cancel tickers for non-druids
        if mainTicker then mainTicker:Cancel() mainTicker = nil end
        if pollTicker then pollTicker:Cancel() pollTicker = nil end
        return false
    end
    return true
end

-- ===========================================
-- VERSION CHECK
-- ===========================================

function CheckVersion()
    if not ShreddedSettings["version"] or ShreddedSettings["version"] < 30000 then
        ShreddedDefaultSettings()
    end
    
    -- Ensure critical settings exist (safety check for corrupted settings)
    if not ShreddedSettings["baron"] then ShreddedSettings["baron"] = {} end
    if not ShreddedSettings["barorder"] then ShreddedSettings["barorder"] = {} end
    
    -- Ensure ENERGY and COMBO are always enabled
    if ShreddedSettings["baron"]["ENERGY"] == nil then ShreddedSettings["baron"]["ENERGY"] = true end
    if ShreddedSettings["baron"]["COMBO"] == nil then ShreddedSettings["baron"]["COMBO"] = true end
    
    -- Enable new spells that were added after initial release
    local newSpells = {"DREADFUL_WOUND", "INFECTED_WOUNDS", "FERAL_FRENZY", "FRANTIC_FRENZY"}
    for _, key in ipairs(newSpells) do
        if ShreddedSettings["baron"][key] == nil then 
            ShreddedSettings["baron"][key] = true 
        end
    end
    
    -- Ensure they have barorder entries
    local hasEnergy, hasCombo = false, false
    for frame, spell in pairs(ShreddedSettings["barorder"]) do
        if spell == "ENERGY" then hasEnergy = true end
        if spell == "COMBO" then hasCombo = true end
    end
    if not hasEnergy then ShreddedSettings["barorder"]["ShreddedBar14"] = "ENERGY" end
    if not hasCombo then ShreddedSettings["barorder"]["ShreddedBar15"] = "COMBO" end
end

-- ===========================================
-- BAR AUTO-ORDERING
-- ===========================================

local BAOVal = {}
local BAOUsed = {}

-- Reusable tables for BarAutoOrder (avoid garbage collection)
local BAOSortedSpells = {}

local function BarAutoOrder()
    if ShreddedSettings["barlock"] then
        -- Only export if not already done
        return
    end
    
    local BAOUseds = 0
    wipe(BAOUsed)
    wipe(BAOVal)
    
    -- Special handling for Energy and Combo
    if ShreddedSettings["baron"]["ENERGY"] then fTimes["ENERGY"] = 2000 end
    if ShreddedSettings["baron"]["COMBO"] then fTimes["COMBO"] = 2000 end
    
    for frame, spell in pairs(barOrder) do
        if ShreddedSettings["baron"][spell] then
            BAOUsed[spell] = frame
            BAOUseds = BAOUseds + 1
        end
    end
    
    -- Reuse sorted table instead of creating new one
    wipe(BAOSortedSpells)
    for spell, frame in pairs(BAOUsed) do
        local spellTime = fTimes[spell] or 0
        BAOSortedSpells[#BAOSortedSpells + 1] = {spell = spell, time = spellTime}
    end
    table.sort(BAOSortedSpells, function(a, b) return a.time > b.time end)
    
    -- Assign bars 1 through N
    wipe(BAOVal)
    for i, data in ipairs(BAOSortedSpells) do
        BAOVal["ShreddedBar" .. i] = data.spell
    end
    
    wipe(barOrder)
    for frame, spell in pairs(BAOVal) do
        barOrder[frame] = spell
    end
end

-- ===========================================
-- FRAME UPDATE
-- ===========================================
-- UI FUNCTIONS (must be before OnUpdate)
-- ===========================================

local function HideCooldowns()
    local restAlpha = ShreddedSettings["cooldownrestalpha"] or 0
    for name, frame in pairs(ShreddedCooldownList) do
        if frame then 
            frame:SetAlpha(restAlpha)
            local textureFrame = frame.texture or _G[frame:GetName() .. "Texture"]
            if textureFrame then textureFrame:SetVertexColor(1, 1, 1, restAlpha) end
        end
    end
end

-- ===========================================
-- MAIN UPDATE LOOP (using C_Timer.NewTicker for efficiency)
-- ===========================================

-- Track last known cat form state
local wasInCatForm = false
-- addonInitialized and barMove are declared at file top

-- Main update function - called by ticker, not OnUpdate
local function DoMainUpdate()
    -- Don't run until addon is fully initialized
    if not addonInitialized then return end
    if not CheckIfDruid() then return end
    
    local now = GetTime()
    
    -- Note: No throttle check needed - ticker handles timing
    
    -- Get form - handle potential secret value in combat
    local form = GetShapeshiftForm()
    local isCatForm = false
    
    -- Try direct comparison first (fast path)
    local formOk, formResult = pcall(function() return form == 2 end)
    if formOk and formResult then
        isCatForm = true
    elseif not isCatForm then
        -- Try string.format extraction as backup (slower)
        local numOk, formNum = pcall(function()
            return tonumber(string.format("%d", form))
        end)
        if numOk and formNum == 2 then
            isCatForm = true
        end
    end
    
    -- If in combat and can't determine form, use last known state
    if not isCatForm and InCombatLockdown() and wasInCatForm then
        isCatForm = true
    end
    
    -- Update last known state
    wasInCatForm = isCatForm
    
    if not isCatForm then
        Shredded_HideBars()
        HideCooldowns()
        isDirty = false
        return
    end
    
    -- Only refresh auras at AURA_REFRESH_INTERVAL (slower than UI updates)
    if isDirty or (now - lastAuraRefresh) >= AURA_REFRESH_INTERVAL then
        RefreshAllAuras()
        lastAuraRefresh = now
    end
    
    -- These are fast operations, do them every update
    UpdateEnergy()
    UpdateComboPoints()
    Timerize()
    
    -- Only re-sort bars if not locked (expensive operation)
    if not ShreddedSettings["barlock"] then
        BarAutoOrder()
    end
    
    FrameUpdate()
    
    lastFullUpdate = now
    isDirty = false
    
    -- Handle frame movement timer
    if barMove + 10 > now then
        if ShreddedMoveBarText then ShreddedMoveBarText:SetText("Move the bars! " .. floor(barMove + 10 - now)) end
        if ShreddedMoveCooldownText then ShreddedMoveCooldownText:SetText("Move the cooldowns! " .. floor(barMove + 10 - now)) end
    elseif barMove > 0 and ShreddedMoveCooldown and ShreddedMoveBar and not MouseIsOver(ShreddedMoveCooldown) and not MouseIsOver(ShreddedMoveBar) then
        if ShreddedMoveBarText then ShreddedMoveBarText:SetText("") end
        if ShreddedMoveCooldownText then ShreddedMoveCooldownText:SetText("") end
        ShreddedMoveBar:Hide()
        ShreddedMoveCooldown:Hide()
        ShreddedMoveBar:EnableMouse(false)
        ShreddedMoveCooldown:EnableMouse(false)
        if ShreddedBar1 and ShreddedBar1:GetLeft() then ShreddedSettings["barloc"] = {ShreddedBar1:GetLeft(), ShreddedBar1:GetTop()} end
        if ShreddedCooldown1 and ShreddedCooldown1:GetLeft() then ShreddedSettings["cooldownloc"] = {ShreddedCooldown1:GetLeft(), ShreddedCooldown1:GetTop()} end
        barMove = 0
    end
end

-- Start main update ticker (replaces OnUpdate for ~0% idle CPU usage)
local function StartMainTicker()
    if mainTicker then
        mainTicker:Cancel()
        mainTicker = nil
    end
    mainTicker = C_Timer.NewTicker(UPDATE_INTERVAL, DoMainUpdate)
    print("|cFF00FF00Shredded:|r Main ticker started (100ms interval)")
end

-- Start the ticker immediately (will wait for addonInitialized flag)
StartMainTicker()

-- ===========================================
-- UI FUNCTIONS
-- ===========================================

local function ShowCooldowns()
    for spell, frameNum in pairs(ShreddedSettings["cooldownorder"]) do
        if frameNum ~= "no" then
            local frame = ShreddedCooldownList["ShreddedCooldown" .. frameNum]
            if frame then
                frame:SetAlpha(ShreddedSettings["cooldownalpha"])
            end
        end
    end
end

function Shredded_HideBars()
    for name, frame in pairs(ShreddedBarList) do
        frame:Hide()
        if ShreddedBarIconList[name] then ShreddedBarIconList[name]:Hide() end
        if ShreddedBarBarList[name] then ShreddedBarBarList[name]:Hide() end
    end
end

function Shredded_ShowBars()
    for name, spell in pairs(barOrder) do
        if ShreddedSettings["baron"][spell] then
            ShreddedBarList[name]:Show()
            if ShreddedBarIconList[name] then ShreddedBarIconList[name]:Show() end
            if ShreddedBarBarList[name] then ShreddedBarBarList[name]:Show() end
        end
    end
end

-- ===========================================
-- LAYOUT FUNCTIONS
-- ===========================================

function BarLayout()
    local iter = 0
    local maxBars = math.max(20, #ShreddedCatSpells)
    for i = 1, maxBars do
        local barName = "ShreddedBar" .. i
        if ShreddedBarList[barName] then
            iter = iter + 1
            local bgFrame = _G[barName .. "Bar_Background"]
            if bgFrame and bgFrame.SetColorTexture then
                bgFrame:SetColorTexture(0, 0, 0, ShreddedSettings["barbackalpha"])
            end
            
            _G[barName]:ClearAllPoints()
            if iter == 1 then
                _G[barName]:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["barloc"][1], ShreddedSettings["barloc"][2])
            else
                if ShreddedSettings["bargrowth"] == "up" then
                    _G[barName]:SetPoint("BOTTOM", _G["ShreddedBar" .. (iter - 1)], "TOP", 0, 1)
                else
                    _G[barName]:SetPoint("TOP", _G["ShreddedBar" .. (iter - 1)], "BOTTOM", 0, -1)
                end
            end
            
            local bar = _G[barName .. "Bar"]
            if bar then
                bar:SetMinMaxValues(0, 30)
            end
        end
    end
end

function CooldownLayout()
    local numCooldowns = #ShreddedCooldownSpells
    local maxFrames = math.max(20, numCooldowns)
    
    -- First, hide ALL cooldown frames and clear points
    for i = 1, maxFrames do
        local cdFrame = _G["ShreddedCooldown" .. i]
        if cdFrame then
            cdFrame:ClearAllPoints()
            cdFrame:Hide()
        end
    end
    
    if not _G["ShreddedCooldown1"] then return end
    
    -- Get grid width (columns per row)
    local gridWidth = ShreddedSettings["cooldownlayout"]["width"] or 4
    if gridWidth < 1 then gridWidth = 1 end
    if gridWidth > 12 then gridWidth = 12 end
    
    -- Build list of enabled cooldowns in priority order
    local enabledFrames = {}
    for spell, frameNum in pairs(Shredded_CooldownFrameMap) do
        table.insert(enabledFrames, frameNum)
    end
    table.sort(enabledFrames)  -- Sort by frame number (which is already in priority order)
    
    -- Layout ONLY enabled frames in a grid
    local visibleIndex = 0
    for _, frameNum in ipairs(enabledFrames) do
        local cdFrame = _G["ShreddedCooldown" .. frameNum]
        if cdFrame then
            visibleIndex = visibleIndex + 1
            cdFrame:Show()
            
            if visibleIndex == 1 then
                -- First visible icon anchors to saved position
                cdFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["cooldownloc"][1], ShreddedSettings["cooldownloc"][2])
            else
                local col = (visibleIndex - 1) % gridWidth  -- 0-based column index
                
                if col == 0 then
                    -- First icon of a new row - anchor below the first icon of previous row
                    local prevRowFirst = enabledFrames[visibleIndex - gridWidth]
                    if prevRowFirst then
                        local aboveFrame = _G["ShreddedCooldown" .. prevRowFirst]
                        if aboveFrame then
                            cdFrame:SetPoint("TOPLEFT", aboveFrame, "BOTTOMLEFT")
                        end
                    end
                else
                    -- Continue on same row - anchor to the previous visible frame
                    local prevFrame = _G["ShreddedCooldown" .. enabledFrames[visibleIndex - 1]]
                    if prevFrame then
                        cdFrame:SetPoint("LEFT", prevFrame, "RIGHT")
                    end
                end
            end
        end
    end
end

-- ===========================================
-- BAR PERSONALITY
-- ===========================================

-- Dynamic mapping of spell -> frame (rebuilt when settings change)
Shredded_CooldownFrameMap = {}  -- spell -> frameNum (1-12)
Shredded_FrameSpellMap = {}     -- frameNum -> spell

-- Rebuild the cooldown frame assignment based on enabled spells and priority
local function RebuildCooldownFrameMap()
    wipe(Shredded_CooldownFrameMap)
    wipe(Shredded_FrameSpellMap)
    
    -- Build list of enabled spells that the player actually HAS
    local enabledSpells = {}
    for _, key in ipairs(ShreddedCooldownSpells) do
        -- Must be enabled in settings AND player must have the spell
        local isEnabled = ShreddedSettings["cooldownon"][key] ~= false
        local hasSpell = Shredded_PlayerHasSpell(key)
        
        if isEnabled and hasSpell then
            local priority = ShreddedSettings["cooldownpriority"] and ShreddedSettings["cooldownpriority"][key] or 99
            table.insert(enabledSpells, { key = key, priority = priority })
        end
    end
    
    -- Sort by priority (lower = first)
    table.sort(enabledSpells, function(a, b) return a.priority < b.priority end)
    
    -- Assign frames to enabled spells in priority order (dynamic count)
    local maxFrames = #ShreddedCooldownSpells
    for i, data in ipairs(enabledSpells) do
        if i <= maxFrames then
            Shredded_CooldownFrameMap[data.key] = i
            Shredded_FrameSpellMap[i] = data.key
        end
    end
end

function Shredded_CooldownPersonality()
    -- Rebuild frame assignments
    RebuildCooldownFrameMap()
    
    -- Clear all cooldown frame textures first (dynamic count)
    local numCooldowns = #ShreddedCooldownSpells
    local maxFrames = math.max(20, numCooldowns)
    for i = 1, maxFrames do
        local frameName = "ShreddedCooldown" .. i
        if ShreddedCooldownTextureList[frameName] then
            ShreddedCooldownTextureList[frameName]:SetTexture(nil)
        end
    end
    
    -- Set textures for assigned spells
    for spell, frameNum in pairs(Shredded_CooldownFrameMap) do
        local frameName = "ShreddedCooldown" .. frameNum
        if ShreddedCooldownTextureList[frameName] then
            local iconPath = SPELL_ICONS[spell]
            if iconPath then
                if type(iconPath) == "number" then
                    ShreddedCooldownTextureList[frameName]:SetTexture(iconPath)
                else
                    ShreddedCooldownTextureList[frameName]:SetTexture("Interface/" .. iconPath)
                end
            end
        end
    end
    
    -- Update layout for any enable/disable changes
    CooldownLayout()
    
    FullFrameUpdate()
end

function Shredded_BarPersonality()
    local form = GetShapeshiftForm()
    
    -- Handle secret values in combat
    local isCatForm = false
    pcall(function()
        if form == 2 then
            isCatForm = true
        end
    end)
    if not isCatForm then
        pcall(function()
            local formNum = tonumber(string.format("%d", form))
            if formNum and formNum == 2 then
                isCatForm = true
            end
        end)
    end
    
    -- Test mode bypasses cat form check
    local isTestMode = Shredded_TestMode == true
    if not isCatForm and not isTestMode then return end -- Only in cat form (or test mode)
    
    for frame, spell in pairs(barOrder) do
        -- Set icon texture
        if ShreddedBarIconTextureList[frame] and SPELL_ICONS[spell] then
            local iconPath = SPELL_ICONS[spell]
            if type(iconPath) == "number" then
                ShreddedBarIconTextureList[frame]:SetTexture(iconPath)
            else
                ShreddedBarIconTextureList[frame]:SetTexture("Interface/" .. iconPath)
            end
        end
        
        local spellName = SPELL_NAMES[spell] or spell
        if ShreddedBarTextList[frame] then
            ShreddedBarTextList[frame]:SetText(spellName)
        end
        
        if ShreddedBarBarList[frame] and ShreddedSettings["barcolor"][spell] then
            local c = ShreddedSettings["barcolor"][spell]
            ShreddedBarBarList[frame]:SetStatusBarColor(c[1], c[2], c[3], ShreddedSettings["baralpha"])
            ShreddedBarBarList[frame]:SetMinMaxValues(0, durations[spell] or 30)
        end
    end
end

-- ===========================================
-- FRAME UPDATE LOOP
-- ===========================================

-- Test mode flag - bypasses cat form check for /shredded test
Shredded_TestMode = false

-- Global alias for test access
function Shredded_FullFrameUpdate()
    FullFrameUpdate()
end

function FullFrameUpdate()
    Shredded_BarPersonality()
    
    local form = GetShapeshiftForm()
    
    -- During move mode, show everything regardless of form
    local isMoving = barMove > 0
    
    -- Test mode bypasses cat form check
    local isTestMode = Shredded_TestMode == true
    
    -- Check if in cat form (handle secret values in combat)
    local isCatForm = false
    pcall(function()
        if form == 2 then
            isCatForm = true
        end
    end)
    -- Try string extraction as backup
    if not isCatForm then
        pcall(function()
            local formNum = tonumber(string.format("%d", form))
            if formNum and formNum == 2 then
                isCatForm = true
            end
        end)
    end
    
    if not isCatForm and not isMoving and not isTestMode then
        Shredded_HideBars()
        HideCooldowns()
        return
    end
    
    -- Check if we should hide bars out of combat
    local inCombat = InCombatLockdown()
    local hideBarsDueToCombat = ShreddedSettings["barcombat"] and not inCombat and not isMoving
    
    local time = GetTime()
    
    -- Update cooldown icons
    if ShreddedSettings["cooldownson"] then
        -- During move mode, show all enabled cooldowns
        if isMoving then
            for spell, frameNum in pairs(Shredded_CooldownFrameMap) do
                local frameName = "ShreddedCooldown" .. frameNum
                local frame = ShreddedCooldownList[frameName]
                local textFrame = ShreddedCooldownTextList[frameName]
                local textureFrame = ShreddedCooldownTextureList[frameName]
                if frame then 
                    frame:SetAlpha(ShreddedSettings["cooldownalpha"]) 
                    if textFrame then textFrame:SetText("TEST") end
                    if textureFrame then textureFrame:SetVertexColor(1, 1, 1) end
                end
            end
        else
            -- Normal mode - reset all to 0 first
            local numCooldowns = #ShreddedCooldownSpells
            for i = 1, numCooldowns do
                local frame = ShreddedCooldownList["ShreddedCooldown" .. i]
                if frame then frame:SetAlpha(0) end
            end
        
            for spell, frameNum in pairs(Shredded_CooldownFrameMap) do
                local frameName = "ShreddedCooldown" .. frameNum
                local frame = ShreddedCooldownList[frameName]
                local textFrame = ShreddedCooldownTextList[frameName]
                local textureFrame = ShreddedCooldownTextureList[frameName]
                
                if frame and textFrame then
                    -- Check if this is a proc or cooldown (use isProc/isCooldown flag from spell metadata)
                    local spellMeta = Shredded_SpellMeta[spell]
                    local isProc = spellMeta and spellMeta.isProc
                    local isCooldown = spellMeta and spellMeta.isCooldown
                    local spellId = spellMeta and spellMeta.id
                    
                    -- PRIORITY 1: CDM Viewer (works in combat - spellID is always readable!)
                    -- PRIORITY 2: GetPlayerAuraBySpellID (fallback for out-of-combat)
                    -- PRIORITY 3: Check overlay (spell glow)
                    local auraData = nil
                    local auraInstanceID = nil
                    local isAuraActive = false
                    local remaining = 0
                    
                    -- PRIORITY 1: CDM Viewer lookup (like CooldownCompanion)
                    if spellId then
                        local viewerFrame = Shredded_viewerAuraFrames[spellId]
                        -- Also check altIds in viewer map
                        if not viewerFrame and spellMeta and spellMeta.altIds then
                            for _, altId in ipairs(spellMeta.altIds) do
                                viewerFrame = Shredded_viewerAuraFrames[altId]
                                if viewerFrame then break end
                            end
                        end
                        
                        if viewerFrame then
                            -- auraInstanceID is nil when inactive, non-nil when active
                            local instId = viewerFrame.auraInstanceID
                            
                            -- Detailed combat log for CLEARCASTING only (first few ticks)
                            if spell == "CLEARCASTING" and Shredded_CombatLogEnabled then
                                Shredded_ccLogCount = (Shredded_ccLogCount or 0) + 1
                                if Shredded_ccLogCount <= 10 or (instId and Shredded_ccLogCount % 20 == 0) then
                                    local parentName = viewerFrame:GetParent() and viewerFrame:GetParent():GetName() or "?"
                                    local isVis = viewerFrame:IsVisible() and "vis" or "hid"
                                    local isActive = viewerFrame.isActive and "Y" or "N"
                                    print("|cFF88FFFF[CDM]|r CC tick#" .. Shredded_ccLogCount .. " instId=" .. tostring(instId) .. " active=" .. isActive .. " " .. isVis .. " parent=" .. parentName)
                                end
                            end
                            
                            if instId then
                                auraInstanceID = instId
                                isAuraActive = true
                                
                                -- Get remaining time (best-effort, not required for detection)
                                local dok, durationObj = pcall(C_UnitAuras.GetAuraDuration, "player", instId)
                                if dok and durationObj then
                                    local remainingSec, totalDurationSec = DecodeDurationObject(durationObj)
                                    if remainingSec and remainingSec > 0 then
                                        remaining = remainingSec
                                    end
                                end
                                -- If decode failed, try viewer's Cooldown widget for timing
                                if remaining <= 0 and viewerFrame.Cooldown then
                                    pcall(function()
                                        local startMs, durMs = viewerFrame.Cooldown:GetCooldownTimes()
                                        if durMs and durMs > 0 then
                                            local endMs = startMs + durMs
                                            local nowMs = GetTime() * 1000
                                            if endMs > nowMs then
                                                remaining = (endMs - nowMs) / 1000
                                            end
                                        end
                                    end)
                                end
                            end
                            -- NOTE: Do NOT use Cooldown widget as fallback detection.
                            -- Cooldown:GetCooldownTimes() retains stale data from previously-active
                            -- procs, causing false positives. Only auraInstanceID is reliable.
                        end
                    end
                    
                    -- PRIORITY 2: GetPlayerAuraBySpellID (fallback for out-of-combat or if CDM viewer not populated)
                    -- NOTE: Only check the primary buff ID here, NOT altIds.
                    -- altIds contain talent/ability IDs (e.g. 16864 Omen of Clarity) that are
                    -- passive auras ALWAYS on the player - checking them makes procs always show.
                    if not isAuraActive and spellId then
                        local ok
                        ok, auraData = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
                        if not ok then auraData = nil end
                        
                        -- If GetPlayerAuraBySpellID returned data, the aura IS active
                        -- (auraInstanceID may be secret from this API, so don't gate on it)
                        if auraData then
                            isAuraActive = true
                            
                            -- Try to extract auraInstanceID for timing (may be secret)
                            pcall(function()
                                auraInstanceID = auraData.auraInstanceID
                            end)
                            
                            -- Try to get remaining time - may be secret in combat
                            local mathOk = pcall(function()
                                remaining = auraData.expirationTime - GetTime()
                                if remaining < 0 then remaining = 0 end
                            end)
                            
                            -- If arithmetic failed, try widget decoder with auraInstanceID
                            if (not mathOk or remaining <= 0) and auraInstanceID then
                                local dok, durationObj = pcall(C_UnitAuras.GetAuraDuration, "player", auraInstanceID)
                                if dok and durationObj then
                                    local remainingSec, totalDurationSec = DecodeDurationObject(durationObj)
                                    if remainingSec and remainingSec > 0 then
                                        remaining = remainingSec
                                    end
                                end
                            end
                        end
                    end
                    
                    -- Also check overlay status for procs (backup detection method)
                    local isProcOverlayed = false
                    if isProc and spellId then
                        pcall(function()
                            isProcOverlayed = C_SpellActivationOverlay.IsSpellOverlayed(spellId)
                        end)
                        -- Also check altIds for overlay
                        if not isProcOverlayed and spellMeta.altIds then
                            for _, altId in ipairs(spellMeta.altIds) do
                                pcall(function()
                                    isProcOverlayed = C_SpellActivationOverlay.IsSpellOverlayed(altId)
                                end)
                                if isProcOverlayed then break end
                            end
                        end
                    end
                    
                    -- DEBUG: Log what's being detected (only when something is active)
                    if (isAuraActive or isProcOverlayed) and ShreddedSettings["debug"] then
                        ShreddedV(spell .. ": aura=" .. tostring(isAuraActive) .. " overlay=" .. tostring(isProcOverlayed) .. " frame=" .. frameNum)
                    end
                    
                    -- COMBAT LOG: Print state changes to chat for debugging
                    if isProc and Shredded_CombatLogEnabled then
                        local currentState = isAuraActive or isProcOverlayed
                        local prevState = Shredded_LastProcState[spell]
                        if currentState ~= prevState then
                            Shredded_LastProcState[spell] = currentState
                            if currentState then
                                -- Also show what texture is actually on the frame
                                local actualTexture = textureFrame and textureFrame:GetTexture() or "nil"
                                local expectedIcon = SPELL_ICONS[spell] or "nil"
                                print("|cFF00FF00[Shredded]|r PROC: " .. spell .. " (frame " .. frameNum .. ") aura=" .. tostring(isAuraActive) .. " icon=" .. tostring(expectedIcon) .. " actualTex=" .. tostring(actualTexture))
                            else
                                print("|cFFFF0000[Shredded]|r LOST: " .. spell)
                            end
                        end
                    end
                    
                    -- MAJOR COOLDOWNS (like INCARNATION, CONVOKE) - different behavior
                    -- Show when OFF cooldown (ready), show CD remaining when ON cooldown
                    if isCooldown and spellId then
                        local cdStart, cdDuration = 0, 0
                        pcall(function()
                            local cdInfo = C_Spell.GetSpellCooldown(spellId)
                            if cdInfo then
                                cdStart = cdInfo.startTime or 0
                                cdDuration = cdInfo.duration or 0
                            end
                        end)
                        
                        local cdRemaining = 0
                        if cdStart and cdDuration and cdDuration > 1.5 then  -- >1.5s to ignore GCD
                            cdRemaining = (cdStart + cdDuration) - GetTime()
                            if cdRemaining < 0 then cdRemaining = 0 end
                        end
                        
                        if cdRemaining > 0 then
                            -- ON COOLDOWN - show dimmed with remaining time
                            frame:SetAlpha(ShreddedSettings["cooldownalpha"] * 0.5)  -- Dimmed
                            if cdRemaining < 10 then
                                textFrame:SetText(string.format("%.1f", cdRemaining))
                            else
                                textFrame:SetText(math.floor(cdRemaining))
                            end
                            if textureFrame then textureFrame:SetVertexColor(0.5, 0.5, 0.5, ShreddedSettings["cooldownalpha"]) end
                        else
                            -- OFF COOLDOWN - show bright, ready to use!
                            frame:SetAlpha(ShreddedSettings["cooldownalpha"])
                            textFrame:SetText("!")
                            if textureFrame then textureFrame:SetVertexColor(1, 1, 1, ShreddedSettings["cooldownalpha"]) end
                        end
                    elseif isProc then
                        -- PROCS - show when buff is active (use it now!)
                        local showProcIcon = isProcOverlayed or isAuraActive
                        
                        if showProcIcon then
                            frame:SetAlpha(ShreddedSettings["cooldownalpha"])
                            -- Show remaining time from self-tracking (if available)
                            if remaining > 0 and remaining < 10 then
                                textFrame:SetText(string.format("%.1f", remaining))
                            elseif remaining >= 10 then
                                textFrame:SetText(math.floor(remaining))
                            else
                                -- No valid remaining time - just show "!" to indicate active proc
                                textFrame:SetText("!")
                            end
                            if textureFrame then textureFrame:SetVertexColor(1, 1, 1, ShreddedSettings["cooldownalpha"]) end
                        else
                            -- Use rest opacity for inactive procs
                            local restAlpha = ShreddedSettings["cooldownrestalpha"] or 0
                            frame:SetAlpha(restAlpha)
                            textFrame:SetText("")
                            if textureFrame then textureFrame:SetVertexColor(1, 1, 1, restAlpha) end
                        end
                    else
                        -- Fallback for anything else marked as proc/cooldown
                        local showProcIcon = isProcOverlayed or isAuraActive
                        
                        if showProcIcon then
                            frame:SetAlpha(ShreddedSettings["cooldownalpha"])
                            if remaining > 0 and remaining < 10 then
                                textFrame:SetText(string.format("%.1f", remaining))
                            elseif remaining >= 10 then
                                textFrame:SetText(math.floor(remaining))
                            else
                                textFrame:SetText("!")
                            end
                            if textureFrame then textureFrame:SetVertexColor(1, 1, 1, ShreddedSettings["cooldownalpha"]) end
                        else
                            -- Use rest opacity for inactive procs
                            local restAlpha = ShreddedSettings["cooldownrestalpha"] or 0
                            frame:SetAlpha(restAlpha)
                            textFrame:SetText("")
                            if textureFrame then textureFrame:SetVertexColor(1, 1, 1, restAlpha) end
                        end
                    end
                    
                    -- Only hide out of combat if that setting is explicitly enabled
                    if not InCombatLockdown() and ShreddedSettings["cooldowncombat"] == true and barMove == 0 then
                        local restAlpha = ShreddedSettings["cooldownrestalpha"] or 0
                        frame:SetAlpha(restAlpha)
                        if textureFrame then textureFrame:SetVertexColor(1, 1, 1, restAlpha) end
                    end
                end
            end
        end  -- end else (not moving)
    else
        HideCooldowns()
    end
    
    -- Update bars
    if ShreddedSettings["catbarson"] then
        -- First hide ALL bars - only those in barOrder will be shown
        local maxBars = math.max(20, #ShreddedCatSpells)
        for i = 1, maxBars do
            local frameName = "ShreddedBar" .. i
            if ShreddedBarList[frameName] then ShreddedBarList[frameName]:Hide() end
            if ShreddedBarIconList[frameName] then ShreddedBarIconList[frameName]:Hide() end
            if ShreddedBarBarList[frameName] then ShreddedBarBarList[frameName]:Hide() end
        end
        
        for frame, spell in pairs(barOrder) do
            if ShreddedSettings["baron"][spell] then
                local bar = ShreddedBarBarList[frame]
                local secs = ShreddedBarSecsList[frame]
                local text = ShreddedBarTextList[frame]
                local icon = ShreddedBarIconList[frame]
                local mainFrame = ShreddedBarList[frame]
                
                if bar then
                    if spell == "ENERGY" then
                        -- Energy: StatusBar accepts secret values natively in Midnight
                        local rawEnergy = UnitPower("player", 3)
                        local rawMaxEnergy = UnitPowerMax("player", 3)
                        
                        -- SetMinMaxValues needs real numbers, use cached or default
                        local maxVal = Shredded_cachedMaxEnergy or 100
                        if maxVal < 1 then maxVal = 100 end
                        
                        bar:SetMinMaxValues(0, maxVal)
                        -- SetValue accepts secret values directly (C-side handles them)
                        bar:SetValue(rawEnergy)
                        -- SetFormattedText also accepts secret values (like print() does)
                        if secs then 
                            -- Use pcall in case of edge cases
                            pcall(function()
                                secs:SetFormattedText("%d", rawEnergy)
                            end)
                        end
                    elseif spell == "COMBO" then
                        -- Combo points: StatusBar accepts secret values
                        local combo = UnitPower("player", 4)
                        local maxCombo = UnitPowerMax("player", 4)
                        
                        -- Use cached max or default
                        local maxComboVal = Shredded_cachedMaxCombo or 5
                        if maxComboVal < 1 then maxComboVal = 5 end
                        
                        bar:SetMinMaxValues(0, maxComboVal)
                        bar:SetValue(combo)
                        if secs then
                            pcall(function()
                                secs:SetFormattedText("%d", combo)
                            end)
                        end
                    else
                        -- Buff/debuff display
                        local rawData = auraRawData[spell]
                        
                        if rawData and rawData.expirationTime then
                            -- Use the actual duration from rawData, fall back to static durations table
                            local dur = SafeNumber(rawData.duration, 0)
                            if dur <= 0 then dur = SafeNumber(durations[spell], 30) end
                            bar:SetMinMaxValues(0, dur)
                            
                            -- Calculate remaining - our stored expirationTime is a real number
                            local remaining = rawData.expirationTime - GetTime()
                            
                            if remaining > 0 then
                                bar:SetValue(remaining)
                                if secs then 
                                    secs:Show()
                                    if remaining < 10 then
                                        secs:SetText(string.format("%.1f", remaining))
                                    else
                                        secs:SetText(math.floor(remaining))
                                    end
                                end
                            else
                                -- Aura expired
                                bar:SetValue(0)
                                if secs then 
                                    secs:Show()
                                    secs:SetText("0")
                                end
                            end
                        else
                            -- No aura active
                            local dur = SafeNumber(durations[spell], 30)
                            bar:SetMinMaxValues(0, dur)
                            bar:SetValue(0)
                            
                            -- Reset color to normal
                            local c = ShreddedSettings["barcolor"][spell] or {0.5, 0.5, 0.5}
                            if bar.SetStatusBarColor then
                                bar:SetStatusBarColor(c[1], c[2], c[3], ShreddedSettings["baralpha"] or 0.9)
                            end
                            
                            if secs then 
                                secs:Show()
                                secs:SetText("0") 
                            end
                        end
                    end
                    
                    -- Show/hide logic
                    local shouldShow = true
                    local isAuraActive = (auraRawData[spell] ~= nil) or (spell == "ENERGY") or (spell == "COMBO")
                    
                    -- Hide bars out of combat if setting enabled
                    if hideBarsDueToCombat then
                        shouldShow = false
                    -- Energy and Combo always show in cat form (if not hidden by combat)
                    elseif spell == "ENERGY" or spell == "COMBO" then
                        shouldShow = true
                    elseif not isAuraActive then
                        -- No aura = don't show unless barzero is enabled
                        -- When barlock (static order) is on, barzero is forced on
                        local showZero = ShreddedSettings["barzero"] or ShreddedSettings["barlock"]
                        if not showZero then
                            shouldShow = false
                        end
                    end
                    
                    -- Always show during move mode
                    if barMove > 0 then
                        shouldShow = true
                    end
                    
                    if shouldShow then
                        if mainFrame then mainFrame:Show() end
                        if icon then icon:Show() end
                        bar:Show()
                    else
                        if mainFrame then mainFrame:Hide() end
                        if icon then icon:Hide() end
                        bar:Hide()
                    end
                end
            end
        end
    else
        Shredded_HideBars()
    end
    
    -- Update state tracking
    for name, frame in pairs(ShreddedBarList) do
        ShreddedBarState[name] = frame:IsShown() and 1 or 0
    end
    
    for name, frame in pairs(ShreddedCooldownList) do
        if frame:GetAlpha() == 0 then
            ShreddedCooldownState[name] = 0
        else
            ShreddedCooldownState[name] = 1
        end
    end
end

function FrameUpdate()
    FullFrameUpdate()
end

-- ===========================================
-- FRAME LOADING
-- ===========================================

function Shredded_LoadFrames()
    -- Dynamic frame count based on spell lists
    local maxCooldowns = math.max(20, #ShreddedCooldownSpells)  -- At least 20 for future expansion
    local maxBars = math.max(20, #ShreddedCatSpells)            -- At least 20 for future expansion
    local maxFrames = math.max(maxCooldowns, maxBars)
    
    for i = 1, maxFrames do
        local cd = CreateFrame("Frame", "ShreddedCooldown" .. i, UIParent, "ShreddedCooldownTemplate")
        local bar = CreateFrame("Frame", "ShreddedBar" .. i, UIParent, "ShreddedBarTemplate")
        
        ShreddedCooldownList["ShreddedCooldown" .. i] = _G["ShreddedCooldown" .. i]
        ShreddedCooldownTextList["ShreddedCooldown" .. i] = _G["ShreddedCooldown" .. i .. "Text"]
        ShreddedCooldownTextureList["ShreddedCooldown" .. i] = _G["ShreddedCooldown" .. i .. "Texture"]
        ShreddedBarList["ShreddedBar" .. i] = _G["ShreddedBar" .. i]
        ShreddedBarTextList["ShreddedBar" .. i] = _G["ShreddedBar" .. i .. "BarText"]
        ShreddedBarSecsList["ShreddedBar" .. i] = _G["ShreddedBar" .. i .. "BarSecs"]
        ShreddedBarIconList["ShreddedBar" .. i] = _G["ShreddedBar" .. i .. "Icon"]
        ShreddedBarIconTextureList["ShreddedBar" .. i] = _G["ShreddedBar" .. i .. "IconTexture"]
        ShreddedBarBarList["ShreddedBar" .. i] = _G["ShreddedBar" .. i .. "Bar"]
        
        -- Hide and destroy any existing cooldown frames from previous sessions
        local existingCd = _G["ShreddedBar" .. i .. "Cooldown"]
        if existingCd then
            existingCd:Hide()
            existingCd:SetParent(nil)
            existingCd:ClearAllPoints()
        end
        ShreddedBarCooldownList["ShreddedBar" .. i] = nil -- No cooldown frames
    end
    
    -- Create move frames (parent to UIParent so they don't inherit alpha)
    local moveCd = CreateFrame("Frame", "ShreddedMoveCooldown", UIParent, "ShreddedMoveTemplate")
    local moveBar = CreateFrame("Frame", "ShreddedMoveBar", UIParent, "ShreddedMoveTemplate")
    
    moveCd:SetFrameStrata("DIALOG")
    moveBar:SetFrameStrata("DIALOG")
    
    -- Ensure settings exist with defaults (handle migration from old saved vars)
    ShreddedSettings["cooldownloc"] = ShreddedSettings["cooldownloc"] or ShreddedSettings["warningloc"] or {500, 500}
    ShreddedSettings["barloc"] = ShreddedSettings["barloc"] or {500, 400}
    ShreddedSettings["cooldownsize"] = ShreddedSettings["cooldownsize"] or ShreddedSettings["warningsize"] or 40
    ShreddedSettings["cooldownfont"] = ShreddedSettings["cooldownfont"] or ShreddedSettings["warningfont"] or 24
    ShreddedSettings["cooldownalpha"] = ShreddedSettings["cooldownalpha"] or ShreddedSettings["warningalpha"] or 0.85
    ShreddedSettings["cooldownlayout"] = ShreddedSettings["cooldownlayout"] or ShreddedSettings["warninglayout"] or {width = 4, height = 3}
    -- Migrate old direction/size format to width/height
    if ShreddedSettings["cooldownlayout"]["direction"] and not ShreddedSettings["cooldownlayout"]["width"] then
        local oldSize = ShreddedSettings["cooldownlayout"]["size"] or 4
        if ShreddedSettings["cooldownlayout"]["direction"] == "r" then
            -- Old "rows" meant icons stacked vertically, then wrap right
            ShreddedSettings["cooldownlayout"]["width"] = 3
            ShreddedSettings["cooldownlayout"]["height"] = oldSize
        else
            -- Old "columns" meant icons go right, then wrap down
            ShreddedSettings["cooldownlayout"]["width"] = oldSize
            ShreddedSettings["cooldownlayout"]["height"] = 3
        end
    end
    ShreddedSettings["cooldownlayout"]["width"] = ShreddedSettings["cooldownlayout"]["width"] or 4
    ShreddedSettings["cooldownlayout"]["height"] = ShreddedSettings["cooldownlayout"]["height"] or 3
    -- Migrate from old "catwarningson" to "cooldownson" (only if cooldownson hasn't been set yet)
    if ShreddedSettings["cooldownson"] == nil then
        if ShreddedSettings["catwarningson"] ~= nil then
            ShreddedSettings["cooldownson"] = ShreddedSettings["catwarningson"]
        else
            ShreddedSettings["cooldownson"] = true
        end
    end
    ShreddedSettings["cooldowntime"] = ShreddedSettings["cooldowntime"] or ShreddedSettings["warntime"] or {}
    ShreddedSettings["cooldownon"] = ShreddedSettings["cooldownon"] or {}  -- Individual ability toggles
    
    -- ALWAYS ensure all cooldown spells have entries (handle addon updates adding new spells)
    for idx, key in ipairs(ShreddedCooldownSpells) do
        if ShreddedSettings["cooldownon"][key] == nil then
            ShreddedSettings["cooldownon"][key] = true  -- Default new spells to enabled
        end
    end
    
    -- Initialize/migrate cooldownpriority (new system)
    if not ShreddedSettings["cooldownpriority"] then
        ShreddedSettings["cooldownpriority"] = {}
        -- Migrate from old cooldownorder if present
        if ShreddedSettings["cooldownorder"] then
            for spell, oldFrame in pairs(ShreddedSettings["cooldownorder"]) do
                if type(oldFrame) == "number" then
                    ShreddedSettings["cooldownpriority"][spell] = oldFrame
                end
            end
        end
    end
    -- ALWAYS ensure all cooldown spells have priority entries (handle addon updates adding new spells)
    local maxExistingPriority = 0
    for _, pri in pairs(ShreddedSettings["cooldownpriority"]) do
        if type(pri) == "number" and pri > maxExistingPriority then
            maxExistingPriority = pri
        end
    end
    for idx, key in ipairs(ShreddedCooldownSpells) do
        if not ShreddedSettings["cooldownpriority"][key] then
            maxExistingPriority = maxExistingPriority + 1
            ShreddedSettings["cooldownpriority"][key] = maxExistingPriority
        end
    end
    
    moveCd:ClearAllPoints()
    moveCd:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["cooldownloc"][1], ShreddedSettings["cooldownloc"][2])
    moveBar:ClearAllPoints()
    moveBar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["barloc"][1], ShreddedSettings["barloc"][2])
    moveBar:Hide()
    moveCd:Hide()
    
    moveBar:SetScript("OnMouseDown", function(self) self:StartMoving() end)
    moveBar:SetScript("OnMouseUp", function(self) 
        self:StopMovingOrSizing()
        -- Calculate bar position based on growth direction
        if ShreddedSettings["bargrowth"] == "up" then
            -- Move box bottom is bar1 position
            ShreddedSettings["barloc"] = {self:GetLeft(), self:GetBottom() + ShreddedSettings["barheight"]}
        else
            ShreddedSettings["barloc"] = {self:GetLeft(), self:GetTop()}
        end
        ShreddedBar1:ClearAllPoints()
        ShreddedBar1:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["barloc"][1], ShreddedSettings["barloc"][2])
        BarLayout()
    end)
    moveCd:SetScript("OnMouseDown", function(self) self:StartMoving() end)
    moveCd:SetScript("OnMouseUp", function(self) 
        self:StopMovingOrSizing()
        ShreddedSettings["cooldownloc"] = {self:GetLeft(), self:GetTop()}
        ShreddedCooldown1:ClearAllPoints()
        ShreddedCooldown1:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["cooldownloc"][1], ShreddedSettings["cooldownloc"][2])
        CooldownLayout()
    end)
    
    CooldownLayout()
    BarLayout()
    Shredded_CooldownPersonality()
    Shredded_BarPersonality()
    
    ShreddedCooldown1:ClearAllPoints()
    ShreddedCooldown1:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["cooldownloc"][1], ShreddedSettings["cooldownloc"][2])
    ShreddedBar1:ClearAllPoints()
    ShreddedBar1:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["barloc"][1], ShreddedSettings["barloc"][2])
end

-- ===========================================
-- REFRESH FUNCTION
-- ===========================================

function Shredded_Refresh()
    -- Update cooldown frames
    local maxCooldowns = math.max(20, #ShreddedCooldownSpells)
    for i = 1, maxCooldowns do
        local cd = _G["ShreddedCooldown" .. i]
        if cd then
            cd:SetWidth(ShreddedSettings["cooldownsize"])
            cd:SetHeight(ShreddedSettings["cooldownsize"])
            local cdText = _G["ShreddedCooldown" .. i .. "Text"]
            if cdText then
                cdText:SetFont("Fonts\\FRIZQT__.TTF", ShreddedSettings["cooldownfont"], "OUTLINE")
            end
        end
    end
    
    exportBarOrder()
    BarAutoOrder()
    
    -- Update bar frames
    local maxBars = math.max(20, #ShreddedCatSpells)
    for i = 1, maxBars do
        local bar = _G["ShreddedBar" .. i]
        if bar then
            bar:SetWidth(ShreddedSettings["barwidth"])
            bar:SetHeight(ShreddedSettings["barheight"])
            
            local barBar = _G["ShreddedBar" .. i .. "Bar"]
            if barBar then
                barBar:SetWidth(ShreddedSettings["barwidth"] - ShreddedSettings["barheight"])
                barBar:SetHeight(ShreddedSettings["barheight"])
                barBar:SetStatusBarTexture(ShreddedSettings["bartexture"])
            end
            
            local barIcon = _G["ShreddedBar" .. i .. "Icon"]
            if barIcon then
                barIcon:SetWidth(ShreddedSettings["barheight"])
                barIcon:SetHeight(ShreddedSettings["barheight"])
            end
            
            local bg = _G["ShreddedBar" .. i .. "Bar_Background"]
            if bg and bg.SetColorTexture then
                bg:SetColorTexture(0, 0, 0, ShreddedSettings["barbackalpha"])
            end
            
            local barText = _G["ShreddedBar" .. i .. "BarText"]
            if barText then
                barText:SetFont("Fonts\\FRIZQT__.TTF", ShreddedSettings["barfont"], "OUTLINE")
                local fc = ShreddedSettings["barcolor"]["font"] or {1, 1, 1}
                barText:SetTextColor(fc[1], fc[2], fc[3])
            end
            
            local barSecs = _G["ShreddedBar" .. i .. "BarSecs"]
            if barSecs then
                barSecs:SetFont("Fonts\\FRIZQT__.TTF", ShreddedSettings["barfont"], "OUTLINE")
                local fc = ShreddedSettings["barcolor"]["font"] or {1, 1, 1}
                barSecs:SetTextColor(fc[1], fc[2], fc[3])
            end
        end
    end
    
    CooldownLayout()
    Shredded_CooldownPersonality()
    Shredded_BarPersonality()
end

-- ===========================================
-- MOVE FUNCTION
-- ===========================================

function Shredded_Move()
    if not ShreddedMoveBar or not ShreddedMoveCooldown then
        ShreddedO("Error: Move frames not loaded yet!")
        return
    end
    
    local barcount = 0
    for _, spell in pairs(barOrder) do
        if ShreddedSettings["baron"][spell] then
            barcount = barcount + 1
        end
    end
    
    ShreddedMoveBar:SetWidth(ShreddedSettings["barheight"] + ShreddedSettings["barwidth"])
    ShreddedMoveBar:SetHeight(ShreddedSettings["barheight"] * math.max(barcount, 3))
    ShreddedMoveCooldown:SetWidth(ShreddedSettings["cooldownsize"] * 4)
    ShreddedMoveCooldown:SetHeight(ShreddedSettings["cooldownsize"] * 3)
    
    -- Position at saved locations, accounting for bar growth direction
    ShreddedMoveBar:ClearAllPoints()
    if ShreddedSettings["bargrowth"] == "up" then
        -- Bars grow up, so the anchor is at the bottom
        ShreddedMoveBar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["barloc"][1], ShreddedSettings["barloc"][2] - ShreddedSettings["barheight"])
    else
        -- Bars grow down, anchor is at top
        ShreddedMoveBar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["barloc"][1], ShreddedSettings["barloc"][2])
    end
    
    ShreddedMoveCooldown:ClearAllPoints()
    ShreddedMoveCooldown:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ShreddedSettings["cooldownloc"][1], ShreddedSettings["cooldownloc"][2])
    
    barMove = GetTime()
    ShreddedMoveCooldown:Show()
    ShreddedMoveBar:Show()
    ShreddedMoveBar:EnableMouse(true)
    ShreddedMoveCooldown:EnableMouse(true)
    
    ShreddedO("Move mode enabled! Drag the blue boxes to reposition. They will auto-hide after 10 seconds.")
end

-- ===========================================
-- COOLDOWN THRESHOLD
-- ===========================================

function Shredded_CooldownThreshold(value)
    for spell, _ in pairs(timers) do
        ShreddedSettings["cooldowntime"][spell] = value or 5
    end
end

-- ===========================================
-- EXPOSE GLOBALS FOR OPTIONS
-- ===========================================

ShreddedColoredSpell = "RIP"
-- Expose barOrder for status command
function Shredded_GetBarOrder()
    return barOrder
end
