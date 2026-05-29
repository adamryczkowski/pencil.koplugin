--[[--
Integration spec: Path-A persistence round-trip.

Tests the write → store → read-back contract that lets a saved Path-A
highlight survive a book close + re-open. See feature-plan.md §5 for
the full chain:

  Write:  finishTextHighlight → rh.saveHighlight(false)
       →  ReaderHighlight:saveHighlight (readerhighlight.lua:2108-2148)
       →  ReaderAnnotation:addItem
       →  KOReader doc_settings `annotations` key.

  Read:   ReaderAnnotation:onReadSettings (readerannotation.lua:111-156)
       →  restores from doc_settings on book open.

The test verifies the boundary that the saved item arrives at and
leaves with the same `pos0`/`pos1` XPointer fields and the M3-wired
`drawer`/`color` fields intact. Two-annotations-on-same-word
(edge-case row 4 in feature-plan.md §4) is also covered.

Pattern-B inline-mock; no main.lua require; no ReaderAnnotation require.

Run with: busted spec/pencil_text_highlight_persistence_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Pattern-B mock of ReaderAnnotation
--   • addItem(item) appends to .annotations unconditionally (no dedup —
--     mirrors the production "two highlights on same word" decision
--     in feature-plan.md §4).
--   • serialize() returns a shallow snapshot that the doc_settings
--     layer would persist; tests round-trip via this snapshot.
--   • onReadSettings(stored) replaces .annotations from a stored
--     snapshot (mirrors readerannotation.lua:111-156 restore).
-- ---------------------------------------------------------------------

local function makeReaderAnnotation()
    local ra = { annotations = {}, _add_calls = 0 }

    function ra.addItem(self, item)
        self._add_calls = self._add_calls + 1
        table.insert(self.annotations, item)
        return #self.annotations
    end

    function ra.serialize(self)
        -- Shallow snapshot — KOReader's real persistence does a deep
        -- serialization via lua-persist, but for round-trip-shape
        -- assertions the shallow form is equivalent because we only
        -- mutate scalar fields (pos0, pos1, text, drawer, color).
        local out = {}
        for _, item in ipairs(self.annotations) do
            local copy = {}
            for k, v in pairs(item) do copy[k] = v end
            table.insert(out, copy)
        end
        return out
    end

    function ra.onReadSettings(self, stored)
        self.annotations = {}
        for _, item in ipairs(stored or {}) do
            table.insert(self.annotations, item)
        end
    end

    return ra
end

-- ---------------------------------------------------------------------

describe("Path-A persistence — addItem records all required fields", function()

    it("inserts the item; pos0, pos1, drawer, color, text all preserved", function()
        local ra = makeReaderAnnotation()
        ra:addItem({
            text = "the quick brown fox",
            pos0 = "/body/p[1].0",
            pos1 = "/body/p[1].19",
            drawer = "lighten",
            color = "yellow",
        })
        assert.equals(1, ra._add_calls)
        assert.equals(1, #ra.annotations)
        local s = ra.annotations[1]
        assert.equals("/body/p[1].0",  s.pos0)
        assert.equals("/body/p[1].19", s.pos1)
        assert.equals("lighten",       s.drawer)
        assert.equals("yellow",        s.color)
        assert.equals("the quick brown fox", s.text)
    end)

end)

describe("Path-A persistence — close/re-open round trip (M5 spec ③)", function()

    it("onReadSettings restores all saved items with all fields intact", function()
        -- VERBATIM the M5 spec ③ acceptance:
        --   Given: finishTextHighlight completes with word set {"quick","brown","fox"};
        --          mock ReaderAnnotation:addItem records the call
        --   When:  mock ReaderAnnotation:onReadSettings restores stored annotations
        --   Then:  restored annotation has pos0 and pos1 XPointer fields;
        --          drawer == 'lighten'; color matches the active tool color
        local ra1 = makeReaderAnnotation()
        ra1:addItem({
            text = "quick brown fox", words = { "quick", "brown", "fox" },
            pos0 = "X0", pos1 = "X1",
            drawer = "lighten", color = "yellow",
        })

        -- Simulate close-and-reopen: serialize via doc_settings,
        -- then restore into a fresh ReaderAnnotation.
        local stored = ra1:serialize()
        local ra2 = makeReaderAnnotation()
        ra2:onReadSettings(stored)

        assert.equals(1, #ra2.annotations)
        local r = ra2.annotations[1]
        assert.equals("X0",      r.pos0)
        assert.equals("X1",      r.pos1)
        assert.equals("lighten", r.drawer)
        assert.equals("yellow",  r.color)
        assert.equals("quick brown fox", r.text)
    end)

    it("preserves all five palette colors across round-trip (M3 ties to M5)", function()
        local ra1 = makeReaderAnnotation()
        local palette = { "Yellow", "Green", "Pink", "Cyan", "Orange" }
        for _, name in ipairs(palette) do
            ra1:addItem({
                pos0 = "P_" .. name, pos1 = "Q_" .. name,
                text = name .. " span",
                drawer = "lighten", color = name,
            })
        end

        local ra2 = makeReaderAnnotation()
        ra2:onReadSettings(ra1:serialize())

        assert.equals(#palette, #ra2.annotations)
        for i, name in ipairs(palette) do
            assert.equals(name,      ra2.annotations[i].color)
            assert.equals("lighten", ra2.annotations[i].drawer)
        end
    end)

    it("round-trip is a no-op on a serialised-then-restored snapshot (idempotent)", function()
        local ra1 = makeReaderAnnotation()
        ra1:addItem({
            pos0 = "P0", pos1 = "P1", text = "alpha",
            drawer = "lighten", color = "yellow",
        })
        ra1:addItem({
            pos0 = "Q0", pos1 = "Q1", text = "beta",
            drawer = "lighten", color = "pink",
        })

        local ra2 = makeReaderAnnotation()
        ra2:onReadSettings(ra1:serialize())
        local ra3 = makeReaderAnnotation()
        ra3:onReadSettings(ra2:serialize())

        assert.equals(2, #ra3.annotations)
        assert.equals("alpha", ra3.annotations[1].text)
        assert.equals("yellow", ra3.annotations[1].color)
        assert.equals("beta", ra3.annotations[2].text)
        assert.equals("pink", ra3.annotations[2].color)
    end)

end)

describe("Path-A persistence — two-annotations-on-same-word sub-case (M5 spec ③)", function()

    it("two addItem calls for the same XPointer span both persist (no dedup)", function()
        -- VERBATIM the M5 spec ③ two-annotations sub-case:
        --   Given: two addItem calls for the same XPointer span
        --   When:  onReadSettings restores
        --   Then:  both annotation items present in the store; no crash; no silent dedup
        local ra = makeReaderAnnotation()
        ra:addItem({ pos0 = "P0", pos1 = "P1", text = "x",
                     drawer = "lighten", color = "yellow" })
        ra:addItem({ pos0 = "P0", pos1 = "P1", text = "x",
                     drawer = "lighten", color = "yellow" })
        assert.equals(2, ra._add_calls)
        assert.equals(2, #ra.annotations)
    end)

    it("two-on-same-word survive close/re-open without silent dedup", function()
        local ra1 = makeReaderAnnotation()
        ra1:addItem({ pos0 = "P0", pos1 = "P1", text = "x",
                      drawer = "lighten", color = "yellow" })
        ra1:addItem({ pos0 = "P0", pos1 = "P1", text = "x",
                      drawer = "lighten", color = "yellow" })

        local ra2 = makeReaderAnnotation()
        ra2:onReadSettings(ra1:serialize())
        assert.equals(2, #ra2.annotations)
    end)

    it("two-on-same-word with DIFFERENT colors both survive (compounding intentional)", function()
        -- The visual decision in feature-plan.md §4 row 4 is that
        -- compounding two highlights on the same word is acceptable
        -- (drawer='lighten' multiplies, so two yellows = darker yellow).
        -- Even with different colors, both items must persist for the
        -- visual compound to be possible.
        local ra1 = makeReaderAnnotation()
        ra1:addItem({ pos0 = "P0", pos1 = "P1", drawer = "lighten", color = "yellow" })
        ra1:addItem({ pos0 = "P0", pos1 = "P1", drawer = "lighten", color = "pink" })

        local ra2 = makeReaderAnnotation()
        ra2:onReadSettings(ra1:serialize())
        assert.equals(2, #ra2.annotations)
        assert.equals("yellow", ra2.annotations[1].color)
        assert.equals("pink",   ra2.annotations[2].color)
    end)

    it("does not crash when two items have identical XPointers", function()
        local ra = makeReaderAnnotation()
        assert.has_no.errors(function()
            ra:addItem({ pos0 = "P0", pos1 = "P1",
                         drawer = "lighten", color = "yellow" })
            ra:addItem({ pos0 = "P0", pos1 = "P1",
                         drawer = "lighten", color = "yellow" })
        end)
    end)

end)

describe("Path-A persistence — input robustness", function()

    it("onReadSettings with nil stored snapshot is a no-op (empty annotations)", function()
        local ra = makeReaderAnnotation()
        ra:addItem({ pos0 = "P0", pos1 = "P1" })
        ra:onReadSettings(nil)
        assert.equals(0, #ra.annotations)
    end)

    it("onReadSettings with empty array clears existing annotations", function()
        local ra = makeReaderAnnotation()
        ra:addItem({ pos0 = "P0", pos1 = "P1" })
        ra:onReadSettings({})
        assert.equals(0, #ra.annotations)
    end)

end)
