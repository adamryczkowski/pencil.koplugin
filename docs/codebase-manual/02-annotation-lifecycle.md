# §2 Annotation lifecycle

This section traces a single annotation from physical stylus contact
through save, reload, and paint. The EPUB and PDF paths are shown
side-by-side. Each labelled step cites the source location that owns
it; reflow / page-turn cache invalidation lives in [§5](05-reflow.md).

## Step 0: tool selection

The reader-side `Dispatcher` actions `pencil_select_pen` and
`pencil_select_eraser` (registered in `Pencil:init` at
`main.lua:305-335`) dispatch the `PencilSelectPen` and
`PencilSelectEraser` events. The actual flip of
`self.current_tool` happens in the event handlers
`Pencil:onPencilSelectPen` (`main.lua:383`) and
`Pencil:onPencilSelectEraser` (`main.lua:392`), which set the
tool to `TOOL_PEN = "pen"` or `TOOL_ERASER = "eraser"`
respectively. The physical stylus eraser end (`BTN_TOOL_RUBBER` /
`slot.tool == TOOL_TYPE_ERASER`) overrides this at the input
layer — see `handleStylusSlot` at `main.lua:442`.

## Step 1: pen-down

KOReader's input thread delivers a stylus event. `handleStylusSlot`
at `main.lua:442` is the receiver. For a pen-down (`slot.x` and
`slot.y` set, `slot.tool == TOOL_TYPE_STYLUS = 1`, no eraser flag),
it calls:

- `startRawStroke()` at `main.lua:730` — opens a new
  `current_stroke = { points = {}, page = currentpage, tool, color,
  width, datetime = os.time() }` record. `datetime` is a Unix
  timestamp in seconds (per-stroke, not per-point — KOReader's
  input layer does not expose per-sample timestamps).
- `addRawPoint(x, y)` at `main.lua:755` — appends the first point.

For an eraser-active contact (`self.eraser_button_active == true`),
the same handler calls `eraseAtPoint(x, y, page)` at `main.lua:4286`
for each move sample. The eraser TAP-vs-DRAG distinction is computed
*after* the gesture completes — see step 5b below.

## Step 2: pen-move

Each subsequent slot event (still inside the same contact) calls
`addRawPoint(x, y)` to append a `{x, y}` to `current_stroke.points`.
Coalescing and smoothing live inside `addRawPoint`; the saved point
list is the smoothed one. Goal-1 / Goal-2 / Goal-3 share this step.

## Step 3: pen-up

