--[[
    Shredded Options - Feral Druid Combat Tracker
    Version 1.0.0 - Midnight Update
]]

local addonName, Shredded = ...

-- Helper to set text on checkboxes/radio buttons (handles different template versions)
local function SetButtonText(button, text)
    if button.Text then
        button.Text:SetText(text)
    elseif button.text then
        button.text:SetText(text)
    end
end

-- Shared spell name lookup (used by multiple panels)
local SPELL_DISPLAY_NAMES = {
    -- Resources
    ENERGY = "Energy",
    COMBO = "Combo Points",
    -- Core/Class Talents
    TIGERS_FURY = "Tiger's Fury",
    THRASH = "Thrash",
    RAKE = "Rake",
    RIP = "Rip",
    -- Feral Spec
    PREDATORY_SWIFTNESS = "Predatory Swiftness",
    CLEARCASTING = "Clearcasting",
    PRIMAL_WRATH = "Primal Wrath",
    SABERTOOTH = "Sabertooth",
    SUDDEN_AMBUSH = "Sudden Ambush",
    MOMENT_OF_CLARITY = "Moment of Clarity",
    BERSERK = "Berserk",
    WILD_SLASHES = "Wild Slashes",
    SOUL_OF_THE_FOREST = "Soul of the Forest",
    CARNIVOROUS_INSTINCT = "Carnivorous Instinct",
    FRANTIC_MOMENTUM = "Frantic Momentum",
    APEX_PREDATOR = "Apex Predator's Craving",
    FERAL_FRENZY = "Feral Frenzy",
    FRANTIC_FRENZY = "Frantic Frenzy",
    INCARNATION = "Incarnation: Ashamane",
    CONVOKE = "Convoke the Spirits",
    MOONFIRE_CAT = "Moonfire",
    BLOODTALONS = "Bloodtalons",
    CIRCLE_OF_LIFE = "Circle of Life and Death",
    -- Hero: Druid of the Claw
    RAVAGE = "Ravage!",
    KILLING_STRIKES = "Killing Strikes",
    SAVAGE_FURY = "Savage Fury",
    COILED_TO_SPRING = "Coiled to Spring",
    DREADFUL_WOUND = "Dreadful Wound",
    INFECTED_WOUNDS = "Infected Wounds",
    BESTIAL_STRENGTH = "Bestial Strength",
    WILDSHAPE_MASTERY = "Wildshape Mastery",
    EMPOWERED_SHAPESHIFTING = "Empowered Shapeshifting",
    CLAW_RAMPAGE = "Claw Rampage",
    -- Hero: Wildstalker
    THRIVING_GROWTH = "Thriving Growth",
    STRATEGIC_INFUSION = "Strategic Infusion",
    WILDSTALKER_POWER = "Wildstalker's Power",
    LETHAL_PRESERVATION = "Lethal Preservation",
    BURSTING_GROWTH = "Bursting Growth",
    BOND_WITH_NATURE = "Bond with Nature",
    RESILIENT_FLOURISHING = "Resilient Flourishing",
    ROOT_NETWORK = "Root Network",
    TWIN_SPROUTS = "Twin Sprouts",
    VIGOROUS_CREEPERS = "Vigorous Creepers",
    BERSERK_FRENZY = "Berserk: Frenzy",
    BRUTAL_SLASH = "Brutal Slash",
    THRASH_CAT = "Thrash",
}

-- Helper to get display name for a spell
local function GetSpellDisplayName(spellKey)
    -- First check Shredded_SpellMeta for displayName (from SPELL_DATABASE)
    if Shredded_SpellMeta and Shredded_SpellMeta[spellKey] and Shredded_SpellMeta[spellKey].displayName then
        return Shredded_SpellMeta[spellKey].displayName
    end
    -- Then fallback to local SPELL_DISPLAY_NAMES table
    return SPELL_DISPLAY_NAMES[spellKey] or spellKey
end

-- Helper to check if player has a spell (uses global from Shredded.lua)
local function PlayerHasSpell(spellKey)
    if Shredded_PlayerHasSpell then
        return Shredded_PlayerHasSpell(spellKey)
    end
    -- Fallback: assume available
    return true
end

-- Helper to get spell tooltip info
local function GetSpellTooltip(spellKey)
    if Shredded_GetSpellInfo then
        local info = Shredded_GetSpellInfo(spellKey)
        if info then
            local source = info.source or "Unknown"
            local tip = info.tooltip or ""
            return "|cFFFFD100" .. source .. "|r\n" .. tip
        end
    end
    return ""
end

-- ===========================================
-- SLASH COMMANDS
-- ===========================================

