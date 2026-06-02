--[[--
Unit tests for lib/annotation_persistence — pure-Lua serialize /
deserialize round-trip for the {version, strokes, annotation_groups}
state shape that main.lua's saveStrokes / loadStrokes use on disk.

Specs PER3-1..PER3-5 per Goal-3 plan §G3-6 (leader's G3-M6 spec list,
which redefines the PER3 scope: PER3-1 covers the save-after-delete
lifecycle via a callback mock; PER3-2..PER3-3 cover round-trip
correctness; PER3-4..PER3-5 cover the empty-store edge cases). The
original plan §G3-6 PER3 list (anchor-schema field-by-field round-
trip) is subsumed here by deep-equal assertions and is covered
implicitly by PER3-3.

Run with: busted spec/annotation_persistence_spec.lua

The serialize / deserialize / round_trip surfaces are pure Lua —
no CRengine dependencies, no require('main'). Serialization uses
KOReader's `dump` module (the same module saveStrokes calls in
main.lua:4658) so the on-disk format is identical.
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local AnnotationPersistence = require("lib/annotation_persistence")
local EraserTap             = require("lib/eraser_tap")

local function deep_equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

describe("AnnotationPersistence round-trip (G3-PER3-1..G3-PER3-5)", function()

    it("G3-PER3-1: after eraser-tap delete, save callback is invoked exactly once", function()
        -- The eraser_tap → save coupling: EraserTap.handle_tap fires its
        -- save_fn argument exactly once after a successful delete. This
        -- spec proves the persistence lifecycle hooks together with the
        -- delete handler.
        local state = {
            annotation_groups = {
                { anchor = { type = "explicit" },
                  cluster_bbox = { x = 100, y = 100, w = 80, h = 60 },
                  stroke_indices = { 1, 2, 3 } },
            },
            tool_active = "eraser",
        }
        local save_count = 0
        local function save_fn() save_count = save_count + 1 end

        EraserTap.handle_tap(150, 150, 0, state, save_fn)

        assert.are.equal(1, save_count)
    end)

    it("G3-PER3-2: deleted annotation absent from serialize → deserialize reload", function()
        local state = {
            version = 3,
            strokes = {},
            annotation_groups = {
                { label = "A", anchor = { type = "explicit" },
                  cluster_bbox = { x = 0, y = 0, w = 50, h = 50 } },
                { label = "B", anchor = { type = "explicit" },
                  cluster_bbox = { x = 100, y = 100, w = 80, h = 60 } },
                { label = "C", anchor = { type = "explicit" },
                  cluster_bbox = { x = 300, y = 300, w = 40, h = 40 } },
            },
        }
        EraserTap.handle_tap(150, 150, 0, state, nil)  -- removes B

        local reloaded = AnnotationPersistence.round_trip(state)

        assert.are.equal(2, #reloaded.annotation_groups)
        for _, g in ipairs(reloaded.annotation_groups) do
            assert.are_not.equal("B", g.label)
        end
    end)

    it("G3-PER3-3: surviving annotations deep-equal after round-trip", function()
        -- Cover all four anchor.type variants (nil / line / explicit /
        -- pdf_page) so the round-trip exercises every dispatcher branch
        -- documented in lib/anchor_constants.lua's 4-value schema.
        local state = {
            version = 3,
            strokes = { { tool = "pen", points = { { x = 1, y = 2 } } } },
            annotation_groups = {
                { label = "legacy",    anchor = nil },
                { label = "line-G2",   anchor = { type = "line",
                                                  xp = "/body/p[3]/text()[1]",
                                                  dx_em = 0.4, dy_lh = 0.2 } },
                { label = "explicit",  anchor = { type = "explicit",
                                                  xp = "/body/p[5]/text()[1]",
                                                  cluster_bbox = { x = 10, y = 20, w = 30, h = 40 },
                                                  scale = 0.9,
                                                  clarified = true } },
                { label = "pdf_page",  anchor = { type = "pdf_page", page = 17 } },
            },
        }

        local reloaded = AnnotationPersistence.round_trip(state)

        assert.is_true(deep_equal(state, reloaded))
    end)

    it("G3-PER3-4: empty annotation_groups serializes cleanly (no error)", function()
        local state = { version = 3, strokes = {}, annotation_groups = {} }
        local source = AnnotationPersistence.serialize(state)
        assert.is_string(source)
        -- Smoke: serialized form is a valid Lua return statement.
        assert.is_truthy(source:match("^return "))
    end)

    it("G3-PER3-5: empty store reload yields empty annotation_groups (no error)", function()
        local state = { version = 3, strokes = {}, annotation_groups = {} }
        local reloaded = AnnotationPersistence.round_trip(state)
        assert.is_table(reloaded)
        assert.is_table(reloaded.annotation_groups)
        assert.are.equal(0, #reloaded.annotation_groups)
    end)

end)
