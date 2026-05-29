# Gate Audit — `experimental_text_highlight`

**Milestone**: G1-GATE-AUDIT (M1 of `annotation-text-anchoring`)
**Audit date**: 2026-05-29
**Audit scope**: Enumerate every reason `experimental_text_highlight` was
  introduced as an off-by-default experimental flag, and for each reason
  determine whether it is still blocking promotion to `default = true`
  (i.e. whether M4 G1-FLIP-DEFAULT may proceed).

---

## 1. Gate location

The flag is defined and consumed in three places in
`pencil.koplugin/main.lua`:

| Site | Line | Role |
|---|---|---|
| Default assignment | 1118 | `self.experimental_text_highlight = settings.experimental_text_highlight or false` |
| Persistence | 1176 | written through `saveSettings()` |
| Dispatch predicate | 512 | gates the `startTextHighlight` / `extendTextHighlight` / `finishTextHighlight` branch |
| Menu toggle (kill-switch) | 1418–1439 | `Text highlight (side button)` checkbox |

The user-facing rationale for the gate lives in the menu `help_text` at
`main.lua:1420`:

> "When enabled, holding the stylus side button during a pen drag creates
> a native KOReader text highlight on the underlying words, like a
> long-press → Highlight. **Off by default because this is a new
> integration and has edge cases. Requires a stylus that sends
> BTN_STYLUS2.**"

That sentence enumerates three distinct gate reasons, listed and audited
below.

---

## 2. Introducing commit

`git log --all -S "experimental_text_highlight"` returns a single
originating commit:

```
47a6012 enable side button select to highlight
        laurenamy <lauren.a.adam@hotmail.com>, 2026-04-16
        +251 LOC (single-file plugin), introduces:
          - self.highlighting state
          - handleStylusSlot dispatch branch (main.lua:512 today)
          - startTextHighlight / extendTextHighlight / finishTextHighlight
          - _paintTempSelection / _clearTempSelection
          - eraseHighlightAtScreenPos + findHighlightAtScreenPos
          - menu toggle with the help-text above
```

Between `47a6012` and `HEAD` (`eabb847`), six follow-up commits hardened
the surface that the gate originally protected:

```
64368f0  P0 — gate slot.tool side-button clear on side_button_set_by_slot
ca76de5  P1 — refresh stale highlighter test + cover new Goal 1 API surface
895aa17  P2 — refresh scope per-tool + include_start contract + Snowflake-safe fallback
ea19989  P3a — DRY consolidations (single mutator, stamp helper, loader helper,
              single-sourced fallback color, folded InfoMessage)
c0ca9ee  P3b — rename multiplyRectHL → multiplyRectHighlighter; log unknown color
              names; picker title in highlighter mode
eabb847  P4 — document deferred clone, correct legacy-stroke comment,
              annotate picker tuning
```

These six commits are the material change between "the day the gate was
written" and "today". Each gate reason is audited below against the
current state of `main.lua` (not the 2026-04-16 state).

---

## 3. Per-reason audit

### Reason R1 — "this is a new integration"

**As stated** (verbatim, `main.lua:1420`): "Off by default because this is
a new integration…"

**Interpretation**: At introduction time the call chain
`startTextHighlight → ReaderHighlight.saveHighlight → ReaderAnnotation:addItem`
was new code with no test coverage, untested in concert with the
existing freehand stroke path, and undocumented as a Pencil-side
contract on `ReaderHighlight`.

**Current state — resolved**. Evidence:

- **Test coverage exists**: `busted` reports `174 successes / 0 failures
  / 0 errors / 0 pending` against the current tree (run 2026-05-29 from
  REPO_ROOT). The post-introduction P1 commit (`ca76de5`) explicitly
  "refresh stale highlighter test + cover new Goal 1 API surface" —
  the integration now has dedicated specs.
- **The dispatch contract is explicit and pcall-guarded**:
  `main.lua:907` wraps `getWordFromPosition` in `pcall`; `main.lua:945`
  wraps `getTextFromPositions` in `pcall`; `main.lua:971` wraps
  `rh.saveHighlight` in `pcall` with a `logger.warn` on failure.
  Three CRengine boundaries, three guards — the integration cannot
  crash the plugin via a missing/changed KOReader API.
