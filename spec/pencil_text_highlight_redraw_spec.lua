--[[--
Integration spec: Path-A saved-item redraw contract.

Tests the redraw boundary that Path A depends on. When a saved Path-A
annotation item with an XPointer span (pos0/pos1) is encountered during
a page paint, KOReader's readerview.lua redraw loop must:

  1. Skip the item when item.page != cur_page (per-page clip filter
     at readerview.lua:629-643).
  2. Resolve current screen rectangles via
     document:getScreenBoxesFromPositions(pos0, pos1) — pcall-wrapped
     per main.lua:3057-3068 (CRengine boundary).
  3. Skip nil / zero-height boxes (readerview.lua:644-668).
  4. Call drawHighlightRect for each surviving rect, passing through
     the item's drawer and color fields (which M3 wired in
     lib/highlight_color_wiring.lua).

This spec is a Pattern-B inline-mock simulator that mirrors the
readerview.lua redraw loop verbatim. Per M5 testability strategy in
feature-plan.md §6, KOReader surfaces are mocked at the call
boundary; no main.lua require; no input.lua require.

Run with: busted spec/pencil_text_highlight_redraw_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Pattern-B inline mocks of KOReader surfaces.
-- ---------------------------------------------------------------------

-- Mock CRengine document.
--   opts.boxes:
--     table : array of {x,y,w,h} rect tables returned by
--             getScreenBoxesFromPositions
--     nil   : engine returned nil (word disappeared / no rendering yet)
--     false : engine threw — exercises the main.lua:3057-3068 pcall
--             guard
local function makeMockDocument(opts)
    opts = opts or {}
    local doc = {
        _calls = { getScreenBoxesFromPositions = {} },
        _boxes = opts.boxes,
    }
    function doc.getScreenBoxesFromPositions(self, pos0, pos1)
        table.insert(self._calls.getScreenBoxesFromPositions,
            { pos0 = pos0, pos1 = pos1 })
        if self._boxes == false then
            error("simulated CRengine error")
        end
        return self._boxes
    end
    return doc
end

-- Mock rect drawer. Collects every drawHighlightRect call so the spec
-- can assert on the rects, drawer mode, and color that the redraw
-- loop forwarded.
local function makeMockDrawer()
    local drawer = { _calls = {} }
    function drawer.drawHighlightRect(self, rect, drawer_mode, color)
        table.insert(self._calls, {
            rect = rect, drawer = drawer_mode, color = color,
        })
    end
    return drawer
end

-- Simulator of readerview.lua:629-668 redraw loop, applied to a single
-- saved Path-A item. Mirrors:
--   • per-page clip filter (629-643)
--   • CRengine resolution via getScreenBoxesFromPositions, pcall-wrapped
--   • nil/empty-result skip
--   • per-box h>0 filter (652-668)
--   • per-box drawHighlightRect with item drawer + color
local function simulateRedrawItem(item, cur_page, document, drawer)
    -- Per-page clip filter.
    if item.page and item.page ~= cur_page then return end
    -- CRengine call (pcall-guarded per main.lua:3057-3068 pattern).
    local ok, boxes = pcall(document.getScreenBoxesFromPositions,
                            document, item.pos0, item.pos1)
    if not ok or boxes == nil then return end
    for _, rect in ipairs(boxes) do
        -- Skip nil entries and h==0 entries.
        if rect and rect.h and rect.h > 0 then
            drawer:drawHighlightRect(rect, item.drawer, item.color)
        end
    end
end

-- ---------------------------------------------------------------------

describe("Path-A redraw contract — current-page, valid xpointer span", function()

    it("calls getScreenBoxesFromPositions with the item's pos0 and pos1", function()
        local doc = makeMockDocument{ boxes = { { x=10, y=20, w=80, h=16 } } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1,
              drawer = "lighten", color = "yellow" },
            1, doc, drawer)
        assert.equals(1, #doc._calls.getScreenBoxesFromPositions)
        assert.equals("P0", doc._calls.getScreenBoxesFromPositions[1].pos0)
        assert.equals("P1", doc._calls.getScreenBoxesFromPositions[1].pos1)
    end)

    it("calls drawHighlightRect with the engine-returned rect (not the original capture rect)", function()
        -- VERBATIM the M5 spec ① acceptance:
        --   Given: saved item with xpointer pos0/pos1; mock returns {{x=10,y=20,w=80,h=16}}
        --   When:  drawXPointerSavedHighlight (or equivalent) is called
        --   Then:  multiplyRectHighlighter / drawHighlightRect is called with {x=10,y=20,w=80,h=16}
        local doc = makeMockDocument{ boxes = { { x=10, y=20, w=80, h=16 } } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1,
              drawer = "lighten", color = "yellow" },
            1, doc, drawer)
        assert.equals(1, #drawer._calls)
        local call = drawer._calls[1]
        assert.equals(10, call.rect.x)
        assert.equals(20, call.rect.y)
        assert.equals(80, call.rect.w)
        assert.equals(16, call.rect.h)
    end)

    it("forwards the item's drawer and color (M3 wiring reaches the paint call)", function()
        local doc = makeMockDocument{ boxes = { { x=1, y=1, w=10, h=10 } } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1,
              drawer = "lighten", color = "yellow" },
            1, doc, drawer)
        assert.equals("lighten", drawer._calls[1].drawer)
        assert.equals("yellow",  drawer._calls[1].color)
    end)

    it("draws every valid box (multi-line highlight)", function()
        local doc = makeMockDocument{ boxes = {
            { x=10, y=20,  w=80,  h=16 },
            { x=10, y=40,  w=120, h=16 },
            { x=10, y=60,  w=50,  h=16 },
        } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1,
              drawer = "lighten", color = "yellow" },
            1, doc, drawer)
        assert.equals(3, #drawer._calls)
    end)

end)

