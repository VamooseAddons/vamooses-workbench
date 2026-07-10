-- ============================================================================
-- Data/ExpansionData.lua
-- Ported from HDG_ExpansionData.lua for VamoosesWorkbench
-- ============================================================================

VWB = VWB or {}
VWB.Data = VWB.Data or {}
VWB.Data.ExpansionData = {}

local ED = VWB.Data.ExpansionData

-- ============================================================================
-- EXPANSIONS
-- ============================================================================
-- Localized expansion names from WoW clients:
-- EN=English, DE=German, ES=Spanish, FR=French, IT=Italian, RU=Russian, KO=Korean, ZH=Chinese
ED.EXPANSION_DATA = {
    { display = "Classic",                api = "Classic",      abbr = "Classic", short = "CLS", color = { r = 0.6, g = 0.6, b = 0.6 } },
    -- TBC: Outland (EN), Scherbenwelt (DE), Terrallende (ES), Outreterre (FR), Terre Esterne (IT)
    { display = "The Burning Crusade",    api = "Outland",      abbr = "TBC",     short = "TBC", color = { r = 0.4, g = 0.7, b = 0.4 },
      aliases = { "Burning Crusade", "Outland", "Scherbenwelt", "Terrallende", "Outreterre", "Terre Esterne", "Запределье", "外域", "아웃랜드" } },
    -- WotLK: Northrend (EN), Nordend (DE), Rasganorte (ES), Norfendre (FR), Nordania (IT)
    { display = "Wrath of the Lich King", api = "Northrend",    abbr = "WotLK",   short = "WLK", color = { r = 0.4, g = 0.6, b = 0.8 },
      aliases = { "Northrend", "WotLK", "Nordend", "Rasganorte", "Norfendre", "Nordania", "Нордскол", "诺森德", "노스렌드" } },
    -- Cata: Kataklysmus (DE), Cataclismo (ES/IT/PT)
    { display = "Cataclysm",              api = "Cataclysm",    abbr = "Cata",    short = "CAT", color = { r = 0.8, g = 0.5, b = 0.2 },
      aliases = { "Kataklysmus", "Cataclismo", "Катаклизм", "大地的裂变", "대격변" } },
    -- MoP: Pandaria same in most languages
    { display = "Mists of Pandaria",      api = "Pandaria",     abbr = "MoP",     short = "MOP", color = { r = 0.3, g = 0.7, b = 0.5 },
      aliases = { "Pandaria", "MoP", "Пандария", "潘达利亚", "판다리아" } },
    -- WoD: Draenor same in most languages
    { display = "Warlords of Draenor",    api = "Draenor",      abbr = "WoD",     short = "WOD", color = { r = 0.7, g = 0.5, b = 0.3 },
      aliases = { "Draenor", "WoD", "Дренор", "德拉诺", "드레노어" } },
    -- Legion: same in most languages
    { display = "Legion",                 api = "Legion",       abbr = "Legion",  short = "LEG", color = { r = 0.5, g = 0.9, b = 0.3 },
      aliases = { "Легион", "军团再临", "군단" } },
    -- BfA: Kul Tiran (Alliance), Zandalari (Horde) - faction-specific profession skill names
    { display = "Battle for Azeroth",     api = "BfA",          abbr = "BfA",     short = "BFA", color = { r = 0.8, g = 0.7, b = 0.2 },
      aliases = { "Kul Tiran", "Zandalari", "Kul Tiras", "Kul", "Культирас", "Зандалари", "库尔提拉斯", "赞达拉", "쿨 티란", "잔달라" } },
    -- SL: Schattenlande (DE), Ombreterre (FR), Tierras Sombrías (ES), Terre Ombrose (IT)
    { display = "Shadowlands",            api = "Shadowlands",  abbr = "SL",      short = "SL",  color = { r = 0.6, g = 0.4, b = 0.8 },
      aliases = { "Schattenlande", "Ombreterre", "Tierras Sombrías", "Terre Ombrose", "Темные Земли", "暗影国度", "어둠땅" } },
    -- DF: Dracheninseln (DE), Islas del Dragón (ES), Îles aux Dragons (FR), Isole dei Draghi (IT)
    { display = "Dragonflight",           api = "Dragon Isles", abbr = "DF",      short = "DF",  color = { r = 0.2, g = 0.6, b = 1.0 },
      aliases = { "Dragon Isles", "Dragon", "Dracheninseln", "Islas del Dragón", "Îles aux Dragons", "Isole dei Draghi", "Драконьи острова", "巨龙群岛", "용의 섬" } },
    -- TWW: Khaz Algar is same in most languages (proper noun)
    { display = "The War Within",         api = "Khaz Algar",   abbr = "TWW",     short = "TWW", color = { r = 1.0, g = 0.5, b = 0.2 },
      aliases = { "Khaz Algar", "Khaz", "Каз'Алгар", "卡兹阿加", "카즈 알가르" } },
    -- Midnight: future expansion
    { display = "Midnight",               api = "Midnight",     abbr = "MN",      short = "MN",  color = { r = 0.6, g = 0.2, b = 0.8 } },
}

