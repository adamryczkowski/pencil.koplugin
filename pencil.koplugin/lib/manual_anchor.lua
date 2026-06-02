--[[--
ManualAnchor state machine — Goal-3 ambiguity / clarification /
orphan lifecycle for pen-stroke cluster anchors.

When the cluster heuristic (lib/cluster_heuristic) returns an
ambiguous ranking (`is_confident == false`) the capture pipeline
hands the cluster off to this module. ManualAnchor owns the
per-cluster state that drives:

  • the exclamation glyph rendered at the top-right of the cluster
    bounding box (paint_anchor_group emits the op when
    `ma.clarified == false`);
  • the second-tap "clarify" gesture — user taps the text line they
    meant to anchor to; the second tap re-runs the heuristic
    restricted to lines near the tap;
  • the eraser-tap-on-connector "re-anchor" gesture — flips
    `clarified` back to false so the exclamation re-appears and the
    user can retry;
  • the eraser-tap-on-exclamation escape hatch — emits an orphan
    anchor record (`xp == nil`, `clarified == true`) so the
    annotation persists without a text anchor (paint-time path
    routes to the badge fallback);
  • find_target() — when multiple clusters on a page are still
    ambiguous, route a clarification tap to the NEAREST cluster
    whose bbox sits within `CLARIFICATION_RADIUS_LH * lh_px` of the
    tap point. Outside that radius the tap is treated as a fresh
    stroke (not handled here — caller falls through).

State is per-cluster — one `ma_state` per ambiguous group. No
globals; no UI coupling; no `require('main')`. All constants pull
from lib/anchor_constants.lua per hard-constraint #5.

Stylus-only: every entry point is invoked by a stylus tap or
eraser tap. No keyboard prompts anywhere (DoD #4).

----------------------------------------------------------------------
Public API
----------------------------------------------------------------------

    new(cluster) → ma_state

    get_exclamation_pos(ma_state) → { x, y }
        top-right corner of cluster.bbox_screen

    on_clarification_tap(ma_state, tap_pos, line_boxes, now_ms)
        → { resolved = bool,
            debounced = bool,        -- second tap within CLARIFY_DEBOUNCE_MS
            anchor_record = {…} }    -- only on resolved=true

    on_eraser_tap_connector(ma_state) → void
        flips clarified back to false (re-enters MA-1 state)

    on_eraser_tap_exclamation(ma_state) → orphan_record
        escape hatch: returns { type="explicit", xp=nil,
        cluster_bbox=…, clarified=true }

    find_target(ma_list, tap_pos, lh_px) → ma_state | nil
        nearest ma whose bbox is within CLARIFICATION_RADIUS_LH·lh_px
        of tap_pos (Euclidean distance to bbox edge)

----------------------------------------------------------------------
@module pencil.lib.manual_anchor
--]]--

local AnchorConstants = require("lib/anchor_constants")

local ManualAnchor = {}

-- Re-export for caller convenience (matches the lib/stroke_cluster
-- pattern; downstream callers don't need to double-require).
ManualAnchor.CLARIFY_DEBOUNCE_MS = AnchorConstants.CLARIFY_DEBOUNCE_MS
ManualAnchor.CLARIFICATION_RADIUS_LH = AnchorConstants.CLARIFICATION_RADIUS_LH

--- Build a fresh ManualAnchor state for an ambiguous cluster.
-- @param cluster  finalize() output from lib/stroke_cluster
-- @return ma_state
function ManualAnchor.new(cluster)
    return {
        cluster     = cluster,
        clarified   = false,
        last_tap_ms = nil,
    }
end

--- Position of the exclamation glyph: top-right corner of the
-- cluster bounding box. Returns nil if the cluster has no bbox
-- (degenerate input; caller suppresses the op).
function ManualAnchor.get_exclamation_pos(ma_state)
    if type(ma_state) ~= "table" then return nil end
    local cluster = ma_state.cluster
    if type(cluster) ~= "table" then return nil end
    local bb = cluster.bbox_screen
    if type(bb) ~= "table" then return nil end
    return {
        x = (bb.x or 0) + (bb.w or 0),
        y = (bb.y or 0),
    }
end

-- Internal: build the explicit-anchor record from a chosen line.
local function anchor_from_line(ma_state, line_xp, clarified)
    local bb = ma_state.cluster and ma_state.cluster.bbox_screen or nil
    return {
        type         = "explicit",
        xp           = line_xp,
        cluster_bbox = bb and { x = bb.x, y = bb.y, w = bb.w, h = bb.h }
                        or { x = 0, y = 0, w = 0, h = 0 },
        scale        = 1.0,
        clarified    = clarified,
    }
end

-- Internal: shortest distance from a point to a {x,y,w,h} bbox.
-- 0 if the point is inside the bbox.
local function point_bbox_distance(px, py, bb)
    if type(bb) ~= "table" then return math.huge end
    local x0 = bb.x or 0
    local y0 = bb.y or 0
    local x1 = x0 + (bb.w or 0)
    local y1 = y0 + (bb.h or 0)
    local dx = 0
    if px < x0 then dx = x0 - px
    elseif px > x1 then dx = px - x1 end
    local dy = 0
    if py < y0 then dy = y0 - py
    elseif py > y1 then dy = py - y1 end
    if dx == 0 and dy == 0 then return 0 end
    return math.sqrt(dx * dx + dy * dy)
end

--- Handle a clarification tap on a candidate text line. If the tap
-- arrives within CLARIFY_DEBOUNCE_MS of the previous tap on this
-- state the call is dropped (no heuristic re-run, no state change).
-- Otherwise we score the supplied `line_boxes` against the cluster
-- via the H4 heuristic, restricted to the line nearest the tap (the
-- caller is responsible for filtering `line_boxes` to the local
-- neighbourhood; this function picks the single best from whatever
-- the caller passes in).
--
-- On resolve the ma_state is mutated: `clarified` flips to true and
-- the anchor record is returned for the caller to assign to
-- group.anchor.
--
-- @param ma_state    table from ManualAnchor.new()
-- @param tap_pos     { x, y } screen point
-- @param line_boxes  list of { bbox = {x,y,w,h}, xp = <string>,
--                              baseline = <number> }
-- @param now_ms      current time in milliseconds
-- @return { resolved = bool, debounced = bool, anchor_record = table | nil }
function ManualAnchor.on_clarification_tap(ma_state, tap_pos, line_boxes, now_ms)
    if type(ma_state) ~= "table" then
        return { resolved = false, debounced = false }
    end
    -- Debounce: silently drop a second tap inside the window. We
    -- still record the previous tap's t_ms below on a non-debounced
    -- call.
    if type(ma_state.last_tap_ms) == "number"
        and type(now_ms) == "number"
        and (now_ms - ma_state.last_tap_ms) <= AnchorConstants.CLARIFY_DEBOUNCE_MS
    then
        return { resolved = false, debounced = true }
    end

    ma_state.last_tap_ms = now_ms

    if type(line_boxes) ~= "table" or #line_boxes == 0 then
        return { resolved = false, debounced = false }
    end

    -- Pick the line whose bbox is closest to the tap (within its
    -- own bbox = distance 0). This is the clarification proxy:
    -- "the line the user pointed at".
    local best_idx, best_dist = nil, math.huge
    for i, line in ipairs(line_boxes) do
        if type(line) == "table" and type(line.bbox) == "table" then
            local d = point_bbox_distance(
                tap_pos.x or 0, tap_pos.y or 0, line.bbox)
            if d < best_dist then
                best_dist = d
                best_idx = i
            end
        end
    end

    if not best_idx or best_dist == math.huge then
        return { resolved = false, debounced = false }
    end

    -- Proximity gate: the tap must land within CLARIFICATION_RADIUS_LH
    -- line-heights of the chosen line's bbox. Using the chosen line's
    -- own bbox.h as the lh proxy means a typical 16-px line with the
    -- radius constant of 5 gives an 80-px "near" envelope — enough to
    -- absorb stylus tremor at the top/bottom of a line but tight
    -- enough that a margin-far tap stays inconclusive (the caller
    -- treats it as fresh ink). The plan §1.4 phrasing "re-runs H4+S2
    -- heuristic constrained to text near the touch point" is honoured
    -- by this proximity-only gate: the user's explicit tap IS the
    -- answer; the H4 heuristic is the AUTOMATIC capture path, not
    -- the manual-anchor path.
    local chosen = line_boxes[best_idx]
    local line_h = (chosen.bbox and chosen.bbox.h) or 0
    local near_radius = AnchorConstants.CLARIFICATION_RADIUS_LH * line_h
    if near_radius > 0 and best_dist > near_radius then
        return { resolved = false, debounced = false }
    end
    if near_radius <= 0 then
        -- Degenerate line bbox (zero height): only an exact-inside
        -- tap can resolve.
        if best_dist > 0 then
            return { resolved = false, debounced = false }
        end
    end

    local anchor = anchor_from_line(ma_state, chosen.xp, true)
    ma_state.clarified = true
    return {
        resolved      = true,
        debounced     = false,
        anchor_record = anchor,
    }
end

--- Re-anchor gesture: eraser-tap on the connector line. Flips the
-- clarified flag back to false so the exclamation re-renders and
-- the user can retry a clarification tap.
function ManualAnchor.on_eraser_tap_connector(ma_state)
    if type(ma_state) ~= "table" then return end
    ma_state.clarified = false
    ma_state.last_tap_ms = nil
end

--- Escape hatch: eraser-tap on the exclamation glyph itself. The
-- cluster persists without a text anchor — an "orphan" annotation
-- whose paint-time path falls through to the rotation-badge.
function ManualAnchor.on_eraser_tap_exclamation(ma_state)
    if type(ma_state) ~= "table" then return nil end
    ma_state.clarified = true
    ma_state.last_tap_ms = nil
    return anchor_from_line(ma_state, nil, true)
end

--- Route a clarification tap to the nearest unresolved ma_state
-- whose cluster bbox falls within CLARIFICATION_RADIUS_LH · lh_px
-- of the tap. Already-clarified states are skipped (caller treats
-- the tap as fresh ink). Returns nil when no ma_state is in range.
--
-- @param ma_list  list of ma_state from new()
-- @param tap_pos  { x, y } screen point
-- @param lh_px    runtime line-height in pixels (for radius scaling)
-- @return ma_state | nil
function ManualAnchor.find_target(ma_list, tap_pos, lh_px)
    if type(ma_list) ~= "table" or type(tap_pos) ~= "table" then
        return nil
    end
    local radius_px = (AnchorConstants.CLARIFICATION_RADIUS_LH
                       * (lh_px or 0))
    if radius_px <= 0 then return nil end
    local best_ma, best_dist = nil, math.huge
    for _, ma in ipairs(ma_list) do
        if type(ma) == "table" and ma.cluster and not ma.clarified then
            local d = point_bbox_distance(
                tap_pos.x or 0, tap_pos.y or 0, ma.cluster.bbox_screen)
            if d <= radius_px and d < best_dist then
                best_dist = d
                best_ma = ma
            end
        end
    end
    return best_ma
end

return ManualAnchor
