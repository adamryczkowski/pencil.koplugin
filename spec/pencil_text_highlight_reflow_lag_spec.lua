--[[--
Integration spec: pre-reflow cache invalidation closes the stale-render window.

Bug (M7 root cause, confirmed by panel triage): KOReader's
`ReaderView:resetHighlightBoxesCache` is wired as the
`onDocumentRerendered` handler at readerview.lua:1217. That event
fires only AFTER CRengine has finished reflowing the document — on a
Kobo, reflow can take ~5 seconds for a font-size or rotation change.
During that 5-second window, any redraw of saved Path-A annotations
reads from the stale `highlight_boxes_cache` and paints highlights at
their pre-reflow positions, producing the visible lag the operator
reported.

Fix (this milestone): the plugin subscribes to the PRE-reflow events
that KOReader emits BEFORE invoking CRengine, and clears the cache at
that point. Now any interim repaint during the reflow window finds an
empty cache, falls through to the pcall-guarded
`getScreenBoxesFromPositions` call, and either gets fresh boxes (if
CRengine is far enough along) or returns nil (no draw — which is the
correct behaviour while reflow is in flight; "highlights briefly
disappear" is acceptable per feature-plan.md §4 row 3).

The 5 events that fire BEFORE CRengine reflow (verified via direct
read of KOReader modules):
  • SetDimensions  — readerrolling.lua:1111 (rotation entry path)
  • SetFontSize    — readerfont.lua:207 (font size change)
  • SetFont        — readerfont.lua:283+ (font family change)
  • SetLineSpace   — readerfont.lua:216 (line spacing change)
  • SetPageMargins — readertypeset.lua:552 (margin change)

The first fix at ca0e57e (`Pencil:onDocumentRerendered` with a
`UIManager:setDirty` call) is redundant — ReaderRolling already calls
`setDirty(view.dialog, 'partial')` at readerrolling.lua:1059 right
after broadcasting `DocumentRerendered`. This spec also verifies that
redundant `setDirty` is removed from the rerendered handler.

Pattern-B inline-mock; no main.lua require.

Run with: busted spec/pencil_text_highlight_reflow_lag_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Inline mocks of the boundary surfaces.
-- ---------------------------------------------------------------------

-- Build a mock ReaderView with a call-recording resetHighlightBoxesCache.
-- `throws = true` simulates an exceptional engine state — used to verify
-- the pcall guard in each handler.
local function makeView(opts)
    opts = opts or {}
    local view = {
        _reset_calls = 0,
        _throws = opts.throws,
    }
    function view.resetHighlightBoxesCache(self)
        self._reset_calls = self._reset_calls + 1
        if self._throws then error("simulated CRengine error") end
    end
    return view
end

-- Build a mock pencil instance. Variants drive the defensive paths:
--   no_ui            : self.ui = nil (plugin not bound to a ReaderUI)
--   no_view          : self.ui.view = nil
--   no_reset_fn      : self.ui.view exists but lacks resetHighlightBoxesCache
local function makePencil(variant)
    variant = variant or {}
    if variant.no_ui then return {} end
    if variant.no_view then return { ui = {} } end
    if variant.no_reset_fn then
        return { ui = { view = {} } }
    end
    local view = makeView{ throws = variant.throws }
    return { ui = { view = view, _view_ref = view } }
end

-- ---------------------------------------------------------------------
-- Mirrors of the 5 new handler bodies. Each spec asserts the contract
-- this mirror encodes; the source-level test below verifies main.lua
-- contains the same code shape.
-- ---------------------------------------------------------------------

local function makeResetHandler()
    return function(self)
        if self.ui and self.ui.view then
            pcall(self.ui.view.resetHighlightBoxesCache, self.ui.view)
        end
    end
end

-- ---------------------------------------------------------------------
-- Per-handler contract tests
-- ---------------------------------------------------------------------

-- Each KOReader event handler shares the same body. We test the shared
-- body via one mirror and then verify (in the source test below) that
-- main.lua defines each named handler with that body.
local PRE_REFLOW_EVENTS = {
    "onSetDimensions",
    "onSetFontSize",
    "onSetFont",
    "onSetLineSpace",
    "onSetPageMargins",
}

describe("M7 pre-reflow cache invalidation — shared handler body", function()

    it("calls resetHighlightBoxesCache on self.ui.view", function()
        local handler = makeResetHandler()
        local pencil = makePencil()
        handler(pencil)
        assert.equals(1, pencil.ui._view_ref._reset_calls)
    end)

    it("calls resetHighlightBoxesCache once per event (idempotent in count)", function()
        local handler = makeResetHandler()
        local pencil = makePencil()
        handler(pencil)
        handler(pencil)
        handler(pencil)
        assert.equals(3, pencil.ui._view_ref._reset_calls)
    end)

    it("is a no-op when self.ui is nil (plugin not yet bound to ReaderUI)", function()
        local handler = makeResetHandler()
        local pencil = makePencil{ no_ui = true }
        assert.has_no.errors(function() handler(pencil) end)
    end)

    it("is a no-op when self.ui.view is nil (view not yet attached)", function()
        local handler = makeResetHandler()
        local pencil = makePencil{ no_view = true }
        assert.has_no.errors(function() handler(pencil) end)
    end)

    it("pcall guards resetHighlightBoxesCache if it raises (CRengine boundary)", function()
        local handler = makeResetHandler()
        local pencil = makePencil{ throws = true }
        assert.has_no.errors(function() handler(pencil) end)
        -- The function was reached (pcall caught its raise); count goes
        -- up before the raise.
        assert.equals(1, pencil.ui._view_ref._reset_calls)
    end)

    it("pcall guards when resetHighlightBoxesCache is missing (older KOReader)", function()
        local handler = makeResetHandler()
        local pencil = makePencil{ no_reset_fn = true }
        -- pcall(nil_fn, ...) returns ok=false, no raise. Handler must
        -- not propagate the failure even if the view exists but lacks
        -- the method (build-compat tolerance for older KOReader).
        assert.has_no.errors(function() handler(pencil) end)
    end)

end)

-- ---------------------------------------------------------------------
-- Source-level assertion: main.lua defines all 5 named handlers with
-- the same body shape (the KOReader event-dispatch mechanism keys on
-- the handler NAME, so each must exist as a discrete Pencil:onXxx
-- function definition; a single shared closure is not enough).
-- ---------------------------------------------------------------------

local function readMain()
    local f = io.open("pencil.koplugin/main.lua", "r")
    assert.is_not_nil(f, "main.lua must be readable from project root")
    local src = f:read("*a")
    f:close()
    return src
end

-- Strip Lua single-line comments so source-level contains-checks on
-- the handler body aren't fooled by comment text that mentions a name
-- without using it (e.g. the post-fix comment block describing why
-- UIManager:setDirty was removed).
local function stripLuaComments(s)
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

describe("M7 main.lua source — pre-reflow event handlers are defined", function()

    for _, name in ipairs(PRE_REFLOW_EVENTS) do
        it("defines Pencil:" .. name, function()
            local src = readMain()
            local body = findHandlerBody(src, name)
            assert.is_not_nil(body,
                "Pencil:" .. name .. " handler must be defined in main.lua")
        end)

        it("Pencil:" .. name .. " body calls resetHighlightBoxesCache", function()
            local src = readMain()
            local body = findHandlerBody(src, name)
            assert.is_not_nil(body)
            assert.is_truthy(
                body:find("resetHighlightBoxesCache", 1, true),
                "Pencil:" .. name ..
                    " must call resetHighlightBoxesCache to close the stale-cache window")
        end)

        it("Pencil:" .. name .. " body is pcall-wrapped (CRengine guard)", function()
            local src = readMain()
            local body = findHandlerBody(src, name)
            assert.is_not_nil(body)
            assert.is_truthy(
                body:find("pcall", 1, true),
                "Pencil:" .. name ..
                    " must pcall-wrap the KOReader call per main.lua:3057-3068 pattern")
        end)

        it("Pencil:" .. name .. " body does NOT call UIManager:setDirty", function()
            -- ReaderRolling already handles the post-reflow setDirty at
            -- readerrolling.lua:1059. Adding another setDirty here would
            -- duplicate work and risk a spurious "ui" repaint mid-reflow.
            local src = readMain()
            local body = findHandlerBody(src, name)
            assert.is_not_nil(body)
            assert.falsy(
                body:find("UIManager:setDirty", 1, true),
                "Pencil:" .. name .. " must NOT add a setDirty call — " ..
                    "ReaderRolling already handles the post-reflow repaint")
        end)
    end

end)

-- ---------------------------------------------------------------------
-- onDocumentRerendered correctness: the M7 fix removes the redundant
-- UIManager:setDirty call added by ca0e57e (the first fix). The handler
-- may either be deleted or kept as a documented no-op; this spec
-- accepts either, but enforces that the body does NOT call setDirty.
-- ---------------------------------------------------------------------

describe("M7 onDocumentRerendered — redundant setDirty removed", function()

    it("if Pencil:onDocumentRerendered exists, its body does NOT call UIManager:setDirty", function()
        local src = readMain()
        local body = findHandlerBody(src, "onDocumentRerendered")
        if body == nil then
            -- Handler removed entirely — that is also an acceptable
            -- M7 outcome (the first fix was reverted).
            return
        end
        assert.falsy(
            body:find("UIManager:setDirty", 1, true),
            "Pencil:onDocumentRerendered must NOT call UIManager:setDirty after M7 — " ..
                "ReaderRolling already handles the post-reflow repaint at " ..
                "readerrolling.lua:1059 (the ca0e57e setDirty was redundant)")
    end)

end)
