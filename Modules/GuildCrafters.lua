VWB = VWB or {}
VWB.GuildCrafters = {}

-- ============================================================================
-- VamoosesWorkbench - GuildCrafters
-- "Who in my guild can craft this?" Roster cache (debounced) + C_Club
-- profession enrichment + per-recipe QueryGuildMembersForRecipe. Lifted from
-- VamoosesGuildCraft's GuildQuery.lua, with CraftingOrdersHook's scanSession
-- token discipline added on top (GuildQuery.lua on its own accepts stray
-- results while idle). No UI consumer this round -- module + event only.
-- See docs/VPC_PORTABLE_PATTERNS_2026-07-04.md section 5.4.
-- ============================================================================

local GC = VWB.GuildCrafters
local GQ = VWB.Constants.GuildQuery

GC.roster = {}             -- [fullName] = { class, classFile, online, zone, rank, level, prof1Name, prof1ID, prof2Name, prof2ID, presence }
GC.craftersByRecipe = {}   -- session cache: [recipeID] = { crafters = {...}, dataHole = bool }
GC.rosterDebounceTimer = nil

GC.scanSession = 0          -- integer token; bumped per Query() call, re-checked in every deferred closure
GC.pendingRecipeID = nil    -- recipeID the CURRENT scanSession is waiting on (unsolicited-result guard)
GC.queryList = {}           -- direct professionID, then parentProfessionID (no guild-wide crawl)
GC.queryIndex = 0

local function DebugPrint(msg)
    VWB.Log:Debug("GuildCrafters: " .. msg)
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function GC:Initialize()
    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
    self.eventFrame:RegisterEvent("GUILD_RECIPE_KNOWN_BY_MEMBERS")
    self.eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "GUILD_ROSTER_UPDATE" then
            self:DebouncedRosterRefresh()
        elseif event == "GUILD_RECIPE_KNOWN_BY_MEMBERS" then
            self:OnRecipeKnownByMembers()
        end
    end)

    if IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end

-- ============================================================================
-- ROSTER CACHE (debounced GUILD_ROSTER_UPDATE + C_Club enrichment)
-- ============================================================================

function GC:DebouncedRosterRefresh()
    if self.rosterDebounceTimer then
        self.rosterDebounceTimer:Cancel()
    end
    self.rosterDebounceTimer = C_Timer.NewTimer(GQ.ROSTER_DEBOUNCE, function()
        self:RefreshRoster()
    end)
end

function GC:RefreshRoster()
    local numTotal = GetNumGuildMembers()
    if not numTotal or numTotal == 0 then return end

    local newRoster = {}
    local NS = VWB.NoSecret -- secret-capture boundary; a secret name would even crash as a table key
    for i = 1, numTotal do
        local name, rankName, rankIndex, level, classDisplayName, zone,
              _, _, online, _, classFile = GetGuildRosterInfo(i)
        name = NS(name)
        if name then
            newRoster[name] = {
                class = NS(classDisplayName),
                classFile = NS(classFile),
                online = NS(online),
                zone = NS(zone) or "",
                rank = NS(rankName),
                rankIndex = NS(rankIndex),
                level = NS(level),
            }
        end
    end

    self:EnrichFromClub(newRoster)
    self.roster = newRoster
    VWB.EventBus:Trigger("VWB_ROSTER_UPDATED", {})
end

function GC:EnrichFromClub(members)
    local NS = VWB.NoSecret -- secret-capture boundary; club reads describe other players
    local clubId = NS(C_Club.GetGuildClubId()) -- exception(boundary): nil outside a guild club; secret in protected contexts
    if not clubId then return end

    -- O(1) lookup indexes: full name and short name -> roster entry
    local byFull, byShort = {}, {}
    for name, m in pairs(members) do
        byFull[name] = m
        local short = name:match("^([^-]+)")
        if short then byShort[short] = m end
    end

    local clubMembers = NS(C_Club.GetClubMembers(clubId)) -- exception(boundary): whole memberId array comes back secret in protected contexts
    if not clubMembers then return end
    for _, memberId in ipairs(clubMembers) do
        local info = NS(C_Club.GetMemberInfo(clubId, memberId)) -- exception(boundary): nil mid-roster-update; whole struct secret in protected contexts
        local memberName = info and NS(info.name) -- exception(boundary): name field can be secret independently
        local matched = memberName and (byFull[memberName] or byShort[memberName])
        if matched then
            matched.prof1Name = NS(info.profession1Name) or ""
            matched.prof1ID   = NS(info.profession1ID) or 0
            matched.prof2Name = NS(info.profession2Name) or ""
            matched.prof2ID   = NS(info.profession2ID) or 0
            matched.presence  = NS(info.presence)
        end
    end
