--[[--
Wiring tests for Goal-3 reflow / page-turn handler activation
(G3-M4 WR-1..WR-3) and Goal-3 paintTo dispatch wiring (G3-M8.5
WR-1..WR-5; tagged G3-M8.5-WR-N to disambiguate from the G3-M4
WR series above).

G3-M4 WR series (reflow / page-turn cache invalidation):
- WR-1: Pencil:onDocumentRerendered (was no-op as of M7-REPAINT-LAG-FIX)
        is activated to invalidate the Goal-3 paint memo cache after
        CRengine reflow completes.
- WR-2: Pencil:onPageUpdate (PDF page-turn entry point) calls
        self:_onPageTurn() so paint memos are cleared on every page
        crossing (CRengine does not reflow on page-turn — caller must
        invalidate the page-scoped memos explicitly).
- WR-3: Pencil:onUpdatePos (EPUB rolling/scroll entry point) calls
        self:_onPageTurn() for the same reason.

G3-M8.5 WR series (paintTo 4-branch dispatch into paint_anchor_group):
- WR-1: explicit-anchor groups dispatch to StrokePaint.paint_anchor_group.
- WR-2: pdf_page-anchor groups dispatch to paint_anchor_group AND gate
        via PdfAnchor.should_render.
- WR-3: nil-anchor groups skip the anchor-owned dispatch entirely
        (earned-path preservation — they fall through to the
        renderStroke fallback below).
- WR-4: line-anchor groups still route to StrokePaint.paint_with_anchor
        (BYTE-IDENTICAL Goal-2 earned path).
- WR-5: stale-rotation filter inside paintTo bypasses explicit/pdf_page
        groups via a 2-line type-guard (Goal-3 anchors handle their
        own rotation/page state).

Pattern B inline-mock + Pattern A source-grep. No require('main').
Source-level checks use stripLuaComments + findHandlerBody (precedent
established in spec/stroke_paint_spec.lua) so comment text isn't a
false positive.

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

-- ---------------------------------------------------------------------
-- G3-M8.5 paintTo dispatch wiring (WR-1..WR-5)
-- ---------------------------------------------------------------------

describe("Goal-3 G3-M8.5 paintTo dispatch wiring", function()

    local function get_paintTo_body()
        local src = read_file(MAIN_LUA)
        return findHandlerBody(src, "paintTo")
    end

    it("G3-M8.5-WR-1: paintTo dispatches explicit-anchor groups to paint_anchor_group", function()
        local body = get_paintTo_body()
        assert.is_not_nil(body, "paintTo handler body must be findable")
        -- The dispatch must check for the "explicit" anchor type
        assert.is_truthy(body:find('"explicit"', 1, true),
            "paintTo must reference \"explicit\" anchor.type in dispatch (G3-M8.5-WR-1)")
        -- And route it to paint_anchor_group (the lib/ Goal-3 paint
        -- entry — Goal-2 entry is paint_with_anchor; WR-4 covers that)
        assert.is_truthy(body:find("paint_anchor_group", 1, true),
            "paintTo must call StrokePaint.paint_anchor_group for explicit/pdf_page (G3-M8.5-WR-1)")

        -- Behavioural mirror: a fake dispatcher that mirrors the
        -- real paintTo's if/elseif structure for the explicit case.
        local calls = { paint_anchor_group = 0, paint_with_anchor = 0 }
        local function dispatch_one(group)
            if group.anchor then
                local atype = group.anchor.type
                if atype == "explicit" or atype == "pdf_page" then
                    calls.paint_anchor_group = calls.paint_anchor_group + 1
                else
                    calls.paint_with_anchor = calls.paint_with_anchor + 1
                end
            end
        end
        dispatch_one({ anchor = { type = "explicit", xp = "/body/p[3]/text()" } })
        assert.equals(1, calls.paint_anchor_group)
        assert.equals(0, calls.paint_with_anchor)
    end)

    it("G3-M8.5-WR-2: paintTo dispatches pdf_page-anchor groups via PdfAnchor.should_render", function()
        local body = get_paintTo_body()
        assert.is_not_nil(body)
        assert.is_truthy(body:find('"pdf_page"', 1, true),
            "paintTo must reference \"pdf_page\" anchor.type in dispatch (G3-M8.5-WR-2)")
        -- Must gate pdf_page via the explicit page-equality predicate
        -- (defensive against a future getGroupCurrentPage refactor).
        assert.is_truthy(body:find("PdfAnchor", 1, true),
            "paintTo must require / reference PdfAnchor for pdf_page page-gate (G3-M8.5-WR-2)")
        assert.is_truthy(body:find("should_render", 1, true),
            "paintTo must call PdfAnchor.should_render to gate pdf_page rendering (G3-M8.5-WR-2)")

        -- Behavioural mirror: pdf_page on captured page renders; on
        -- a different page is gated out.
        local calls = { paint_anchor_group = 0 }
        local function dispatch_one(group, current_page)
            if group.anchor then
                local atype = group.anchor.type
                if atype == "explicit" or atype == "pdf_page" then
                    -- Mirror the should_render gate
                    local gate_ok = true
                    if atype == "pdf_page"
                            and group.anchor.page ~= current_page then
                        gate_ok = false
                    end
                    if gate_ok then
                        calls.paint_anchor_group = calls.paint_anchor_group + 1
                    end
                end
            end
        end
        dispatch_one({ anchor = { type = "pdf_page", page = 5 } }, 5)
        assert.equals(1, calls.paint_anchor_group)
        dispatch_one({ anchor = { type = "pdf_page", page = 5 } }, 7)
        assert.equals(1, calls.paint_anchor_group)  -- still 1; off-page gated out
    end)

    it("G3-M8.5-WR-3: nil-anchor groups skip the anchor-owned dispatch (earned-path preservation)", function()
        local body = get_paintTo_body()
        assert.is_not_nil(body)
        -- The anchor-owned loop must still gate on `if group.anchor`
        -- (the nil-anchor case never enters the dispatch — it falls
        -- through to the renderStroke fallback below the loop).
        assert.is_truthy(body:find("if group.anchor", 1, true),
            "paintTo anchor-owned loop must still gate on `if group.anchor` so nil-anchor groups bypass it (G3-M8.5-WR-3)")

        -- Behavioural mirror: nil-anchor group invokes neither callback.
        local calls = { paint_anchor_group = 0, paint_with_anchor = 0 }
        local function dispatch_one(group)
            if group.anchor then
                local atype = group.anchor.type
                if atype == "explicit" or atype == "pdf_page" then
                    calls.paint_anchor_group = calls.paint_anchor_group + 1
                else
                    calls.paint_with_anchor = calls.paint_with_anchor + 1
                end
            end
        end
        dispatch_one({ anchor = nil })
        assert.equals(0, calls.paint_anchor_group,
            "nil-anchor must NOT call paint_anchor_group (earned path)")
        assert.equals(0, calls.paint_with_anchor,
            "nil-anchor must NOT call paint_with_anchor (earned path; falls through to renderStroke fallback)")
    end)

    it("G3-M8.5-WR-4: line-anchor groups still call paint_with_anchor (BYTE-IDENTICAL G2 earned path)", function()
        local body = get_paintTo_body()
        assert.is_not_nil(body)
        -- The Goal-2 entry point must still be called for line / nil
        -- (the else branch of the new 4-branch dispatch).
        assert.is_truthy(body:find("paint_with_anchor", 1, true),
            "paintTo must still call StrokePaint.paint_with_anchor for line/nil anchors (earned-path preserved; G3-M8.5-WR-4)")

        -- Behavioural mirror: line-anchor group routes to paint_with_anchor.
        local calls = { paint_anchor_group = 0, paint_with_anchor = 0 }
        local function dispatch_one(group)
            if group.anchor then
                local atype = group.anchor.type
                if atype == "explicit" or atype == "pdf_page" then
                    calls.paint_anchor_group = calls.paint_anchor_group + 1
                else
                    calls.paint_with_anchor = calls.paint_with_anchor + 1
                end
            end
        end
        dispatch_one({ anchor = { type = "line", xp = "/body/p[3]/text()",
                                  dx_em = 0.4, dy_lh = 0.2 } })
        assert.equals(1, calls.paint_with_anchor,
            "line-anchor must route to paint_with_anchor (Goal-2 earned path)")
        assert.equals(0, calls.paint_anchor_group,
            "line-anchor must NOT route to paint_anchor_group")
    end)

    it("G3-M8.5-WR-6: paintTo executor handles every op type emitted by paint_anchor_group", function()
        local body = get_paintTo_body()
        assert.is_not_nil(body)
        -- Every render-op type that paint_anchor_group can emit must have
        -- a matching `op.type == "..."` executor branch in paintTo. Per
        -- the analyst v2 delta: the no_ux_changes constraint meant 'no
        -- new behaviors beyond what paint_anchor_group already implements',
        -- NOT 'skip executing the visual ops'. highlight_underline,
        -- connector, and exclamation are Goal-3's core visual deliverables
        -- and MUST execute (G3 DoD #1 is unsatisfiable without them).
        for _, optype in ipairs({"stroke", "badge",
                                  "highlight_underline", "connector",
                                  "exclamation"}) do
            local needle = 'op.type == "' .. optype .. '"'
            assert.is_truthy(body:find(needle, 1, true),
                "paintTo executor must handle op.type=='" .. optype
                .. "' (G3-M8.5-WR-6)")
        end
    end)

    it("G3-M9-PULSE-1: _drawAnchorExclamation schedules a UIManager pulse when op.pulse==true", function()
        -- G3-M9: the exclamation glyph delivers a one-shot e-ink
        -- pulse on first paint (EXCLAMATION_PULSE_DURATION_MS = 300ms,
        -- per lib/anchor_constants.lua). Implementation: when
        -- op.pulse is truthy AND the instance flag
        -- _exclamation_pulse_scheduled is not yet set, call
        -- UIManager:scheduleIn(EXCLAMATION_PULSE_DURATION_MS/1000, fn)
        -- and set the flag to prevent re-scheduling on subsequent
        -- paints.

        -- Source-level: the helper body must reference UIManager
        -- scheduleIn, the EXCLAMATION_PULSE_DURATION_MS constant
        -- (via AnchorConstants), and the instance flag.
        local src = read_file(MAIN_LUA)
        local body = findHandlerBody(src, "_drawAnchorExclamation")
        assert.is_not_nil(body,
            "_drawAnchorExclamation helper body must be findable")
        assert.is_truthy(body:find("scheduleIn", 1, true),
            "_drawAnchorExclamation must call UIManager:scheduleIn for the first-paint pulse (G3-M9-PULSE-1)")
        assert.is_truthy(body:find("EXCLAMATION_PULSE_DURATION_MS", 1, true),
            "_drawAnchorExclamation must source the pulse delay from AnchorConstants.EXCLAMATION_PULSE_DURATION_MS (G3-M9-PULSE-1)")
        assert.is_truthy(body:find("_exclamation_pulse_scheduled", 1, true),
            "_drawAnchorExclamation must guard the scheduler with the _exclamation_pulse_scheduled instance flag so the pulse is one-shot per Pencil instance (G3-M9-PULSE-1)")

        -- Behavioural mirror: a fake exclamation drawer that
        -- captures UIManager:scheduleIn calls. Verifies:
        --   - op.pulse=true on a fresh instance → 1 schedule call
        --   - op.pulse=true on the same instance again → 0 new schedule
        --     (one-shot per instance per the _exclamation_pulse_scheduled
        --     guard)
        --   - op.pulse=false → 0 schedule calls
        local schedule_calls = 0
        local function fake_draw_exclamation(instance, op, ui_manager)
            if op.pulse and not instance._exclamation_pulse_scheduled then
                instance._exclamation_pulse_scheduled = true
                ui_manager:scheduleIn(0.3, function() end)
            end
        end
        local fake_um = {
            scheduleIn = function(_, _, _)
                schedule_calls = schedule_calls + 1
            end,
        }
        local pencil = {}
        fake_draw_exclamation(pencil, { pulse = true }, fake_um)
        assert.equals(1, schedule_calls)
        fake_draw_exclamation(pencil, { pulse = true }, fake_um)
        assert.equals(1, schedule_calls,
            "second pulse=true paint on same instance must NOT re-schedule")
        fake_draw_exclamation({}, { pulse = false }, fake_um)
        assert.equals(1, schedule_calls,
            "pulse=false must NOT schedule")
    end)

    it("G3-M8.5-WR-5: stale-rotation filter bypasses explicit/pdf_page via type-guard", function()
        local body = get_paintTo_body()
        assert.is_not_nil(body)
        -- Find the stale-rotation filter region — it begins with the
        -- "local stale_indices = nil" declaration and ends just before
        -- the anchor-owned loop.
        local stale_start = body:find("local stale_indices", 1, true)
        assert.is_not_nil(stale_start,
            "stale-rotation filter region must be locatable in paintTo")
        local stale_end = body:find("local anchor_owned", stale_start, true)
        assert.is_not_nil(stale_end,
            "anchor-owned region must follow stale-rotation filter")
        local stale_region = body:sub(stale_start, stale_end)
        -- The type-guard inside the stale-rotation region must mention
        -- BOTH "explicit" and "pdf_page" so Goal-3 anchored groups
        -- bypass the Goal-2 stale-rotation badge bookkeeping.
        assert.is_truthy(stale_region:find('"explicit"', 1, true),
            "stale-rotation filter region must contain \"explicit\" type-guard (G3-M8.5-WR-5)")
        assert.is_truthy(stale_region:find('"pdf_page"', 1, true),
            "stale-rotation filter region must contain \"pdf_page\" type-guard (G3-M8.5-WR-5)")

        -- Behavioural mirror: a group with explicit/pdf_page anchor
        -- type bypasses the bookkeeping increment.
        local function should_bypass(group)
            return group.anchor
               and (group.anchor.type == "explicit"
                 or group.anchor.type == "pdf_page")
        end
        assert.is_true(should_bypass({ anchor = { type = "explicit" } }))
        assert.is_true(should_bypass({ anchor = { type = "pdf_page" } }))
        assert.is_falsy(should_bypass({ anchor = { type = "line" } }))
        assert.is_falsy(should_bypass({ anchor = nil }))
    end)

end)
