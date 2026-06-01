--[[--
H4 ambiguity-scorer + S2 ranked top-3 heuristic for Goal-3 explicit
pen-stroke anchoring.

Each candidate text line is scored by

        score_j = overlap(cluster_bbox, line_bbox_j)
                × crossing_count(stroke_segments, line_baseline_j)

where:

    overlap         = intersection-area / cluster_bbox-area
                      (normalised to the cluster, so the result sits
                      in [0, 1] independent of line length).

    crossing_count  = integer number of stroke segment midpoints
                      whose y-coordinate falls inside the band
                      [line_baseline − 0.5·line_height,
                       line_baseline + 0.5·line_height].

The product rewards lines that the cluster both spatially overlaps
AND actually crosses with ink. A purely tangential line — bbox
overlap but zero ink crossings — scores zero. A line below an arrow
shaft — many crossings but zero bbox overlap — also scores zero.
Only when both factors are positive does the line earn a score.

Plan §1.2 / §2 G3-M3. AMBIGUITY_GAP_THRESHOLD = 0.20 sourced from
lib/anchor_constants.lua per hard-constraint #5 — no inline literal.

----------------------------------------------------------------------
Public API
----------------------------------------------------------------------

    score_line(cluster_bbox, stroke_segments, line_bbox, line_baseline)
        → float                 H4 score for a single candidate line

    rank(cluster, line_box_list)
        → [{line_bbox, xp, score}, ...]   top-3 sorted desc by score

    is_confident(ranked, threshold)
        → bool                  true iff (top1.score - top2.score)
                                strictly > threshold

    fetch_line_boxes(doc, page) → list of {x,y,w,h} | nil
        pcall-wrapped engine helper. doc must expose
        :getPageXPointer(page) → string and
        :getScreenBoxesFromPositions(xp0, xp1, do_join) → list,
        both per credocument.lua (KS a43eb8db). Any throw, nil
        return, or non-table shape collapses to nil — the caller
        (G3-M4 paint) treats nil as "no candidate lines available"
        → manual-anchor prompt or rotation-badge fallback.

----------------------------------------------------------------------
Shapes
----------------------------------------------------------------------

    cluster_bbox     { x, y, w, h }   plan §1.7 persistable shape
    line_bbox        { x, y, w, h }   credocument Geom shape (KS a43eb8db)
    stroke_segments  [{x, y}, ...]    pre-extracted midpoints between
                                       consecutive stroke points
    line_box_list    [{bbox, xp,      caller-supplied; xp resolution
                       baseline},      lives in stroke_capture for
                      ...]             G3-M3+M4 — out of scope here

    cluster          { strokes        cluster record from
                       = [...],        StrokeCluster.finalize() —
                       bbox_screen     .strokes is the list of stroke
                       = {x,y,w,h},    records with .points to derive
                       ... }           midpoints from
    ranked entry     { line_bbox,     element of rank() output and
                       xp,             is_confident() input
                       score }

@module pencil.lib.cluster_heuristic
--]]--

local AnchorConstants = require("lib/anchor_constants")

local ClusterHeuristic = {}

-- Re-export so callers (lib/stroke_capture, lib/manual_anchor) can read
-- the threshold from this module without re-requiring anchor_constants.
ClusterHeuristic.AMBIGUITY_GAP_THRESHOLD = AnchorConstants.AMBIGUITY_GAP_THRESHOLD

-- Internal: intersection-area / cluster-area. Returns 0 for any
-- degenerate input (nil, zero area, no overlap). Both inputs are
-- expected in the {x, y, w, h} shape.
local function overlap_fraction(cluster_bbox, line_bbox)
    if type(cluster_bbox) ~= "table" or type(line_bbox) ~= "table" then
        return 0
    end
    local cw = cluster_bbox.w or 0
    local ch = cluster_bbox.h or 0
    local cluster_area = cw * ch
    if cluster_area <= 0 then return 0 end
    local cx0 = cluster_bbox.x
    local cy0 = cluster_bbox.y
    local cx1 = cx0 + cw
    local cy1 = cy0 + ch
    local lx0 = line_bbox.x
    local ly0 = line_bbox.y
    local lx1 = lx0 + (line_bbox.w or 0)
    local ly1 = ly0 + (line_bbox.h or 0)
    local ix_left   = math.max(cx0, lx0)
    local iy_top    = math.max(cy0, ly0)
    local ix_right  = math.min(cx1, lx1)
    local iy_bottom = math.min(cy1, ly1)
    local iw = ix_right - ix_left
    local ih = iy_bottom - iy_top
    if iw <= 0 or ih <= 0 then return 0 end
    return (iw * ih) / cluster_area
end

-- Internal: integer count of midpoints whose y falls inside the
-- baseline ± (0.5 · line_height) band.
local function crossing_count(stroke_segments, line_bbox, line_baseline)
    if type(stroke_segments) ~= "table"
        or type(line_bbox) ~= "table"
        or type(line_baseline) ~= "number"
    then
        return 0
    end
    local half_lh = (line_bbox.h or 0) * 0.5
    if half_lh <= 0 then return 0 end
    local lo = line_baseline - half_lh
    local hi = line_baseline + half_lh
    local count = 0
    for i = 1, #stroke_segments do
        local mid = stroke_segments[i]
        if type(mid) == "table" and type(mid.y) == "number"
            and mid.y >= lo and mid.y <= hi
        then
            count = count + 1
        end
    end
    return count
end

