--[[--
Wiring tests for Goal-3 reflow / page-turn handler activation.

Specs WR-1..WR-3 per Goal-3 plan §2 (G3-M4).

WR-1: Pencil:onDocumentRerendered (was no-op as of M7-REPAINT-LAG-FIX)
       is activated to invalidate the Goal-3 paint memo cache after
       CRengine reflow completes.
WR-2: Pencil:onPageUpdate (PDF page-turn entry point) calls
       self:_onPageTurn() so paint memos are cleared on every page
       crossing (CRengine does not reflow on page-turn — caller must
       invalidate the page-scoped memos explicitly).
WR-3: Pencil:onUpdatePos (EPUB rolling/scroll entry point) calls
       self:_onPageTurn() for the same reason.

Pattern B inline-mock — no require('main'). Source-level checks use
the stripLuaComments + findHandlerBody precedent established in
spec/stroke_paint_spec.lua so comment text isn't a false positive.

Run with: busted spec/g3_wiring_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Source-level helpers (precedent from spec/stroke_paint_spec.lua)
-- ---------------------------------------------------------------------

local function read_file(path)
    local f = io.open(path, "r")
    assert.is_not_nil(f, path .. " must be readable from project root")
    local src = f:read("*a")
    f:close()
    return src
end

local function stripLuaComments(s)
    s = s:gsub("%-%-%[%[.-%]%]", "")
    return (s:gsub("%-%-[^\n]*", ""))
end

local function findHandlerBody(src, handler_name)
    local needle = "function Pencil:" .. handler_name
    local body_start = src:find(needle, 1, true)
    if not body_start then return nil end
    local next_handler = src:find("\nfunction Pencil:", body_start + 1, true)
    local body_end = next_handler or (#src + 1)
    return stripLuaComments(src:sub(body_start, body_end - 1))
end

local MAIN_LUA = "pencil.koplugin/main.lua"

-- ---------------------------------------------------------------------
-- Inline body mirrors (Pattern B; behavioural assertions)
-- ---------------------------------------------------------------------

-- Mirror of the post-G3-M4 onDocumentRerendered body. Verifies the
-- documented behavioural contract regardless of how the production
-- code chooses to spell it (helper name may evolve).
local function on_document_rerendered_body(pencil)
    if pencil._clearPaintMemos then
        pencil:_clearPaintMemos()
    end
end

-- Mirror of the _onPageTurn helper that onPageUpdate / onUpdatePos
-- both delegate to.
local function on_page_turn_body(pencil)
    if pencil._clearPaintMemos then
        pencil:_clearPaintMemos()
    end
end

local function makePencil()
    return {
        _paint_memos = { line_boxes_by_page = {}, free_spot_map = {} },
        _clear_calls = 0,
        _clearPaintMemos = function(self)
            self._clear_calls = self._clear_calls + 1
            self._paint_memos = nil
        end,
    }
end

-- ---------------------------------------------------------------------
-- Specs
-- ---------------------------------------------------------------------

describe("Goal-3 G3-M4 wiring", function()

    it("G3-WR-1: onDocumentRerendered now invalidates Goal-3 paint memos (post-reflow)", function()
        -- Behavioural: a Pencil-shaped instance with a clearPaintMemos
        -- recorder receives one clear call when the handler body runs.
        local pencil = makePencil()
        on_document_rerendered_body(pencil)
        assert.equals(1, pencil._clear_calls)
        assert.is_nil(pencil._paint_memos)

        -- Source-level: the production handler body must reference
        -- _clearPaintMemos (or an equivalent G3 paint-memo clearer).
        local src = read_file(MAIN_LUA)
        local body = findHandlerBody(src, "onDocumentRerendered")
        assert.is_not_nil(body)
        assert.is_truthy(body:find("_clearPaintMemos", 1, true),
            "onDocumentRerendered body must call self:_clearPaintMemos() (G3-M4 WR-1)")
    end)

    it("G3-WR-2: onPageUpdate (PDF page-turn) clears paint memos via _onPageTurn", function()
        local pencil = makePencil()
        on_page_turn_body(pencil)
        assert.equals(1, pencil._clear_calls)

        local src = read_file(MAIN_LUA)
        local body = findHandlerBody(src, "onPageUpdate")
        assert.is_not_nil(body)
        -- Either an explicit _onPageTurn() delegation or a direct
        -- _clearPaintMemos() call is acceptable.
        local has_helper = body:find("_onPageTurn", 1, true) ~= nil
        local has_direct = body:find("_clearPaintMemos", 1, true) ~= nil
        assert.is_true(has_helper or has_direct,
            "onPageUpdate body must call self:_onPageTurn() or self:_clearPaintMemos() (G3-M4 WR-2)")
    end)

    it("G3-WR-3: onUpdatePos (EPUB rolling/scroll) clears paint memos via _onPageTurn", function()
        local pencil = makePencil()
        on_page_turn_body(pencil)
        assert.equals(1, pencil._clear_calls)

        local src = read_file(MAIN_LUA)
        local body = findHandlerBody(src, "onUpdatePos")
        assert.is_not_nil(body)
        local has_helper = body:find("_onPageTurn", 1, true) ~= nil
        local has_direct = body:find("_clearPaintMemos", 1, true) ~= nil
        assert.is_true(has_helper or has_direct,
            "onUpdatePos body must call self:_onPageTurn() or self:_clearPaintMemos() (G3-M4 WR-3)")
    end)

end)
