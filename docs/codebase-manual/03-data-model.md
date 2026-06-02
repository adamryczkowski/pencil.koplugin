# §3 Data model

This section is the canonical schema reference for everything the
plugin persists to disk and everything it carries in memory. Field
names are exact (Goal-2 lesson #1 — see §3.5 below — explicitly
forbids casual renames).

## 3.1 The on-disk envelope

`saveStrokes` (`main.lua:4765`) writes the following table as a Lua
literal via KOReader's `require("dump")` module:

```lua
return {
  version = 3,                   -- bumped from 2 when image_path/rotation
                                 -- fields were added on annotation groups
  strokes = { stroke_record, … },
  annotation_groups = { group_record, … },
}
```

`loadStrokes` (`main.lua:4663`) reads this via `dofile` (or
`loadstring` under the busted env) and feeds each entry through
`strokeFromSaved` (`main.lua:4737`) before installing.

## 3.2 Stroke record

Produced by `strokeToSaveable` (`main.lua:4724`) and consumed by
`strokeFromSaved` (`main.lua:4737`).

```lua
stroke = {
  -- Identity
  tool       = "pen" | "highlighter",  -- string, NOT enum
  color_name = "Red" | "Yellow" | …,   -- one of the 9 names; see
                                       -- lib/highlight_color_wiring.lua
  width      = <number>,               -- saved stroke width in px

  -- Geometry
  points     = { { x = <int>, y = <int> }, … },
  page       = <int>,                  -- 1-based KOReader page number

  -- Provenance
  datetime   = <int>,                  -- os.time() at pen-down;
                                       -- per-stroke, NOT per-point
                                       -- (input layer does not expose
                                       -- per-sample timestamps — KS fb895d30)
  rotation   = <0..3>,                 -- screen rotation at draw time
                                       -- (used by stale-rotation filter)
}
```

The `color` Blitbuffer is reconstituted at load time from
`color_name` (Blitbuffer instances are not directly serializable).
Strokes are stored at native screen pixel coordinates at the
captured rotation; reflow does NOT rewrite stroke geometry — the
anchor record is what makes the strokes survive reflow (see §3.3).

## 3.3 Annotation group record

Each `annotation_groups[i]` represents a temporally-and-spatially
clustered set of strokes (Goal-2 grouping rule:
`GROUP_TIME_THRESHOLD_S` AND `GROUP_SPATIAL_THRESHOLD = 200 px`). A
group is the unit of:

- bookmark / TOC entry creation (`syncAllBookmarks` at
  `main.lua:3526`).
- image-thumbnail capture (`captureGroupImage` at `main.lua:3569`).
- anchor resolution (one anchor per group).
- atomic delete (Goal-3 eraser TAP — see §6).

```lua
group = {
  -- Identity
  id          = <string>,             -- stable UUID-ish per group
  page        = <int>,                -- canonical page (rotation-stable)
  rotation    = <0..3>,               -- rotation at group creation

  -- Membership
  stroke_indices = { 1, 2, 3, … },    -- indices into the top-level
                                      -- strokes array
  bbox        = { x, y, w, h },       -- union bbox of member strokes
                                      -- at captured rotation

  -- Goal-1 / Goal-2 / Goal-3 anchor (see §3.4 — four-value dispatcher)
  anchor      = nil | "line" | "explicit" | "pdf_page",

  -- Goal-2 image thumbnail
  image_path     = <string>?,         -- absolute path under the images dir
  image_rotation = <0..3>?,           -- rotation when image was captured

  -- Goal-2 bookmark linkage
  bookmark_page  = <string>?,         -- xpointer used to anchor the bookmark
}
```

The `anchor` field is intentionally polymorphic so legacy
(pre-Goal-2) saves stay loadable: a missing `anchor` means
`anchor == nil`, and the four-value dispatcher routes `nil` to the
rotation-badge EARNED path.

## 3.4 The four-value `anchor.type` dispatcher

Documented in `lib/anchor_constants.lua` lines 32-51 and
`lib/stroke_anchor.lua` header. Each value owns one rendering path:

| `anchor.type`   | Path                                                                   | Owner module(s)                                   |
| --------------- | ---------------------------------------------------------------------- | -------------------------------------------------- |
| `nil`           | legacy / image-only → rotation-badge EARNED                            | Goal-2 back-compat (stale-rotation filter inside `paintTo`, approximately `main.lua:4446-4491`) |
| `"line"`        | Goal-2 implicit line-relative anchor                                   | `lib/stroke_anchor.lua` + `main.lua:_drawStrokeTranslated` |
| `"explicit"`    | Goal-3 EPUB cluster anchor (xpointer + cluster_bbox + connector + scale + free-spot history + clarified flag) | `lib/stroke_capture.lua` + `lib/stroke_paint.lua` + `lib/manual_anchor.lua` |
| `"pdf_page"`    | Goal-3 PDF page-anchor (page number + bbox; no heuristic, no auto-layout) | `lib/pdf_anchor.lua` + `lib/stroke_paint.lua`     |

