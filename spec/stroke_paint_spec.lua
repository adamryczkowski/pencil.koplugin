--[[--
Unit + source tests for lib/stroke_paint and Goal-2 paint-time wiring.

Specs SP-1..SP-7 per Goal-2 plan §2 (G2-M4).

Behavioural specs SP-1..SP-5 test lib/stroke_paint.paint_with_anchor
directly with mock `doc` and injected callbacks (no require('main')).

SP-6 and SP-7 mix behavioural + source-level assertions:
  SP-6 — source-level: the 5 pre-reflow handlers in main.lua each call
         self:_clearStrokeAnchorCache(); behavioural: a fresh
         paint_with_anchor invocation always re-queries
         getScreenPositionFromXPointer (no internal cache leak).
  SP-7 — integration: capture from stroke start-point on a multi-line
         stroke (vertical span > GROUP_SPATIAL_THRESHOLD) yields an
         anchor whose xpointer is the START-LINE; paint then resolves
         to the start-line's screen position.

Source-level checks follow the pencil_text_highlight_reflow_lag_spec
stripLuaComments helper precedent (avoid false positives from comments).

Run with: busted spec/stroke_paint_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local StrokePaint   = require("lib/stroke_paint")
local StrokeCapture = require("lib/stroke_capture")

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- Mock doc whose getScreenPositionFromXPointer is configurable.
-- @param opts {
--    screen_y       = number|nil  -- returned screen_y
--    screen_x       = number|nil  -- returned screen_x
--    pcall_raises   = bool        -- if true, raise inside
--    returns_nil    = bool        -- if true, return nil from the call
-- }
-- Also records each xpointer queried so we can count re-resolves.
local function make_paint_doc(opts)
    opts = opts or {}
    local doc = { xpointer_queries = {} }
    function doc:getScreenPositionFromXPointer(xp)
        table.insert(self.xpointer_queries, xp)
        if opts.pcall_raises then error("simulated build-compat fail") end
        if opts.returns_nil then return nil end
        return opts.screen_y, opts.screen_x
    end
    return doc
end

local function read_file(path)
    local f = io.open(path, "r")
    assert.is_not_nil(f, path .. " must be readable from project root")
    local src = f:read("*a")
    f:close()
    return src
end

local function stripLuaComments(s)
    -- Strip Lua block comments first (--[[ ... ]] / --[[-- ... --]]--).
    -- Non-greedy: handles the doc-style block used in lib/*.lua headers.
    s = s:gsub("%-%-%[%[.-%]%]", "")
    -- Then strip single-line --... comments.
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

local PRE_REFLOW_EVENTS = {
    "onSetDimensions",
    "onSetFontSize",
    "onSetFont",
    "onSetLineSpace",
    "onSetPageMargins",
}

local VALID_ANCHOR = {
    type  = "line",
    xp    = "/body/DocFragment[1]/p[3]/text()",
    dx_em = 1.5,
    dy_lh = 0.5,
}

-- ---------------------------------------------------------------------
-- SP-1..SP-5: behavioural specs on lib/stroke_paint
-- ---------------------------------------------------------------------

describe("StrokePaint.paint_with_anchor", function()

    it("SP-1: anchor hit + screen_y>=0 → draw_translated_fn called with tx/ty", function()
        local doc = make_paint_doc({ screen_y = 100, screen_x = 50 })
        local group = { anchor = VALID_ANCHOR }
        local em_px, lh_px = 10, 20
        local drawn_with
        local draw_translated_fn = function(g, tx, ty)
            drawn_with = { g = g, tx = tx, ty = ty }
        end
        local rotation_badge_called = false
        local rotation_badge_fn = function() rotation_badge_called = true end

        StrokePaint.paint_with_anchor(group, doc, em_px, lh_px,
            draw_translated_fn, rotation_badge_fn)

        assert.is_not_nil(drawn_with, "draw_translated_fn must be called")
        assert.equals(group, drawn_with.g)
        -- tx = screen_x + dx_em*em_px = 50 + 1.5*10 = 65
        -- ty = screen_y + dy_lh*lh_px = 100 + 0.5*20 = 110
        assert.equals(65, drawn_with.tx)
        assert.equals(110, drawn_with.ty)
        assert.is_false(rotation_badge_called)
    end)

    it("SP-2: anchor hit + screen_y<0 → silent clip; NEITHER drawer NOR badge called", function()
        local doc = make_paint_doc({ screen_y = -50, screen_x = 50 })
        local group = { anchor = VALID_ANCHOR }
        local drawn = false
        local badged = false
        StrokePaint.paint_with_anchor(group, doc, 10, 20,
            function() drawn = true end,
            function() badged = true end)
        assert.is_false(drawn,
            "SP-2: screen_y<0 must NOT call draw_translated_fn")
        assert.is_false(badged,
            "SP-2: screen_y<0 must NOT call rotation_badge_fn — anchor is valid, just off-page")
    end)

    it("SP-3: getScreenPositionFromXPointer pcall raises → rotation_badge_fn called (EARNED)", function()
        local doc = make_paint_doc({ pcall_raises = true })
        local group = { anchor = VALID_ANCHOR }
        local drawn = false
        local badged_with
        StrokePaint.paint_with_anchor(group, doc, 10, 20,
            function() drawn = true end,
            function(g) badged_with = g end)
        assert.is_false(drawn)
        assert.equals(group, badged_with,
            "SP-3: pcall failure must route to rotation_badge_fn(group)")
    end)

    it("SP-4: group.anchor == nil → rotation_badge_fn called (legacy/image-only)", function()
        local doc = make_paint_doc({ screen_y = 100, screen_x = 50 })
        local group = { anchor = nil }
        local drawn = false
        local badged_with
        StrokePaint.paint_with_anchor(group, doc, 10, 20,
            function() drawn = true end,
            function(g) badged_with = g end)
        assert.is_false(drawn,
            "SP-4: anchor=nil must NOT call draw_translated_fn")
        assert.equals(group, badged_with,
            "SP-4: anchor=nil must call rotation_badge_fn(group)")
        assert.equals(0, #doc.xpointer_queries,
            "SP-4: with anchor=nil there's no xpointer to query")
    end)

    it("SP-5: lib/stroke_paint.lua does NOT inherit Goal-1 lighten/highlighter wiring", function()
        -- TOOL_PEN ink style is the draw_translated_fn callback's
        -- responsibility (RTM-15 / UX-C2). The lib must not reference the
        -- Goal-1 highlighter colour drawer, the `lighten` blend mode, or
        -- the HighlightColorWiring module — those belong to Path A.
        local src = stripLuaComments(read_file(
            "pencil.koplugin/lib/stroke_paint.lua"))
        assert.falsy(src:find("HighlightColorWiring", 1, true),
            "SP-5: lib/stroke_paint.lua must NOT reference HighlightColorWiring")
        assert.falsy(src:find("highlight_color_wiring", 1, true),
            "SP-5: lib/stroke_paint.lua must NOT reference highlight_color_wiring")
        assert.falsy(src:find("lighten", 1, true),
            "SP-5: lib/stroke_paint.lua must NOT reference the `lighten` blend drawer")
        -- Also verify paint_with_anchor passes the group through to the
        -- drawer unmodified — no style mutation in the lib.
        local doc = make_paint_doc({ screen_y = 50, screen_x = 30 })
        local group = {
            anchor = VALID_ANCHOR,
            tool = "pen",        -- TOOL_PEN sentinel; must survive intact
            color = "#000000",
        }
        local drawer_saw
        StrokePaint.paint_with_anchor(group, doc, 10, 20,
            function(g) drawer_saw = g end, function() end)
        assert.equals("pen", drawer_saw.tool,
            "SP-5: paint_with_anchor must not mutate group.tool")
        assert.equals("#000000", drawer_saw.color,
            "SP-5: paint_with_anchor must not mutate group.color")
    end)

end)

-- ---------------------------------------------------------------------
-- SP-6: reflow handlers + cache-clear invariants
-- ---------------------------------------------------------------------

describe("SP-6 reflow invalidation", function()

    it("SP-6: each of the 5 pre-reflow handlers calls self:_clearStrokeAnchorCache()", function()
        local src = read_file("pencil.koplugin/main.lua")
        for _, name in ipairs(PRE_REFLOW_EVENTS) do
            local body = findHandlerBody(src, name)
            assert.is_not_nil(body,
                "SP-6: Pencil:" .. name .. " must still be defined")
            -- The existing Goal-1 line (Pencil:onSetDimensions etc. each
            -- call pcall(self.ui.view.resetHighlightBoxesCache, ...)) MUST
            -- remain — RTM-25, R2 / G1-regression guard.
            assert.is_truthy(body:find("resetHighlightBoxesCache", 1, true),
                "SP-6: Pencil:" .. name .. " must STILL call " ..
                "resetHighlightBoxesCache (Goal-1 line preserved)")
            -- And Goal-2 adds one new line.
            assert.is_truthy(body:find("_clearStrokeAnchorCache", 1, true),
                "SP-6: Pencil:" .. name ..
                " must also call self:_clearStrokeAnchorCache()")
        end
    end)

    it("SP-6: Pencil:_clearStrokeAnchorCache is defined in main.lua", function()
        local src = read_file("pencil.koplugin/main.lua")
        local body = findHandlerBody(src, "_clearStrokeAnchorCache")
        assert.is_not_nil(body,
            "SP-6: Pencil:_clearStrokeAnchorCache must be defined in main.lua")
    end)

    it("SP-6: paint_with_anchor re-resolves xpointer on each call (no stale lib-internal cache)", function()
        -- The cache lives on the Pencil instance, not in the lib.
        -- lib/stroke_paint must therefore query the doc every time —
        -- otherwise a stale cache would survive across reflow events.
        local doc = make_paint_doc({ screen_y = 100, screen_x = 50 })
        local group = { anchor = VALID_ANCHOR }
        StrokePaint.paint_with_anchor(group, doc, 10, 20,
            function() end, function() end)
        StrokePaint.paint_with_anchor(group, doc, 10, 20,
            function() end, function() end)
        assert.equals(2, #doc.xpointer_queries,
            "SP-6: each paint_with_anchor call must re-query " ..
            "getScreenPositionFromXPointer; lib must not memoize")
        for _, xp in ipairs(doc.xpointer_queries) do
            assert.equals(VALID_ANCHOR.xp, xp)
        end
    end)

end)

-- ---------------------------------------------------------------------
-- SP-7: multi-line stroke anchors to its START-LINE
-- ---------------------------------------------------------------------

describe("SP-7 multi-line stroke anchors to start-line", function()

    -- GROUP_SPATIAL_THRESHOLD is declared at main.lua:111 and equals 200.
    -- Multi-line stroke = vertical span greater than the threshold; under
    -- the current scheme that's a single group whose start-point chooses
    -- the line anchor (capture uses stroke.points[1] exclusively, so the
    -- end-line / centre-line never wins — 2B-UX-C1, 2B-CF3).
    local GROUP_SPATIAL_THRESHOLD = 200

    -- Mock doc whose word lookups discriminate by y so we can prove the
    -- start-line (not end-line) won.
    -- Mock matches the real CreDocument:getWordFromPosition shape:
    -- {word, sbox, pos0, pos1} — see credocument.lua:605-680.
    local function make_capture_doc()
        return {
            getWordFromPosition = function(self, pos, do_not_draw_selection)
                if pos.y <= 150 then
                    return {
                        word = "top",
                        pos0 = "x/top-line",
                        pos1 = "x/top-line.3",
                        sbox = { x = 20, y = 100, w = 200, h = 20 },
                    }
                elseif pos.y >= 350 then
                    return {
                        word = "bot",
                        pos0 = "x/bottom-line",
                        pos1 = "x/bottom-line.3",
                        sbox = { x = 20, y = 400, w = 200, h = 20 },
                    }
                end
                return nil
            end,
            getNearestWordAndBoxFromPosition = function() return nil end,
        }
    end

    it("SP-7: GROUP_SPATIAL_THRESHOLD declared near top of main.lua with value 200", function()
        local src = read_file("pencil.koplugin/main.lua")
        local lines = {}
        for line in src:gmatch("[^\n]*\n?") do
            table.insert(lines, line)
        end
        -- Plan §2 cites main.lua:111; allow ±5 line drift across edits.
        local found_decl_line = nil
        for i = 100, math.min(120, #lines) do
            local l = lines[i] or ""
            if l:find("GROUP_SPATIAL_THRESHOLD", 1, true)
                    and l:find("=", 1, true)
                    and l:find("200", 1, true) then
                found_decl_line = i
                break
            end
        end
        assert.is_not_nil(found_decl_line,
            "SP-7: GROUP_SPATIAL_THRESHOLD = 200 must be declared near main.lua:111")
    end)

    it("SP-7: capture from start-point of a multi-line stroke anchors to TOP line", function()
        local capture_doc = make_capture_doc()
        -- Vertical span 300 > GROUP_SPATIAL_THRESHOLD=200 → multi-line.
        local stroke_points = {
            { x = 50, y = 100 },   -- start-line (top)
            { x = 60, y = 250 },   -- middle
            { x = 70, y = 400 },   -- end-line (bottom)
        }
        local vspan = stroke_points[#stroke_points].y - stroke_points[1].y
        assert.is_true(vspan > GROUP_SPATIAL_THRESHOLD,
            "fixture must be multi-line by the GROUP_SPATIAL_THRESHOLD definition")
        local stroke_start_pt = stroke_points[1]
        local anchor = StrokeCapture.compute_anchor(capture_doc, stroke_start_pt)
        assert.is_not_nil(anchor)
        assert.equals("x/top-line", anchor.xp,
            "SP-7: anchor.xp must come from the START line, not the end-line")
    end)

    it("SP-7: paint of a multi-line group resolves through start-line xpointer only", function()
        -- Paint stage: mock getScreenPositionFromXPointer records the
        -- xpointer queried — must equal the start-line xpointer set at
        -- capture time.
        local paint_doc = make_paint_doc({ screen_y = 100, screen_x = 50 })
        local group = {
            anchor = {
                type = "line",
                xp = "x/top-line",
                dx_em = 0,
                dy_lh = 0,
            },
        }
        local drawn_with
        StrokePaint.paint_with_anchor(group, paint_doc, 10, 20,
            function(g, tx, ty) drawn_with = { tx = tx, ty = ty } end,
            function() end)
        assert.equals(1, #paint_doc.xpointer_queries)
        assert.equals("x/top-line", paint_doc.xpointer_queries[1],
            "SP-7: paint must resolve via the start-line xpointer")
        assert.equals(50,  drawn_with.tx)   -- screen_x + 0
        assert.equals(100, drawn_with.ty)   -- screen_y + 0
    end)

end)
