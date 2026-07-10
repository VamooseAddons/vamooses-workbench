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

-- Get current theme key
function VWB.Constants:GetCurrentTheme()
    local state = VWB.Store and VWB.Store:GetState()
    return (state and state.config and state.config.theme) or "solarizeddark"
end

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

-- Helper functions for color access
function VWB.Constants:GetHex(colorName)
    local scheme = VWB.Colors.Schemes.SolarizedDark
    if VWB.Theme and VWB.Theme.currentScheme then
        scheme = VWB.Theme.currentScheme
    end
    local color = scheme and scheme[colorName]
    if color then
        -- Generate hex from RGB (schemes use 'a' not 'hex')
        return string.format("%02x%02x%02x",
            math.floor(color.r * 255),
            math.floor(color.g * 255),
            math.floor(color.b * 255))
    end
    return "ffffff"
end

function VWB.Constants:GetRGB(colorName)
    local scheme = VWB.Colors.Schemes.SolarizedDark
    if VWB.Theme and VWB.Theme.currentScheme then
        scheme = VWB.Theme.currentScheme
    end
    local c = scheme and scheme[colorName]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
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

VWB.Constants.UI = {
    -- Window dimensions (DecorDrop-style)
    WINDOW_WIDTH = 1140,
    WINDOW_HEIGHT = 700,

    -- Title and tab sizing
    titleBarHeight = 28,
    tabHeight = 24,
    tabWidth = 100,

    -- Page rail (left side, outside main frame)
    PAGE_RAIL_WIDTH = 44,
    PAGE_BUTTON_SIZE = 40,

    -- Recipes page 3-column layout
    NAV_PANEL_WIDTH = 240,
    RECIPE_LIST_WIDTH = 360,
    -- Queue + Materials fills remaining (~460px)

    -- Row sizing
    rowHeight = 20,
    recipeRowHeight = 20,
    rowSpacing = 22,
    queueRowHeight = 22,
    queueRowSpacing = 24,
    headerHeight = 20,
    stockroomRowHeight = 24,

    -- Button sizing
    buttonHeight = 22,
    buttonPadding = 4,
    checkboxSize = 24,

    -- Panel sizing
    panelPadding = 8,
    sectionHeaderOffset = 30,  -- Space from panel top to scroll area start
    sectionSpacing = 15,
    dividerHeight = 1,

    -- 3-Column Panel Layout (legacy, still used by current panels)
    PANEL_GAP = 6,              -- Gap between panels
    PANEL_PADDING = 4,          -- Outer padding from frame edge
    PANEL_HEADER_HEIGHT = 22,   -- Header bar height for each panel
    LEFT_PANEL_WIDTH = 260,     -- Recipe list panel
    MIDDLE_PANEL_WIDTH = 260,   -- Crafting queue panel
    RIGHT_PANEL_MIN_WIDTH = 200, -- Raw materials panel
    PANEL_HEIGHT = 480,         -- Panel content height
    FILTER_ROWS_HEIGHT = 60,    -- Two rows: filters/search (24) + gap + profession tabs (28)

    -- Data tab column widths
    colWidthTime = 75,
    colWidthItem = 180,
    colWidthQty = 40,
    colWidthProfession = 100,

    -- Trainer tab column widths
    colWidthFaction = 30,
    colWidthName = 160,
    colWidthZone = 140,
    colWidthCoords = 70,
}

-- ============================================================================
-- 5b. PAGE DEFINITIONS
-- ============================================================================

