-- ============================================================================
-- VWB namespace bootstrap - LOADED FIRST.
-- ============================================================================
-- Unifies the two module styles under ONE table:
--   * signals-native modules (Reactor/Layout/Showroom) take the addon private
--     table via `local _, ns = ...`
--   * modules ported from VamoosePowerCrafter use a bare global `VWB`
-- Setting _G.VWB to the private table makes `ns` and `VWB` the same object, so
-- ported files need only a VPC->VWB rename (no vararg plumbing). MUST be the
-- first entry in the .toc, before any file that reads `VWB` or `ns`.
-- ============================================================================

local _, ns = ...
_G.VWB = ns
VWB_DB = VWB_DB or {}

-- Midnight secret-value scrub (Reference/MIDNIGHT_SECRET_VALUES.md). Guild /
-- club / recipe-member fields describe OTHER players and can come back secret in
-- protected contexts; a captured secret crashes far away later -- as a table key,
-- in a sort comparator, or via SetText -> width contagion inside Blizzard layout
-- code. Treat a secret as "unknowable right now" (nil); the next event refills.
-- MANDATORY on GuildCrafters' guild/club/recipe-member reads.
function VWB.NoSecret(v)
    if issecretvalue(v) then return nil end -- exception(boundary): guild/club fields secret in protected contexts
    return v
end
