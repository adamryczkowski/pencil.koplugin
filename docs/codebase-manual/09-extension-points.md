# §9 Extension points

This section is the maintainer's guide for adding features without
breaking the four-value dispatcher, the earned-paths invariants, or
the on-disk schema compatibility. Each subsection is one extension
scenario with the concrete file changes, the spec-coverage
expectations, and the migration risks.

## 9.1 Adding a new annotation type

Scenario: the user wants a new annotation primitive (e.g. a
hand-drawn arrow with a typed label, or a sticky-note-style text
annotation).

Touch points:

1. **Schema** — extend
   [`§3.4`](03-data-model.md#34-the-four-value-anchortype-dispatcher)
   with a new `anchor.type` value (let's call it `"sticky"` for
   illustration). The dispatcher table in
   `lib/anchor_constants.lua` lines 32-51 and
   `lib/stroke_anchor.lua` header MUST be updated in lockstep.
2. **Persistence** — `spec/annotation_persistence_spec.lua`
   PER3-3 fixture MUST grow a fifth variant covering the new
   `anchor.type`. Round-trip is automatic (the serializer is
   data-driven) but the spec assertion needs to know the new
   shape.
3. **Paint** — `lib/stroke_paint.lua` `paint_anchor_group` gets
   a new branch:

   ```lua
   if atype == "sticky" then
     -- emit per-type render ops
     return ops
   end
   ```

   Render ops for the new type MUST slot into the LOCKED
   ordering (`highlight_underline < connector < stroke <
   exclamation < badge`). Adding a new op type (e.g.
   `"sticky_body"`) requires extending the ordering invariant in
   `lib/stroke_paint.lua:118-119` (the `paint_anchor_group`
   header block) and adjusting `spec/stroke_paint_anchor_spec.lua`
   to test the new ordering.
4. **Stale-rotation filter** — the stale-rotation filter inside
   `paintTo` (approximately `main.lua:4446-4491`) gained a
   `g3_typed` type-guard at SHA `72d6920` (G3-M8.5); see
   [§5.4](05-reflow.md#54-the-stale-rotation-filter-goal-2-earned-path).
   Adding a new annotation type that should bypass the filter
   means extending the `g3_typed` expression to include the new
   `anchor.type`:

   ```lua
   if group.anchor and (group.anchor.type == "explicit"
                     or group.anchor.type == "pdf_page"
                     or group.anchor.type == "sticky") then
     goto skip_stale_filter
   end
   ```

   Document in the commit why the new type is included
   (typically: "the new type has its own anchor resolution that
   does not require the rotation short-circuit").
5. **Capture site** — wire the new capture path in
   `_onClusterCloseTimeout` (`main.lua:970`) or wherever the new
   type is generated.

Specs required: 4 minimum (capture round-trip, paint dispatch,
persistence round-trip, integration wiring).

Migration: existing saves are unaffected — a missing `anchor.type`
defaults to nil (rotation-badge EARNED), and unknown types fall
through to the empty-op-list branch in `paint_anchor_group`. No
on-disk schema bump needed unless the new type stores fields the
serializer cannot handle (functions, userdata, threads — all
forbidden by the persistence module).

## 9.2 Adding a new format-dispatch entry

Scenario: KOReader gains a new document format (e.g. fixed-layout
EPUB, CBZ, MOBI) that needs its own anchor strategy.

The current dispatch fork is EPUB vs PDF, decided in
`_onClusterCloseTimeout` (`main.lua:970`) by checking
`self.ui.document.is_pic` / the koptinterface presence /
`self.ui.rolling` vs `self.ui.paging`.

Steps:

1. **Identify the format probe** — KOReader exposes
   `self.ui.document.file` (path), `self.ui.document.koptinterface`
   (presence indicates PDF or DJVU), and various class predicates.
   Pick the smallest probe that uniquely identifies the new
   format.
2. **Add a new lib module** — by convention,
   `lib/<format>_anchor.lua` with `compute(reader, …)` and
   `should_render(group, …)` mirroring
   [`lib/pdf_anchor.lua`](../../pencil.koplugin/lib/pdf_anchor.lua).
3. **Wire the dispatch** — in `_onClusterCloseTimeout`, add the
   new format branch BEFORE the catch-all EPUB branch (PDF is
   currently caught by koptinterface presence; new formats are
   typically more specific).
4. **Capture-time field** — add a new `anchor.type` value (e.g.
   `"djvu_page"`) per §9.1.
5. **Update the manual** — every section that talks about
   format-specific behavior MUST mention the new format
   (discipline rule #5: silence on a format is a defect).

Specs required: one per public `lib/<format>_anchor.lua`
function (typically 3-4: compute happy path, compute defensive
nil, should_render true, should_render false).

## 9.3 Modifying the anchor schema (with version migration)

Scenario: an existing `anchor.type` needs new fields or different
field semantics.

The on-disk envelope is `{ version = 3, strokes, annotation_groups
}`. The version field is the migration knob:

1. **Bump the version** — `saveStrokes` (at `main.lua:4765`)
   writes the `version = 3` literal (at `main.lua:4800`). A new
   schema bumps to 4.
2. **Add a migration function** — `loadStrokes` at
   `main.lua:4663` currently normalizes pre-Goal-2 saves (no
   `annotation_groups` field) up to the current shape; the same
   pattern applies to a v3→v4 migration. The migration runs once
   on load and is idempotent (re-running it on an already-v4 save
   is a no-op).
3. **Spec the migration** — add a PER3-N spec that loads a
   fixture v3 save and asserts the v4 shape after migration. Add
   another PER3-N+1 spec that round-trips a v4 save unchanged.
4. **Document the migration** — update
   [`§3.4`](03-data-model.md#34-the-four-value-anchortype-dispatcher)
   with the new fields and a note on the version bump.

Migration risks:

- **Forward compatibility**: a user who downgrades the plugin
  AFTER a v4 save MUST not lose data. The recommended pattern is
  to keep the v3 fields populated alongside the new v4 fields so
  the older `loadStrokes` ignores the new fields and recovers
  the v3 shape. Drop v3 fields only when v3 is no longer
  supported.
- **Backward compatibility**: a v3 file must keep loading after
  the v4 bump. The migration function MUST handle the v3 → v4
  case.
- **Mock churn**: every spec mock that hand-constructs an
  `anchor` table MUST be updated. The `spec/annotation_persistence_spec.lua`
  PER3-3 fixture is the canonical "all four (or N) anchor types"
  reference and should be updated first.

## 9.4 Adding a new constant

Scenario: a new tuning knob is needed (e.g. a new hit-target
constant for a new gesture).

Hard-constraint #5 (from Goal-3 brief): all named constants live
in `lib/anchor_constants.lua`. No inline numeric literals at
paint sites.

Steps:

1. Add the constant to `lib/anchor_constants.lua` with a doc
   comment explaining the rationale (units, default value, the
   knob's user-visible effect).
2. Add a row to the §1.7 UX Constants Table in
   `AI-docs/annotation-text-anchoring/goal-3-plan.md` if the
   constant belongs to Goal-3.
3. Require `AnchorConstants` in the lib module that consumes
   the constant. Use the named field, never the literal.
4. Specs MAY reference the constant by name (e.g. `local TAP_MAX
   = AnchorConstants.ERASE_TAP_MAX_DISTANCE_PX`) so spec values
   move in lockstep with the constant.

## 9.5 Adding a new render-op type

Scenario: a new visual primitive (e.g. a highlight glow, a
fade-in animation marker).

The render-op list is consumed by `paintTo` at `main.lua:4421`.
Each op has a `type` field and op-specific data.

Steps:

1. Define the new op shape (e.g. `{ type = "glow", group, radius,
   alpha }`).
2. Decide its place in the LOCKED ordering. The current order is
   `highlight_underline < connector < stroke < exclamation <
   badge`. The new op MUST slot somewhere; document the choice
   in `lib/stroke_paint.lua:118-119` (the `paint_anchor_group`
   header block) and update the ordering invariant.
3. Add the op emission in `lib/stroke_paint.lua`
   `paint_anchor_group`.
4. Add the executor in `main.lua` `paintTo` (the actual draw
   calls).
5. Spec the new op:
   - In `spec/stroke_paint_anchor_spec.lua` PT-N: assert the
     op is emitted (or NOT emitted) in the expected scenarios.
   - In `spec/stroke_paint_anchor_spec.lua` PT-M: assert the
     ordering invariant still holds with the new op in the mix.

## 9.6 Future tightening (known refactor candidates)

Not blocking the current release, but worth recording:

1. **Per-point timestamps for cluster-close**. The current
   `CLUSTER_CLOSE_TIMEOUT_MS = 1200 ms` timer fires from the
   last pen-DOWN; a stroke that takes longer than 1200 ms to
   draw may close the cluster mid-stroke (see [§6.1.a](
   06-explicit-anchoring.md#61a-known-edge-case-cluster-close-mid-stroke)).
   Per-point timestamps would let the timer fire from pen-UP
   instead. Blocking: KOReader's input layer does not currently
   expose them (KS fb895d30).

2. **PDF page capture at pen-DOWN, not at cluster-close**. The
   current `PdfAnchor.compute` calls `reader:getCurrentPage()`
   at cluster-close (1200 ms after the last pen-DOWN). If the
   user pages away during that window, the anchor pins to the
   wrong page (see [§6.6 Known UX limitations](
   06-explicit-anchoring.md#known-ux-limitations) item 3). Fix
   is to capture the page at the first pen-DOWN of the cluster
   and carry it through to the close.

3. **Free-spot history LRU**. `FREE_SPOT_HISTORY_CAP = 1` is a
   single-entry cache replaced unconditionally on layout-key
   change (per simplicity-critic C-4). When the user reflows
   back and forth across two known layouts, the cache thrashes.
   An LRU of N=4 would amortize the recompute cost. Not
   blocking; performance has not been a complaint.

4. **PDF auto-layout (free-spot for PDF)**. PDF currently
   anchors strokes to their saved pixel coordinates with no
   displacement. A future feature could offer the same L2
   margin-preference / L4 in-text fallback as EPUB, using the
   PDF's page-bbox boundaries instead of `text_line_bboxes`.

5. **Eraser TAP threshold per-device**. `ERASE_TAP_MAX_DISTANCE_PX
   = 10` is a single global. A per-device override (e.g. via the
   plugin settings menu) would help users on lower-DPI
   digitizers. Not blocking; the constant is tunable in
   `lib/anchor_constants.lua` for the determined user.

6. **Manual-anchor exclamation auto-dismiss**. Per [§6.6 Known
   UX limitations](06-explicit-anchoring.md#known-ux-limitations)
   item 6, the exclamation glyph never times out. A 30 s
   auto-dismiss to "orphan" would simplify the UX, at the cost
   of accidentally orphaning slow-thinking users. Trade-off,
   not a fix.

7. **Exclamation hue from lib emit**. The G3-M8.5 executor
   `Pencil:_drawAnchorExclamation` (`main.lua`) hardcodes the
   indigo `{75, 0, 130}` hue because
   `lib/stroke_paint.lua`'s `paint_anchor_group` does not
   currently populate `op.hue` for `exclamation` ops (it does
   populate `op.hue` for `highlight_underline` and `connector`
   ops). The migration is two changes:
   - Extend `paint_anchor_group` (in `lib/stroke_paint.lua`) to
     emit `hue = AnchorConstants.ANCHOR_UNDERLINE_HUE` on the
     exclamation op (single visual family — same indigo as the
     underline + connector — per
     [§6.3](06-explicit-anchoring.md#63-anchor-highlight--connector-g3-3)).
   - Strip the hardcoded `{75, 0, 130}` from
     `Pencil:_drawAnchorExclamation` and consume the new
     `op.hue` field instead.
   Currently hardcoded because the M8.5 scope was bounded to
   wire the dispatch, not to extend the lib emit shape.

8. **Pulse animation in exclamation glyph**. The G3-M8.5
   executor `Pencil:_drawAnchorExclamation` accepts a `pulse`
   argument (emitted by `paint_anchor_group` as
   `op.pulse = false` for the steady-state exclamation, per
   `EXCLAMATION_PULSE_DURATION_MS = 300 ms` in
   `lib/anchor_constants.lua`) but the executor currently
   renders only the static glyph — the `pulse` flag is
   accepted and discarded. Animating the one-shot first-paint
   pulse means scheduling a `UIManager:scheduleIn(0.3, …)` from
   the executor when `pulse == true` and triggering a
   repaint at the end. The animation is a follow-up because:
   - `UIManager:scheduleIn` from inside a paint pass adds an
     execution-order subtlety (the schedule fires AFTER the
     current paint completes, so the pulse must be encoded as
     a state field on the group that the next paint reads).
   - The static glyph is functionally complete as a manual-
     anchor prompt; the pulse is a polish item.
   Currently a no-op because UIManager scheduling from inside
   the paint pass was deferred from M8.5 to keep the scope
   bounded to the dispatch wiring.
