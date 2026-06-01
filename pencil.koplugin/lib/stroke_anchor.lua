--[[--
Pure-Lua line-relative anchor math for Goal-2 pen-stroke text-anchoring.

This module owns the coordinate arithmetic for translating between the
hardware (verbatim) stroke pixel coordinates captured by the digitiser and
the line-relative anchor record that survives reflow. It does NOT call
any CRengine API and has no module-level dependencies — the caller
threads a `word_result` (returned by `CreDocument:getWordFromPosition` or
`getNearestWordAndBoxFromPosition`) in. This is what makes the module
busted-testable without requiring `main`.

----------------------------------------------------------------------
Schema (Goal-2 plan §1, LOCKED) — owns the `"line"` anchor variant
----------------------------------------------------------------------

    group.anchor = {
        type  = "line",            -- this module's owned variant
        xp    = "<xpointer>",      -- line xpointer at stroke start-point
        dx_em = <float>,           -- horizontal offset in em units
        dy_lh = <float>,           -- vertical offset in line-height units
    }

Or `group.anchor = nil` for legacy strokes / image-only pages /
anchor-miss at capture (rotation-badge path at paint time).

OQ-3 LOCKED in plan §2 G2-M2:
    lh_px = word_result.pos.h
    em_px = word_result.pos.h * 0.6

----------------------------------------------------------------------
4-value anchor.type dispatcher (Goal-3 schema lockdown, G3-M1)
----------------------------------------------------------------------

Goal-3 extends `group.anchor` from a 2-value contract (nil | "line")
to a 4-value contract. This module remains the sole owner of the
`"line"` variant; the three other variants live in their own modules:

    anchor.type    Path                                  Module owner
    -----------    -----                                 ------------
    nil            legacy → rotation-badge EARNED        (Goal-2 back-
                   (main.lua:4239-4311 byte-identical)    compat; no
                                                          per-type
                                                          module)
    "line"         Goal-2 implicit line-relative anchor  THIS module
                   (xp, dx_em, dy_lh — see schema above) (lib/stroke_anchor)
    "explicit"     Goal-3 EPUB cluster anchor (xp +      lib/stroke_capture
                   cluster_bbox + connector_geom +       (capture)
                   scale + free_spot_history +           lib/stroke_paint
                   clarified)                            (render)
                                                          lib/manual_anchor
                                                          (state machine)
    "pdf_page"     Goal-3 PDF page-anchor                lib/pdf_anchor
                   (page integer only)                   (capture)
                                                          lib/stroke_paint
                                                          (render)

----------------------------------------------------------------------
"explicit" anchor record schema (G3-M4 paint, G3-M2/M3 capture)
----------------------------------------------------------------------

    group.anchor = {
        type              = "explicit",
        xp                = <xpointer_string>,    -- anchor text line xpointer
                                                   -- (nil only on MA-6 orphan
                                                   --  sentinel — escape hatch)
        cluster_bbox      = { x, y, w, h },       -- cluster bbox at capture
                                                   -- (screen px)
        connector_geom    = { x0, y0, x1, y1 },   -- connector endpoints
                                                   -- (screen px; updated on
                                                   --  reflow)
        scale             = <float 0.5..1.0>,     -- current scale factor
        free_spot_history = { layout_key,         -- single-record layout
                              x_em, y_lh, scale }, -- cache (cap=1)
        clarified         = <bool>,               -- false ⇒ ambiguity prompt
                                                   -- active; true ⇒ resolved
    }

----------------------------------------------------------------------
"pdf_page" anchor record schema (G3-M7 capture + render)
----------------------------------------------------------------------

    group.anchor = {
        type = "pdf_page",
        page = <integer>,           -- 1-based page number at capture time
    }

PDF strokes render at saved pixel coordinates on the matching page.
No heuristic, no connector, no exclamation, no auto-layout. Atomic
delete still applies (eraser-tap removes the annotation group only —
no highlight, no connector to remove). PDFs do not reflow, so
rotation survival is NOT a DoD requirement for the PDF path.

----------------------------------------------------------------------
Stale-rotation filter explicit type guard (G3-M4 wiring)
----------------------------------------------------------------------

The earned rotation-badge filter at main.lua:4247-4296 stays
byte-identical for `nil` and `"line"` groups (Goal-2 hard
constraint). G3-M4 adds a 2-line guard above the filter so that
`"explicit"` and `"pdf_page"` groups bypass it and reach the
draw step unchanged:

    if group.anchor
        and (group.anchor.type == "explicit"
             or group.anchor.type == "pdf_page") then
        goto skip_stale_filter
    end

Spec PT-6 (G3-M4) is the regression guard: an `"explicit"` group
with a stale rotation tag must still reach stroke draw.

----------------------------------------------------------------------
Render-op ordering invariant (LOCKED in G3-M4)
----------------------------------------------------------------------

    highlight_underline  <  stroke  <  exclamation  <  badge

Underline drawn first so ink sits on top; exclamation second-to-last
so it stays visible on top of strokes; badge last so the legacy
fallback marker stays visible when present.

----------------------------------------------------------------------
Named-constants surface
----------------------------------------------------------------------

All 18 numeric tuning values (paint primitives, hue triples, timing
windows, scale ratios) live in `lib/anchor_constants.lua` per
operator hard-constraint #5. This module does not define numeric
literals beyond the OQ-3 `* 0.6` em-from-lh ratio (LOCKED in Goal-2
§2 G2-M2; not a tunable constant — derived from CRengine word-box
geometry).

@module pencil.lib.stroke_anchor
--]]--

