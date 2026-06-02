--[[--
Unit tests for lib/pdf_anchor — PDF page-anchor capture (compute) +
render-time page-equality gate (should_render).

Specs PA-1..PA-4 per Goal-3 plan §G3-7.

Per KSQ-2 resolution (pdfdocument FKS 62b9061a): PdfDocument:
getCurrentPage() DOES NOT EXIST. The reader/view layer owns the
current page (ReaderRolling / ReaderPaging exposes it). Current page
indexing is 1-based per KOReader convention. compute_pdf_anchor here
takes a `reader` argument (NOT a document) and calls
`reader:getCurrentPage()` to capture the page at cluster-close time;
the captured page is then compared at render time against the active
page via should_render.

Render dispatch for pdf_page anchors is already exercised by PT-2 in
spec/stroke_paint_anchor_spec.lua (G3-M4): paint_anchor_group emits a
single stroke op and zero highlight/connector/exclamation/badge ops.
PA-4 below composes this dispatch with the page gate to document the
end-to-end PDF lifecycle (capture → store → render gate).

Run with: busted spec/pdf_anchor_spec.lua

The compute / should_render surfaces are pure Lua — no MuPDF / koreader
runtime, no require('main'). The reader argument is a plain mock table
with a `getCurrentPage` method (1-based integer return).
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local PdfAnchor   = require("lib/pdf_anchor")
local StrokePaint = require("lib/stroke_paint")

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function make_reader(page_or_fn)
    local r = {}
    if type(page_or_fn) == "function" then
        r.getCurrentPage = page_or_fn
    else
        function r:getCurrentPage() return page_or_fn end
    end
    return r
end

local function count_op(ops, t)
    local n = 0
    for _, op in ipairs(ops) do
        if op.type == t then n = n + 1 end
    end
    return n
end

local function noop() end

----------------------------------------------------------------------
-- Specs
----------------------------------------------------------------------

describe("PdfAnchor.compute (G3-PA-1, G3-PA-4 capture)", function()

    it("G3-PA-1: compute captures current page from reader:getCurrentPage() (1-based)", function()
        local reader = make_reader(17)
        local stroke_bbox = { x = 100, y = 200, w = 80, h = 40 }

        local anchor = PdfAnchor.compute(reader, stroke_bbox)

        assert.is_table(anchor)
        assert.are.equal("pdf_page", anchor.type)
        assert.are.equal(17, anchor.page)  -- 1-based per KSQ-2
        assert.is_table(anchor.bbox)
        assert.are.equal(100, anchor.bbox.x)
        assert.are.equal(200, anchor.bbox.y)
        assert.are.equal(80,  anchor.bbox.w)
        assert.are.equal(40,  anchor.bbox.h)
    end)

end)

describe("PdfAnchor.should_render (G3-PA-2, G3-PA-3 page gate)", function()

    it("G3-PA-2: should_render returns true when group.anchor.page == current_page", function()
        local group = { anchor = { type = "pdf_page", page = 5 } }
        assert.is_true(PdfAnchor.should_render(group, 5))
    end)

    it("G3-PA-3: should_render returns false when group.anchor.page != current_page", function()
        local group = { anchor = { type = "pdf_page", page = 5 } }
        assert.is_false(PdfAnchor.should_render(group, 3))
    end)

end)

describe("PdfAnchor end-to-end (G3-PA-4 capture → render gate → stroke-only dispatch)", function()

    it("G3-PA-4: compute → store → should_render gates render, paint emits stroke only", function()
        -- (1) Capture: pen-stroke fires on PDF page 7.
        local reader = make_reader(7)
        local stroke_bbox = { x = 50, y = 50, w = 40, h = 40 }
        local anchor = PdfAnchor.compute(reader, stroke_bbox)
        local group  = { anchor = anchor, stroke_indices = { 1 } }

        -- (2) Render-time gate: caller asks "should I render this group
        -- on the current page?" before invoking paint_anchor_group.
        assert.is_true (PdfAnchor.should_render(group, 7))  -- captured page
        assert.is_false(PdfAnchor.should_render(group, 8))  -- other page

        -- (3) Dispatch: when the gate passes, paint_anchor_group emits
        -- exactly one stroke op (no underline, no connector, no
        -- exclamation, no badge — pdf_page is "stroke only" per the
        -- 4-value dispatcher).
        local doc = {}  -- unused for pdf_page branch
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, noop, noop, noop, noop)

        assert.is_table(ops)
        assert.are.equal(1, count_op(ops, "stroke"))
        assert.are.equal(0, count_op(ops, "highlight_underline"))
        assert.are.equal(0, count_op(ops, "connector"))
        assert.are.equal(0, count_op(ops, "exclamation"))
        assert.are.equal(0, count_op(ops, "badge"))
    end)

end)
