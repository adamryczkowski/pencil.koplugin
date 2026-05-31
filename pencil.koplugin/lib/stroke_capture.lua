--[[--
Goal-2 pen-stroke anchor capture — pcall chain.

This module owns the inverse-lookup CRengine calls needed to compute an
anchor record for a newly-completed pen stroke. It is the ONLY place
Goal-2 calls `getWordFromPosition` / `getNearestWordAndBoxFromPosition`,
and every call is pcall-wrapped per the build-compat idiom
(main.lua:3057-3068) so a missing-method on a divergent KOReader build
degrades gracefully to `anchor = nil` (→ rotation-badge path at paint
time).

`doc` is dependency-injected by the caller (`main.lua` →
`Pencil:assignStrokeToGroup`, which passes `self.ui.document`). In specs
this allows a plain table mock — the module file does not `require` any
CRengine module.

Strategy (Goal-2 plan §1):

  Step 1: strict inverse lookup (ReaderKeySelection idiom)
    `getWordFromPosition(pos, true)` — the third arg `do_not_draw_selection`
    is REQUIRED to suppress the marker-paint side effect at capture
    time (R1, RTM-5, SC-4 regression guard).

  Step 2: fuzzy inverse lookup
    `getNearestWordAndBoxFromPosition(pos, 0)` — DIR_ANY whole-page
    search. Used when the strict lookup misses (stroke near but not
    on text — margin annotation, between lines).

  Step 3: nil anchor
    Both lookups missed → `compute_anchor` returns nil → caller
    writes `group.anchor = nil` → paint-time rotation-badge path.

@module pencil.lib.stroke_capture
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokeAnchor = require("lib/stroke_anchor")

local StrokeCapture = {}

--- Compute an anchor record for a newly-completed stroke.
--
-- @param doc        CreDocument object (or mock table in specs).
--                   Must respond to either of:
--                     getWordFromPosition(self, pos, do_not_draw_selection)
--                     getNearestWordAndBoxFromPosition(self, pos, dir)
-- @param stroke_pt  { x = number, y = number } start-point of the stroke
-- @return table  { type="line", xp, dx_em, dy_lh }   anchor record
-- @return nil    when both lookups miss / raise / yield no usable word
function StrokeCapture.compute_anchor(doc, stroke_pt)
    if type(doc) ~= "table" or type(stroke_pt) ~= "table" then
        return nil
    end

    -- Step 1: strict inverse lookup.
    -- build-compat: CreDocument:getWordFromPosition (credocument.lua:605).
    -- Returns {word, sbox, pos0, pos1} on hit — NOT {xpointer, pos}.
    -- The 3rd arg `do_not_draw_selection=true` suppresses the marker-paint
    -- side effect at capture time (R1, RTM-5, SC-4 regression guard).
    local ok1, word = pcall(doc.getWordFromPosition, doc, stroke_pt, true)
    if ok1 and type(word) == "table" and word.pos0 and word.sbox then
        local lh = word.sbox.h or 20
        local normalized = { xpointer = word.pos0, pos = word.sbox }
        local anchor = StrokeAnchor.compute_line_anchor(
            normalized, stroke_pt, lh * 0.6, lh)
        if anchor then
            -- Remember the capture-time line-height so paint can compute
            -- the stroke-size scale ratio (lh_paint / lh_capture).
            anchor.lh_capture = lh
            return anchor
        end
    end

    -- Step 2: fuzzy inverse lookup.
    -- build-compat: CreDocument:getNearestWordAndBoxFromPosition
    -- (credocument.lua:719-744). Returns same shape as Step 1.
    -- DIR_ANY = 0 = whole-page search.
    local ok2, nearest = pcall(
        doc.getNearestWordAndBoxFromPosition, doc, stroke_pt, 0)
    if ok2 and type(nearest) == "table" and nearest.pos0 and nearest.sbox then
        local lh = nearest.sbox.h or 20
        local normalized = { xpointer = nearest.pos0, pos = nearest.sbox }
        local anchor = StrokeAnchor.compute_line_anchor(
            normalized, stroke_pt, lh * 0.6, lh)
        if anchor then
            anchor.lh_capture = lh
            return anchor
        end
    end

    -- Step 3: nil anchor — image-only / no-text / vertical-text-miss.
    -- Caller writes group.anchor=nil → paint-time rotation-badge path
    -- at main.lua:4239-4311 (EARNED fallback).
    return nil
end

return StrokeCapture
