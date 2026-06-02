--[[--
Eraser TAP vs DRAG classification + atomic annotation-group delete on
TAP. Per Goal-3 plan §G3-6 and KSQ-4 resolution: input.lua does NOT
distinguish eraser TAP from DRAG at the input layer (all BTN_TOOL_RUBBER
events route identically), so the plugin owns the distinction here
using ERASE_TAP_MAX_DISTANCE_PX from lib/anchor_constants.lua.

A TAP (motion_distance ≤ threshold) on an annotation group's
cluster_bbox triggers an atomic group delete — the entire cluster is
removed in a single table.remove call so the 3-artefact atomicity
invariant (group + anchor highlight + connector) is upheld by virtue of
all three artefacts living in or being derived from the single group
record.

A DRAG (motion_distance > threshold) is the existing per-stroke erase
path (main.lua:eraseAtPoint) and is NOT re-implemented here — this
module is the TAP branch only.

----------------------------------------------------------------------
Public API
----------------------------------------------------------------------

    classify(motion_distance_px)
        → "tap"   if motion_distance_px ≤ ERASE_TAP_MAX_DISTANCE_PX
        → "drag"  otherwise

    find_group_at(x, y, annotation_groups, hit_target_px)
        → group_index | nil
                  first group whose cluster_bbox (optionally padded by
                  hit_target_px) contains (x, y); nil when no group is
                  under the tap point.

    delete_group_atomic(annotation_groups, group_index)
        → deleted_group | nil
                  table.remove the group at group_index and return the
                  removed table; nil when group_index is out of range.

    handle_tap(x, y, motion_distance_px, state, save_fn)
        → deleted_group | nil
                  Coordinator: classify motion → tap; find group → idx;
                  delete atomically → mutate state.annotation_groups;
                  invoke save_fn(state) exactly once on successful
                  delete; nil + no save_fn call when nothing to delete
                  or when motion classifies as drag.

state shape:  { annotation_groups = [...], tool_active = "eraser",
                ... } — only annotation_groups is mutated; other
                fields (notably tool_active) are deliberately preserved
                so the eraser tool stays active across chained deletes
                (matches existing main.lua flow).

@module pencil.lib.eraser_tap
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local AnchorConstants = require("lib/anchor_constants")

local EraserTap = {}

local ERASE_TAP_MAX_DISTANCE_PX = AnchorConstants.ERASE_TAP_MAX_DISTANCE_PX
local DEFAULT_HIT_TARGET_PX     = 0  -- hit-test uses bbox itself by default

--- Classify a single eraser gesture (one pen-down ⇢ pen-up cycle).
-- Inclusive threshold: a motion distance equal to the threshold still
-- counts as a tap. Negative or non-numeric inputs are treated as zero.
function EraserTap.classify(motion_distance_px)
    if type(motion_distance_px) ~= "number" or motion_distance_px < 0 then
        motion_distance_px = 0
    end
    if motion_distance_px <= ERASE_TAP_MAX_DISTANCE_PX then
        return "tap"
    end
    return "drag"
end

--- Strict-inequality AABB hit-test, padded by hit_target_px on every
-- side. Returns the index of the FIRST group whose cluster_bbox
-- contains (x, y) within the padded region, or nil. Groups are
-- iterated in their canonical order so the topmost-painted (latest)
-- group wins when bboxes overlap — this matches the visual stacking
-- order from lib/stroke_paint.lua's render-op sequence.
function EraserTap.find_group_at(x, y, annotation_groups, hit_target_px)
    if not annotation_groups then return nil end
    local pad = hit_target_px or DEFAULT_HIT_TARGET_PX
    for i, group in ipairs(annotation_groups) do
        local bb = group and group.cluster_bbox
        if bb then
            if x >= bb.x - pad
               and x <= bb.x + bb.w + pad
               and y >= bb.y - pad
               and y <= bb.y + bb.h + pad then
                return i
            end
        end
    end
    return nil
end

--- Remove the group at group_index from the list atomically. Returns
-- the removed group table or nil. Uses table.remove for O(n)
-- list-shift semantics; the entire group is removed in a single call
-- so a partial delete (one stroke from a multi-stroke cluster) is
-- impossible at this layer.
function EraserTap.delete_group_atomic(annotation_groups, group_index)
    if not annotation_groups or type(group_index) ~= "number" then
        return nil
    end
    if group_index < 1 or group_index > #annotation_groups then
        return nil
    end
    return table.remove(annotation_groups, group_index)
end

--- Coordinator: classify motion, look up group, delete atomically,
-- fire save callback. Returns the deleted group or nil. state.
-- tool_active and any other non-annotation_groups field is preserved
-- (no implicit tool-state reset).
function EraserTap.handle_tap(x, y, motion_distance_px, state, save_fn)
    if not state or not state.annotation_groups then return nil end
    if EraserTap.classify(motion_distance_px) ~= "tap" then
        return nil
    end
    local idx = EraserTap.find_group_at(
        x, y, state.annotation_groups, DEFAULT_HIT_TARGET_PX)
    if not idx then return nil end
    local deleted = EraserTap.delete_group_atomic(
        state.annotation_groups, idx)
    if deleted and save_fn then
        save_fn(state)
    end
    return deleted
end

return EraserTap
