--[[--
Unit tests for lib/stroke_cluster — pure-Lua cluster state machine.

Specs CL-1..CL-5 per Goal-3 plan §2 (G3-M2).

Run with: busted spec/stroke_cluster_spec.lua

The module under test is dependency-free pure Lua: no CRengine calls,
no UIManager, no plugin state. Stroke records are plain tables with
{bbox = {x0,y0,x1,y1}, t_ms = <number>, page = <number>}, so this
spec file does NOT require('main') and does NOT mock CRengine.

Reuses GROUP_SPATIAL_THRESHOLD (=200) and CLUSTER_CLOSE_TIMEOUT_MS
(=1200) from lib/anchor_constants.lua per operator hard-constraint #5
(no inline numeric literals at sites).
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokeCluster = require("lib/stroke_cluster")
local AnchorConstants = require("lib/anchor_constants")

local TIMEOUT_MS = AnchorConstants.CLUSTER_CLOSE_TIMEOUT_MS
local SPATIAL_PX = AnchorConstants.GROUP_SPATIAL_THRESHOLD

--- Helper: build a stroke record with sensible defaults.
local function S(x0, y0, x1, y1, t_ms, page)
    return {
        bbox = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 },
        t_ms = t_ms,
        page = page or 1,
    }
end

describe("StrokeCluster", function()

    it("G3-CL-1: single stroke finalizes after CLUSTER_CLOSE_TIMEOUT_MS", function()
        -- Cluster boundary = no new pen-DOWN within CLUSTER_CLOSE_TIMEOUT_MS
        -- of the previous pen-DOWN. should_close is the pure-Lua test that
        -- the main.lua timer wraps; cluster goes from "open" → "closed" at
        -- the timeout threshold.
        local c = StrokeCluster.new()
        StrokeCluster.add_stroke(c, S(10, 20, 30, 40, 1000))
        -- At the boundary itself: still open (strict >, not >=).
        assert.is_false(StrokeCluster.should_close(c, 1000 + TIMEOUT_MS))
        -- 1 ms past the boundary: closed.
        assert.is_true(StrokeCluster.should_close(c, 1000 + TIMEOUT_MS + 1))
        local rec = StrokeCluster.finalize(c)
        assert.is_not_nil(rec)
        assert.equals(1, #rec.strokes)
        assert.equals(1000, rec.t_first)
        assert.equals(1000, rec.t_last)
        assert.equals(1, rec.page)
    end)

    it("G3-CL-2: two strokes within CLUSTER_CLOSE_TIMEOUT_MS → same cluster", function()
        -- Spatial-proximity AND time-proximity both satisfied → second stroke
        -- joins the same cluster (should_join true; cluster not yet closed
        -- at the second stroke's arrival time).
        local c = StrokeCluster.new()
        StrokeCluster.add_stroke(c, S(10, 20, 30, 40, 1000))
        local s2 = S(35, 22, 55, 42, 1000 + TIMEOUT_MS - 1)  -- 1 ms before close
        assert.is_false(StrokeCluster.should_close(c, s2.t_ms))
        assert.is_true(StrokeCluster.should_join(c, s2))
        StrokeCluster.add_stroke(c, s2)
        assert.equals(2, #c.strokes)
        assert.equals(1000, c.t_first)
        assert.equals(s2.t_ms, c.t_last)
    end)

    it("G3-CL-3: two strokes > CLUSTER_CLOSE_TIMEOUT_MS apart → different clusters", function()
        -- Caller's loop: should_close true at the second stroke's arrival
        -- time → finalize old cluster, start a new one. Two distinct cluster
        -- records, each with one stroke.
        local c1 = StrokeCluster.new()
        StrokeCluster.add_stroke(c1, S(10, 20, 30, 40, 1000))
        local s2_t = 1000 + TIMEOUT_MS + 100  -- 100ms past the close boundary
        assert.is_true(StrokeCluster.should_close(c1, s2_t))
        local rec1 = StrokeCluster.finalize(c1)
        local c2 = StrokeCluster.new()
        StrokeCluster.add_stroke(c2, S(12, 22, 32, 42, s2_t))
        local rec2 = StrokeCluster.finalize(c2)
        assert.equals(1, #rec1.strokes)
        assert.equals(1, #rec2.strokes)
        assert.equals(1000, rec1.t_first)
        assert.equals(s2_t, rec2.t_first)
    end)

    it("G3-CL-4: cluster bbox spans union of all stroke bboxes ({x,y,w,h} shape)", function()
        -- get_bbox returns the {x,y,w,h} shape matching the plan §1 explicit
        -- anchor schema (group.anchor.cluster_bbox); internal math uses
        -- {x0,y0,x1,y1} but the public shape is the persistable one.
        local c = StrokeCluster.new()
        StrokeCluster.add_stroke(c, S(10, 20, 30, 40, 1000))
        StrokeCluster.add_stroke(c, S(50, 10, 70, 50, 1100))
        StrokeCluster.add_stroke(c, S(20, 30, 40, 60, 1200))
        -- Union: x0=10, y0=10, x1=70, y1=60 → x=10, y=10, w=60, h=50.
        local bb = StrokeCluster.get_bbox(c)
        assert.equals(10, bb.x)
        assert.equals(10, bb.y)
        assert.equals(60, bb.w)
        assert.equals(50, bb.h)
        -- finalize() returns same shape under .bbox_screen (matches the
        -- arch-planner cluster record signature).
        local rec = StrokeCluster.finalize(c)
        assert.equals(10, rec.bbox_screen.x)
        assert.equals(60, rec.bbox_screen.w)
        assert.equals(50, rec.bbox_screen.h)
    end)

    it("G3-CL-5: strokes > GROUP_SPATIAL_THRESHOLD apart → separate clusters", function()
        -- AND condition with time-proximity: even if the second stroke
        -- arrives within CLUSTER_CLOSE_TIMEOUT_MS, a spatial gap larger
        -- than GROUP_SPATIAL_THRESHOLD blocks the join. Caller starts a
        -- new cluster.
        local c = StrokeCluster.new()
        StrokeCluster.add_stroke(c, S(10, 20, 30, 40, 1000))
        -- Second stroke 300 px right (x-gap = 330 - 30 = 300 > 200).
        local s2 = S(330, 22, 350, 42, 1100)
        -- Time window is fine (only 100 ms elapsed).
        assert.is_false(StrokeCluster.should_close(c, s2.t_ms))
        -- But spatial gap blocks the merge.
        assert.is_false(StrokeCluster.should_join(c, s2))
        -- Boundary case: stroke exactly at SPATIAL_PX gap → joins (inclusive).
        local s_boundary = S(30 + SPATIAL_PX, 22, 30 + SPATIAL_PX + 10, 42, 1100)
        assert.is_true(StrokeCluster.should_join(c, s_boundary))
    end)

end)
