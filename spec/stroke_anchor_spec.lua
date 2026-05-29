--[[--
Unit tests for lib/stroke_anchor — pure-Lua line-relative anchor math.

Specs SA-1..SA-5 per Goal-2 plan §2 (G2-M2).

Run with: busted spec/stroke_anchor_spec.lua

The module under test is dependency-free pure Lua: no CRengine calls,
no UIManager, no plugin state. Both functions take only plain tables and
numbers, so this file does NOT require('main').
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokeAnchor = require("lib/stroke_anchor")

describe("StrokeAnchor", function()

    describe("compute_line_anchor", function()

        it("SA-1: returns anchor with type='line', xp, numeric dx_em/dy_lh", function()
            local word_result = {
                xpointer = "x/p",
                pos = { x = 10, y = 20, w = 100, h = 20 },
            }
            local stroke_pt = { x = 25, y = 30 }
            local em_px = 12
            local lh_px = 20
            local anchor = StrokeAnchor.compute_line_anchor(word_result, stroke_pt, em_px, lh_px)
            assert.is_not_nil(anchor)
            assert.equals("line", anchor.type)
            assert.equals("x/p", anchor.xp)
            assert.equals("number", type(anchor.dx_em))
            assert.equals("number", type(anchor.dy_lh))
        end)

        it("SA-2: returns nil for nil word_result, no error", function()
            local stroke_pt = { x = 25, y = 30 }
            local anchor = StrokeAnchor.compute_line_anchor(nil, stroke_pt, 12, 20)
            assert.is_nil(anchor)
        end)

        it("SA-5: returns nil when word_result.xpointer is nil (graceful miss)", function()
            local word_result = {
                xpointer = nil,
                pos = { x = 10, y = 20, w = 100, h = 20 },
            }
            local stroke_pt = { x = 25, y = 30 }
            local anchor = StrokeAnchor.compute_line_anchor(word_result, stroke_pt, 12, 20)
            assert.is_nil(anchor)
        end)

    end)

    describe("resolve_anchor_delta", function()

        it("SA-3: tx = screen_x + dx_em*em_px; ty = screen_y + dy_lh*lh_px", function()
            local anchor = { type = "line", xp = "x/p", dx_em = 1.5, dy_lh = 0.5 }
            local tx, ty = StrokeAnchor.resolve_anchor_delta(anchor, 100, 200, 10, 20)
            assert.equals(115, tx)  -- 100 + 1.5 * 10
            assert.equals(210, ty)  -- 200 + 0.5 * 20
        end)

        it("SA-4: zero deltas → tx==screen_x, ty==screen_y", function()
            local anchor = { type = "line", xp = "x/p", dx_em = 0, dy_lh = 0 }
            local tx, ty = StrokeAnchor.resolve_anchor_delta(anchor, 314, 271, 10, 20)
            assert.equals(314, tx)
            assert.equals(271, ty)
        end)

    end)

end)
