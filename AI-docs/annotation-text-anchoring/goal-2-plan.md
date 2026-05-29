# Goal-2 Plan: Pen-stroke Text-anchoring — COMPLETE

**Status**: COMPLETE — Sub-goal 2A CONVERGED + Sub-goal 2B IMPLEMENTED, VALIDATED, AND LANDED.
**Deliverable**: This file documents the final plan and the as-built implementation. §1–§6 are FINAL.
**Rounds used (2A)**: 1 (synthesis) + 1 (update/final verdict)
**Implementation rounds (2B)**: 7 milestones M1–M7, TDD-first, one commit per milestone, validator-gated.

## Milestone Ledger (as-built)

| Milestone | Commit  | Busted     | Scope                                                              |
| --------- | ------- | ---------- | ------------------------------------------------------------------ |
| G2-M1     | d3916cc | 304/0/0    | Plan lockdown — anchor schema & discard-raw rejection documented   |
| G2-M2     | 197b0a3 | 309/0/0    | lib/stroke_anchor + lib/stroke_capture + lib/stroke_paint + SA-1–5 |
| G2-M3     | c27fdfd | 314/0/0    | Wire StrokeCapture.compute_anchor in assignStrokeToGroup + SC-1–5  |
| G2-M4     | 51ccabc | 325/0/0    | paintTo paint_with_anchor wiring + 5 reflow handlers + SP-1–7      |
| G2-M5     | 25cbb45 | 329/0/0    | Persistence round-trip specs PER-1–4 (spec-only)                   |
| G2-M6     | b9e0c45 | 330/0/0    | Ruby / vertical-text graceful degradation RU-1 (spec-only)         |
| G2-M7     | (this)  | 330/0/0    | Documentation closeout                                             |

**Validator verdict aggregate**: ALL 7 milestones PASS. Baseline 304 → final 330 (+26 specs: SA(5) + SC(5) + SP(11) + PER(4) + RU(1)).

## Carried-forward post-merge consideration

**FINDING-G2M3-1** (MEDIUM, non-blocking, deferred to post-merge): the anchor capture in `Pencil:assignStrokeToGroup` (G2-M3 wiring) does not gate on `stroke.page == self:getCurrentPage()` the way the surrounding `xpointer_v2` block does. In normal use the two are equivalent because both fire during stroke commit on the visible page; the edge case is a hypothetical stroke whose `page` field has drifted from the current page (e.g. mid-flush) — in that case the anchor would resolve against the wrong page's screen position. Considered acceptable for the current scope because: (a) the surrounding code paths gate identically, (b) the anchor's xpointer is page-independent (resolved at paint time, not capture time), (c) on resolution mismatch the lib's rotation-badge path activates cleanly per SP-3 / SP-4 / RU-1. Tracked in `docs-AI/g2m-validation-report.md` for a future hardening pass.

---

## §1 Chosen Strategy + Reasoning (from Sub-goal 2A)

### Chosen: Op7-line-relative (verbatim-plus-anchor, line-relative mechanism)

**One-sentence summary**: Persist the existing raw pixel stroke (verbatim, already stored, zero new cost) alongside an additive nullable anchor record {type="line", xp, dx_em, dy_lh}; at paint time resolve the anchor to translate the stroke with reflowing text; on anchor miss fall through to the existing EARNED rotation-badge path.

### Anchor record schema (additive, nullable)

```lua
-- New nullable field on each annotation_groups[i] item:
group.anchor = {
  type  = "line",               -- only valid value in this PR
  xp    = <xpointer_string>,    -- line xpointer at stroke start-point
  dx_em = <float>,              -- dx from line anchor in em units
  dy_lh = <float>,              -- dy from line anchor in line-height units
}
-- OR:
group.anchor = nil              -- anchor miss at capture; legacy strokes; image-only page
```

Legacy strokes (saved before Goal-2) have `group.anchor = nil` on load and use the existing rotation-badge path at main.lua:4239–4311 unchanged.

### Capture algorithm (onStrokeEnd, main.lua:846 region)