--- H4 score for one candidate line. The product is zero whenever
-- either factor is zero (tangential lines score zero regardless of
-- bbox overlap; lines outside the cluster bbox score zero regardless
-- of crossings).
--
-- @param cluster_bbox    { x, y, w, h }
-- @param stroke_segments list of midpoints [{x, y}, ...]
-- @param line_bbox       { x, y, w, h } from credocument
-- @param line_baseline   y-coordinate of the line's baseline
-- @return number
function ClusterHeuristic.score_line(cluster_bbox, stroke_segments,
                                      line_bbox, line_baseline)
    local ov = overlap_fraction(cluster_bbox, line_bbox)
    if ov == 0 then return 0 end
    local crossings = crossing_count(stroke_segments, line_bbox, line_baseline)
    if crossings == 0 then return 0 end
    return ov * crossings
end

-- Internal: walk every stroke's .points and emit the segment-midpoint
-- list the H4 scorer consumes. Each consecutive pair (points[i],
-- points[i+1]) contributes one midpoint. A stroke with fewer than 2
-- points contributes nothing.
local function midpoints_from_cluster(cluster)
    local mids = {}
    if type(cluster) ~= "table" then return mids end
    local strokes = cluster.strokes
    if type(strokes) ~= "table" then return mids end
    for _, stroke in ipairs(strokes) do
        local pts = stroke and stroke.points
        if type(pts) == "table" and #pts >= 2 then
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                if type(a) == "table" and type(b) == "table"
                    and type(a.x) == "number" and type(a.y) == "number"
                    and type(b.x) == "number" and type(b.y) == "number"
                then
                    table.insert(mids, {
                        x = (a.x + b.x) * 0.5,
                        y = (a.y + b.y) * 0.5,
                    })
                end
            end
        end
    end
    return mids
end

--- S2 ranked top-3 output. Each entry of `line_box_list` is
-- `{bbox = {x,y,w,h}, xp = <string>, baseline = <number>}` (caller
-- supplies xp + baseline — typically the row's y-midpoint for
-- baseline when CRengine doesn't expose it explicitly).
--
-- Returns an array of at most three records sorted descending by
-- score. Zero-score lines are NOT filtered out — they still appear
-- in the sorted output so the caller's `is_confident` can compare
-- meaningfully against a true second-best (which may itself be
-- zero on a sparse page).
--
-- @param cluster        finalize() output (.strokes + .bbox_screen)
-- @param line_box_list  list of {bbox, xp, baseline}
-- @return list  [{line_bbox, xp, score}, ...]  (length 0..3)
function ClusterHeuristic.rank(cluster, line_box_list)
    if type(line_box_list) ~= "table" or #line_box_list == 0 then
        return {}
    end
    local cluster_bbox = cluster and cluster.bbox_screen
    local mids = midpoints_from_cluster(cluster)
    local scored = {}
    for i = 1, #line_box_list do
        local entry = line_box_list[i]
        if type(entry) == "table" and type(entry.bbox) == "table" then
            local s = ClusterHeuristic.score_line(
                cluster_bbox, mids, entry.bbox, entry.baseline)
            table.insert(scored, {
                line_bbox = entry.bbox,
                xp        = entry.xp,
                score     = s,
            })
        end
    end
    table.sort(scored, function(a, b) return (a.score or 0) > (b.score or 0) end)
    local top3 = {}
    for i = 1, math.min(3, #scored) do
        top3[i] = scored[i]
    end
    return top3
end

--- Confidence gate. Confident iff `top1.score - top2.score >
-- threshold`. Empty ranked list ⇒ not confident. Single-entry
-- ranked list ⇒ top1.score is compared against an implicit second of
-- zero — confident iff top1.score > threshold. The caller (G3-M4)
-- uses this to fork between auto-anchor (confident) and the
-- manual-anchor exclamation prompt (ambiguous).
--
-- @param ranked    output of rank()
-- @param threshold AMBIGUITY_GAP_THRESHOLD by default
-- @return boolean
function ClusterHeuristic.is_confident(ranked, threshold)
    threshold = threshold or AnchorConstants.AMBIGUITY_GAP_THRESHOLD
    if type(ranked) ~= "table" or #ranked == 0 then return false end
    local top1 = ranked[1] and ranked[1].score or 0
    local top2 = ranked[2] and ranked[2].score or 0
    return (top1 - top2) > threshold
end

--- Engine-touching helper: query CRengine for the screen bboxes of
-- every text line on `page`. All three CRengine entries are
-- pcall-wrapped (build-compat) so a throw from any of them — or a
-- non-table result — collapses to nil. The caller treats nil as
-- "no candidate lines available" → rotation-badge fallback or
-- manual-anchor prompt depending on the cluster's other state.
--
-- @param doc   CreDocument (mockable; see spec G3-AH-6)
-- @param page  1-based page number
-- @return list of {x, y, w, h} | nil
function ClusterHeuristic.fetch_line_boxes(doc, page)
    if type(doc) ~= "table" then return nil end
    -- build-compat: doc:getPageXPointer
    local ok1, xp_start = pcall(function() return doc:getPageXPointer(page) end)
    if not ok1 or type(xp_start) ~= "string" then return nil end
    -- build-compat: doc:getPageXPointer
    local ok2, xp_end = pcall(function() return doc:getPageXPointer(page + 1) end)
    if not ok2 or type(xp_end) ~= "string" then return nil end
    -- build-compat: doc:getScreenBoxesFromPositions
    local ok3, boxes = pcall(function()
        return doc:getScreenBoxesFromPositions(xp_start, xp_end, true)
    end)
    if not ok3 or type(boxes) ~= "table" then return nil end
    return boxes
end

return ClusterHeuristic