end

function GC:GetRosterEntry(fullName)
    return self.roster[fullName]
end

-- ============================================================================
-- CRAFTER QUERY (direct + parent professionID only; scanSession token discipline)
-- ============================================================================

-- Async: result (or a timeout-driven dataHole) arrives via VWB_CRAFTERS_UPDATED
-- { recipeID, crafters, dataHole }. dataHole=true means "Blizzard doesn't
-- track this recipe" (silence), distinct from a legitimate empty crafters list.
function GC:Query(recipeID)
    if not IsInGuild() then
        DebugPrint("Not in a guild")
        return
    end

    self.scanSession = self.scanSession + 1
    local session = self.scanSession
    self.pendingRecipeID = recipeID

    local profInfo = C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
    self.queryList = {}
    if profInfo and profInfo.professionID then
        table.insert(self.queryList, profInfo.professionID)
    end
    if profInfo and profInfo.parentProfessionID and profInfo.parentProfessionID ~= profInfo.professionID then
        table.insert(self.queryList, profInfo.parentProfessionID)
    end

    if #self.queryList == 0 then
        self:FinishQuery(session, recipeID, {}, true)
        return
    end

    self.queryIndex = 0
    self:TryNextProfession(session, recipeID)
end

function GC:TryNextProfession(session, recipeID)
    if session ~= self.scanSession then return end -- superseded by a newer Query()

    self.queryIndex = self.queryIndex + 1
    local skillLineID = self.queryList[self.queryIndex]
    if not skillLineID then
        -- Exhausted direct + parent professionID -- Blizzard's guild data has
        -- a gap for this recipe, not "nobody in the guild can craft it".
        self:FinishQuery(session, recipeID, {}, true)
        return
    end

    C_GuildInfo.QueryGuildMembersForRecipe(skillLineID, recipeID, 1)

    C_Timer.After(GQ.CRAFTER_TIMEOUT, function()
        if session ~= self.scanSession then return end
        if self.pendingRecipeID == recipeID and self.queryList[self.queryIndex] == skillLineID then
            self:TryNextProfession(session, recipeID)
        end
    end)
end

function GC:OnRecipeKnownByMembers()
    if not self.pendingRecipeID then return end -- unsolicited: no query in flight

    local _, recipeID, numMembers = GetGuildRecipeInfoPostQuery()
    if not recipeID or recipeID ~= self.pendingRecipeID then return end -- stale/different query's result

    local session = self.scanSession
    local crafters = {}
    if numMembers and numMembers > 0 then
        local NS = VWB.NoSecret -- secret-capture boundary; name/online feed the sort + row text
        for i = 1, numMembers do
            local displayName, fullName, classFileName, online = GetGuildRecipeMember(i)
            displayName, fullName, classFileName, online = NS(displayName), NS(fullName), NS(classFileName), NS(online)
            local rosterEntry = fullName and self.roster[fullName]
            table.insert(crafters, {
                name = fullName or displayName or "?",
                displayName = displayName or "?",
                classFile = classFileName or "WARRIOR",
                online = online or false,
                zone = rosterEntry and rosterEntry.zone or "",
                rank = rosterEntry and rosterEntry.rank or "",
            })
        end
    end

    table.sort(crafters, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.name < b.name
    end)

    if #crafters > 0 then
        self:FinishQuery(session, recipeID, crafters, false)
    else
        -- This profession had no crafters; try the next candidate (parent),
        -- or dataHole once direct+parent are both exhausted.
        self:TryNextProfession(session, recipeID)
    end
end

function GC:FinishQuery(session, recipeID, crafters, dataHole)
    if session ~= self.scanSession then return end -- superseded

    self.pendingRecipeID = nil

    local cacheCount = 0
    for _ in pairs(self.craftersByRecipe) do cacheCount = cacheCount + 1 end
    if cacheCount >= GQ.MAX_CACHED_RECIPES then
        for k in pairs(self.craftersByRecipe) do
            self.craftersByRecipe[k] = nil -- arbitrary eviction; session cache, not correctness-critical
            break
        end
    end
    self.craftersByRecipe[recipeID] = { crafters = crafters, dataHole = dataHole }

    VWB.EventBus:Trigger("VWB_CRAFTERS_UPDATED", { recipeID = recipeID, crafters = crafters, dataHole = dataHole })
