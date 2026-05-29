--[[--
Integration spec: Path-A reflow cache-invalidation contract.

Tests that after a DocumentRerendered event (orientation change, font
resize, font family change, line spacing change, margin change),
KOReader's highlight-boxes cache is cleared so the next redraw
re-queries `getScreenBoxesFromPositions` with fresh layout state. This
is the chain that lets a saved Path-A annotation follow the same words
across a reflow without any plugin-side reflow handler — see
feature-plan.md §3 reflow event coverage matrix.

Hook points being simulated:
  • readerview.lua:1216-1218 — `onDocumentRerendered =
    resetHighlightBoxesCache` and `onAnnotationsModified =
    resetHighlightBoxesCache` aliases.
  • readerview.lua:644 — the per-paint redraw entry that consults the
    cache and falls through to `getScreenBoxesFromPositions` on miss.
  • main.lua:3057-3068 — the pcall pattern that guards every CRengine
    boundary, including this one in the cache path.

Pattern-B inline-mock; no main.lua require; no readerview require.

Run with: busted spec/pencil_text_highlight_reflow_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Pattern-B inline mocks
-- ---------------------------------------------------------------------

-- Mock CRengine document. Counts every call so the spec can assert
-- on cache-hit vs cache-miss behavior.
local function makeMockDocument(opts)
    opts = opts or {}
    local doc = {
        _call_count = 0,
        _boxes = opts.boxes,
    }
    function doc.getScreenBoxesFromPositions(self, pos0, pos1)
        self._call_count = self._call_count + 1
        if self._boxes == false then error("simulated CRengine error") end
        return self._boxes
    end
    return doc
end

-- Mock ReaderView with a highlight-boxes cache, mirroring readerview.lua.
-- Keying scheme: `<pos0>|<pos1>` per the production lookup contract.
local function makeReaderView(opts)
    local view = {
        document = opts.document,
        highlight_boxes_cache = {},
    }

    -- Mirror readerview.lua:1216-1218 — resetHighlightBoxesCache is the
    -- alias target for both onDocumentRerendered and onAnnotationsModified.
    function view.resetHighlightBoxesCache(self)
        for k in pairs(self.highlight_boxes_cache) do
            self.highlight_boxes_cache[k] = nil
        end
    end
    view.onDocumentRerendered  = view.resetHighlightBoxesCache
    view.onAnnotationsModified = view.resetHighlightBoxesCache

    -- Mirror the per-paint lookup at readerview.lua:644: cache hit
    -- returns immediately; cache miss runs the pcall-guarded CRengine
    -- call and stores the result in the cache (only on non-nil).
    function view.getBoxesForItem(self, item)
        local key = (item.pos0 or "") .. "|" .. (item.pos1 or "")
        local cached = self.highlight_boxes_cache[key]
        if cached then return cached end
        local ok, boxes = pcall(self.document.getScreenBoxesFromPositions,
                                self.document, item.pos0, item.pos1)
        if not ok then return nil end
        if boxes == nil then return nil end
        self.highlight_boxes_cache[key] = boxes
        return boxes
    end

    return view
end

-- ---------------------------------------------------------------------

describe("Path-A reflow contract — cache fill on first lookup", function()

    it("caches engine result so a second lookup does not re-query CRengine", function()
        local doc = makeMockDocument{ boxes = { { x=1, y=2, w=3, h=4 } } }
        local view = makeReaderView{ document = doc }
        local item = { pos0 = "P0", pos1 = "P1" }
        local b1 = view:getBoxesForItem(item)
        assert.equals(1, doc._call_count)
        local b2 = view:getBoxesForItem(item)
        assert.equals(1, doc._call_count)  -- second lookup is a cache hit
        assert.is_true(b1 == b2)
    end)

    it("different XPointer keys produce independent cache entries", function()
        local doc = makeMockDocument{ boxes = { { x=1, y=2, w=3, h=4 } } }
        local view = makeReaderView{ document = doc }
        view:getBoxesForItem({ pos0 = "A0", pos1 = "A1" })
        view:getBoxesForItem({ pos0 = "B0", pos1 = "B1" })
        assert.equals(2, doc._call_count)
        -- Each key is its own cache entry; neither was clobbered.
        assert.is_not_nil(view.highlight_boxes_cache["A0|A1"])
        assert.is_not_nil(view.highlight_boxes_cache["B0|B1"])
    end)

end)

describe("Path-A reflow contract — DocumentRerendered clears the cache", function()

    it("resetHighlightBoxesCache clears the table; next lookup re-queries the engine", function()
        -- VERBATIM the M5 spec ② acceptance:
        --   Given: cache populated from previous paint; DocumentRerendered event fires
        --   When:  resetHighlightBoxesCache handler runs
        --   Then:  cache cleared; next drawXPointerSavedHighlight call invokes
        --          getScreenBoxesFromPositions again (not stale cache)
        local doc = makeMockDocument{ boxes = { { x=1, y=2, w=3, h=4 } } }
        local view = makeReaderView{ document = doc }
        local item = { pos0 = "P0", pos1 = "P1" }

        view:getBoxesForItem(item)
        assert.equals(1, doc._call_count)

        view:resetHighlightBoxesCache()
        assert.is_nil(view.highlight_boxes_cache["P0|P1"])

        view:getBoxesForItem(item)
        assert.equals(2, doc._call_count)  -- post-reset → fresh engine call
    end)

    it("onDocumentRerendered alias routes to the same cache-clear handler", function()
        local view = makeReaderView{ document = makeMockDocument{ boxes = {} } }
        view.highlight_boxes_cache["P0|P1"] = "stale_rect_array"
        view:onDocumentRerendered()
        assert.is_nil(view.highlight_boxes_cache["P0|P1"])
    end)

    it("onAnnotationsModified alias routes to the same cache-clear handler", function()
        local view = makeReaderView{ document = makeMockDocument{ boxes = {} } }
        view.highlight_boxes_cache["P0|P1"] = "stale_rect_array"
        view:onAnnotationsModified()
        assert.is_nil(view.highlight_boxes_cache["P0|P1"])
    end)

    it("clearing an empty cache is a no-op (defensive)", function()
        local view = makeReaderView{ document = makeMockDocument{ boxes = {} } }
        assert.has_no.errors(function() view:resetHighlightBoxesCache() end)
    end)

end)

describe("Path-A reflow contract — nil-boxes sub-case (word disappeared)", function()

    it("does not crash when engine returns nil (no boxes for this xpointer)", function()
        -- VERBATIM the M5 spec ② nil-boxes sub-case:
        --   Given: getScreenBoxesFromPositions returns nil (word disappeared after reflow)
        --   When:  redraw
        --   Then:  no crash; annotation item retained in store; no rectangle drawn
        local doc = makeMockDocument{ boxes = nil }
        local view = makeReaderView{ document = doc }
        local boxes
        assert.has_no.errors(function()
            boxes = view:getBoxesForItem({ pos0 = "P0", pos1 = "P1" })
        end)
        assert.is_nil(boxes)
    end)

    it("does NOT cache a nil result (so a later reflow can recover the word)", function()
        -- Critical: if nil were cached, a word that briefly disappeared
        -- would stay invisible until DocumentRerendered fired again.
        -- Recoverable disappearance (e.g., temporary engine state) must
        -- self-heal on the very next paint.
        local doc = makeMockDocument{ boxes = nil }
        local view = makeReaderView{ document = doc }
        local item = { pos0 = "P0", pos1 = "P1" }

        view:getBoxesForItem(item)
        assert.equals(1, doc._call_count)
        assert.is_nil(view.highlight_boxes_cache["P0|P1"])

        view:getBoxesForItem(item)
        assert.equals(2, doc._call_count)
    end)

    it("annotation item is not mutated by a failed lookup (item retention)", function()
        local doc = makeMockDocument{ boxes = nil }
        local view = makeReaderView{ document = doc }
        local item = {
            pos0 = "P0", pos1 = "P1",
            text = "hello", drawer = "lighten", color = "yellow",
        }
        view:getBoxesForItem(item)
        view:resetHighlightBoxesCache()
        view:getBoxesForItem(item)
        -- All fields preserved.
        assert.equals("P0",      item.pos0)
        assert.equals("P1",      item.pos1)
        assert.equals("hello",   item.text)
        assert.equals("lighten", item.drawer)
        assert.equals("yellow",  item.color)
    end)

    it("does not crash when the engine throws (CRengine pcall guard)", function()
        local doc = makeMockDocument{ boxes = false }
        local view = makeReaderView{ document = doc }
        local boxes
        assert.has_no.errors(function()
            boxes = view:getBoxesForItem({ pos0 = "P0", pos1 = "P1" })
        end)
        assert.is_nil(boxes)
    end)

end)

describe("Path-A reflow contract — multiple reflows in sequence", function()

    it("each DocumentRerendered triggers a fresh engine call on the next paint", function()
        local doc = makeMockDocument{ boxes = { { x=1, y=2, w=3, h=4 } } }
        local view = makeReaderView{ document = doc }
        local item = { pos0 = "P0", pos1 = "P1" }

        -- Tick 1: first paint
        view:getBoxesForItem(item) ; assert.equals(1, doc._call_count)
        -- Reflow 1
        view:onDocumentRerendered()
        view:getBoxesForItem(item) ; assert.equals(2, doc._call_count)
        -- Reflow 2 (e.g. font size change)
        view:onDocumentRerendered()
        view:getBoxesForItem(item) ; assert.equals(3, doc._call_count)
        -- Reflow 3 (e.g. orientation change)
        view:onDocumentRerendered()
        view:getBoxesForItem(item) ; assert.equals(4, doc._call_count)
    end)

end)
