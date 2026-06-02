# §8 Testing

The plugin has two distinct test surfaces: pure-Lua busted specs
under `spec/` and on-device manual tests under `manual-test/`.
Both are load-bearing — the Goal-2 mock-vs-prod disaster proved
that green specs alone do not guarantee a working pipeline.

## 8.1 busted specs

Layout: one spec file per `lib/` module, plus integration
specs that exercise cross-module wirings. All under
`/spec/` at the repository root (not under `pencil.koplugin/`).

Run with:

```
eval "$(luarocks --local path)" && busted
```

(or `just validate` — see the project `justfile`). The runner
must be installed via `luarocks --local install busted`. Lua
5.4 is the test environment.

Current count: **384 successes / 0 failures / 0 errors / 0
pending** at commit `72d6920` (Goal-3 G3-M8.5 PASS).

### 8.1.a Spec file ↔ module mapping

| Spec file                                | Module(s) under test                          |
| ---------------------------------------- | --------------------------------------------- |
| `spec/stroke_anchor_spec.lua`            | `lib/stroke_anchor.lua` (Goal-2 schema)       |
| `spec/stroke_capture_spec.lua`           | `lib/stroke_capture.lua`                      |
| `spec/stroke_paint_spec.lua`             | `lib/stroke_paint.lua` (Goal-2 paint surface) |
| `spec/stroke_paint_anchor_spec.lua`      | `lib/stroke_paint.lua` `paint_anchor_group` (Goal-3 PT-1..PT-8) |
| `spec/stroke_persist_spec.lua`           | Save/load round-trip (Goal-2)                 |
| `spec/stroke_ruby_spec.lua`              | Goal-1 ruby-text edge case                    |
| `spec/stroke_cluster_spec.lua`           | `lib/stroke_cluster.lua` (G3-M2 CL-1..CL-5)   |
| `spec/cluster_heuristic_spec.lua`        | `lib/cluster_heuristic.lua` (G3-M3 AH-1..AH-6) |
| `spec/manual_anchor_spec.lua`            | `lib/manual_anchor.lua` (G3-M4 MA-1..MA-6 + MA-LAT-1) |
| `spec/free_spot_spec.lua`                | `lib/free_spot.lua` (G3-M5a FS-1..FS-3, G3-M5b FS-4..FS-6) |
| `spec/eraser_tap_spec.lua`               | `lib/eraser_tap.lua` (G3-M6 ER-1..ER-4)       |
| `spec/annotation_persistence_spec.lua`   | `lib/annotation_persistence.lua` (G3-M6 PER3-1..PER3-5) |
| `spec/pdf_anchor_spec.lua`               | `lib/pdf_anchor.lua` (G3-M7 PA-1..PA-4)       |
| `spec/g3_wiring_spec.lua`                | Cross-cutting Goal-3 main.lua wiring (G3-M4 WR-1..WR-3 reflow / G3-M8.5 WR-1..WR-6 paintTo dispatch) |
| `spec/annotation_groups_spec.lua`        | Goal-2 group-rebuild logic                    |
| `spec/erase_spec.lua`                    | Pre-Goal-3 eraser drag path                   |
| `spec/eraser_button_spec.lua`            | Hardware eraser-button state machine          |
| `spec/pen_width_spec.lua`                | Goal-1 pen-width settings                     |
| `spec/color_spec.lua`                    | Goal-1 9-color palette + Blitbuffer wiring    |
| `spec/geometry_spec.lua`                 | `lib/geometry.lua` (pre-Goal-3 helpers)       |
| `spec/toggle_spec.lua`                   | Goal-1 pen/eraser toggle event chain          |
| `spec/pencil_text_highlight_*_spec.lua`  | Goal-1 text-highlight extract / paint / persistence pipeline (10 files) |

### 8.1.b Mock-shape discipline

The Goal-2 disaster shipped 26 green specs because the mocks
named the wrong fields. The discipline now in force:

