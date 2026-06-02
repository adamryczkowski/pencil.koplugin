--[[--
Two-tier auto-layout for Goal-3 explicit pen-stroke annotation clusters:

  L2  margin-preference pass  (G3-M5a) — try LEFT then RIGHT page
                                          margin strip at decreasing
                                          SCALE_STEP_RATIOS.
  L4  in-text BELOW/ABOVE port (G3-M5b) — when L2 exhausts, try
                                          placing the cluster directly
                                          below the anchor line first
                                          (Western reading-order
                                          precedence), then above.

Both passes share a strict-inequality AABB collision predicate
(`overlaps`) and a single SCALE_STEP_RATIOS descent. When both passes
exhaust without a non-colliding placement, find_free_spot returns nil
and the calling main.lua wiring falls through to the rotation-badge
EARNED path (existing prior-production fallback, preserved byte-
identical at main.lua:4239-4311).

The L4 BELOW/ABOVE shape is ported (not monkey-patched) from
ReaderHighlight:_getDialogAnchor (readerhighlight.lua:1470-1476). The
existing readerhighlight implementation always centers x; that is
incompatible with our anchor-anchored x semantics (cluster left edge
sits at anchor_bbox.x), so we replicate the y-arithmetic but keep our
own x choice.

Plan §1.5 / §2 G3-M5a + G3-M5b. All constants (FREE_SPOT_MARGIN_PX,
SCALE_STEP_RATIOS, MIN_SCALE_RATIO, FREE_SPOT_HISTORY_CAP) live in
lib/anchor_constants.lua per hard-constraint #5 — no inline numeric
literal at L2 or L4 sites. FREE_SPOT_MARGIN_PX doubles as the L4
padding between anchor edge and cluster edge.

----------------------------------------------------------------------
Public API
----------------------------------------------------------------------

    find_free_spot(cluster_bbox, anchor_bbox, text_line_bboxes,
                   other_annotation_bboxes, screen_bounds)
        → { x, y, scale }   placement found (LEFT or RIGHT margin, at
                            the largest non-colliding SCALE_STEP_RATIO
                            ≥ MIN_SCALE_RATIO)
        → nil               no margin candidate fits at any scale
                            (caller falls back to rotation-badge)

All inputs are plain rect tables `{ x, y, w, h }` in screen pixels.
screen_bounds is the active viewport (usually `{x=0, y=0, w=screen_w,
h=screen_h}`). text_line_bboxes is the list of visible text lines on
the current page (sourced via getScreenBoxesFromPositions in the
calling main.lua wiring; this module sees only the rect list, no
CRengine handle).

----------------------------------------------------------------------
Algorithm
----------------------------------------------------------------------

L2 (margin-preference pass):
    For each side in {LEFT, RIGHT}:
        For each scale in SCALE_STEP_RATIOS (descending):
            Skip if scale < MIN_SCALE_RATIO (readability floor, DoD §B).
            scaled_w = cluster_bbox.w * scale
            scaled_h = cluster_bbox.h * scale
            candidate.x = 0                        (LEFT)
                        | screen_bounds.w - scaled_w (RIGHT)
            candidate.y = anchor_bbox.y            (y near the anchor)
            If non-colliding, return { x, y, scale }.

L4 (in-text BELOW/ABOVE port, R-precedent-only):
    L4-BELOW guard: anchor_bbox.y + anchor_bbox.h + FREE_SPOT_MARGIN_PX
                    < screen_bounds.h. (Otherwise no room below.)
        For each scale in SCALE_STEP_RATIOS:
            candidate.x = anchor_bbox.x
            candidate.y = anchor_bbox.y + anchor_bbox.h + FREE_SPOT_MARGIN_PX
            If non-colliding, return { x, y, scale }.
    L4-ABOVE guard: FREE_SPOT_MARGIN_PX
                    < anchor_bbox.y - cluster_bbox.h * MIN_SCALE_RATIO.
                    (Otherwise the smallest-allowed cluster cannot fit
                    above even at the readability floor.)
        For each scale in SCALE_STEP_RATIOS:
            candidate.x = anchor_bbox.x
            candidate.y = anchor_bbox.y - cluster_bbox.h * scale
                        - FREE_SPOT_MARGIN_PX
            If non-colliding, return { x, y, scale }.

Return nil (rotation-badge EARNED fallback).

Collision is strict-inequality axis-aligned bounding-box overlap:

    overlaps(a, b)  ≡  a.x + a.w > b.x  AND  b.x + b.w > a.x
                   AND  a.y + a.h > b.y  AND  b.y + b.h > a.y

Edge-touching (e.g. candidate x = text_line right edge) is therefore
NOT a collision — the margin candidate is considered to fit when its
ink simply abuts the text body without overlapping it.

@module pencil.lib.free_spot
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local AnchorConstants = require("lib/anchor_constants")

local FreeSpot = {}

--- Mirror of AnchorConstants values for fast paint-loop access.
-- Re-required at module load time only; mirror MUST match the
-- canonical table exactly (single-file tuning surface invariant).
local FREE_SPOT_MARGIN_PX = AnchorConstants.FREE_SPOT_MARGIN_PX
local MIN_SCALE_RATIO     = AnchorConstants.MIN_SCALE_RATIO
local SCALE_STEP_RATIOS   = AnchorConstants.SCALE_STEP_RATIOS

--- Strict-inequality AABB overlap predicate.
-- Edge contact (a.x + a.w == b.x) is NOT an overlap so a margin
-- candidate may sit flush with the text body's outer edge.
-- Both rects must be `{x, y, w, h}` non-negative numbers.
local function overlaps(a, b)
    if not a or not b then return false end
    if a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0 then
        return false
    end
    return a.x + a.w > b.x
       and b.x + b.w > a.x
       and a.y + a.h > b.y
       and b.y + b.h > a.y
end

--- Collision-check a candidate rect against every text-line bbox and
-- every other-annotation bbox. Returns true on the first overlap.
local function collides(candidate, text_line_bboxes, other_annotation_bboxes)
    if text_line_bboxes then
        for _, tbox in ipairs(text_line_bboxes) do
            if overlaps(candidate, tbox) then
                return true
            end
        end
    end
    if other_annotation_bboxes then
        for _, abox in ipairs(other_annotation_bboxes) do
            if overlaps(candidate, abox) then
                return true
            end
        end
    end
    return false
end

--- Try each scale step on a given side (LEFT or RIGHT). Returns the
-- first non-colliding placement table or nil.
-- side: "LEFT" or "RIGHT"
local function try_side(side, cluster_bbox, anchor_bbox,
                       text_line_bboxes, other_annotation_bboxes,
                       screen_bounds)
    for _, scale in ipairs(SCALE_STEP_RATIOS) do
        if scale >= MIN_SCALE_RATIO then
            local scaled_w = cluster_bbox.w * scale
            local scaled_h = cluster_bbox.h * scale
            local cx
            if side == "LEFT" then
                cx = 0
            else  -- "RIGHT"
                cx = screen_bounds.w - scaled_w
            end
            local candidate = {
                x = cx,
                y = anchor_bbox.y,
                w = scaled_w,
                h = scaled_h,
            }
            if not collides(candidate, text_line_bboxes,
                            other_annotation_bboxes) then
                return { x = cx, y = anchor_bbox.y, scale = scale }
            end
        end
    end
    return nil
end

--- Try BELOW the anchor line at each SCALE_STEP_RATIO. Returns the
-- first non-colliding placement or nil. x stays at anchor_bbox.x; y
-- = anchor.y + anchor.h + padding (constant across all scales — the
-- candidate sits flush below the anchor regardless of scale).
local function try_below(cluster_bbox, anchor_bbox,
                         text_line_bboxes, other_annotation_bboxes,
                         screen_bounds)
    local cy = anchor_bbox.y + anchor_bbox.h + FREE_SPOT_MARGIN_PX
    -- Guard: anchor + padding must leave room within the viewport.
    if cy >= screen_bounds.h then
        return nil
    end
    for _, scale in ipairs(SCALE_STEP_RATIOS) do
        if scale >= MIN_SCALE_RATIO then
            local scaled_w = cluster_bbox.w * scale
            local scaled_h = cluster_bbox.h * scale
            local candidate = {
                x = anchor_bbox.x,
                y = cy,
                w = scaled_w,
                h = scaled_h,
            }
            if not collides(candidate, text_line_bboxes,
                            other_annotation_bboxes) then
                return { x = anchor_bbox.x, y = cy, scale = scale }
            end
        end
    end
    return nil
end

--- Try ABOVE the anchor line at each SCALE_STEP_RATIO. Returns the
-- first non-colliding placement or nil. y depends on scale here
-- (y = anchor.y - cluster.h * scale - padding) because the cluster is
-- anchored by its top edge — a smaller scale lifts the top edge.
local function try_above(cluster_bbox, anchor_bbox,
                         text_line_bboxes, other_annotation_bboxes,
                         screen_bounds)
    -- Guard: even the smallest readable cluster must fit between the
    -- viewport top and the anchor (minus padding).
    if FREE_SPOT_MARGIN_PX
       >= anchor_bbox.y - cluster_bbox.h * MIN_SCALE_RATIO then
        return nil
    end
    for _, scale in ipairs(SCALE_STEP_RATIOS) do
        if scale >= MIN_SCALE_RATIO then
            local scaled_w = cluster_bbox.w * scale
            local scaled_h = cluster_bbox.h * scale
            local cy = anchor_bbox.y - scaled_h - FREE_SPOT_MARGIN_PX
            if cy >= 0 then
                local candidate = {
                    x = anchor_bbox.x,
                    y = cy,
                    w = scaled_w,
                    h = scaled_h,
                }
                if not collides(candidate, text_line_bboxes,
                                other_annotation_bboxes) then
                    return { x = anchor_bbox.x, y = cy, scale = scale }
                end
            end
        end
    end
    -- Avoid an unused-local warning for screen_bounds when the guard
    -- short-circuits — screen_bounds is part of the public API contract.
    local _ = screen_bounds
    return nil
end

--- Public entry — L2 margin pass then L4 in-text fallback.
-- Returns `{x, y, scale}` on success, nil when both passes exhaust
-- (caller falls through to rotation-badge EARNED path).
function FreeSpot.find_free_spot(cluster_bbox, anchor_bbox,
                                 text_line_bboxes,
                                 other_annotation_bboxes,
                                 screen_bounds)
    if not cluster_bbox or not anchor_bbox or not screen_bounds then
        return nil
    end

    -- L2: LEFT margin first (paper-ergonomic precedent: notes flow into
    -- the leading margin in Western reading order).
    local result = try_side("LEFT", cluster_bbox, anchor_bbox,
                            text_line_bboxes, other_annotation_bboxes,
                            screen_bounds)
    if result then return result end

    -- L2: RIGHT margin fallback.
    result = try_side("RIGHT", cluster_bbox, anchor_bbox,
                      text_line_bboxes, other_annotation_bboxes,
                      screen_bounds)
    if result then return result end

    -- L4: in-text BELOW (R-precedent: reader expects margin notes to
    -- flow downward into the next white-space band).
    result = try_below(cluster_bbox, anchor_bbox,
                       text_line_bboxes, other_annotation_bboxes,
                       screen_bounds)
    if result then return result end

    -- L4: in-text ABOVE (last resort before badge fallback).
    result = try_above(cluster_bbox, anchor_bbox,
                       text_line_bboxes, other_annotation_bboxes,
                       screen_bounds)
    if result then return result end

    -- Both passes exhausted → caller engages rotation-badge EARNED.
    return nil
end

return FreeSpot
