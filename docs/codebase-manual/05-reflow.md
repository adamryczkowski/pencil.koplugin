# §5 Reflow (EPUB)

This section documents every KOReader event that triggers a re-flow
of the document body and how the plugin's anchor / paint pipeline
reacts. PDF documents do NOT reflow — page geometry is fixed —
and the corresponding event handlers on the plugin no-op when the
document format is PDF.

## 5.1 Reflow events (exhaustive list)

KOReader fires the following events when a property change causes
CRengine's text-layout cache to be invalidated. The plugin listens
for each:

| Event                  | Plugin handler                      | Source                |
| ---------------------- | ----------------------------------- | --------------------- |
| `SetFontSize`          | `Pencil:onSetFontSize`              | `main.lua:5037`       |
| `SetFont`              | `Pencil:onSetFont`                  | `main.lua:5045`       |
| `SetLineSpace`         | `Pencil:onSetLineSpace`             | `main.lua:5053`       |
| `SetPageMargins`       | `Pencil:onSetPageMargins`           | `main.lua:5061`       |
| `SetDimensions`        | `Pencil:onSetDimensions`            | `main.lua:5029`       |
| `DocumentRerendered`   | `Pencil:onDocumentRerendered`       | `main.lua:5099`       |
| `PageUpdate`           | `Pencil:onPageUpdate`               | `main.lua:5104`       |
| `UpdatePos`            | `Pencil:onUpdatePos`                | `main.lua:5134`       |

Implicit reflow triggers (these flow through `DocumentRerendered`
or `SetDimensions` rather than firing their own event):

- Rotation change: `KOptInterface` / `ReaderRolling` fires
  `SetDimensions` after a rotation, which `onSetDimensions`
  handles.
- Style-tweak change: routes through `DocumentRerendered`.
- `sync_t_b_page_margins` toggle: routes through `SetPageMargins`.

## 5.2 What each event invalidates

The plugin's invalidation discipline:

- **Anchor-resolution cache** (the small per-tick memo of
  `_getAnchorMetrics` results, `main.lua:4938`): cleared on every
  one of the eight events above. Cleared via
  `_clearStrokeAnchorCache()` (`main.lua:4938`) and, for the
  Goal-3 paint-loop memos, via `_clearPaintMemos()`
  (`main.lua:5075`).
- **Image thumbnail cache**: image_path remains valid until
  rotation or font-size change invalidates the captured pixels.
  Rotation invalidation is the rotation-badge filter's job
  (§5.4 below); font-size changes route through
  `onSetFontSize` which calls `_clearStrokeAnchorCache()` and
  schedules a `backfillMissingImages()` re-capture.
- **Page-stroke index** (`self.page_strokes` —
  `main.lua:4048`): page indices are page-number-keyed and survive
  reflow as long as `stroke.page` does not change. They are
  rebuilt on undo and on eraser delete.

## 5.3 The Goal-3 paint memos and `_onPageTurn`

Goal-3 added two methods that participate in the reflow story:

- `Pencil:_clearPaintMemos()` at `main.lua:5075` — drops any
  paint-loop memo that depended on the previous page's geometry
  (currently the explicit-anchor screen-position memo and the
  ambiguity-heuristic line-box memo).
- `Pencil:_onPageTurn()` at `main.lua:5083` — convenience caller
  that wraps `_clearPaintMemos` plus any other page-boundary
  reset. Called from `onPageUpdate` and `onUpdatePos` at the end of
  their existing bodies (see WR-1 and WR-2 specs).
- `Pencil:onDocumentRerendered()` at `main.lua:5099` — activated
  in G3-M4 (was a no-op comment block before). Now calls
  `_clearPaintMemos`; this is the precondition for explicit
  anchors to recompute their screen position after a reflow.

## 5.4 The stale-rotation filter (Goal-2 earned path)

The filter inside `paintTo` (approximately `main.lua:4446-4491`)
is the canonical example of an earned fallback. Each rendered
group is gated by:

