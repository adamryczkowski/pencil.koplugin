--[[--
Unit tests for `lib/dispatch_predicate.shouldRouteToTextHighlight`.

Covers the M2 G1-DISPATCH-WIDEN widening of the dispatch predicate at
main.lua:512: the menu-selected highlighter tool must route through
Path A even when the side button is OFF, while the pre-existing
side-button-promoted route and the sticky-during-drag invariant must
continue to fire (regression guard).

Pure-Lua test against the extracted lib/ module — no main.lua require,
no input.lua require, no UIManager, no Screen. Tool constants are
mirrored as Lua literals matching main.lua:42-44.

Run with: busted spec/pencil_text_highlight_dispatch_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local DispatchPredicate = require("lib/dispatch_predicate")

-- Tool constants — mirror main.lua:42-44 literals; do NOT require('input').
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"
local TOOL_TYPE_HIGHLIGHTER = 3  -- main.lua:432 (local in handleStylusSlot)
local TOOL_TYPE_ERASER = 2

-- Convenience for spec readability: build an opts table with sensible
-- defaults and let each `it` override only the field under test.
local function opts(over)
    local o = {
        enabled = true,
        slot_tool = 0,
        tool_type_highlighter = TOOL_TYPE_HIGHLIGHTER,
        highlighting = false,
        current_tool = TOOL_PEN,
        tool_highlighter_name = TOOL_HIGHLIGHTER,
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end

describe("DispatchPredicate.shouldRouteToTextHighlight", function()

    describe("M2 widening — menu-selected highlighter, side-button OFF", function()
        it("routes to Path A when current_tool is highlighter and slot_tool is not promoted", function()
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                current_tool = TOOL_HIGHLIGHTER,
                slot_tool = 0,           -- side button OFF: no promotion
                highlighting = false,
            })
            assert.is_true(r)
        end)

        it("routes to Path A when current_tool is highlighter even with slot_tool == eraser-code", function()
            -- Defensive: the menu-tool decision is independent of the input
            -- layer's slot_tool field. Side-button state is irrelevant here.
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                current_tool = TOOL_HIGHLIGHTER,
                slot_tool = TOOL_TYPE_ERASER,
                highlighting = false,
            })
            assert.is_true(r)
        end)
    end)

    describe("regression — side-button promoted (BTN_STYLUS2)", function()
        it("routes to Path A when slot_tool == tool_type_highlighter (original path)", function()
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                slot_tool = TOOL_TYPE_HIGHLIGHTER,
                current_tool = TOOL_PEN,  -- menu tool is pen; side button promotes
            })
            assert.is_true(r)
        end)
    end)

    describe("sticky during drag", function()
        it("continues to route while highlighting is true (side button released mid-drag)", function()
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                slot_tool = 0,           -- side button OFF (released mid-drag)
                current_tool = TOOL_PEN, -- menu tool is pen
                highlighting = true,     -- in-progress Path-A drag
            })
            assert.is_true(r)
        end)
    end)

    describe("non-routing cases", function()
        it("does NOT route when current_tool is pen and no side-button promotion", function()
            -- Pen + no side button = the freehand-stroke path; must stay out
            -- of Path A or every pen stroke would become a text highlight.
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                current_tool = TOOL_PEN,
                slot_tool = 0,
                highlighting = false,
            })
            assert.is_false(r)
        end)

        it("does NOT route when current_tool is eraser", function()
            -- Eraser must reach the eraser branch lower in handleStylusSlot,
            -- not enter Path A.
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                current_tool = TOOL_ERASER,
                slot_tool = 0,
                highlighting = false,
            })
            assert.is_false(r)
        end)
    end)

    describe("kill-switch — enabled = false", function()
        it("never routes when enabled is false, even with menu tool = highlighter", function()
            -- Mirrors the M4 kill-switch contract: user toggling the
            -- experimental_text_highlight menu OFF must fully disable Path A.
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                enabled = false,
                current_tool = TOOL_HIGHLIGHTER,
                slot_tool = TOOL_TYPE_HIGHLIGHTER,
                highlighting = false,
            })
            assert.is_false(r)
        end)

        it("never routes when enabled is false, even mid-drag (defensive)", function()
            local r = DispatchPredicate.shouldRouteToTextHighlight(opts{
                enabled = false,
                highlighting = true,
                current_tool = TOOL_PEN,
                slot_tool = 0,
            })
            assert.is_false(r)
        end)
    end)

    describe("input robustness", function()
        it("returns false for nil opts (defensive)", function()
            assert.is_false(DispatchPredicate.shouldRouteToTextHighlight(nil))
        end)

        it("returns false for empty opts table (no flags set)", function()
            assert.is_false(DispatchPredicate.shouldRouteToTextHighlight({}))
        end)
    end)

end)
