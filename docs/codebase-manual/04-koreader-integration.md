# §4 KOReader integration

This section lists every KOReader API the plugin calls. Each call
includes its real argument and return shape (derived from the
upstream source via file-knowledge-agent scans during Goal-3 panel
work) and the corresponding plugin call site.

KOReader's source churns; line numbers in `frontend/…` may have
drifted by the time the reader sees this manual. Function names are
durable; cite by name + file when in doubt.

## 4.1 CRengine document API (EPUB)

Owner: `frontend/document/credocument.lua` (FKS a43eb8db).

### 4.1.a `doc:getScreenPositionFromXPointer(xp)`

Resolves an xpointer to current screen coordinates.

- Argument: xpointer string.
- Returns: `screen_y, screen_x` (NOTE: y-first ordering — Goal-2
  fixture mistake).
- Returns `nil` (no error raised) when the xpointer cannot be
  resolved on the current page (e.g. off-screen text, deleted DOM
  node).

Plugin call sites:

- `Pencil:_getAnchorMetrics(xp)` at `main.lua:4949` — wrapped in
  `pcall`, marker comment `-- build-compat:
  getScreenPositionFromXPointer`. Used for Goal-2 line-anchor
  resolution.
- `StrokePaint.paint_anchor_group` in `lib/stroke_paint.lua` —
  same wrapper pattern, fall-through to badge fallback on nil.

### 4.1.b `doc:getPageXPointer(pageno)`

Returns the xpointer at the start of a given page.

- Argument: 1-based page number.
- Returns: xpointer string, or empty string at end-of-document.

Plugin call site:

- `ClusterHeuristic.fetch_line_boxes` in
  `lib/cluster_heuristic.lua` — paired call with
  `getScreenBoxesFromPositions` below; both pcall-wrapped under one
  `build-compat:` marker.

### 4.1.c `doc:getScreenBoxesFromPositions(xp0, xp1, want_lines)`

Returns the list of line bboxes between two xpointers.

- Arguments: two xpointer strings + a boolean (true =
  line-resolution, false = character-resolution).
- Returns: table list of `{ x, y, w, h }` rects in screen pixel
  coordinates. Bare tables, no `box = {…}` wrapper.

Plugin call site:

- `ClusterHeuristic.fetch_line_boxes` — the ambiguity heuristic's
  source of candidate lines. The `true` argument is mandatory; the
  `false` form is character-resolution and would feed wrong data
  to the H4 scorer.

### 4.1.d `doc:getWordFromPosition(pos)`

Used for the Goal-1 text-highlight extract path.

- Argument: `{x, y, page}` position table.
- Returns: `{ word, sbox = {x,y,w,h}, pos = {x,y,page}, pbox = …
  }` or nil.
- The text bbox is `sbox`. NOT `pos`. NOT `pbox`. (Goal-2 lesson:
  the obvious-sounding name is wrong; the mock that hardcoded
  `{ pos = {…} }` was the Goal-2 ghost spec.)

Plugin call site:

- `Pencil:startTextHighlight` at `main.lua:1028` and onward —
  Goal-1 text-highlight extraction. Not used in Goal-3 directly.

### 4.1.e `doc:getNearestWordAndBoxFromPosition(pos, accept_table)`

Variant that yields xpointers when `accept_table` is true.

- Argument: same `{x, y, page}` + `true`.
- Returns: `{ word, sbox = {x,y,w,h}, pos0 = <xpointer>, pos1 =
  <xpointer> }` or nil.
- The xpointer field is `pos0`. NOT `xpointer`. NOT `pos`.

Plugin call site:

- `Pencil:getXPointerAtBboxCenter(bbox)` at `main.lua:3197` —
  Goal-2 cluster-center-to-xpointer mapping for the line anchor.

### 4.1.f `_callCacheReset` (internal)

CRengine's reflow cache reset. KOReader exposes it via per-document
helpers when a property change requires re-tessellation.

