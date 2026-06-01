--[[--
Centralised named-constant table for Goal-3 explicit anchoring.

Hard constraint #5 (operator scope-lock, Goal-3 brief):

    All 18 named constants live in lib/anchor_constants.lua.
    Do NOT inline numeric literals at paint sites.

This module is the single-file tuning surface for every magic-number
value introduced by Goal-3 (and the four Goal-2 constants that the
Goal-3 modules also consume). All other lib/ modules and the paint
sites in main.lua require() this module and reference the named field
rather than re-declaring the literal locally. Goal-2 lesson #2
("paint-time pixel literals are tech debt") is enforced here.

The module is doc/const-only — pure Lua, no engine dependencies, no
side effects, busted-clean. It can be required from any spec without
pulling main.lua/Device/UIManager/Blitbuffer.

Constant sourcing
-----------------

Each entry below cites its rationale source in goal-3-plan.md §1.7.
Twelve constants are owned here outright (paint primitives + timing).
Six constants are mirrored here from their owning lib/ module's §1.7
"Module" column (lib/stroke_cluster, lib/cluster_heuristic,
lib/free_spot, lib/manual_anchor) so a tuner has a single index to
read. The mirror keeps anchor_constants.lua canonical for paint-site
references; per-module local copies, when added in G3-M2..M5b, MUST
require this module rather than re-stating the literal.

4-value anchor.type dispatcher (Goal-3 schema lockdown, G3-M1)
---------------------------------------------------------------

    anchor.type    Path                                  Owner
    -----------    -----                                 -----
    nil            legacy → rotation-badge EARNED        Goal-2 back-compat
                   (main.lua:4239-4311 byte-identical)
    "line"         Goal-2 implicit line-relative anchor  lib/stroke_anchor
                   (xp, dx_em, dy_lh; see header there)
    "explicit"     Goal-3 EPUB cluster anchor            lib/stroke_capture
                   (xp + cluster_bbox + connector_geom + lib/stroke_paint
                   + scale + free_spot_history)          lib/manual_anchor
    "pdf_page"     Goal-3 PDF page-anchor                lib/pdf_anchor
                   (page integer only)                   lib/stroke_paint

Stale-rotation filter (main.lua:4247-4296) gains a 2-line type-guard
in G3-M4: `"explicit"` and `"pdf_page"` groups bypass the rotation
filter so their saved stroke geometry reaches the draw step
unchanged. The filter remains byte-identical for `nil` and `"line"`
(earned-path preservation, Goal-2 hard constraint).

Render-op ordering invariant (LOCKED in G3-M4)
----------------------------------------------

    highlight_underline  <  stroke  <  exclamation  <  badge

(Underline drawn first so ink sits on top; badge last so the
fallback marker stays visible when present.)

@module pencil.lib.anchor_constants
--]]--

local AnchorConstants = {}

-- ---------------------------------------------------------------
-- Paint primitives (owned here; consumed by lib/stroke_paint.lua)
-- ---------------------------------------------------------------

--- Connector eraser-tap hit-target half-width, in screen pixels.
-- 8px each side of the 2px visual line → 16px total tap target
-- (~1.3mm at 300PPI Kobo Libra Colour). Tremor-tolerant; matches
-- feature-ux-critic G-D recommendation.
AnchorConstants.CONNECTOR_HIT_TARGET_PX = 16

--- Anchor underline draw height, in screen pixels.
-- 1px disappears under e-ink antialiasing; 3px competes with body
-- text descenders. 2px = standard underline.
AnchorConstants.ANCHOR_UNDERLINE_HEIGHT_PX = 2

--- Anchor underline alpha (0..255). ~60% opacity — visible but
-- non-competitive with body text.
AnchorConstants.ANCHOR_UNDERLINE_ALPHA = 153

--- Connector line width, in screen pixels.
-- 1px is too thin under R2 critique; 2px deliberately matches
-- the underline family so the connector reads as one visual
-- system with the anchor mark.
AnchorConstants.CONNECTOR_LINE_WIDTH_PX = 2

--- Connector alpha (0..255). Same value as underline — one visual
-- family.
AnchorConstants.CONNECTOR_ALPHA = 153

