--[[--
Goal-2 pen-stroke paint decision — anchor-resolve OR rotation-badge.

This module owns the per-stroke paint-time choice between:

  (A) Anchor-resolved translation: anchor present + xpointer resolves
      to a valid on-screen line → draw the verbatim stroke translated
      by the recomputed (tx, ty) delta.

  (B) Off-screen silent clip: anchor present + xpointer resolves to
      `screen_y < 0` (line on a previous virtual page) → DO NOT draw
      and DO NOT show a rotation badge. Standard KOReader clipping
      semantics — the content is simply outside the current view.

  (C) Rotation-badge fallback (EARNED): anchor=nil OR pcall raised OR
      `screen_y == nil` (xpointer no longer resolvable) → invoke the
      caller-supplied `rotation_badge_fn`, which is wired to
      `main.lua:4239-4311`. This is the EARNED prior-production
      fallback path — it must not be accidentally bypassed (R4).

The two CRengine-touching boundaries (`getScreenPositionFromXPointer`,
and the drawer / badge callbacks) are dependency-injected so this
module is busted-testable with a plain table mock. The module does NOT
require any CRengine module.

Caller wiring (main.lua Pencil:paintTo ~:4200):

    stroke_paint.paint_with_anchor(group, self.ui.document, em_px, lh_px,
        function(g, tx, ty) self:_drawStrokeTranslated(g, tx, ty) end,
        function(g) self:_rotationBadgeRender(g) end)

TOOL_PEN ink rendering (UX-C2, RTM-15): the `draw_translated_fn`
callback is responsible for the pen's own width/colour/opacity from
`tool_settings[TOOL_PEN]`. This module does NOT and MUST NOT inherit
Goal-1's `lighten` highlighter drawer. Anchor resolution affects
POSITION only, not style.

@module pencil.lib.stroke_paint
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokeAnchor = require("lib/stroke_anchor")

local StrokePaint = {}

--- Paint a stroke using its anchor record, or fall back to the rotation
-- badge.
--
-- @param group               annotation group; may have `.anchor` field
-- @param doc                 CreDocument object (or mock table in specs)
-- @param em_px               number — current em size in pixels
-- @param lh_px               number — current line-height in pixels
-- @param draw_translated_fn  function(group, tx, ty) — TOOL_PEN-aware
--                            stroke drawer; called on anchor hit
-- @param rotation_badge_fn   function(group) — EARNED fallback path,
--                            wired to main.lua:4239-4311
function StrokePaint.paint_with_anchor(group, doc, em_px, lh_px,
                                       draw_translated_fn, rotation_badge_fn)
    if group and group.anchor then
        -- build-compat: CreDocument:getScreenPositionFromXPointer
        -- (credocument.lua:908-925; cached at :1927).
        -- Returns (y, x) on success, nil on resolve failure.
        local ok, screen_y, screen_x = pcall(
            doc.getScreenPositionFromXPointer, doc, group.anchor.xp)
        if ok and screen_y ~= nil then
            if screen_y >= 0 then
                -- (A) anchor hit → translate (and optionally scale) the stroke
                local tx, ty = StrokeAnchor.resolve_anchor_delta(
                    group.anchor, screen_x, screen_y, em_px, lh_px)
                -- Scale strokes proportionally to line-height change between
                -- capture and paint. Strokes captured before this field was
                -- added (lh_capture nil) keep their original size (scale=1).
                local scale = 1.0
                if group.anchor.lh_capture
                        and type(group.anchor.lh_capture) == "number"
                        and group.anchor.lh_capture > 0 then
                    scale = lh_px / group.anchor.lh_capture
                end
                draw_translated_fn(group, tx, ty, scale)
                return
            else
                -- (B) off-screen (prior virtual page) → silent clip.
                -- Anchor is VALID, just out of view. No badge — that
                -- would falsely suggest the anchor failed.
                return
            end
        end
        -- pcall raised, or screen_y==nil: anchor no longer resolves
        -- (book reopened on a different build / xpointer invalidated).
        -- Fall through to EARNED rotation-badge path.
    end
    -- (C) anchor=nil (legacy / image-only / capture miss) OR resolve
    -- failure → EARNED rotation-badge fallback at main.lua:4239-4311.
    rotation_badge_fn(group)
end

return StrokePaint
