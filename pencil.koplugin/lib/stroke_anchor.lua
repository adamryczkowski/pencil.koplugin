--[[--
Pure-Lua line-relative anchor math for Goal-2 pen-stroke text-anchoring.

This module owns the coordinate arithmetic for translating between the
hardware (verbatim) stroke pixel coordinates captured by the digitiser and
the line-relative anchor record that survives reflow. It does NOT call
any CRengine API and has no module-level dependencies — the caller
threads a `word_result` (returned by `CreDocument:getWordFromPosition` or
`getNearestWordAndBoxFromPosition`) in. This is what makes the module
busted-testable without requiring `main`.

Schema (Goal-2 plan §1, LOCKED):

    group.anchor = {
        type  = "line",            -- only valid value in this PR
        xp    = "<xpointer>",      -- line xpointer at stroke start-point
        dx_em = <float>,           -- horizontal offset in em units
        dy_lh = <float>,           -- vertical offset in line-height units
    }

Or `group.anchor = nil` for legacy strokes / image-only pages /
anchor-miss at capture (rotation-badge path at paint time).

OQ-3 LOCKED in plan §2 G2-M2:
    lh_px = word_result.pos.h
    em_px = word_result.pos.h * 0.6

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
