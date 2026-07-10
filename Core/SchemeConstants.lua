-- ============================================================================
-- Vamoose Addons - Shared Color Schemes
-- Master color definitions for VamoosesEndeavors and VamoosePowerCrafter
-- Source of truth for all theme colors
-- ============================================================================

VAMOOSE_SchemeConstants = {

    -- ========================================================================
    -- Solarized Dark: "The IDE Look"
    -- High readability, low contrast fatigue.
    -- ========================================================================
    SolarizedDark = {
        -- Window & Containers
        bg           = {r=0.00, g=0.17, b=0.21, a=0.95}, -- Base03 (#002b36)
        panel        = {r=0.03, g=0.21, b=0.26, a=1.00}, -- Base02 (#073642)
        border       = {r=0.35, g=0.43, b=0.46, a=1.00}, -- Base01 (#586e75)

        -- Typography
        text         = {r=0.51, g=0.58, b=0.59, a=1.00}, -- Base0  (#839496)
        text_header  = {r=0.58, g=0.63, b=0.63, a=1.00}, -- Base1  (#93a1a1)
        text_dim     = {r=0.35, g=0.43, b=0.46, a=1.00}, -- Base01 (#586e75)

        -- Interactive: Buttons & Inputs
        button_normal   = {r=0.03, g=0.21, b=0.26, a=1.00}, -- Base02 (#073642)
        button_hover    = {r=0.35, g=0.43, b=0.46, a=0.30}, -- Base01 (30% Opacity)
        button_active   = {r=0.00, g=0.17, b=0.21, a=1.00}, -- Base03 (Recedes into BG)
        button_inactive = {r=0.03, g=0.21, b=0.26, a=0.40}, -- Base02 (40% Opacity)

        -- Interactive Text Colors
        button_text_norm  = {r=0.58, g=0.63, b=0.63, a=1.00}, -- Base1
        button_text_hover = {r=0.99, g=0.96, b=0.89, a=1.00}, -- Base3 (Brightest White)
        button_text_dis   = {r=0.35, g=0.43, b=0.46, a=0.50}, -- Base01 (Dimmed)

        -- Semantics
        accent       = {r=0.15, g=0.55, b=0.82, a=1.00}, -- Blue (#268bd2)
        success      = {r=0.52, g=0.60, b=0.00, a=1.00}, -- Green (#859900)
        warning      = {r=0.71, g=0.54, b=0.00, a=1.00}, -- Yellow (#b58900)
        error        = {r=0.86, g=0.20, b=0.18, a=1.00}, -- Red (#dc322f)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Solarized Light: "The Paper Look"
    -- Warm and bright, requires inversion of logic for buttons.
    -- ========================================================================
    SolarizedLight = {
        -- Window & Containers
        bg           = {r=0.99, g=0.96, b=0.89, a=0.95}, -- Base3 (#fdf6e3)
        panel        = {r=0.93, g=0.91, b=0.84, a=1.00}, -- Base2 (#eee8d5)
        border       = {r=0.58, g=0.63, b=0.63, a=0.50}, -- Base1 (Subtle border)

        -- Typography
        text         = {r=0.40, g=0.48, b=0.51, a=1.00}, -- Base00 (#657b83)
        text_header  = {r=0.35, g=0.43, b=0.46, a=1.00}, -- Base01 (#586e75)
        text_dim     = {r=0.58, g=0.63, b=0.63, a=1.00}, -- Base1  (#93a1a1)

        -- Interactive: Buttons & Inputs
        button_normal   = {r=0.93, g=0.91, b=0.84, a=1.00}, -- Base2 (#eee8d5)
        button_hover    = {r=0.83, g=0.86, b=0.86, a=0.40}, -- Base2 darkened
        button_active   = {r=0.89, g=0.86, b=0.79, a=1.00}, -- Slightly Darker Base3
        button_inactive = {r=0.93, g=0.91, b=0.84, a=0.40}, -- Base2 (Low Opacity)

        -- Interactive Text Colors
        button_text_norm  = {r=0.35, g=0.43, b=0.46, a=1.00}, -- Base01
        button_text_hover = {r=0.00, g=0.17, b=0.21, a=1.00}, -- Base03 (Sharp Black)
        button_text_dis   = {r=0.58, g=0.63, b=0.63, a=0.50}, -- Base1 (Faded)

        -- Semantics
        accent       = {r=0.15, g=0.55, b=0.82, a=1.00}, -- Blue
        success      = {r=0.52, g=0.60, b=0.00, a=1.00}, -- Green
        warning      = {r=0.80, g=0.29, b=0.09, a=1.00}, -- Orange (Better visibility on light)
        error        = {r=0.86, g=0.20, b=0.18, a=1.00}, -- Red

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Gruvbox Dark: Warm, retro terminal style
    -- ========================================================================
    GruvboxDark = {
        -- Containers
        bg              = {r=0.16, g=0.16, b=0.16, a=0.95}, -- #282828 (Bg0)
        panel           = {r=0.24, g=0.22, b=0.21, a=1.00}, -- #3c3836 (Bg1)
        border          = {r=0.31, g=0.29, b=0.27, a=1.00}, -- #504945 (Bg2)

        -- Typography
        text            = {r=0.92, g=0.86, b=0.70, a=1.00}, -- #ebdbb2 (Fg1)
        text_header     = {r=0.98, g=0.95, b=0.78, a=1.00}, -- #fbf1c7 (Fg0)
        text_dim        = {r=0.66, g=0.60, b=0.52, a=1.00}, -- #a89984 (Gray)

        -- Interactive: Buttons
        button_normal   = {r=0.31, g=0.29, b=0.27, a=1.00}, -- #504945 (Bg2)
        button_hover    = {r=0.40, g=0.36, b=0.33, a=1.00}, -- #665c54 (Bg3)
        button_active   = {r=0.11, g=0.13, b=0.13, a=1.00}, -- #1d2021 (Bg0 Hard - Pressed)
        button_inactive = {r=0.24, g=0.22, b=0.21, a=0.50}, -- #3c3836 (50% Opacity)

        -- Interactive Text
        button_text_norm  = {r=0.92, g=0.86, b=0.70, a=1.00}, -- #ebdbb2
        button_text_hover = {r=1.00, g=1.00, b=1.00, a=1.00}, -- White (High Contrast)
        button_text_dis   = {r=0.57, g=0.51, b=0.45, a=1.00}, -- #928374 (Dimmed)

        -- Semantic
        accent          = {r=0.51, g=0.65, b=0.59, a=1.00}, -- #83a598 (Blue)
        success         = {r=0.72, g=0.73, b=0.15, a=1.00}, -- #b8bb26 (Green)
        warning         = {r=0.98, g=0.74, b=0.18, a=1.00}, -- #fabd2f (Yellow)
        error           = {r=0.98, g=0.29, b=0.21, a=1.00}, -- #fb4934 (Red)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Gruvbox Light: Aged paper aesthetic
    -- ========================================================================
    GruvboxLight = {
        -- Containers
        bg              = {r=0.98, g=0.95, b=0.78, a=0.95}, -- #fbf1c7 (Bg0)
        panel           = {r=0.92, g=0.86, b=0.70, a=1.00}, -- #ebdbb2 (Bg1)
        border          = {r=0.84, g=0.77, b=0.63, a=1.00}, -- #d5c4a1 (Bg2)

        -- Typography
        text            = {r=0.24, g=0.22, b=0.21, a=1.00}, -- #3c3836 (Fg1)
        text_header     = {r=0.16, g=0.16, b=0.16, a=1.00}, -- #282828 (Fg0)
        text_dim        = {r=0.57, g=0.51, b=0.45, a=1.00}, -- #928374 (Gray)

        -- Interactive: Buttons
        button_normal   = {r=0.84, g=0.77, b=0.63, a=1.00}, -- #d5c4a1 (Darker Paper)
        button_hover    = {r=0.74, g=0.68, b=0.58, a=1.00}, -- #bdae93 (Bg3)
        button_active   = {r=0.66, g=0.60, b=0.52, a=1.00}, -- #a89984 (Bg4 - Pressed)
        button_inactive = {r=0.92, g=0.86, b=0.70, a=0.50}, -- #ebdbb2 (50% Opacity)

        -- Interactive Text
        button_text_norm  = {r=0.24, g=0.22, b=0.21, a=1.00}, -- #3c3836
        button_text_hover = {r=0.11, g=0.13, b=0.13, a=1.00}, -- #1d2021 (Almost Black)
        button_text_dis   = {r=0.66, g=0.60, b=0.52, a=1.00}, -- #a89984

        -- Semantic
        accent          = {r=0.03, g=0.40, b=0.47, a=1.00}, -- #076678 (Dark Teal)
        success         = {r=0.60, g=0.59, b=0.10, a=1.00}, -- #98971a (Green)
        warning         = {r=0.84, g=0.60, b=0.13, a=1.00}, -- #d79921 (Dark Yellow)
        error           = {r=0.80, g=0.14, b=0.11, a=1.00}, -- #cc241d (Red)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Everforest Dark (Medium): Deep, swampy, soft.
    -- Best for: Night time, low eye strain.
    -- ========================================================================
    EverforestDark = {
        -- Window & Containers
        bg           = {r=0.18, g=0.21, b=0.23, a=0.95}, -- #2d353b (Bg0)
        panel        = {r=0.20, g=0.25, b=0.27, a=1.00}, -- #343f44 (Bg1)
        border       = {r=0.31, g=0.36, b=0.37, a=1.00}, -- #4f585e (Bg3)

        -- Typography
        text         = {r=0.83, g=0.78, b=0.67, a=1.00}, -- #d3c6aa (Fg)
        text_header  = {r=0.90, g=0.85, b=0.72, a=1.00}, -- #e6dfc7 (Pale)
        text_dim     = {r=0.52, g=0.57, b=0.54, a=1.00}, -- #859289 (Grey)

        -- INTERACTIVE: Buttons
        button_normal   = {r=0.24, g=0.28, b=0.30, a=1.00}, -- #3d484d (Bg2)
        button_hover    = {r=0.28, g=0.32, b=0.35, a=1.00}, -- #475258 (Bg3)
        button_active   = {r=0.14, g=0.16, b=0.18, a=1.00}, -- #232a2e (Dim - Pressed)
        button_inactive = {r=0.20, g=0.25, b=0.27, a=0.40}, -- #343f44

        -- Interactive Text
        button_text_norm  = {r=0.83, g=0.78, b=0.67, a=1.00}, -- #d3c6aa
        button_text_hover = {r=1.00, g=1.00, b=1.00, a=1.00}, -- White
        button_text_dis   = {r=0.48, g=0.52, b=0.49, a=1.00}, -- #7a8478

        -- Semantic Accents
        accent       = {r=0.50, g=0.73, b=0.70, a=1.00}, -- #7fbbb3 (Blue)
        success      = {r=0.65, g=0.75, b=0.50, a=1.00}, -- #a7c080 (Green)
        warning      = {r=0.86, g=0.74, b=0.50, a=1.00}, -- #dbbc7f (Yellow)
        error        = {r=0.90, g=0.49, b=0.50, a=1.00}, -- #e67e80 (Red)
        crafting     = {r=0.51, g=0.75, b=0.57, a=1.00}, -- #83c092 (Aqua)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Everforest Light (Medium): Warm, earthy, organic.
    -- Best for: Day time, high readability, "Sage/Tan" aesthetic.
    -- ========================================================================
    EverforestLight = {
        -- Window & Containers
        -- A warm sage-beige, distinct from Solarized's yellow-beige
        bg           = {r=0.93, g=0.92, b=0.83, a=0.95}, -- #efebd4 (Bg Medium)
        panel        = {r=0.90, g=0.89, b=0.80, a=1.00}, -- #e6e2cc (Bg Dim)
        border       = {r=0.74, g=0.76, b=0.68, a=1.00}, -- #bdc3af (Grey 2)

        -- Typography
        text         = {r=0.36, g=0.42, b=0.45, a=1.00}, -- #5c6a72 (Fg)
        text_header  = {r=0.29, g=0.34, b=0.36, a=1.00}, -- #4c566a (Darker Slate)
        text_dim     = {r=0.57, g=0.61, b=0.56, a=1.00}, -- #939f91 (Grey 1)

        -- INTERACTIVE: Buttons & Inputs
        -- Normal: Slightly darker than BG to pop
        button_normal   = {r=0.88, g=0.87, b=0.76, a=1.00}, -- #e0dcc7

        -- Hover: Lighter/Warmer (The "Sunlight" effect)
        button_hover    = {r=0.99, g=0.96, b=0.89, a=0.60}, -- #fdf6e3

        -- Active: Pressed down (Darker Sage)
        button_active   = {r=0.83, g=0.81, b=0.71, a=1.00}, -- #d3c6aa

        -- Disabled: Faded into background
        button_inactive = {r=0.93, g=0.92, b=0.83, a=0.40}, -- #efebd4 (Low Alpha)

        -- Interactive Text
        button_text_norm  = {r=0.36, g=0.42, b=0.45, a=1.00}, -- #5c6a72
        button_text_hover = {r=0.23, g=0.27, b=0.29, a=1.00}, -- #3a454a (Sharper)
        button_text_dis   = {r=0.57, g=0.61, b=0.56, a=1.00}, -- #939f91

        -- Semantic Accents (Warm & Natural)
        accent       = {r=0.23, g=0.58, b=0.77, a=1.00}, -- #3a94c5 (Blue)
        success      = {r=0.55, g=0.63, b=0.00, a=1.00}, -- #8da101 (Green)
        warning      = {r=0.87, g=0.63, b=0.00, a=1.00}, -- #dfa000 (Yellow)
        error        = {r=0.97, g=0.33, b=0.32, a=1.00}, -- #f85552 (Red)
        crafting     = {r=0.21, g=0.65, b=0.49, a=1.00}, -- #35a77c (Aqua - for progress bars)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Everforest Access: Accessibility-focused dark theme
    -- Based on Everforest Dark with enhanced contrast
    -- ========================================================================
    EverforestAccess = {
        -- Window & Containers
        bg           = {r=0.18, g=0.21, b=0.23, a=0.95}, -- #2d353b (Bg0)
        panel        = {r=0.20, g=0.25, b=0.27, a=1.00}, -- #343f44 (Bg1)
        border       = {r=0.31, g=0.36, b=0.37, a=1.00}, -- #4f585e (Bg3)

        -- Typography
        text         = {r=0.83, g=0.78, b=0.67, a=1.00}, -- #d3c6aa (Fg)
        text_header  = {r=0.90, g=0.85, b=0.72, a=1.00}, -- #e6dfc7 (Pale)
        text_dim     = {r=0.52, g=0.57, b=0.54, a=1.00}, -- #859289 (Grey)

        -- INTERACTIVE: Buttons
        button_normal   = {r=0.24, g=0.28, b=0.30, a=1.00}, -- #3d484d (Bg2)
        button_hover    = {r=0.28, g=0.32, b=0.35, a=1.00}, -- #475258 (Bg3)
        button_active   = {r=0.14, g=0.16, b=0.18, a=1.00}, -- #232a2e (Dim - Pressed)
        button_inactive = {r=0.20, g=0.25, b=0.27, a=0.40}, -- #343f44

        -- Interactive Text
        button_text_norm  = {r=0.83, g=0.78, b=0.67, a=1.00}, -- #d3c6aa
        button_text_hover = {r=1.00, g=1.00, b=1.00, a=1.00}, -- White
        button_text_dis   = {r=0.48, g=0.52, b=0.49, a=1.00}, -- #7a8478

        -- Semantic Accents
        accent       = {r=0.50, g=0.73, b=0.70, a=1.00}, -- #7fbbb3 (Blue)
        success      = {r=0.65, g=0.75, b=0.50, a=1.00}, -- #a7c080 (Green)
        warning      = {r=0.86, g=0.74, b=0.50, a=1.00}, -- #dbbc7f (Yellow)
        error        = {r=0.90, g=0.49, b=0.50, a=1.00}, -- #e67e80 (Red)
        crafting     = {r=0.51, g=0.75, b=0.57, a=1.00}, -- #83c092 (Aqua)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Kanagawa Dark (Wave): Warm ink blacks
    -- ========================================================================
    KanagawaDark = {
        -- Containers
        bg              = {r=0.12, g=0.12, b=0.16, a=0.95}, -- #1F1F28 (Sumi Ink 1)
        panel           = {r=0.21, g=0.21, b=0.27, a=1.00}, -- #363646 (Sumi Ink 3)
        border          = {r=0.09, g=0.09, b=0.11, a=1.00}, -- #16161D (Sumi Ink 0)

        -- Typography
        text            = {r=0.86, g=0.84, b=0.73, a=1.00}, -- #DCD7BA (Fuji White)
        text_header     = {r=0.90, g=0.80, b=0.65, a=1.00}, -- #E6C384 (Carp Yellow)
        text_dim        = {r=0.45, g=0.44, b=0.41, a=1.00}, -- #727169 (Fuji Gray)

        -- Interactive: Buttons
        button_normal   = {r=0.16, g=0.16, b=0.22, a=1.00}, -- #2A2A37 (Sumi Ink 2)
        button_hover    = {r=0.22, g=0.22, b=0.29, a=1.00}, -- #39394d (Custom Lighten)
        button_active   = {r=0.09, g=0.09, b=0.11, a=1.00}, -- #16161D (Sumi Ink 0)
        button_inactive = {r=0.21, g=0.21, b=0.27, a=0.40}, -- #363646 (Faded)

        -- Interactive Text
        button_text_norm  = {r=0.86, g=0.84, b=0.73, a=1.00}, -- #DCD7BA
        button_text_hover = {r=0.49, g=0.61, b=0.85, a=1.00}, -- #7E9CD8 (Crystal Blue)
        button_text_dis   = {r=0.33, g=0.33, b=0.43, a=1.00}, -- #54546D

        -- Semantic
        accent          = {r=0.49, g=0.61, b=0.85, a=1.00}, -- #7E9CD8 (Crystal Blue)
        success         = {r=0.46, g=0.58, b=0.42, a=1.00}, -- #76946A (Autumn Green)
        warning         = {r=1.00, g=0.62, b=0.23, a=1.00}, -- #FF9E3B (Ronin Yellow)
        error           = {r=0.91, g=0.14, b=0.14, a=1.00}, -- #E82424 (Samurai Red)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Kanagawa Light (Lotus): Elegant parchment
    -- ========================================================================
    KanagawaLight = {
        -- Containers
        bg              = {r=0.95, g=0.93, b=0.74, a=0.95}, -- #f2ecbc (Lotus White 3)
        panel           = {r=0.90, g=0.87, b=0.70, a=1.00}, -- #e5e9f0 (Lotus White 2)
        border          = {r=0.54, g=0.54, b=0.50, a=1.00}, -- #8a8980 (Lotus Gray 3)

        -- Typography
        text            = {r=0.33, g=0.33, b=0.39, a=1.00}, -- #545464 (Lotus Ink 1)
        text_header     = {r=0.26, g=0.26, b=0.42, a=1.00}, -- #43436c (Lotus Ink 2)
        text_dim        = {r=0.44, g=0.43, b=0.38, a=1.00}, -- #716e61 (Lotus Gray 2)

        -- Interactive: Buttons
        button_normal   = {r=0.85, g=0.82, b=0.65, a=1.00}, -- #d5d9c7 (Lotus White 1)
        button_hover    = {r=0.80, g=0.77, b=0.60, a=1.00}, -- Darker Parchment
        button_active   = {r=0.95, g=0.93, b=0.74, a=1.00}, -- #f2ecbc (Recedes into BG)
        button_inactive = {r=0.85, g=0.82, b=0.65, a=0.50}, -- Faded

        -- Interactive Text
        button_text_norm  = {r=0.26, g=0.26, b=0.42, a=1.00}, -- #43436c (Lotus Ink 2)
        button_text_hover = {r=0.00, g=0.00, b=0.00, a=1.00}, -- Black
        button_text_dis   = {r=0.63, g=0.61, b=0.68, a=1.00}, -- #a09cac (Lotus Violet 1)

        -- Semantic
        accent          = {r=0.40, g=0.58, b=0.75, a=1.00}, -- #6693bf (Lotus Teal)
        success         = {r=0.42, g=0.58, b=0.54, a=1.00}, -- #6a9589 (Wave Aqua)
        warning         = {r=0.91, g=0.54, b=0.00, a=1.00}, -- #e98a00 (Lotus Orange 2)
        error           = {r=0.77, g=0.29, b=0.43, a=1.00}, -- #c4746e (Dragon Red)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "" },
        },
    },

    -- ========================================================================
    -- Accessibility High Contrast: Maximum visibility
    -- Pure black background with neon accents for vision impairment support
    -- ========================================================================
    AccessibilityHC = {
        -- Containers (High Contrast: Pure Black & White Borders)
        bg              = {r=0.00, g=0.00, b=0.00, a=1.00}, -- #000000 (Pure Black)
        panel           = {r=0.00, g=0.00, b=0.00, a=1.00}, -- #000000
        border          = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF (Pure White)

        -- Typography
        text            = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF
        text_header     = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF
        text_dim        = {r=0.70, g=0.70, b=0.70, a=1.00}, -- #B3B3B3

        -- Interactive: Buttons
        button_normal   = {r=0.20, g=0.20, b=0.20, a=1.00}, -- #333333
        button_hover    = {r=0.40, g=0.40, b=0.40, a=1.00}, -- #666666
        button_active   = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF (Inverted)
        button_inactive = {r=0.10, g=0.10, b=0.10, a=1.00}, -- #1A1A1A

        -- Interactive Text
        button_text_norm  = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF
        button_text_hover = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF
        button_text_dis   = {r=0.50, g=0.50, b=0.50, a=1.00}, -- #808080

        -- Semantic (Vibrant "Neon" for visibility on Black)
        accent          = {r=0.00, g=1.00, b=1.00, a=1.00}, -- #00FFFF (Cyan)
        success         = {r=0.00, g=1.00, b=0.00, a=1.00}, -- #00FF00 (Lime)
        warning         = {r=1.00, g=1.00, b=0.00, a=1.00}, -- #FFFF00 (Yellow)
        error           = {r=1.00, g=0.20, b=0.20, a=1.00}, -- #FF3333 (Bright Red)

        -- Font Definitions
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "OUTLINE" },
            body   = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "OUTLINE" },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 10, flags = "OUTLINE" },
        },
    },

    -- ========================================================================
    -- Housing Theme: Native WoW "Endeavor Tasks" aesthetic
    -- Dark charcoal with bronze/wood trim and Blizzard Gold accents
    -- Uses Blizzard Atlas textures for authentic WoW look
    -- ========================================================================
    HousingTheme = {
        -- Window & Containers
        bg              = {r=0.11, g=0.11, b=0.11, a=0.95}, -- #1c1c1c (Charcoal)
        panel           = {r=0.05, g=0.05, b=0.05, a=0.60}, -- #0d0d0d (Transparent Black)
        border          = {r=0.44, g=0.36, b=0.26, a=1.00}, -- #705c42 (Bronze/Wood)

        -- Atlas Textures (from Blizzard_HousingDashboard)
        atlas = {
            -- Main backgrounds
            background = "housing-dashboard-bg-activity",                  -- Activity panel background
            panelBg = "housing-basic-panel-background",                    -- Basic panel background
            taskRowBg = "housing-dashboard-initiatives-tasks-listitem-bg", -- Task row background
            -- XP/Progress elements
            xpBanner = "housing-dashboard-tasks-listitem-flag",            -- XP/points flag badge
            fillBarBg = "housing-dashboard-fillbar-bar-bg",                -- Fill bar background
            fillBarFill = "housing-dashboard-fillbar-fill",                -- Fill bar fill
            -- Decorative
            divider = "housing-dashboard-divider-horz-tile",               -- Horizontal divider (tileable)
            checkmark = "common-icon-checkmark",                           -- Completion checkmark
            cornerTL = "housing-dashboard-filigree-corner-TL",             -- Filigree corner top-left
            cornerTR = "housing-dashboard-filigree-corner-TR",             -- Filigree corner top-right
            cornerBL = "housing-dashboard-filigree-corner-BL",             -- Filigree corner bottom-left
            cornerBR = "housing-dashboard-filigree-corner-BR",             -- Filigree corner bottom-right
            -- Wood sign header (3-part)
            headerLeft = "housing-dashboard-woodsign-left",                -- Wood sign header (left)
            headerCenter = "housing-dashboard-woodsign-center",            -- Wood sign header (center, tiled)
            headerRight = "housing-dashboard-woodsign-right",              -- Wood sign header (right)
            -- Foliage decorations
            foliageLeft = "housing-dashboard-foliage-header_left",         -- Foliage decoration left
            foliageRight = "housing-foliage-header_right",                 -- Foliage decoration right
            -- Timer elements
            timerBg = "housing-dashboard-timertag-bg",                     -- Timer tag background
            timerIcon = "housing-dashboard-timertag-clock-icon",           -- Timer clock icon
            -- Native UI tabs (proper tab atlases)
            tabActive = "_uiframe-activetab-center",                       -- Active tab (native UI)
            tabInactive = "_uiframe-tab-center",                           -- Inactive tab (native UI)
            tabActiveLeft = "uiframe-activetab-left",                      -- Active tab left cap
            tabActiveRight = "uiframe-activetab-right",                    -- Active tab right cap
            tabInactiveLeft = "uiframe-tab-left",                          -- Inactive tab left cap
            tabInactiveRight = "uiframe-tab-right",                        -- Inactive tab right cap
        },

        -- Typography
        text            = {r=1.00, g=1.00, b=1.00, a=1.00}, -- #FFFFFF (White)
        text_header     = {r=1.00, g=0.82, b=0.00, a=1.00}, -- #FFD100 (Blizzard Gold)
        text_dim        = {r=0.70, g=0.70, b=0.70, a=1.00}, -- #B3B3B3 (Light Grey)
        text_green      = {r=0.25, g=1.00, b=0.25, a=1.00}, -- #40FF40 (Completed Green)

        -- Interactive: Buttons
        button_normal   = {r=0.15, g=0.15, b=0.15, a=0.80}, -- Dark Grey
        button_hover    = {r=0.25, g=0.25, b=0.25, a=0.80}, -- Lighter Grey
        button_active   = {r=0.10, g=0.10, b=0.10, a=1.00}, -- Darker on press
        button_inactive = {r=0.15, g=0.15, b=0.15, a=0.40}, -- Faded

        -- Interactive Text
        button_text_norm  = {r=1.00, g=1.00, b=1.00, a=1.00}, -- White
        button_text_hover = {r=1.00, g=0.82, b=0.00, a=1.00}, -- Blizzard Gold
        button_text_dis   = {r=0.50, g=0.50, b=0.50, a=1.00}, -- Grey

        -- Header Bar (Wood texture background)
        header_bar      = {r=0.27, g=0.18, b=0.11, a=1.00}, -- #452e1c (Dark Wood)

        -- Semantic Accents
        accent          = {r=1.00, g=0.82, b=0.00, a=1.00}, -- Blizzard Gold
        success         = {r=0.25, g=1.00, b=0.25, a=1.00}, -- Completed Green
        warning         = {r=1.00, g=0.60, b=0.00, a=1.00}, -- Orange
        error           = {r=1.00, g=0.25, b=0.25, a=1.00}, -- Red

        -- Font Definitions (FRIZQT for both header and body)
        fonts = {
            header = { file = "Fonts\\FRIZQT__.TTF", size = 14, flags = "", shadow = true },
            body   = { file = "Fonts\\FRIZQT__.TTF", size = 12, flags = "", shadow = true },
            small  = { file = "Fonts\\ARIALN.TTF",   size = 12, flags = "", shadow = true },
        },
    },
}

-- ============================================================================
-- HDG THEME LIFT (2026-07-11) -- palette-per-theme + composer.
-- Lifted from HousingDecorGuide/Core/HDGR_SchemeConstants.lua: each theme is
-- ~16 hex values straight from its upstream (vim/Catppuccin/etc.) source; the
-- composer assembles VWB's flat scheme shape. Adding a theme = one palette
-- table below + a ThemeOrder/Names/DisplayNames entry in Core/Constants.lua.
-- ============================================================================

-- Parse "#RRGGBB" to an rgba table (optional alpha arg). Hard-errors on
-- malformed input rather than letting a tonumber-failure cascade into
-- {r=nil} and a paint-time crash. (HDG's hex(), verbatim behavior.)
local function hex(s, a)
    if type(s) ~= "string" or s:sub(1, 1) ~= "#" or #s ~= 7 then
        error(("hex(): expected \"#RRGGBB\", got %q"):format(tostring(s)), 2)
    end
    local r = tonumber(s:sub(2, 3), 16)
    local g = tonumber(s:sub(4, 5), 16)
    local b = tonumber(s:sub(6, 7), 16)
    if not (r and g and b) then
        error(("hex(): non-hex digits in %q"):format(s), 2)
    end
    return { r = r / 255, g = g / 255, b = b / 255, a = a or 1 }
end

local function withAlpha(c, a) return { r = c.r, g = c.g, b = c.b, a = a } end

-- Locale-safe base font (HDG lesson): FRIZQT__.TTF is LATIN-ONLY; Blizzard's
-- STANDARD_TEXT_FONT points at the correct per-locale file (identical to
-- FRIZQT on enUS/Latin clients). Shared table across the lifted themes.
local _base = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF" -- exception(boundary): Blizzard global, set pre-addon-load
local LIFTED_FONTS = {
    header = { file = _base, size = 14, flags = "" },
    body   = { file = _base, size = 12, flags = "" },
    small  = { file = _base, size = 10, flags = "" },
}

local PALETTE_KEYS = {
    "bg", "panel", "border", "text", "text_header", "text_dim", "text_disabled",
    "button_normal", "button_hover", "button_active", "button_disabled",
    "accent", "accent_brighter", "success", "warning", "error",
}

-- Compose VWB's flat scheme shape from a palette. Loud on a missing key --
-- a silent nil here becomes a paint-time crash six views away.
local function BuildScheme(p)
    for _, key in ipairs(PALETTE_KEYS) do
        if p[key] == nil then error(("BuildScheme: palette missing %q"):format(key), 2) end
    end
    return {
        bg = p.bg, panel = p.panel, border = p.border,
        text = p.text, text_header = p.text_header, text_dim = p.text_dim,
        button_normal = p.button_normal, button_hover = p.button_hover,
        button_active = p.button_active, button_inactive = p.button_disabled,
        button_text_norm = p.text, button_text_hover = p.accent_brighter,
        button_text_dis = p.text_disabled,
        accent = p.accent, success = p.success, warning = p.warning, error = p.error,
        fonts = LIFTED_FONTS,
    }
end

-- Palettes: values verbatim from HDG (each sourced from the theme's upstream).
local Palettes = {}

-- Catppuccin Mocha -- https://github.com/catppuccin/catppuccin#-palette
Palettes.Mocha = {
    bg = hex("#1e1e2e", 0.95), panel = hex("#313244"), border = hex("#6c7086"),
    text = hex("#cdd6f4"), text_header = hex("#cdd6f4"), text_dim = hex("#a6adc8"),
    text_disabled = hex("#6c7086"),
    button_normal = hex("#45475a"), button_hover = hex("#585b70"),
    button_active = hex("#313244"), button_disabled = withAlpha(hex("#45475a"), 0.40),
    accent = hex("#89b4fa"), accent_brighter = hex("#b4befe"),
    success = hex("#a6e3a1"), warning = hex("#f9e2af"), error = hex("#f38ba8"),
}

-- Tokyonight Night -- https://github.com/folke/tokyonight.nvim
Palettes.TokyonightNight = {
    bg = hex("#1a1b26", 0.95), panel = hex("#292e42"), border = hex("#3b4261"),
    text = hex("#c0caf5"), text_header = hex("#c0caf5"), text_dim = hex("#737aa2"),
    text_disabled = hex("#565f89"),
    button_normal = hex("#3b4261"), button_hover = hex("#414868"),
    button_active = hex("#292e42"), button_disabled = withAlpha(hex("#3b4261"), 0.40),
    accent = hex("#7aa2f7"), accent_brighter = hex("#89ddff"),
    success = hex("#9ece6a"), warning = hex("#e0af68"), error = hex("#f7768e"),
}

-- Rose Pine main -- https://rosepinetheme.com/palette
Palettes.RosePineMain = {
    bg = hex("#1f1d2e", 0.95), panel = hex("#26233a"), border = hex("#6e6a86"),
    text = hex("#e0def4"), text_header = hex("#e0def4"), text_dim = hex("#6e6a86"),
    text_disabled = hex("#524f67"),
    button_normal = hex("#403d52"), button_hover = hex("#524f67"),
    button_active = hex("#26233a"), button_disabled = withAlpha(hex("#403d52"), 0.40),
    accent = hex("#9ccfd8"), accent_brighter = hex("#ebbcba"),
    success = hex("#31748f"), warning = hex("#f6c177"), error = hex("#eb6f92"),
}

-- Gruvbox dark hard -- https://github.com/morhetz/gruvbox
Palettes.GruvboxDarkHard = {
    bg = hex("#282828", 0.95), panel = hex("#3c3836"), border = hex("#7c6f64"),
    text = hex("#ebdbb2"), text_header = hex("#fbf1c7"), text_dim = hex("#bdae93"),
    text_disabled = hex("#a89984"),
    button_normal = hex("#504945"), button_hover = hex("#665c54"),
    button_active = hex("#3c3836"), button_disabled = withAlpha(hex("#504945"), 0.40),
    accent = hex("#83a598"), accent_brighter = hex("#8ec07c"),
    success = hex("#b8bb26"), warning = hex("#fabd2f"), error = hex("#fb4934"),
}

-- ColorblindSafe -- WCAG AA; deuteranopia/protanopia/tritanopia safe (HDG original)
Palettes.ColorblindSafe = {
    bg = hex("#101418", 0.95), panel = hex("#182029"), border = hex("#46515D"),
    text = hex("#F1F5F9"), text_header = hex("#FFFFFF"), text_dim = hex("#7E8B99"),
    text_disabled = hex("#5F6A75"),
    button_normal = hex("#32414D"), button_hover = hex("#3C4C59"),
    button_active = hex("#182029"), button_disabled = withAlpha(hex("#32414D"), 0.40),
    accent = hex("#4EA3F1"), accent_brighter = hex("#93C5FD"),
    success = hex("#00A896"), warning = hex("#F2C94C"), error = hex("#D84C8B"),
}

-- Nord -- https://www.nordtheme.com/docs/colors-and-palettes
Palettes.Nord = {
    bg = hex("#2e3440", 0.95), panel = hex("#434c5e"), border = hex("#4c566a"),
    text = hex("#d8dee9"), text_header = hex("#eceff4"), text_dim = hex("#d8dee9"),
    text_disabled = hex("#4c566a"),
    button_normal = hex("#434c5e"), button_hover = hex("#4c566a"),
    button_active = hex("#3b4252"), button_disabled = withAlpha(hex("#434c5e"), 0.40),
    accent = hex("#88c0d0"), accent_brighter = hex("#8fbcbb"),
    success = hex("#a3be8c"), warning = hex("#ebcb8b"), error = hex("#bf616a"),
}

-- Dracula -- https://draculatheme.com/contribute
Palettes.Dracula = {
    bg = hex("#282a36", 0.95), panel = hex("#383a47"), border = hex("#6272a4"),
    text = hex("#f8f8f2"), text_header = hex("#f8f8f2"), text_dim = hex("#6272a4"),
    text_disabled = hex("#44475a"),
    button_normal = hex("#44475a"), button_hover = hex("#6272a4"),
    button_active = hex("#383a47"), button_disabled = withAlpha(hex("#44475a"), 0.40),
    accent = hex("#bd93f9"), accent_brighter = hex("#ff79c6"),
    success = hex("#50fa7b"), warning = hex("#f1fa8c"), error = hex("#ff5555"),
}

-- Nightfly -- https://github.com/bluz71/vim-nightfly-colors
Palettes.Nightfly = {
    bg = hex("#011627", 0.95), panel = hex("#0e293f"), border = hex("#4b6479"),
    text = hex("#c3ccdc"), text_header = hex("#fafafa"), text_dim = hex("#7c8f8f"),
    text_disabled = hex("#4b6479"),
    button_normal = hex("#1d3b53"), button_hover = hex("#2c3043"),
    button_active = hex("#0e293f"), button_disabled = withAlpha(hex("#1d3b53"), 0.40),
    accent = hex("#82aaff"), accent_brighter = hex("#7fdbca"),
    success = hex("#a1cd5e"), warning = hex("#ecc48d"), error = hex("#ff5874"),
}

-- OneNord -- https://github.com/rmehri01/onenord.nvim
Palettes.OneNord = {
    bg = hex("#2e3440", 0.95), panel = hex("#3b4252"), border = hex("#6c7a93"),
    text = hex("#d8dee9"), text_header = hex("#d8dee9"), text_dim = hex("#6c7a93"),
    text_disabled = hex("#4c566a"),
    button_normal = hex("#3b4252"), button_hover = hex("#4c566a"),
    button_active = hex("#2e3440"), button_disabled = withAlpha(hex("#3b4252"), 0.40),
    accent = hex("#81a1c1"), accent_brighter = hex("#88c0d0"),
    success = hex("#a3be8c"), warning = hex("#ebcb8b"), error = hex("#bf616a"),
}

-- Badwolf -- https://github.com/sjl/badwolf
Palettes.Badwolf = {
    bg = hex("#1c1b1a", 0.95), panel = hex("#35322d"), border = hex("#857f78"),
    text = hex("#f8f6f2"), text_header = hex("#ffffff"), text_dim = hex("#998f84"),
    text_disabled = hex("#666462"),
    button_normal = hex("#35322d"), button_hover = hex("#45413b"),
    button_active = hex("#242321"), button_disabled = withAlpha(hex("#35322d"), 0.40),
    accent = hex("#0a9dff"), accent_brighter = hex("#60bfff"),
    success = hex("#aeee00"), warning = hex("#ffa724"), error = hex("#ff2c4b"),
}

-- Purpura -- VSCode Purpura port (HDG's signature pink-on-violet)
Palettes.Purpura = {
    bg = hex("#1e0030", 0.95), panel = hex("#350043"), border = hex("#490e6d"),
    text = hex("#f0f0f0"), text_header = hex("#ffffff"), text_dim = hex("#898989"),
    text_disabled = hex("#808080"),
    button_normal = hex("#471469"), button_hover = hex("#5e0066"),
    button_active = hex("#25003d"), button_disabled = withAlpha(hex("#471469"), 0.40),
    accent = hex("#ff00d4"), accent_brighter = hex("#ff59e3"),
    success = hex("#acff59"), warning = hex("#ffc363"), error = hex("#f44747"),
}

-- Green -- phosphor-terminal green-on-black (HDG original)
Palettes.Green = {
    bg = hex("#030702", 0.95), panel = hex("#0b1606"), border = hex("#448c27"),
    text = hex("#5ec435"), text_header = hex("#72f13e"), text_dim = hex("#356d1e"),
    text_disabled = hex("#254d15"),
    button_normal = hex("#0f1f09"), button_hover = hex("#17300d"),
    button_active = hex("#081105"), button_disabled = withAlpha(hex("#0f1f09"), 0.40),
    accent = hex("#72f13e"), accent_brighter = hex("#9cf578"),
    success = hex("#5ec435"), warning = hex("#c4d62a"), error = hex("#aa3731"),
}

for name, palette in pairs(Palettes) do
    VAMOOSE_SchemeConstants[name] = BuildScheme(palette)
end