Plugin does NOT call this directly. The plugin listens for the
*events* KOReader fires after `_callCacheReset` runs (see §5).

## 4.2 Reader / view layer

Owner: `ReaderRolling` (EPUB), `ReaderPaging` (PDF), and the
`ReaderUI` shell. None of these have stable line numbers across
KOReader versions; the call surface is what matters.

### 4.2.a `reader:getCurrentPage()`

Returns the 1-based current page number.

- KSQ-2 finding (pdfdocument FKS 62b9061a): this method does NOT
  exist on `PdfDocument`. It lives on the reader/view layer. For
  EPUB the call is on `ReaderRolling`; for PDF it is on
  `ReaderPaging`.
- KOReader exposes the active reader through `self.ui` on a plugin
  instance, so `self.ui.rolling:getCurrentPage()` /
  `self.ui.paging:getCurrentPage()` are the in-plugin call shapes.

Plugin call sites:

- `Pencil:getCurrentPage()` at `main.lua:3171` — the canonical
  in-plugin helper. Wraps the underlying reader call and returns
  the integer.
- `PdfAnchor.compute(reader, stroke_bbox)` in `lib/pdf_anchor.lua`
  — `pcall`-wraps the call so a missing method or runtime
  exception yields nil instead of crashing the capture site.

### 4.2.b `self.ui.doc_settings`

Per-document persistent settings (the sidecar `metadata.epub.lua`
file). The plugin reads `doc_settings.doc_sidecar_dir` in
`getStrokesFilePath()` (`main.lua:4649`) to anchor its own strokes
file inside the same dir.

### 4.2.c `self.ui:registerPostInitCallback` and friends

Used during `Pencil:init` (`main.lua:206`) to schedule the stylus
input takeover after the reader has finished its own init pass. No
arguments; the callback receives no parameters.

## 4.3 PDF / koptinterface

Owner: `frontend/document/pdfdocument.lua` and
`frontend/document/koptinterface.lua` (FKSes 62b9061a and the
KSQ-5 panel context).

### 4.3.a `koptinterface.getWordFromPosition(doc, pos)`

PDF analogue of credocument's word lookup.

- Returns `{ word, pbox = {x,y,w,h}, sbox = {x,y,w,h}, pos =
  {x,y,page} }` or nil. Note PDF version has BOTH `pbox` (page
  coords) and `sbox` (screen coords); credocument has only `sbox`.

Not used by Goal-3 directly. PDF strokes do not text-pin.

### 4.3.b `koptinterface.getTextFromPositions(doc, pos0, pos1)`

PDF range-text lookup. Returns `{ text, pboxes, sboxes, pos0, pos1
}` or nil.

Not used by Goal-3.

### 4.3.c `koptinterface.getPageBoxesFromPositions(doc, pageno, ppos0, ppos1)`

PDF per-page bbox enumeration. Returns a table list `{ boxes =
{...} }` of `{x,y,w,h}` rects, or nil.

Not used by Goal-3. PDF strokes capture their own bbox at draw
time; no text-line resolution.

### 4.3.d PDF current-page

There is no PDF-layer current-page accessor. KSQ-2 confirmed: the
reader/view layer (ReaderPaging) owns it. See §4.2.a.

## 4.4 Input layer

Owner: `frontend/device/input.lua` (FKS 7a516b9a) and the
device-specific Kobo / reMarkable input modules.

### 4.4.a `pen_slot` event payload

Each stylus contact produces a stream of slot events with payload:

```lua
slot = {
  id     = <int>,                    -- contact id (resets on lift)
  x      = <int>,                    -- screen pixel x
  y      = <int>,                    -- screen pixel y
  tool   = <int>,                    -- 1 = TOOL_TYPE_STYLUS
                                     -- 2 = TOOL_TYPE_ERASER
                                     -- 4 = TOOL_TYPE_HIGHLIGHTER
  pressure = <int>?,                 -- present on Kobo Elipsa /
                                     -- Sage; absent on devices
                                     -- without pressure-sensitive
                                     -- digitizers
}
```