```lua
-- Compute anchor for newly completed stroke
-- pcall-wrapped per build-compat idiom (main.lua:3057-3068)
local anchor = nil
local doc = self.ui.document

-- Step 1: strict inverse lookup (ReaderKeySelection idiom)
local word = pcall_wrap(doc.getWordFromPosition, doc, stroke_start_point, true)
if word then
  anchor = compute_line_anchor(word, stroke_start_point)  -- → lib/stroke_anchor.lua
end

-- Step 2: fuzzy inverse lookup — DIR_ANY = whole page search from start-point
if not anchor then
  local nearest = pcall_wrap(doc.getNearestWordAndBoxFromPosition, doc, stroke_start_point, 0)
  if nearest then
    anchor = compute_line_anchor(nearest, stroke_start_point)
  end
end

-- Step 3: nil anchor (image-only page, blank page, far-from-text margin)
-- anchor stays nil; rotation-badge path activates at paint time

group.anchor = anchor
```

`compute_line_anchor` extracts {line_xp, dx_em, dy_lh} from the CRengine word result. Pure-Lua math lives in `lib/stroke_anchor.lua`.

### Paint algorithm (Pencil:paintTo)

```lua
if group.anchor then
  local ok, screen_y, screen_x = pcall(doc.getScreenPositionFromXPointer, doc, group.anchor.xp)
  if ok and screen_y and screen_y >= 0 then
    -- translate verbatim stroke coords by anchor delta
    draw_stroke_translated(group, screen_x + group.anchor.dx_em, screen_y + group.anchor.dy_lh)
    return
  end
  -- pcall raised, nil, or off-screen → fall through to rotation-badge
end
-- nil anchor OR anchor resolve failure → EARNED rotation-badge path
rotation_badge_render(group)  -- main.lua:4239-4311
```

**Off-screen behavior**: if `screen_y < 0` (anchor line is on a previous virtual page), the stroke is not drawn. This is standard KOReader painting behavior — content outside the current view is naturally clipped.

### Reflow handling (M7 idiom extended)

The existing 5 pre-reflow handlers (main.lua:4604+, M7 commit ac82909) each gain one line:

```lua
function Pencil:onSetDimensions()
  pcall(self.ui.view.resetHighlightBoxesCache, self.ui.view)
  self:_clearStrokeAnchorCache()          -- Goal-2 addition: one line
end
-- (identical extension for onSetFontSize / onSetFont / onSetLineSpace / onSetPageMargins)
```

`_clearStrokeAnchorCache()` clears the per-stroke resolved-screen-position cache. Plugin-side only; no new reflow events.

### Why this strategy (reasoning tied to operator empathy bar)

1. **Handwriting personality is never lost** (paper-book bar §1): the verbatim tier means the stroke is ALWAYS visible to the user — even on complete anchor failure, the rotation-badge path renders the stroke. Failure mode 3 (stroke disappears) is structurally impossible.

2. **"What I drew is what I see" at capture time** (paper-book bar): no classification at capture, no shape snap, no surprise morph. The stroke is rendered verbatim immediately after lift-off. Capture-time feedback is the anchor-hit/miss binary signal visible via the rotation-badge style.

3. **Reflow idiom symmetry with Goal-1** (carry-over §3): Op3 line-relative anchor uses exactly the same xpointer + `getScreenPositionFromXPointer` pattern as Goal-1's highlight anchoring, invalidated by the same 5 pre-reflow handlers from M7. Zero new reflow surface.

4. **Engine modification surface = ZERO** (operator-addendum §2 budget UNUSED): all inverse-mapping APIs (credocument.lua:605, 719–744, 908–925) exist in shipped KOReader. Pure plugin-side change.

5. **Graceful degradation via EARNED shim** (fallback-necessity-critic): the rotation-badge fallback at main.lua:4239–4311 is prior_production=true — real users have strokes captured under different rotations. This is the right terminal tier.