The stale-rotation filter inside `paintTo` (approximately
`main.lua:4446-4491`, Goal-2) has a two-line type-guard
(`g3_typed = group.anchor and (group.anchor.type == "explicit"
or "pdf_page")`) at SHA `72d6920` (G3-M8.5) that bypasses the
filter for those two anchor types so the saved stroke geometry
reaches the draw step unchanged. The filter itself remains
byte-identical for `nil` and `"line"` (Goal-2 earned-path
preservation invariant). The guard is documented in
`lib/anchor_constants.lua`'s 4-value dispatcher block and is
integration-spec-covered (`spec/g3_wiring_spec.lua` G3-M8.5-WR-5,
which greps the stale-rotation region for both `"explicit"` and
`"pdf_page"` type strings). See [§2 Step 5a](
02-annotation-lifecycle.md#step-5a-paint-next-redraw) and
[§7.3.a](07-pdf.md#73a-page-equality-gate).

### 3.4.a `anchor.type == "line"` (Goal-2)

```lua
anchor = {
  type   = "line",
  xp     = <xpointer_string>,         -- credocument xpointer to the
                                      -- anchor text line
  dx_em  = <float>,                   -- x offset from line start in em units
  dy_lh  = <float>,                   -- y offset from line baseline in lh units
}
```

Resolved at paint time via `_getAnchorMetrics(xp)` (`main.lua:4949`)
which calls `doc:getScreenPositionFromXPointer(xp)` (pcall-wrapped).
On miss → rotation-badge EARNED.

### 3.4.b `anchor.type == "explicit"` (Goal-3 EPUB)

```lua
anchor = {
  type              = "explicit",
  xp                = <xpointer_string>,        -- anchor text line; nil
                                                -- when orphan (MA-6 escape)
  cluster_bbox      = { x, y, w, h },           -- cluster bbox at capture
                                                -- (screen px, captured rotation)
  scale             = <0.5..1.0>,               -- current scale factor
                                                -- (free-spot output)
  free_spot_history = {                          -- single-record cache
    layout_key = <string>,                       -- captured layout fingerprint
    x_em       = <float>,
    y_lh       = <float>,
    scale      = <float>,
    line_w_px  = <int>,
  },
  connector_geom    = { x0, y0, x1, y1 },        -- updated on reflow
  clarified         = <bool>,                    -- true once H4+S2 confident
                                                -- or once user resolved
                                                -- ambiguity; false while
                                                -- exclamation glyph is active
}
```

`xp == nil AND clarified == true` is the orphan state: the user
eraser-tapped the exclamation glyph (MA-6 escape hatch from
[§6](06-explicit-anchoring.md)). The render path treats orphans as
a badge fallback at the cluster bbox top-left corner.

### 3.4.c `anchor.type == "pdf_page"` (Goal-3 PDF)

```lua
anchor = {
  type = "pdf_page",
  page = <int>,                       -- 1-based; captured from
                                      -- reader:getCurrentPage()
  bbox = { x, y, w, h },              -- stroke bbox at native pixel
                                      -- coords on the captured page
}
```

No xpointer (PDF has no DOM); no scale (PDFs don't reflow); no
free-spot history (no auto-layout for PDF); no connector. Render
path is a single page-equality gate followed by stroke draw at saved
pixel coordinates.

## 3.5 Field-naming discipline (Goal-2 lesson)

Goal-2 shipped 26 green specs hiding a fully broken pipeline because
the mocks used field names that disagreed with the real KOReader
return shapes. The lesson, recorded in this manual's discipline
rule #2:

- `getWordFromPosition` returns `{ word, sbox = {x,y,w,h}, pos =
  {x,y,page}, pbox = … }`. The text box is `sbox`. It is NOT `pos`,
  even though "pos" sounds like the obvious name.
- credocument's `getNearestWordAndBoxFromPosition` returns
  `{ word, sbox = {x,y,w,h}, pos0 = <xpointer>, pos1 = <xpointer> }`
  in the `accept_table` variant. The xpointer field is `pos0`. It
  is NOT `xpointer`.
- `getScreenBoxesFromPositions(p0, p1, true)` returns a list of
  `{x, y, w, h}` tables. They are bare rect tables — NOT
  `{ box = {…} }` wrappers.

The Goal-3 lib modules deal with this discipline by accepting plain
rect tables in their public APIs and `pcall`-wrapping every
credocument boundary in `main.lua` / lib so a real-API call that
returns nil or raises does not crash the paint loop. The field
names above are derived from the real source at
`frontend/document/credocument.lua` per the file-knowledge agent's
scan (FKS a43eb8db); see [§4](04-koreader-integration.md) for the
full citation list.

## 3.6 The strokes file path

`getStrokesFilePath()` at `main.lua:4649` returns
`<sidecar_dir>/pencil.strokes.lua` where `sidecar_dir` is
`self.ui.doc_settings.doc_sidecar_dir` (KOReader's per-document
state directory under `metadata.…/`). On absence of the sidecar
dir, save is silently skipped (avoids creating orphan files for
documents the reader cannot pin).
