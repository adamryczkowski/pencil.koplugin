# Goal-3 changelog

Per-milestone summary of the Goal-3 ("explicit anchoring + Phase-9
codebase manual") implementation. Each entry pins the commit SHA,
the post-commit busted count, the key files touched, and a one-
paragraph summary. The companion file
[`docs/codebase-manual/`](.) is the present-tense reference
(source-pinned to SHA `7d9325b` at the close of G3-M10); this
changelog is the historical milestone-by-milestone ledger.

## G3-M1 — anchor_constants + stroke_anchor (SHA `3b3a498`) [330/0/0]

- Key files: `lib/anchor_constants.lua` (NEW), `lib/stroke_anchor.lua`
- Established the 4-value `anchor.type` enum (`nil` / `"line"` /
  `"explicit"` / `"pdf_page"`); the central named-constant table
  (single-file tuning surface); the LOCKED render-op ordering
  invariant (initially 4 entries; extended to 5 with `connector`
  in G3-M8 round). Documentation-and-constants milestone — no
  paint behavior changes yet.

## G3-M2 — stroke_cluster + cluster-close timer (SHA `f86b8c2`) [335/0/0]

- Key files: `lib/stroke_cluster.lua` (NEW), `main.lua` +117 lines
  for `_routeStrokeToCluster` / `_resetClusterCloseTimer` /
  `_onClusterCloseTimeout`, `spec/stroke_cluster_spec.lua` (+5
  CL-1..CL-5)
- Cluster bookkeeping: `add_stroke`, `should_join`, `should_close`,
  `get_bbox`, `finalize`. The 1200 ms `CLUSTER_CLOSE_TIMEOUT_MS`
  timer is reset on every pen-DOWN; cluster-close fires
  `_onClusterCloseTimeout` 1200 ms after the last DOWN with no
  new DOWN in between.

## G3-M3 — cluster_heuristic (SHA `db07bf5`) [341/0/0]

- Key files: `lib/cluster_heuristic.lua` (NEW),
  `spec/cluster_heuristic_spec.lua` (+6 AH-1..AH-6)
- H4 scorer (`score_line = overlap × crossing_count`) + S2
  ranked-top-3 output + `is_confident` gate against
  `AMBIGUITY_GAP_THRESHOLD = 0.20`. `fetch_line_boxes` pcall-
  wraps the three credocument calls (`getPageXPointer`,
  `getPageXPointer`, `getScreenBoxesFromPositions`) under one
  `build-compat:` marker.

## G3-M4 — paint_anchor_group + manual_anchor + reflow wiring (SHA `ddf7b08`) [359/0/0]

- Key files: `lib/stroke_paint.lua` +221 lines for
  `paint_anchor_group`, `lib/manual_anchor.lua` (NEW),
  `main.lua` +50/-12 lines for `_clearPaintMemos` /
  `_onPageTurn` / `onDocumentRerendered` activation, 5 spec
  files (+15 PT-1..PT-8 + MA-1..MA-6 + MA-LAT-1 + WR-1..WR-3)
- The Goal-3 paint dispatch (`paint_anchor_group`) emits the
  ordered render-op list for `"explicit"` and `"pdf_page"`
  groups. Manual-anchor state machine (per-cluster, no globals)
  for ambiguous clusters: clarification tap, debounce,
  eraser-tap-on-connector re-anchor, eraser-tap-on-exclamation
  orphan. Reflow / page-turn cache invalidation wired via
  `_clearPaintMemos` + the `onDocumentRerendered` /
  `onPageUpdate` / `onUpdatePos` event handlers.

## G3-M5a — free_spot L2 margin-preference pass (SHA `b463b37`) [362/0/0]

- Key files: `lib/free_spot.lua` (NEW, 180 lines),
  `spec/free_spot_spec.lua` (+3 FS-1..FS-3)
- Auto-layout LEFT / RIGHT margin search at descending
  `SCALE_STEP_RATIOS = {1.0, 0.9, 0.75, 0.6, 0.5}` with strict-
  inequality AABB overlap (edge-touching not a collision). On
  failure: returns `nil` so the rotation-badge EARNED path takes
  over.

## G3-M5b — free_spot L4 in-text BELOW/ABOVE port (SHA `3b1864a`) [365/0/0]

- Key files: `lib/free_spot.lua` (extended; +107 lines),
  `spec/free_spot_spec.lua` (+3 FS-4..FS-6)
- In-text fallback (when L2 fails): try BELOW the anchor line
  first (Western reading-order precedence), then ABOVE. Ported
  from `ReaderHighlight:_getDialogAnchor` y-arithmetic with the
  R-precedent-only restriction (cluster left edge stays at
  `anchor_bbox.x`, not centered). When both passes exhaust:
  rotation-badge EARNED fallback.

## G3-M6 — eraser_tap + annotation_persistence (SHA `e26cd93`) [374/0/0]

- Key files: `lib/eraser_tap.lua` (NEW),
  `lib/annotation_persistence.lua` (NEW),
  `spec/eraser_tap_spec.lua` (+4 ER-1..ER-4),
  `spec/annotation_persistence_spec.lua` (+5 PER3-1..PER3-5)
- Per KSQ-4: input.lua does NOT distinguish TAP from DRAG —
  plugin owns the classification via
  `ERASE_TAP_MAX_DISTANCE_PX = 10`. TAP on a cluster bbox
  triggers atomic group delete (single `table.remove`; 3-artefact
  atomicity by construction). Pure-Lua `dump`-compatible
  serializer for the on-disk `{version, strokes,
  annotation_groups}` envelope so persistence specs can round-
  trip without booting KOReader.

## G3-M7 — pdf_anchor (SHA `1308e63`) [378/0/0]

- Key files: `lib/pdf_anchor.lua` (NEW),
  `spec/pdf_anchor_spec.lua` (+4 PA-1..PA-4)
- Per KSQ-2: `PdfDocument:getCurrentPage()` does NOT exist —
  current-page state is owned by the reader/view layer
  (ReaderRolling / ReaderPaging). `compute(reader, stroke_bbox)`
  pcall-wraps `reader:getCurrentPage()` and returns
  `{ type = "pdf_page", page = N, bbox = stroke_bbox }` or
  `nil` on failure. `should_render(group, current_page)` is the
  render-time page-equality gate.

## G3-M8.5 — paintTo dispatch wiring (SHA `72d6920`) [384/0/0]

- Key files: `main.lua` +185/-50 (4-branch dispatch + 5-op
  executor + 3 new paint helpers + 2-line type-guard),
  `spec/g3_wiring_spec.lua` +233 (G3-M8.5-WR-1..WR-6 integration
  specs)
- `paintTo` now dispatches on `group.anchor.type`: `nil` falls
  through to the renderStroke fallback (gated by `if
  group.anchor`); `"line"` keeps the BYTE-IDENTICAL Goal-2
  `paint_with_anchor` call; `"explicit"` and `"pdf_page"` call
  `paint_anchor_group` and execute the returned render-op list
  via a 5-branch op executor (stroke / badge / highlight_underline
  / connector / exclamation). `pdf_page` is additionally gated
  by `PdfAnchor.should_render`. 3 new helpers
  (`_drawAnchorUnderline`, `_drawConnector`,
  `_drawAnchorExclamation`) implement the visual primitives via
  `paintRectRGB32` + `drawLineSegment` (no font dependency for
  the exclamation glyph — rect-composition matches
  `renderRotationBadge`). Stale-rotation filter gains a 2-line
  `g3_typed` type-guard so explicit/pdf_page groups bypass the
  Goal-2 stale-rotation bookkeeping.

## G3-M8 — Phase-9 codebase manual (SHA `3f35698`) [384/0/0]

- Key files: `docs/codebase-manual/` (10 files, NEW: README +
  §1 architecture + §2 lifecycle + §3 data model + §4 KOReader
  integration + §5 reflow + §6 explicit anchoring + §7 PDF +
  §8 testing + §9 extension points), `lib/anchor_constants.lua`
  comment fix (header re-tense + LOCKED ordering 5-element)
- The "describe-to-test" manual produced by the Phase-9 pass.
  Discipline rules in force: every API cited by file + function
  name; every data shape derived from the real return value;
  no marketing language; worked examples over reference; both
  formats covered; reflow events exhaustive. Source-pinned to
  SHA `72d6920` (G3-M8.5). §9.6 lists 8 future-tightening items;
  items 7 + 8 closed in G3-M9.

## G3-M9 — exclamation_hue + first-paint pulse (SHA `7d9325b`) [386/0/0]

- Key files: `lib/stroke_paint.lua` (exclamation op emits hue),
  `pencil.koplugin/main.lua` (3 helpers + executor +
  `_drawAnchorExclamation` pulse scheduler),
  `spec/stroke_paint_anchor_spec.lua` (+1 G3-M9-HUE-1),
  `spec/g3_wiring_spec.lua` (+1 G3-M9-PULSE-1)
- Closed §9.6 items 7 + 8 from the M8 manual. (1) The exclamation
  op now carries `hue = AnchorConstants.ANCHOR_UNDERLINE_HUE`
  (single visual family with underline + connector). (2)
  Hardcoded `{75, 0, 130}` literals stripped from all 3 paint
  helpers — `AnchorConstants`-driven fallbacks instead (hard-
  constraint #5 fully enforced; future hue changes propagate
  without touching `main.lua`). (3)
  `_drawAnchorExclamation` schedules a one-shot first-paint pulse
  via `UIManager:scheduleIn(EXCLAMATION_PULSE_DURATION_MS /
  1000, ...)` guarded by `self._exclamation_pulse_scheduled` so
  the scheduler does NOT re-fire on every subsequent paint. The
  scheduled callback calls `UIManager:setDirty(..., "ui")` to
  trigger one re-render — single pulse, not a loop. pcall-wrapped
  per the build-compat idiom.

## G3-M10 — closeout (this commit) [386/0/0]

- Key files: this changelog (NEW),
  `docs/codebase-manual/09-extension-points.md` (§9.6 items 7+8
  re-tensed to "Landed in G3-M9")
- Doc-only milestone. Final closeout of Goal-3: 10 substantive
  milestones from G3-M1 through G3-M9 (G3-M8.5 inserted between
  M7 and M8 to integrate the dispatch wiring before the manual
  was committed), 56 new specs (330 → 386), 11 new `lib/`
  modules, 10 new manual sections, full earned-path preservation
  for Goal-1 + Goal-2. No new code. Busted unchanged at 386/0/0.

---

## Earned-paths preservation audit (across all 10 commits)

The Goal-3 implementation preserved every Goal-1 / Goal-2 earned
path byte-identically:

- `Pencil:renderRotationBadge` (Goal-2 badge primitive) — unchanged.
- `Pencil:_rotationBadgeRender` (Goal-2 per-group badge dispatcher)
  — unchanged.
- The 5 pre-reflow handlers (`onSetDimensions` / `onSetFontSize` /
  `onSetFont` / `onSetLineSpace` / `onSetPageMargins`) — unchanged
  apart from the additive `self:_clearStrokeAnchorCache()` call
  which has been there since Goal-2.
- The xpointer_v2 lazy-upgrade block (around `main.lua:3133-3147`)
  — unchanged.
- Path-A Goal-1 `TOOL_HIGHLIGHTER` rendering — unchanged.
- The stale-rotation filter inner Goal-2 logic (the existing
  `if group.image_rotation == nil ...` branches inside the filter
  block) — unchanged. Goal-3 only ADDED the outer `g3_typed`
  bypass guard, which is two purely additive lines at the top of
  the inner block.
- `Pencil:paint_with_anchor` (Goal-2 paint entry) — unchanged;
  still called for `nil` and `"line"` anchors via the new
  `paintTo` dispatch's `else` clause.

## Spec count progression

| Milestone | Delta | Total |
|---|---|---|
| Goal-2 baseline | — | 330 |
| G3-M2 | +5 (CL) | 335 |
| G3-M3 | +6 (AH) | 341 |
| G3-M4 | +18 (PT + MA + WR + MA-LAT) | 359 |
| G3-M5a | +3 (FS-1..FS-3) | 362 |
| G3-M5b | +3 (FS-4..FS-6) | 365 |
| G3-M6 | +9 (ER + PER3) | 374 |
| G3-M7 | +4 (PA) | 378 |
| G3-M8.5 | +6 (WR-1..WR-6 paintTo dispatch) | 384 |
| G3-M8 | 0 (doc-only) | 384 |
| G3-M9 | +2 (HUE-1 + PULSE-1) | 386 |
| G3-M10 | 0 (doc-only) | 386 |