```lua
if group.rotation ~= current_screen_rotation then
  return self:_rotationBadgeRender(bb, group)   -- badge at saved bbox
end
```

— with the consequence that strokes whose saved rotation does not
match the current screen rotation render as a badge instead of as
strokes. This is correct (rotating the screen rewrites the page
layout but does NOT rewrite the stroke's saved pixel coordinates,
so blindly drawing them would put ink in the wrong place).

Goal-3 added a 2-line type-guard at the top of the filter at SHA
`72d6920` (G3-M8.5), per [§2 Step 5a](
02-annotation-lifecycle.md#step-5a-paint-next-redraw) and
[§7.3.a](07-pdf.md#73a-page-equality-gate). The live shape is:

```lua
local g3_typed = group.anchor
    and (group.anchor.type == "explicit"
      or group.anchor.type == "pdf_page")
if not g3_typed then
    -- existing Goal-2 stale-rotation bookkeeping
end
```

— so an explicit or pdf_page anchor bypasses the rotation
short-circuit. This is justified because:

- `"explicit"` groups have an xpointer that the paint path
  re-resolves on every paint; whatever pixel position the
  rotation happens to produce IS the correct position.
- `"pdf_page"` groups have no rotation handling by design (PDFs
  don't reflow; rotation is a render-layer transform applied to
  the bb after the strokes are drawn).

The filter itself remains byte-identical for `nil` and `"line"`
— preserving the Goal-2 earned-paths invariant. The type-guard
is two purely additive lines at the top of the filter's inner
block; it does not modify any existing branch. Integration-spec-
covered by `spec/g3_wiring_spec.lua` G3-M8.5-WR-5.

This filter is the bug that silently blocked Goal-2 anchored paint
from working from the original Goal-2 commits until the fix at
`4a72ea6`. The original Goal-2 path forgot to clear
`group.rotation` after a successful anchor re-resolution, so the
filter shorted to badge on every paint. The fix was a one-line
update of `group.rotation` inside the `"line"` paint branch; the
filter itself stays untouched.

## 5.5 The paint pipeline order

Each `paintTo` invocation (`main.lua:4421`) does the following in
strict order:

1. Early-out: if there are no strokes at all on the current page,
   return immediately.
2. Iterate `annotation_groups`. For each group:
   a. Check the four-value dispatcher (§3.4).
   b. Run the stale-rotation filter (with Goal-3 type-guard).
   c. Compute the render-op list (`paint_anchor_group` for
      `"explicit"` / `"pdf_page"`; in-line for `"line"`; badge for
      `nil`).
   d. Execute each render-op against `bb` in the LOCKED ordering:
      `highlight_underline < connector < stroke < exclamation <
      badge` (see [§6](06-explicit-anchoring.md)).
3. Apply image-thumbnail overlays where present.
4. Apply the temporary preview selection if a stroke is currently
   in-progress (`_paintTempSelection` at `main.lua:992`).

The paint pipeline is the single point where the four-value
dispatcher is consumed; everything upstream (capture, anchor
assignment, free-spot layout) is data-only.

## 5.6 PDF reflow story

PDF does not reflow. The listed reflow events still fire on a PDF
document (KOReader uses the same event broker for both formats),
but the plugin handlers detect format via
`self.ui.document.is_pic` / `self.ui.document.koptinterface` and
short-circuit. Concretely:

- `_clearStrokeAnchorCache()` runs but the cache is empty for
  `"pdf_page"` anchors (`PdfAnchor.should_render` is a stateless
  page-equality check, no memo).
- `_clearPaintMemos()` runs but is a no-op for PDF (no per-tick
  paint memo is populated for the `"pdf_page"` branch).
- The stale-rotation filter's type-guard explicitly opts
  `"pdf_page"` groups out of the rotation short-circuit (§5.4).

The result: a PDF page-anchored stroke renders at saved pixel
coordinates whenever the current page matches its captured page,
independent of font / rotation / margin / line-spacing changes
(none of which apply to PDF anyway).
