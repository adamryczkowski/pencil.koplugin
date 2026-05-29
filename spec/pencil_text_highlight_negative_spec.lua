--[[--
Negative-path tests for the Path-A dispatch: a stroke that landed on
no text must be silently discarded — no annotation entry created, no
exception thrown, no plugin state changed.

Edge case from feature-plan.md §4 row 1 ("Stroke over no text →
DISCARD silently"). The contract is encoded in
`DispatchPredicate.extractWordSet` returning nil for missing/empty/
whitespace-only selections; the integration consumes that nil as the
"do not assign rh.selected_text" signal.

This spec exercises two layers:
  (a) the pure helper — extractWordSet returns nil for every form of
      "nothing to highlight";
  (b) the integration contract — a small simulator that mirrors
      extendTextHighlight's "if words then add to store" decision
      shows that no annotation lands in the Path-A store when the
      helper returns nil.

Pure-Lua test — no main.lua require, no CRengine require, no
UIManager. Run with:
  busted spec/pencil_text_highlight_negative_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local DispatchPredicate = require("lib/dispatch_predicate")

-- ---------------------------------------------------------------------
-- (a) Pure helper layer
-- ---------------------------------------------------------------------

describe("DispatchPredicate.extractWordSet — negative cases", function()

    it("returns nil for a nil selection (pcall returned ok=true, nil)", function()
        assert.is_nil(DispatchPredicate.extractWordSet(nil))
    end)

    it("returns nil for a non-table selection (defensive)", function()
        assert.is_nil(DispatchPredicate.extractWordSet("oops"))
        assert.is_nil(DispatchPredicate.extractWordSet(42))
        assert.is_nil(DispatchPredicate.extractWordSet(false))
    end)

    it("returns nil for an empty selection table", function()
        assert.is_nil(DispatchPredicate.extractWordSet({}))
    end)

    it("returns nil when text field is missing", function()
        -- Some CRengine paths return a selection with pos0/pos1 but no
        -- usable text (e.g. caret landed between glyphs).
        assert.is_nil(DispatchPredicate.extractWordSet({ pos0 = "x", pos1 = "y" }))
    end)

    it("returns nil when text is empty string", function()
        assert.is_nil(DispatchPredicate.extractWordSet({ text = "" }))
    end)

    it("returns nil when text is whitespace-only", function()
        assert.is_nil(DispatchPredicate.extractWordSet({ text = "   \t\n  " }))
    end)

    it("returns nil for non-string text (malformed selection)", function()
        assert.is_nil(DispatchPredicate.extractWordSet({ text = 42 }))
        assert.is_nil(DispatchPredicate.extractWordSet({ text = false }))
    end)

    it("does not throw on any of these inputs", function()
        assert.has_no.errors(function()
            DispatchPredicate.extractWordSet(nil)
            DispatchPredicate.extractWordSet({})
            DispatchPredicate.extractWordSet({ text = "" })
            DispatchPredicate.extractWordSet({ text = "   " })
        end)
    end)

end)

-- ---------------------------------------------------------------------
-- (b) Integration contract layer — a simulator of the boundary
--     between Pencil:extendTextHighlight and the Path-A annotation
--     store. Mirrors main.lua:945-948 logic without requiring main.lua.
-- ---------------------------------------------------------------------

-- Simulate one slot tick of the Path-A integration: the engine's
-- selection dict is consumed via extractWordSet; only on a non-nil
-- word list does the integration assign rh.selected_text and (later,
-- on finishTextHighlight) push an annotation to the store. A nil word
-- list is the silent-discard signal — no store mutation, no error.
local function simulateExtendTextHighlight(rh, annotation_store, selection)
    local words = DispatchPredicate.extractWordSet(selection)
    if words then
        rh.selected_text = {
            text  = selection.text,
            pos0  = selection.pos0,
            pos1  = selection.pos1,
            words = words,
        }
        -- Mirror main.lua:965-975 "save on finish" boundary; in the
        -- simulator we conflate extend + finish since the negative-path
        -- contract is "store remains empty across the whole drag".
        table.insert(annotation_store, rh.selected_text)
    end
    -- nil word set → no rh.selected_text assignment, no store insert.
end

describe("Path-A negative-path discard (integration contract)", function()

    it("adds no annotation when getTextFromPositions returns nil", function()
        local rh, store = { selected_text = nil }, {}
        simulateExtendTextHighlight(rh, store, nil)
        assert.equals(0, #store)
        assert.is_nil(rh.selected_text)
    end)

    it("adds no annotation when getTextFromPositions returns empty table", function()
        local rh, store = { selected_text = nil }, {}
        simulateExtendTextHighlight(rh, store, {})
        assert.equals(0, #store)
        assert.is_nil(rh.selected_text)
    end)

    it("adds no annotation when selection has empty text", function()
        local rh, store = { selected_text = nil }, {}
        simulateExtendTextHighlight(rh, store, { text = "", pos0 = "x", pos1 = "y" })
        assert.equals(0, #store)
        assert.is_nil(rh.selected_text)
    end)

    it("adds no annotation when selection has whitespace-only text", function()
        local rh, store = { selected_text = nil }, {}
        simulateExtendTextHighlight(rh, store, { text = "  \t  ", pos0 = "x", pos1 = "y" })
        assert.equals(0, #store)
        assert.is_nil(rh.selected_text)
    end)

    it("does add an annotation when selection has real text (positive control)", function()
        -- Sanity check: the simulator only suppresses for the nil-words
        -- case. If extractWordSet returned non-nil we'd over-suppress.
        local rh, store = { selected_text = nil }, {}
        simulateExtendTextHighlight(rh, store, {
            text = "hello world",
            pos0 = "x", pos1 = "y",
        })
        assert.equals(1, #store)
        assert.is_not_nil(rh.selected_text)
        assert.equals("hello world", store[1].text)
    end)

    it("does not throw across any of the negative inputs", function()
        assert.has_no.errors(function()
            local rh, store = { selected_text = nil }, {}
            simulateExtendTextHighlight(rh, store, nil)
            simulateExtendTextHighlight(rh, store, {})
            simulateExtendTextHighlight(rh, store, { text = "" })
            simulateExtendTextHighlight(rh, store, { text = "   " })
        end)
    end)

end)
