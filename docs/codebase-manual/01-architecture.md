# §1 Architecture

## Where the plugin lives

`pencil.koplugin` is a KOReader plugin (`*.koplugin` directory) that
the reader auto-loads at startup. The top-level entry point is
`pencil.koplugin/main.lua`, which returns a `WidgetContainer`
subclass named `Pencil`. The plugin attaches event handlers via
KOReader's `EventListener` contract — every public function whose
name starts with `on…` is dispatched by the reader's event broker
(e.g. `onSetFontSize`, `onPageUpdate`, `onCloseDocument`).

The plugin owns:

- A stylus input override that bypasses KOReader's gesture detector
  and reads raw stylus events directly (`setupPenInput` at
  `main.lua:1914`, `teardownPenInput` at `main.lua:2027`).
- A per-document strokes file under the document's sidecar dir,
  written via `saveStrokes` (`main.lua:4765`) and read via
  `loadStrokes` (`main.lua:4663`). The on-disk format is a Lua
  `return {...}` literal produced by KOReader's `dump` module.
- The screen-overlay paint, applied each redraw via `paintTo`
  (`main.lua:4421`). The paint runs after KOReader's text/highlight
  layers so pen strokes sit on top.
- A set of small lookup tables and helper modules under
  `pencil.koplugin/lib/`. The `lib/` modules are pure Lua — no
  `require('main')`, no UIManager or Blitbuffer dependencies — so
  they can be exercised under busted without booting the reader.

## The `lib/` module split

Each `lib/` module owns one responsibility. Tests under `spec/`
mirror this split one-to-one.

| Module | Lines | Owns |
|---|---|---|
| `lib/anchor_constants.lua` | 215 | Central named-constant table for Goal-3 (CLUSTER_CLOSE_TIMEOUT_MS, AMBIGUITY_GAP_THRESHOLD, FREE_SPOT_MARGIN_PX, ERASE_TAP_MAX_DISTANCE_PX, the indigo hue tables, the connector/underline geometry). Single-file tuning surface. No engine deps. |
| `lib/stroke_anchor.lua` | 205 | Schema and dispatcher documentation for the four-value `anchor.type` (`nil`, `"line"`, `"explicit"`, `"pdf_page"`); helper math for Goal-2 line-relative anchor resolution. |
| `lib/stroke_capture.lua` | 98 | Per-stroke geometric capture helpers used by `endRawStroke` (bbox computation, page-pin). |
| `lib/stroke_paint.lua` | 319 | `paint_anchor_group` — pure dispatch from a group + scalars to an ordered render-op list. Does NOT execute draw calls; the caller (main.lua `paintTo`) is the executor. |
| `lib/stroke_cluster.lua` | 224 | Goal-3 cluster bookkeeping: `add_stroke`, `should_join`, `should_close`, `get_bbox`, `finalize`. The 1200 ms cluster-close timeout lives here. |
| `lib/cluster_heuristic.lua` | 272 | Goal-3 H4 ambiguity scorer (`score_line = overlap × crossings`) and S2 ranked top-3 + confidence gap. Pcall-wraps the credocument calls in `fetch_line_boxes`. |
| `lib/manual_anchor.lua` | 272 | Goal-3 manual-anchor state machine for ambiguous clusters: clarification tap, debounce, eraser-tap on connector (re-anchor), eraser-tap on exclamation (orphan). Per-cluster state, no globals. |
| `lib/free_spot.lua` | 287 | Goal-3 L2 (margin) + L4 (in-text below/above) auto-layout search. Strict-AABB overlap predicate. Returns `{x, y, scale}` or `nil`. |
| `lib/eraser_tap.lua` | 135 | Goal-3 eraser TAP vs DRAG classification + atomic group delete on TAP. `handle_tap` coordinator calls a `save_fn` callback on successful delete. |
| `lib/annotation_persistence.lua` | 169 | Pure-Lua serialize / deserialize / round-trip for the `{version, strokes, annotation_groups}` shape that `saveStrokes` writes via KOReader's `dump`. Deterministic key order. |
| `lib/pdf_anchor.lua` | 103 | Goal-3 PDF page-anchor `compute(reader, stroke_bbox)` and `should_render(group, current_page)`. Pcall-wraps `reader:getCurrentPage()`. |
| `lib/dispatch_predicate.lua` | small | Boolean dispatch helpers used by `paintTo` to gate per-tool branches. |
| `lib/geometry.lua` | small | Pre-Goal-3 geometric helpers used by stroke capture and paint. |
| `lib/highlight_color_wiring.lua` | 102 | Goal-1 highlight-color routing (the nine-palette Color8 mapping). |
| `lib/settings_defaults.lua` | 65 | Default values for the per-tool settings store. |

## Responsibility boundaries

The plugin keeps a strict separation between pure-Lua libs and the
KOReader-touching `main.lua`. This separation is what made Goal-2's
mock-vs-prod disaster recoverable: the libs are unit-testable
without booting the reader, and `main.lua` is the only place where
real CRengine / Blitbuffer / UIManager calls land.

- `lib/*.lua` modules are pure data + algorithms. They MAY hold a
  `package.path` mutation at the top to make `require("lib/...")`
  work under busted, but they do NOT call any KOReader API directly.
  Where a KOReader-shaped argument is required (e.g. a `doc` handle
  for `getScreenBoxesFromPositions`), the lib accepts it as a
  parameter and `pcall`-wraps the call (`build-compat:` comment
  marker) so a missing method or runtime exception yields a graceful
  nil rather than a crash.
- `main.lua` glues `lib/` modules to KOReader. It owns the
  `Pencil:on…` event handlers, the actual draw calls, the file
  I/O, and the integration with the reader's `Dispatcher` /
  `ReaderUI` / `UIManager` services. No business logic lives in
  `main.lua` that does not have a corresponding pure-Lua test in
  `spec/`.
- `spec/*_spec.lua` files mirror the `lib/` layout. Cross-cutting
  integration (e.g. `g3_wiring_spec.lua`) reads `main.lua` as text
  and greps for required wirings — see [§8](08-testing.md) for the
  inline-mock + source-grep pattern.

## Goal-by-goal additions

The three feature goals layered on top of each other without
breaking earned paths:

- **Goal-1**: pen strokes, eraser, color picker, undo. Strokes are
  saved at native pixel coordinates and replayed unchanged on the
  same page. No anchor.
- **Goal-2**: line-relative anchor (`anchor.type == "line"`). Each
  group remembers an xpointer + `dx_em` / `dy_lh` offsets so its
  strokes follow text reflow. Rotation-badge fallback for groups
  that cannot resolve their xpointer at paint time. (Goal-2 also
  introduced the stale-rotation filter inside `paintTo`
  (approximately `main.lua:4446-4491`) — see §5.)
- **Goal-3**: explicit-anchor EPUB clusters (`anchor.type ==
  "explicit"`) and PDF page-anchors (`anchor.type == "pdf_page"`).
  Adds the cluster timer, the ambiguity heuristic, the connector +
  exclamation primitives, the free-spot layout, the eraser-tap atomic
  delete, and the PDF capture-and-gate. Goal-2's earned paths are
  preserved byte-identically — Goal-3 only adds dispatch branches
  for `"explicit"` and `"pdf_page"` and a 2-line type-guard in the
  stale-rotation filter.

The four-value `anchor.type` dispatcher (documented in
`lib/anchor_constants.lua` lines 32-51 and `lib/stroke_anchor.lua`
header) is the single mediating contract between these three goals.
See [§3](03-data-model.md) for the schema details.
