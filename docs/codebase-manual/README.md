# pencil.koplugin codebase manual

This directory holds the "describe-to-test" codebase manual produced by
the Goal-3 orchestrator's Phase-9 pass. It is a developer / maintainer
reference, not an end-user guide.

## Audience

Readers are expected to be comfortable with:

- Lua 5.1 / LuaJIT and Lua 5.4 (the plugin runs under LuaJIT on Kobo
  devices and under Lua 5.4 in the busted test environment).
- KOReader's plugin model and event dispatch.
- The CRengine document API surface (`frontend/document/credocument.lua`
  in KOReader) and the PDF / koptinterface path.

What this manual gives you that the source comments do not: an
end-to-end picture of how an annotation moves from stylus contact
through capture, clustering, anchoring, save, load, and paint, with
both EPUB and PDF paths shown side-by-side.

## Table of contents

1. [`01-architecture.md`](01-architecture.md) — where the plugin sits
   in the KOReader plugin model; the `lib/` module split and
   responsibility boundaries.
2. [`02-annotation-lifecycle.md`](02-annotation-lifecycle.md) —
   stylus pen-down through paint, with Goal-1 / Goal-2 / Goal-3 paths
   labelled at each step and the EPUB-vs-PDF dispatch fork made
   explicit.
3. [`03-data-model.md`](03-data-model.md) — annotation group, stroke,
   and anchor record schemas; the four-value `anchor.type` dispatcher;
   the field-naming discipline learned from Goal-2.
4. [`04-koreader-integration.md`](04-koreader-integration.md) — every
   KOReader API the plugin calls (credocument for EPUB, pdfdocument /
   koptinterface for PDF, the input layer for stylus and eraser),
   each with its real return shape.
5. [`05-reflow.md`](05-reflow.md) — EPUB reflow events, what each
   invalidates, the anchor pass's place in the paint pipeline, and the
   stale-rotation filter that silently blocked Goal-2 until commit
   `4a72ea6`.
6. [`06-explicit-anchoring.md`](06-explicit-anchoring.md) — the Goal-3
   EPUB workflow: cluster detection, ambiguity heuristic, manual-
   anchor mode, free-spot layout, and the connector primitive.
7. [`07-pdf.md`](07-pdf.md) — the PDF page-anchor path; explicit
   statement that there are no heuristics, no auto-layout, and no
   connector for PDF.
8. [`08-testing.md`](08-testing.md) — the busted spec layout under
   `spec/`, the mock-shape discipline, and the on-device manual-test
   PLAYBOOK + REMOTE-AUTOMATION workflow.
9. [`09-extension-points.md`](09-extension-points.md) — adding a new
   annotation type, adding a new format-dispatch entry, modifying the
   anchor schema with version-migration notes.

## Known UX limitations

A separate "Known UX Limitations" section is embedded near the end of
[`06-explicit-anchoring.md`](06-explicit-anchoring.md#known-ux-limitations).
It is the canonical place for limitations the manual chooses not to
hide behind marketing language, including reflow position drift,
device-dependent eraser sensitivity, and PDF page-capture timing.

## Discipline rules in force

These rules were earned the hard way by Goal-2's mock-vs-prod
divergence (26 green specs hiding a broken pipeline). Every file in
this manual is held to them:

1. Every API call described in this manual is verified against the
   real KOReader source. File path + function name are cited; line
   numbers are cited only with the SHA they came from (KOReader's
   source churns).
2. Every data-shape description is derived from the real return value.
   If a spec mock disagrees with the manual, the manual is canonical
   and the mock is a defect.
3. No marketing language. "Powerful", "elegant", "robust",
   "world-class" — cut on sight. Describe what it does and what it
   does not do.
4. Worked examples over reference structure. Each integration point
   has at least one concrete trace of a real call with real argument
   shapes.
5. Both formats covered. Any section that talks about EPUB anchor
   resolution states what PDF does too (typically: "PDF skips this
   step; the page IS the anchor"). Silence on PDF is a defect.
6. Reflow events are listed exhaustively in §05. Each event is paired
   with its cache-invalidation story.

## Source pins

- Plugin code reviewed against `pencil.koplugin/` at commit `72d6920`
  (Goal-3 G3-M8.5 PASS — paintTo dispatch wiring live).
- KOReader API citations reviewed against the file-knowledge-agent
  snapshots used during Goal-3 panel work (FKS IDs are quoted inline
  where relevant). Line numbers are SHA-pinned where they appear.

## What this manual is not

- An end-user "how to draw with the pencil plugin" guide.
- A KOReader fork or contribution proposal.
- A history of the Goal-1 / Goal-2 / Goal-3 design process. That
  lives under `AI-docs/annotation-text-anchoring/` (`feature-goal.md`,
  `goal-2-plan.md`, `goal-3-plan.md`, etc.). This manual is the
  present-tense reference; the design docs are the historical record.
