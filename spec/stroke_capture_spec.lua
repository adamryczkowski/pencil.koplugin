--[[--
Unit tests for lib/stroke_capture — Goal-2 pen-stroke anchor capture
pcall chain.

Specs SC-1..SC-5 per Goal-2 plan §2 (G2-M3).

Run with: busted spec/stroke_capture_spec.lua

The module under test owns the CRengine inverse-lookup boundary
(getWordFromPosition + getNearestWordAndBoxFromPosition). It receives
`doc` by dependency injection, so this spec mocks `doc` with a plain
table — NO require('main'), no UIManager, no real CreDocument.
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokeCapture = require("lib/stroke_capture")

--- Build a doc mock.
-- @param opts {
--    word           = table|nil  — returned by getWordFromPosition
--    word_raises    = bool       — if true, getWordFromPosition raises
--    nearest        = table|nil  — returned by getNearestWordAndBoxFromPosition
--    nearest_raises = bool
-- }
-- The mock also records each call's args so SC-4 can assert.
local function make_doc(opts)
    opts = opts or {}
    local doc = { calls = {} }
    function doc:getWordFromPosition(pos, do_not_draw_selection)
        table.insert(self.calls, {
            method = "getWordFromPosition",
            pos = pos,
            arg3 = do_not_draw_selection,
        })
        if opts.word_raises then error("simulated build-compat fail") end
        return opts.word
    end
    function doc:getNearestWordAndBoxFromPosition(pos, dir)
        table.insert(self.calls, {
            method = "getNearestWordAndBoxFromPosition",
            pos = pos,
            arg3 = dir,
        })
        if opts.nearest_raises then error("simulated build-compat fail") end
        return opts.nearest
    end
    return doc
end

-- VALID_WORD shape MUST match the real CreDocument:getWordFromPosition return
-- shape (credocument.lua:605-680): a wordbox with .pos0 (xpointer of the
-- text-range start) and .sbox (Geom screen-box). Earlier versions of this
-- spec used hypothetical fields `xpointer`/`pos` that don't exist on the
-- real API — the mock-vs-prod divergence let the Goal-2 wiring ship broken.
local VALID_WORD = {
    word = "anchor",
    pos0 = "/body/DocFragment[1]/p[3]/text()",
    pos1 = "/body/DocFragment[1]/p[3]/text().6",
    sbox = { x = 50, y = 100, w = 200, h = 20 },
}

describe("StrokeCapture.compute_anchor", function()

    it("SC-1: strict lookup returns valid word → anchor non-nil, type='line'", function()
        local doc = make_doc({ word = VALID_WORD })
        local stroke_pt = { x = 80, y = 110 }
        local anchor = StrokeCapture.compute_anchor(doc, stroke_pt)
        assert.is_not_nil(anchor)
        assert.equals("line", anchor.type)
        assert.equals("string", type(anchor.xp))
        assert.equals(VALID_WORD.pos0, anchor.xp)
    end)

    it("SC-2: strict pcall raises → falls to fuzzy → anchor non-nil if fuzzy returns valid", function()
        local doc = make_doc({
            word_raises = true,
            nearest = VALID_WORD,
        })
        local stroke_pt = { x = 80, y = 110 }
        local anchor = StrokeCapture.compute_anchor(doc, stroke_pt)
        assert.is_not_nil(anchor)
        assert.equals("line", anchor.type)
        assert.equals(VALID_WORD.pos0, anchor.xp)
        -- Both methods consulted in order:
        assert.equals("getWordFromPosition",  doc.calls[1].method)
        assert.equals("getNearestWordAndBoxFromPosition", doc.calls[2].method)
    end)

    it("SC-3: both lookups return nil → nil (image-only / no-text page)", function()
        local doc = make_doc({ word = nil, nearest = nil })
        local stroke_pt = { x = 80, y = 110 }
        local anchor = StrokeCapture.compute_anchor(doc, stroke_pt)
        assert.is_nil(anchor)
    end)

    it("SC-4: getWordFromPosition called with `true` as 3rd arg (do_not_draw_selection regression guard)", function()
        local doc = make_doc({ word = VALID_WORD })
        local stroke_pt = { x = 80, y = 110 }
        StrokeCapture.compute_anchor(doc, stroke_pt)
        -- Find the recorded getWordFromPosition call and assert its 3rd arg.
        local seen_strict = false
        for _, c in ipairs(doc.calls) do
            if c.method == "getWordFromPosition" then
                seen_strict = true
                assert.equals(true, c.arg3,
                    "SC-4 regression: getWordFromPosition MUST be called with " ..
                    "do_not_draw_selection=true; got " .. tostring(c.arg3))
            end
        end
        assert.is_true(seen_strict,
            "SC-4 regression: getWordFromPosition was never called")
    end)

    it("SC-5: fuzzy returns word on margin stroke → no error raised", function()
        -- Strict miss, fuzzy hits — represents a stroke in the margin near
        -- text. compute_anchor must complete without raising regardless of
        -- whether the resulting anchor is non-nil.
        local doc = make_doc({ word = nil, nearest = VALID_WORD })
        local stroke_pt = { x = 12, y = 100 }
        local ok, result = pcall(StrokeCapture.compute_anchor, doc, stroke_pt)
        assert.is_true(ok, "compute_anchor raised: " .. tostring(result))
        -- Either nil (graceful miss) or a well-formed anchor is acceptable.
        if result ~= nil then
            assert.equals("line", result.type)
        end
    end)

end)