-- Rail pages (primary content, left rail icons)
VWB.Constants.RailPages = {
    -- ids are persisted in VWB_DB.ui.activePage -- labels changed in the Workshop
    -- naming pass (2026-07-04), ids deliberately kept stable
    -- hint = the plain-language function, shown dim next to the workshop name
    -- in the rail flyout so the cute labels never obscure what a page does
    { id = "recipes",  icon = "Interface\\Icons\\Trade_BlackSmithing", label = "Workbench", hint = "recipes & queue" },
    { id = "preview",  icon = "Interface\\Icons\\INV_Misc_Spyglass_03", label = "Showroom", hint = "3D preview" },
    { id = "profit",   icon = "Interface\\Icons\\INV_Misc_Coin_17", label = "Ledger", hint = "profit" },
    { id = "reagents", icon = "Interface\\Icons\\INV_Crate_01", label = "Stockroom", hint = "reagents" },
    { id = "alts",     icon = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend", label = "Roster", hint = "your characters" },
    { id = "data",     icon = "Interface\\Icons\\INV_Misc_Note_06", label = "Records", hint = "scans & stats" },
    { id = "config",   icon = "Interface\\Icons\\INV_Misc_Gear_01", label = "Settings", hint = "options" },
}

-- Bottom tabs (secondary/utility, under frame)

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
}

-- ============================================================================
-- 7. CATEGORY CLASSIFICATIONS
-- ============================================================================

VWB.Constants.CategoryClassifications = {
    Consumables = {
        "Potion", "Elixir", "Phial", "Flask", "Cauldron", "Cures", "Tonic",
        "Anti-Venom", "Oil", "Concoction", "Extract",
        "Cooking", "Everyday", "Meal", "Feast", "Dish", "Food", "Cuisine",
        "Wrap", "Stew", "Soul Food", "Quick and Easy", "Delicious",
        "Nutritious", "Crisp", "Refreshing", "Beverage", "Drink",
        "Fish Dish", "Large Meal", "Snack", "Delicac", "Dessert",
        "Holiday", "Meat", "Way of the", "Orcish", "Best of the Best",
        "Scroll", "Vantus", "Contract", "Rune",
        "Drum", "Bandage",
        "Explosive", "Bomb", "EZ-Thro",
        "Incense",
    },
    Enchants = {
        "Enchant", "Embellish", "Emboss", "Illusion", "Item Enhancer",
        "Spellthread",
    },
    Gems = {
        "Gem", "Jewel", "Sapphire", "Ruby", "Emerald", "Onyx",
        "Blasphemite", "Jewelry Enhancer",
    },
    Profession = {
        "Profession", "Treatise", "Training",
        "Material", "Reagent", "Smelting", "Milling", "Disenchant",
        "Transmut", "Ink", "Prospect", "Refinement",
        "Finishing Reagent", "Optional Reagent",
        "Armor Kit", "Armor Mod", "Equipment Mod", "Weapon Mod",
        "Tool", "Accessori", "Scope", "Tinker",
        "Bag", "Research",
    },
    Toys = { "Toy", "Prism", "Statue", "Firework", "Novelti" },
    Armor = {
        "Armor", "Mail Armor", "Leather Armor", "Cloth Armor", "Plate",
        "Boots", "Belt", "Bracer", "Chest", "Glove", "Gauntlet",
        "Helm", "Hat", "Hood", "Leg", "Pant", "Shoulder", "Wrist",
        "Cloak", "Robe", "Tunic", "Garment", "Shirt",
        "Trinket", "Necklace", "Ring", "Jewelry", "Crown",
        "Goggle",
        "Competitor", "Bestial", "Geared For Combat",
    },
    Weapons = {
        "Weapon", "Axe", "Dagger", "Mace", "Staff", "Stave", "Sword",
        "Wand", "Bow", "Gun", "Crossbow", "Fist Weapon", "Polearm",
        "Off-Hand", "Shield", "Rod",
    },
    Mounts = { "Mount", "Skyriding" },
    Pets = { "Pet", "Companion", "Battle Pet" },
    Decor = { "House Decor", "Housing", "Decor" },
}

VWB.Constants.ProfessionDefaults = {
    Mining = "Profession",
    Herbalism = "Profession",
    Skinning = "Profession",
}

VWB.Constants.ClassificationOrder = {
    "All", "Consumables", "Enchants", "Gems", "Profession",
    "Toys", "Armor", "Weapons", "Mounts", "Pets", "Decor", "Misc"
}

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
-- 8. SMART FOLDERS - Groups related categories into logical folders
-- ============================================================================