local function SetupSlashCommands()
    SlashCmdList["Shredded"] = function(msg)
        msg = msg:lower():trim()
        if msg == "lock" or msg == "move" then
            Shredded_Move()
        elseif msg == "reset" then
            ShreddedDefaultSettings()
            Shredded_Refresh()
            ShreddedO("Settings reset to defaults!")
        elseif msg == "buffs" then
            -- Dump all player buffs with spell IDs and overlay status
            local lines = {"=== Player Buffs (run during combat!) ==="}
            local count = 0
            for i = 1, 40 do
                local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
                if aura then
                    -- Check overlay status for this spell
                    local hasOverlay = false
                    pcall(function()
                        hasOverlay = C_SpellActivationOverlay.IsSpellOverlayed(aura.spellId)
                    end)
                    local overlayStr = hasOverlay and " [OVERLAY!]" or ""
                    
                    -- Build the entire line inside pcall to avoid secret contamination
                    local ok, line = pcall(function()
                        return string.format("%s - ID: %d (dur: %.1fs)%s", 
                            tostring(aura.name), 
                            aura.spellId, 
                            aura.duration or 0,
                            overlayStr)
                    end)
                    if ok and line then
                        table.insert(lines, line)
                    else
                        table.insert(lines, "Buff " .. i .. ": [secret values]" .. overlayStr)
                    end
                    count = count + 1
                else
                    break
                end
            end
            if count == 0 then
                table.insert(lines, "No buffs found on player")
            else
                table.insert(lines, "")
                table.insert(lines, "Total: " .. count .. " buffs")
            end
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
        elseif msg == "debuffs" then
            -- Dump all debuffs on target with spell IDs (uses popup to avoid chat addon issues)
            local lines = {"=== Target Debuffs ==="}
            if not UnitExists("target") then
                table.insert(lines, "No target selected!")
            else
                local count = 0
                for i = 1, 40 do
                    local aura = C_UnitAuras.GetDebuffDataByIndex("target", i)
                    if aura then
                        -- Build the entire line inside pcall to avoid secret contamination
                        local ok, line = pcall(function()
                            local mineStr = ""
                            if aura.isFromPlayerOrPlayerPet then
                                mineStr = " [YOURS]"
                            end
                            return string.format("%s - ID: %d (dur: %.1fs)%s", 
                                tostring(aura.name), 
                                aura.spellId, 
                                aura.duration or 0,
                                mineStr)
                        end)
                        if ok and line then
                            table.insert(lines, line)
                        else
                            table.insert(lines, "Debuff " .. i .. ": [secret values]")
                        end
                        count = count + 1
                    else
                        break
                    end
                end
                if count == 0 then
                    table.insert(lines, "No debuffs found on target")
                else
                    table.insert(lines, "")
                    table.insert(lines, "Total: " .. count .. " debuffs")
                end
            end
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
        elseif msg == "test" then
            -- Test mode: simulate all enabled bars with valid spells
            local testDuration = 10  -- seconds
            local now = GetTime()
            local count = 0
            local triggered = {}
            local failed = {}
            
            -- Build barOrder for test (bypass Shredded_PlayerHasSpell check)
            local testBarOrder = {}
            local barIndex = 1
            
            if ShreddedCatSpells and ShreddedSettings and ShreddedSettings["baron"] then
                for _, key in ipairs(ShreddedCatSpells) do
                    if ShreddedSettings["baron"][key] then
                        -- Check if spell exists
                        local spellData = Shredded_SpellMeta and Shredded_SpellMeta[key]
                        local spellId = spellData and spellData.id
                        local isValid = false
                        local spellName = key
                        
                        if spellId and type(spellId) == "number" then
                            local info = C_Spell.GetSpellInfo(spellId)
                            if info and info.name then
                                isValid = true
                                spellName = info.name
                            end
                        elseif key == "ENERGY" or key == "COMBO" then
                            isValid = true  -- Resources are always valid
                        end
                        
                        if isValid then
                            -- Inject fake aura data
                            if Shredded_auraRawData then
                                Shredded_auraRawData[key] = {
                                    duration = testDuration,
                                    expirationTime = now + testDuration,
                                    exists = true,
                                    source = "TEST"
                                }
                            end
                            -- Also add to barOrder
                            testBarOrder["ShreddedBar" .. barIndex] = key
                            barIndex = barIndex + 1
                            table.insert(triggered, key)
                            count = count + 1
                        else
                            table.insert(failed, key .. " (ID: " .. tostring(spellId) .. ")")
                        end
                    end
                end
            end
            
            -- Copy test order to actual barOrder
            if Shredded_barOrder then
                wipe(Shredded_barOrder)
                for frame, spell in pairs(testBarOrder) do
                    Shredded_barOrder[frame] = spell
                end
            end
            
            -- Enable test mode (bypasses cat form check)
            Shredded_TestMode = true
            
            -- Force full frame update (not just bar personality)
            if Shredded_FullFrameUpdate then
                Shredded_FullFrameUpdate()
            elseif Shredded_BarPersonality then
                Shredded_BarPersonality()
            end
            
            -- Disable test mode after a delay
            C_Timer.After(testDuration + 1, function()
                Shredded_TestMode = false
                -- Clear test data
                if Shredded_auraRawData then
                    for _, key in ipairs(triggered) do
                        Shredded_auraRawData[key] = nil
                    end
                end
            end)
            
            -- Print summary to chat (not popup, so bars are visible)
            ShreddedO("=== Test Mode: " .. count .. " bars triggered for " .. testDuration .. "s ===")
            if #failed > 0 then
                ShreddedO("Failed spells: " .. table.concat(failed, ", "))
            end
            
        elseif msg == "combatlog" then
            -- Toggle real-time combat logging to chat
            Shredded_CombatLogEnabled = not Shredded_CombatLogEnabled
            wipe(Shredded_LastProcState)  -- Reset state tracking
            if Shredded_CombatLogEnabled then
                ShreddedO("|cFF00FF00Combat log ENABLED|r - proc state changes will print to chat during combat")
            else
                ShreddedO("|cFFFF0000Combat log DISABLED|r")
            end
            
        elseif msg == "cdm" then
            -- Debug CDM viewer map - shows which spells are mapped to which viewer children
            local lines = {"=== CDM Viewer Map Debug ===", ""}
            
            -- Check CDM CVar
            local cdmCvar = GetCVar("cooldownViewerEnabled")
            table.insert(lines, "CVar cooldownViewerEnabled = " .. tostring(cdmCvar))
            table.insert(lines, "")
            
            -- Check if viewers exist
            local viewerNames = {"EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer", "BuffBarCooldownViewer"}
            table.insert(lines, "Viewer Frames:")
            for _, name in ipairs(viewerNames) do
                local viewer = _G[name]
                if viewer then
                    local children = {viewer:GetChildren()}
                    local hasCooldownInfo = 0
                    local noCooldownInfo = 0
                    for _, child in pairs(children) do
                        if child.cooldownInfo then
                            hasCooldownInfo = hasCooldownInfo + 1
                        else
                            noCooldownInfo = noCooldownInfo + 1
                        end
                    end
                    table.insert(lines, "  " .. name .. ": " .. #children .. " children (" .. hasCooldownInfo .. " with cooldownInfo, " .. noCooldownInfo .. " without)")
                    
                    -- Show all children (with or without cooldownInfo)
                    for i, child in ipairs(children) do
                        if child.cooldownInfo then
                            local sid = child.cooldownInfo.spellID or "nil"
                            local oid = child.cooldownInfo.overrideSpellID
                            local tid = child.cooldownInfo.overrideTooltipSpellID
                            local instId = child.auraInstanceID
                            local aUnit = child.auraDataUnit
                            local hasCd = child.Cooldown and "Y" or "N"
                            local vis = child:IsVisible() and "vis" or "hid"
                            local spellName = ""
                            if type(sid) == "number" then
                                pcall(function() spellName = C_Spell.GetSpellName(sid) or "" end)
                            end
                            local extra = ""
                            if oid then extra = extra .. " override=" .. oid end
                            if tid then extra = extra .. " tooltip=" .. tid end
                            if instId then extra = extra .. " instID=" .. tostring(instId) end
                            if aUnit then extra = extra .. " unit=" .. aUnit end
                            table.insert(lines, "    [" .. i .. "] ID:" .. tostring(sid) .. " (" .. spellName .. ") CD:" .. hasCd .. " " .. vis .. extra)
                        else
                            -- No cooldownInfo - dump what we CAN see
                            local childName = child:GetName() or "unnamed"
                            local childType = child:GetObjectType() or "?"
                            local vis = child:IsVisible() and "vis" or "hid"
                            local hasCd = child.Cooldown and "Y" or "N"
                            -- Enumerate known/common keys
                            local keys = {}
                            for k, v in pairs(child) do
                                if type(k) == "string" and k ~= "0" then
                                    local vtype = type(v)
                                    if vtype == "number" or vtype == "string" or vtype == "boolean" then
                                        table.insert(keys, k .. "=" .. tostring(v))
                                    elseif vtype == "table" then
                                        table.insert(keys, k .. "={...}")
                                    elseif vtype == "function" then
                                        -- skip functions
                                    else
                                        table.insert(keys, k .. "=<" .. vtype .. ">")
                                    end
                                end
                            end
                            local keyStr = #keys > 0 and (" keys: " .. table.concat(keys, ", ")) or " (no custom keys)"
                            table.insert(lines, "    [" .. i .. "] NO cooldownInfo | name=" .. childName .. " type=" .. childType .. " CD:" .. hasCd .. " " .. vis .. keyStr)
                        end
                    end
                else
                    table.insert(lines, "  " .. name .. ": NOT FOUND (global is nil)")
                end
            end
            
            table.insert(lines, "")
            table.insert(lines, "Shredded_viewerAuraFrames (our tracked spells):")
            if Shredded_viewerAuraFrames then
                for _, key in ipairs(ShreddedCooldownSpells) do
                    local meta = Shredded_SpellMeta and Shredded_SpellMeta[key]
                    local id = meta and meta.id
                    if id then
                        local child = Shredded_viewerAuraFrames[id]
                        if child then
                            local parentName = child:GetParent() and child:GetParent():GetName() or "?"
                            local instId = child.auraInstanceID
                            local aUnit = child.auraDataUnit
                            local status = parentName
                            if instId then status = status .. " instID=" .. tostring(instId) end
                            if aUnit then status = status .. " unit=" .. aUnit end
                            table.insert(lines, "  " .. key .. " (ID:" .. id .. ") -> " .. status)
                        else
                            -- Try to find via GetCooldownAuraBySpellID
                            local auraId = nil
                            pcall(function() auraId = C_UnitAuras.GetCooldownAuraBySpellID(id) end)
                            local auraStr = auraId and auraId ~= 0 and (" auraID=" .. auraId) or ""
                            table.insert(lines, "  " .. key .. " (ID:" .. id .. ") -> NOT MAPPED" .. auraStr)
                        end
                    end
                end
                -- Also check bar spells
                table.insert(lines, "")
                table.insert(lines, "Bar spells:")
                if ShreddedCatSpells then
                    for _, key in ipairs(ShreddedCatSpells) do
                        local meta = Shredded_SpellMeta and Shredded_SpellMeta[key]
                        local id = meta and meta.id
                        if id then
                            local child = Shredded_viewerAuraFrames[id]
                            if child then
                                local parentName = child:GetParent() and child:GetParent():GetName() or "?"
                                local isBuff = parentName == "BuffIconCooldownViewer" or parentName == "BuffBarCooldownViewer"
                                table.insert(lines, "  " .. key .. " (ID:" .. id .. ") -> " .. parentName .. (isBuff and " [BUFF]" or " [CD]"))
                            else
                                table.insert(lines, "  " .. key .. " (ID:" .. id .. ") -> NOT MAPPED")
                            end
                        end
                    end
                end
            else
                table.insert(lines, "  [Shredded_viewerAuraFrames is nil/empty!]")
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "rebuild" then
            -- Force rebuild of CDM viewer map
            if Shredded_RebuildViewerMap then
                Shredded_viewerMapRetries = 0  -- Reset retry counter
                Shredded_RebuildViewerMap()
                ShreddedO("|cFF00FF00CDM viewer map rebuilt!|r Run /shredded cdm to check results.")
            else
                ShreddedO("|cFFFF0000BuildViewerAuraMap not available yet.|r")
            end
            
        elseif msg == "procs" then
            -- Debug proc detection - shows frame map status and detection
            local lines = {"=== Proc Icons Debug ===", ""}
            
            -- Show global settings first
            local cooldownsOn = ShreddedSettings and ShreddedSettings["cooldownson"]
            local cooldownAlpha = ShreddedSettings and ShreddedSettings["cooldownalpha"] or 0
            table.insert(lines, "Settings: cooldownson=" .. tostring(cooldownsOn) .. ", alpha=" .. tostring(cooldownAlpha))
            table.insert(lines, "")
            
            -- First show the frame map status
            table.insert(lines, "Frame Map Status:")
            local mapCount = 0
            if Shredded_CooldownFrameMap then
                for spell, frameNum in pairs(Shredded_CooldownFrameMap) do
                    mapCount = mapCount + 1
                    local frameName = "ShreddedCooldown" .. frameNum
                    local frame = ShreddedCooldownList and ShreddedCooldownList[frameName]
                    local alpha = frame and frame:GetAlpha() or "?"
                    local shown = frame and frame:IsShown() and "Y" or "N"
                    local iconId = Shredded_SPELL_ICONS and Shredded_SPELL_ICONS[spell] or "nil"
                    table.insert(lines, "  " .. spell .. " -> Frame " .. frameNum .. " (icon:" .. tostring(iconId) .. ", alpha=" .. tostring(alpha) .. ")")
                end
            end
            if mapCount == 0 then
                table.insert(lines, "  [EMPTY! No procs mapped to frames]")
            end
            
            table.insert(lines, "")
            table.insert(lines, "Proc Detection Status:")
            
            -- Check each proc in ShreddedCooldownSpells
            for _, key in ipairs(ShreddedCooldownSpells) do
                local meta = Shredded_SpellMeta and Shredded_SpellMeta[key]
                local spellId = meta and meta.id
                local isProc = meta and meta.isProc
                local isCooldown = meta and meta.isCooldown
                
                if (isProc or isCooldown) and spellId then
                    local overlayed = false
                    pcall(function()
                        overlayed = C_SpellActivationOverlay.IsSpellOverlayed(spellId)
                    end)
                    
                    local hasAura = Shredded_auraRawData and Shredded_auraRawData[key] ~= nil
                    local inMap = Shredded_CooldownFrameMap and Shredded_CooldownFrameMap[key] ~= nil
                    local hasSpell = Shredded_PlayerHasSpell and Shredded_PlayerHasSpell(key)
                    local hasIcon = Shredded_SPELL_ICONS and Shredded_SPELL_ICONS[key] ~= nil
                    local iconId = Shredded_SPELL_ICONS and Shredded_SPELL_ICONS[key] or "nil"
                    
                    -- Check talentId specifically
                    local talentId = meta.talentId
                    local talentCheck = "N/A"
                    if talentId and type(talentId) == "number" then
                        local ips = IsPlayerSpell(talentId) and "Y" or "N"
                        local isk = IsSpellKnown(talentId) and "Y" or "N"
                        talentCheck = "IPS=" .. ips .. ",ISK=" .. isk
                    end
                    
                    local status = ""
                    if overlayed then status = status .. " [OVERLAY]" end
                    if hasAura then status = status .. " [AURA]" end
                    if not inMap then status = status .. " [NOT MAPPED]" end
                    if not hasSpell then status = status .. " [NO SPELL]" end
                    if not hasIcon then status = status .. " [NO ICON]" else status = status .. " [icon:" .. tostring(iconId) .. "]" end
                    if status == "" then status = " (ready, waiting)" end
                    
                    local typeStr = isProc and "proc" or "cd"
                    local talentStr = talentId and (" tal:" .. talentId .. " " .. talentCheck) or ""
                    table.insert(lines, "  " .. key .. " (" .. typeStr .. ", ID:" .. spellId .. talentStr .. ")" .. status)
                else
                    local reason = "no meta"
                    if meta and not spellId then reason = "no ID" end
                    if meta and spellId and not isProc and not isCooldown then reason = "not proc/cd" end
                    table.insert(lines, "  " .. key .. " [SKIP: " .. reason .. "]")
                end
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "framemap" then
            -- Debug frame mapping - show exactly which spell is on which frame
            local lines = {"=== Frame Map Debug ===", ""}
            
            table.insert(lines, "Shredded_CooldownFrameMap (spell -> frame):")
            if Shredded_CooldownFrameMap then
                local sorted = {}
                for spell, frameNum in pairs(Shredded_CooldownFrameMap) do
                    table.insert(sorted, {spell = spell, frame = frameNum})
                end
                table.sort(sorted, function(a, b) return a.frame < b.frame end)
                for _, entry in ipairs(sorted) do
                    local iconId = SPELL_ICONS and SPELL_ICONS[entry.spell] or "nil"
                    table.insert(lines, "  Frame " .. entry.frame .. " = " .. entry.spell .. " (icon:" .. tostring(iconId) .. ")")
                end
            end
            
            table.insert(lines, "")
            table.insert(lines, "Shredded_FrameSpellMap (frame -> spell):")
            if Shredded_FrameSpellMap then
                for i = 1, 20 do
                    local spell = Shredded_FrameSpellMap[i]
                    if spell then
                        local iconId = SPELL_ICONS and SPELL_ICONS[spell] or "nil"
                        table.insert(lines, "  Frame " .. i .. " = " .. spell .. " (icon:" .. tostring(iconId) .. ")")
                    end
                end
            end
            
            table.insert(lines, "")
            table.insert(lines, "Actual Frame Textures:")
            for i = 1, 20 do
                local frameName = "ShreddedCooldown" .. i
                local textureFrame = ShreddedCooldownTextureList and ShreddedCooldownTextureList[frameName]
                if textureFrame then
                    local texturePath = textureFrame:GetTexture()
                    if texturePath then
                        table.insert(lines, "  Frame " .. i .. " texture: " .. tostring(texturePath))
                    end
                end
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "talentcheck" then
            -- Debug what procs Shredded thinks the player has
            local lines = {"=== Talent/Proc Detection Debug ===", ""}
            
            -- Show detected hero tree (use global function)
            local heroTree = "unknown"
            if Shredded_DetectHeroTree then
                heroTree = Shredded_DetectHeroTree() or "nil (can't detect)"
            end
            table.insert(lines, "Detected Hero Tree: " .. heroTree)
            table.insert(lines, "")
            
            -- Check each proc spell
            table.insert(lines, "Proc Spells (from ShreddedCooldownSpells):")
            for _, spell in ipairs(ShreddedCooldownSpells) do
                local meta = Shredded_SpellMeta and Shredded_SpellMeta[spell]
                if meta and meta.isProc then
                    local hasSpell = Shredded_PlayerHasSpell and Shredded_PlayerHasSpell(spell)
                    local isEnabled = ShreddedSettings and ShreddedSettings["cooldownon"] and ShreddedSettings["cooldownon"][spell] ~= false
                    local source = meta.source or "?"
                    local frameNum = Shredded_CooldownFrameMap and Shredded_CooldownFrameMap[spell] or "none"
                    -- Use global Shredded_SPELL_ICONS
                    local iconId = Shredded_SPELL_ICONS and Shredded_SPELL_ICONS[spell]
                    local hasIcon = iconId and "Y" or "N"
                    
                    local status = ""
                    if hasSpell then status = status .. "[HAS] " else status = status .. "[NO] " end
                    if isEnabled then status = status .. "[ON] " else status = status .. "[OFF] " end
                    status = status .. "frame=" .. tostring(frameNum) .. " icon=" .. hasIcon
                    if iconId then status = status .. " (" .. tostring(iconId) .. ")" end
                    
                    table.insert(lines, "  " .. spell .. " (" .. source .. "): " .. status)
                end
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "detect" then
            -- Real-time detection debug - what's being detected RIGHT NOW
            local inCombat = InCombatLockdown()
            local lines = {"=== Real-Time Proc Detection ===", "Combat: " .. tostring(inCombat), ""}
            
            for _, spell in ipairs(ShreddedCooldownSpells) do
                local spellMeta = Shredded_SpellMeta and Shredded_SpellMeta[spell]
                local spellId = spellMeta and spellMeta.id
                local frameNum = Shredded_CooldownFrameMap and Shredded_CooldownFrameMap[spell]
                
                if spellId and spellMeta and spellMeta.isProc then
                    -- Check event-captured instance cache FIRST (like CooldownCompanion)
                    local cachedInstId = Shredded_auraInstanceCache and Shredded_auraInstanceCache[spell]
                    
                    -- Check GetPlayerAuraBySpellID for main ID
                    local auraData = nil
                    local auraOk, auraResult = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
                    if auraOk then auraData = auraResult end
                    
                    local auraInstanceID = nil
                    if auraData then
                        pcall(function() auraInstanceID = auraData.auraInstanceID end)
                    end
                    
                    -- Also check altIds
                    local altIdFound = nil
                    if not auraInstanceID and spellMeta.altIds then
                        for _, altId in ipairs(spellMeta.altIds) do
                            local altOk, altData = pcall(C_UnitAuras.GetPlayerAuraBySpellID, altId)
                            if altOk and altData then
                                pcall(function()
                                    if altData.auraInstanceID then
                                        auraInstanceID = altData.auraInstanceID
                                        altIdFound = altId
                                    end
                                end)
                            end
                            if auraInstanceID then break end
                        end
                    end
                    
                    -- Check IsSpellOverlayed
                    local overlayed = false
                    pcall(function()
                        overlayed = C_SpellActivationOverlay.IsSpellOverlayed(spellId)
                    end)
                    -- Also check altIds for overlay
                    if not overlayed and spellMeta.altIds then
                        for _, altId in ipairs(spellMeta.altIds) do
                            pcall(function()
                                overlayed = C_SpellActivationOverlay.IsSpellOverlayed(altId)
                            end)
                            if overlayed then break end
                        end
                    end
                    
                    local status = ""
                    if cachedInstId then
                        status = status .. "[CACHE:" .. cachedInstId .. "] "
                    end
                    if auraInstanceID then 
                        status = status .. "[API:" .. auraInstanceID
                        if altIdFound then status = status .. " via altId " .. altIdFound end
                        status = status .. "] "
                    end
                    if overlayed then status = status .. "[OVERLAY] " end
                    if status == "" then status = "(not detected)" end
                    
                    local frameStr = frameNum and ("Frame " .. frameNum) or "NOT MAPPED"
                    table.insert(lines, spell .. " (ID:" .. spellId .. ") " .. frameStr .. " - " .. status)
                end
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "buffscan" then
            -- Scan ALL current player buffs and show their ACTUAL spell IDs
            -- This is critical to find correct buff IDs for procs
            local lines = {"=== ACTUAL Player Buffs Right Now ===", "Run this when a proc is active!", ""}
            
            for i = 1, 40 do
                local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
                if not aura then break end
                
                local name, spellId, icon, duration, expTime, instId = "?", "?", "?", "?", "?", "?"
                pcall(function() name = aura.name end)
                pcall(function() spellId = aura.spellId end)
                pcall(function() icon = aura.icon end)
                pcall(function() duration = aura.duration end)
                pcall(function() expTime = aura.expirationTime end)
                pcall(function() instId = aura.auraInstanceID end)
                
                -- Check if this ID is in our database
                local knownAs = Shredded_SPELL_ID_TO_KEY and Shredded_SPELL_ID_TO_KEY[spellId] or nil
                local knownStr = knownAs and (" -> " .. knownAs) or ""
                
                -- Check overlay
                local hasOverlay = false
                if type(spellId) == "number" then
                    pcall(function() hasOverlay = C_SpellActivationOverlay.IsSpellOverlayed(spellId) end)
                end
                local overlayStr = hasOverlay and " [GLOW]" or ""
                
                local line = string.format("%d. %s (ID:%s) dur=%s%s%s", i, tostring(name), tostring(spellId), tostring(duration), knownStr, overlayStr)
                table.insert(lines, line)
            end
            
            table.insert(lines, "")
            table.insert(lines, "IDs with -> show what Shredded thinks they are.")
            table.insert(lines, "IDs without -> are NOT in our database!")
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "auras" then
            -- Debug what's actually in auraRawData
            local lines = {"=== auraRawData Debug ===", ""}
            
            if not Shredded_auraRawData then
                table.insert(lines, "Shredded_auraRawData is nil!")
            else
                local count = 0
                local now = GetTime()
                for key, data in pairs(Shredded_auraRawData) do
                    count = count + 1
                    local remaining = 0
                    if data.expirationTime then
                        remaining = data.expirationTime - now
                    end
                    local line = key .. ":"
                    line = line .. " exp=" .. tostring(data.expirationTime or "nil")
                    line = line .. " dur=" .. tostring(data.duration or "nil")
                    line = line .. " rem=" .. string.format("%.1f", remaining)
                    line = line .. " src=" .. tostring(data.source or "?")
                    table.insert(lines, line)
                end
                if count == 0 then
                    table.insert(lines, "[Empty - no auras being tracked]")
                else
                    table.insert(lines, "")
                    table.insert(lines, "Total: " .. count .. " tracked auras")
                end
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "log" then
            -- Show the proc log - captured during combat
            local lines = {"=== Proc Log (last 50) ===", "Fight first, then check this log!", ""}
            
            if not Shredded_ProcLog or #Shredded_ProcLog == 0 then
                table.insert(lines, "No procs logged yet. Enter combat and trigger some procs!")
            else
                -- Deduplicate by spell ID (show each unique ID once with count)
                local seen = {}
                local unique = {}
                for _, entry in ipairs(Shredded_ProcLog) do
                    if not seen[entry.id] then
                        seen[entry.id] = { name = entry.name, id = entry.id, overlay = entry.overlay, count = 1 }
                        table.insert(unique, seen[entry.id])
                    else
                        seen[entry.id].count = seen[entry.id].count + 1
                        if entry.overlay then seen[entry.id].overlay = true end
                    end
                end
                
                -- Sort by count descending
                table.sort(unique, function(a, b) return a.count > b.count end)
                
                for _, entry in ipairs(unique) do
                    local overlayStr = entry.overlay and " [OVERLAY]" or ""
                    table.insert(lines, string.format("%s - ID: %d (x%d)%s", 
                        entry.name, entry.id, entry.count, overlayStr))
                end
                
                table.insert(lines, "")
                table.insert(lines, "Total unique: " .. #unique)
                table.insert(lines, "Use these IDs to update SPELL_DATABASE!")
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "clearlog" then
            if Shredded_ProcLog then
                wipe(Shredded_ProcLog)
            end
            ShreddedO("Proc log cleared!")
            
        elseif msg == "trace" then
            -- Trace proc display logic for CLEARCASTING
            local lines = {"=== Proc Display Trace (CLEARCASTING) ===", ""}
            local spell = "CLEARCASTING"
            
            -- Check SPELL_ID_TO_KEY registration
            local spellMeta = Shredded_SpellMeta and Shredded_SpellMeta[spell]
            if spellMeta then
                local primaryId = spellMeta.id
                local talentId = spellMeta.talentId
                local reverseLookup = Shredded_SPELL_ID_TO_KEY and Shredded_SPELL_ID_TO_KEY[primaryId]
                table.insert(lines, "SPELL_ID_TO_KEY[" .. tostring(primaryId) .. "]: " .. tostring(reverseLookup))
                if talentId then
                    local talentLookup = Shredded_SPELL_ID_TO_KEY and Shredded_SPELL_ID_TO_KEY[talentId]
                    table.insert(lines, "SPELL_ID_TO_KEY[" .. tostring(talentId) .. "]: " .. tostring(talentLookup))
                end
                if spellMeta.altIds then
                    for _, altId in ipairs(spellMeta.altIds) do
                        local altLookup = Shredded_SPELL_ID_TO_KEY and Shredded_SPELL_ID_TO_KEY[altId]
                        table.insert(lines, "SPELL_ID_TO_KEY[" .. tostring(altId) .. "]: " .. tostring(altLookup))
                    end
                end
            end
            table.insert(lines, "")
            
            -- Check frame map
            local frameNum = Shredded_CooldownFrameMap and Shredded_CooldownFrameMap[spell]
            table.insert(lines, "FrameMap: " .. (frameNum and tostring(frameNum) or "NOT MAPPED"))
            
            if frameNum then
                local frameName = "ShreddedCooldown" .. frameNum
                local frame = ShreddedCooldownList and ShreddedCooldownList[frameName]
                local textFrame = ShreddedCooldownTextList and ShreddedCooldownTextList[frameName]
                
                table.insert(lines, "frameName: " .. frameName)
                table.insert(lines, "frame exists: " .. tostring(frame ~= nil))
                table.insert(lines, "textFrame exists: " .. tostring(textFrame ~= nil))
                
                if frame then
                    table.insert(lines, "frame:GetAlpha(): " .. tostring(frame:GetAlpha()))
                    table.insert(lines, "frame:IsShown(): " .. tostring(frame:IsShown()))
                    table.insert(lines, "frame:IsVisible(): " .. tostring(frame:IsVisible()))
                end
            end
            
            table.insert(lines, "")
            
            -- Check auraRawData
            local rawData = Shredded_auraRawData and Shredded_auraRawData[spell]
            table.insert(lines, "auraRawData[CLEARCASTING]: " .. (rawData and "EXISTS" or "NIL"))
            if rawData then
                table.insert(lines, "  source: " .. tostring(rawData.source or "?"))
                table.insert(lines, "  exists: " .. tostring(rawData.exists))
                if rawData.expirationTime then
                    local remaining = rawData.expirationTime - GetTime()
                    table.insert(lines, "  remaining: " .. string.format("%.1f", remaining) .. "s")
                end
            end
            local isAuraActive = (rawData ~= nil)
            table.insert(lines, "isAuraActive: " .. tostring(isAuraActive))
            
            -- Check auraInstanceCache
            local cachedInstance = Shredded_auraInstanceCache and Shredded_auraInstanceCache[spell]
            table.insert(lines, "auraInstanceCache: " .. (cachedInstance and tostring(cachedInstance) or "NIL"))
            
            -- Check pending procs
            local pendingInfo = Shredded_pendingProcs and Shredded_pendingProcs[spell]
            if pendingInfo then
                local age = GetTime() - pendingInfo.time
                table.insert(lines, "pendingProc: YES (age: " .. string.format("%.1f", age) .. "s)")
            else
                table.insert(lines, "pendingProc: NO")
            end
            
            table.insert(lines, "")
            
            -- Direct API check right now
            local spellMeta = Shredded_SpellMeta and Shredded_SpellMeta[spell]
            if spellMeta and spellMeta.id then
                local apiResult = "nil"
                pcall(function()
                    local data = C_UnitAuras.GetPlayerAuraBySpellID(spellMeta.id)
                    if data then
                        apiResult = "FOUND (instanceID=" .. tostring(data.auraInstanceID) .. ")"
                    end
                end)
                table.insert(lines, "Direct API check (ID " .. spellMeta.id .. "): " .. apiResult)
                
                -- Also try altIds
                if spellMeta.altIds then
                    for _, altId in ipairs(spellMeta.altIds) do
                        pcall(function()
                            local data = C_UnitAuras.GetPlayerAuraBySpellID(altId)
                            if data then
                                table.insert(lines, "  Alt ID " .. altId .. ": FOUND")
                            end
                        end)
                    end
                end
            end
            
            table.insert(lines, "")
            
            -- Check spell metadata
            table.insert(lines, "SpellMeta exists: " .. tostring(spellMeta ~= nil))
            if spellMeta then
                table.insert(lines, "  isProc: " .. tostring(spellMeta.isProc))
                table.insert(lines, "  isCooldown: " .. tostring(spellMeta.isCooldown))
                table.insert(lines, "  id: " .. tostring(spellMeta.id))
            end
            
            local isProc = spellMeta and spellMeta.isProc
            local isCooldown = spellMeta and spellMeta.isCooldown
            
            table.insert(lines, "")
            
            -- Check overlay
            local spellId = spellMeta and spellMeta.id
            local isProcOverlayed = false
            if isProc and spellId then
                pcall(function()
                    isProcOverlayed = C_SpellActivationOverlay.IsSpellOverlayed(spellId)
                end)
            end
            table.insert(lines, "isProcOverlayed: " .. tostring(isProcOverlayed))
            
            table.insert(lines, "")
            
            -- Final calculation
            local showProcIcon = false
            if isProc or isCooldown then
                showProcIcon = isProcOverlayed or isAuraActive
            end
            table.insert(lines, "isProc or isCooldown: " .. tostring(isProc or isCooldown))
            table.insert(lines, "showProcIcon: " .. tostring(showProcIcon))
            
            table.insert(lines, "")
            
            -- Settings
            table.insert(lines, "cooldownson: " .. tostring(ShreddedSettings and ShreddedSettings["cooldownson"]))
            table.insert(lines, "cooldownalpha: " .. tostring(ShreddedSettings and ShreddedSettings["cooldownalpha"]))
            
            table.insert(lines, "")
            table.insert(lines, "=== Widget Decoder Test ===")
            -- Test the decoder on any cached instanceID
            if cachedInstance then
                local decoderResult = "N/A"
                pcall(function()
                    local durationObj = C_UnitAuras.GetAuraDuration("player", cachedInstance)
                    if durationObj then
                        -- Try to use the decoder widget
                        local decoder = ShreddedSecretDecoderCooldown
                        if decoder and decoder.SetCooldownFromDurationObject then
                            pcall(function()
                                decoder:SetCooldownFromDurationObject(durationObj)
                            end)
                            local startTimeMs, durationMs = decoder:GetCooldownTimes()
                            if durationMs and durationMs > 0 then
                                -- Values are in milliseconds
                                local nowMs = GetTime() * 1000
                                local remainingMs = (startTimeMs + durationMs) - nowMs
                                decoderResult = string.format("remaining: %.2f sec, total: %.2f sec", remainingMs / 1000, durationMs / 1000)
                            else
                                decoderResult = "0 returned"
                            end
                        else
                            decoderResult = "decoder widget not found"
                        end
                    else
                        decoderResult = "durationObj nil"
                    end
                end)
                table.insert(lines, "Decoder test: " .. decoderResult)
            else
                table.insert(lines, "Decoder test: no cached instanceID")
            end
            
            table.insert(lines, "")
            table.insert(lines, "=== Scanning ALL buffs for 'clear' ===")
            -- Scan all buffs looking for anything with "clear" in the name
            for i = 1, 40 do
                local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
                if not aura then break end
                local name, spellIdFound = nil, nil
                pcall(function()
                    name = aura.name
                    spellIdFound = aura.spellId
                end)
                if name and type(name) == "string" then
                    local lowerName = string.lower(name)
                    if string.find(lowerName, "clear") or string.find(lowerName, "omen") then
                        table.insert(lines, "FOUND: " .. name .. " (ID: " .. tostring(spellIdFound) .. ")")
                    end
                end
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "scan" then
            -- Dump ALL current buffs with their IDs
            local lines = {"=== ALL Current Buffs ===", "Run this OUT OF COMBAT for readable IDs!", ""}
            
            local count = 0
            for i = 1, 40 do
                local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
                if not aura then break end
                
                local name, spellIdFound, duration, instanceId = "?", "?", "?", "?"
                
                -- auraInstanceID is always readable (NeverSecret)
                instanceId = aura.auraInstanceID or "?"
                
                -- Other fields may be secret - wrap in pcall
                pcall(function()
                    -- Try to convert to string to test if readable
                    local testName = tostring(aura.name)
                    if testName and testName ~= "nil" then
                        name = aura.name
                    end
                end)
                pcall(function()
                    local testId = tostring(aura.spellId)
                    if testId and testId ~= "nil" then
                        spellIdFound = aura.spellId
                    end
                end)
                pcall(function()
                    local testDur = tostring(aura.duration)
                    if testDur and testDur ~= "nil" then
                        duration = aura.duration
                    end
                end)
                
                count = count + 1
                table.insert(lines, string.format("%d. %s - ID: %s (inst: %s)", 
                    i, tostring(name), tostring(spellIdFound), tostring(instanceId)))
            end
            
            table.insert(lines, "")
            table.insert(lines, "Total buffs: " .. count)
            if count > 0 then
                table.insert(lines, "")
                table.insert(lines, "If IDs show '?' you're in combat!")
                table.insert(lines, "Run this command OUT OF COMBAT")
                table.insert(lines, "while procs are active (attack dummy, exit combat)")
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "active" then
            -- Show which procs are in ACTIVE_SPELLS
            local lines = {"=== ACTIVE_SPELLS Proc Check ===", ""}
            
            table.insert(lines, "Procs in ShreddedCooldownSpells:")
            for _, key in ipairs(ShreddedCooldownSpells) do
                local inActive = Shredded_ACTIVE_SPELLS and Shredded_ACTIVE_SPELLS[key]
                local meta = Shredded_SpellMeta and Shredded_SpellMeta[key]
                local status = inActive and "IN ACTIVE_SPELLS" or "NOT in ACTIVE_SPELLS"
                local typeStr = ""
                if meta then
                    if meta.isProc then typeStr = "proc" end
                    if meta.isCooldown then typeStr = "cd" end
                end
                table.insert(lines, "  " .. key .. " (" .. typeStr .. "): " .. status)
            end
            
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
            
        elseif msg == "bars" then
            -- Debug which bars are enabled
            local lines = {"=== Timer Bars Config ==="}
            local checkSpells = {"RIP", "RAKE", "THRASH", "TIGERS_FURY", "DREADFUL_WOUND", "INFECTED_WOUNDS", "FERAL_FRENZY", "FRANTIC_FRENZY", "ENERGY", "COMBO"}
            for _, key in ipairs(checkSpells) do
                local enabled = ShreddedSettings and ShreddedSettings["baron"] and ShreddedSettings["baron"][key]
                local inCatSpells = false
                if ShreddedCatSpells then
                    for _, s in ipairs(ShreddedCatSpells) do
                        if s == key then inCatSpells = true break end
                    end
                end
                table.insert(lines, key .. ": enabled=" .. tostring(enabled) .. ", inList=" .. tostring(inCatSpells))
            end
            table.insert(lines, "")
            table.insert(lines, "Total ShreddedCatSpells: " .. (ShreddedCatSpells and #ShreddedCatSpells or 0))
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
        elseif msg == "frenzy" then
            -- Debug Feral/Frantic Frenzy detection
            local output = "=== Frenzy Detection Debug ===\n\n"
            
            -- Check Feral Frenzy
            local feralIds = {274837, 274838, 274839}
            output = output .. "Feral Frenzy checks:\n"
            for _, id in ipairs(feralIds) do
                local hasSpell = IsPlayerSpell(id)
                local known = IsSpellKnown(id)
                output = output .. "  ID " .. id .. ": IsPlayerSpell=" .. tostring(hasSpell) .. ", IsSpellKnown=" .. tostring(known) .. "\n"
            end
            
            -- Check Frantic Frenzy
            local franticIds = {441593, 441226, 473552, 1244079}
            output = output .. "\nFrantic Frenzy checks:\n"
            for _, id in ipairs(franticIds) do
                local hasSpell = IsPlayerSpell(id)
                local known = IsSpellKnown(id)
                output = output .. "  ID " .. id .. ": IsPlayerSpell=" .. tostring(hasSpell) .. ", IsSpellKnown=" .. tostring(known) .. "\n"
            end
            
            -- Check for spell overrides
            output = output .. "\nSpell Override checks:\n"
            if C_Spell.GetOverrideSpell then
                local override274837 = C_Spell.GetOverrideSpell(274837)
                output = output .. "  GetOverrideSpell(274837): " .. tostring(override274837) .. "\n"
                if override274837 and override274837 ~= 274837 then
                    local overrideInfo = C_Spell.GetSpellInfo(override274837)
                    output = output .. "    Override name: " .. (overrideInfo and overrideInfo.name or "nil") .. "\n"
                end
            else
                output = output .. "  C_Spell.GetOverrideSpell not available\n"
            end
            
            -- Check IsSpellKnownOrOverridesKnown
            output = output .. "\nIsSpellKnownOrOverridesKnown checks:\n"
            if IsSpellKnownOrOverridesKnown then
                output = output .. "  274837 (Feral): " .. tostring(IsSpellKnownOrOverridesKnown(274837)) .. "\n"
                output = output .. "  1244079 (Frantic debuff): " .. tostring(IsSpellKnownOrOverridesKnown(1244079)) .. "\n"
            else
                output = output .. "  IsSpellKnownOrOverridesKnown not available\n"
            end
            
            -- Check FindSpellOverrideByID
            output = output .. "\nFindSpellOverrideByID checks:\n"
            if FindSpellOverrideByID then
                local override = FindSpellOverrideByID(274837)
                output = output .. "  FindSpellOverrideByID(274837): " .. tostring(override) .. "\n"
            else
                output = output .. "  FindSpellOverrideByID not available\n"
            end
            
            -- Try to find by name using modern API
            output = output .. "\nName lookups:\n"
            local feralInfo = C_Spell.GetSpellInfo(274837)
            local franticInfo = C_Spell.GetSpellInfo(441593)
            output = output .. "  Feral Frenzy (274837) name: " .. (feralInfo and feralInfo.name or "nil") .. "\n"
            output = output .. "  Frantic Frenzy (441593) name: " .. (franticInfo and franticInfo.name or "nil") .. "\n"
            
            -- Try more IDs for Frantic
            local frantic2 = C_Spell.GetSpellInfo(1244079)
            output = output .. "  Frantic (1244079) name: " .. (frantic2 and frantic2.name or "nil") .. "\n"
            
            -- Check spellbook for actual spell name
            output = output .. "\nSpellbook check:\n"
            local spellInfo = C_Spell.GetSpellInfo(274837)
            if spellInfo then
                output = output .. "  Spell 274837 current name: " .. spellInfo.name .. "\n"
                -- Check if name is "Frantic Frenzy" vs "Feral Frenzy"
                if spellInfo.name == "Frantic Frenzy" then
                    output = output .. "  ** FRANTIC FRENZY DETECTED via name! **\n"
                elseif spellInfo.name == "Feral Frenzy" then
                    output = output .. "  ** FERAL FRENZY DETECTED via name **\n"
                end
            end
            
            -- Show in copyable popup
            Shredded_ShowDebugPopup(output)
            
        elseif msg == "debug" then
            Shredded_Debug()
        elseif msg == "verbose" then
            Shredded_VerboseDebug = not Shredded_VerboseDebug
            ShreddedO("Verbose debug: " .. (Shredded_VerboseDebug and "ON" or "OFF"))
        elseif msg == "status" then
            -- Quick status check
            ShreddedO("=== Shredded Status ===")
            ShreddedO("Cat form: " .. tostring(GetShapeshiftForm() == 2))
            ShreddedO("Bars on: " .. tostring(ShreddedSettings["catbarson"]))
            ShreddedO("Cooldowns on: " .. tostring(ShreddedSettings["cooldownson"]))
            -- Count enabled bars
            local enabledCount = 0
            for spell, enabled in pairs(ShreddedSettings["baron"] or {}) do
                if enabled then enabledCount = enabledCount + 1 end
            end
            ShreddedO("Enabled spells: " .. enabledCount)
            -- Check barOrder
            local barOrderCount = 0
            local bo = Shredded_GetBarOrder and Shredded_GetBarOrder() or {}
            for frame, spell in pairs(bo) do
                barOrderCount = barOrderCount + 1
            end
            ShreddedO("barOrder entries: " .. barOrderCount)
            -- Check ENERGY/COMBO specifically
            ShreddedO("ENERGY baron: " .. tostring(ShreddedSettings["baron"]["ENERGY"]))
            ShreddedO("COMBO baron: " .. tostring(ShreddedSettings["baron"]["COMBO"]))
            -- Check cooldown order
            local cdCount = 0
            for spell, frame in pairs(ShreddedSettings["cooldownorder"] or {}) do
                if frame ~= "no" then cdCount = cdCount + 1 end
            end
            ShreddedO("Cooldown assignments: " .. cdCount)
        elseif msg == "test" then
            -- Quick test to see what auras we can find right now - show in popup
            local lines = {}
            local function addLine(text)
                table.insert(lines, tostring(text))
            end
            
            addLine("=== Shredded Aura Test ===")
            addLine("In combat: " .. tostring(InCombatLockdown()))
            addLine("")
            
            -- Test C_UnitAuras API (modern)
            addLine("--- C_UnitAuras API (Modern) ---")
            local tfData = C_UnitAuras.GetPlayerAuraBySpellID(5217)
            addLine("Tiger's Fury (C_UnitAuras): " .. (tfData and "FOUND" or "nil"))
            
            -- Test name-based iteration (KEY TEST - this should work in combat!)
            addLine("")
            addLine("--- Name-Based Iteration (KEY TEST) ---")
            local tfByName = nil
            -- Get Tiger's Fury name via C_Spell API
            local tfSpellInfo = C_Spell.GetSpellInfo(5217)
            local tfName = tfSpellInfo and tfSpellInfo.name
            if tfName then
                addLine("Looking for spell name: '" .. tfName .. "'")
                for i = 1, 40 do
                    local data = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
                    if not data then break end
                    -- Secret value trick: use table lookup instead of direct comparison
                    local matched = false
                    pcall(function()
                        local lookup = {}
                        lookup[data.name] = true
                        matched = lookup[tfName]
                    end)
                    if matched then
                        tfByName = data
                        addLine("FOUND Tiger's Fury at index " .. i .. " via table lookup trick!")
                        break
                    end
                end
                if not tfByName then
                    addLine("Tiger's Fury NOT FOUND (buff may not be active)")
                end
            else
                addLine("Could not get spell name for Tiger's Fury")
            end
            
            -- Test OLD UnitBuff/UnitDebuff API
            addLine("")
            addLine("--- UnitBuff/UnitDebuff API (Legacy) ---")
            local auraData = C_UnitAuras.GetAuraDataByIndex("player", 1, "HELPFUL")
            addLine("GetAuraDataByIndex(player,1): " .. (auraData and "FOUND" or "nil"))
            
            -- Try UnitAura (oldest)
            if UnitAura then
                local name = UnitAura("player", 1, "HELPFUL")
                addLine("UnitAura(player,1): " .. (name and tostring(name) or "nil"))
            else
                addLine("UnitAura: not available")
            end
            
            -- Count all buffs via iteration
            addLine("")
            addLine("--- Buff Iteration Test ---")
            local buffCount = 0
            for i = 1, 40 do
                local data = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
                if data then
                    buffCount = buffCount + 1
                else
                    break
                end
            end
            addLine("Total buffs found: " .. buffCount .. " (details secret in combat)")
            
            -- Test AuraUtil.ForEachAura
            addLine("")
            addLine("--- AuraUtil.ForEachAura Test ---")
            local forEachCount = 0
            if AuraUtil and AuraUtil.ForEachAura then
                AuraUtil.ForEachAura("player", "HELPFUL", nil, function(auraData)
                    forEachCount = forEachCount + 1
                    if forEachCount <= 3 then
                        local spellId = 0
                        pcall(function()
                            spellId = tonumber(string.format("%d", auraData.spellId)) or 0
                        end)
                        addLine("  ForEach: spellId=" .. spellId)
                    end
                end, true)
                addLine("Total via ForEachAura: " .. forEachCount)
            else
                addLine("AuraUtil.ForEachAura not available")
            end
            
            -- Test GetAuraSlots (alternative method)
            addLine("")
            addLine("--- GetAuraSlots Test ---")
            pcall(function()
                if C_UnitAuras.GetAuraSlots then
                    local slots = C_UnitAuras.GetAuraSlots("player", "HELPFUL")
                    if slots then
                        local slotCount = 0
                        for _ in pairs(slots) do slotCount = slotCount + 1 end
                        addLine("GetAuraSlots returned: " .. slotCount .. " slots")
                    else
                        addLine("GetAuraSlots returned nil")
                    end
                else
                    addLine("GetAuraSlots not available")
                end
            end)
            
            -- Check our tracking
            addLine("")
            addLine("--- Self-Tracked Player Auras (via CD/Cast) ---")
            if Shredded_selfTrack and Shredded_selfTrack.player then
                local tracked = 0
                for k, v in pairs(Shredded_selfTrack.player) do
                    tracked = tracked + 1
                    local remaining = v.expirationTime and (v.expirationTime - GetTime()) or 0
                    local src = v.fromCooldown and "[CD]" or (v.fromCast and "[ShreddedT]" or (v.fromAPI and "[API]" or (v.fromDirectLookup and "[DIRECT]" or (v.fromPoll and "[POLL]" or "[OTHER]"))))
                    addLine("  " .. k .. ": " .. string.format("%.1f", remaining) .. "s " .. src)
                end
                if tracked == 0 then
                    addLine("  (none)")
                end
                addLine("Total: " .. tracked)
            end
            addLine("")
            
            -- Check target tracking
            addLine("--- Self-Tracked Target Auras (via CD/Cast) ---")
            if Shredded_selfTrack and Shredded_selfTrack.target then
                local tracked = 0
                for k, v in pairs(Shredded_selfTrack.target) do
                    tracked = tracked + 1
                    local remaining = v.expirationTime and (v.expirationTime - GetTime()) or 0
                    local src = v.fromCast and "[ShreddedT]" or (v.fromAPI and "[API]" or "[?]")
                    addLine("  " .. k .. ": " .. string.format("%.1f", remaining) .. "s " .. src)
                end
                if tracked == 0 then
                    addLine("  (none)")
                end
                addLine("Total: " .. tracked)
            end
            addLine("")
            
            -- Check auraRawData
            addLine("--- auraRawData (what bars use) ---")
            if Shredded_auraRawData then
                local raw = 0
                for k, v in pairs(Shredded_auraRawData) do
                    raw = raw + 1
                    local remaining = v.expirationTime and (v.expirationTime - GetTime()) or 0
                    addLine("  " .. k .. ": " .. string.format("%.1f", remaining) .. "s")
                end
                if raw == 0 then
                    addLine("  (none)")
                end
                addLine("Total: " .. raw)
            end
            
            -- Show in popup
            Shredded_ShowDebugPopup(table.concat(lines, "\n"))
        else
            Shredded_OpenOptions()
        end
    end
    _G.SLASH_Shredded1 = "/shredded"
    _G.SLASH_Shredded2 = "/shredded"
    
    -- Quick debug shortcut
    _G.SLASH_ShreddedD1 = "/shreddedd"
    SlashCmdList["ShreddedD"] = function(msg)
        SlashCmdList["Shredded"]("debug")
    end
end

-- ===========================================
-- OPTIONS PANEL SETUP (Modern API)
-- ===========================================

local optionsPanel = nil
local optionsCategory = nil

local function CreateOptionsPanel()
    optionsPanel = CreateFrame("Frame", "ShreddedOptions", UIParent)
    optionsPanel.name = "Shredded"
    
    -- Title
    local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Shredded - Feral Combat Tracker")
    
    -- Version
    local version = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    version:SetText("Version 3.0.0 - The War Within")
    
    -- Description
    local desc = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -16)
    desc:SetWidth(550)
    desc:SetJustifyH("LEFT")
    desc:SetText("Shredded tracks your Feral Druid DoTs, procs, buffs, energy and combo points.\n\nUse /shredded move to reposition the Timer Bars and Proc Icons.\nUse /shredded reset to restore default settings.")
    
    -- Move Frames Button
    local moveBtn = CreateFrame("Button", "ShreddedOptionsMove", optionsPanel, "UIPanelButtonTemplate")
    moveBtn:SetSize(180, 30)
    moveBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
    moveBtn:SetText("Move Frames")
    moveBtn:SetScript("OnClick", function()
        Shredded_Move()
    end)
    
    -- Reset Settings Button
    local resetBtn = CreateFrame("Button", "ShreddedOptionsReset", optionsPanel, "UIPanelButtonTemplate")
    resetBtn:SetSize(180, 30)
    resetBtn:SetPoint("LEFT", moveBtn, "RIGHT", 20, 0)
    resetBtn:SetText("Reset to Defaults")
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("Shredded_RESET_CONFIRM")
    end)
    
    -- Create reset confirmation dialog
    StaticPopupDialogs["Shredded_RESET_CONFIRM"] = {
        text = "Are you sure you want to reset all Shredded settings to defaults?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            ShreddedDefaultSettings()
            Shredded_Refresh()
            ShreddedO("Settings reset to defaults!")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    
    return optionsPanel
end

-- ===========================================
-- PROC ICONS PANEL (ability toggles + ordering)
-- ===========================================

local cooldownLayoutPanel = nil

local function CreateCooldownLayoutPanel()
    cooldownLayoutPanel = CreateFrame("Frame", "ShreddedOptionsCooldownLayout", UIParent)
    cooldownLayoutPanel.name = "Proc Icons"
    
    -- Title
    local title = cooldownLayoutPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Proc Icons Options")
    
    -- Enable Cooldowns Checkbox
    local enableCooldowns = CreateFrame("CheckButton", "ShreddedOptionsCooldownToggle", cooldownLayoutPanel, "InterfaceOptionsCheckButtonTemplate")
    enableCooldowns:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -15)
    SetButtonText(enableCooldowns, "Enable Proc Icons")
    enableCooldowns:SetScript("OnClick", function(self)
        ShreddedSettings["cooldownson"] = self:GetChecked()
        Shredded_Refresh()
    end)
    
    -- Hide Out of Combat
    local combatToggle = CreateFrame("CheckButton", "ShreddedOptionsCooldownCombat", cooldownLayoutPanel, "InterfaceOptionsCheckButtonTemplate")
    combatToggle:SetPoint("TOPLEFT", enableCooldowns, "BOTTOMLEFT", 0, -2)
    SetButtonText(combatToggle, "Hide Out of Combat")
    combatToggle:SetScript("OnClick", function(self)
        ShreddedSettings["cooldowncombat"] = self:GetChecked()
    end)
    
    -- Cooldown Threshold Slider
    local thresholdLabel = cooldownLayoutPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    thresholdLabel:SetPoint("TOPLEFT", combatToggle, "BOTTOMLEFT", 0, -15)
    thresholdLabel:SetText("Alert Threshold (sec)")
    
    local thresholdSlider = CreateFrame("Slider", "ShreddedOptionsCooldownThreshold", cooldownLayoutPanel, "OptionsSliderTemplate")
    thresholdSlider:SetPoint("TOPLEFT", thresholdLabel, "BOTTOMLEFT", 0, -10)
    thresholdSlider:SetMinMaxValues(1, 15)
    thresholdSlider:SetValueStep(1)
    thresholdSlider:SetObeyStepOnDrag(true)
    thresholdSlider:SetWidth(150)
    thresholdSlider.Low:SetText("1")
    thresholdSlider.High:SetText("15")
    thresholdSlider:SetScript("OnValueChanged", function(self, value)
        Shredded_CooldownThreshold(floor(value))
        self.Text:SetText(floor(value) .. "s")
    end)
    
    -- Icons per Row slider
    local widthLabel = cooldownLayoutPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    widthLabel:SetPoint("TOPLEFT", thresholdSlider, "BOTTOMLEFT", 0, -20)
    widthLabel:SetText("Icons per Row")
    
    local widthSlider = CreateFrame("Slider", "ShreddedOptionsCooldownWidth", cooldownLayoutPanel, "OptionsSliderTemplate")
    widthSlider:SetPoint("TOPLEFT", widthLabel, "BOTTOMLEFT", 0, -10)
    widthSlider:SetMinMaxValues(1, 12)
    widthSlider:SetValueStep(1)
    widthSlider:SetObeyStepOnDrag(true)
    widthSlider:SetWidth(150)
    widthSlider.Low:SetText("1")
    widthSlider.High:SetText("12")
    widthSlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["cooldownlayout"]["width"] = floor(value)
        self.Text:SetText(floor(value))
        Shredded_Refresh()
    end)
    
    -- =============================================
    -- RIGHT SIDE: Ability Order List with Up/Down
    -- =============================================
    
    local orderLabel = cooldownLayoutPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    orderLabel:SetPoint("TOPLEFT", 280, -50)
    orderLabel:SetText("Proc Icon Priority (top = first icon)")
    
    local availNote = cooldownLayoutPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    availNote:SetPoint("TOPLEFT", orderLabel, "BOTTOMLEFT", 0, -2)
    availNote:SetText("|cFF888888Greyed = not available with current talents|r")
    
    -- Scroll frame for ability list (many more items now)
    local scrollFrame = CreateFrame("ScrollFrame", "ShreddedCooldownOrderScroll", cooldownLayoutPanel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", availNote, "BOTTOMLEFT", 0, -5)
    scrollFrame:SetSize(280, 320)
    
    local listContainer = CreateFrame("Frame", "ShreddedCooldownOrderList", scrollFrame)
    listContainer:SetSize(260, 800)  -- Tall enough for all abilities
    scrollFrame:SetScrollChild(listContainer)
    
    -- Store row references
    local abilityRows = {}
    
    local function RefreshAbilityOrder()
        -- Hide all existing rows
        for _, row in pairs(abilityRows) do
            if row.frame then row.frame:Hide() end
        end
        
        -- Initialize priority if needed
        if not ShreddedSettings["cooldownpriority"] then
            ShreddedSettings["cooldownpriority"] = {}
        end
        if not ShreddedSettings["cooldownon"] then
            ShreddedSettings["cooldownon"] = {}
        end
        
        -- Ensure all spells have priority values
        for idx, key in ipairs(ShreddedCooldownSpells) do
            if not ShreddedSettings["cooldownpriority"][key] then
                ShreddedSettings["cooldownpriority"][key] = idx
            end
        end
        
        -- Build sorted list of spells by priority (ASCENDING for display - priority 1 = first icon position)
        local sortedSpells = {}
        for idx, key in ipairs(ShreddedCooldownSpells) do
            local priority = ShreddedSettings["cooldownpriority"][key] or idx
            local enabled = ShreddedSettings["cooldownon"][key] ~= false
            local available = PlayerHasSpell(key)
            table.insert(sortedSpells, { key = key, priority = priority, enabled = enabled, available = available })
        end
        table.sort(sortedSpells, function(a, b) return a.priority < b.priority end)  -- Ascending: priority 1 first
        
        -- Create/update rows
        for i, data in ipairs(sortedSpells) do
            local spellKey = data.key
            local isAvailable = data.available
            
            if not abilityRows[spellKey] then
                local row = CreateFrame("Frame", nil, listContainer)
                row:SetSize(240, 22)
                
                -- Checkbox
                local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                check:SetPoint("LEFT", 0, 0)
                check:SetSize(22, 22)
                check.spellKey = spellKey
                check:SetScript("OnClick", function(self)
                    if not PlayerHasSpell(self.spellKey) then
                        self:SetChecked(false)
                        return
                    end
                    ShreddedSettings["cooldownon"][self.spellKey] = self:GetChecked()
                    if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
                end)
                
                -- Spell name
                local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                label:SetPoint("LEFT", check, "RIGHT", 2, 0)
                label:SetWidth(115)
                label:SetJustifyH("LEFT")
                label:SetText(GetSpellDisplayName(spellKey))
                
                -- Tooltip on hover
                row:EnableMouse(true)
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(GetSpellDisplayName(self.spellKey), 1, 1, 1)
                    local tipText = GetSpellTooltip(self.spellKey)
                    if tipText and tipText ~= "" then
                        GameTooltip:AddLine(tipText, nil, nil, nil, true)
                    end
                    if not PlayerHasSpell(self.spellKey) then
                        GameTooltip:AddLine("|cFFFF4444Not available - talent not selected|r", nil, nil, nil, true)
                    end
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.spellKey = spellKey
                
                -- Move Up button
                local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                upBtn:SetSize(26, 18)
                upBtn:SetPoint("LEFT", label, "RIGHT", 5, 0)
                upBtn:SetText("Up")
                upBtn.spellKey = spellKey
                upBtn:SetScript("OnClick", function(self)
                    local currentPriority = ShreddedSettings["cooldownpriority"][self.spellKey] or 1
                    if currentPriority > 1 then
                        -- Find spell with priority one less and swap
                        for key, pri in pairs(ShreddedSettings["cooldownpriority"]) do
                            if pri == currentPriority - 1 then
                                ShreddedSettings["cooldownpriority"][key] = currentPriority
                                break
                            end
                        end
                        ShreddedSettings["cooldownpriority"][self.spellKey] = currentPriority - 1
                        RefreshAbilityOrder()
                        if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
                    end
                end)
                
                -- Move Down button
                local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                downBtn:SetSize(26, 18)
                downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
                downBtn:SetText("Dn")
                downBtn.spellKey = spellKey
                downBtn:SetScript("OnClick", function(self)
                    local currentPriority = ShreddedSettings["cooldownpriority"][self.spellKey] or 1
                    local maxPriority = #ShreddedCooldownSpells
                    if currentPriority < maxPriority then
                        -- Find spell with priority one more and swap
                        for key, pri in pairs(ShreddedSettings["cooldownpriority"]) do
                            if pri == currentPriority + 1 then
                                ShreddedSettings["cooldownpriority"][key] = currentPriority
                                break
                            end
                        end
                        ShreddedSettings["cooldownpriority"][self.spellKey] = currentPriority + 1
                        RefreshAbilityOrder()
                        if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
                    end
                end)
                
                abilityRows[spellKey] = {
                    frame = row,
                    check = check,
                    label = label,
                    upBtn = upBtn,
                    downBtn = downBtn
                }
            end
            
            local row = abilityRows[spellKey]
            row.frame:Show()
            row.frame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 0, -(i-1) * 24)
            row.check:SetChecked(data.enabled and isAvailable)
            
            -- Show position number and handle availability
            local displayName = GetSpellDisplayName(spellKey)
            row.label:SetText(i .. ". " .. displayName)
            
            if isAvailable then
                row.label:SetTextColor(1, 1, 1)  -- White for available
                row.check:Enable()
                row.upBtn:Enable()
                row.downBtn:Enable()
            else
                row.label:SetTextColor(0.5, 0.5, 0.5)  -- Grey for unavailable
                row.check:Disable()
                row.check:SetChecked(false)
                row.upBtn:Disable()
                row.downBtn:Disable()
            end
        end
    end
    
    -- OnShow
    cooldownLayoutPanel:SetScript("OnShow", function()
        RefreshAbilityOrder()
        
        if ShreddedSettings then
            enableCooldowns:SetChecked(ShreddedSettings["cooldownson"])
            combatToggle:SetChecked(ShreddedSettings["cooldowncombat"])
            
            local threshVal = ShreddedSettings["cooldowntime"] and ShreddedSettings["cooldowntime"]["RIP"] or 5
            thresholdSlider:SetValue(threshVal)
            thresholdSlider.Text:SetText(floor(threshVal) .. "s")
            
            local layoutWidth = ShreddedSettings["cooldownlayout"] and ShreddedSettings["cooldownlayout"]["width"] or 4
            widthSlider:SetValue(layoutWidth)
            widthSlider.Text:SetText(floor(layoutWidth))
        end
        
        if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
    end)
    
    return cooldownLayoutPanel
end

-- ===========================================
-- PROC VISUALS PANEL (size, font, opacity)
-- ===========================================

local cooldownVisualsPanel = nil

local function CreateCooldownVisualsPanel()
    cooldownVisualsPanel = CreateFrame("Frame", "ShreddedOptionsCooldownVisuals", UIParent)
    cooldownVisualsPanel.name = "Proc Visuals"
    
    -- Title
    local title = cooldownVisualsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Proc Icon Visual Options")
    
    -- Cooldown Size Slider
    local sizeLabel = cooldownVisualsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -30)
    sizeLabel:SetText("Proc Icon Size")
    
    local sizeSlider = CreateFrame("Slider", "ShreddedOptionsCooldownSize", cooldownVisualsPanel, "OptionsSliderTemplate")
    sizeSlider:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", 0, -10)
    sizeSlider:SetMinMaxValues(20, 80)
    sizeSlider:SetValueStep(1)
    sizeSlider:SetObeyStepOnDrag(true)
    sizeSlider:SetWidth(200)
    sizeSlider.Low:SetText("20")
    sizeSlider.High:SetText("80")
    sizeSlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["cooldownsize"] = floor(value)
        self.Text:SetText(floor(value))
        Shredded_Refresh()
    end)
    sizeSlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["cooldownsize"] or 40)
    end)
    
    -- Cooldown Font Size Slider
    local fontLabel = cooldownVisualsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -30)
    fontLabel:SetText("Cooldown Font Size")
    
    local fontSlider = CreateFrame("Slider", "ShreddedOptionsCooldownFont", cooldownVisualsPanel, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -10)
    fontSlider:SetMinMaxValues(8, 36)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)
    fontSlider:SetWidth(200)
    fontSlider.Low:SetText("8")
    fontSlider.High:SetText("36")
    fontSlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["cooldownfont"] = floor(value)
        self.Text:SetText(floor(value))
        Shredded_Refresh()
    end)
    fontSlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["cooldownfont"] or 24)
    end)
    
    -- Cooldown Opacity Slider
    local opacityLabel = cooldownVisualsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    opacityLabel:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 0, -30)
    opacityLabel:SetText("Cooldown Opacity")
    
    local opacitySlider = CreateFrame("Slider", "ShreddedOptionsCooldownOpacity", cooldownVisualsPanel, "OptionsSliderTemplate")
    opacitySlider:SetPoint("TOPLEFT", opacityLabel, "BOTTOMLEFT", 0, -10)
    opacitySlider:SetMinMaxValues(0.1, 1)
    opacitySlider:SetValueStep(0.05)
    opacitySlider:SetObeyStepOnDrag(true)
    opacitySlider:SetWidth(200)
    opacitySlider.Low:SetText("10%")
    opacitySlider.High:SetText("100%")
    opacitySlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["cooldownalpha"] = value
        self.Text:SetText(floor(value * 100) .. "%")
        Shredded_Refresh()
    end)
    opacitySlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["cooldownalpha"] or 0.85)
    end)
    
    -- Rest Opacity Slider (show icons when not active)
    local restOpacityLabel = cooldownVisualsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    restOpacityLabel:SetPoint("TOPLEFT", opacitySlider, "BOTTOMLEFT", 0, -30)
    restOpacityLabel:SetText("Rest Opacity (0 = hidden when inactive)")
    
    local restOpacitySlider = CreateFrame("Slider", "ShreddedOptionsCooldownRestOpacity", cooldownVisualsPanel, "OptionsSliderTemplate")
    restOpacitySlider:SetPoint("TOPLEFT", restOpacityLabel, "BOTTOMLEFT", 0, -10)
    restOpacitySlider:SetMinMaxValues(0, 1)
    restOpacitySlider:SetValueStep(0.05)
    restOpacitySlider:SetObeyStepOnDrag(true)
    restOpacitySlider:SetWidth(200)
    restOpacitySlider.Low:SetText("0%")
    restOpacitySlider.High:SetText("100%")
    restOpacitySlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["cooldownrestalpha"] = value
        self.Text:SetText(floor(value * 100) .. "%")
        Shredded_Refresh()
    end)
    restOpacitySlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["cooldownrestalpha"] or 0)
    end)
    
    -- OnShow
    cooldownVisualsPanel:SetScript("OnShow", function()
        if ShreddedSettings then
            local cdSize = ShreddedSettings["cooldownsize"] or 40
            sizeSlider:SetValue(cdSize)
            sizeSlider.Text:SetText(floor(cdSize))
            
            local cdFont = ShreddedSettings["cooldownfont"] or 24
            fontSlider:SetValue(cdFont)
            fontSlider.Text:SetText(floor(cdFont))
            
            local cdOpacity = ShreddedSettings["cooldownalpha"] or 0.85
            opacitySlider:SetValue(cdOpacity)
            opacitySlider.Text:SetText(floor(cdOpacity * 100) .. "%")
        end
        
        if Shredded_CooldownPersonality then Shredded_CooldownPersonality() end
    end)
    
    return cooldownVisualsPanel
