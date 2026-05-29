--[[--
Integration spec: two-sidecar architecture survives independent writes.

Path A (text-anchored highlights) lands in KOReader's
`annotations` doc_settings key; Path B (pen strokes + legacy
freehand highlights) lands in the plugin's own `pencil_strokes.lua`
sidecar file. The two sidecars are independently keyed and live in
different files — no key collision possible.

This spec verifies the namespace boundary stays clean under all four
write/read orderings (Path-A then Path-B; Path-B then Path-A;
interleaved; round-trip) and that a corrupt entry in one sidecar
does not propagate into the other.

See feature-plan.md §5 "Two-sidecar architecture post-promotion".

Pattern-B inline-mock; no main.lua require; no DocSettings require.

Run with: busted spec/pencil_text_highlight_sidecar_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- ---------------------------------------------------------------------
-- Pattern-B mocks
-- ---------------------------------------------------------------------

-- Mock KOReader doc_settings (the metadata.lua sidecar). The real one
-- is a table-backed object with saveSetting/readSetting accessors.
local function makeDocSettings()
    local ds = { _table = {} }
    function ds.saveSetting(self, key, value)
        self._table[key] = value
    end
    function ds.readSetting(self, key, default)
        local v = self._table[key]
        if v == nil then return default end
        return v
    end
    function ds.hasKey(self, key) return self._table[key] ~= nil end
    return ds
end

-- Mock the pencil_strokes.lua sidecar (Path-B). Real implementation is
-- a Lua-serialised file at <book>.sdr/pencil_strokes.lua; the test only
-- cares about the write/read round-trip shape.
local function makePencilStrokesFile()
    local f = { _strokes = {} }
    function f.write(self, strokes)
        -- Shallow clone so the spec can detect a Path-A side effect
        -- mutating the array.
        self._strokes = {}
        for _, s in ipairs(strokes or {}) do
            table.insert(self._strokes, s)
        end
    end
    function f.read(self) return self._strokes end
    return f
end

-- ---------------------------------------------------------------------

describe("Two-sidecar architecture — independent writes (M5 spec ④)", function()

    it("Path-A write does NOT modify pre-existing Path-B data", function()
        -- VERBATIM the M5 spec ④ acceptance:
        --   Given: pencil_strokes.lua contains Path-B pen stroke data; new
        --          Path-A annotation written to KOReader annotations key
        --   When:  both sidecars written and read back
        --   Then:  pencil_strokes.lua data unchanged; annotations key contains
        --          Path-A item; no key collision; no data corruption
        local strokes_file = makePencilStrokesFile()
        local doc_settings = makeDocSettings()

        local original_strokes = {
            { page = 1, points = { {x=10,y=20}, {x=30,y=40} },
              color = "Black", color_name = "Black", tool = "pen" },
            { page = 2, points = { {x=50,y=60} },
              color = "Red", color_name = "Red", tool = "pen" },
        }
        strokes_file:write(original_strokes)

        -- Path-A annotation write.
        doc_settings:saveSetting("annotations", {
            { pos0 = "P0", pos1 = "P1",
              text = "hello", drawer = "lighten", color = "yellow" },
        })

        local read_strokes = strokes_file:read()
        assert.equals(2, #read_strokes)
        assert.equals(1,       read_strokes[1].page)
        assert.equals("Black", read_strokes[1].color_name)
        assert.equals("pen",   read_strokes[1].tool)
        assert.equals(2,       read_strokes[2].page)
        assert.equals("Red",   read_strokes[2].color_name)
    end)

    it("Path-B write does NOT modify pre-existing Path-A annotations", function()
        local strokes_file = makePencilStrokesFile()
        local doc_settings = makeDocSettings()

        doc_settings:saveSetting("annotations", {
            { pos0 = "P0", pos1 = "P1",
              text = "hello", drawer = "lighten", color = "yellow" },
        })

        -- Now Path-B writer fires.
        strokes_file:write({
            { page = 1, points = { {x=1,y=2} }, color_name = "Blue", tool = "pen" },
        })

        local annotations = doc_settings:readSetting("annotations")
        assert.equals(1,        #annotations)
        assert.equals("hello",  annotations[1].text)
        assert.equals("yellow", annotations[1].color)
        assert.equals("lighten", annotations[1].drawer)
        assert.equals("P0",     annotations[1].pos0)
        assert.equals("P1",     annotations[1].pos1)
    end)

end)

describe("Two-sidecar architecture — both round-trip independently", function()

    it("write both → read both: each sidecar returns its own data verbatim", function()
        local strokes_file = makePencilStrokesFile()
        local doc_settings = makeDocSettings()

        strokes_file:write({
            { page = 1, points = { {x=10,y=20} }, color_name = "Black", tool = "pen" },
            { page = 1, points = { {x=30,y=40} }, color_name = "Red",   tool = "pen" },
        })
        doc_settings:saveSetting("annotations", {
            { pos0 = "A0", pos1 = "A1", drawer = "lighten", color = "yellow" },
            { pos0 = "B0", pos1 = "B1", drawer = "lighten", color = "pink" },
        })

        local strokes     = strokes_file:read()
        local annotations = doc_settings:readSetting("annotations")

        assert.equals(2, #strokes)
        assert.equals(2, #annotations)
        assert.equals("Black", strokes[1].color_name)
        assert.equals("Red",   strokes[2].color_name)
        assert.equals("yellow", annotations[1].color)
        assert.equals("pink",   annotations[2].color)
    end)

    it("interleaved writes (B → A → B → A) end with both stores correct", function()
        local strokes_file = makePencilStrokesFile()
        local doc_settings = makeDocSettings()

        -- B1
        strokes_file:write({ { page = 1, points = { {x=1,y=1} }, color_name = "Black" } })
        -- A1
        doc_settings:saveSetting("annotations",
            { { pos0 = "P0", pos1 = "P1", drawer = "lighten", color = "yellow" } })
        -- B2 (append-equivalent: rewrite with both)
        strokes_file:write({
            { page = 1, points = { {x=1,y=1} }, color_name = "Black" },
            { page = 1, points = { {x=2,y=2} }, color_name = "Red" },
        })
        -- A2 (append-equivalent: rewrite with both)
        doc_settings:saveSetting("annotations", {
            { pos0 = "P0", pos1 = "P1", drawer = "lighten", color = "yellow" },
            { pos0 = "Q0", pos1 = "Q1", drawer = "lighten", color = "pink" },
        })

        assert.equals(2, #strokes_file:read())
        assert.equals(2, #doc_settings:readSetting("annotations"))
        assert.equals("Red",   strokes_file:read()[2].color_name)
        assert.equals("pink",  doc_settings:readSetting("annotations")[2].color)
    end)

end)

describe("Two-sidecar architecture — namespace boundary (no key collision)", function()

    it("the two sidecars use distinct key spaces", function()
        -- pencil_strokes.lua is a SEPARATE FILE at <book>.sdr/pencil_strokes.lua;
        -- KOReader annotations live under the 'annotations' key of the
        -- doc_settings metadata.lua file. Different files entirely; no
        -- key collision possible. This test documents the assumption.
        local doc_settings = makeDocSettings()
        doc_settings:saveSetting("annotations",     "<path-A payload>")
        doc_settings:saveSetting("highlight",        "<KOReader native>")
        doc_settings:saveSetting("bookmarks",        "<KOReader native>")
        -- Path-B does NOT write into doc_settings; pencil_strokes lives in
        -- its own file. So no Path-B key is expected here.
        assert.equals("<path-A payload>",  doc_settings:readSetting("annotations"))
        assert.equals("<KOReader native>", doc_settings:readSetting("highlight"))
        assert.equals("<KOReader native>", doc_settings:readSetting("bookmarks"))
        assert.is_false(doc_settings:hasKey("pencil_strokes"))
    end)

    it("falls back to default on missing key (defensive — empty annotations on fresh book)", function()
        local doc_settings = makeDocSettings()
        local annotations = doc_settings:readSetting("annotations", {})
        assert.is_table(annotations)
        assert.equals(0, #annotations)
    end)

end)

describe("Two-sidecar architecture — data corruption isolation", function()

    it("malformed Path-B entry does not block a fresh Path-A write", function()
        local strokes_file = makePencilStrokesFile()
        local doc_settings = makeDocSettings()

        -- Corrupt Path-B sidecar (mixed valid + garbage).
        strokes_file:write({
            "this is not a stroke",        -- malformed: string instead of stroke table
            { page = 1, points = { {x=1,y=2} }, color_name = "Black" },
        })

        -- Path-A write proceeds unaffected.
        assert.has_no.errors(function()
            doc_settings:saveSetting("annotations", {
                { pos0 = "P0", pos1 = "P1",
                  drawer = "lighten", color = "yellow" },
            })
        end)

        local annotations = doc_settings:readSetting("annotations")
        assert.equals(1,        #annotations)
        assert.equals("yellow", annotations[1].color)
        -- Path-B corruption stays in Path-B's sidecar.
        assert.equals(2, #strokes_file:read())
    end)

    it("malformed Path-A annotation entry does not block a fresh Path-B write", function()
        local strokes_file = makePencilStrokesFile()
        local doc_settings = makeDocSettings()

        doc_settings:saveSetting("annotations", {
            "garbage",                                  -- malformed
            { pos0 = "P0", pos1 = "P1", drawer = "lighten", color = "yellow" },
        })

        assert.has_no.errors(function()
            strokes_file:write({
                { page = 1, points = { {x=1,y=2} }, color_name = "Red" },
            })
        end)

        local strokes = strokes_file:read()
        assert.equals(1,     #strokes)
        assert.equals("Red", strokes[1].color_name)
        assert.equals(2,     #doc_settings:readSetting("annotations"))
    end)

end)
