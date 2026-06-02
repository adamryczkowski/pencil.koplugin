--[[--
L2 margin-preference auto-layout pass for Goal-3 explicit pen-stroke
annotation clusters. Tries to place the cluster bbox inside the page's
LEFT or RIGHT margin strip at progressively smaller scale steps; falls
back to nil (→ rotation-badge EARNED) when no candidate fits.

L4 (in-text BELOW/ABOVE port from ReaderHighlight:_getDialogAnchor) is
deferred to G3-M5b. M5a deliberately scope-limits to L2 only — when
the margin pass fails, find_free_spot returns nil and the existing
rotation-badge fallback engages. The G3-M5b commit will append the L4
arm before the `return nil` line below; nothing in the M5a public
surface changes (single in-out function).

Plan §1.5 / §2 G3-M5a. All constants (FREE_SPOT_MARGIN_PX = 24,
SCALE_STEP_RATIOS = {1.0, 0.9, 0.75, 0.6, 0.5}, MIN_SCALE_RATIO = 0.5,
FREE_SPOT_HISTORY_CAP = 1) live in lib/anchor_constants.lua per
hard-constraint #5 — no inline numeric literal at L2 sites.

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
Algorithm (L2 margin-preference pass)
----------------------------------------------------------------------

For each side in {LEFT, RIGHT}:
    For each scale in SCALE_STEP_RATIOS (descending):
        Skip if scale < MIN_SCALE_RATIO (readability floor, DoD §B).
        scaled_w = cluster_bbox.w * scale
        scaled_h = cluster_bbox.h * scale
        candidate.x = 0                        (LEFT)
                    | screen_bounds.w - scaled_w (RIGHT)
        candidate.y = anchor_bbox.y            (y near the anchor line)
        If candidate does not collide with any text_line_bbox AND any
        other_annotation_bbox, return { x, y, scale }.
Return nil.

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

--- Public entry — L2 margin-preference search.
-- Returns `{x, y, scale}` on success, nil when no margin candidate
-- fits (M5b will replace the `return nil` with an L4 in-text fallback
-- pass; until then, nil propagates to the rotation-badge EARNED path).
function FreeSpot.find_free_spot(cluster_bbox, anchor_bbox,
                                 text_line_bboxes,
                                 other_annotation_bboxes,
                                 screen_bounds)
    if not cluster_bbox or not anchor_bbox or not screen_bounds then
        return nil
    end

    -- LEFT margin first (paper-ergonomic precedent: notes flow into
    -- the leading margin in Western reading order).
    local result = try_side("LEFT", cluster_bbox, anchor_bbox,
                            text_line_bboxes, other_annotation_bboxes,
                            screen_bounds)
    if result then return result end

    -- RIGHT margin fallback.
    result = try_side("RIGHT", cluster_bbox, anchor_bbox,
                      text_line_bboxes, other_annotation_bboxes,
                      screen_bounds)
    if result then return result end

    -- L4 (in-text BELOW/ABOVE) deferred to G3-M5b.
    return nil
end

--- Suppress unused-variable warnings while L4 wiring is deferred to
-- M5b. FREE_SPOT_MARGIN_PX is documented for tuners and will be the
-- collision-padding constant for the L4 pass; reading it here keeps
-- the named-constant import visible to lib audits.
local _ = FREE_SPOT_MARGIN_PX

return FreeSpot