end

function GC:GetCrafters(recipeID)
    return self.craftersByRecipe[recipeID]
end

-- ============================================================================
-- TOOLTIP SURFACING
-- Appends the guild-crafters block to a live GameTooltip. Cache hit paints
-- immediately; a miss shows "checking..." and fires Query -- when the async
-- result lands and the SAME recipe's tooltip is still up, the lines fill in.
-- ============================================================================

local MAX_TOOLTIP_CRAFTERS = 5

local function AddCraftersLines(tooltip, result)
    tooltip:AddLine(" ")
    if result.dataHole then
        tooltip:AddLine(VWB.UI:ColorCode("base01") .. "Guild crafters: not tracked by Blizzard|r")
        return
    end
    if #result.crafters == 0 then
        tooltip:AddLine(VWB.UI:ColorCode("base01") .. "Guild crafters: none|r")
        return
    end
    tooltip:AddLine(VWB.UI:ColorCode("cyan") .. "Guild crafters:|r")
    for i, crafter in ipairs(result.crafters) do
        if i > MAX_TOOLTIP_CRAFTERS then
            tooltip:AddLine(VWB.UI:ColorCode("base01") .. "  +" .. (#result.crafters - MAX_TOOLTIP_CRAFTERS) .. " more|r")
            break
        end
        local color = RAID_CLASS_COLORS[crafter.classFile] or { r = 1, g = 1, b = 1 } -- exception(boundary): classFile is guild-API data
        local status = crafter.online and "|cFF00FF00online|r" or (VWB.UI:ColorCode("base01") .. "offline|r")
        tooltip:AddDoubleLine("  " .. crafter.displayName, status, color.r, color.g, color.b, 1, 1, 1)
    end
end

-- Works against any surface speaking the GameTooltip append dialect
-- (AddLine/AddDoubleLine/Show/IsShown) -- rows pass VWB.UI.Tooltip now, but
-- GameTooltip still works for any future ambient-tooltip integration.
function GC:AppendCraftersToTooltip(tooltip, recipeID)
    if not recipeID or not IsInGuild() then return end
    local cached = self.craftersByRecipe[recipeID]
    if cached then
        self._tooltipRecipeID = nil
        self._tooltipFrame = nil
        self._tooltipLineCount = nil
        AddCraftersLines(tooltip, cached)
    else
        self._tooltipLineCount = tooltip:GetNumLines() -- snapshot: fill-in rolls the placeholder back
        tooltip:AddLine(" ")
        tooltip:AddLine(VWB.UI:ColorCode("base01") .. "Guild crafters: checking...|r")
        self._tooltipRecipeID = recipeID
        self._tooltipFrame = tooltip
        self:Query(recipeID)
    end
    tooltip:Show()
end

-- Rows call this from OnLeave so a late result can't append to whatever
-- unrelated tooltip happens to be showing by then
function GC:CancelTooltip()
    self._tooltipRecipeID = nil
    self._tooltipFrame = nil
    self._tooltipLineCount = nil
end

-- Mid-hover fill-in for queried results: appends to the SAME surface the
-- "checking..." line went to, if it's still up
VWB.EventBus:Register("VWB_CRAFTERS_UPDATED", function(payload)
    local tipFrame = GC._tooltipFrame
    if GC._tooltipRecipeID == payload.recipeID and tipFrame and tipFrame:IsShown() then
        local lineCount = GC._tooltipLineCount
        GC._tooltipRecipeID = nil
        GC._tooltipFrame = nil
        GC._tooltipLineCount = nil
        if tipFrame.TruncateTo then -- exception(boundary): GameTooltip surface can't remove lines, so the placeholder stays and the block appends below it
            tipFrame:TruncateTo(lineCount) -- drop the "checking..." placeholder block
        end
        AddCraftersLines(tipFrame, payload)
        tipFrame:Show()
    end
end)

function GC:ClearCache()
    self.craftersByRecipe = {}
    self.pendingRecipeID = nil
end