-- Lookup Tables
ED.EXPANSION_ORDER = {}
local expByName = {}

for i, exp in ipairs(ED.EXPANSION_DATA) do
    exp.order = i
    table.insert(ED.EXPANSION_ORDER, exp)
    expByName[exp.display] = exp
    expByName[exp.api] = exp
    expByName[exp.abbr] = exp
    if exp.aliases then
        for _, alias in ipairs(exp.aliases) do
            expByName[alias] = exp
        end
    end
end

function ED.GetExpansionInfo(name)
    if not name then return nil end
    return expByName[name]
end

function ED.GetColor(name)
    local info = ED.GetExpansionInfo(name)
    if info then return info.color end
    return { r = 0.5, g = 0.5, b = 0.5 }
end

-- Default fallback color (base0 gray from Solarized)
local DEFAULT_COLOR = { r = 0.51, g = 0.58, b = 0.59 }

-- Apply expansion color to a FontString
-- fontString: the FontString to color
-- expansionName: name/api/abbr of expansion (or nil for default)
-- adjust: optional amount to brighten (positive) or dim (negative)
function ED.SetTextColor(fontString, expansionName, adjust)
    local color = DEFAULT_COLOR
    if expansionName then
        local info = ED.GetExpansionInfo(expansionName)
        if info and info.color then
            color = info.color
        end
    end

    local r, g, b = color.r, color.g, color.b
    if adjust then
        r = math.max(0, math.min(1, r + adjust))
        g = math.max(0, math.min(1, g + adjust))
        b = math.max(0, math.min(1, b + adjust))
    end

    fontString:SetTextColor(r, g, b)
end

-- Get RGB values for an expansion (unpacked for SetTextColor)
-- Returns r, g, b values directly
function ED.GetRGB(expansionName, adjust)
    local color = DEFAULT_COLOR
    if expansionName then
        local info = ED.GetExpansionInfo(expansionName)
        if info and info.color then
            color = info.color
        end
    end

    local r, g, b = color.r, color.g, color.b
    if adjust then
        r = math.max(0, math.min(1, r + adjust))
        g = math.max(0, math.min(1, g + adjust))
        b = math.max(0, math.min(1, b + adjust))
    end

    return r, g, b
end

-- ============================================================================
-- PROFESSIONS
-- ============================================================================
-- Blizzard's classic tradeskill icons (stable Interface\Icons assets)
ED.PROFESSION_DATA = {
    { name = "Alchemy",        id = 171, code = "AL", icon = "Interface\\Icons\\Trade_Alchemy" },
    { name = "Blacksmithing",  id = 164, code = "BS", icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { name = "Cooking",        id = 185, code = "CK", icon = "Interface\\Icons\\INV_Misc_Food_15" },
    { name = "Enchanting",     id = 333, code = "EN", icon = "Interface\\Icons\\Trade_Engraving" },
    { name = "Engineering",    id = 202, code = "EG", icon = "Interface\\Icons\\Trade_Engineering" },
    { name = "Inscription",    id = 773, code = "IN", icon = "Interface\\Icons\\INV_Inscription_Tradeskill01" },
    { name = "Jewelcrafting",  id = 755, code = "JC", icon = "Interface\\Icons\\INV_Misc_Gem_01" },
    { name = "Leatherworking", id = 165, code = "LW", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    { name = "Tailoring",      id = 197, code = "TL", icon = "Interface\\Icons\\Trade_Tailoring" },
    { name = "Herbalism",      id = 182, code = "HB", icon = "Interface\\Icons\\Trade_Herbalism" },
    { name = "Mining",         id = 186, code = "MN", icon = "Interface\\Icons\\Trade_Mining" },
    { name = "Skinning",       id = 393, code = "SK", icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
    -- Secondary skills (tester request 2026-07-11): GetProfessions() slots 3+4.
    -- No recipes -> Records/RecipeQuery unaffected; Roster skill rows only.
    { name = "Fishing",        id = 356, code = "FS", icon = "Interface\\Icons\\Trade_Fishing" },
    { name = "Archaeology",    id = 794, code = "AR", icon = "Interface\\Icons\\Trade_Archaeology" },
}

ED.PROFESSION_ORDER = {}
local profByName = {}

for i, prof in ipairs(ED.PROFESSION_DATA) do
    table.insert(ED.PROFESSION_ORDER, prof)
    profByName[prof.name] = prof
end

function ED.GetProfessionInfo(name)
    return profByName[name]
end