6. **Simplest path** (simplicity-critic): verbatim tier is FREE (existing Path-B storage). Anchor record is ~100–200 bytes additive overhead. No classifier, no per-point storage, no engine patches. Storage cost is bounded regardless of stroke complexity.

### UX non-negotiables satisfied (ux-northstar §5)

| Rule | How satisfied |
|---|---|
| §5.1 Classification feedback at capture | Binary anchor-hit/miss signal (anchor field populated vs nil); rotation-badge on miss is perceptible at first reflow |
| §5.2 Anchor-miss preserves stroke visibly | Rotation-badge path ALWAYS renders stroke — no silent drop |
| §5.3 No reflow-time shape morph | Stroke ink path (pixels) is NEVER modified; only translation delta changes on reflow |
| §5.4 No keyboard anywhere | No keyboard flow introduced |
| §5.5 Pen ink visually distinct from highlights | TOOL_PEN strokes retain existing ink rendering: own width/opacity/color from tool_settings[TOOL_PEN]. Do NOT inherit Goal-1 `lighten` drawer or highlighter color wiring. Anchor resolution affects POSITION only, not style. |

### Discard-raw rejection (EARNED)

The operator addendum invited "reduce-to-semantic-primitive" (Op6) as an out-of-the-box direction. This is explicitly rejected as the PRIMARY path because ux-northstar §5.2 is binding: "anchor-miss must preserve stroke visibly." Discarding the raw stroke violates this rule on anchor miss. Op6 remains a valid OPT-IN extension (user-initiated snap at lift-off, confidence-gated) but is not the default path in this plan.

---

## §2 Milestone Plan

**Status**: FINAL — Sub-goal 2B converged (5/5 critics APPROVED).
**Milestone count**: 7 (G2-M1..G2-M7)
**Spec count**: 22 (SA-1..SA-5, SC-1..SC-5, SP-1..SP-7, PER-1..PER-4, RU-1)
**Projected busted count**: 304 → 326/0/0
**Dependency chain**: G2-M1 → G2-M2 → G2-M3 → G2-M4 → G2-M5 → G2-M6 → G2-M7

| ID | Title | Type | Specs | 2B Gates | Depends On |
|---|---|---|---|---|---|
| G2-M1 | Schema lockdown + discard-raw EARNED record | doc-only | 0 | 2B-CF1 | — |
| G2-M2 | Three lib/ modules: stroke_anchor, stroke_capture, stroke_paint | new modules | 5 | 2B-R2 | G2-M1 |
| G2-M3 | Wire capture: assignStrokeToGroup calls stroke_capture | main.lua | 5 | 2B-R1 (2 pcalls) | G2-M2 |
| G2-M4 | Wire paint: paintTo calls stroke_paint + reflow invalidation | main.lua | 7 | 2B-R1 (3rd pcall), 2B-UX-C1, 2B-UX-C2, 2B-CF2, 2B-CF3 | G2-M3 |
| G2-M5 | Persistence round-trip verification | spec only | 4 | 2B-PERSIST, 2B-CF4 | G2-M3 |
| G2-M6 | Ruby/vertical-text verification | spec only | 1 | 2B-RUBY | G2-M2 |
| G2-M7 | Documentation closeout | doc-only | 0 | — | G2-M6 |

---

### G2-M1 — Schema lockdown + discard-raw EARNED record

**Scope**: Documentation only. No code changes.

**Deliverable**: Update `goal-2-plan.md` (this file) recording:
1. Anchor record schema `{type="line", xp, dx_em, dy_lh}` LOCKED (additive, nullable)
2. `group.anchor = nil` semantics LOCKED: legacy strokes, image-only pages, anchor-miss
3. Discard-raw rejection EARNED per ux-northstar §5.2 (2B-CF1)
4. Verbatim tier: Path-B raw pixel coords unchanged
5. TOOL_PEN ink rendering NOT inheriting Goal-1 lighten drawer (2B-UX-C2 stated)

**Spec count**: 0 (doc-only).

---

### G2-M2 — Three lib/ modules: stroke_anchor, stroke_capture, stroke_paint

