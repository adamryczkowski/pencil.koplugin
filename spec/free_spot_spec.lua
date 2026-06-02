--[[--
Unit tests for lib/free_spot — L2 margin-preference + L4 in-text
BELOW/ABOVE auto-layout passes.

Specs FS-1..FS-3 per Goal-3 plan §2 (G3-M5a) — L2 margin pass.
Specs FS-4..FS-6 per Goal-3 plan §2 (G3-M5b) — L4 in-text fallback.

FS-2 now blocks every L4 candidate too (wide cluster on full-screen
text), so "no fit anywhere → nil" still holds after M5b wires L4.

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

    it("G3-FS-2: cluster does not fit in either margin → nil (L2 boundary)", function()
        -- Wide cluster + full-screen text → every L2 candidate AND every
        -- L4 candidate (BELOW/ABOVE) collides regardless of scale.
        -- This single fixture proves the M5a→M5b transition: in M5a it
        -- returned nil because L4 was unwired; in M5b it returns nil
        -- because both passes exhaust without a non-colliding placement.
        local cluster_bbox = { x = 100, y = 200, w = 300, h = 30 }
        local anchor_bbox  = { x = 100, y = 200, w = 200, h = 16 }
        local text_line_bboxes = {
            { x = 0, y = 0, w = 500, h = 800 },  -- text fills the whole screen
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

describe("FreeSpot.find_free_spot (L4 in-text BELOW/ABOVE fallback)", function()

    it("G3-FS-4: L4 finds BELOW position when L2 margins are exhausted", function()
        -- Anchor on a full-width text line so both margin strips collide
        -- at every scale (L2 exhausted). Region BELOW the anchor line is
        -- free, so L4 BELOW finds a fit at scale 1.0:
        --   candidate.y = anchor.y + anchor.h + MARGIN = 200 + 16 + 24 = 240
        --   candidate.x = anchor.x = 50
        local cluster_bbox = { x = 100, y = 200, w = 80, h = 30 }
        local anchor_bbox  = { x = 50,  y = 200, w = 200, h = 16 }
        local text_line_bboxes = {
            -- Anchor text line spans full screen width → L2 fully blocked
            { x = 0, y = 200, w = 500, h = 16 },
            -- No text in the BELOW region (anchor_y + anchor_h + padding
            -- onwards).
        }
        local other_annotation_bboxes = {}
        local screen_bounds = { x = 0, y = 0, w = 500, h = 800 }

        local result = FreeSpot.find_free_spot(
            cluster_bbox, anchor_bbox,
            text_line_bboxes, other_annotation_bboxes, screen_bounds)

        assert.is_table(result)
        assert.are.equal(1.0, result.scale)
        assert.are.equal(anchor_bbox.x, result.x)                       -- 50
        assert.are.equal(anchor_bbox.y + anchor_bbox.h + MARGIN, result.y)  -- 240
    end)

    it("G3-FS-5: L4 finds ABOVE position when BELOW is blocked", function()
        -- Anchor on full-width text (L2 blocked), AND text fills the
        -- BELOW region (L4-below blocked), but the region ABOVE the
        -- anchor is free → L4 ABOVE returns:
        --   candidate.y = anchor.y - cluster.h * scale - MARGIN
        --              = 400 - 30 * 1.0 - 24 = 346
        --   candidate.x = anchor.x = 50
        local cluster_bbox = { x = 100, y = 400, w = 80, h = 30 }
        local anchor_bbox  = { x = 50,  y = 400, w = 200, h = 16 }
        local text_line_bboxes = {
            { x = 0, y = 400, w = 500, h = 16 },   -- anchor line full-width
            { x = 0, y = 440, w = 500, h = 360 },  -- below region full-blocked
        }
        local other_annotation_bboxes = {}
        local screen_bounds = { x = 0, y = 0, w = 500, h = 800 }

        local result = FreeSpot.find_free_spot(
            cluster_bbox, anchor_bbox,
            text_line_bboxes, other_annotation_bboxes, screen_bounds)

        assert.is_table(result)
        assert.are.equal(1.0, result.scale)
        assert.are.equal(anchor_bbox.x, result.x)  -- 50
        assert.are.equal(anchor_bbox.y - cluster_bbox.h * 1.0 - MARGIN, result.y)  -- 346
    end)

    it("G3-FS-6: L4 returns nil when both BELOW and ABOVE are blocked", function()
        -- Text fills the entire screen → no candidate (L2 margin or L4
        -- in-text) can possibly fit at any scale. find_free_spot must
        -- return nil so the rotation-badge EARNED path engages.
        local cluster_bbox = { x = 100, y = 400, w = 80, h = 30 }
        local anchor_bbox  = { x = 50,  y = 400, w = 200, h = 16 }
        local text_line_bboxes = {
            { x = 0, y = 0, w = 500, h = 800 },  -- text fills screen
        }
        local other_annotation_bboxes = {}
        local screen_bounds = { x = 0, y = 0, w = 500, h = 800 }

        local result = FreeSpot.find_free_spot(
            cluster_bbox, anchor_bbox,
            text_line_bboxes, other_annotation_bboxes, screen_bounds)

        assert.is_nil(result)
    end)

end)