end

-- ===========================================
-- TIMER BARS OPTIONS PANEL
-- ===========================================

local barPanel = nil

local function CreateBarPanel()
    barPanel = CreateFrame("Frame", "ShreddedOptionsBar", UIParent)
    barPanel.name = "Timer Bars"
    
    -- Title
    local title = barPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Timer Bars Options")
    
    -- TOP: 2x2 checkbox layout
    -- Row 1, Column 1: Enable Bars
    local enableBars = CreateFrame("CheckButton", "ShreddedOptionsBarCatToggle", barPanel, "InterfaceOptionsCheckButtonTemplate")
    enableBars:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    SetButtonText(enableBars, "Enable Timer Bars")
    enableBars:SetScript("OnClick", function(self)
        ShreddedSettings["catbarson"] = self:GetChecked()
        Shredded_Refresh()
    end)
    enableBars:SetScript("OnShow", function(self)
        self:SetChecked(ShreddedSettings["catbarson"])
    end)
    
    -- Row 1, Column 2: Hide Out of Combat
    local combatToggle = CreateFrame("CheckButton", "ShreddedOptionsBarCombat", barPanel, "InterfaceOptionsCheckButtonTemplate")
    combatToggle:SetPoint("LEFT", enableBars, "RIGHT", 180, 0)
    SetButtonText(combatToggle, "Hide Timer Bars Out of Combat")
    combatToggle:SetScript("OnClick", function(self)
        ShreddedSettings["barcombat"] = self:GetChecked()
    end)
    combatToggle:SetScript("OnShow", function(self)
        self:SetChecked(ShreddedSettings["barcombat"])
    end)
    
    -- Row 2, Column 1: Static Bar Order
    local lockToggle = CreateFrame("CheckButton", "ShreddedOptionsBarLock", barPanel, "InterfaceOptionsCheckButtonTemplate")
    lockToggle:SetPoint("TOPLEFT", enableBars, "BOTTOMLEFT", 0, -5)
    SetButtonText(lockToggle, "Static Bar Order (Don't auto-sort)")
    lockToggle:SetScript("OnClick", function(self)
        ShreddedSettings["barlock"] = self:GetChecked()
        Shredded_Refresh()
    end)
    lockToggle:SetScript("OnShow", function(self)
        self:SetChecked(ShreddedSettings["barlock"])
    end)
    
    -- Row 2, Column 2: Show When Zero
    local zeroToggle = CreateFrame("CheckButton", "ShreddedOptionsBarZero", barPanel, "InterfaceOptionsCheckButtonTemplate")
    zeroToggle:SetPoint("LEFT", lockToggle, "RIGHT", 180, 0)
    SetButtonText(zeroToggle, "Show Timer Bars When Timer is Zero")
    zeroToggle:SetScript("OnClick", function(self)
        ShreddedSettings["barzero"] = self:GetChecked()
    end)
    zeroToggle:SetScript("OnShow", function(self)
        self:SetChecked(ShreddedSettings["barzero"])
    end)
    
    -- =============================================
    -- BOTTOM: Bar Order List (3 columns, 15 each)
    -- =============================================
    
    local orderLabel = barPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    orderLabel:SetPoint("TOPLEFT", lockToggle, "BOTTOMLEFT", 0, -20)
    orderLabel:SetText("Timer Bar Priority (top = first bar)")
    
    local availNote = barPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    availNote:SetPoint("TOPLEFT", orderLabel, "BOTTOMLEFT", 0, -2)
    availNote:SetText("|cFF888888Greyed = not available with current talents|r")
    
    -- Container frame for bar list (3 columns)
    local barListContainer = CreateFrame("Frame", "ShreddedBarOrderList", barPanel)
    barListContainer:SetPoint("TOPLEFT", availNote, "BOTTOMLEFT", 0, -5)
    barListContainer:SetSize(620, 340)  -- Wide enough for 3 columns
    
    -- Store row references
    local barRows = {}
    
    local function RefreshBarOrder()
        -- Hide all existing rows
        for _, row in pairs(barRows) do
            if row.frame then row.frame:Hide() end
        end
        
        -- Initialize priority if needed
        if not ShreddedSettings["barpriority"] then
            ShreddedSettings["barpriority"] = {}
        end
        if not ShreddedSettings["baron"] then
            ShreddedSettings["baron"] = {}
        end
        
        -- Get the spell list - use ShreddedCatSpells if available, with robust fallback
        local spellList = {}
        if ShreddedCatSpells and type(ShreddedCatSpells) == "table" and #ShreddedCatSpells > 0 then
            spellList = ShreddedCatSpells
        else
            -- Comprehensive fallback list of all possible spells
            spellList = {
                "TIGERS_FURY", "CLEARCASTING", "BLOODTALONS", "PREDATORY_SWIFTNESS",
                "SUDDEN_AMBUSH", "APEX_PREDATOR", "BERSERK", "INCARNATION",
                "RIP", "RAKE", "THRASH", "MOONFIRE_CAT",
                "ENERGY", "COMBO"
            }
        end
        
        if #spellList == 0 then return end
        
        -- Ensure all spells have priority values
        for idx, key in ipairs(spellList) do
            if not ShreddedSettings["barpriority"][key] then
                ShreddedSettings["barpriority"][key] = idx
            end
        end
        
        -- Build sorted list of spells by priority (ASCENDING - priority 1 = first bar position)
        local sortedSpells = {}
        for idx, key in ipairs(spellList) do
            local priority = ShreddedSettings["barpriority"][key] or idx
            local enabled = ShreddedSettings["baron"][key] ~= false
            local available = PlayerHasSpell(key)
            table.insert(sortedSpells, { key = key, priority = priority, enabled = enabled, available = available })
        end
        table.sort(sortedSpells, function(a, b) return a.priority < b.priority end)  -- Ascending: priority 1 first
        
        -- Create/update rows (3 columns layout, 15 items per column)
        local itemsPerColumn = 15
        
        for i, data in ipairs(sortedSpells) do
            local spellKey = data.key
            local isAvailable = data.available
            
            if not barRows[spellKey] then
                local row = CreateFrame("Frame", nil, barListContainer)
                row:SetSize(200, 20)
                
                -- Checkbox
                local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                check:SetPoint("LEFT", 0, 0)
                check:SetSize(20, 20)
                check.spellKey = spellKey
                check:SetScript("OnClick", function(self)
                    if not PlayerHasSpell(self.spellKey) then
                        self:SetChecked(false)
                        return
                    end
                    ShreddedSettings["baron"][self.spellKey] = self:GetChecked()
                    if Shredded_BarPersonality then Shredded_BarPersonality() end
                    Shredded_Refresh()
                end)
                
                -- Spell name
                local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                label:SetPoint("LEFT", check, "RIGHT", 2, 0)
                label:SetWidth(85)
                label:SetJustifyH("LEFT")
                label:SetText(GetSpellDisplayName(spellKey))
                
                -- Tooltip on hover
                row:EnableMouse(true)
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(GetSpellDisplayName(self.spellKey), 1, 1, 1)
                    local tipText = GetSpellTooltip(self.spellKey)
                    if tipText and tipText ~= "" then
                        GameTooltip:AddLine(tipText, nil, nil, nil, true)
                    end
                    if not PlayerHasSpell(self.spellKey) then
                        GameTooltip:AddLine("|cFFFF4444Not available - talent not selected|r", nil, nil, nil, true)
                    end
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.spellKey = spellKey
                
                -- Move Up button
                local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                upBtn:SetSize(22, 16)
                upBtn:SetPoint("LEFT", label, "RIGHT", 2, 0)
                upBtn:SetText("Up")
                upBtn.spellKey = spellKey
                upBtn:SetScript("OnClick", function(self)
                    local currentPriority = ShreddedSettings["barpriority"][self.spellKey] or 1
                    if currentPriority > 1 then
                        -- Find spell with priority one less and swap
                        for key, pri in pairs(ShreddedSettings["barpriority"]) do
                            if pri == currentPriority - 1 then
                                ShreddedSettings["barpriority"][key] = currentPriority
                                break
                            end
                        end
                        ShreddedSettings["barpriority"][self.spellKey] = currentPriority - 1
                        RefreshBarOrder()
                        if Shredded_BarPersonality then Shredded_BarPersonality() end
                        Shredded_Refresh()
                    end
                end)
                
                -- Move Down button
                local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                downBtn:SetSize(22, 16)
                downBtn:SetPoint("LEFT", upBtn, "RIGHT", 1, 0)
                downBtn:SetText("Dn")
                downBtn.spellKey = spellKey
                downBtn:SetScript("OnClick", function(self)
                    local currentPriority = ShreddedSettings["barpriority"][self.spellKey] or 1
                    local maxPriority = #spellList
                    if currentPriority < maxPriority then
                        -- Find spell with priority one more and swap
                        for key, pri in pairs(ShreddedSettings["barpriority"]) do
                            if pri == currentPriority + 1 then
                                ShreddedSettings["barpriority"][key] = currentPriority
                                break
                            end
                        end
                        ShreddedSettings["barpriority"][self.spellKey] = currentPriority + 1
                        RefreshBarOrder()
                        if Shredded_BarPersonality then Shredded_BarPersonality() end
                        Shredded_Refresh()
                    end
                end)
                
                barRows[spellKey] = {
                    frame = row,
                    check = check,
                    label = label,
                    upBtn = upBtn,
                    downBtn = downBtn
                }
            end
            
            local row = barRows[spellKey]
            row.frame:Show()
            
            -- Position in 3-column layout (15 items per column)
            local col = math.floor((i - 1) / itemsPerColumn)  -- 0, 1, or 2
            local rowInCol = (i - 1) % itemsPerColumn  -- 0 to 14
            local xOffset = col * 210
            local yOffset = -rowInCol * 22
            row.frame:SetPoint("TOPLEFT", barListContainer, "TOPLEFT", xOffset, yOffset)
            row.check:SetChecked(data.enabled and isAvailable)
            
            -- Show position number and handle availability
            local displayName = GetSpellDisplayName(spellKey)
            row.label:SetText(i .. ". " .. displayName)
            
            if isAvailable then
                row.label:SetTextColor(1, 1, 1)  -- White for available
                row.check:Enable()
                row.upBtn:Enable()
                row.downBtn:Enable()
            else
                row.label:SetTextColor(0.5, 0.5, 0.5)  -- Grey for unavailable
                row.check:Disable()
                row.check:SetChecked(false)
                row.upBtn:Disable()
                row.downBtn:Disable()
            end
        end
    end
    
    -- OnShow
    barPanel:SetScript("OnShow", function()
        RefreshBarOrder()
        
        if ShreddedSettings then
            enableBars:SetChecked(ShreddedSettings["catbarson"])
            combatToggle:SetChecked(ShreddedSettings["barcombat"])
            lockToggle:SetChecked(ShreddedSettings["barlock"])
            zeroToggle:SetChecked(ShreddedSettings["barzero"])
        end
        
        if Shredded_BarPersonality then Shredded_BarPersonality() end
    end)
    
    -- Also do initial population after a short delay (for first load)
    C_Timer.After(0.5, function()
        if barPanel:IsVisible() then
            RefreshBarOrder()
        end
    end)
    
    return barPanel
