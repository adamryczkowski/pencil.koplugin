--[[--
Unit tests for `lib/highlight_color_wiring`.

Covers the M3 G1-COLOR-WIRING decision: a saved Path-A highlight
annotation must carry drawer='lighten' and color=<active tool color
name>, so the saved item renders in the user's chosen highlighter
color on every reflow / restore (not in KOReader's default highlight
color, which would be a visible regression on stationary renders per
REQUIREMENTS_FILE).

Pure-Lua test against the extracted lib/ module — no main.lua require,
no ReaderHighlight require, no UIManager. The integration sites
(main.lua:919-926 startTextHighlight and :958-962 extendTextHighlight)
are simulated by mirroring the assignment-and-readback boundary.

Run with: busted spec/pencil_text_highlight_color_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local HighlightColorWiring = require("lib/highlight_color_wiring")

-- Tool constant — mirrors main.lua:42 literal; do NOT require('input').
local TOOL_HIGHLIGHTER = "highlighter"

describe("HighlightColorWiring.resolve — positive cases", function()

    it("returns drawer='lighten' and color='yellow' for an active yellow tool", function()
        local tool_settings = {
            [TOOL_HIGHLIGHTER] = { color_name = "yellow", color = "<fake_bb>" },
        }
        local w = HighlightColorWiring.resolve(tool_settings)
        assert.is_table(w)
        assert.equals("lighten", w.drawer)
        assert.equals("yellow", w.color)
    end)

    it("returns drawer='lighten' regardless of which palette name is set", function()
        for _, name in ipairs({ "Yellow", "Green", "Pink", "Cyan", "Orange" }) do
            local w = HighlightColorWiring.resolve({
                [TOOL_HIGHLIGHTER] = { color_name = name },
            })
            assert.equals("lighten", w.drawer)
            assert.equals(name, w.color)
        end
    end)

    it("ignores the raw color (Blitbuffer object) — only color_name reaches the saved item", function()
        -- Path A persists colors by name; KOReader resolves name -> RGB at
        -- paint time. The raw `color` field on tool_settings is used by
        -- Path-B native rendering and is not part of the Path-A persistence
        -- contract.
        local tool_settings = {
            [TOOL_HIGHLIGHTER] = { color_name = "Green", color = nil },
        }
        local w = HighlightColorWiring.resolve(tool_settings)
        assert.equals("Green", w.color)
    end)

    it("exposes DRAWER_LIGHTEN as a stable string", function()
        assert.equals("lighten", HighlightColorWiring.DRAWER_LIGHTEN)
    end)

end)

describe("HighlightColorWiring.resolve — degraded cases (drawer still set, color falls back)", function()

    it("returns drawer='lighten' with color=nil when color_name field is missing", function()
        local w = HighlightColorWiring.resolve({ [TOOL_HIGHLIGHTER] = {} })
        assert.is_table(w)
        assert.equals("lighten", w.drawer)
        assert.is_nil(w.color)
    end)

    it("returns drawer='lighten' with color=nil when color_name is empty string", function()
        local w = HighlightColorWiring.resolve({ [TOOL_HIGHLIGHTER] = { color_name = "" } })
        assert.equals("lighten", w.drawer)
        assert.is_nil(w.color)
    end)

    it("returns drawer='lighten' with color=nil when color_name is non-string", function()
        local w = HighlightColorWiring.resolve({ [TOOL_HIGHLIGHTER] = { color_name = 42 } })
        assert.equals("lighten", w.drawer)
        assert.is_nil(w.color)
    end)

end)

describe("HighlightColorWiring.resolve — input robustness", function()

    it("returns nil for nil tool_settings (no crash on uninitialised state)", function()
        assert.is_nil(HighlightColorWiring.resolve(nil))
    end)

    it("returns nil for non-table tool_settings (defensive)", function()
        assert.is_nil(HighlightColorWiring.resolve("oops"))
        assert.is_nil(HighlightColorWiring.resolve(42))
        assert.is_nil(HighlightColorWiring.resolve(false))
    end)

    it("returns nil when the TOOL_HIGHLIGHTER entry is missing", function()
        assert.is_nil(HighlightColorWiring.resolve({}))
    end)

    it("returns nil when the TOOL_HIGHLIGHTER entry is not a table", function()
        assert.is_nil(HighlightColorWiring.resolve({ [TOOL_HIGHLIGHTER] = "oops" }))
    end)

    it("does not throw on any of these inputs", function()
        assert.has_no.errors(function()
            HighlightColorWiring.resolve(nil)
            HighlightColorWiring.resolve({})
            HighlightColorWiring.resolve({ [TOOL_HIGHLIGHTER] = nil })
            HighlightColorWiring.resolve({ [TOOL_HIGHLIGHTER] = { color_name = "" } })
        end)
    end)

end)

describe("HighlightColorWiring.apply — in-place assignment to selected_text", function()

    it("sets drawer and color fields on the dict", function()
        local sel = { text = "hello", pos0 = "x", pos1 = "y" }
        local wiring = { drawer = "lighten", color = "Yellow" }
        HighlightColorWiring.apply(sel, wiring)
        assert.equals("lighten", sel.drawer)
        assert.equals("Yellow", sel.color)
    end)

    it("returns the same selected_text reference (chainable)", function()
        local sel = { text = "x" }
        local returned = HighlightColorWiring.apply(sel, { drawer = "lighten", color = "Y" })
        assert.is_true(returned == sel)
    end)

    it("is a no-op when wiring is nil (preserves dict)", function()
        local sel = { text = "x", drawer = "preexisting", color = "preexisting" }
        HighlightColorWiring.apply(sel, nil)
        assert.equals("preexisting", sel.drawer)
        assert.equals("preexisting", sel.color)
    end)

    it("is a no-op when selected_text is nil (no crash)", function()
        assert.has_no.errors(function()
            HighlightColorWiring.apply(nil, { drawer = "lighten", color = "Y" })
        end)
    end)

end)

-- ---------------------------------------------------------------------
-- Integration contract — simulator of finishTextHighlight save path
-- ---------------------------------------------------------------------

-- Mirrors the M3 wiring path:
--   1. startTextHighlight (main.lua:919-926) builds rh.selected_text
--      and applies the wiring;
--   2. extendTextHighlight (main.lua:958-962) overwrites
--      rh.selected_text and re-applies the wiring on each extend;
--   3. finishTextHighlight (main.lua:982) calls rh:saveHighlight which
--      reads drawer + color off rh.selected_text and writes them onto
--      the saved annotation item.
local function simulateFinish(tool_settings, raw_selected_text)
    local rh = { selected_text = raw_selected_text }
    local wiring = HighlightColorWiring.resolve(tool_settings)
    HighlightColorWiring.apply(rh.selected_text, wiring)
    -- saveHighlight builds the item from rh.selected_text — mirror only
    -- the fields the M3 contract asserts on.
    return {
        drawer = rh.selected_text.drawer,
        color  = rh.selected_text.color,
        text   = rh.selected_text.text,
        pos0   = rh.selected_text.pos0,
        pos1   = rh.selected_text.pos1,
    }
end

describe("Integration: finishTextHighlight saved-item contract (M3 spec ①)", function()

    it("saved annotation item has drawer='lighten' and color='yellow' for active yellow tool", function()
        -- VERBATIM the M3 acceptance criterion from feature-plan.md §6
        -- and milestone-implementer-instructions.md §Milestone 3 Spec ①:
        --   Given: Path-A highlight save call; tool color = "yellow"; active TOOL_HIGHLIGHTER
        --   When:  finishTextHighlight runs
        --   Then:  saved annotation item has item.drawer == 'lighten' AND item.color == "yellow"
        local tool_settings = {
            [TOOL_HIGHLIGHTER] = { color_name = "yellow" },
        }
        local raw = {
            text = "the quick brown fox",
            pos0 = "/body/p[1].0",
            pos1 = "/body/p[1].19",
            sboxes = {}, pboxes = {},
        }
        local item = simulateFinish(tool_settings, raw)
        assert.equals("lighten", item.drawer)
        assert.equals("yellow", item.color)
        -- Sanity: the other fields survive the wiring step.
        assert.equals("the quick brown fox", item.text)
        assert.equals("/body/p[1].0", item.pos0)
        assert.equals("/body/p[1].19", item.pos1)
    end)

    it("re-applying wiring after a tool color change picks up the new color", function()
        -- User selects yellow, starts a drag, then changes to pink mid-book.
        -- The next stroke must land with pink, not yellow.
        local tool_settings = {
            [TOOL_HIGHLIGHTER] = { color_name = "yellow" },
        }
        local raw1 = { text = "first", pos0 = "a", pos1 = "b" }
        local item1 = simulateFinish(tool_settings, raw1)
        assert.equals("yellow", item1.color)

        tool_settings[TOOL_HIGHLIGHTER].color_name = "pink"
        local raw2 = { text = "second", pos0 = "c", pos1 = "d" }
        local item2 = simulateFinish(tool_settings, raw2)
        assert.equals("pink", item2.color)
        assert.equals("lighten", item2.drawer)
    end)

    it("does not strip existing pos0/pos1 fields off the selection dict", function()
        local tool_settings = {
            [TOOL_HIGHLIGHTER] = { color_name = "Green" },
        }
        local raw = {
            text = "hello",
            pos0 = "P0", pos1 = "P1",
            sboxes = { "s1" }, pboxes = { "p1" },
        }
        local item = simulateFinish(tool_settings, raw)
        assert.equals("P0", item.pos0)
        assert.equals("P1", item.pos1)
    end)

end)
