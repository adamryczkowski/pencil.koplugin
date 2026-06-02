--[[--
Unit tests for lib/stroke_paint.paint_anchor_group — Goal-3 paint-time
dispatch + render-op-list geometry.

Specs PT-1..PT-8 per Goal-3 plan §2 (G3-M4).

The function under test is pure: it consumes a group + scalars and
returns a render_op_list describing what the caller (main.lua paintTo)
must draw. Callbacks are passed for signature stability but the
function does not invoke them — the caller is the executor. This
makes the function fully busted-testable with a plain-table doc
mock and no UIManager/Blitbuffer/ReaderUI dependency.

Render-op ordering invariant (LOCKED, plan §1.7):

    highlight_underline  <  connector  <  stroke  <  exclamation  <  badge

(Connector is inserted between highlight_underline and stroke; not in
the LOCKED triple but consistent with the "underline family draws
under ink" rationale.)

Run with: busted spec/stroke_paint_anchor_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokePaint = require("lib/stroke_paint")

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function make_doc(opts)
    opts = opts or {}
    local doc = { _xp_queries = {} }
    function doc:getScreenPositionFromXPointer(xp)
        table.insert(self._xp_queries, xp)
        if opts.pcall_raises then error("simulated build-compat fail") end
        if opts.returns_nil then return nil end
        return opts.screen_y or 100, opts.screen_x or 50
    end
    return doc
end

local function find_op(ops, t)
    for i, op in ipairs(ops) do
        if op.type == t then return i, op end
    end
    return nil, nil
end

local function count_op(ops, t)
    local n = 0
    for _, op in ipairs(ops) do
        if op.type == t then n = n + 1 end
    end
    return n
end

local function noop() end

-- Standard callback bundle (none of these should fire for the pure
-- dispatch function; they exist for signature stability).
local function bundle()
    return noop, noop, noop, noop
end

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------

local EXPLICIT_CLARIFIED = {
    type = "explicit",
    xp = "/body/DocFragment[1]/p[3]/text()",
    cluster_bbox = { x = 200, y = 300, w = 80, h = 40 },
    scale = 1.0,
    clarified = true,
}

local EXPLICIT_AMBIGUOUS = {
    type = "explicit",
    xp = "/body/DocFragment[1]/p[3]/text()",
    cluster_bbox = { x = 200, y = 300, w = 80, h = 40 },
    scale = 1.0,
    clarified = false,
}

local PDF_PAGE_ANCHOR = {
    type = "pdf_page",
    page = 3,
}

local LINE_ANCHOR = {
    type = "line",
    xp = "/body/DocFragment[1]/p[3]/text()",
    dx_em = 1.5,
    dy_lh = 0.5,
}

-- ---------------------------------------------------------------------
-- Specs
-- ---------------------------------------------------------------------

describe("StrokePaint.paint_anchor_group", function()

    it("G3-PT-1: explicit-anchor group → render_op_list has stroke + connector + highlight_underline", function()
        local doc = make_doc({ screen_y = 350, screen_x = 50 })
        local group = { anchor = EXPLICIT_CLARIFIED, stroke_indices = { 1, 2 } }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        assert.is_table(ops)
        assert.is_true(count_op(ops, "highlight_underline") == 1)
        assert.is_true(count_op(ops, "connector") == 1)
        assert.is_true(count_op(ops, "stroke") == 1)
        -- clarified=true → no exclamation
        assert.equals(0, count_op(ops, "exclamation"))
        -- resolved → no badge
        assert.equals(0, count_op(ops, "badge"))
    end)

    it("G3-PT-2: pdf_page-anchor group → render_op_list contains stroke only", function()
        local doc = make_doc()  -- not used for pdf_page path
        local group = { anchor = PDF_PAGE_ANCHOR, stroke_indices = { 1 } }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        assert.is_table(ops)
        assert.equals(1, count_op(ops, "stroke"))
        assert.equals(0, count_op(ops, "connector"))
        assert.equals(0, count_op(ops, "highlight_underline"))
        assert.equals(0, count_op(ops, "exclamation"))
        assert.equals(0, count_op(ops, "badge"))
    end)

    it("G3-PT-3: nil-anchor group → empty render_op_list (caller routes to rotation-badge)", function()
        local doc = make_doc()
        local group = { anchor = nil, stroke_indices = { 1 } }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        assert.is_table(ops)
        assert.equals(0, #ops)
    end)

    it("G3-PT-4: line-anchor group → empty render_op_list (caller routes to Goal-2 paint_with_anchor)", function()
        local doc = make_doc()
        local group = { anchor = LINE_ANCHOR, stroke_indices = { 1 } }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        assert.is_table(ops)
        assert.equals(0, #ops)
    end)

    it("G3-PT-5: clarified=false → exclamation op included; LOCKED ordering respected", function()
        local doc = make_doc({ screen_y = 350, screen_x = 50 })
        local group = { anchor = EXPLICIT_AMBIGUOUS, stroke_indices = { 1 } }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        assert.equals(1, count_op(ops, "exclamation"))
        -- LOCKED ordering: highlight_underline < stroke < exclamation
        local i_uline = find_op(ops, "highlight_underline")
        local i_stroke = find_op(ops, "stroke")
        local i_exc = find_op(ops, "exclamation")
        assert.is_not_nil(i_uline)
        assert.is_not_nil(i_stroke)
        assert.is_not_nil(i_exc)
        assert.is_true(i_uline < i_stroke)
        assert.is_true(i_stroke < i_exc)
    end)

    it("G3-M9-HUE-1: exclamation op carries hue field (ANCHOR_UNDERLINE_HUE — single visual family)", function()
        -- G3-M9: paint_anchor_group emits op.hue for the exclamation
        -- branch so the paintTo executor can drop its hardcoded
        -- {75, 0, 130} fallback (hard-constraint #5 — no inline color
        -- literals at paint sites). The exclamation hue MUST match
        -- ANCHOR_UNDERLINE_HUE so the underline + connector +
        -- exclamation render as one visual family.
        local AnchorConstants = require("lib/anchor_constants")
        local doc = make_doc({ screen_y = 350, screen_x = 50 })
        local group = { anchor = EXPLICIT_AMBIGUOUS, stroke_indices = { 1 } }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        local _, exc = find_op(ops, "exclamation")
        assert.is_not_nil(exc)
        assert.is_table(exc.hue)
        assert.are.equal(AnchorConstants.ANCHOR_UNDERLINE_HUE.r, exc.hue.r)
        assert.are.equal(AnchorConstants.ANCHOR_UNDERLINE_HUE.g, exc.hue.g)
        assert.are.equal(AnchorConstants.ANCHOR_UNDERLINE_HUE.b, exc.hue.b)
    end)

    it("G3-PT-6: explicit-anchor group with stale rotation tag still reaches stroke draw", function()
        -- The stale-rotation filter is wired in main.lua and bypasses
        -- "explicit"/"pdf_page" groups via a type guard. paint_anchor_group
        -- itself does not consult any rotation tag — confirm it emits a
        -- stroke op for an explicit group regardless of stale_rotation_tag.
        local doc = make_doc({ screen_y = 350, screen_x = 50 })
        local stale_group = {
            anchor = EXPLICIT_CLARIFIED,
            stroke_indices = { 1, 2 },
            rotation_tag = "STALE_pre_g3",
            captured_rotation = 1,  -- "old" rotation
        }
        local dt, rb, ah, cn = bundle()
        local ops = StrokePaint.paint_anchor_group(
            stale_group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        assert.equals(1, count_op(ops, "stroke"))
        assert.equals(0, count_op(ops, "badge"))
    end)

    it("G3-PT-7: line-anchor returns empty {} (no regression for Goal-2 stationary render path)", function()
        -- Byte-equivalence proxy: paint_anchor_group is a no-op for the
        -- Goal-2 line-anchor variant. The caller's existing
        -- paint_with_anchor stays the source of truth — and is untouched
        -- by G3-M4. Repeated invocations are idempotent.
        local doc = make_doc({ screen_y = 350, screen_x = 50 })
        local group = { anchor = LINE_ANCHOR, stroke_indices = { 1 } }
        local dt, rb, ah, cn = bundle()
        for _ = 1, 5 do
            local ops = StrokePaint.paint_anchor_group(
                group, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
            assert.equals(0, #ops)
        end
        -- And: paint_with_anchor for the same group still routes through
        -- the Goal-2 draw_translated callback (not the badge).
        local hit, badge = 0, 0
        StrokePaint.paint_with_anchor(group, doc, 12, 20,
            function() hit = hit + 1 end,
            function() badge = badge + 1 end)
        assert.equals(1, hit)
        assert.equals(0, badge)
    end)

    it("G3-PT-8: N=10 explicit-anchor groups paint within a sane budget (perf proxy)", function()
        -- This is a perf PROXY (not a real-time gate). Documents that
        -- the pure dispatch is cheap enough to call 10× per paintTo
        -- tick. The Kobo refresh budget is ~250ms; we set a generous
        -- 100ms proxy for the pure-Lua scoring + op-list construction.
        local doc = make_doc({ screen_y = 350, screen_x = 50 })
        local dt, rb, ah, cn = bundle()
        local groups = {}
        for i = 1, 10 do
            groups[i] = {
                anchor = {
                    type = "explicit",
                    xp = "/body/p[" .. i .. "]/text()",
                    cluster_bbox = { x = 100 + i, y = 200 + i * 30, w = 80, h = 40 },
                    scale = 1.0,
                    clarified = (i % 2 == 0),
                },
                stroke_indices = { i },
            }
        end
        local t0 = os.clock()
        for _, g in ipairs(groups) do
            StrokePaint.paint_anchor_group(
                g, doc, 12, 20, 800, 600, 0, dt, rb, ah, cn)
        end
        local elapsed = os.clock() - t0
        assert.is_true(elapsed < 0.1,
            string.format("10 paint_anchor_group calls took %.4fs (budget 0.1s)", elapsed))
    end)

end)