end

-- ===========================================
-- TIMER VISUALS OPTIONS PANEL
-- ===========================================

local barColorPanel = nil

local function CreateBarColorPanel()
    barColorPanel = CreateFrame("Frame", "ShreddedOptionsBarColor", UIParent)
    barColorPanel.name = "Timer Visuals"
    
    -- Title
    local title = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Timer Bar Visual Options")
    
    -- Bar Width Slider
    local widthLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    widthLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    widthLabel:SetText("Bar Width")
    
    local widthSlider = CreateFrame("Slider", "ShreddedOptionsBarColorWidth", barColorPanel, "OptionsSliderTemplate")
    widthSlider:SetPoint("TOPLEFT", widthLabel, "BOTTOMLEFT", 0, -10)
    widthSlider:SetMinMaxValues(80, 300)
    widthSlider:SetValueStep(5)
    widthSlider:SetObeyStepOnDrag(true)
    widthSlider:SetWidth(200)
    widthSlider.Low:SetText("80")
    widthSlider.High:SetText("300")
    widthSlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["barwidth"] = floor(value)
        self.Text:SetText(floor(value))
        Shredded_Refresh()
    end)
    widthSlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["barwidth"] or 150)
    end)
    
    -- Bar Height Slider
    local heightLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heightLabel:SetPoint("TOPLEFT", widthSlider, "BOTTOMLEFT", 0, -30)
    heightLabel:SetText("Bar Height")
    
    local heightSlider = CreateFrame("Slider", "ShreddedOptionsBarColorHeight", barColorPanel, "OptionsSliderTemplate")
    heightSlider:SetPoint("TOPLEFT", heightLabel, "BOTTOMLEFT", 0, -10)
    heightSlider:SetMinMaxValues(10, 40)
    heightSlider:SetValueStep(1)
    heightSlider:SetObeyStepOnDrag(true)
    heightSlider:SetWidth(200)
    heightSlider.Low:SetText("10")
    heightSlider.High:SetText("40")
    heightSlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["barheight"] = floor(value)
        self.Text:SetText(floor(value))
        Shredded_Refresh()
    end)
    heightSlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["barheight"] or 18)
    end)
    
    -- Bar Font Size Slider
    local fontLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", heightSlider, "BOTTOMLEFT", 0, -30)
    fontLabel:SetText("Bar Font Size")
    
    local fontSlider = CreateFrame("Slider", "ShreddedOptionsBarColorFont", barColorPanel, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -10)
    fontSlider:SetMinMaxValues(6, 20)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)
    fontSlider:SetWidth(200)
    fontSlider.Low:SetText("6")
    fontSlider.High:SetText("20")
    fontSlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["barfont"] = floor(value)
        self.Text:SetText(floor(value))
        Shredded_Refresh()
    end)
    fontSlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["barfont"] or 11)
    end)
    
    -- Bar Opacity Slider
    local opacityLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    opacityLabel:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 0, -30)
    opacityLabel:SetText("Bar Opacity")
    
    local opacitySlider = CreateFrame("Slider", "ShreddedOptionsBarColorOpacity", barColorPanel, "OptionsSliderTemplate")
    opacitySlider:SetPoint("TOPLEFT", opacityLabel, "BOTTOMLEFT", 0, -10)
    opacitySlider:SetMinMaxValues(0.1, 1)
    opacitySlider:SetValueStep(0.05)
    opacitySlider:SetObeyStepOnDrag(true)
    opacitySlider:SetWidth(200)
    opacitySlider.Low:SetText("10%")
    opacitySlider.High:SetText("100%")
    opacitySlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["baralpha"] = value
        self.Text:SetText(floor(value * 100) .. "%")
        Shredded_Refresh()
    end)
    opacitySlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["baralpha"] or 0.9)
    end)
    
    -- Background Opacity Slider
    local bgOpacityLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    bgOpacityLabel:SetPoint("TOPLEFT", opacitySlider, "BOTTOMLEFT", 0, -30)
    bgOpacityLabel:SetText("Background Opacity")
    
    local bgOpacitySlider = CreateFrame("Slider", "ShreddedOptionsBarColorBackgroundOpacity", barColorPanel, "OptionsSliderTemplate")
    bgOpacitySlider:SetPoint("TOPLEFT", bgOpacityLabel, "BOTTOMLEFT", 0, -10)
    bgOpacitySlider:SetMinMaxValues(0, 1)
    bgOpacitySlider:SetValueStep(0.05)
    bgOpacitySlider:SetObeyStepOnDrag(true)
    bgOpacitySlider:SetWidth(200)
    bgOpacitySlider.Low:SetText("0%")
    bgOpacitySlider.High:SetText("100%")
    bgOpacitySlider:SetScript("OnValueChanged", function(self, value)
        ShreddedSettings["barbackalpha"] = value
        self.Text:SetText(floor(value * 100) .. "%")
        Shredded_Refresh()
    end)
    bgOpacitySlider:SetScript("OnShow", function(self)
        self:SetValue(ShreddedSettings["barbackalpha"] or 0.4)
    end)
    
    -- Texture Dropdown
    local textureLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    textureLabel:SetPoint("TOPLEFT", 280, -50)
    textureLabel:SetText("Bar Texture")
    
    local textureDropdown = CreateFrame("Frame", "ShreddedOptionsBarTextureDropdown", barColorPanel, "UIDropDownMenuTemplate")
    textureDropdown:SetPoint("TOPLEFT", textureLabel, "BOTTOMLEFT", -15, -5)
    
    local textures = {
        {name = "Blizzard", path = [[Interface\TargetingFrame\UI-StatusBar]]},
        {name = "Aluminium", path = [[Interface\Addons\Shredded\bars\Aluminium]]},
        {name = "Armory", path = [[Interface\Addons\Shredded\bars\Armory]]},
        {name = "BantoBar", path = [[Interface\Addons\Shredded\bars\BantoBar.tga]]},
        {name = "Glaze2", path = [[Interface\Addons\Shredded\bars\Glaze2]]},
        {name = "Gloss", path = [[Interface\Addons\Shredded\bars\Gloss]]},
        {name = "Graphite", path = [[Interface\Addons\Shredded\bars\Graphite]]},
        {name = "Grid", path = [[Interface\Addons\Shredded\bars\Grid]]},
        {name = "Healbot", path = [[Interface\Addons\Shredded\bars\Healbot]]},
        {name = "LiteStep", path = [[Interface\Addons\Shredded\bars\LiteStep]]},
        {name = "Minimalist", path = [[Interface\Addons\Shredded\bars\Minimalist]]},
        {name = "Otravi", path = [[Interface\Addons\Shredded\bars\Otravi]]},
        {name = "Outline", path = [[Interface\Addons\Shredded\bars\Outline]]},
        {name = "Perl", path = [[Interface\Addons\Shredded\bars\Perl]]},
        {name = "Round", path = [[Interface\Addons\Shredded\bars\Round]]},
        {name = "Smooth", path = [[Interface\Addons\Shredded\bars\Smooth]]},
    }
    
    local function TextureDropdown_OnClick(self, arg1, arg2, checked)
        ShreddedSettings["bartexture"] = arg1
        ShreddedSettings["bartexturename"] = arg2
        UIDropDownMenu_SetText(textureDropdown, arg2)
        Shredded_Refresh()
    end
    
    local function TextureDropdown_Initialize(self, level)
        local info = UIDropDownMenu_CreateInfo()
        for _, tex in ipairs(textures) do
            info.text = tex.name
            info.arg1 = tex.path
            info.arg2 = tex.name
            info.func = TextureDropdown_OnClick
            info.checked = (ShreddedSettings["bartexturename"] == tex.name)
            UIDropDownMenu_AddButton(info, level)
        end
    end
    
    UIDropDownMenu_Initialize(textureDropdown, TextureDropdown_Initialize)
    UIDropDownMenu_SetWidth(textureDropdown, 150)
    
    textureDropdown:SetScript("OnShow", function(self)
        UIDropDownMenu_SetText(self, ShreddedSettings["bartexturename"] or "BantoBar")
    end)
    
    -- Bar Color Options Label
    local colorLabel = barColorPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    colorLabel:SetPoint("TOPLEFT", textureDropdown, "BOTTOMLEFT", 15, -30)
    colorLabel:SetText("Click to change bar colors:")
    
    -- Container for color buttons (will be populated dynamically)
    local colorContainer = CreateFrame("Frame", nil, barColorPanel)
    colorContainer:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -10)
    colorContainer:SetSize(400, 200)
    
    local colorButtons = {}
    
    local function RefreshColorButtons()
        -- Hide existing buttons
        for _, btn in pairs(colorButtons) do
            btn:Hide()
        end
        
        -- Get spell list with robust fallback
        local spellList = {}
        if ShreddedCatSpells and type(ShreddedCatSpells) == "table" and #ShreddedCatSpells > 0 then
            spellList = ShreddedCatSpells
        else
            -- Comprehensive fallback list
            spellList = {
                "TIGERS_FURY", "CLEARCASTING", "BLOODTALONS", "PREDATORY_SWIFTNESS",
                "SUDDEN_AMBUSH", "APEX_PREDATOR", "BERSERK", "INCARNATION",
                "RIP", "RAKE", "THRASH", "MOONFIRE_CAT",
                "ENERGY", "COMBO"
            }
        end
        
        if #spellList == 0 then return end
        
        local row, col = 0, 0
        local maxCols = 3
        
        for i, spellKey in ipairs(spellList) do
            if not colorButtons[spellKey] then
                local colorBtn = CreateFrame("Button", "ShreddedOptionsColor_" .. spellKey, colorContainer)
                colorBtn:SetSize(20, 20)
                
                local tex = colorBtn:CreateTexture(nil, "BACKGROUND")
                tex:SetAllPoints()
                colorBtn.texture = tex
                
                local label = colorBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                label:SetPoint("LEFT", colorBtn, "RIGHT", 5, 0)
                label:SetText(GetSpellDisplayName(spellKey))
                colorBtn.label = label
                
                colorBtn.spellKey = spellKey
                
                colorBtn:SetScript("OnClick", function(self)
                    local c = ShreddedSettings["barcolor"][self.spellKey] or {1, 1, 1}
                    ColorPickerFrame:SetupColorPickerAndShow({
                        r = c[1],
                        g = c[2],
                        b = c[3],
                        swatchFunc = function()
                            local r, g, b = ColorPickerFrame:GetColorRGB()
                            ShreddedSettings["barcolor"][self.spellKey] = {r, g, b}
                            self.texture:SetColorTexture(r, g, b)
                            Shredded_Refresh()
                        end,
                        cancelFunc = function(prev)
                            ShreddedSettings["barcolor"][self.spellKey] = {prev.r, prev.g, prev.b}
                            self.texture:SetColorTexture(prev.r, prev.g, prev.b)
                            Shredded_Refresh()
                        end,
                    })
                end)
                
                colorButtons[spellKey] = colorBtn
            end
            
            local btn = colorButtons[spellKey]
            btn:Show()
            
            -- Position in grid
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", colorContainer, "TOPLEFT", col * 130, -row * 25)
            
            -- Update color
            if ShreddedSettings and ShreddedSettings["barcolor"] and ShreddedSettings["barcolor"][spellKey] then
                local c = ShreddedSettings["barcolor"][spellKey]
                btn.texture:SetColorTexture(c[1], c[2], c[3])
            else
                btn.texture:SetColorTexture(1, 1, 1)
            end
            
            col = col + 1
            if col >= maxCols then
                col = 0
                row = row + 1
            end
        end
    end
    
    -- Update when panel is shown
    barColorPanel:SetScript("OnShow", function()
        -- Update sliders with explicit text
        if ShreddedSettings then
            local barWidth = ShreddedSettings["barwidth"] or 150
            widthSlider:SetValue(barWidth)
            widthSlider.Text:SetText(floor(barWidth))
            
            local barHeight = ShreddedSettings["barheight"] or 18
            heightSlider:SetValue(barHeight)
            heightSlider.Text:SetText(floor(barHeight))
            
            local barFont = ShreddedSettings["barfont"] or 11
            fontSlider:SetValue(barFont)
            fontSlider.Text:SetText(floor(barFont))
            
            local barOpacity = ShreddedSettings["baralpha"] or 0.9
            opacitySlider:SetValue(barOpacity)
            opacitySlider.Text:SetText(floor(barOpacity * 100) .. "%")
            
            local bgOpacity = ShreddedSettings["barbackalpha"] or 0.4
            bgOpacitySlider:SetValue(bgOpacity)
            bgOpacitySlider.Text:SetText(floor(bgOpacity * 100) .. "%")
            
            UIDropDownMenu_SetText(textureDropdown, ShreddedSettings["bartexturename"] or "BantoBar")
        end
        -- Then refresh color buttons
        RefreshColorButtons()
    end)
    
    -- Also do initial population after a short delay
    C_Timer.After(0.5, function()
        if barColorPanel:IsVisible() then
            RefreshColorButtons()
        end
    end)
    
    return barColorPanel
