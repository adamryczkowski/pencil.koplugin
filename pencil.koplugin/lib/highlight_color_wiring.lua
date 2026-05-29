--[[--
Color/drawer wiring for Path-A text highlights.

Extracted from main.lua:919-926 (startTextHighlight first-word preview)
and main.lua:958-962 (extendTextHighlight multi-word selection) so the
"what visual style does the saved Path-A annotation land with?"
decision is testable without require'ing main.

Without this wiring, the rh.selected_text dict that
ReaderHighlight:saveHighlight consumes carries no drawer or color
fields, so KOReader falls back to whatever drawer/color
ReaderHighlight last had — typically the legacy default, which is a
visible color regression on stationary renders (REQUIREMENTS_FILE
"No regression on stationary renders").

The Path-A contract is:
  drawer  = 'lighten'   — multiply-blend mode used for all highlighter
                          renders (matches the per-tool color decision
                          on Path B and KOReader's own highlighter)
  color   = the color_name string of the user's currently-active
            highlighter palette entry; the saved annotation references
            colors by NAME so they survive palette refresh and theme
            changes (KOReader resolves name → RGB at paint time)

@module pencil.lib.highlight_color_wiring
--]]--

local HighlightColorWiring = {}

-- Tool key — mirrors the local TOOL_HIGHLIGHTER literal at main.lua:42.
-- Hard-coded here rather than passed in because this module is
-- specifically the wiring for the *highlighter* tool; passing the key
-- would just be ceremony.
local TOOL_HIGHLIGHTER = "highlighter"

-- The drawer value attached to every Path-A item. 'lighten' is the
-- multiply-blend mode used by readerview.lua:666 drawHighlightRect and
-- matches the Pencil-side multiplyRectHighlighter mapping (main.lua
-- post-P3b rename). Constant rather than configurable: a different
-- drawer would no longer be a "highlight" by the operator's framing.
local DRAWER_LIGHTEN = "lighten"

--- Resolve the {drawer, color} pair to attach to rh.selected_text so
-- a subsequent ReaderHighlight:saveHighlight call builds a Path-A item
-- with the active highlighter color.
--
-- Pure: depends only on `tool_settings`. Caller is responsible for
-- threading self.tool_settings in at the call site.
--
-- Returns nil if the tool_settings table or its highlighter entry is
-- missing/malformed — caller treats nil as "no wiring; let KOReader
-- use its current default" (defensive: never crash a save just because
-- settings are unreadable).
--
-- Returns { drawer = 'lighten', color = nil } when the highlighter
-- entry exists but has no usable color_name. The drawer is still set
-- (lighten is the right blend mode regardless of which color the user
-- has picked); the color falls back to whatever KOReader chose, which
-- is functionally the same as the pre-M3 behavior.
--
-- @param tool_settings table — self.tool_settings (Pencil instance)
-- @return table { drawer, color } | nil
function HighlightColorWiring.resolve(tool_settings)
    if type(tool_settings) ~= "table" then return nil end
    local entry = tool_settings[TOOL_HIGHLIGHTER]
    if type(entry) ~= "table" then return nil end
    local color_name = entry.color_name
    if type(color_name) ~= "string" or #color_name == 0 then
        -- Highlighter entry exists but no usable color_name. Still
        -- attach the drawer so the blend mode is right; color falls
        -- through to KOReader's current default.
        return { drawer = DRAWER_LIGHTEN, color = nil }
    end
    return { drawer = DRAWER_LIGHTEN, color = color_name }
end

--- Apply the resolved {drawer, color} to a selected-text dict in
-- place. Helper for the call sites in startTextHighlight /
-- extendTextHighlight so the wiring is a single function call rather
-- than four assignment lines duplicated across two sites.
--
-- No-op when wiring is nil (preserves existing dict fields) or when
-- selected_text is not a table (defensive — the caller should have
-- already filtered nil/error returns from CRengine).
--
-- @param selected_text table — rh.selected_text dict (mutated)
-- @param wiring table|nil    — return value of .resolve()
-- @return table — same selected_text reference (for chaining)
function HighlightColorWiring.apply(selected_text, wiring)
    if type(selected_text) ~= "table" or type(wiring) ~= "table" then
        return selected_text
    end
    selected_text.drawer = wiring.drawer
    selected_text.color = wiring.color
    return selected_text
end

-- Exposed for spec assertions; not consumed by main.lua.
HighlightColorWiring.DRAWER_LIGHTEN = DRAWER_LIGHTEN
HighlightColorWiring.TOOL_HIGHLIGHTER = TOOL_HIGHLIGHTER

return HighlightColorWiring
