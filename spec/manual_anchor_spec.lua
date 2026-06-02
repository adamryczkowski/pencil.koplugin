--[[--
Unit tests for lib/manual_anchor — Goal-3 manual-anchor state machine.

Specs MA-1..MA-6 + MA-LAT-1 per Goal-3 plan §2 (G3-M4).

The module owns the exclamation/clarify/orphan/re-anchor lifecycle
for ambiguous clusters. State is per-cluster (one ma_state per group);
the module has no globals. All entry points are pure-Lua, so this
spec file does NOT require('main').

CLARIFY_DEBOUNCE_MS = 300 and CLARIFICATION_RADIUS_LH = 5 are sourced
from lib/anchor_constants.lua per hard-constraint #5.

Run with: busted spec/manual_anchor_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local ManualAnchor = require("lib/manual_anchor")
local AnchorConstants = require("lib/anchor_constants")

local DEBOUNCE = AnchorConstants.CLARIFY_DEBOUNCE_MS
local RADIUS_LH = AnchorConstants.CLARIFICATION_RADIUS_LH

local function make_cluster(opts)
    opts = opts or {}
    return {
        strokes = opts.strokes or {},
        bbox_screen = opts.bbox or { x = 100, y = 200, w = 80, h = 40 },
        page = opts.page or 1,
        t_first = opts.t_first or 1000,
        t_last = opts.t_last or 1000,
    }
end

describe("ManualAnchor", function()

    it("G3-MA-1: ambiguous cluster → new ma_state starts unclarified; exclamation at top-right of cluster_bbox", function()
        local cluster = make_cluster({ bbox = { x = 100, y = 200, w = 80, h = 40 } })
        local ma = ManualAnchor.new(cluster)
        assert.is_table(ma)
        assert.is_false(ma.clarified)
        -- Exclamation is rendered at the top-right corner of the cluster bbox.
        local pos = ManualAnchor.get_exclamation_pos(ma)
        assert.equals(100 + 80, pos.x)  -- right edge
        assert.equals(200, pos.y)        -- top edge
    end)

    it("G3-MA-2: confident clarification tap resolves the anchor → clarified=true, exclamation dismissed", function()
        local cluster = make_cluster()
        local ma = ManualAnchor.new(cluster)
        local line_boxes = {
            { bbox = { x = 100, y = 240, w = 200, h = 16 }, xp = "/p[5]/text()" },
        }
        local tap = { x = 150, y = 248 }   -- inside the line bbox
        local result = ManualAnchor.on_clarification_tap(ma, tap, line_boxes, 1500)
        assert.is_true(result.resolved)
        assert.is_table(result.anchor_record)
        assert.equals("explicit", result.anchor_record.type)
        assert.equals("/p[5]/text()", result.anchor_record.xp)
        assert.is_true(result.anchor_record.clarified)
        -- Side-effect: the ma_state is now also marked clarified so
        -- the caller knows to drop the exclamation op.
        assert.is_true(ma.clarified)
    end)

    it("G3-MA-3: per-group state — a second cluster does not inherit the first cluster's resolution", function()
        local c1 = make_cluster({ bbox = { x = 100, y = 200, w = 80, h = 40 } })
        local c2 = make_cluster({ bbox = { x = 400, y = 500, w = 60, h = 30 } })
        local ma1 = ManualAnchor.new(c1)
        local ma2 = ManualAnchor.new(c2)
        assert.is_not.equal(ma1, ma2)
        -- Resolve ma1.
        local line_boxes = {
            { bbox = { x = 100, y = 240, w = 200, h = 16 }, xp = "/p[5]/text()" },
        }
        ManualAnchor.on_clarification_tap(ma1,
            { x = 150, y = 248 }, line_boxes, 1500)
        assert.is_true(ma1.clarified)
        -- ma2 is unaffected.
        assert.is_false(ma2.clarified)
    end)

    it("G3-MA-4: eraser-tap on connector → clarified flips back to false (re-anchor gesture)", function()
        local cluster = make_cluster()
        local ma = ManualAnchor.new(cluster)
        local line_boxes = {
            { bbox = { x = 100, y = 240, w = 200, h = 16 }, xp = "/p[5]/text()" },
        }
        ManualAnchor.on_clarification_tap(ma,
            { x = 150, y = 248 }, line_boxes, 1500)
        assert.is_true(ma.clarified)
        ManualAnchor.on_eraser_tap_connector(ma)
        assert.is_false(ma.clarified)
    end)

    it("G3-MA-5: nearest-cluster routing — tap within CLARIFICATION_RADIUS_LH·lh resolves to closest ma_state", function()
        local c1 = make_cluster({ bbox = { x = 100, y = 200, w = 80, h = 40 } })
        local c2 = make_cluster({ bbox = { x = 500, y = 200, w = 80, h = 40 } })
        local ma1 = ManualAnchor.new(c1)
        local ma2 = ManualAnchor.new(c2)
        local lh = 20
        -- Tap right next to c1's bbox.
        local near_c1 = { x = 110, y = 240 }
        local target = ManualAnchor.find_target({ ma1, ma2 }, near_c1, lh)
        assert.equals(ma1, target)
        -- Tap far from both (outside the radius).
        local far_off = { x = 1500, y = 1500 }
        local none = ManualAnchor.find_target({ ma1, ma2 }, far_off, lh)
        assert.is_nil(none)
    end)

    it("G3-MA-6: eraser-tap on exclamation → orphan annotation record (xp=nil; clarified=true escape hatch)", function()
        local cluster = make_cluster({ bbox = { x = 100, y = 200, w = 80, h = 40 } })
        local ma = ManualAnchor.new(cluster)
        local orphan = ManualAnchor.on_eraser_tap_exclamation(ma)
        assert.is_table(orphan)
        assert.equals("explicit", orphan.type)
        assert.is_nil(orphan.xp)
        assert.is_true(orphan.clarified)
        -- Side-effect: ma_state goes to clarified so the exclamation
        -- is dismissed from the render_op_list.
        assert.is_true(ma.clarified)
        -- cluster_bbox is preserved for paint-time positioning of the badge.
        assert.equals(100, orphan.cluster_bbox.x)
        assert.equals(80, orphan.cluster_bbox.w)
    end)

    it("G3-MA-LAT-1: clarification tap debounce — second tap within CLARIFY_DEBOUNCE_MS is silently dropped", function()
        local cluster = make_cluster()
        local ma = ManualAnchor.new(cluster)
        local line_boxes = {
            { bbox = { x = 100, y = 240, w = 200, h = 16 }, xp = "/p[5]/text()" },
            { bbox = { x = 100, y = 260, w = 200, h = 16 }, xp = "/p[6]/text()" },
        }
        -- First tap: ambiguity NOT resolved (heuristic returns no clear
        -- winner). Use a tap far from any line so both lines score 0.
        local far_tap = { x = 9999, y = 9999 }
        local r1 = ManualAnchor.on_clarification_tap(ma, far_tap, line_boxes, 1000)
        assert.is_false(r1.resolved)
        assert.is_falsy(r1.debounced)
        assert.is_false(ma.clarified)
        -- Second tap within CLARIFY_DEBOUNCE_MS of the first.
        local r2 = ManualAnchor.on_clarification_tap(ma,
            { x = 150, y = 248 }, line_boxes, 1000 + DEBOUNCE - 1)
        assert.is_false(r2.resolved)
        assert.is_true(r2.debounced)
        assert.is_false(ma.clarified)  -- unchanged
        -- A third tap exactly at debounce window expiry IS processed.
        local r3 = ManualAnchor.on_clarification_tap(ma,
            { x = 150, y = 248 }, line_boxes, 1000 + DEBOUNCE + 1)
        assert.is_falsy(r3.debounced)
    end)

end)