1. **Every CRengine mock derives its shape from real source.**
   `doc:getScreenPositionFromXPointer(xp)` returns `screen_y,
   screen_x` (y-first) — see [§4.1.a](04-koreader-integration.md#41a-docgetscreenpositionfromxpointerxp).
   `doc:getWordFromPosition(pos)` returns `{ word, sbox = {…},
   pos = {…} }` — the bbox is `sbox`, NOT `pos`.
2. **Every spec file documents the mock origin in its header.**
   Look for the `-- mock derived from credocument.lua per
   KS a43eb8db` comment block or equivalent.
3. **Specs that exercise lib modules MUST NOT require('main').**
   The lib modules are pure Lua by design; pulling main.lua into
   the spec environment hides integration bugs (e.g. Blitbuffer
   was nil, UIManager was nil → spec passed against a wrong
   surface).
4. **Integration specs use the inline-mock + source-grep
   pattern.** `spec/g3_wiring_spec.lua` is the canonical example:
   it reads `main.lua` as text via `io.open`, strips comments with
   a small helper, and `grep`s for the required wiring strings
   (e.g. `self:_clearPaintMemos()` inside `onDocumentRerendered`).
   No `require('main')`; no Blitbuffer mock; no UIManager mock.

### 8.1.c Adding a new spec

Recipe:

1. Create `spec/<module_name>_spec.lua`.
2. Top of file: `package.path = package.path ..
   ";pencil.koplugin/?.lua"`.
3. Require the module under test.
4. Header comment block documenting:
   - Which plan section / milestone the spec corresponds to.
   - The mock-shape origin (file path + KS / FKS id where
     applicable).
   - How to run (`busted spec/<file>.lua`).
5. `describe` blocks per public function, `it` blocks per
   spec tag (e.g. `G3-FS-1`).
6. Run `busted` to confirm the new spec is picked up and the
   count matches the milestone's expected delta.

## 8.2 On-device manual tests

Layout: `manual-test/` at the repository root.

- `manual-test/PLAYBOOK.md` — the user-facing walkthrough.
  Sequenced steps that exercise every annotation lifecycle path
  on a real Kobo device. Goal-3 acceptance includes the "WRONG!
  + arrow + L03 circle" multi-stroke EPUB cluster test (clean
  strike + arrow + line-03 circle) plus the matching PDF page
  annotation. Rotation, font change, eraser-tap, eraser-drag,
  reload are each separate steps.
- `manual-test/RUNNER.md` — orchestration notes for running the
  PLAYBOOK against a connected Kobo device (USB mount + SSH).
- `manual-test/SSH-SCREENSHOT.md` — the operator-on-call SSH
  workflow (`fb0` capture + `convert` to PNG) used to produce
  evidence screenshots for DoD validation.

The on-device tests are the only place that catch
device-render bugs (e.g. Kaleido 3 hue collapse — see
[§6.6 Known UX limitations](06-explicit-anchoring.md#known-ux-limitations)).
Spec coverage cannot reach the e-ink renderer.

### 8.2.a When to run manual tests

- Before any commit that touches `main.lua` paint or persistence
  paths.
- Before any commit that adds a new render-op type or changes the
  LOCKED ordering.
- Before promoting a new feature past its plan's DoD #N
  ("operator-on-call SSH validation") checkpoint.
- After any change to `lib/anchor_constants.lua` hue or pixel
  values.

Spec changes alone do NOT require an on-device pass — the busted
suite is the gate for pure-Lua changes.

## 8.3 The describe-to-test loop

This manual itself is a test artefact. The Phase-9 "describe
to test" pass exists because writing the manual forces the author
to look at the real function signatures and the real data flow,
which surfaces shape mismatches that the mocks let through.

Concretely: while writing [§3](03-data-model.md) and
[§4](04-koreader-integration.md), the author MUST verify each
cited field name against the real source. The
file-knowledge-agent snapshots (FKSes a43eb8db, 62b9061a,
7a516b9a) are the canonical references for the CRengine,
pdfdocument, and input.lua sources respectively.

If the manual disagrees with a spec mock, the manual is canonical
(discipline rule #2 — see [README §discipline rules](README.md#discipline-rules-in-force)).
The disagreement is a defect to fix in the mock; the manual
documents the right shape and the spec is updated to match.

## 8.4 Coverage gaps

The current spec suite covers:

- Every `lib/` module's public API.
- The four-value `anchor.type` dispatcher in
  `spec/stroke_paint_anchor_spec.lua` and
  `spec/annotation_persistence_spec.lua` (PER3-3 round-trips all
  four variants).
- The Goal-3 main.lua wiring requirements
  (`spec/g3_wiring_spec.lua` G3-M4 WR-1..WR-3 + G3-M8.5 WR-1..WR-6).

The current spec suite does NOT cover:

- The actual Blitbuffer draw calls. The render-op model
  intentionally decouples the op list from the executor so
  busted does not need a Blitbuffer mock; the trade-off is that
  draw correctness is on the on-device manual tests.
- The UIManager scheduler. Timer behavior (cluster-close,
  debounced save, color-picker check) is tested by reading the
  main.lua source for the `UIManager:schedule(...)` call sites
  with the correct argument; the actual timing is on the
  manual tests.
- The input thread. Stylus and eraser input is a kernel-level
  event stream that no Lua mock can faithfully reproduce; on
  device only.

These gaps are the on-device manual tests' job and are listed
explicitly so future maintainers do not assume green busted ==
green pipeline.