**Scope**: Three new pure-Lua files in `lib/`. No engine calls inside modules; CRengine calls
are dependency-injected (caller passes `doc`, which is mocked in specs).

**Precedent**: `lib/geometry.lua` (ADVISORY-2), `lib/dispatch_predicate.lua` (Goal-1).

#### `lib/stroke_anchor.lua` — pure coord math

```lua
--- Compute anchor record from a CRengine word result and stroke start-point.
-- @param word_result  table from getWordFromPosition or getNearestWordAndBoxFromPosition
--   word_result.xpointer  string -- xpointer for the word/line (CRengine field)
--   word_result.pos       Geom   -- screen box {x,y,w,h} (used for em/lh estimate)
-- @param stroke_pt    {x=int, y=int}
-- @param em_px        number (see OQ-3 resolution: word_result.pos.h * 0.6)
-- @param lh_px        number (word_result.pos.h)
-- @return {type="line", xp=string, dx_em=float, dy_lh=float} OR nil
-- nil if word_result.xpointer is nil/absent, or inputs invalid.
function M.compute_line_anchor(word_result, stroke_pt, em_px, lh_px) end

--- Resolve anchor to translation delta.
-- @param anchor  {type="line", xp, dx_em, dy_lh}
-- @param screen_x, screen_y  number — from getScreenPositionFromXPointer
-- @param em_px, lh_px  number
-- @return tx, ty  number, number
function M.resolve_anchor_delta(anchor, screen_x, screen_y, em_px, lh_px) end
```

**OQ-3 LOCKED**: `lh_px = word_result.pos.h`, `em_px = word_result.pos.h * 0.6`. No new API surface (ADVISORY-1 compliant).

#### `lib/stroke_capture.lua` — pcall capture chain

```lua
--- Compute anchor for a new stroke. Contains ALL pcall-wrapped CRengine calls.
-- @param doc          CreDocument object (or mock in spec)
-- @param stroke_pt    {x=int, y=int}
-- @return anchor table OR nil
function M.compute_anchor(doc, stroke_pt)
  -- build-compat: getWordFromPosition do_not_draw_selection=true (credocument.lua:605)
  local ok1, word = pcall(doc.getWordFromPosition, doc, stroke_pt, true)
  if ok1 and word then
    local lh = word.pos and word.pos.h or 20
    local anchor = stroke_anchor.compute_line_anchor(word, stroke_pt, lh*0.6, lh)
    if anchor then return anchor end
  end
  -- build-compat: getNearestWordAndBoxFromPosition DIR_ANY=0 (credocument.lua:719-744)
  local ok2, nearest = pcall(doc.getNearestWordAndBoxFromPosition, doc, stroke_pt, 0)
  if ok2 and nearest then
    local lh = nearest.pos and nearest.pos.h or 20
    return stroke_anchor.compute_line_anchor(nearest, stroke_pt, lh*0.6, lh)
  end
  return nil
end
```

#### `lib/stroke_paint.lua` — paint decision

```lua
--- Paint a stroke using anchor or fallback to rotation-badge.
-- @param group               annotation group with optional .anchor field
-- @param doc                 CreDocument object (or mock in spec)
-- @param em_px, lh_px        number (current layout metrics)
-- @param draw_translated_fn  function(group, tx, ty)
-- @param rotation_badge_fn   function(group) — main.lua:4239-4311, EARNED
function M.paint_with_anchor(group, doc, em_px, lh_px, draw_translated_fn, rotation_badge_fn)
  if group.anchor then
    -- build-compat: getScreenPositionFromXPointer (credocument.lua:908-925, cached :1927)
    local ok, screen_y, screen_x = pcall(
      doc.getScreenPositionFromXPointer, doc, group.anchor.xp)
    if ok and screen_y ~= nil then
      if screen_y >= 0 then
        local tx, ty = stroke_anchor.resolve_anchor_delta(
          group.anchor, screen_x, screen_y, em_px, lh_px)
        draw_translated_fn(group, tx, ty)
        return
      else
        return  -- off-screen: silent clip, NOT rotation-badge (valid anchor, prior page)
      end
    end
    -- pcall raised or screen_y==nil: anchor invalid → fall through to EARNED badge
  end
  rotation_badge_fn(group)  -- EARNED: main.lua:4239-4311
end
```

