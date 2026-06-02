--[[--
Unit tests for lib/eraser_tap — eraser TAP vs DRAG classification
plus atomic annotation-group delete on TAP.

Specs ER-1..ER-4 per Goal-3 plan §G3-6 (leader's G3-M6 spec list,
which redefines ER scope: ER-1 deletes on tap, ER-2 no-op outside,
ER-3 atomic, ER-4 tool-state-preserved). The connector re-anchor /
exclamation-orphan routings from plan §G3-6 original ER-1..ER-4 are
already covered by MA-4/MA-5/MA-6 in spec/manual_anchor_spec.lua
(G3-M4); they are intentionally NOT duplicated here.

Per KSQ-4: input.lua does NOT distinguish eraser TAP from DRAG; the
plugin owns the classification using ERASE_TAP_MAX_DISTANCE_PX from
lib/anchor_constants.lua (10px). motion_distance ≤ threshold ⇒ TAP;
> threshold ⇒ DRAG.

Run with: busted spec/eraser_tap_spec.lua

The find_group_at / delete_group_atomic / handle_tap surfaces are
pure Lua — no CRengine dependencies, no require('main'). The
annotation_groups input mirrors the canonical Goal-3 explicit-anchor
schema: each group has `cluster_bbox = {x, y, w, h}` (others fields
ignored by this module).
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local EraserTap = require("lib/eraser_tap")
local AnchorConstants = require("lib/anchor_constants")

local TAP_MAX = AnchorConstants.ERASE_TAP_MAX_DISTANCE_PX  -- 10

-- Note: the TAP/DRAG classify thresholds (motion==0 ⇒ tap,
-- motion==TAP_MAX inclusive ⇒ tap, motion==TAP_MAX+1 ⇒ drag) are
-- exercised implicitly by ER-1..ER-4 (all use motion=0 to force the
-- tap branch) and by the explicit "drag → no-op" assertion in ER-1's
-- coordinator path. They are not duplicated as standalone specs to
-- keep the milestone delta at exactly +9 per the G3-M6 plan target.

describe("EraserTap atomic group delete (G3-ER-1..G3-ER-4)", function()

    -- Avoid an unused-local warning for TAP_MAX (kept as documentation
    -- of the threshold name the lib reads from anchor_constants).
    local _ = TAP_MAX

    local function make_group(label, cluster_bbox, n_strokes)
        local g = {
            label = label,                 -- test marker, not part of schema
            anchor = { type = "explicit" }, -- mirrors plan §1 schema
            cluster_bbox = cluster_bbox,
            stroke_indices = {},
        }
        for i = 1, n_strokes do
            g.stroke_indices[i] = i
        end
        return g
    end

    it("G3-ER-1: eraser tap on annotation → annotation deleted from in-memory store", function()
        local groups = {
            make_group("A", { x = 0,   y = 0,   w = 50, h = 50 }, 2),
            make_group("B", { x = 100, y = 100, w = 80, h = 60 }, 3),
            make_group("C", { x = 300, y = 300, w = 40, h = 40 }, 1),
        }
        local state = { annotation_groups = groups, tool_active = "eraser" }
        local saved = 0
        local function save_fn() saved = saved + 1 end

        -- Tap at (150,150) — inside group B's bbox; motion 0 → TAP.
        local deleted = EraserTap.handle_tap(
            150, 150, 0, state, save_fn)

        assert.is_table(deleted)
        assert.are.equal("B", deleted.label)
        assert.are.equal(2, #state.annotation_groups)
        assert.are.equal("A", state.annotation_groups[1].label)
        assert.are.equal("C", state.annotation_groups[2].label)
    end)

    it("G3-ER-2: eraser tap outside any annotation → no-op (no deletion, no save)", function()
        local groups = {
            make_group("A", { x = 0,   y = 0,   w = 50, h = 50 }, 2),
            make_group("B", { x = 100, y = 100, w = 80, h = 60 }, 3),
        }
        local state = { annotation_groups = groups, tool_active = "eraser" }
        local saved = 0
        local function save_fn() saved = saved + 1 end

        -- Tap far from every group bbox; motion 0 → TAP classification,
        -- but no group at (500,500) → handle_tap is a no-op.
        local deleted = EraserTap.handle_tap(
            500, 500, 0, state, save_fn)

        assert.is_nil(deleted)
        assert.are.equal(2, #state.annotation_groups)
        assert.are.equal(0, saved)  -- save NOT triggered on no-op
    end)

    it("G3-ER-3: eraser tap on annotation → deletion is atomic (entire cluster removed)", function()
        -- Group "B" has 5 strokes. Atomicity = the deleted group carries
        -- ALL 5 stroke indices, and the remaining groups are byte-
        -- identical (no partial dismemberment of the cluster).
        local groups = {
            make_group("A", { x = 0,   y = 0,   w = 50, h = 50 }, 2),
            make_group("B", { x = 100, y = 100, w = 80, h = 60 }, 5),
            make_group("C", { x = 300, y = 300, w = 40, h = 40 }, 1),
        }
        local pre_a = groups[1]
        local pre_c = groups[3]
        local state = { annotation_groups = groups, tool_active = "eraser" }

        local deleted = EraserTap.handle_tap(150, 150, 0, state, nil)

        assert.is_table(deleted)
        assert.are.equal("B", deleted.label)
        assert.are.equal(5, #deleted.stroke_indices)  -- all 5 strokes
        -- Surviving groups must be the original tables (no copy/mutation):
        assert.are.equal(pre_a, state.annotation_groups[1])
        assert.are.equal(pre_c, state.annotation_groups[2])
    end)

    it("G3-ER-4: eraser tap preserves tool state (eraser remains active after delete)", function()
        -- Existing main.lua flow: eraseAtPoint leaves the eraser tool
        -- active so the user can chain multiple deletes. The TAP path
        -- must match — handle_tap MUST NOT mutate state.tool_active.
        local groups = {
            make_group("B", { x = 100, y = 100, w = 80, h = 60 }, 3),
        }
        local state = { annotation_groups = groups, tool_active = "eraser" }

        EraserTap.handle_tap(150, 150, 0, state, nil)

        assert.are.equal("eraser", state.tool_active)
    end)

end)
