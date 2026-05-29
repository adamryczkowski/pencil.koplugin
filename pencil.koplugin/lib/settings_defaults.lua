--[[--
Settings-default resolution for the pencil plugin.

Extracted from main.lua:1118 (Pencil:loadSettings) so the
"what does an empty / partial settings file resolve to?" decision is
testable without require'ing main.

Currently only owns one decision — the M4 G1-FLIP-DEFAULT flip of
`experimental_text_highlight` from `false` to `true` — but the module
is the natural home for any future defaults that depend on
gate-audit-style preconditions (i.e. defaults that turned over once
their gate reasons were resolved).

Design contract for every helper in here:
  • Pure: depends only on the `settings` argument, no global reads.
  • Defensive: a nil / non-table / partial settings argument must
    never crash; the function returns the new-build default.
  • Idempotent for explicit values: if the user has previously written
    `true` or `false` into their settings, the helper must honour that
    value verbatim. New defaults only apply when the key is absent.
  • Kill-switch preserving: explicit `false` continues to return
    `false` after the default flip so users who prefer the legacy
    behaviour can opt out via the menu toggle.

@module pencil.lib.settings_defaults
--]]--

local SettingsDefaults = {}

--- Resolve `experimental_text_highlight` from a settings table.
--
-- M4 G1-FLIP-DEFAULT semantics (post-flip):
--   • absent key or nil settings   → true  (new build default)
--   • explicit user value `false`  → false (kill-switch preserved)
--   • explicit user value `true`   → true  (idempotent)
--   • non-boolean value (corrupt settings) → true (treat as absent;
--     defensive — never preserve a malformed toggle as opt-out)
--
-- Precondition (documented in
-- AI-docs/annotation-text-anchoring/gate-audit.md): all three gate
-- reasons stated at main.lua:1420 are resolved. R1 (new integration)
-- by the P0–P4 hardening cycle; R2 (edge cases) by feature-plan.md §4
-- decisions and the M2/M5 spec coverage; R3 (BTN_STYLUS2 dependency)
-- by the M2 G1-DISPATCH-WIDEN predicate widening.
--
-- @param settings table|nil — `G_reader_settings:readSetting(...)` shape
-- @return boolean
function SettingsDefaults.experimentalTextHighlight(settings)
    if type(settings) ~= "table" then
        return true  -- nil / non-table = no prior user state = use new default
    end
    local v = settings.experimental_text_highlight
    if v == false then
        -- Kill-switch: explicit opt-out persists across the flip. The
        -- only way this resolves to false. Required so users who
        -- preferred the freehand-only behaviour can disable Path A via
        -- the menu toggle at main.lua:1418-1439.
        return false
    end
    -- Every other case (nil / true / corrupt / non-boolean) collapses
    -- to the new build default.
    return true
end

return SettingsDefaults