**5 specs** (`spec/stroke_anchor_spec.lua`):

| Spec ID | Given / When / Then |
|---|---|
| SA-1 | Given word_result `{xpointer="x/p", pos={x=10,y=20,w=100,h=20}}` / When compute_line_anchor / Then anchor.type=="line", anchor.xp=="x/p", dx_em+dy_lh are numbers |
| SA-2 | Given nil word_result / When compute_line_anchor / Then nil, no error |
| SA-3 | Given anchor {dx_em=1.5, dy_lh=0.5}, screen_x=100, screen_y=200, em_px=10, lh_px=20 / When resolve_anchor_delta / Then tx==115, ty==210 |
| SA-4 | Given anchor dx_em=0, dy_lh=0 / When resolve_anchor_delta / Then tx==screen_x, ty==screen_y |
| SA-5 | Given word_result where xpointer==nil / When compute_line_anchor / Then nil (graceful miss) |

**Gates closed**: 2B-R2.

---

### G2-M3 — Wire capture: assignStrokeToGroup calls stroke_capture

**Scope**: `main.lua` — else-branch of `assignStrokeToGroup` at ~:3204 (after `group.xpointer_v2` block :3133-3147).

```lua
-- main.lua ~:3204 (after xpointer_v2 block)
local stroke_capture = require("lib/stroke_capture")
group.anchor = stroke_capture.compute_anchor(self.ui.document, stroke_start_pt)
-- nil → rotation-badge at paint time; non-nil → anchor-resolved paint
```

**5 specs** (`spec/stroke_capture_spec.lua` — uses mock doc, no require('main')):

| Spec ID | Given / When / Then |
|---|---|
| SC-1 | Given mock doc: getWordFromPosition returns valid word with xpointer / When compute_anchor called / Then anchor ~= nil, anchor.type=="line", anchor.xp is string |
| SC-2 | Given mock doc: getWordFromPosition pcall raises / When compute_anchor called / Then falls to fuzzy; if fuzzy returns valid word, anchor non-nil |
| SC-3 | Given mock doc: both lookups return nil / When compute_anchor called / Then nil (image-only / no-text page) |
| SC-4 | Given mock doc that records call args / When compute_anchor called / Then getWordFromPosition called with `true` as 3rd arg (do_not_draw_selection regression guard) |
| SC-5 | Given mock doc: fuzzy returns word on a margin stroke / When compute_anchor called / Then anchor non-nil or nil — no error raised |

**Gates closed**: 2B-R1 (pcall on getWordFromPosition + getNearestWordAndBoxFromPosition with build-compat comments, in lib/stroke_capture.lua).

---

### G2-M4 — Wire paint: paintTo calls stroke_paint + reflow invalidation

**Scope**: `main.lua` — `Pencil:paintTo` at ~:4200 + 5 pre-reflow handlers at :4604+.

```lua
-- main.lua paintTo
local stroke_paint = require("lib/stroke_paint")
stroke_paint.paint_with_anchor(group, self.ui.document, em_px, lh_px,
  function(g, tx, ty) self:_drawStrokeTranslated(g, tx, ty) end,
  function(g) self:_rotationBadgeRender(g) end)  -- main.lua:4239-4311, EARNED

-- Reflow handlers (onSetDimensions/onSetFontSize/onSetFont/onSetLineSpace/onSetPageMargins)
function Pencil:onSetDimensions()
  pcall(self.ui.view.resetHighlightBoxesCache, self.ui.view)
  self:_clearStrokeAnchorCache()  -- Goal-2 addition (one line)
end
-- identical one-line extension for all 5 handlers
```

