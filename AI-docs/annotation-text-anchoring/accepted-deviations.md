# Accepted Deviations — annotation-text-anchoring

**Milestone**: G1-ACCEPTED-DEVIATION-NOTE (M6 of `annotation-text-anchoring`)
**Acceptance date**: 2026-05-29
**Acceptance scope**: Records the explicit operator/panel acceptance of
  the three deviations enumerated in `feature-plan.md §9`. No code
  change. No new busted spec. Validation gate unchanged from M5.

This document is the M6 audit-trail artefact: the M6 milestone brief
says "if the verbatim accepted-deviation statement is already present
in feature-plan.md §9 ADA-1, this milestone is a no-op commit that
records the acceptance explicitly." That condition holds — see the
verbatim-presence check below — and this file is that explicit record.

---

## 1. Verbatim-presence check (against `feature-plan.md §9`)

### ADA-1 — Visual geometry change (stationary renders)

**Reference**: `feature-plan.md` line 290.

**Verbatim text required by M6 milestone brief**:

> Path B paints a stylus-path-traced color smear; Path A paints uniform
> word-/line-aligned rectangles via `drawHighlightRect`
> (readerview.lua:666). Geometries differ by design. Per operator
> framing ("raw pixel stroke is low-fidelity input; high-fidelity
> intent is 'these words'"), the visual change IS the feature. No
> separate busted test needed for this deviation.

**Verbatim text actually present at `feature-plan.md:290`**:

> Path B paints a stylus-path-traced color smear; Path A paints uniform
> word-/line-aligned rectangles via `drawHighlightRect`
> (readerview.lua:666). Geometries differ by design. Per operator
> framing ("raw pixel stroke is low-fidelity input; high-fidelity
> intent is 'these words'"), the visual change IS the feature. No
> separate busted test needed for this deviation.

**Status**: PRESENT VERBATIM — character-for-character match.

### ADA-2 — Goal-2 stroke extent under rotation

**Reference**: `feature-plan.md` line 294.

**Text actually present**:

> Model B per-stroke delta `{line_xpointer, dx_em, dy_line_h}` does NOT
> preserve stroke extent under rotation (horizontal portrait stroke
> under-covers wider landscape line). Operator tolerance is positional,
> not proportional. Accepted for FOLLOWUP PR; not in scope here.

**Status**: PRESENT (out-of-scope deviation; Goal-2 work scoped out per
  feature-plan.md §1; ADA-2 carries to the FOLLOWUP PR rather than this
  feature).

### ADA-3 — No migration of legacy absolute-coordinate annotations

**Reference**: `feature-plan.md` line 298.

**Text actually present**:

> Users with pre-existing highlights in `pencil_strokes.lua` will see
> them drift on reflow, same as today. Migration is a separate
> follow-up feature (REQUIREMENTS_FILE §Out of scope). The two-sidecar
> architecture preserves both sidecars independently so legacy data
> survives alongside new Path-A data.

**Status**: PRESENT (REQUIREMENTS_FILE explicitly lists "Migration of
  pre-existing absolute-coordinate annotations" as out of scope at
  L62–L69; ADA-3 records the operator's awareness of the resulting
  legacy-data drift).

---

## 2. Acceptance

The panel leader has, by routing M1–M5 through to commit-validator PASS
and instructing M6 to proceed, ratified all three accepted deviations
as binding on this feature branch:

| ADA | Verbatim in §9 | Spec coverage (or scope-out reason) | Accepted |
|---|---|---|---|
| ADA-1 | yes (line 290) | "No separate busted test needed" — visual change IS the feature; verified via M3 wiring tests (`pencil_text_highlight_color_spec.lua`) and M5 redraw tests (`pencil_text_highlight_redraw_spec.lua` `drawHighlightRect` boundary) confirm Path-A behavior, not Path-B geometry. | YES |
| ADA-2 | yes (line 294) | Out of scope this PR (Goal 2 scoped out per feature-plan.md §1.2; covered by FOLLOWUP PR per feature-plan.md §8). | YES (for FOLLOWUP PR) |
| ADA-3 | yes (line 298) | Two-sidecar isolation verified by M5 `pencil_text_highlight_sidecar_spec.lua` (Path-A write does not touch `pencil_strokes.lua`; Path-B write does not touch `annotations` doc_settings key). | YES |

---

## 3. Traceability — which committed milestones land under each ADA

This is the operator's record of "what was actually delivered under
the umbrella of each accepted deviation". The commit SHAs below are
the M1–M5 commits as routed and PASSed by the commit-validator.

### Under ADA-1 (visual geometry change, no separate test)

| Commit | Milestone | What it landed |
|---|---|---|
| `cb94719` | M1 G1-GATE-AUDIT       | Gate-audit doc; no code change. |
| `97031e5` | M2 G1-DISPATCH-WIDEN   | Widened dispatch so menu-tool reaches Path A. |
| `ebfc5f1` | M3 G1-COLOR-WIRING     | Stamps `drawer='lighten'` + `color=<tool color name>`. |
| `b3078f5` | M4 G1-FLIP-DEFAULT     | Defaults `experimental_text_highlight` to `true`. |
| `734e9ae` | M5 G1-SPECS            | 4 KOReader-integration specs verifying the redraw, reflow, persistence, and sidecar contracts under Path-A geometry. |

### Under ADA-2 (Goal-2 stroke extent under rotation)

(none on this PR — FOLLOWUP PR per feature-plan.md §8 "Goal-2-FOLLOWUP
design"; Model B per-stroke `{line_xpointer, dx_em, dy_line_h}` and
its `length_em_x`/`length_em_y` extent-scaling refinement are
deferred.)

### Under ADA-3 (no migration of legacy absolute-coordinate annotations)

| Commit | Milestone | Why it lands under ADA-3 |
|---|---|---|
| `734e9ae` | M5 G1-SPECS | `pencil_text_highlight_sidecar_spec.lua` verifies the two-sidecar isolation that makes the no-migration policy safe: legacy `pencil_strokes.lua` data survives unchanged alongside new Path-A annotations. |

---

## 4. M6 commit gate

| Check | Status |
|---|---|
| ADA-1 verbatim in `feature-plan.md §9` | PASS (line 290) |
| ADA-2 present in `feature-plan.md §9` | PASS (line 294) |
| ADA-3 present in `feature-plan.md §9` | PASS (line 298) |
| `busted` baseline (post-M5) | 277 successes / 0 failures / 0 errors / 0 pending |
| `busted` post-M6 (no code change) | 277 successes / 0 failures / 0 errors / 0 pending — unchanged |
| Code lines changed by M6 | 0 (documentation only) |
| New busted specs added by M6 | 0 (documentation milestone per feature-plan.md §6) |

**M6 acceptance**: confirmed. All three accepted deviations are
explicitly on record. The feature `annotation-text-anchoring` is ready
to ship as Goal-1 complete; Goal-2 carries to FOLLOWUP PR per
feature-plan.md §8.

---

*End of acceptance record.*
