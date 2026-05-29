--[[--
Dispatch predicate for the text-highlight (Path A) branch in
`Pencil:handleStylusSlot` (main.lua:512).

Extracted from main.lua so the routing decision is testable without
require'ing main (which would pull in UIManager / Screen / Blitbuffer /
ReaderUI and break under `busted`). Mirrors the lib/geometry.lua
extraction pattern — pure functions, no UIManager, no plugin instance
state, no side effects.

This module owns two related decisions:

  1. `shouldRouteToTextHighlight(opts)` — should the current stylus slot
     event enter the Path-A call chain (startTextHighlight /
     extendTextHighlight / finishTextHighlight) instead of the freehand
     stroke path? G1-DISPATCH-WIDEN (M2) widens this so that the
     menu-selected highlighter tool ALSO routes to Path A, in addition to
     the pre-existing side-button-promoted-slot-tool route.

  2. `extractWordSet(selection)` — given a selection table as returned
     by `document:getTextFromPositions` (or `getWordFromPosition`),
     extract the whitespace-separated word list. Returns nil when the
     selection is missing, empty, or whitespace-only — which is the
     discard signal for "stroke landed over no text" (edge case decided
     in feature-plan.md §4).

@module pencil.lib.dispatch_predicate
--]]--

local DispatchPredicate = {}

--- Should this slot event be routed through Path A?
--
-- Pure: depends only on the values in `opts`. Caller threads the live
-- Pencil-instance state in.
--
-- Routing fires when the feature flag is on AND at least one of three
-- entry conditions holds:
--   • Side-button promoted: input.lua has set `slot.tool` to the
--     highlighter type code while BTN_STYLUS2 is held. (Pre-M2 path.)
--   • Sticky-during-drag: a Path-A drag is already in flight; route
--     every subsequent slot event until pen-lift so a mid-drag
--     side-button release does not abort the selection.
--   • Menu-selected highlighter: the user has chosen the highlighter
--     tool via the plugin's tool-toggle gesture. (M2 widening — this is
--     the new branch that lets users without BTN_STYLUS2 reach Path A.)
--
-- @param opts table with fields:
--   enabled               (boolean) `self.experimental_text_highlight`
--   slot_tool             (number)  `slot.tool` from the input layer
--   tool_type_highlighter (number)  numeric code input.lua uses for
--                                   the highlighter slot tool
--                                   (mirrors `TOOL_TYPE_HIGHLIGHTER`
--                                   declared in `Pencil:handleStylusSlot`)
--   highlighting          (boolean) `self.highlighting` (sticky state)
--   current_tool          (string)  `self.current_tool`
--   tool_highlighter_name (string)  `TOOL_HIGHLIGHTER` constant value
--                                   (main.lua:42, currently "highlighter")
-- @return boolean
function DispatchPredicate.shouldRouteToTextHighlight(opts)
    if not opts or not opts.enabled then return false end
    -- Side-button-promoted slot tool. Original (pre-M2) entry path.
    if opts.slot_tool == opts.tool_type_highlighter then return true end
    -- Sticky: keep routing until pen-lift even if the side button is
    -- released mid-drag. Without this, releasing BTN_STYLUS2 partway
    -- through a selection would drop the rest of the drag.
    if opts.highlighting then return true end
    -- Menu-selected highlighter tool (M2 widening — G1-DISPATCH-WIDEN).
    -- Lets stylus users without a side button reach Path A by selecting
    -- the highlighter tool from the plugin's tool-toggle gesture.
    if opts.current_tool == opts.tool_highlighter_name then return true end
    return false
end

--- Extract a whitespace-separated word list from a CRengine selection.
--
-- The caller passes the value returned by
-- `document:getTextFromPositions(...)` (extendTextHighlight, main.lua:945)
-- or `document:getWordFromPosition(...)` (startTextHighlight, main.lua:907).
-- Both return a selection dict containing a `text` field on success and
-- nil on error / no-text-here.
--
-- Returns nil when the selection cannot produce any words — this is the
-- discard signal that the integration consumes (no `rh.selected_text`
-- assignment → finishTextHighlight's `has_selection` guard at
-- main.lua:958-959 is false → no `saveHighlight` call → no annotation
-- written). Mirrors the "stroke over no text → discard silently" edge
-- case decided in feature-plan.md §4 row 1.
--
-- @param selection table|nil as returned by CRengine selection APIs
-- @return table|nil array of non-empty word strings, or nil
function DispatchPredicate.extractWordSet(selection)
    if type(selection) ~= "table" then return nil end
    local text = selection.text
    if type(text) ~= "string" or #text == 0 then return nil end
    local words = {}
    for w in string.gmatch(text, "%S+") do
        words[#words + 1] = w
    end
    if #words == 0 then return nil end
    return words
end

return DispatchPredicate