local StrokeAnchor = {}

--- Compute an anchor record from a CRengine word result and a stroke point.
--
-- Pure: no engine calls, no side effects. Caller (lib/stroke_capture.lua)
-- has already pcall-wrapped the CRengine inverse-lookup.
--
-- The anchor records the offset of the stroke start-point relative to the
-- top-left of the word/line box, normalised by em/lh so the same offset
-- can be replayed against the same line at any future font size or
-- margin layout.
--
-- @param word_result table from getWordFromPosition /
--                    getNearestWordAndBoxFromPosition.
--                    Expected fields:
--                      .xpointer (string) — line xpointer
--                      .pos      ({x,y,w,h}) — screen box at capture
-- @param stroke_pt   { x = number, y = number } — start-point of stroke
-- @param em_px       number — current em size in pixels
-- @param lh_px       number — current line-height in pixels
-- @return table  { type="line", xp, dx_em, dy_lh }  on success
-- @return nil          when word_result is nil, has no xpointer, or
--                      lacks a usable .pos (graceful miss — caller
--                      assigns group.anchor = nil → rotation-badge path)
function StrokeAnchor.compute_line_anchor(word_result, stroke_pt, em_px, lh_px)
    if type(word_result) ~= "table" then return nil end
    local xp = word_result.xpointer
    if type(xp) ~= "string" or #xp == 0 then return nil end
    local pos = word_result.pos
    if type(pos) ~= "table" then return nil end
    if type(stroke_pt) ~= "table" then return nil end
    if type(em_px) ~= "number" or em_px <= 0 then return nil end
    if type(lh_px) ~= "number" or lh_px <= 0 then return nil end

    local px = pos.x or 0
    local py = pos.y or 0
    local sx = stroke_pt.x or 0
    local sy = stroke_pt.y or 0

    return {
        type  = "line",
        xp    = xp,
        dx_em = (sx - px) / em_px,
        dy_lh = (sy - py) / lh_px,
    }
end

--- Resolve an anchor record + current line screen position to a stroke
-- translation delta.
--
-- Inverse of `compute_line_anchor`: given an anchor record captured at
-- one layout and the current screen position of the same xpointer
-- (queried by the caller from `getScreenPositionFromXPointer`), return
-- the (tx, ty) pixel coordinates to translate the verbatim stroke to.
--
-- Pure: no engine calls.
--
-- @param anchor    { type, xp, dx_em, dy_lh }
-- @param screen_x  number — current x of the anchored line on screen
-- @param screen_y  number — current y of the anchored line on screen
-- @param em_px     number — current em size in pixels
-- @param lh_px     number — current line-height in pixels
-- @return tx number, ty number
function StrokeAnchor.resolve_anchor_delta(anchor, screen_x, screen_y, em_px, lh_px)
    local tx = screen_x + anchor.dx_em * em_px
    local ty = screen_y + anchor.dy_lh * lh_px
    return tx, ty
end

return StrokeAnchor
