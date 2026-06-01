--[[--
Unit tests for lib/cluster_heuristic — H4 (overlap × crossing_count)
scorer and S2 ranked top-3 output.

Specs AH-1..AH-6 per Goal-3 plan §2 (G3-M3).

Run with: busted spec/cluster_heuristic_spec.lua

The scoring and ranking surface is pure Lua — no CRengine dependencies,
no require('main'). The fetch_line_boxes helper (AH-6) is the single
engine-touching entry point and is exercised against an inline mock
`doc` whose shape mirrors KOReader's credocument.lua (KS a43eb8db):
- `doc:getPageXPointer(page)`           → xpointer string
- `doc:getScreenBoxesFromPositions(...)` → list of {x, y, w, h}

Both are pcall-wrapped in the lib (build-compat idiom).
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local ClusterHeuristic = require("lib/cluster_heuristic")
local AnchorConstants = require("lib/anchor_constants")

local GAP = AnchorConstants.AMBIGUITY_GAP_THRESHOLD

describe("ClusterHeuristic", function()

    it("G3-AH-1: cluster inside line bbox → score = overlap × crossings, positive", function()
        -- Line spans y∈[20,40], h=20; baseline at center (y=30).
        -- Cluster is fully inside line bbox and the stroke segment
        -- midpoints sit inside the [baseline − 0.5·lh, baseline + 0.5·lh]
        -- band, so both overlap and crossing_count are nonzero.
        local line_bbox = { x = 10, y = 20, w = 200, h = 20 }
        local line_baseline = 30
        local cluster_bbox = { x = 20, y = 22, w = 10, h = 8 }
        local midpoints = {
            { x = 25, y = 28 },  -- inside band
            { x = 27, y = 32 },  -- inside band
        }
        local score = ClusterHeuristic.score_line(
            cluster_bbox, midpoints, line_bbox, line_baseline)
        -- overlap = (10·8) / (10·8) = 1.0; crossings = 2; score = 2.0.
        assert.is_true(score > 0)
        assert.equals(2.0, score)
    end)

    it("G3-AH-2: cluster in margin, zero crossings → score = 0", function()
        -- Cluster sits entirely off the line bbox AND all midpoints fall
        -- outside the baseline band. The crossing_count factor is 0 so
        -- the product is 0 regardless of (here-also-zero) overlap.
        local line_bbox = { x = 10, y = 20, w = 200, h = 20 }
        local line_baseline = 30
        local cluster_bbox = { x = 300, y = 100, w = 20, h = 20 }
        local midpoints = {
            { x = 305, y = 110 },
            { x = 315, y = 115 },
        }
        local score = ClusterHeuristic.score_line(
            cluster_bbox, midpoints, line_bbox, line_baseline)
        assert.equals(0, score)
    end)

    it("G3-AH-3: top1 − top2 > AMBIGUITY_GAP_THRESHOLD → is_confident = true", function()
        -- 0.30 gap > 0.20 threshold → confident.
        local ranked = {
            { line_bbox = {}, xp = "a", score = 0.80 },
            { line_bbox = {}, xp = "b", score = 0.50 },
            { line_bbox = {}, xp = "c", score = 0.10 },
        }
        assert.is_true(ClusterHeuristic.is_confident(ranked, GAP))
    end)

    it("G3-AH-4: top1 − top2 ≤ AMBIGUITY_GAP_THRESHOLD → is_confident = false", function()
        -- 0.10 gap ≤ 0.20 threshold → ambiguous; manual-anchor prompt
        -- will fire at the paint site (G3-M4 MA state).
        local ranked = {
            { line_bbox = {}, xp = "a", score = 0.50 },
            { line_bbox = {}, xp = "b", score = 0.40 },
            { line_bbox = {}, xp = "c", score = 0.10 },
        }
        assert.is_false(ClusterHeuristic.is_confident(ranked, GAP))
    end)

    it("G3-AH-5: empty line list → rank returns {} and is_confident returns false", function()
        local cluster = {
            strokes     = {},
            bbox_screen = { x = 10, y = 20, w = 30, h = 30 },
        }
        local ranked = ClusterHeuristic.rank(cluster, {})
        assert.is_table(ranked)
        assert.equals(0, #ranked)
        assert.is_false(ClusterHeuristic.is_confident(ranked, GAP))
    end)

    it("G3-AH-6: fetch_line_boxes pcall-wraps getScreenBoxesFromPositions; mock matches credocument {x,y,w,h} shape", function()
        -- Happy path — mock `doc` modelled after credocument.lua (KS
        -- a43eb8db): getPageXPointer(p) returns a string; getScreen-
        -- BoxesFromPositions(xp0, xp1, true) returns list of
        -- {x,y,w,h} rectangles.
        local calls = { getPageXPointer = 0, getScreenBoxesFromPositions = 0 }
        local mock_doc = {
            getPageXPointer = function(self, page)
                calls.getPageXPointer = calls.getPageXPointer + 1
                return "/body/DocFragment[1]/text()[" .. tostring(page) .. "]"
            end,
            getScreenBoxesFromPositions = function(self, xp0, xp1, do_join)
                calls.getScreenBoxesFromPositions = calls.getScreenBoxesFromPositions + 1
                assert.is_string(xp0)
                assert.is_string(xp1)
                return {
                    { x = 10, y = 20, w = 200, h = 16 },
                    { x = 10, y = 40, w = 195, h = 16 },
                    { x = 10, y = 60, w = 180, h = 16 },
                }
            end,
        }
        local boxes = ClusterHeuristic.fetch_line_boxes(mock_doc, 1)
        assert.is_table(boxes)
        assert.equals(3, #boxes)
        assert.equals(10, boxes[1].x)
        assert.equals(20, boxes[1].y)
        assert.equals(200, boxes[1].w)
        assert.equals(16, boxes[1].h)
        assert.equals(2, calls.getPageXPointer)
        assert.equals(1, calls.getScreenBoxesFromPositions)

        -- Error path — pcall must catch a throw from either call site;
        -- fetch returns nil without raising.
        local throwing_doc = {
            getPageXPointer = function(self, page) error("boom") end,
            getScreenBoxesFromPositions = function(self) error("nope") end,
        }
        local nil_boxes = ClusterHeuristic.fetch_line_boxes(throwing_doc, 1)
        assert.is_nil(nil_boxes)

        -- Wrong return shape (non-table) → graceful nil, no crash.
        local bad_shape_doc = {
            getPageXPointer = function(self, page) return "xp:" .. page end,
            getScreenBoxesFromPositions = function(self) return 42 end,
        }
        local nil_boxes2 = ClusterHeuristic.fetch_line_boxes(bad_shape_doc, 1)
        assert.is_nil(nil_boxes2)
    end)

end)