VWB.Constants.SmartFolders = {
    Jewelcrafting = {
        ["Color Gems"] = { "Red Gems", "Blue Gems", "Yellow Gems", "Green Gems", "Orange Gems", "Purple Gems", "Gems" },
        ["Named Gems"] = { "Extravagant Emeralds", "Radiant Rubies", "Stunning Sapphires", "Ostentatious Onyxes", "Ambivalent Amber", "Benevolent Blasphemite" },
        Elemental = { "Air Gems", "Earth Gems", "Fire Gems", "Frost Gems", "Rudimentary Gems" },
        Special = { "Meta Gems", "Primalist Gems", "Prismatic Gems", "Prisms", "Prisms & Statues", "Statues", "Statues & Carvings" },
        Jewelry = { "Rings", "Necklaces", "Jewelry", "Crowns", "Crowns & Accessories", "Jewelry Enhancers", "Trinkets" },
        Equipment = { "Fist Weapons", "Weapons", "Profession Equipment", "Hats" },
        Crafting = { "Prospecting", "Mass Prospecting", "Basic Reagents", "Finishing Reagents", "Reagents", "Reagents and Research", "Materials", "Jewelcrafting Essentials", "Optional Reagents", "Optional Embellishments", "Research", "Training" },
    },
    Alchemy = {
        Combat = { "Combat Potions", "Flasks", "Phials", "Vicious Flasks", "Elemental Phials and Potions", "Air Phials", "Frost Phials", "Air Potions", "Frost Potions" },
        Utility = { "Utility Potions", "Potions", "Cures & Tonics", "Anti-Venoms", "Incense", "Oils", "Oils and Extracts", "Mana Oils" },
        Elixirs = { "Elixirs", "Potions and Elixirs", "Basic Concoctions", "Cauldrons" },
        Crafting = { "Transmutation", "Transmutations", "Alchemist Stones", "Finishing Reagents", "Reagents", "Reagents and Research", "Materials", "Alchemy Essentials", "Optional Reagents", "Research", "Training" },
        Trinkets = { "Trinkets", "Trinkets and Trinket Upgrades" },
    },
    Tailoring = {
        Bags = { "Bags", "Embroidered Bags" },
        Body = { "Armor", "Cloth Armor", "Robes & Tunics", "Garments", "Azureweave Garments", "Chronocloth Garments", "Specialized Armor", "Reshii Wraps" },
        Slots = { "Boots", "Belts", "Bracers", "Gloves", "Hats & Hoods", "Hats & Accessories", "Pants", "Shoulders", "Cloaks", "Shirts" },
        Utility = { "Bandages", "Cures of Draenor", "Cures of the Broken Isles", "Battle Flags", "Battle Standards", "Nets", "Spellthread", "Spellthreads" },
        Crafting = { "Materials", "Woven Cloth", "Woven Dawn", "Woven Dusk", "Dyes and Thread", "Conversions", "Finishing Reagents", "Reagents", "Reagents and Research", "Optional Reagents", "Embroidery", "Assorted Embroidery", "Training" },
    },
    Engineering = {
        Explosives = { "Bombs", "Explosives", "EZ-Thro", "Fireworks" },
        Gadgets = { "Devices", "Tinkers", "Tinker's Essentials", "Robotics", "Safety Components", "Cogwheels", "Combat Tools" },
        Goggles = { "Goggles", "Cloth Goggles", "Leather Goggles", "Mail Goggles", "Plate Goggles", "Armor" },
        Weapons = { "Guns", "Guns & Bows", "Weapons", "Scopes", "Scopes & Ammo" },
        Crafting = { "Parts", "Tools", "Profession Equipment", "Belt Attachments", "Finishing Reagents", "Reagents", "Reagents and Research", "Optional Reagents" },
    },
    Cooking = {
        Feasts = { "Feasts", "Great Feasts", "Cooking For Others" },
        Meals = { "Large Meals", "Light Meals", "A Full Belly", "Everyday Cooking", "Quick and Easy", "Nutritious and Delicious", "Delicious and Nutritious" },
        Fish = { "Fish Dishes", "Deluxe Fish Dishes", "Simple Fish Dishes" },
        Meat = { "Meat Dishes", "Meat Meals", "Orcish Cuisine" },
        Snacks = { "Snacks", "Desserts", "Delicacies", "Unusual Delights", "Best of the Best", "Secret Recipes" },
        Drinks = { "Beverages", "Delightful Drinks", "Crisp and Refreshing", "Soul Food" },
        Ways = { "Way of the Brew", "Way of the Grill", "Way of the Oven", "Way of the Pot", "Way of the Steamer", "Way of the Wok" },
    },
    Enchanting = {
        Weapon = { "Weapon", "Weapon Enchantments" },
        Armor = { "Armor Enchantments", "Chest Enchantments", "Cloak", "Cloak Enchantments", "Boot Enchantments", "Bracer Enchantments", "Wrist Enchantments", "Glove Enchantments", "Shoulder Enchantments" },
        Jewelry = { "Ring", "Ring Enchantments", "Neck", "Neck Enchantments", "Trinket" },
        ["Off-Hand"] = { "Shield Enchantments", "Shield and Off-Hand Enchantments" },
        Illusions = { "Illusions", "Algari Illusions", "Illusory Goods" },
        Crafting = { "Rods", "Rods and Wands", "Wands", "Disenchant", "Disenchants", "Shatters", "Conversions", "Reagents", "Reagents and Research", "Optional Reagents", "Infusions of Power", "Magical Merchandise", "Training" },
        Oils = { "Oils", "Mana Oils" },
    },
    Blacksmithing = {
        Body = { "Armor", "Chest" },
        Slots = { "Belts", "Boots", "Bracers", "Gauntlets", "Helms", "Legs", "Shoulders" },
        Weapons = { "Weapons", "Weapons and Shields", "Shields" },
        Mods = { "Armor Mods", "Equipment Mods", "Weapon Mods", "Weapons Mods", "Item Enhancers" },
        Crafting = { "Smelting", "Stonework", "Frameworks", "Materials", "Reagents", "Reagents and Research", "Finishing Reagents", "Optional Reagents", "Training" },
        Utility = { "Skeleton Keys", "Consumable Tools" },
    },
    Leatherworking = {
        Leather = { "Leather Armor", "Specialized Armor" },
        Mail = { "Mail Armor" },
        Slots = { "Boots", "Belts", "Bracers", "Chest", "Chests", "Gloves", "Helms", "Pants", "Shoulders", "Cloaks" },
        Consumables = { "Drums", "Armor Kits", "Armor Enhancers", "Consumables" },
        Bags = { "Bags", "Tents" },
        Crafting = { "Materials", "Reagents", "Reagents and Research", "Finishing Reagents", "Optional Reagents", "Embossments", "Research" },
        Training = { "Basic Training", "Material Preparation Training", "Shaping Training", "Stitching Training", "Tanning Training" },
    },
    Inscription = {
        Glyphs = { "Glyphs" },
        Contracts = { "Contracts", "Blood Contracts", "Vantus Runes" },
        Scrolls = { "Scrolls", "Scrolls & Research", "Books & Scrolls", "Runes", "Runes and Sigils" },
        Missives = { "Missives", "Crafting Tool Missives", "Gathering Tool Missives" },
        Weapons = { "Staves", "Staves & Off-Hands", "Staves & Wands", "Off-Hands", "Off-hand", "Weapons", "Weapons & Off-Hands" },
        Crafting = { "Ink", "Inks", "Mass Milling", "Conversions", "Reagents", "Reagents and Research", "Optional Reagents", "Research" },
        Cards = { "Card", "Cards", "Mysteries", "Trinkets" },
        Skyriding = { "Skyriding - Cliffside Wylderdrake", "Skyriding - Grotto Netherwing Drake", "Skyriding - Highland Drake", "Skyriding - Renewed Proto-Drake", "Skyriding - Windborne Velocidrake", "Skyriding - Winding Slitherdrake" },
    },
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
