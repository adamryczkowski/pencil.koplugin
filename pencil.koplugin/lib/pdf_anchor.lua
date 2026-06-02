--[[--
PDF page-anchor capture (cluster-close → group.anchor) + render-time
page-equality gate. Per Goal-3 plan §G3-7: PDF strokes carry a fixed
page number and render only when the active page equals the captured
page. No heuristic, no auto-layout, no connector, no exclamation —
just the stroke at saved pixel coordinates.

Per KSQ-2 resolution (pdfdocument FKS 62b9061a-f944-4e81-a4d2-
69901b0d3594): PdfDocument:getCurrentPage() DOES NOT EXIST in
pdfdocument.lua (L1-420 scanned). Current-page state is owned by the
reader/view layer — ReaderRolling for CRengine-rendered EPUB+PDF,
ReaderPaging for raw PDF. compute() therefore takes a `reader`
argument (NOT a document) and calls `reader:getCurrentPage()` to
capture the page number. Indexing is 1-based per KOReader convention.

KOReader's reader:getCurrentPage may not always exist or may raise
(stateless koptinterface path; suspended renderer; cold-cache during
init). compute() pcall-wraps the call so a missing-method or
exception path yields nil rather than crashing the capture site;
callers MAY treat a nil-anchor capture as "skip" (no PDF anchor
attached, stroke remains in the legacy nil-anchor → rotation-badge
EARNED path).

----------------------------------------------------------------------
Public API
----------------------------------------------------------------------

    compute(reader, stroke_bbox)
        → { type = "pdf_page", page = N, bbox = stroke_bbox }
                  on success (N from reader:getCurrentPage()).
        → nil     when reader is missing/invalid, getCurrentPage is
                  unavailable, the call raises, or the returned page
                  is not a positive integer.

    should_render(group, current_page)
        → true    when group.anchor.type == "pdf_page" and
                  group.anchor.page == current_page.
        → false   in every other case (different page, non-pdf_page
                  anchor type, missing fields). Acts as a type guard
                  so callers can blanket-test all groups and only
                  paint the ones that match.

stroke_bbox shape: {x, y, w, h} in native PDF page pixel coordinates
at the captured rotation. Goal-3 PDF strokes render at saved pixel
coordinates with no rotation handling (per DoD #1 PDF rotation note in
plan §G3-7).

@module pencil.lib.pdf_anchor
--]]--

local PdfAnchor = {}

--- Defensive pcall wrapper around reader:getCurrentPage(). Returns
-- the page integer or nil. Centralised here so both call paths
-- (capture + future render-loop guards) share one boundary.
local function safe_get_current_page(reader)
    if type(reader) ~= "table" then return nil end
    local fn = reader.getCurrentPage
    if type(fn) ~= "function" then return nil end
    -- build-compat: reader:getCurrentPage()  (KOReader API surface;
    -- absent on some reader implementations — pcall protects the
    -- capture site from a missing-method crash).
    local ok, page = pcall(fn, reader)
    if not ok or type(page) ~= "number" then return nil end
    if page < 1 then return nil end
    -- Force integer (page numbers are inherently integral; float
    -- inputs are normalised to floor).
    return math.floor(page)
end

--- Capture a PDF page anchor at cluster-close time.
function PdfAnchor.compute(reader, stroke_bbox)
    local page = safe_get_current_page(reader)
    if not page then return nil end
    if type(stroke_bbox) ~= "table" then return nil end
    return {
        type = "pdf_page",
        page = page,
        bbox = {
            x = stroke_bbox.x,
            y = stroke_bbox.y,
            w = stroke_bbox.w,
            h = stroke_bbox.h,
        },
    }
end

--- Render-time page-equality gate. Returns true iff the group is a
-- pdf_page-anchored group AND its captured page equals the caller's
-- current_page. All other anchor types (nil / "line" / "explicit")
-- return false here — they take their own render path elsewhere in
-- the dispatcher (lib/stroke_paint.lua paint_anchor_group).
function PdfAnchor.should_render(group, current_page)
    if type(group) ~= "table" then return false end
    local anchor = group.anchor
    if type(anchor) ~= "table" then return false end
    if anchor.type ~= "pdf_page" then return false end
    if type(anchor.page) ~= "number" then return false end
    if type(current_page) ~= "number" then return false end
    return anchor.page == current_page
end

return PdfAnchor