--- Exclamation glyph height in line-height units (self-scaling
-- on reflow). Resolved at paint time as `1.5 * lh_px_runtime`,
-- NOT as a hardcoded pixel literal (Goal-2 lesson #2).
AnchorConstants.EXCLAMATION_SIZE_LH = 1.5

--- Exclamation alpha (0..255). ~80% opacity — higher than the
-- underline/connector pair to signal "needs attention" without
-- becoming modal.
AnchorConstants.EXCLAMATION_ALPHA = 204

--- Exclamation pulse animation duration, in milliseconds.
-- One e-ink full-refresh cycle (~250ms) plus settle margin. Single
-- pulse only (not repeating).
AnchorConstants.EXCLAMATION_PULSE_DURATION_MS = 300

--- Minimum clearance around a rotation-badge fallback marker, in
-- screen pixels. ~24px glyph + 4px padding each side. Verified
-- against actual badge size at SSH Session 1 (DoD #10).
AnchorConstants.BADGE_FALLBACK_MIN_CLEARANCE_PX = 32

--- Clarification-tap debounce window, in milliseconds.
-- A second `ManualAnchor.on_clarification_tap` landing within this
-- window of the first is dropped silently (no heuristic re-run, no
-- state change). Prevents double-tap mis-routing on cold-cache
-- delays. Reuses the EXCLAMATION_PULSE_DURATION_MS interval — one
-- e-ink refresh cycle. (feature-ux G-E condition; spec MA-LAT-1
-- in G3-M4.)
AnchorConstants.CLARIFY_DEBOUNCE_MS = 300

-- ---------------------------------------------------------------
-- Hue constants (owned here; consumed by underline + connector
-- + exclamation draw primitives)
-- ---------------------------------------------------------------

--- Anchor underline hue (indigo, #4B0082).
-- Indigo sits between Blue (#0000FF) and Purple (#800080) in hue
-- space; red=75 distinguishes from Blue (red=0); unequal RGB
-- avoids the grayscale range (lighten mode = Blitbuffer.gray);
-- not in the 9-name Goal-1 palette. SSH validation at DoD #10:
-- ∆E ≥ 10 CIE76 vs all other rendered bars.
AnchorConstants.ANCHOR_UNDERLINE_HUE = { r = 75, g = 0, b = 130 }

--- Connector hue (indigo, #4B0082). Same as underline — one
-- visual family.
AnchorConstants.CONNECTOR_HUE = { r = 75, g = 0, b = 130 }

--- Fallback hue (teal, #008080) if indigo collapses onto
-- Blue/Purple under Kaleido 3 rendering. Validated at SSH
-- Session 1 fb0 dump before promotion.
AnchorConstants.FALLBACK_HUE = { r = 0, g = 128, b = 128 }

-- ---------------------------------------------------------------
-- Mirrored constants (owned by other lib/ modules per §1.7;
-- mirrored here for single-file tuning. Owning modules MAY
-- require() this table or declare a local mirror; mirrors must
-- match this file exactly.)
-- ---------------------------------------------------------------

--- Cluster-close timer, in milliseconds. No new pen-DOWN event
-- within this window of the previous pen-DOWN ⇒ cluster closes.
-- Per Q1 resolution (C1 fixed timeout). Source-of-truth module:
-- lib/stroke_cluster.lua (G3-M2).
AnchorConstants.CLUSTER_CLOSE_TIMEOUT_MS = 1200

--- Group spatial proximity threshold, in screen pixels.
-- Pre-existing Goal-2 constant (main.lua:108). Grouping is the
-- AND of pen-DOWN time proximity and spatial proximity.
AnchorConstants.GROUP_SPATIAL_THRESHOLD = 200

--- Heuristic ambiguity confidence gap. If `top1.score -
-- top2.score > AMBIGUITY_GAP_THRESHOLD` the cluster is confident
-- and auto-anchors. Else the manual-anchor prompt fires.
-- Rationale: clean-strike gap ≈ 0.65, margin-note gap ≈ 0.10,
-- two-line gap ≈ 0.05 — 0.20 sits cleanly between the
-- confident and ambiguous fixture clusters. Source-of-truth
-- module: lib/cluster_heuristic.lua (G3-M3).
AnchorConstants.AMBIGUITY_GAP_THRESHOLD = 0.20

--- Free-spot margin strip width, in screen pixels. ~2mm at
-- 300dpi Kobo Libra Colour. Narrow enough to fall through to the
-- L4 in-text fallback when the cluster is wider than the strip
-- can accommodate. Source-of-truth module: lib/free_spot.lua
-- (G3-M5a).
AnchorConstants.FREE_SPOT_MARGIN_PX = 24

--- Minimum scale ratio for the auto-layout scale-down loop. Both
-- L2 (margin) and L4 (in-text) refuse candidates below this floor
-- — readability gate per DoD §B. Source-of-truth module:
-- lib/free_spot.lua (G3-M5a).
AnchorConstants.MIN_SCALE_RATIO = 0.5

--- Scale step ratios, descending. Tried in order until a free
-- spot is found or the floor (MIN_SCALE_RATIO) is reached.
-- Source-of-truth module: lib/free_spot.lua (G3-M5a).
AnchorConstants.SCALE_STEP_RATIOS = { 1.0, 0.9, 0.75, 0.6, 0.5 }

--- Free-spot history cap, per annotation group. Cap=1 — single
-- entry replaced unconditionally on layout-key change.
-- simplicity-critic C-4: no premature LRU. Source-of-truth
-- module: lib/free_spot.lua (G3-M5a).
AnchorConstants.FREE_SPOT_HISTORY_CAP = 1

--- Clarification-tap proximity radius, in line-height units. The
-- second tap is treated as "near the cluster" only when it falls
-- within this radius of the cluster_bbox; outside this radius it
-- is treated as a fresh stroke. Source-of-truth module:
-- lib/manual_anchor.lua (G3-M4).
AnchorConstants.CLARIFICATION_RADIUS_LH = 5

return AnchorConstants
