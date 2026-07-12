-- ============================================================================
-- VamoosesWorkbench - Constants
-- Imports color schemes from SchemeConstants.lua
-- ============================================================================

VWB = VWB or {}
VWB.Constants = {}
VWB.Colors = {}

-- ============================================================================
-- 1. IMPORT COLOR SCHEMES FROM SHARED SCHEMECONSTANTS
-- ============================================================================

VWB.Colors.Schemes = VAMOOSE_SchemeConstants or {}

-- ============================================================================
-- 2. THEME MANAGEMENT
-- ============================================================================

-- Theme cycle order (11 originals + 12 lifted from HDG 2026-07-11)
VWB.Constants.ThemeOrder = {
    "solarizeddark",
    "solarizedlight",
    "gruvboxdark",
    "gruvboxlight",
    "gruvboxhard",
    "everforestdark",
    "everforestlight",
    "kanagawadark",
    "kanagawalight",
    "mocha",
    "tokyonight",
    "rosepine",
    "nord",
    "onenord",
    "dracula",
    "nightfly",
    "badwolf",
    "purpura",
    "green",
    "colorblind",
    "accessibilityhc",
    "housingtheme"
}

-- Maps config key to scheme name (for VWB.Colors.Schemes lookup)
VWB.Constants.ThemeNames = {
    solarizeddark = "SolarizedDark",
    solarizedlight = "SolarizedLight",
    gruvboxdark = "GruvboxDark",
    gruvboxlight = "GruvboxLight",
    everforestdark = "EverforestDark",
    everforestlight = "EverforestLight",
    everforestaccess = "EverforestDark", -- retired 2026-07-11: was byte-identical to EverforestDark; legacy persisted keys map across
    kanagawadark = "KanagawaDark",
    kanagawalight = "KanagawaLight",
    accessibilityhc = "AccessibilityHC",
    housingtheme = "HousingTheme",
    -- Lifted from HDG (palette + composer in SchemeConstants.lua)
    mocha = "Mocha",
    tokyonight = "TokyonightNight",
    rosepine = "RosePineMain",
    gruvboxhard = "GruvboxDarkHard",
    colorblind = "ColorblindSafe",
    nord = "Nord",
    onenord = "OneNord",
    dracula = "Dracula",
    nightfly = "Nightfly",
    badwolf = "Badwolf",
    purpura = "Purpura",
    green = "Green",
    -- Legacy mappings for backwards compatibility
    dark = "SolarizedDark",
    light = "SolarizedLight",
    everforest = "EverforestDark",
    kanagawa = "KanagawaDark",
}

-- User-friendly display names for tooltips
VWB.Constants.ThemeDisplayNames = {
    solarizeddark = "Solarized Dark",
    solarizedlight = "Solarized Light",
    gruvboxdark = "Gruvbox Dark",
    gruvboxlight = "Gruvbox Light",
    everforestdark = "Everforest Dark",
    everforestlight = "Everforest Light",
    kanagawadark = "Kanagawa Dark",
    kanagawalight = "Kanagawa Light",
    accessibilityhc = "Accessibility HC",
    housingtheme = "Housing Theme",
    -- Lifted from HDG
    mocha = "Catppuccin Mocha",
    tokyonight = "Tokyonight Night",
    rosepine = "Rose Pine",
    gruvboxhard = "Gruvbox Dark Hard",
    colorblind = "Colorblind Safe",
    nord = "Nord",
    onenord = "OneNord",
    dracula = "Dracula",
    nightfly = "Nightfly",
    badwolf = "Badwolf",
    purpura = "Purpura",
    green = "Terminal Green",
    -- Legacy mappings
    dark = "Solarized Dark",
    light = "Solarized Light",
    everforest = "Everforest Dark",
    kanagawa = "Kanagawa Dark",
}

-- ============================================================================
-- 3. FONT MANAGEMENT
-- ============================================================================

VWB.Constants.FontOrder = { "ARIALN", "FRIZQT__", "skurri", "MORPHEUS", "Expressway" }

VWB.Constants.FontDisplayNames = {
    ARIALN = "Arial Narrow",
    FRIZQT__ = "Friz Quadrata",
    skurri = "Skurri",
    MORPHEUS = "Morpheus",
    Expressway = "Expressway",
}

