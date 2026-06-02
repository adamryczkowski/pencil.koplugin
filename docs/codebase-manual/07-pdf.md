# §7 PDF page-anchor path

This section is the PDF counterpart of [§6](06-explicit-anchoring.md).
The contrast with EPUB is intentional and is the central point of
this section: **PDF has no heuristics, no auto-layout, no connector,
no exclamation, no manual-anchor mode.** The page IS the anchor.

## 7.1 Why PDF is simpler

PDF documents do not reflow. Font size, line spacing, page margins,
and (for KOReader's purposes) rotation are properties of the render
layer, not of the document body. Stroke pixel coordinates captured
at draw time remain valid for as long as the document is on the
same page.

The Goal-3 EPUB workflow exists because EPUB reflows — an anchor
needs to be "remembered" relative to the text so the strokes
follow the new line position. PDF has no text to anchor to (in the
general case; embedded text positions are not stable across
KOReader's reflow modes either), and no reflow to follow. The
simplest possible anchor is the page number itself.

## 7.2 The capture path

Owner: `lib/pdf_anchor.lua`.

When the cluster-close timer fires (`_onClusterCloseTimeout` at
`main.lua:970`) and the document format is PDF, the handler calls:

```lua
PdfAnchor.compute(reader, stroke_bbox)
  → { type = "pdf_page", page = <int>, bbox = {x,y,w,h} }
  → nil  on failure
```

The `reader` argument is `self.ui.rolling` (KOReader-mode PDF) or
`self.ui.paging` (raw-page PDF). KSQ-2 (pdfdocument FKS
62b9061a-f944-4e81-a4d2-69901b0d3594) confirmed that
`PdfDocument:getCurrentPage()` does NOT exist; the reader/view
layer owns current-page state.

`compute` is defensive: it `pcall`-wraps `reader:getCurrentPage()`
because the call may be absent on some reader implementations or
raise during cold-cache moments. On any failure it returns nil,
and the stroke falls through to the legacy nil-anchor →
rotation-badge EARNED path (Goal-2 back-compat).

The returned anchor is a plain table with three fields:

- `type = "pdf_page"` — the dispatcher key.
- `page = <int>` — 1-based, integer-forced via `math.floor`.
- `bbox = {x, y, w, h}` — the cluster's screen-pixel bbox at
  capture time. PDFs do not reflow, so this bbox stays valid;
  the field is preserved for future features (e.g. PDF
  free-spot layout, see [§9](09-extension-points.md)).

## 7.3 The render path

Owner: `lib/stroke_paint.lua` (the existing G3-M4 `paint_anchor_group`
branch for `atype == "pdf_page"`).

The render path is two steps:

### 7.3.a Page-equality gate

The caller (`paintTo` at `main.lua:4421`, integrated at SHA
`72d6920` per G3-M8.5) asks:

```lua
PdfAnchor.should_render(group, current_page)
```

This returns true only when:

1. `group.anchor` is a table.
2. `group.anchor.type == "pdf_page"`.
3. `group.anchor.page == current_page` (integer equality).

Any other anchor type, missing fields, or page mismatch returns
false. The gate is a strict type guard so callers can blanket-
test all groups and only paint the ones that match.

### 7.3.b Stroke-only emit

When the gate passes, `paint_anchor_group(group, doc, em_px, lh_px,
screen_w, screen_h, screen_rot, draw_translated_fn,
rotation_badge_fn, anchor_highlight_fn, connector_fn)` emits a
single render op:

```lua
{
  type  = "stroke",
  group = group,
  scale = 1.0,                       -- PDF anchor always renders at
                                     -- 1.0 (no free-spot scale)
  dx    = 0,
  dy    = 0,
}
```

— and zero ops of every other type:

- No `highlight_underline` op (no text-line underline; PDF has no
  text-anchored underline target).
- No `connector` op (no connector line; the stroke IS at the
  anchor target).
- No `exclamation` op (no ambiguity prompt; capture is
  deterministic).
- No `badge` op (no rotation-badge fallback; rotation does not
  apply to a fixed-page anchor).

Verified by `spec/stroke_paint_anchor_spec.lua` PT-2 and end-to-
end by `spec/pdf_anchor_spec.lua` PA-4.

## 7.4 What PDF explicitly does NOT do

For each Goal-3 EPUB feature in §6, the corresponding PDF behavior:

| EPUB (§6)                                                      | PDF (this section)                                  |
| -------------------------------------------------------------- | --------------------------------------------------- |
| Cluster detection (§6.1)                                        | Same 1200 ms timer; same cluster bookkeeping.       |
| Ambiguity heuristic H4+S2 (§6.2)                                | NOT run. PDF has no text-line anchor target.        |
| Anchor highlight underline (§6.3)                               | NOT drawn. No text line to underline.               |
| Connector line (§6.3)                                           | NOT drawn. Stroke IS at the anchor target.          |
| Manual-anchor mode / exclamation glyph (§6.4)                   | NOT shown. Capture is deterministic.                |
| Free-spot auto-layout L2 + L4 (§6.5)                            | NOT run. PDF strokes stay where the user drew them. |
| Eraser-tap atomic delete (§6.6)                                 | Same as EPUB — `lib/eraser_tap.lua` is format-agnostic; the cluster bbox lookup works on any group with a `cluster_bbox` field. |
| Render-op ordering (§6.7)                                       | Trivially satisfied (only one op type is emitted).  |
| Rotation-badge filter type-guard (§5.4)                         | Bypasses the rotation short-circuit so saved pixel coords reach the draw step unchanged (`pdf_page` listed in the type-guard alongside `explicit`). |

## 7.5 PDF rotation

KOReader rotates the PDF page at the render layer (the
`Blitbuffer` blit applies the rotation), not in the document.
`nativeToPageRectTransform(doc, pageno, rect)` (per KSQ-5)
returns the page-coordinate rect unchanged in native mode and
`Geom.boundingBox(boxes)` in reflow mode; it does NOT transform
for rotation.

The DoD #1 PDF rotation note (plan §G3-7) is explicit:

> Goal-3 PDF strokes render at saved pixel coordinates; rotation
> survival is NOT a DoD requirement for PDF (PDFs don't reflow;
> page orientation is fixed).

In practice, if the user rotates the screen between drawing and
re-opening the document on the same PDF page, the strokes will
render at the captured pixel coordinates relative to the
unrotated render. KOReader's render layer applies the rotation
transform over the whole bb (text + strokes together), so the
visual effect is "strokes follow the page". A side-effect is that
strokes drawn in portrait mode and viewed in landscape mode will
sit at the captured x/y, which may no longer align with the same
text region on screen. Users who care about rotation-stable PDF
strokes are advised to draw and view at the same rotation.

## 7.6 PDF persistence

Same envelope as EPUB (`{ version = 3, strokes = {...},
annotation_groups = {...} }` — see [§3.1](03-data-model.md#31-the-on-disk-envelope)).
The only PDF-specific field is `group.anchor.page` (1-based
integer). `spec/annotation_persistence_spec.lua` PER3-3 round-
trips a fixture group with `anchor = { type = "pdf_page", page =
17 }` to prove the schema survives serialize → deserialize
unchanged.
