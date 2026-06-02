# §6 Explicit anchoring (EPUB)

This section is the Goal-3 EPUB workflow: how a multi-stroke pen
cluster becomes an `anchor.type == "explicit"` annotation group
that survives reflow, can be ambiguity-prompted, can be
free-spot-laid-out, and can be eraser-tap-deleted atomically.

PDF documents take a different path — see [§7](07-pdf.md).

## 6.1 Cluster detection (G3-1)

Two strokes belong to the same cluster when BOTH:

1. The most recent pen-DOWN of the existing cluster is within
   `CLUSTER_CLOSE_TIMEOUT_MS = 1200 ms` of the new pen-DOWN.
2. The spatial distance between cluster bbox and new stroke bbox is
   under `GROUP_SPATIAL_THRESHOLD = 200 px` (reused from Goal-2).

Both constants live in `lib/anchor_constants.lua`.

The implementation is in `lib/stroke_cluster.lua` (the
`StrokeCluster.add_stroke` and `should_join` predicates) and the
wiring is in `main.lua`:

- `Pencil:_routeStrokeToCluster(stroke_idx)` at `main.lua:919` —
  called from `endRawStroke` (`main.lua:851`); feeds the new
  stroke into the active cluster or starts a fresh one.
- `Pencil:_resetClusterCloseTimer()` at `main.lua:948` — installs
  a 1200 ms `UIManager:schedule` for cluster-close. Each new
  pen-DOWN cancels the prior schedule and reinstalls.
- `Pencil:_onClusterCloseTimeout()` at `main.lua:970` — the
  cluster-close handler; runs the H4+S2 heuristic for EPUB,
  PdfAnchor.compute for PDF.

### 6.1.a Known edge case (cluster-close mid-stroke)

If a single stroke takes longer than 1200 ms to draw (very long
shaft on a stylus), the cluster-close timer may fire before
pen-up. The current cluster is then closed at the last pen-DOWN
timestamp; the in-flight stroke joins a new cluster on its own
pen-DOWN sample. This is accepted for the MVP and is the
canonical reason why per-point timestamps would help — the input
layer does not currently expose them (KS fb895d30).

## 6.2 Ambiguity heuristic (G3-2)

Owner: `lib/cluster_heuristic.lua`.

For each visible text line on the cluster's page, the H4 score is:

```
score_j = overlap(cluster_bbox, line_bbox_j)
        × crossing_count(stroke_segments, line_baseline_j)
```

where:

- `overlap()` is intersection area normalized to `cluster_bbox`
  area — a value in `[0, 1]` independent of line length.
- `crossing_count` is the integer number of stroke segment
  midpoints whose y-coordinate falls inside
  `[baseline − 0.5 × line_height, baseline + 0.5 × line_height]`.

The product is zero when either factor is zero, so:

- A line tangent to the cluster bbox but never crossed by ink
  scores zero.
- A line crossed by ink but outside the cluster bbox scores zero.

Visible lines come from `fetch_line_boxes(doc, page)`, which
`pcall`-wraps `doc:getPageXPointer(page)`,
`doc:getPageXPointer(page+1)`, and
`doc:getScreenBoxesFromPositions(p0, p1, true)` under one
`build-compat: getScreenBoxesFromPositions` marker.

The scorer feeds into `ClusterHeuristic.rank(cluster,
line_box_list)`, which returns the top-3 candidates sorted
descending by score. Then `ClusterHeuristic.is_confident(ranked,
threshold)` applies the confidence gate:

```
top1.score − top2.score > AMBIGUITY_GAP_THRESHOLD (= 0.20)
```

A missing `top2` is treated as score 0, so a single-candidate
cluster is confident iff `top1.score > 0`.

The gap threshold 0.20 was chosen against three fixture clusters
the panel measured: clean-strike gap ≈ 0.65, margin-note gap
≈ 0.10, two-line gap ≈ 0.05. 0.20 sits cleanly between the
"confident" and "ambiguous" cases.

## 6.3 Anchor-highlight + connector (G3-3)

When `is_confident` returns true, the cluster's group gets:

```lua
group.anchor = {
  type         = "explicit",
  xp           = top1.xp,         -- line-start xpointer of the
                                  -- top-ranked line
  cluster_bbox = {x, y, w, h},    -- captured bbox in screen px
  scale        = 1.0,             -- before free-spot layout runs
  clarified    = true,
}
```

The render-time draw uses `StrokePaint.paint_anchor_group` (in
`lib/stroke_paint.lua`) to emit, in order:

1. `highlight_underline` op — a 2-px-high indigo (`#4B0082`, alpha
   153) underline on the anchor line, drawn first so ink sits on
   top.
2. `connector` op — a 2-px solid indigo line from the anchor
   underline midpoint to the nearest edge of the cluster bbox.
   Hit-target for eraser-tap is 16 px (`CONNECTOR_HIT_TARGET_PX`),
   wider than the visual width so tremor-tolerant.
