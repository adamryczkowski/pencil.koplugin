--[[--
Unit tests for lib/free_spot — L2 margin-preference auto-layout pass.

Specs FS-1..FS-3 per Goal-3 plan §2 (G3-M5a). L4 (in-text BELOW/ABOVE
fallback) is deferred to G3-M5b and intentionally NOT exercised here:
FS-2 asserts that "no L2 fit → nil" so the badge fallback engages until
M5b adds the second tier.

Run with: busted spec/free_spot_spec.lua

The find_free_spot surface is pure Lua — no CRengine dependencies, no
require('main'). Inputs are plain rect tables ({x, y, w, h}); outputs
are {x, y, scale} or nil. Collision uses strict-inequality
axis-aligned bounding-box (AABB) overlap so margin-edge contact is
NOT a collision (440-right-edge of text body meeting 440-left-edge of
right-margin candidate at scale 0.75 → no collision → fits).
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local FreeSpot = require("lib/free_spot")
local AnchorConstants = require("lib/anchor_constants")

local MARGIN = AnchorConstants.FREE_SPOT_MARGIN_PX  -- 24

describe("FreeSpot.find_free_spot (L2 margin pass)", function()

    it("G3-FS-1: cluster fits in left margin at scale 1.0", function()
        -- screen 500px wide, text body x∈[MARGIN, 500-MARGIN] = [24,476]
        -- cluster is 20×30 (narrower than the 24px margin strip at scale 1.0)
        local cluster_bbox = { x = 100, y = 200, w = 20, h = 30 }
        local anchor_bbox  = { x = 50,  y = 200, w = 100, h = 16 }
        local text_line_bboxes = {
            { x = MARGIN, y = 200, w = 500 - 2 * MARGIN, h = 30 },
        }
        local other_annotation_bboxes = {}
        local screen_bounds = { x = 0, y = 0, w = 500, h = 800 }

        local result = FreeSpot.find_free_spot(
            cluster_bbox, anchor_bbox,
            text_line_bboxes, other_annotation_bboxes, screen_bounds)

        assert.is_table(result)
        assert.are.equal(0, result.x)              -- LEFT margin start
        assert.are.equal(anchor_bbox.y, result.y)  -- y near anchor_bbox.y
        assert.are.equal(1.0, result.scale)        -- best (largest) scale
    end)

    it("G3-FS-2: cluster does not fit in either margin → nil (L4 not yet wired)", function()
        -- Wide cluster + full-width text → every L2 candidate collides
        -- regardless of scale (even at the 0.5 floor).
        local cluster_bbox = { x = 100, y = 200, w = 300, h = 30 }
        local anchor_bbox  = { x = 100, y = 200, w = 200, h = 16 }
        local text_line_bboxes = {
            { x = 0, y = 200, w = 500, h = 30 },  -- spans full screen width
        }
        local other_annotation_bboxes = {}
        local screen_bounds = { x = 0, y = 0, w = 500, h = 800 }

        local result = FreeSpot.find_free_spot(
            cluster_bbox, anchor_bbox,
            text_line_bboxes, other_annotation_bboxes, screen_bounds)

        assert.is_nil(result)  -- L4 not yet wired in M5a; nil → badge
    end)

    it("G3-FS-3: cluster fits only at scale 0.75 in right margin", function()
        -- screen 500px wide; text body fills [0, 440] (60px right margin).
        -- cluster is 80×30 — too wide for left (text starts at x=0) and
        -- too wide for the right margin at scale 1.0/0.9, but at scale
        -- 0.75 → scaled_w=60, x=500-60=440 sits exactly on text right
        -- edge (strict-inequality AABB → no collision → fits).
        local cluster_bbox = { x = 100, y = 200, w = 80, h = 30 }
        local anchor_bbox  = { x = 100, y = 200, w = 200, h = 16 }
        local text_line_bboxes = {
            { x = 0, y = 200, w = 440, h = 30 },  -- text body left-flush
        }
        local other_annotation_bboxes = {}
        local screen_bounds = { x = 0, y = 0, w = 500, h = 800 }

        local result = FreeSpot.find_free_spot(
            cluster_bbox, anchor_bbox,
            text_line_bboxes, other_annotation_bboxes, screen_bounds)

        assert.is_table(result)
        assert.are.equal(0.75, result.scale)
        -- right margin placement: x = screen_w - scaled_w
        assert.are.equal(500 - 80 * 0.75, result.x)  -- 440
        assert.are.equal(anchor_bbox.y, result.y)
    end)

end)