end


function Shredded_SetupOptions()
    --print("|cFF00FF00Shredded:|r Setting up options...")
    SetupSlashCommands()
    
    -- Create panels
    local mainPanel = CreateOptionsPanel()
    local cdLayoutPanel = CreateCooldownLayoutPanel()
    local cdVisualsPanel = CreateCooldownVisualsPanel()
    local barLayoutPanel = CreateBarPanel()
    local barVisualsPanel = CreateBarColorPanel()
    
    --print("|cFF00FF00Shredded:|r Panels created, registering with Settings API...")
    
    -- Use modern Settings API if available (10.0+)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        -- Modern WoW 10.0+ Settings API
        local category, layout = Settings.RegisterCanvasLayoutCategory(mainPanel, mainPanel.name)
        Settings.RegisterAddOnCategory(category)
        
        -- Sub-categories
        local cdLayoutSubCat = Settings.RegisterCanvasLayoutSubcategory(category, cdLayoutPanel, cdLayoutPanel.name)
        local cdVisualsSubCat = Settings.RegisterCanvasLayoutSubcategory(category, cdVisualsPanel, cdVisualsPanel.name)
        local barSubCat = Settings.RegisterCanvasLayoutSubcategory(category, barLayoutPanel, barLayoutPanel.name)
        local visualSubCat = Settings.RegisterCanvasLayoutSubcategory(category, barVisualsPanel, barVisualsPanel.name)
        
        optionsCategory = category
        
        --print("|cFF00FF00Shredded:|r Options registered with Settings API successfully!")
    else
        -- Fallback: just use slash commands
        --print("|cFFFF0000Shredded:|r Settings API not available - use /shredded move and /shredded reset")
    end
    
    -- Schedule a delayed refresh to ensure all data is ready
    C_Timer.After(1.0, function()
        -- Force panels to refresh their data even if not visible
        if cdLayoutPanel and cdLayoutPanel.GetScript then
            local onShow = cdLayoutPanel:GetScript("OnShow")
            if onShow then pcall(onShow, cdLayoutPanel) end
        end
        if cdVisualsPanel and cdVisualsPanel.GetScript then
            local onShow = cdVisualsPanel:GetScript("OnShow")
            if onShow then pcall(onShow, cdVisualsPanel) end
        end
        if barLayoutPanel and barLayoutPanel.GetScript then
            local onShow = barLayoutPanel:GetScript("OnShow")
            if onShow then pcall(onShow, barLayoutPanel) end
        end
        if barVisualsPanel and barVisualsPanel.GetScript then
            local onShow = barVisualsPanel:GetScript("OnShow")
            if onShow then pcall(onShow, barVisualsPanel) end
        end
    end)