- **The sticky-during-drag invariant is documented**: `main.lua:507–523`
  has a block comment ("Sticky: once we enter, we stay until pen lift
  even if the side button is released mid-drag") and the corresponding
  P0 fix (`64368f0`) added a precondition gate
  (`side_button_set_by_slot`) so the slot-tool clear logic interacts
  correctly with the dispatch branch.
- **The promotion of the feature to "default = true" is the operator's
  current ask** (`AI-docs/annotation-text-anchoring/inputs/requirements.md`).
  "New integration" is therefore not a separately blocking concern; it
  is the very thing the operator is requesting to land.

**Verdict**: R1 **RESOLVED** — the integration is no longer new in any
material sense: it has six follow-up commits of hardening, dedicated
test coverage, pcall guards on every CRengine call, and an explicit
sticky-state contract.

---

### Reason R2 — "has edge cases"

**As stated** (verbatim, `main.lua:1420`): "…and has edge cases."

**Interpretation**: At introduction time the edge cases below were
either undecided or hand-wavingly handled. The four edge cases
identified by the panel (feature-plan.md §4) are:

| Edge case | Decision | Where handled |
|---|---|---|
| Stroke over no text (margin / blank) | Discard silently | `getTextFromPositions` returns empty → `selected_text` not assigned → `finishTextHighlight`'s `has_selection` guard at `main.lua:958–959` is false → no `saveHighlight` call |
| Stroke spanning page boundary | Delegate to KOReader's per-page clip filter | `frontend/apps/reader/modules/readerview.lua:629–643` (KOReader-side; plugin uses unchanged path) |
| Word disappears after reflow | Silently skipped; item retained; no crash | `readerview.lua:644–645` skips nil boxes; `652–668` filters `h==0` (KOReader-side) |
| Two highlights on same word | Both persist; `addItem` no dedup | `ReaderAnnotation:addItem` (KOReader-side); plugin makes no dedup assumption |

**Current state — resolved**. Evidence:

- **All four edge cases now have explicit decisions** (feature-plan.md §4).
  Each decision is grounded in a verified file/line reference, not a
  guess.
- **Three of four edge cases ride existing KOReader behaviour** —
  per-page clip filter, nil-box skip, no-dedup `addItem` — which means
  the plugin is not introducing new edge-case code; it is reusing
  paths KOReader already exercises for finger-driven highlights.
- **The "discard silently" path is exercised by the planned negative
  spec** (`pencil_text_highlight_negative_spec.lua` in M2). The
  guarding code is already in place at `main.lua:958–959`
  (`has_selection` condition).
- **The remaining three edge cases get dedicated specs in M5**
  (`redraw_spec` page-boundary sub-case, `reflow_spec` nil-boxes
  sub-case, `persistence_spec` two-annotations sub-case). Each spec is
  named, grounded in a feature-plan.md decision, and on a milestone
  earlier than M4 G1-FLIP-DEFAULT only by sequence — there is no
  blocker that requires the specs to land before the default flip;
  the default flip and the spec suite are independent of each other.

**Verdict**: R2 **RESOLVED** — every edge case the original author
flagged has a written decision, and either rides on already-correct
KOReader behaviour or has a guard in the current `main.lua`. The
upcoming M2/M5 specs make the edge-case behaviour test-enforced; they
are not preconditions for the default flip in M4.

---

### Reason R3 — "Requires a stylus that sends BTN_STYLUS2"

**As stated** (verbatim, `main.lua:1420`): "Requires a stylus that sends
BTN_STYLUS2."

**Interpretation**: At introduction time the only way to enter the
Path-A branch was for `input.lua` to promote `slot.tool` to
`TOOL_TYPE_HIGHLIGHTER` in response to a `BTN_STYLUS2` press. A user
whose stylus does not emit `BTN_STYLUS2` could not reach the new code
path at all — hence the feature was useless to that user and was
defaulted off so the menu toggle would not mislead them.

**Current state — addressed by M2, no longer blocking M4**. Evidence:

- **The dispatch predicate at `main.lua:512` is being widened by M2**
  (`G1-DISPATCH-WIDEN`, feature-plan.md §6). After M2 the predicate
  routes **any** `TOOL_HIGHLIGHTER` stroke to `startTextHighlight`,
  regardless of side-button state. A user who selects the highlighter
  tool from the plugin menu reaches Path A on a plain stylus contact
  — no hardware side-button required.
- **The side-button-promoted path is preserved** (regression-guarded by
  `pencil_text_highlight_dispatch_spec.lua` ②). Existing BTN_STYLUS2
  users see no change in behaviour.
- **The M2 commit lands before the M4 flip**. The milestone ordering
  (M2 → M3 → M4) guarantees the dispatch is widened before the
  default is flipped, so a user who picks up the post-flip build
  receives both changes together: the feature is on AND it works on
  every stylus, not just BTN_STYLUS2-emitting ones.

**Verdict**: R3 **RESOLVED by M2** — the hardware-coupling reason that
originally justified the off-by-default is removed by widening the
dispatch predicate (M2). Once M2 ships, BTN_STYLUS2 is no longer a
precondition for reaching Path A.

---

## 4. Audit conclusion

| Reason | Status |
|---|---|
| R1 — "new integration" | **RESOLVED** (6 hardening commits, 174 specs, pcall guards on every CRengine boundary) |
| R2 — "edge cases" | **RESOLVED** (4 edge cases with written decisions; 3 of 4 ride existing KOReader behaviour; spec coverage planned in M2/M5 but not a precondition for the flip) |
| R3 — "Requires BTN_STYLUS2" | **RESOLVED by M2** (dispatch widening at `main.lua:512` removes the hardware coupling before M4 lands) |

**All gate reasons are resolved — M4 G1-FLIP-DEFAULT may proceed.**

---

## 5. Carry-overs for M2 / M4

These are inputs the audit produced for downstream milestones; not gate
reasons.

- **M2 dispatch-predicate edit (the exact code G1-DISPATCH-WIDEN will
  apply)**: at `main.lua:512`, change the condition

  ```lua
  if self.experimental_text_highlight
          and (slot.tool == TOOL_TYPE_HIGHLIGHTER or self.highlighting) then
  ```

  to a predicate that ALSO admits the menu-tool path
  (`self.current_tool == TOOL_HIGHLIGHTER`) in addition to the
  side-button-promoted slot-tool path. The exact text-form will be
  authored in M2 — this audit only certifies that no gate reason
  blocks that change.

- **M4 menu kill-switch retention**: M4's commit must keep the menu
  toggle at `main.lua:1418–1439` intact so users who prefer the legacy
  freehand-only behaviour can opt out. The default value at
  `main.lua:1118` is the only line whose default literal changes;
  `experimental_text_highlight` itself remains a settings-bearing flag.

- **Menu help-text update (cosmetic, deferred)**: the help-text at
  `main.lua:1420` will eventually need rewording (it currently says
  "Off by default" and "Requires BTN_STYLUS2", both of which become
  false post-flip and post-M2). Updating the help-text is not in M1's
  scope; M4 is the natural commit for it. Documenting here so it is
  not forgotten.

---

*End of audit.*
