-- ============================================================================
-- VamoosesWorkbench - CharacterData
-- Multi-character profession scanning (engine decoupled from UI)
-- ============================================================================

VWB = VWB or {}
VWB.CharacterData = {}

local ED -- lazy ref to VWB.Data.ExpansionData

local function GetED()
    if not ED then ED = VWB.Data.ExpansionData end
    return ED
end

-- SkillLine ID -> profession name
local PROFESSION_SKILL_LINES = {
    [171] = "Alchemy",
    [164] = "Blacksmithing",
    [185] = "Cooking",
    [333] = "Enchanting",
    [202] = "Engineering",
    [773] = "Inscription",
    [755] = "Jewelcrafting",
    [165] = "Leatherworking",
    [197] = "Tailoring",
    [182] = "Herbalism",
    [186] = "Mining",
    [393] = "Skinning",
    [356] = "Fishing",
    [794] = "Archaeology",
}

-- Normalize API expansion names to display names
local function NormalizeExpansionName(apiName)
    if not apiName then return nil end
    local ed = GetED()
    if ed then
        local info = ed.GetExpansionInfo(apiName)
        if info then return info.display end
    end
    return apiName
end

-- "Northrend Alchemy" + "Alchemy" -> "Northrend" (locale-safe: plain suffix strip, no patterns)
local function StripBaseSuffix(childName, baseName)
    if baseName and childName:sub(-#baseName) == baseName then
        return childName:sub(1, #childName - #baseName):match("^%s*(.-)%s*$")
    end
    return childName
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function VWB.CharacterData:Initialize()
    -- No WoW events needed here; scanning is on-demand
end

function VWB.CharacterData:GetCharacterKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    return name .. "-" .. realm
end

function VWB.CharacterData:GetAllCharacters()
    return VWB.Store:GetState().account.characters or {}
end

-- Scan current character's professions and dispatch to Store
function VWB.CharacterData:ScanCurrentProfessions()
    local charKey = self:GetCharacterKey()
    local professions = {}

    -- Get profession slots -- ALL five: slots 3+4 (archaeology, fishing) were
    -- discarded pre-2026-07-11; a nil slot (skill not learned / removed from
    -- the game) simply skips in the loop below, so capturing them is safe.
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    local profSlots = { prof1, prof2, archaeology, fishing, cooking }

    -- Get expansion-level skill data from open profession window (if any)
    local openProfSkillLevels = {}
    local openProfSkillLine = nil

    if C_TradeSkillUI and C_TradeSkillUI.GetChildProfessionInfos then
        local childInfos = C_TradeSkillUI.GetChildProfessionInfos()
        if childInfos and #childInfos > 0 then
            local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo()
            local baseName = baseInfo and baseInfo.professionName
            for _, childInfo in ipairs(childInfos) do
                -- exception(boundary): ProfessionInfo.expansionName is permanently bugged ("Unknown",
                -- see Reference/_SIGNATURES.md) -- derive the era from the child professionName
                -- prefix instead ("Northrend Alchemy" -> "Northrend" -> ED alias -> display name)
                local prefix = StripBaseSuffix(childInfo.professionName, baseName)
                if prefix ~= "" and childInfo.skillLevel and childInfo.maxSkillLevel then
                    local normalizedName = NormalizeExpansionName(prefix)
                    if normalizedName then
                        openProfSkillLevels[normalizedName] = {
                            current = childInfo.skillLevel,
                            max = childInfo.maxSkillLevel,
                        }
                    end
                end
            end
            if baseInfo and baseInfo.professionID then
                openProfSkillLine = baseInfo.professionID
            end
        end
    end

    -- Get existing character data to preserve cached skill levels
    local existingCharData = self:GetAllCharacters()[charKey] or {}
    local existingProfessions = existingCharData.professions or {}

    for _, slot in ipairs(profSlots) do
        if slot then
            local name, icon, _, _, _, _, skillLine = GetProfessionInfo(slot)
            local profName = PROFESSION_SKILL_LINES[skillLine] or name

            if profName then
                local skillLevels = {}

                if openProfSkillLine == skillLine and next(openProfSkillLevels) then
                    skillLevels = openProfSkillLevels
                elseif existingProfessions[profName] and existingProfessions[profName].skillLevels then
                    local oldLevels = existingProfessions[profName].skillLevels
                    for expName, skillData in pairs(oldLevels) do
                        if expName ~= "Unknown" then -- prune keys saved by the pre-fix expansionName bug
                            local normalizedName = NormalizeExpansionName(expName) or expName
                            if not skillLevels[normalizedName] or skillData.current > (skillLevels[normalizedName].current or 0) then
                                skillLevels[normalizedName] = skillData
                            end
                        end
                    end
                end

                professions[profName] = {
                    icon = icon,
                    skillLevels = skillLevels,
                }
            end
        end
    end

    VWB.Store:Dispatch("SAVE_CHARACTER_PROFESSIONS", {
        charKey = charKey,
        name = UnitName("player"),
        realm = GetRealmName(),
        class = select(2, UnitClass("player")),
        faction = UnitFactionGroup("player"),
        professions = professions,
    })
end