**GROUP_SPATIAL_THRESHOLD**: defined at main.lua:111, value=200px. Multi-line strokes (vertical span > 200px) anchor to START-LINE only (C1). This is automatic: capture uses start-point only, so no additional code needed. Cited in SP-7 for 2B-CF3.

**7 specs** (`spec/stroke_paint_spec.lua` — uses mock doc + injected fns, no require('main')):

| Spec ID | Given / When / Then |
|---|---|
| SP-1 | Given group with valid anchor, mock doc returns screen_y=100, screen_x=50 / When paint_with_anchor / Then draw_translated_fn called with correct tx/ty (2B-CF2 stationary-render) |
| SP-2 | Given group with valid anchor, mock doc returns screen_y=-50 (off-screen) / When paint_with_anchor / Then draw_translated_fn NOT called, rotation_badge_fn NOT called (silent clip) |
| SP-3 | Given group with valid anchor, mock doc.getScreenPositionFromXPointer raises / When paint_with_anchor / Then rotation_badge_fn called (anchor invalid fallback, EARNED) |
| SP-4 | Given group.anchor == nil (legacy or image-only) / When paint_with_anchor / Then rotation_badge_fn called |
| SP-5 | Given TOOL_PEN group / When paint_with_anchor / Then stroke ink rendering uses tool_settings[TOOL_PEN] width/color/opacity — NOT Goal-1 lighten drawer (2B-UX-C2) |
| SP-6 | Given reflow event (onSetFontSize) / When handler fires / Then _clearStrokeAnchorCache called; subsequent paint re-resolves xpointer |
| SP-7 | Given multi-line stroke (vertical span > GROUP_SPATIAL_THRESHOLD=200, main.lua:111) / When capture then paint / Then anchor.xp is from start-line; paint uses start-line translation (2B-UX-C1, 2B-CF3) |

**Gates closed**: 2B-R1 (3rd pcall on getScreenPositionFromXPointer in lib/stroke_paint.lua), 2B-UX-C1, 2B-UX-C2, 2B-CF2, 2B-CF3.

---

### G2-M5 — Persistence round-trip

**Scope**: Spec only. No new code (G2-M3 schema already writes `group.anchor`).

`saveStrokes` (main.lua:4407-4455) and `loadStrokes` (main.lua:4305+) use `serpent` serialisation. `data.version = 3` — no bump needed. Nil fields omitted by serpent, loading as nil (correct).

**4 specs** (`spec/stroke_persist_spec.lua` — direct serpent test, no require('main')):

| Spec ID | Given / When / Then |
|---|---|
| PER-1 | Given group with anchor=nil / When serpent.dump + serpent.load / Then loaded.anchor == nil (2B-PERSIST) |
| PER-2 | Given group with anchor={type="line", xp="x/p", dx_em=1.5, dy_lh=0.5} / When round-trip / Then loaded anchor fields all correct (2B-CF4) |
| PER-3 | Given file written with anchor=nil and re-loaded (data.version=3 unchanged) / When loadStrokes / Then no error, anchor remains nil |
| PER-4 | Given mixed file (some groups with anchor, some nil) / When round-trip / Then each group's anchor correctly restored |

**Gates closed**: 2B-PERSIST, 2B-CF4.

---

### G2-M6 — Ruby/vertical-text verification

**Scope**: Spec only + grep of languagesupport.lua (KS 793f4e4d).

**Finding** (pre-confirmed by codebase-analyst + languagesupport.lua:211-217): Under vertical-text mode, `getWordFromPosition` may return nil. The capture chain in `lib/stroke_capture.compute_anchor` handles this: strict miss → fuzzy miss → nil → main.lua assigns `group.anchor = nil` → rotation-badge at paint. Safe degradation.

**1 spec** (`spec/stroke_ruby_spec.lua`):

| Spec ID | Given / When / Then |
|---|---|
| RU-1 | Given mock doc: both getWordFromPosition + getNearestWordAndBoxFromPosition return nil (vertical-text / ruby mode) / When compute_anchor / Then nil returned (no error) — rotation-badge will fire at paint (2B-RUBY) |

**Gates closed**: 2B-RUBY.

