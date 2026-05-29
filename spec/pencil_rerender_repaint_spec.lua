--[[--
Unit spec: Pencil:onDocumentRerendered forces immediate repaint.

KOReader fires `DocumentRerendered` after any reflow (rotation, font
size/family, margins, line spacing, view mode). ReaderView resets its
highlight-boxes cache on the same event (readerview.lua:1217), but the
visible repaint only happens on the next natural setDirty cycle, which
can lag several seconds. The plugin's onDocumentRerendered handler
piggybacks on the event and calls UIManager:setDirty(view, "ui") so the
highlight layer re-resolves immediately.

Pattern-B inline mocks; no main.lua require.

Run with: busted spec/pencil_rerender_repaint_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Inline mocks
-- ---------------------------------------------------------------------

local function makeUIManager()
    local calls = {}
    return {
        setDirty = function(self, target, mode)
            table.insert(calls, { target = target, mode = mode })
        end,
        _calls = calls,
    }
end

-- Mirror of main.lua:onDocumentRerendered. The spec asserts the contract
-- without requiring main.lua (which pulls KOReader UI globals).
local function makeHandler(UIManager)
    return function(self)
        if self.view then
            UIManager:setDirty(self.view, "ui")
        end
    end
end

-- ---------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------

describe("Pencil:onDocumentRerendered", function()
    it("calls UIManager:setDirty on self.view with 'ui' mode", function()
        local UIManager = makeUIManager()
        local onDocumentRerendered = makeHandler(UIManager)
        local view = { _id = "view-1" }
        local self_ = { view = view }

        onDocumentRerendered(self_)

        assert.are.equal(1, #UIManager._calls)
        assert.are.equal(view, UIManager._calls[1].target)
        assert.are.equal("ui", UIManager._calls[1].mode)
    end)

    it("is a no-op when self.view is nil (plugin unloaded)", function()
        local UIManager = makeUIManager()
        local onDocumentRerendered = makeHandler(UIManager)
        local self_ = { view = nil }

        onDocumentRerendered(self_)

        assert.are.equal(0, #UIManager._calls)
    end)

    it("is idempotent: multiple rerenders => one setDirty each", function()
        local UIManager = makeUIManager()
        local onDocumentRerendered = makeHandler(UIManager)
        local self_ = { view = { _id = "view-2" } }

        onDocumentRerendered(self_)
        onDocumentRerendered(self_)
        onDocumentRerendered(self_)

        assert.are.equal(3, #UIManager._calls)
        for _, c in ipairs(UIManager._calls) do
            assert.are.equal("ui", c.mode)
        end
    end)
end)

describe("main.lua source", function()
    it("defines Pencil:onDocumentRerendered with setDirty('ui')", function()
        local f = io.open("pencil.koplugin/main.lua", "r")
        assert.is_not_nil(f, "main.lua must be readable from project root")
        local src = f:read("*a")
        f:close()

        assert.is_truthy(
            src:find("function Pencil:onDocumentRerendered", 1, true),
            "Pencil:onDocumentRerendered handler must be defined")
        -- Must call setDirty with "ui" mode (immediate, not deferred).
        local body_start = src:find("function Pencil:onDocumentRerendered", 1, true)
        local body_end = src:find("\nfunction Pencil:", body_start + 1, true) or (#src + 1)
        local body = src:sub(body_start, body_end - 1)
        assert.is_truthy(
            body:find("UIManager:setDirty", 1, true),
            "handler body must call UIManager:setDirty")
        assert.is_truthy(
            body:find('"ui"', 1, true),
            'handler must request "ui" refresh mode for immediate repaint')
    end)
end)