describe("Path-A redraw contract — page-boundary clip filter (M5 spec ① page-boundary sub-case)", function()

    it("draws nothing when item.page does not match cur_page (XPointer on page 2, cur_page=1)", function()
        -- VERBATIM the M5 spec ① page-boundary sub-case:
        --   Given: XPointer span on page 2; cur_page == 1
        --   When:  redraw
        --   Then:  no rectangle drawn (per-page clip filter at readerview.lua:629-643)
        local doc = makeMockDocument{ boxes = { { x=10, y=20, w=80, h=16 } } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 2,
              drawer = "lighten", color = "yellow" },
            1, doc, drawer)
        assert.equals(0, #drawer._calls)
        -- The clip filter must run BEFORE the engine call so a wrong-page
        -- item doesn't incur the cost of a CRengine resolution.
        assert.equals(0, #doc._calls.getScreenBoxesFromPositions)
    end)

    it("draws when item.page matches cur_page (positive control)", function()
        local doc = makeMockDocument{ boxes = { { x=10, y=20, w=80, h=16 } } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 2 },
            2, doc, drawer)
        assert.equals(1, #drawer._calls)
    end)

end)

describe("Path-A redraw contract — nil/empty/h0 box handling (readerview.lua:644-668)", function()

    it("draws nothing when engine returns nil (word disappeared after reflow)", function()
        local doc = makeMockDocument{ boxes = nil }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1 },
            1, doc, drawer)
        assert.equals(0, #drawer._calls)
    end)

    it("draws nothing when engine returns an empty box array", function()
        local doc = makeMockDocument{ boxes = {} }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1 },
            1, doc, drawer)
        assert.equals(0, #drawer._calls)
    end)

    it("skips boxes with h==0 (zero-height filter at readerview.lua:652-668)", function()
        local doc = makeMockDocument{ boxes = {
            { x=10, y=20, w=80, h=0 },   -- collapsed; must be skipped
            { x=10, y=40, w=80, h=16 },  -- valid
        } }
        local drawer = makeMockDrawer()
        simulateRedrawItem(
            { pos0 = "P0", pos1 = "P1", page = 1,
              drawer = "lighten", color = "yellow" },
            1, doc, drawer)
        assert.equals(1, #drawer._calls)
        assert.equals(16, drawer._calls[1].rect.h)
    end)

    it("does not crash when getScreenBoxesFromPositions throws (CRengine pcall guard)", function()
        local doc = makeMockDocument{ boxes = false }   -- raises
        local drawer = makeMockDrawer()
        assert.has_no.errors(function()
            simulateRedrawItem(
                { pos0 = "P0", pos1 = "P1", page = 1 },
                1, doc, drawer)
        end)
        assert.equals(0, #drawer._calls)
    end)

end)