3. `stroke` op — the cluster strokes at their saved pixel
   coordinates, translated by any free-spot offset and scaled by
   `group.anchor.scale`.

All four constants (`ANCHOR_UNDERLINE_HEIGHT_PX = 2`,
`ANCHOR_UNDERLINE_ALPHA = 153`, `CONNECTOR_LINE_WIDTH_PX = 2`,
`CONNECTOR_ALPHA = 153`) live in `lib/anchor_constants.lua` per
hard-constraint #5 (no inline literals at paint sites; Goal-2
lesson #2 — paint-time pixel literals are tech debt).

Hue choice: indigo `#4B0082` sits between Blue and Purple in hue
space; `red=75` distinguishes it from Blue (`red=0`); unequal RGB
keeps it out of the grayscale range (lighten mode uses
`Blitbuffer.gray`). The 9-name Goal-1 palette is unaffected. A
teal `#008080` fallback is provisioned (`FALLBACK_HUE`) for the
case where indigo collapses onto Blue/Purple under Kaleido 3
rendering; SSH validation at DoD #10 confirms the choice.

## 6.4 Manual-anchor mode (G3-4)

When `is_confident` returns false, the cluster gets `clarified =
false`. The render-op list now ALSO includes:

4. `exclamation` op — a static indigo `!` glyph at the cluster
   bbox's top-right corner. Single pulse animation
   (`EXCLAMATION_PULSE_DURATION_MS = 300 ms`) on first paint;
   then stays as a non-modal marker.

Owner: `lib/manual_anchor.lua`. The state machine is per-cluster
(no globals). Public surface:

- `ManualAnchor.new(cluster)` — fresh state.
- `on_clarification_tap(state, tap_x, tap_y, line_metrics)` —
  user tapped near the annotation. Proximity-gated (the second
  tap is treated as "clarification" only when within
  `CLARIFICATION_RADIUS_LH = 5` line-heights of the cluster bbox;
  outside that radius is a fresh stroke). The proximity rule is
  deliberately NOT the heuristic — the user's explicit tap IS
  the answer; H4 is the automatic-capture path only. Debounced
  via `CLARIFY_DEBOUNCE_MS = 300 ms` to prevent double-tap
  mis-routing.
- `on_eraser_tap_connector(state)` — re-anchor gesture: flips
  `clarified = false`, exclamation reappears.
- `on_eraser_tap_exclamation(state)` — orphan escape hatch
  (MA-6): sets `xp = nil` and `clarified = true`. Cluster
  persists without an anchor; renders as a badge at the cluster
  bbox top-left.

The user can keep drawing elsewhere while the exclamation glyph
is active — the manual-anchor mode is non-modal.

## 6.5 Free-spot auto-layout (G3-5)

When the cluster bbox is wider than the text body's margin OR
overlaps text content that the reader would be reading at the
same time, the strokes can be displaced (and rescaled) into a
"free spot" by `lib/free_spot.lua:find_free_spot`. Two passes:

### 6.5.a L2 margin-preference pass (G3-M5a)

For each side in `{LEFT, RIGHT}`, for each scale in
`SCALE_STEP_RATIOS = {1.0, 0.9, 0.75, 0.6, 0.5}` (descending):

- Skip if scale < `MIN_SCALE_RATIO = 0.5` (readability floor).
- `scaled_w = cluster.w × scale`, `scaled_h = cluster.h × scale`.
- Candidate `x = 0` (LEFT) or `screen_w − scaled_w` (RIGHT);
  candidate `y = anchor_bbox.y`.
