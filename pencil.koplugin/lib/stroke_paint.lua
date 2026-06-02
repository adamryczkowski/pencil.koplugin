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
local AnchorConstants = require("lib/anchor_constants")

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

-- ------------------------------------------------------------------
-- Goal-3 G3-M4: paint_anchor_group — 4-value anchor.type dispatcher
-- ------------------------------------------------------------------
--
-- Pure dispatch + geometry. Consumes a group + the runtime scalars
-- (font metrics, screen extents) and emits an ordered render_op_list
-- describing what the caller (main.lua paintTo) must draw. Does NOT
-- invoke any of the callback parameters — they exist in the signature
-- for caller-side dispatch symmetry (per plan §2 G3-M4 confirmed
-- arch-planner signature) and may be wired up here in a future
-- milestone if the dispatch ever needs to side-effect during scoring.
--
-- Render-op shapes (plan §2 stroke_paint.lua doc comment):
--   {type="stroke",              group, scale, dx, dy}
--   {type="connector",           x0, y0, x1, y1, width_px, alpha, hue}
--   {type="highlight_underline", x, y, w, height_px, alpha, hue}
--   {type="exclamation",         x, y, size_lh, alpha, pulse}
--   {type="badge",               x, y}
--
-- LOCKED ordering: highlight_underline < connector < stroke <
-- exclamation < badge. (Connector sits between underline and stroke;
-- both line elements draw under the ink for the "underline family"
-- visual identity.)
--
-- 4-value type dispatch:
--   nil        → empty list (caller routes via existing
--                 paint_with_anchor → rotation-badge EARNED)
--   "line"     → empty list (caller routes via existing
--                 paint_with_anchor → Goal-2 path)
--   "explicit" → highlight_underline + connector + stroke
--                 (+ exclamation if clarified=false; + badge if xp
--                 missing/unresolvable for the orphan/lookup-fail path)
--   "pdf_page" → stroke only (caller does the page-equality gate;
--                 no heuristic, no connector — per plan §1.7 PDF spec)
--
-- @param group               group with .anchor field
-- @param doc                 CreDocument | PdfDocument | mock
-- @param em_px, lh_px        runtime font metrics
-- @param screen_w, screen_h  screen extents (for clamp / off-screen test;
--                            currently informational — used by free-spot
--                            in G3-M5)
-- @param screen_rot          screen rotation (informational, same)
-- @param draw_translated_fn  G2 stroke drawer (caller's responsibility)
-- @param rotation_badge_fn   G2 badge fallback (caller's responsibility)
-- @param anchor_highlight_fn G3 underline drawer (caller's responsibility)
-- @param connector_fn        G3 connector drawer (caller's responsibility)
-- @return render_op_list      ordered array (empty on nil/line type)
function StrokePaint.paint_anchor_group(group, doc,
                                         em_px, lh_px,
                                         screen_w, screen_h, screen_rot,
                                         draw_translated_fn, rotation_badge_fn,
                                         anchor_highlight_fn, connector_fn)
    local ops = {}

    if type(group) ~= "table" or type(group.anchor) ~= "table" then
        return ops
    end

    local atype = group.anchor.type

    -- Goal-2 "line" anchors stay on the existing paint_with_anchor
    -- path; this dispatcher emits nothing so the caller's fallthrough
    -- continues to drive the verbatim translated stroke draw.
    if atype == "line" then
        return ops
    end

    -- PDF page-anchor: stroke-only. The caller is responsible for
    -- (a) gating on doc:getCurrentPage() == group.anchor.page and
    -- (b) translating the saved pixel paths verbatim. We emit a
    -- single stroke op so the caller's iterator picks it up; dx/dy
    -- are zero (saved at native pixel coords; PDFs don't reflow).
    if atype == "pdf_page" then
        table.insert(ops, {
            type  = "stroke",
            group = group,
            scale = 1.0,
            dx    = 0,
            dy    = 0,
        })
        return ops
    end

    -- "explicit" — EPUB cluster anchor. The remainder of this
    -- function targets this branch.
    if atype ~= "explicit" then
        return ops  -- unknown type → empty (caller routes to fallback)
    end

    local cluster_bbox = group.anchor.cluster_bbox
        or { x = 0, y = 0, w = 0, h = 0 }
    local lh = lh_px or 20
    local em = em_px or 12

    -- Orphan sentinel (MA-6 escape hatch): explicit anchor with no
    -- xpointer. Emit a single badge op at the cluster's saved
    -- top-left so the user can still see and reach the annotation.
    if type(group.anchor.xp) ~= "string" or #group.anchor.xp == 0 then
        table.insert(ops, {
            type = "badge",
            x    = cluster_bbox.x,
            y    = cluster_bbox.y,
        })
        return ops
    end

    -- Resolve the anchor's text-line screen position.
    -- build-compat: CreDocument:getScreenPositionFromXPointer
    local resolved, screen_y, screen_x = false, nil, nil
    if type(doc) == "table" then
        local ok, sy, sx = pcall(
            doc.getScreenPositionFromXPointer, doc, group.anchor.xp)
        if ok and type(sy) == "number" and type(sx) == "number" then
            resolved, screen_y, screen_x = true, sy, sx
        end
    end

    if not resolved then
        -- xpointer no longer resolves (book reopened on a different
        -- build, fragment deleted, …) → graceful badge fallback. The
        -- existing G2 rotation-badge path also activates via the
        -- caller's fallthrough; emitting a badge op here makes the
        -- op-list a complete contract.
        table.insert(ops, {
            type = "badge",
            x    = cluster_bbox.x,
            y    = cluster_bbox.y,
        })
        return ops
    end

    -- Estimate the underline width. We don't have the line's actual
    -- on-screen bbox at this dispatch layer (G3-M5 will route the
    -- free-spot pass through and could supply it); use the cluster
    -- bbox width as a reasonable proxy. Free-spot lands in G3-M5;
    -- this estimate is replaced by the line_bbox.w cached on the
    -- group's free_spot_history at that time.
    local line_w = cluster_bbox.w
    if line_w <= 0 then line_w = 4 * em end
    local fs = group.anchor.free_spot_history
    if type(fs) == "table" and type(fs.line_w_px) == "number" then
        line_w = fs.line_w_px
    end

    -- 1. highlight_underline — drawn at the resolved text line.
    local underline_y = screen_y + lh
        - AnchorConstants.ANCHOR_UNDERLINE_HEIGHT_PX
    table.insert(ops, {
        type      = "highlight_underline",
        x         = screen_x,
        y         = underline_y,
        w         = line_w,
        height_px = AnchorConstants.ANCHOR_UNDERLINE_HEIGHT_PX,
        alpha     = AnchorConstants.ANCHOR_UNDERLINE_ALPHA,
        hue       = AnchorConstants.ANCHOR_UNDERLINE_HUE,
    })

    -- Compute the cluster paint position. Free-spot history records
    -- the placement chosen by G3-M5a/b; absent (G3-M4 scope) we draw
    -- at the saved cluster_bbox top-left.
    local paint_x = cluster_bbox.x
    local paint_y = cluster_bbox.y
    if type(fs) == "table" then
        if type(fs.x_em) == "number" then
            paint_x = screen_x + fs.x_em * em
        end
        if type(fs.y_lh) == "number" then
            paint_y = screen_y + fs.y_lh * lh
        end
    end

    -- 2. connector — from underline midpoint to nearest cluster
    -- bbox edge. For G3-M4 we use the cluster top edge midpoint as
    -- the nearest-edge proxy; G3-M5 wiring will refine.
    local underline_mid_x = screen_x + line_w * 0.5
    local underline_mid_y = underline_y
    local cluster_top_mid_x = paint_x + cluster_bbox.w * 0.5
    local cluster_top_mid_y = paint_y
    table.insert(ops, {
        type     = "connector",
        x0       = underline_mid_x,
        y0       = underline_mid_y,
        x1       = cluster_top_mid_x,
        y1       = cluster_top_mid_y,
        width_px = AnchorConstants.CONNECTOR_LINE_WIDTH_PX,
        alpha    = AnchorConstants.CONNECTOR_ALPHA,
        hue      = AnchorConstants.CONNECTOR_HUE,
    })

    -- 3. stroke — the verbatim cluster paths translated from
    -- saved cluster_bbox top-left to paint_x/paint_y.
    local dx = paint_x - cluster_bbox.x
    local dy = paint_y - cluster_bbox.y
    local stroke_scale = (type(group.anchor.scale) == "number"
                          and group.anchor.scale) or 1.0
    table.insert(ops, {
        type  = "stroke",
        group = group,
        scale = stroke_scale,
        dx    = dx,
        dy    = dy,
    })

    -- 4. exclamation — only when the cluster is still ambiguous.
    -- Per plan §1.4: static glyph at top-right of cluster bounding
    -- box. Caller animates the single first-touch pulse.
    --
    -- G3-M9: emit op.hue (same indigo family as underline + connector
    -- per §6.3) so the executor can drop its hardcoded {75,0,130}
    -- fallback. ANCHOR_UNDERLINE_HUE doubles as the exclamation hue
    -- (single visual family).
    if group.anchor.clarified == false then
        table.insert(ops, {
            type    = "exclamation",
            x       = paint_x + cluster_bbox.w,
            y       = paint_y,
            size_lh = AnchorConstants.EXCLAMATION_SIZE_LH,
            alpha   = AnchorConstants.EXCLAMATION_ALPHA,
            hue     = AnchorConstants.ANCHOR_UNDERLINE_HUE,
            pulse   = false,
        })
    end

    return ops
end

return StrokePaint
