--[[--
Pure-Lua cluster state machine for Goal-3 explicit pen-stroke anchoring.

A *cluster* is a tighter-grained grouping than a Goal-2 annotation
group. Goal-2 groups loose strokes within a 10-second window into a
single annotation_groups entry (`GROUP_TIME_THRESHOLD_S = 10`,
`GROUP_SPATIAL_THRESHOLD = 200`); Goal-3 clusters strokes within a
sub-second window (`CLUSTER_CLOSE_TIMEOUT_MS = 1200`) so the text
the user is annotating can be resolved while their hand is still on
that page. Both share the 200-px spatial-proximity AND condition.

Clusters are transient — they live only between cluster-open and
cluster-close. The cluster-close event hands a finalized cluster
record off to the heuristic (G3-M3) which derives the explicit
anchor record persisted on `group.anchor`. The cluster itself is
not persisted.

Constants (mirrored from lib/anchor_constants.lua — single source
of truth per hard-constraint #5):

    CLUSTER_CLOSE_TIMEOUT_MS = 1200  (Q1: C1 fixed timeout)
    GROUP_SPATIAL_THRESHOLD  = 200   (reused from Goal-2 grouping)

Per-point timestamps DO NOT EXIST in the input layer (KS fb895d30:
only stroke-level `datetime = os.time()` at pen-down); pen-up time
is unavailable. So cluster-close fires 1200 ms after the last
stroke's pen-DOWN, not pen-up. Known edge case: a single stroke
that takes > 1200 ms to draw may close the cluster mid-stroke. This
is accepted for MVP and documented in the G3-M8 codebase manual.

Same timeout applies to EPUB and PDF (Q9 resolution: PDF needs
cluster grouping for eraser-delete atomicity).

----------------------------------------------------------------------
Stroke shape (caller contract)
----------------------------------------------------------------------

    stroke = {
        bbox = { x0, y0, x1, y1 },  -- computed by Geometry.computeStrokeBbox
        t_ms = <number>,            -- pen-down time in milliseconds
        page = <number>,            -- page number at pen-down
    }

The lib does not iterate stroke.points; it consumes pre-computed
bboxes so the lib stays independent of the geometry module and
remains busted-clean (no require('main')).

----------------------------------------------------------------------
Cluster state shape (returned by new() and mutated by add_stroke)
----------------------------------------------------------------------

    cluster_state = {
        strokes = { stroke, stroke, ... },  -- in insertion order
        bbox    = { x0, y0, x1, y1 } | nil,  -- union; nil while empty
        t_first = <number> | nil,           -- ms of first add_stroke
        t_last  = <number> | nil,           -- ms of latest add_stroke
        page    = <number> | nil,           -- page of first add_stroke
    }

`get_bbox` and `finalize` translate the internal {x0,y0,x1,y1} shape
to the persistable {x,y,w,h} shape matching the explicit-anchor
schema (`group.anchor.cluster_bbox`).

@module pencil.lib.stroke_cluster
--]]--

local AnchorConstants = require("lib/anchor_constants")

local StrokeCluster = {}

-- Re-export for callers that want the constants visible on the module
-- (plan §2 G3-M2 names CLUSTER_CLOSE_TIMEOUT_MS at module scope).
StrokeCluster.CLUSTER_CLOSE_TIMEOUT_MS = AnchorConstants.CLUSTER_CLOSE_TIMEOUT_MS
StrokeCluster.GROUP_SPATIAL_THRESHOLD  = AnchorConstants.GROUP_SPATIAL_THRESHOLD

--- Build a fresh, empty cluster state.
-- @return cluster_state
function StrokeCluster.new()
    return {
        strokes = {},
        bbox    = nil,
        t_first = nil,
        t_last  = nil,
        page    = nil,
    }
end

-- Internal: bbox union in {x0,y0,x1,y1} shape. Returns a fresh table
-- (does not alias either input).
local function bbox_union(a, b)
    if not a then
        return { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 }
    end
    return {
        x0 = math.min(a.x0, b.x0),
        y0 = math.min(a.y0, b.y0),
        x1 = math.max(a.x1, b.x1),
        y1 = math.max(a.y1, b.y1),
    }
end

-- Internal: minimum pixel distance between two {x0,y0,x1,y1} bboxes.
-- 0 if they overlap. Mirrors Goal-2's PencilGeometry.bboxDistance so
-- the spatial-proximity AND condition behaves identically here.
local function bbox_distance(a, b)
    local dx = math.max(a.x0 - b.x1, b.x0 - a.x1, 0)
    local dy = math.max(a.y0 - b.y1, b.y0 - a.y1, 0)
    if dx == 0 and dy == 0 then
        return 0
    elseif dx == 0 then
        return dy
    elseif dy == 0 then
        return dx
    else
        return math.sqrt(dx * dx + dy * dy)
    end
end

--- Test whether a stroke is spatially close enough (and on the same
-- page) to join the cluster. Does NOT test the time window — that's
-- `should_close`'s job. Caller composes the AND: `should_join AND
-- NOT should_close`.
--
-- An empty cluster accepts any stroke (returns true).
--
-- @param cluster_state  table from StrokeCluster.new()
-- @param stroke         stroke record (see header for shape)
-- @return boolean
function StrokeCluster.should_join(cluster_state, stroke)
    if type(cluster_state) ~= "table" then return false end
    if type(stroke) ~= "table" or type(stroke.bbox) ~= "table" then
        return false
    end
    -- Empty cluster: anything joins.
    if not cluster_state.bbox then return true end
    -- Page mismatch is a hard block — clusters are per-page.
    if cluster_state.page and stroke.page
        and cluster_state.page ~= stroke.page then
        return false
    end
    local dist = bbox_distance(cluster_state.bbox, stroke.bbox)
    return dist <= AnchorConstants.GROUP_SPATIAL_THRESHOLD
end

--- Add a stroke to the cluster. Caller is responsible for the
-- accept/reject decision (via `should_join` and `should_close`);
-- this function unconditionally inserts.
--
-- Mutates and returns the same cluster_state for fluent chaining.
--
-- @param cluster_state  table from StrokeCluster.new()
-- @param stroke         stroke record
-- @return cluster_state
function StrokeCluster.add_stroke(cluster_state, stroke)
    if type(stroke) ~= "table" or type(stroke.bbox) ~= "table" then
        return cluster_state
    end
    table.insert(cluster_state.strokes, stroke)
    cluster_state.bbox = bbox_union(cluster_state.bbox, stroke.bbox)
    if not cluster_state.t_first then
        cluster_state.t_first = stroke.t_ms
    end
    cluster_state.t_last = stroke.t_ms
    if not cluster_state.page and stroke.page then
        cluster_state.page = stroke.page
    end
    return cluster_state
end

--- Return true when no new stroke has arrived within
-- `CLUSTER_CLOSE_TIMEOUT_MS` of the latest stroke. The comparison
-- is strict (`>`, not `>=`) so a stroke arriving exactly at the
-- boundary still joins (CL-1, CL-2 specs).
--
-- An empty cluster is never "closed" — it has nothing to close.
--
-- @param cluster_state  table
-- @param now_ms         current time in milliseconds
-- @return boolean
function StrokeCluster.should_close(cluster_state, now_ms)
    if type(cluster_state) ~= "table" then return false end
    if not cluster_state.t_last then return false end
    if type(now_ms) ~= "number" then return false end
    return (now_ms - cluster_state.t_last) > AnchorConstants.CLUSTER_CLOSE_TIMEOUT_MS
end

--- Return the cluster bounding box in the persistable {x, y, w, h}
-- shape. Returns nil for an empty cluster.
--
-- @param cluster_state  table
-- @return table | nil  { x, y, w, h }
function StrokeCluster.get_bbox(cluster_state)
    if type(cluster_state) ~= "table" or not cluster_state.bbox then
        return nil
    end
    local b = cluster_state.bbox
    return {
        x = b.x0,
        y = b.y0,
        w = b.x1 - b.x0,
        h = b.y1 - b.y0,
    }
end

--- Finalize the cluster into an immutable record matching the
-- arch-planner `compute_cluster_anchor(cluster, doc, heuristic)`
-- input contract (plan §2 lib/ function signatures).
--
-- After finalize the caller should discard `cluster_state` and
-- start a fresh one for the next cluster.
--
-- @param cluster_state  table
-- @return table  { strokes, bbox_screen, t_first, t_last, page }
function StrokeCluster.finalize(cluster_state)
    return {
        strokes     = cluster_state.strokes,
        bbox_screen = StrokeCluster.get_bbox(cluster_state),
        t_first     = cluster_state.t_first,
        t_last      = cluster_state.t_last,
        page        = cluster_state.page,
    }
end

return StrokeCluster