When the stylus lifts (slot's `id` resets or `eraser_active` flips),
`endRawStroke()` at `main.lua:851` runs. It:

1. Computes the stroke's screen-pixel bbox.
2. Calls `assignStrokeToGroup(stroke_idx)` at `main.lua:3281` — this
   is the Goal-2 grouping step: stroke gets matched to an existing
   `annotation_groups[i]` whose temporal proximity
   (`GROUP_TIME_THRESHOLD_S`) AND spatial proximity
   (`GROUP_SPATIAL_THRESHOLD = 200 px`) both pass; otherwise a new
   group is appended.
3. **Goal-3 only** — calls `_routeStrokeToCluster(stroke_idx)` at
   `main.lua:919`, which feeds the stroke into a parallel
   `StrokeCluster` record (see [`lib/stroke_cluster.lua`](
   ../../pencil.koplugin/lib/stroke_cluster.lua)). The cluster
   record is separate from the Goal-2 group: it has a shorter
   1200 ms timeout (`CLUSTER_CLOSE_TIMEOUT_MS`) and is what triggers
   the explicit-anchor capture in step 4.
4. Calls `_resetClusterCloseTimer()` at `main.lua:948` — schedules
   `_onClusterCloseTimeout` (`main.lua:970`) 1200 ms after the most
   recent pen-DOWN. Each new stroke restarts the timer.
5. Persists state via the debounced `scheduleDeferredWork()` (so a
   tight pen-strike sequence does not thrash the sidecar file).

The Goal-1 / Goal-2 paths stop here and let the timer-debounced save
take effect. Goal-3 continues at step 4.

## Step 4 (Goal-3, EPUB): cluster close → explicit anchor

After 1200 ms with no new pen-DOWN, `_onClusterCloseTimeout` at
`main.lua:970` fires. The handler:

1. Asks the cluster's `StrokeCluster.finalize` for a closed cluster
   record (bbox plus the list of stroke indices that belong to it).
2. If the document is EPUB: runs the ambiguity heuristic. Source-line
   bboxes come from `ClusterHeuristic.fetch_line_boxes` (in
   `lib/cluster_heuristic.lua`), which `pcall`-wraps the credocument
   calls `doc:getPageXPointer(page)` and
   `doc:getScreenBoxesFromPositions(p0, p1, true)`. The H4 score for
   each candidate line is `overlap(cluster_bbox, line_bbox) ×
   crossing_count(stroke_segments, line_baseline)` (see [§6](
   06-explicit-anchoring.md)). Top-3 ranked output goes through the
   confidence gate `top1.score - top2.score > AMBIGUITY_GAP_THRESHOLD
   = 0.20`.
3. If confident: writes
   `group.anchor = { type = "explicit", xp = top1.xp,
   cluster_bbox = {…}, scale = 1.0, clarified = true,
   connector_geom = {…}, free_spot_history = {…} }` directly onto
   the corresponding annotation group.
4. If ambiguous: writes the same record with `clarified = false`
   and instantiates a `ManualAnchor` state machine
   (`lib/manual_anchor.lua`). The next paint draws the exclamation
   glyph at the cluster bbox's top-right corner. The user then
   either taps near the intended text line (clarification tap) or
   eraser-taps the exclamation (orphan escape hatch — `xp = nil,
   clarified = true`).

## Step 4 (Goal-3, PDF): cluster close → page anchor

For PDF documents, the same timer fires. Instead of running the
heuristic:

- `PdfAnchor.compute(reader, stroke_bbox)` in `lib/pdf_anchor.lua`
  is called. It `pcall`-wraps `reader:getCurrentPage()` (the
  reader/view layer owns current-page state — `PdfDocument:
  getCurrentPage` does not exist in `frontend/document/
  pdfdocument.lua`; the FKS scan against the upstream source
  confirmed this). The returned anchor is
  `{ type = "pdf_page", page = N, bbox = stroke_bbox }`.
- No heuristic, no free-spot layout, no connector. PDF pages do not
  reflow, so the captured pixel coordinates remain valid.

If `reader:getCurrentPage` is missing or `pcall` fails, `compute`
returns nil and the stroke falls through to the legacy nil-anchor
→ rotation-badge EARNED path (Goal-2 back-compat).

## Step 5a: paint (next redraw)

Whenever KOReader repaints the page, `Pencil:paintTo(bb, x, y)` at
`main.lua:4421` runs. At SHA `72d6920` (G3-M8.5) the paint loop
iterates `self.annotation_groups` and dispatches on
`group.anchor.type` in a 4-branch tree:

- `nil` anchor — never enters the anchor-owned loop (gated by
  `if group.anchor`); falls through to the renderStroke fallback
  below the loop. Routes to the rotation-badge EARNED path
  (`_rotationBadgeRender` at `main.lua:5024`) when the group's
  saved rotation does not match the current rotation (the
  stale-rotation filter inside `paintTo`, approximately
  `main.lua:4446-4491`); otherwise draws strokes at saved
  coordinates.
- `"line"` anchor — Goal-2 entry point `StrokePaint.paint_with_anchor(
  group, self.ui.document, em_px, lh_px, draw_translated_fn,
  rotation_badge_fn)` (BYTE-IDENTICAL earned path; the new
  dispatch's `else` clause preserves this call verbatim).
  Resolves the line-anchor through `_getAnchorMetrics(xp)`
  (`main.lua:4949`), computes `(tx, ty)` from `(dx_em, dy_lh)`
  and the current line metrics, then calls
  `_drawStrokeTranslated(group, tx, ty, scale)`
  (`main.lua:4976`).
- `"explicit"` anchor — Goal-3 dispatch via
  `StrokePaint.paint_anchor_group(group, doc, em_px, lh_px,
  screen_w, screen_h, screen_rot, draw_translated_fn,
  rotation_badge_fn, nil, nil)` (the last two callback slots are
  reserved for a future caller-side highlight / connector
  override; the M8.5 executor consumes the returned op list
  directly). Returns the ordered render-op list
  (`highlight_underline < connector < stroke < exclamation <
  badge`); the caller executes each op against the `bb`
  Blitbuffer via the 5-branch executor (`op.type == "stroke"` →
  `_drawStrokeTranslated`, `"badge"` → `_rotationBadgeRender`,
  `"highlight_underline"` → `_drawAnchorUnderline`, `"connector"`
  → `_drawConnector`, `"exclamation"` →
  `_drawAnchorExclamation`). See [§6](06-explicit-anchoring.md).
- `"pdf_page"` anchor — Goal-3 dispatch, additionally gated by
  `PdfAnchor.should_render(group, current_page)`. When the gate
  passes, `paint_anchor_group` emits a single stroke op (no
  connector, no underline, no exclamation, no badge — the page
  IS the anchor). See [§7.3](07-pdf.md#73-the-render-path).

The render-op model means `paint_anchor_group` itself is a pure
function (busted-testable; no Blitbuffer / UIManager dependency)
and the actual draw calls happen at the caller. Both Goal-2
(`paint_with_anchor` for `nil` / `"line"`) and Goal-3
(`paint_anchor_group` for `"explicit"` / `"pdf_page"`) entry
points are live and integration-spec-covered
(`spec/g3_wiring_spec.lua` G3-M8.5-WR-1..WR-6).

## Step 5b: eraser-tap atomic delete (Goal-3)

Per KSQ-4: KOReader's `input.lua` does NOT distinguish a brief
eraser TAP from an erase DRAG — all `BTN_TOOL_RUBBER` events are
routed identically. The plugin computes the distinction.

`lib/eraser_tap.lua` provides `classify(motion_distance_px)`
(returns `"tap"` when motion is ≤ `ERASE_TAP_MAX_DISTANCE_PX = 10`
px, `"drag"` otherwise). The coordinator `handle_tap(x, y, motion,
state, save_fn)` looks up the group whose `cluster_bbox` contains
(x, y) and removes it atomically via `table.remove` — the entire
cluster (group + anchor highlight + connector — three artefacts
derived from a single group record) disappears in one call.

If motion exceeds the threshold, the gesture is a DRAG, which is
the pre-Goal-3 `eraseAtPoint` per-stroke path at `main.lua:4286`.
The two paths are mutually exclusive at the gesture-classification
boundary.

Wiring of `lib/eraser_tap.lua` into `main.lua`'s
`BTN_TOOL_RUBBER` handler is the minimal main.lua delta still
pending — the lib module is fully busted-tested
(`spec/eraser_tap_spec.lua` ER-1..ER-4), but the call site inside
`handleStylusSlot` (`main.lua:442`) currently routes all rubber-
tip events through the existing `eraseAtPoint` per-stroke path.
The tap branch awaits a follow-up integration commit (separate
from G3-M8.5, which wired only the paint-side dispatch).

## Step 6: save

After any of {stroke append, eraser delete, manual-anchor tap, page
turn}, `scheduleDeferredWork()` debounces a call to `saveStrokes()`
at `main.lua:4765`. The serialized payload is:

```
{ version = 3, strokes = {…}, annotation_groups = {…} }
```

written as `return ` + `require("dump")(data)` to the per-document
sidecar file. The same shape is exercised under busted by
`lib/annotation_persistence.lua` (which implements `dump`-compatible
serialization in pure Lua so specs can round-trip without booting
KOReader).

`onCloseDocument` at `main.lua:4816` calls `saveStrokes` one final
unconditional time so anything outstanding hits disk.

## Step 7: reload

On open, `loadStrokes` at `main.lua:4663` reads the sidecar file
back. Old-version files (no `annotation_groups` key) are normalized
to the current shape. Each stroke flows through `strokeFromSaved`
(`main.lua:4737`) which restores Blitbuffer colors from their
serialized name. After the load, `rebuildAnnotationGroups`
(`main.lua:3386`) and `rebuildPageIndex` (`main.lua:4048`) populate
the in-memory indices.

The four-value `anchor.type` dispatcher is back-compat-safe at this
step: a `nil` anchor on a loaded group routes to the rotation-badge
path; a `"line"` anchor routes to Goal-2; `"explicit"` and
`"pdf_page"` are the new Goal-3 branches.