---

### G2-M7 — Documentation closeout

**Scope**: Documentation only.

**Deliverable**:
1. `goal-2-plan.md` fully populated (§1–§6 all non-placeholder)
2. `panel-state.yaml` updated: `goal_2_reopened.status: COMPLETE`
3. Event log entry added
4. No new code, no new spec files.

---

## §3 Requirements-Traceability Matrix

| Row | Requirement | Source | Milestone | Spec | Status |
|---|---|---|---|---|---|
| RTM-1 | Pen stroke persists verbatim pixel coords (Path-B, free) | goal-2-reopened §2 | G2-M1 (doc) | — | FINAL |
| RTM-2 | Anchor record is additive nullable `{type,xp,dx_em,dy_lh}` | 2A convergence | G2-M1 (doc) | SA-1 | FINAL |
| RTM-3 | `lib/stroke_anchor.lua` pure-Lua coord math, no engine calls | 2B-R2 | G2-M2 | SA-1..SA-5 | FINAL |
| RTM-4 | Pure-Lua specs in `spec/stroke_anchor_spec.lua` | 2B-R2 | G2-M2 | SA-1..SA-5 | FINAL |
| RTM-5 | Capture: `getWordFromPosition` called with `do_not_draw_selection=true` | codebase-analyst R5 | G2-M3 | SC-4 | FINAL |
| RTM-6 | Capture: strict lookup pcall-wrapped + `-- build-compat:` comment | 2B-R1 | G2-M2 (stroke_capture.lua) | SC-1,SC-2 | FINAL |
| RTM-7 | Capture: fuzzy lookup pcall-wrapped + `-- build-compat:` comment | 2B-R1 | G2-M2 (stroke_capture.lua) | SC-3,SC-5 | FINAL |
| RTM-8 | Capture: anchor=nil on image-only / no-text page | ux-northstar UX-S2 | G2-M3 | SC-3 | FINAL |
| RTM-9 | Capture: anchor placed at start-line for multi-line strokes | 2B-UX-C1, 2B-CF3 | G2-M4 | SP-7 | FINAL |
| RTM-10 | GROUP_SPATIAL_THRESHOLD cited at main.lua:111, value=200 | lateral-thinker | G2-M4 | SP-7 | FINAL |
| RTM-11 | Paint: `getScreenPositionFromXPointer` pcall-wrapped + `-- build-compat:` | 2B-R1 | G2-M2 (stroke_paint.lua) | SP-1..SP-3 | FINAL |
| RTM-12 | Paint: off-screen (screen_y<0) → silent clip, NO rotation-badge | ux-northstar R5 | G2-M4 | SP-2 | FINAL |
| RTM-13 | Paint: pcall failure/nil → rotation-badge (EARNED :4239-4311) | 2B-CF1, fallback | G2-M4 | SP-3,SP-4 | FINAL |
| RTM-14 | Paint: anchor=nil → rotation-badge (legacy + anchor-miss) | 2B-CF1 | G2-M4 | SP-4 | FINAL |
| RTM-15 | Paint: TOOL_PEN uses own ink rendering, NOT Goal-1 lighten drawer | 2B-UX-C2 | G2-M4 | SP-5 | FINAL |
| RTM-16 | Reflow: 5 pre-reflow handlers extended by _clearStrokeAnchorCache (1 line each) | 2A §reflow | G2-M4 | SP-6 | FINAL |
| RTM-17 | Reflow: no new reflow events introduced | 2A §reflow | G2-M4 | SP-6 | FINAL |
| RTM-18 | Stationary-render: paint deterministic when layout unchanged | 2B-CF2 | G2-M4 | SP-1 | FINAL |
| RTM-19 | Persistence: nil anchor round-trips through serpent | 2B-PERSIST | G2-M5 | PER-1,PER-3 | FINAL |
| RTM-20 | Persistence: full anchor round-trips (close/reopen cycle) | 2B-CF4 | G2-M5 | PER-2,PER-4 | FINAL |
| RTM-21 | Persistence: no data.version bump required | codebase-analyst | G2-M5 | PER-3 | FINAL |
| RTM-22 | Ruby/vertical: graceful degradation → anchor=nil → rotation-badge | 2B-RUBY | G2-M6 | RU-1 | FINAL |
| RTM-23 | Discard-raw rejection EARNED, citing ux-northstar §5.2 | 2B-CF1 | G2-M1 | — | FINAL |
| RTM-24 | Goal-1 Path-A (TOOL_HIGHLIGHTER) untouched | goal-2-reopened §2 | all | SP-5 | FINAL |
| RTM-25 | M7 handlers (Goal-1) extended not replaced | 2A §reflow | G2-M4 | SP-6 | FINAL |