Plugin call site:

- `Pencil:handleStylusSlot(input, slot)` at `main.lua:442` — every
  per-slot tick lands here. The constants `TOOL_TYPE_HIGHLIGHTER =
  4` and `TOOL_TYPE_ERASER = 2` are defined locally in the
  handler.

### 4.4.b `BTN_TOOL_RUBBER`

Kernel-level button event signalling the stylus eraser end is in
contact. The plugin receives it via the slot's `tool` field
(`slot.tool == TOOL_TYPE_ERASER`).

KSQ-4 finding (input-pen FKS 7a516b9a): KOReader's `input.lua`
does NOT distinguish a brief TAP from a sustained DRAG for
`BTN_TOOL_RUBBER`. All eraser events route identically. The
plugin computes the distinction itself — see
`lib/eraser_tap.lua:classify` and §6.

### 4.4.c `BTN_STYLUS2`

Side-button on the Kobo stylus, used by the plugin as a tool-swap
trigger.

Plugin call sites:

- `Pencil:onStylusButtonPress` at `main.lua:1731` (handles the
  press).
- `Pencil:onStylusButtonRelease` at `main.lua:1741` (handles the
  release).
- `Pencil:setSideButtonDown(down, source)` at `main.lua:1704`
  (state-machine helper).

The "tap to toggle pen/eraser" half of the side-button workflow
is wired through `Pencil:togglePenEraser()` at `main.lua:1765`.

## 4.5 KOReader subsystems

### 4.5.a `Dispatcher` (action registry)

`Dispatcher:registerAction` in `Pencil:init` registers
`pencil_toggle_tool`, `pencil_toggle_enabled`, `pencil_select_pen`,
`pencil_select_eraser`, and `pencil_undo` for binding via the
reader's gesture-manager / quick-menu. Cited at
`main.lua:305-335` (the full five-action registration block).

### 4.5.b `UIManager` (UI event loop)

The plugin uses `UIManager:schedule(seconds, callback)` for:

- The Goal-3 cluster-close timer (`_resetClusterCloseTimer` at
  `main.lua:948`). Each new pen-DOWN cancels the previous schedule
  and installs a new one.
- The Goal-2 deferred save (`scheduleDeferredWork` at
  `main.lua:2097`).
- The image-capture debounce (`scheduleGroupImageCapture` at
  `main.lua:3706`).
- The color-picker reset window
  (`scheduleColorPickerCheck` at `main.lua:2163`).

Cancellation is `UIManager:unschedule(handle)` and is paired with
each `schedule` site so a teardown does not leak.

### 4.5.c `ReaderUI` events

Every `Pencil:on<EventName>` method (`main.lua:2045-3170` and the
reflow handlers `4880-4985`) is dispatched by KOReader's event
broker. See §5 for the reflow / page-turn event list.

### 4.5.d `Bookmark` / `ReaderBookmark`

`Pencil:installBookmarkHook` at `main.lua:4012` and
`syncAllBookmarks` at `main.lua:3526` keep one bookmark per
annotation group in sync, anchored by the group's bookmark
xpointer.

### 4.5.e `Blitbuffer`

The actual draw primitives (rectangles, lines, glyphs) land on
`bb` (a `Blitbuffer` instance) inside `paintTo` at
`main.lua:4421`. The `lib/` modules never touch Blitbuffer
directly — they emit ordered render-op lists that the caller
executes.

## 4.6 `dump` (state serializer)

`require("dump")` returns a function that pretty-prints a Lua
value as a Lua literal. The plugin uses it once, in
`saveStrokes` at `main.lua:4807`, to produce the strokes-file
body. `lib/annotation_persistence.lua` provides a
busted-compatible re-implementation covering the data subset the
plugin persists (no functions / userdata / threads) so the
spec environment can round-trip without `dump`.
