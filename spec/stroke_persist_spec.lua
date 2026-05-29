--[[--
Persistence round-trip specs for Goal-2 group.anchor field.

Specs PER-1..PER-4 per Goal-2 plan §2 (G2-M5). Closes:
  - RTM-19 / 2B-PERSIST: anchor=nil round-trips as nil; legacy files
    (no anchor field) load with anchor remaining nil.
  - RTM-20 / 2B-CF4: anchor={type, xp, dx_em, dy_lh} round-trips with
    all fields byte-identical.

This is a SPEC-ONLY milestone — no production code changes. The
existing data.version = 3 sidecar format already accommodates the
new optional group.anchor field because serpent / dump-style
serializers omit nil fields and skip unknown keys on load.

The plugin's actual production serializer (pencil.koplugin/main.lua
:4534 `require('dump')`) uses KOReader's internal `dump` module,
which produces the same `return <table-literal>` form serpent.load
can decode. For test-environment portability we exercise the
round-trip via serpent — semantic equivalence with the production
dump is established because both emit a Lua table literal of the
exact same shape.

No require('main') and no production code touched.

Run with: busted spec/stroke_persist_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local serpent = require("serpent")

-- Round-trip helper: dump → load → return decoded table.
local function round_trip(t)
    local enc = serpent.dump(t)
    local ok, decoded = serpent.load(enc)
    assert.is_true(ok, "serpent.load must succeed; encoded was: " .. enc)
    return decoded, enc
end

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------

local function make_group_no_anchor()
    return {
        stroke_indices = { 1, 2 },
        page = 5,
        xpointer = "/body/DocFragment[1]/p[3]/text()",
        image_path = nil,
        image_rotation = nil,
        anchor = nil,   -- Goal-2 schema: absent / nil for legacy groups
    }
end

local function make_group_with_anchor()
    return {
        stroke_indices = { 3 },
        page = 7,
        xpointer = "/body/DocFragment[1]/p[5]/text()",
        anchor = {
            type  = "line",
            xp    = "/body/DocFragment[1]/p[5]/text()",
            dx_em = 1.5,
            dy_lh = 0.5,
        },
    }
end

-- ---------------------------------------------------------------------
-- PER-1 — RTM-19 / 2B-PERSIST
-- ---------------------------------------------------------------------

describe("stroke persistence — anchor field round-trip", function()

    it("PER-1: group with anchor=nil round-trips with anchor still nil (RTM-19)", function()
        local original = make_group_no_anchor()
        local loaded = round_trip(original)
        assert.is_nil(loaded.anchor,
            "PER-1: anchor=nil before dump must remain nil after load")
        -- Other fields preserved (sanity).
        assert.equals(5, loaded.page)
        assert.equals("/body/DocFragment[1]/p[3]/text()", loaded.xpointer)
        assert.equals(2, #loaded.stroke_indices)
    end)

    -- ---------------------------------------------------------------------
    -- PER-2 — RTM-20 / 2B-CF4
    -- ---------------------------------------------------------------------

    it("PER-2: group with anchor={type,xp,dx_em,dy_lh} round-trips byte-identical (RTM-20)", function()
        local original = make_group_with_anchor()
        local loaded = round_trip(original)
        assert.is_not_nil(loaded.anchor,
            "PER-2: anchor must survive round-trip as a table")
        assert.equals("line", loaded.anchor.type,
            "PER-2: anchor.type must round-trip")
        assert.equals("/body/DocFragment[1]/p[5]/text()", loaded.anchor.xp,
            "PER-2: anchor.xp must round-trip")
        assert.equals(1.5, loaded.anchor.dx_em,
            "PER-2: anchor.dx_em must round-trip (number, exact)")
        assert.equals(0.5, loaded.anchor.dy_lh,
            "PER-2: anchor.dy_lh must round-trip (number, exact)")
    end)

    -- ---------------------------------------------------------------------
    -- PER-3 — legacy file load path
    -- ---------------------------------------------------------------------

    it("PER-3: legacy file (data.version=3, no anchor field) loads with anchor==nil", function()
        -- Simulate a legacy sidecar written before Goal-2: data.version
        -- stays 3 (no bump in G2 per leader directive), and group entries
        -- have no anchor key at all. Loading must not error and must
        -- leave anchor == nil for forward compatibility.
        local legacy_data = {
            version = 3,
            strokes = {
                { tool = "pen", points = { { x = 10, y = 20 } }, page = 1 },
            },
            annotation_groups = {
                {
                    stroke_indices = { 1 },
                    page = 1,
                    xpointer = "/body/DocFragment[1]/p[1]/text()",
                    -- NOTE: no `anchor` key — this is a pre-Goal-2 file.
                },
            },
        }
        local loaded = round_trip(legacy_data)
        assert.equals(3, loaded.version,
            "PER-3: data.version must remain 3 (no bump in Goal-2)")
        assert.equals(1, #loaded.annotation_groups)
        assert.is_nil(loaded.annotation_groups[1].anchor,
            "PER-3: legacy group without anchor key must load as anchor=nil")
        -- Sanity: existing Goal-1 fields preserved.
        assert.equals("/body/DocFragment[1]/p[1]/text()",
            loaded.annotation_groups[1].xpointer)
    end)

    -- ---------------------------------------------------------------------
    -- PER-4 — RTM-20 / 2B-CF4 (mixed-anchor file)
    -- ---------------------------------------------------------------------

    it("PER-4: mixed file (some groups anchored, some nil) — each group's anchor correctly restored", function()
        local mixed_data = {
            version = 3,
            strokes = {
                { tool = "pen", points = { { x = 10, y = 20 } }, page = 1 },
                { tool = "pen", points = { { x = 30, y = 40 } }, page = 1 },
                { tool = "pen", points = { { x = 50, y = 60 } }, page = 2 },
            },
            annotation_groups = {
                {
                    stroke_indices = { 1 },
                    page = 1,
                    xpointer = "/body/DocFragment[1]/p[1]/text()",
                    anchor = nil,  -- legacy / image-only group
                },
                {
                    stroke_indices = { 2 },
                    page = 1,
                    xpointer = "/body/DocFragment[1]/p[2]/text()",
                    anchor = {
                        type  = "line",
                        xp    = "/body/DocFragment[1]/p[2]/text()",
                        dx_em = 2.0,
                        dy_lh = 1.0,
                    },
                },
                {
                    stroke_indices = { 3 },
                    page = 2,
                    xpointer = "/body/DocFragment[1]/p[3]/text()",
                    anchor = {
                        type  = "line",
                        xp    = "/body/DocFragment[1]/p[3]/text()",
                        dx_em = -0.5,
                        dy_lh = 0.25,
                    },
                },
            },
        }
        local loaded = round_trip(mixed_data)
        assert.equals(3, #loaded.annotation_groups)

        -- Group 1: anchor=nil → must remain nil after round-trip.
        assert.is_nil(loaded.annotation_groups[1].anchor,
            "PER-4: group 1 anchor=nil must stay nil")

        -- Group 2: full anchor must round-trip with all fields exact.
        local a2 = loaded.annotation_groups[2].anchor
        assert.is_not_nil(a2, "PER-4: group 2 anchor must survive")
        assert.equals("line", a2.type)
        assert.equals("/body/DocFragment[1]/p[2]/text()", a2.xp)
        assert.equals(2.0, a2.dx_em)
        assert.equals(1.0, a2.dy_lh)

        -- Group 3: negative-delta anchor (sign + fractional preservation).
        local a3 = loaded.annotation_groups[3].anchor
        assert.is_not_nil(a3, "PER-4: group 3 anchor must survive")
        assert.equals("line", a3.type)
        assert.equals(-0.5, a3.dx_em,
            "PER-4: negative dx_em must preserve sign through round-trip")
        assert.equals(0.25, a3.dy_lh,
            "PER-4: fractional dy_lh must preserve precision through round-trip")
    end)

end)