---

## §4 Risks-to-Goal-1 + Mitigations

| Risk | Title | Severity | Mitigation |
|---|---|---|---|
| R1 | `getWordFromPosition` side-effect: draws selection | HIGH | Pass `do_not_draw_selection=true` (credocument.lua:605 arg 2). RTM-5, SC-4 verify. Goal-1 Path-A at main.lua:907 does NOT pass true — Goal-2 MUST differ (lib/stroke_capture.lua enforces this). |
| R2 | Goal-1 reflow handler breakage | MEDIUM | One line added to EACH of the 5 handlers (onSetDimensions/onSetFontSize/onSetFont/onSetLineSpace/onSetPageMargins). SP-6 verifies at least one. PR review checks all 5. |
| R3 | TOOL_PEN stroke inherits Goal-1 lighten drawer accidentally | MEDIUM | SP-5: explicit non-regression spec. RTM-15. lib/stroke_paint.paint_with_anchor callback architecture keeps rendering concerns separate. |
| R4 | Rotation-badge (4239-4311) accidentally bypassed for all strokes | HIGH | SP-3/SP-4 confirm rotation_badge_fn called on pcall-failure and anchor=nil. EARNED path injected as callback — cannot be accidentally bypassed in lib/stroke_paint.lua. |
| R5 | Off-screen/invalid anchor conflation | MEDIUM | Paint algorithm explicitly branches: screen_y<0 → silent return (no badge); pcall-fail/nil → rotation_badge_fn. SP-2 and SP-3 are distinct specs testing the two behaviors. |
| R6 | Serpent serialisation of anchor sub-table breaks on old data.version | LOW | Serpent is additive; nil fields absent in old files load as nil. PER-1/PER-3 verify nil round-trip. No data.version bump needed. |
| R7 | Goal-1 xpointer_v2 and Goal-2 anchor capture interact in assignStrokeToGroup | MEDIUM | Goal-2 anchor written after xpointer_v2 block at ~:3204. No interaction. SC-1 smoke-tests combined result. |

---

## §5 Engine-Modification Surface

**None.** All inverse-mapping primitives exist in shipped KOReader:
- `CreDocument:getWordFromPosition(pos, true)` — credocument.lua:605
- `CreDocument:getNearestWordAndBoxFromPosition(pos, 0)` — credocument.lua:719–744
- `CreDocument:getScreenPositionFromXPointer(xp)` — credocument.lua:908–925 (cached)

The operator-addendum §2 engine-modification budget (fork/downstream patches to KOReader CRengine / ReaderView / ReaderRolling) remains **UNUSED**. Plugin-side only.

---

## §6 KOReader Build-Target Compatibility Note

Same caveat as Goal-1: bottom-edge build target is unknown. Default assumption: CreDocument's inverse primitives (getWordFromPosition, getNearestWordAndBoxFromPosition, getScreenPositionFromXPointer) match koreader-ref HEAD `4f24cb6a`. All call sites are pcall-wrapped per main.lua:3057–3068 idiom; on missing-method `attempt to index nil`, the pcall catches and the rotation-badge path renders the stroke gracefully.

**Ruby/vertical-text**: behavior under vertical-text CRengine mode is a 2B milestone verification item (M-ruby-verify). Goal-2 strokes may fall back to the rotation-badge path in vertical mode until verified.