end

function Shredded_OpenOptions()
    if InCombatLockdown() then
        ShreddedO("Cannot open options during combat. Try again after combat ends.")
        return
    end
    
    if Settings and optionsCategory then
        -- Use pcall to safely attempt opening settings
        local success, err = pcall(function()
            Settings.OpenToCategory(optionsCategory:GetID())
        end)
        if not success then
            ShreddedO("Could not open settings panel. Use /shredded move to move frames, /shredded reset to reset settings")
        end
    else
        -- Fallback message
        ShreddedO("Use /shredded move to move frames, /shredded reset to reset settings")
    end
end

-- ===========================================
-- LEGACY COMPATIBILITY FUNCTIONS
-- ===========================================

-- These are called from other files, ensure they exist
function Shredded_ToggleCatSpell(spell, switch)
    if switch then
        ShreddedSettings["baron"][spell] = true
    else
        ShreddedSettings["baron"][spell] = false
    end
end

function Shredded_Callback(restore)
    local r, g, b
    if restore then
        r, g, b = unpack(restore)
    else
        r, g, b = ColorPickerFrame:GetColorRGB()
    end
    ShreddedSettings["barcolor"][ShreddedColoredSpell] = {r, g, b}
    Shredded_Refresh()
end

function Shredded_DoColors(spell)
    ShreddedColoredSpell = spell
    local c = ShreddedSettings["barcolor"][spell] or {1, 1, 1}
    ColorPickerFrame:SetupColorPickerAndShow({
        r = c[1],
        g = c[2], 
        b = c[3],
        swatchFunc = Shredded_Callback,
    })
end
