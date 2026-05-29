--[[--
Ruby / vertical-text graceful-degradation spec for lib/stroke_capture.

Spec RU-1 per Goal-2 plan §2 (G2-M6). Closes gate 2B-RUBY (RTM-22):

  In CRengine vertical-text or ruby-annotation mode, both word lookups
  (getWordFromPosition and getNearestWordAndBoxFromPosition) return
  nil because CRengine's horizontal-line word model doesn't apply.
  StrokeCapture.compute_anchor must degrade gracefully — return nil
  without raising — so that paintTo's StrokePaint.paint_with_anchor
  routes to the rotation-badge path (SP-4 covered in G2-M4) instead
  of crashing or silently mis-positioning the stroke.

This is a SPEC-ONLY milestone — no production code changes.
The graceful-nil behaviour is already provided by lib/stroke_capture
(G2-M2 commit 197b0a3): compute_anchor walks step-1 → step-2 → nil
fallback, and each step pcall-guards its CRengine call.

No require('main'). Pure mock-doc test against lib/stroke_capture.

Run with: busted spec/stroke_ruby_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokeCapture = require("lib/stroke_capture")

-- Mock doc emulating CRengine vertical-text / ruby mode: BOTH word
-- lookup methods return nil (the horizontal-line word model that the
-- two lookups embody is unavailable in vertical-text typesetting).
local function make_ruby_doc()
    return {
        getWordFromPosition = function(self, pos, do_not_draw_selection)
            return nil
        end,
        getNearestWordAndBoxFromPosition = function(self, pos, radius)
            return nil
        end,
    }
end

describe("StrokeCapture.compute_anchor — vertical-text / ruby mode", function()

    it("RU-1: both CRengine lookups return nil → compute_anchor returns nil gracefully (2B-RUBY / RTM-22)", function()
        local doc = make_ruby_doc()
        local stroke_pt = { x = 100, y = 200 }
        local anchor
        local ok, err = pcall(function()
            anchor = StrokeCapture.compute_anchor(doc, stroke_pt)
        end)
        assert.is_true(ok,
            "RU-1: compute_anchor must NOT raise when both word lookups " ..
            "return nil; got error: " .. tostring(err))
        assert.is_nil(anchor,
            "RU-1: compute_anchor must return nil when both CRengine " ..
            "word lookups fail (vertical-text / ruby mode); the paint " ..
            "stage will then route the group through the rotation-badge " ..
            "path via lib/stroke_paint.paint_with_anchor (SP-4 / G2-M4).")
    end)

end)