VWB.Constants.FontFiles = {
    ARIALN = "Fonts\\ARIALN.TTF",
    FRIZQT__ = "Fonts\\FRIZQT__.TTF",
    skurri = "Fonts\\skurri.TTF",
    MORPHEUS = "Fonts\\MORPHEUS.TTF",
    Expressway = "Interface\\AddOns\\VamoosesWorkbench\\Fonts\\expressway.ttf",
}

-- Get current font family file path
function VWB.Constants:GetFontFile()
    local family = "ARIALN"
    if VWB.Store and VWB.Store.state and VWB.Store.state.config then
        family = VWB.Store.state.config.fontFamily or "ARIALN"
    elseif VWB_DB and VWB_DB.config and VWB_DB.config.fontFamily then
        family = VWB_DB.config.fontFamily
    end
    return self.FontFiles[family] or self.FontFiles.ARIALN
end

-- ============================================================================
-- 4. THEME HELPER FUNCTIONS
-- ============================================================================

-- Theme toggle function (cycles through all themes)
function VWB.Constants:ToggleTheme()
    local state = VWB.Store and VWB.Store:GetState()
    local currentTheme = (state and state.config and state.config.theme) or "solarizeddark"

    -- Find current index and get next theme
    local currentIndex = 1
    for i, theme in ipairs(self.ThemeOrder) do
        if theme == currentTheme then
            currentIndex = i
            break
        end
    end
    local nextIndex = (currentIndex % #self.ThemeOrder) + 1
    local newTheme = self.ThemeOrder[nextIndex]

    if VWB.Store then
        VWB.Store:Dispatch("SET_CONFIG", { key = "theme", value = newTheme })
    end

    return newTheme
end

-- Apply saved theme on load (returns PascalCase scheme name)
function VWB.Constants:ApplyTheme()
    local themeName = "SolarizedDark"
    if VWB_DB and VWB_DB.config and VWB_DB.config.theme then
        themeName = self.ThemeNames[VWB_DB.config.theme] or "SolarizedDark"
    end
    return themeName
end

-- ============================================================================
-- 4b. DERIVED VISUAL COLORS (computed from scheme at runtime)
-- ============================================================================

function VWB.Constants:GetDerivedColors(scheme)
    if not scheme then return {} end
    local w = scheme.warning   -- golden amber in all 11 themes
    local p = scheme.panel
    local b = scheme.border
    return {
        selected_glow = { r = w.r, g = w.g, b = w.b, a = 0.60 },
        selected_fill = { r = w.r, g = w.g, b = w.b, a = 0.18 },
        marble_tint   = { r = p.r, g = p.g, b = p.b, a = 0.35 },
        border_glow   = { r = math.min(b.r * 1.4, 1), g = math.min(b.g * 1.4, 1), b = math.min(b.b * 1.4, 1), a = 1.0 },
        selected_bar  = { r = w.r, g = w.g, b = w.b, a = 1.0 },
    }
end

-- ============================================================================
-- 5. UI SIZING CONSTANTS
-- ============================================================================

-- Only the fields with live readers survive (hygiene 2026-07-13: the VPC-era
-- window/rail/panel geometry constants had zero callers -- the Layout box
-- model owns geometry now -- and the Trainer-tab column widths belonged to a
-- tab that no longer exists).
VWB.Constants.UI = {
    -- Row sizing
    recipeRowHeight = 20,
    stockroomRowHeight = 24,

    -- Records tab column widths
    colWidthTime = 75,
    colWidthItem = 180,
    colWidthQty = 40,
    colWidthProfession = 100,
}

-- ============================================================================
-- 6. PROFESSION ICONS
-- ============================================================================

-- Blizzard's classic tradeskill icons (stable Interface\Icons assets)
VWB.Constants.ProfessionIcons = {
    Alchemy = "Interface\\Icons\\Trade_Alchemy",
    Blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
    Enchanting = "Interface\\Icons\\Trade_Engraving",
    Engineering = "Interface\\Icons\\Trade_Engineering",
    Herbalism = "Interface\\Icons\\Trade_Herbalism",
    Inscription = "Interface\\Icons\\INV_Inscription_Tradeskill01",
    Jewelcrafting = "Interface\\Icons\\INV_Misc_Gem_01",
    Leatherworking = "Interface\\Icons\\Trade_LeatherWorking",
    Mining = "Interface\\Icons\\Trade_Mining",
    Skinning = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    Tailoring = "Interface\\Icons\\Trade_Tailoring",
    Cooking = "Interface\\Icons\\INV_Misc_Food_15",
    ["First Aid"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
    Fishing = "Interface\\Icons\\Trade_Fishing",
    Archaeology = "Interface\\Icons\\Trade_Archaeology",
}

-- THE question-mark fallback icon (hygiene 2026-07-13: was re-declared as a
-- local in three views, inlined in three more, and aliased numerically as
-- 134400 -- one constant, one spelling).
VWB.Constants.ICON_QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

VWB.Constants.ClassificationIcons = {
    All = "Interface\\Buttons\\UI-CheckBox-Check",
    Armor = "Interface\\Icons\\INV_Chest_Plate01",
    Weapons = "Interface\\Icons\\INV_Sword_04",
    Consumables = "Interface\\Icons\\INV_Potion_54",
    Enchants = "Interface\\Icons\\Trade_Engraving",
    Gems = "Interface\\Icons\\INV_Misc_Gem_01",
    Profession = "Interface\\Icons\\INV_Misc_EngGizmos_01",
    Mounts = "Interface\\Icons\\Ability_Mount_RidingHorse",
    Pets = "Interface\\Icons\\INV_Box_PetCarrier_01",
    Toys = "Interface\\Icons\\INV_Misc_Toy_07",
    Decor = "Interface\\Icons\\INV_Misc_Flower_02",
    Misc = "Interface\\Icons\\INV_Misc_QuestionMark",
}

-- ============================================================================
-- 9. GUILD RECIPE HARVEST + GUILD CRAFTERS QUERY (Modules/RecipeHarvest.lua,
-- Modules/GuildCrafters.lua) -- ported from VamoosesGuildCraft/ProfTools
-- ============================================================================

VWB.Constants.Harvest = {
    PROFESSION_TIMEOUT = 10,       -- seconds; per-profession ViewGuildRecipes wait (Mining is huge)
    INTER_PROFESSION_PAUSE = 0.3,  -- seconds; pause between chained guild professions
    HEADER_TIMEOUT = 5,            -- seconds; wait for GUILD_TRADESKILL_UPDATE after QueryGuildRecipes()
    TICK_BUDGET_MS = 10,           -- per-frame time budget for the recipeID scan loop
    BUDGET_CHECK_INTERVAL = 25,    -- iterations between debugprofilestop() checks
    MAX_CATEGORY_DEPTH = 10,       -- category parent-walk guard for expansion derivation
    OWN_HARVEST_DEBOUNCE = 0.5,    -- seconds; coalesces the TRADE_SKILL_LIST_UPDATE burst before Modules/KnownRecipes.lua's own-profession harvest starts
}

VWB.Constants.Projects = {
    MAX_PIECES = 20,   -- per commission; achievement imports hit this scale, and each piece costs a Graph plan walk
    DEFAULT_PAR = 20,  -- stock-piece par when the creator doesn't set one (v1 default preserved)
}

VWB.Constants.Achievements = {
    PROFESSIONS_CATEGORY = 169,     -- Achievement_Category "Professions" root; stable across every expansion (DB2-verified 12.0.7). Children (Alchemy..Archaeology) are walked LIVE, never hardcoded.
    CRITERIA_KNOW_RECIPE = 34,      -- criteriaType: assetID = recipe SPELL id (cross-links to KnownRecipes/Study)
    CRITERIA_CRAFT_ITEM = 29,       -- criteriaType: assetID = ITEM id ("craft each of the following..." family)
    CRITERIA_META = 8,              -- criteriaType: assetID = required achievementID (no exported enum; Blizzard's own CRITERIA_TYPE_ACHIEVEMENT global = 8)
    PROGRESS_BAR_FLAG = 0x1,        -- criteriaFlags: display as quantity/reqQuantity bar
    CRITERIA_SETTLE = 0.5,          -- seconds; CRITERIA_UPDATE fires per craft action -- coalesce before re-reading quantities
}

VWB.Constants.GuildQuery = {
    ROSTER_DEBOUNCE = 0.5,     -- seconds; GUILD_ROSTER_UPDATE debounce
    CRAFTER_TIMEOUT = 3,       -- seconds; QueryGuildMembersForRecipe response wait -> dataHole
    MAX_CACHED_RECIPES = 20,   -- crafter-query session cache cap (arbitrary eviction beyond this)
}

-- Professions whose recipes are almost always gathering "abilities" -- guild
-- recipe views (ViewGuildRecipes) drop the isGatheringRecipe flag, so treat
-- any no-reagent recipe in one of these professions as gathering (ProfTools
-- fallback; a real crafting recipe like "Smelt Copper" still has slots and
-- is not caught by this).
VWB.Constants.GatheringProfessions = {
    Mining = true,
    Herbalism = true,
    Skinning = true,
}

-- Reagent slot type names, keyed by CraftingRecipeSchematic reagentType. This
-- indexing matches ProfTools' original export-pipeline convention, NOT the
-- newer Blizzard doc ordering (0=Basic/1=Finishing/2=Optional/3=Item) -- both
-- Modules/RecipeHarvest.lua (guild) and Modules/KnownRecipes.lua (own-profession)
-- key their recipeStore records against THIS table, so they agree with each other.
VWB.Constants.ReagentSlotTypeNames = {
    [0] = "modifying",
    [1] = "basic",
    [2] = "finishing",
    [3] = "automatic",
}

-- Category-tree-walk expansion aliases (ProfTools' extraction pipeline). Keeps
-- harvested recipe.expansion strings identical to the static DB's, which are
-- VWB.Data.ExpansionData display names (e.g. "Cataclysm", "The War Within").
VWB.Constants.ExpansionCategoryAliases = {
    ["Midnight"] = "Midnight", ["Quel'Thalas"] = "Midnight", ["Quel"] = "Midnight", ["MN"] = "Midnight",
    ["The War Within"] = "The War Within", ["Khaz Algar"] = "The War Within", ["Khaz"] = "The War Within", ["TWW"] = "The War Within",
    ["Dragonflight"] = "Dragonflight", ["Dragon Isles"] = "Dragonflight", ["Dragon"] = "Dragonflight", ["DF"] = "Dragonflight",
    ["Shadowlands"] = "Shadowlands", ["SL"] = "Shadowlands",
    ["Battle for Azeroth"] = "Battle for Azeroth", ["Kul Tiran"] = "Battle for Azeroth", ["Zandalari"] = "Battle for Azeroth", ["BfA"] = "Battle for Azeroth", ["BFA"] = "Battle for Azeroth",
    ["Legion"] = "Legion", ["Broken Isles"] = "Legion", ["Broken Isles Alchemy"] = "Legion", ["Food of the Broken Isles"] = "Legion",
    ["Warlords of Draenor"] = "Warlords of Draenor", ["Draenor"] = "Warlords of Draenor", ["WoD"] = "Warlords of Draenor", ["Food of Draenor"] = "Warlords of Draenor",
    ["Mists of Pandaria"] = "Mists of Pandaria", ["Pandaria"] = "Mists of Pandaria", ["MoP"] = "Mists of Pandaria", ["Pandaren Cuisine"] = "Mists of Pandaria", ["Pandaren"] = "Mists of Pandaria",
    ["Cataclysm"] = "Cataclysm", ["Cata"] = "Cataclysm",
    ["Wrath of the Lich King"] = "Wrath of the Lich King", ["Northrend"] = "Wrath of the Lich King", ["WotLK"] = "Wrath of the Lich King", ["Wrath"] = "Wrath of the Lich King", ["Recipes of the Cold North"] = "Wrath of the Lich King",
    ["The Burning Crusade"] = "The Burning Crusade", ["Outland"] = "The Burning Crusade", ["TBC"] = "The Burning Crusade", ["Burning Crusade"] = "The Burning Crusade", ["Outlandish Dishes"] = "The Burning Crusade",
    ["Classic"] = "Classic", ["Vanilla"] = "Classic", ["Old World Recipes"] = "Classic",
    ["Blacksmithing Plans"] = "Classic", ["Leatherworking Patterns"] = "Classic", ["Tailoring Patterns"] = "Classic",
    ["Jewelcrafting Designs"] = "Classic", ["Engineering"] = "Classic", ["Enchanting"] = "Classic",
    ["Alchemy"] = "Classic", ["Mining"] = "Classic",
}