- Strict-inequality AABB overlap-check against `text_line_bboxes`
  and `other_annotation_bboxes`. Edge-touching is NOT a collision
  (the precondition that lets a right-margin candidate sit flush
  against the text body's right edge).
- First non-colliding candidate → return `{x, y, scale}`.

### 6.5.b L4 in-text BELOW/ABOVE pass (G3-M5b)

When L2 returns nil:

- L4-BELOW guard: `anchor.y + anchor.h + FREE_SPOT_MARGIN_PX <
  screen.h`. Then for each scale, candidate `y = anchor.y +
  anchor.h + padding` (constant across scales; anchored by
  cluster top edge). First non-colliding → return.
- L4-ABOVE guard: `padding < anchor.y − cluster.h ×
  MIN_SCALE_RATIO`. Then for each scale, candidate `y = anchor.y
  − cluster.h × scale − padding` (varies with scale; cluster top
  edge lifts as height shrinks). First non-colliding → return.

The L4 BELOW / ABOVE arithmetic is ported from KOReader's
`ReaderHighlight:_getDialogAnchor` (in `readerhighlight.lua` —
function cited by name only per discipline rule #1, since the
KOReader source is not SHA-pinned in this manual). The upstream
implementation centers `x`; the plugin keeps `x = anchor.x`
(anchor-anchored, not centered) — this is the R-precedent-only
restriction documented in plan §1.5.

### 6.5.c Fallback

When both L2 and L4 exhaust, `find_free_spot` returns nil. The
caller routes the group to the rotation-badge EARNED path
(the stale-rotation filter inside `paintTo`, approximately
`main.lua:4446-4491`, with `_rotationBadgeRender` at
`main.lua:5024`) — the prior-production fallback, preserved
byte-identical.

## 6.6 Eraser-tap atomic delete (G3-6)

Per KSQ-4 (see [§4.4.b](04-koreader-integration.md#44b-btn_tool_rubber)),
KOReader does not distinguish TAP from DRAG for the rubber-tip
event stream. `lib/eraser_tap.lua` adds the distinction:

- `classify(motion)` — `"tap"` when `motion ≤
  ERASE_TAP_MAX_DISTANCE_PX = 10 px`, `"drag"` otherwise.
- `handle_tap(x, y, motion, state, save_fn)` — coordinator that
  classifies, looks up the group whose `cluster_bbox` contains
  `(x, y)`, removes it atomically via `table.remove`, and calls
  `save_fn(state)` exactly once on a successful delete.

The 3-artefact atomicity invariant (group + anchor highlight +
connector all delete together) is satisfied automatically because
all three derive from the single group record. There is no
half-state where the strokes are gone but the underline remains.

`state.tool_active` is deliberately NOT mutated by `handle_tap`;
the eraser tool stays active so the user can chain deletes —
matches the pre-Goal-3 `eraseAtPoint` flow (`main.lua:4286-4348`).

## 6.7 Render-op ordering invariant

LOCKED in G3-M4 (`lib/stroke_paint.lua:118-119` in the
`paint_anchor_group` header block):

```
highlight_underline  <  connector  <  stroke  <  exclamation  <  badge
```

The underline draws first so ink sits on top; the connector ties
them visually; the stroke is the user's mark; the exclamation
glyph (when present) sits above the stroke so the user sees it;
the badge (when present, e.g. orphan or free-spot fallback) is
the topmost element so it never gets hidden.

`StrokePaint.paint_anchor_group` is the canonical emitter for
this order. Specs PT-1..PT-8 in
`spec/stroke_paint_anchor_spec.lua` enforce it.

## Known UX limitations

Per feature-ux gate G-F, these limitations are documented up
front rather than hidden behind marketing language:

1. **Reflow position drift.** When the document is re-flowed
   (font size, font family, margins, line-spacing), the anchor
   xpointer is re-resolved but the stroke's saved pixel
   coordinates do not change. The cluster bbox follows the new
   line position, but the strokes inside it may drift relative to
   the underline if the new line geometry is wildly different
   from the captured geometry. The badge fallback engages when
   the difference is unresolvable.

2. **Eraser TAP-vs-DRAG sensitivity is device-dependent.** The
   plugin uses a 10-px motion threshold (`ERASE_TAP_MAX_DISTANCE_PX`)
   to distinguish a tap from a drag. On devices with a high-DPI
   digitizer (e.g. Kobo Sage at 300 DPI), this is ~0.85 mm —
   wider than typical tremor, narrower than a deliberate
   scribble. On lower-DPI devices, the threshold may feel too
   sensitive or too lax; this constant is tunable in
   `lib/anchor_constants.lua`.

3. **PDF page-anchor captures the page at draw-time only.** For
   PDF documents, the anchor is captured from
   `reader:getCurrentPage()` at the moment the cluster-close
   timer fires (1200 ms after the last pen-DOWN). If the user
   pages away during that 1200 ms window, the anchor will pin to
   the new page, not the page where the stroke was drawn. This is
   a known limitation accepted for the MVP; mitigations (capture
   the page at pen-DOWN instead) are listed in
   [§9](09-extension-points.md#future-tightening).

4. **Cluster-close cuts off long strokes.** Per §6.1.a, a single
   stroke that takes longer than 1200 ms to draw may close the
   cluster mid-stroke. Per-point timestamps would fix this; the
   input layer does not currently expose them.

5. **Hue contrast on Kaleido 3.** The indigo (`#4B0082`) chosen
   for the anchor underline + connector is validated against the
   nine-color Goal-1 palette and the grayscale range, but
   Kaleido 3 e-ink rendering may collapse it onto Blue or
   Purple. A teal `#008080` fallback (`FALLBACK_HUE`) is
   provisioned but not auto-selected; manual SSH validation at
   DoD #10 confirms the indigo on the target Kobo Libra Colour.

6. **Manual-anchor exclamation does not auto-dismiss.** Once the
   exclamation glyph is rendered (ambiguous cluster), it remains
   on screen until the user either taps near the intended text
   line OR eraser-taps the glyph itself (orphan escape hatch).
   There is no time-based auto-dismiss; the user must act.
