--[[--
Unit tests for color picker and pen color functionality.
Tests color selection, color picker triggering, and color persistence.
Run with: busted spec/color_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path
package.path = package.path .. ";pencil.koplugin/?.lua"

-- Mock Blitbuffer for color values
local MockBlitbuffer = {
    COLOR_BLACK = { value = 0x00 },
    Color8 = function(v) return { value = v, type = "gray" } end,
    ColorRGB32 = function(r, g, b, a)
        return { r = r, g = g, b = b, a = a, type = "rgb32" }
    end,
}

-- Tool constants
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"

-- Color picker constants (matching main.lua)
local COLOR_PICKER_HOLD_TIME_MS = 5000
local COLOR_PICKER_MOVE_THRESHOLD = 5

-- Helper to create a stroke with color
local function createStroke(page, points, options)
    options = options or {}
    return {
        page = page,
        points = points,
        width = options.width or 3,
        tool = options.tool or TOOL_PEN,
        color = options.color,
        color_name = options.color_name,
    }
end

-- Mock time module (must be defined before createMockPencil uses it)
local MockTime = {}
MockTime._current_time = 0
function MockTime.now() return MockTime._current_time end
function MockTime.to_ms(t) return t end
function MockTime.set(ms) MockTime._current_time = ms end
function MockTime.advance(ms) MockTime._current_time = MockTime._current_time + ms end

-- Mock Pencil object with color support
local function createMockPencil(options)
    options = options or {}

    local mock = {
        strokes = options.strokes or {},
        tool_settings = {
            [TOOL_PEN] = {
                width = 3,
                color = nil,
                color_name = "Black",
            },
            [TOOL_HIGHLIGHTER] = {
                width = 20,
                color = nil,
            },
            [TOOL_ERASER] = {
                width = 20,
            },
        },
        current_tool = options.current_tool or TOOL_PEN,
        input_debug_mode = false,
        page_strokes = {},
        undo_stack = {},

        -- Color picker state
        color_picker_start_x = nil,
        color_picker_start_y = nil,
        color_picker_start_time = nil,
        color_picker_check_pending = nil,
        color_picker_showing = false,
        color_picker_widget = nil,

        -- Available colors
        available_colors = {},

        -- Pen state
        pen_down = false,
        pen_x = 0,
        pen_y = 0,

        -- Mock tracking
        _saved = false,
        _notification_shown = nil,
        _scheduled_callbacks = {},
    }

    -- Initialize colors (simulating init())
    mock.tool_settings[TOOL_PEN].color = MockBlitbuffer.COLOR_BLACK

    -- Highlighter palette: pale base hues. Rendering uses multiply blending,
    -- which computes result = src * dst / 255 per channel. With very light
    -- source colors the white bg ≈ shows through and dark text stays readable.
    -- Mirrors main.lua's available_highlighter_colors / init() defaults.
    mock.available_highlighter_colors = {
        { name = "Yellow", color = MockBlitbuffer.ColorRGB32(0xFF, 0xF5, 0x9D, 0xFF) },
        { name = "Green",  color = MockBlitbuffer.ColorRGB32(0xC8, 0xE6, 0xC9, 0xFF) },
        { name = "Pink",   color = MockBlitbuffer.ColorRGB32(0xF8, 0xBB, 0xD0, 0xFF) },
        { name = "Cyan",   color = MockBlitbuffer.ColorRGB32(0xB3, 0xE5, 0xFC, 0xFF) },
        { name = "Orange", color = MockBlitbuffer.ColorRGB32(0xFF, 0xCC, 0x80, 0xFF) },
    }
    -- Default highlighter is Yellow (matches main.lua:200-201).
    mock.tool_settings[TOOL_HIGHLIGHTER].color = mock.available_highlighter_colors[1].color
    mock.tool_settings[TOOL_HIGHLIGHTER].color_name = mock.available_highlighter_colors[1].name

    mock.available_colors = {
        { name = "Black", color = MockBlitbuffer.COLOR_BLACK },
        { name = "Red", color = MockBlitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = MockBlitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = MockBlitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = MockBlitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = MockBlitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = MockBlitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = MockBlitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = MockBlitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = MockBlitbuffer.Color8(0x88) },
    }

    -- Experimental pen width picker (off by default). When enabled,
    -- available_widths is appended to the picker's item list.
    mock.experimental_pen_width = options.experimental_pen_width or false
    mock.available_widths = {
        { name = "w3", width = 3 },
        { name = "w5", width = 5 },
        { name = "w7", width = 7 },
        { name = "w9", width = 9 },
    }

    -- Mirrors ColorPickerWidget:init()'s per-row construction. Colors and
    -- widths live on separate rows; buildPickerItems is a flattened view
    -- kept for existing assertions.
    function mock:buildPickerRows()
        local colors = {}
        for _, c in ipairs(self.available_colors) do
            table.insert(colors, { kind = "color", name = c.name, color_value = c.color })
        end
        local widths = {}
        if self.experimental_pen_width then
            for _, w in ipairs(self.available_widths) do
                table.insert(widths, { kind = "width", name = w.name, width_value = w.width })
            end
        end
        return colors, widths
    end

    function mock:buildPickerItems()
        local colors, widths = self:buildPickerRows()
        local items = {}
        for _, c in ipairs(colors) do table.insert(items, c) end
        for _, w in ipairs(widths) do table.insert(items, w) end
        return items
    end

    -- Set pen color
    function mock:setPenColor(color, color_name)
        self.tool_settings[TOOL_PEN].color = color
        self.tool_settings[TOOL_PEN].color_name = color_name
    end

    -- Set highlighter color (mirrors main.lua Pencil:setHighlighterColor).
    -- Issue 12 folded the user-feedback InfoMessage into the setter; mirror
    -- it via the _notification_shown tracking field.
    function mock:setHighlighterColor(color, color_name)
        self.tool_settings[TOOL_HIGHLIGHTER].color = color
        self.tool_settings[TOOL_HIGHLIGHTER].color_name = color_name
        self._saved = true  -- main.lua calls saveSettings()
        self._notification_shown = { text = "Highlighter: " .. tostring(color_name) }
    end

    -- Look up a highlighter color by name
    function mock:getHighlighterColorByName(color_name)
        for _, color_info in ipairs(self.available_highlighter_colors) do
            if color_info.name == color_name then
                return color_info.color
            end
        end
        return nil
    end

    -- Get color by name
    function mock:getColorByName(color_name)
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                return color_info.color
            end
        end
        return nil
    end

    -- Reset color picker tracking
    function mock:resetColorPickerTracking()
        self.color_picker_start_x = nil
        self.color_picker_start_y = nil
        self.color_picker_start_time = nil
    end

    -- Check if color picker should be shown
    function mock:checkColorPickerTrigger()
        if not self.color_picker_start_time then return false end
        if self.color_picker_showing then return false end

        local elapsed_ms = MockTime.to_ms(MockTime.now() - self.color_picker_start_time)
        if elapsed_ms >= COLOR_PICKER_HOLD_TIME_MS then
            self:showColorPicker(self.pen_x, self.pen_y)
            self:resetColorPickerTracking()
            return true
        end
        return false
    end

    -- Schedule color picker check (mock)
    function mock:scheduleColorPickerCheck()
        self.color_picker_check_pending = true
    end

    -- Cancel color picker timer (mock)
    function mock:cancelColorPickerTimer()
        self.color_picker_check_pending = nil
        self:resetColorPickerTracking()
    end

    -- Show color picker (mock)
    function mock:showColorPicker(x, y)
        self.color_picker_showing = true
        self.color_picker_widget = {
            x = x,
            y = y,
            closed = false,
        }
    end

    -- Close color picker (mock)
    function mock:closeColorPicker()
        self.color_picker_showing = false
        self.color_picker_widget = nil
    end

    -- Handle pen touchdown - start tracking for color picker
    function mock:handlePenTouchdown(x, y)
        self.pen_down = true
        self.pen_x = x
        self.pen_y = y

        if self.color_picker_showing and self.color_picker_widget then
            -- Route to color picker
            return true
        end

        self:cancelColorPickerTimer()

        -- Record initial position and timestamp
        self.color_picker_start_x = x
        self.color_picker_start_y = y
        self.color_picker_start_time = MockTime.now()
        self:scheduleColorPickerCheck()

        return true
    end

    -- Handle pen move - check if moved too far
    function mock:handlePenMove(x, y)
        self.pen_x = x
        self.pen_y = y

        if self.color_picker_start_x and self.color_picker_start_y then
            local dx = math.abs(x - self.color_picker_start_x)
            local dy = math.abs(y - self.color_picker_start_y)
            if dx > COLOR_PICKER_MOVE_THRESHOLD or dy > COLOR_PICKER_MOVE_THRESHOLD then
                -- Pen moved too far - reset tracking
                self:resetColorPickerTracking()
                return true
            end
        end

        return true
    end

    -- Handle pen liftoff
    function mock:handlePenLiftoff()
        self.pen_down = false
        self:cancelColorPickerTimer()
    end

    -- Save strokes (mock)
    function mock:saveStrokes()
        self._saved = true
    end

    -- Load pen color by name
    function mock:loadPenColorByName(color_name)
        if color_name then
            self.tool_settings[TOOL_PEN].color_name = color_name
            local color = self:getColorByName(color_name)
            if color then
                self.tool_settings[TOOL_PEN].color = color
                return true
            end
        end
        return false
    end

    -- Load highlighter color by name (mirrors main.lua:1093-1104 loader:
    -- iterate the palette; on match, assign color AND color_name; on
    -- no-match, leave both at their init defaults).
    function mock:loadHighlighterColorByName(color_name)
        if not color_name then return false end
        for _, color_info in ipairs(self.available_highlighter_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_HIGHLIGHTER].color = color_info.color
                self.tool_settings[TOOL_HIGHLIGHTER].color_name = color_name
                return true
            end
        end
        return false
    end

    -- Mirror of main.lua's saveSettings persistence shape — only the
    -- fields that round-trip through highlighter_color_name are modeled.
    function mock:simulateSaveSettings()
        return {
            pen_color_name = self.tool_settings[TOOL_PEN].color_name,
            highlighter_color_name = self.tool_settings[TOOL_HIGHLIGHTER].color_name,
        }
    end

    -- Create stroke with current color
    function mock:createStrokeWithCurrentColor(page, points)
        local tool_settings = self.tool_settings[self.current_tool]
        return {
            page = page,
            points = points,
            width = tool_settings.width,
            tool = self.current_tool,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
        }
    end

    -- Serialize stroke for saving
    function mock:serializeStroke(stroke)
        return {
            page = stroke.page,
            points = stroke.points,
            width = stroke.width,
            tool = stroke.tool,
            color_name = stroke.color_name,  -- Save color name, not color object
        }
    end

    -- Deserialize stroke when loading
    function mock:deserializeStroke(saved)
        local tool = saved.tool or TOOL_PEN
        local tool_settings = self.tool_settings[tool]
        local color = tool_settings.color

        -- Look up color from color_name
        if saved.color_name then
            local looked_up_color = self:getColorByName(saved.color_name)
            if looked_up_color then
                color = looked_up_color
            end
        end

        return {
            page = saved.page,
            points = saved.points,
            width = saved.width,
            tool = tool,
            color = color,
            color_name = saved.color_name,
        }
    end

    return mock
end


describe("pen color functionality", function()

    describe("initialization", function()

        it("initializes with 10 available colors", function()
            local pencil = createMockPencil()
            assert.equals(10, #pencil.available_colors)
        end)

        it("includes expected color names", function()
            local pencil = createMockPencil()
            local color_names = {}
            for _, c in ipairs(pencil.available_colors) do
                color_names[c.name] = true
            end

            assert.is_true(color_names["Black"])
            assert.is_true(color_names["Red"])
            assert.is_true(color_names["Orange"])
            assert.is_true(color_names["Yellow"])
            assert.is_true(color_names["Green"])
            assert.is_true(color_names["Blue"])
            assert.is_true(color_names["Purple"])
            assert.is_true(color_names["Gray"])
        end)

        it("defaults pen color to Black", function()
            local pencil = createMockPencil()
            assert.equals("Black", pencil.tool_settings[TOOL_PEN].color_name)
            assert.is_not_nil(pencil.tool_settings[TOOL_PEN].color)
        end)

        it("sets highlighter to Yellow (ColorRGB32) by default", function()
            -- main.lua's init() now sets highlighter to available_highlighter_colors[1]
            -- (Yellow, ColorRGB32 0xFF/0xF5/0x9D/0xFF) instead of the prior Color8(0xDD)
            -- light-gray. The mock previously hard-coded the stale default and the
            -- assertion silently asserted the removed behaviour; both are now updated.
            local pencil = createMockPencil()
            assert.is_not_nil(pencil.tool_settings[TOOL_HIGHLIGHTER].color)
            assert.equals("rgb32", pencil.tool_settings[TOOL_HIGHLIGHTER].color.type)
            assert.equals("Yellow", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)
            assert.equals(0xFF, pencil.tool_settings[TOOL_HIGHLIGHTER].color.r)
            assert.equals(0xF5, pencil.tool_settings[TOOL_HIGHLIGHTER].color.g)
            assert.equals(0x9D, pencil.tool_settings[TOOL_HIGHLIGHTER].color.b)
        end)

    end)

    describe("setPenColor", function()

        it("sets both color and color_name", function()
            local pencil = createMockPencil()
            local red_color = pencil.available_colors[2].color  -- Red

            pencil:setPenColor(red_color, "Red")

            assert.equals("Red", pencil.tool_settings[TOOL_PEN].color_name)
            assert.equals(red_color, pencil.tool_settings[TOOL_PEN].color)
        end)

        it("can change color multiple times", function()
            local pencil = createMockPencil()

            pencil:setPenColor(pencil.available_colors[3].color, "Orange")
            assert.equals("Orange", pencil.tool_settings[TOOL_PEN].color_name)

            pencil:setPenColor(pencil.available_colors[5].color, "Green")
            assert.equals("Green", pencil.tool_settings[TOOL_PEN].color_name)
        end)

    end)

    describe("getColorByName", function()

        it("returns correct color for valid name", function()
            local pencil = createMockPencil()

            local blue = pencil:getColorByName("Blue")

            assert.is_not_nil(blue)
            assert.equals("rgb32", blue.type)
            assert.equals(0x00, blue.r)
            assert.equals(0x66, blue.g)
            assert.equals(0xFF, blue.b)
        end)

        it("returns nil for unknown color name", function()
            local pencil = createMockPencil()

            local unknown = pencil:getColorByName("Magenta")

            assert.is_nil(unknown)
        end)

    end)

end)


describe("color picker triggering", function()

    before_each(function()
        MockTime.set(0)
    end)

    describe("tracking on touchdown", function()

        it("records position on pen touchdown", function()
            local pencil = createMockPencil()

            pencil:handlePenTouchdown(100, 200)

            assert.equals(100, pencil.color_picker_start_x)
            assert.equals(200, pencil.color_picker_start_y)
        end)

        it("records timestamp on pen touchdown", function()
            MockTime.set(1000)
            local pencil = createMockPencil()

            pencil:handlePenTouchdown(100, 200)

            assert.equals(1000, pencil.color_picker_start_time)
        end)

        it("schedules color picker check", function()
            local pencil = createMockPencil()

            pencil:handlePenTouchdown(100, 200)

            assert.is_true(pencil.color_picker_check_pending)
        end)

    end)

    describe("movement tracking", function()

        it("resets tracking when pen moves beyond threshold", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            -- Move beyond threshold (5 pixels)
            pencil:handlePenMove(106, 100)

            assert.is_nil(pencil.color_picker_start_x)
            assert.is_nil(pencil.color_picker_start_y)
            assert.is_nil(pencil.color_picker_start_time)
        end)

        it("keeps tracking when pen moves within threshold", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            -- Move within threshold
            pencil:handlePenMove(103, 102)

            assert.equals(100, pencil.color_picker_start_x)
            assert.equals(100, pencil.color_picker_start_y)
        end)

        it("resets tracking on Y movement beyond threshold", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            pencil:handlePenMove(100, 110)

            assert.is_nil(pencil.color_picker_start_x)
        end)

    end)

    describe("time-based triggering", function()

        it("shows color picker after hold time elapsed", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)

            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS)
            local triggered = pencil:checkColorPickerTrigger()

            assert.is_true(triggered)
            assert.is_true(pencil.color_picker_showing)
        end)

        it("does not show color picker before hold time", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)

            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS - 1)
            local triggered = pencil:checkColorPickerTrigger()

            assert.is_false(triggered)
            assert.is_false(pencil.color_picker_showing)
        end)

        it("does not show color picker if tracking was reset", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)
            pencil:handlePenMove(200, 100)  -- Reset tracking

            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS)
            local triggered = pencil:checkColorPickerTrigger()

            assert.is_false(triggered)
            assert.is_false(pencil.color_picker_showing)
        end)

        it("resets tracking after showing color picker", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)
            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS)
            pencil:checkColorPickerTrigger()

            assert.is_nil(pencil.color_picker_start_x)
            assert.is_nil(pencil.color_picker_start_y)
            assert.is_nil(pencil.color_picker_start_time)
        end)

    end)

    describe("liftoff handling", function()

        it("cancels color picker timer on liftoff", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            pencil:handlePenLiftoff()

            assert.is_nil(pencil.color_picker_check_pending)
        end)

        it("resets tracking on liftoff", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            pencil:handlePenLiftoff()

            assert.is_nil(pencil.color_picker_start_x)
        end)

    end)

end)


describe("color picker widget", function()

    it("shows at pen position", function()
        local pencil = createMockPencil()

        pencil:showColorPicker(150, 250)

        assert.is_true(pencil.color_picker_showing)
        assert.equals(150, pencil.color_picker_widget.x)
        assert.equals(250, pencil.color_picker_widget.y)
    end)

    it("can be closed", function()
        local pencil = createMockPencil()
        pencil:showColorPicker(100, 100)

        pencil:closeColorPicker()

        assert.is_false(pencil.color_picker_showing)
        assert.is_nil(pencil.color_picker_widget)
    end)

    describe("item list gating (experimental pen width)", function()

        it("includes only colors when experimental_pen_width is off", function()
            local pencil = createMockPencil({ experimental_pen_width = false })

            local items = pencil:buildPickerItems()

            assert.equals(#pencil.available_colors, #items)
            for _, item in ipairs(items) do
                assert.equals("color", item.kind)
            end
        end)

        it("always includes the full color list regardless of flag", function()
            -- Black must not be omitted or shadowed by width items when the
            -- experimental flag is on — the width row is strictly additive.
            local off = createMockPencil({ experimental_pen_width = false })
            local on = createMockPencil({ experimental_pen_width = true })

            local function color_names(items)
                local names = {}
                for _, item in ipairs(items) do
                    if item.kind == "color" then
                        table.insert(names, item.name)
                    end
                end
                return names
            end

            assert.same(color_names(off:buildPickerItems()), color_names(on:buildPickerItems()))
        end)

        it("appends width items only when experimental_pen_width is on", function()
            local pencil = createMockPencil({ experimental_pen_width = true })

            local items = pencil:buildPickerItems()

            assert.equals(
                #pencil.available_colors + #pencil.available_widths,
                #items
            )
            -- Width items live at the tail of the list, after colors
            local tail = items[#items]
            assert.equals("width", tail.kind)
            assert.equals(9, tail.width_value)
        end)

    end)

end)


describe("stroke color handling", function()

    describe("creating strokes", function()

        it("stores current pen color in new stroke", function()
            local pencil = createMockPencil()
            pencil:setPenColor(pencil.available_colors[3].color, "Orange")

            local stroke = pencil:createStrokeWithCurrentColor(1, {{ x = 100, y = 100 }})

            assert.equals("Orange", stroke.color_name)
            assert.is_not_nil(stroke.color)
        end)

        it("stores Black color by default", function()
            local pencil = createMockPencil()

            local stroke = pencil:createStrokeWithCurrentColor(1, {{ x = 100, y = 100 }})

            assert.equals("Black", stroke.color_name)
        end)

    end)

    describe("serialization", function()

        it("saves color_name not color object", function()
            local pencil = createMockPencil()
            local stroke = createStroke(1, {{ x = 100, y = 100 }}, {
                color = pencil.available_colors[4].color,
                color_name = "Yellow",
            })

            local serialized = pencil:serializeStroke(stroke)

            assert.equals("Yellow", serialized.color_name)
            assert.is_nil(serialized.color)
        end)

    end)

    describe("deserialization", function()

        it("restores color from color_name", function()
            local pencil = createMockPencil()
            local saved = {
                page = 1,
                points = {{ x = 100, y = 100 }},
                width = 3,
                tool = TOOL_PEN,
                color_name = "Blue",
            }

            local stroke = pencil:deserializeStroke(saved)

            assert.equals("Blue", stroke.color_name)
            assert.is_not_nil(stroke.color)
            assert.equals("rgb32", stroke.color.type)
        end)

        it("falls back to default color if color_name missing", function()
            local pencil = createMockPencil()
            local saved = {
                page = 1,
                points = {{ x = 100, y = 100 }},
                width = 3,
                tool = TOOL_PEN,
                -- No color_name
            }

            local stroke = pencil:deserializeStroke(saved)

            assert.is_not_nil(stroke.color)
        end)

        it("falls back to default if color_name not found", function()
            local pencil = createMockPencil()
            local saved = {
                page = 1,
                points = {{ x = 100, y = 100 }},
                width = 3,
                tool = TOOL_PEN,
                color_name = "NonexistentColor",
            }

            local stroke = pencil:deserializeStroke(saved)

            -- Should still have a color (the default)
            assert.is_not_nil(stroke.color)
        end)

    end)

end)


describe("color persistence", function()

    it("loads pen color by name", function()
        local pencil = createMockPencil()

        local success = pencil:loadPenColorByName("Green")

        assert.is_true(success)
        assert.equals("Green", pencil.tool_settings[TOOL_PEN].color_name)
        assert.is_not_nil(pencil.tool_settings[TOOL_PEN].color)
    end)

    it("returns false for unknown color name", function()
        local pencil = createMockPencil()

        local success = pencil:loadPenColorByName("UnknownColor")

        assert.is_false(success)
    end)

    it("returns false for nil color name", function()
        local pencil = createMockPencil()

        local success = pencil:loadPenColorByName(nil)

        assert.is_false(success)
    end)

end)


-- ---------------------------------------------------------------------------
-- Highlighter color API (parallel to pen color tests above).
-- Added to cover the Goal 1 surface introduced by the color-and-highlight-button
-- MR: setHighlighterColor, the 5-color available_highlighter_colors palette,
-- highlighter_color_name settings round-trip, and the multiplyRectHighlighter primitive.
-- ---------------------------------------------------------------------------

describe("highlighter color functionality", function()

    describe("available_highlighter_colors palette", function()

        it("initializes with 5 highlighter colors", function()
            local pencil = createMockPencil()
            assert.equals(5, #pencil.available_highlighter_colors)
        end)

        it("includes the documented palette names in order", function()
            local pencil = createMockPencil()
            local names = {}
            for _, c in ipairs(pencil.available_highlighter_colors) do
                table.insert(names, c.name)
            end
            assert.same({ "Yellow", "Green", "Pink", "Cyan", "Orange" }, names)
        end)

        it("every palette entry is a ColorRGB32 value", function()
            -- The multiply primitive operates on RGB32; Color8 entries would
            -- silently downgrade the highlighter to luminance overwrite.
            local pencil = createMockPencil()
            for _, c in ipairs(pencil.available_highlighter_colors) do
                assert.equals("rgb32", c.color.type,
                    "highlighter palette entry " .. c.name .. " is not rgb32")
                assert.equals(0xFF, c.color.a,
                    "highlighter palette entry " .. c.name .. " is not fully opaque")
            end
        end)

    end)

    describe("setHighlighterColor", function()

        it("sets both color and color_name", function()
            local pencil = createMockPencil()
            local green = pencil.available_highlighter_colors[2].color

            pencil:setHighlighterColor(green, "Green")

            assert.equals("Green", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)
            assert.equals(green, pencil.tool_settings[TOOL_HIGHLIGHTER].color)
        end)

        it("can change color multiple times", function()
            local pencil = createMockPencil()

            pencil:setHighlighterColor(pencil.available_highlighter_colors[3].color, "Pink")
            assert.equals("Pink", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)

            pencil:setHighlighterColor(pencil.available_highlighter_colors[4].color, "Cyan")
            assert.equals("Cyan", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)
        end)

        it("does not mutate pen state", function()
            -- Highlighter and pen state are independent; changing one
            -- must not bleed into the other.
            local pencil = createMockPencil()
            local original_pen_name = pencil.tool_settings[TOOL_PEN].color_name
            local original_pen_color = pencil.tool_settings[TOOL_PEN].color

            pencil:setHighlighterColor(
                pencil.available_highlighter_colors[2].color, "Green")

            assert.equals(original_pen_name, pencil.tool_settings[TOOL_PEN].color_name)
            assert.equals(original_pen_color, pencil.tool_settings[TOOL_PEN].color)
        end)

    end)

    describe("getHighlighterColorByName", function()

        it("returns correct color for valid name", function()
            local pencil = createMockPencil()

            local cyan = pencil:getHighlighterColorByName("Cyan")

            assert.is_not_nil(cyan)
            assert.equals("rgb32", cyan.type)
            assert.equals(0xB3, cyan.r)
            assert.equals(0xE5, cyan.g)
            assert.equals(0xFC, cyan.b)
        end)

        it("returns nil for unknown highlighter color name", function()
            local pencil = createMockPencil()

            local unknown = pencil:getHighlighterColorByName("Magenta")

            assert.is_nil(unknown)
        end)

    end)

    describe("highlighter_color_name persistence round-trip", function()

        it("saveSettings emits the current highlighter_color_name", function()
            local pencil = createMockPencil()
            pencil:setHighlighterColor(
                pencil.available_highlighter_colors[5].color, "Orange")

            local saved = pencil:simulateSaveSettings()

            assert.equals("Orange", saved.highlighter_color_name)
        end)

        it("loadHighlighterColorByName restores a saved color", function()
            local pencil = createMockPencil()
            -- Default is Yellow; load Pink and verify both fields move.
            local ok = pencil:loadHighlighterColorByName("Pink")

            assert.is_true(ok)
            assert.equals("Pink", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)
            assert.equals(
                pencil.available_highlighter_colors[3].color,
                pencil.tool_settings[TOOL_HIGHLIGHTER].color)
        end)

        it("round-trips save → load with no data loss", function()
            -- Pick a non-default color, save, simulate a fresh pencil, load.
            local pencil_a = createMockPencil()
            pencil_a:setHighlighterColor(
                pencil_a.available_highlighter_colors[4].color, "Cyan")
            local saved = pencil_a:simulateSaveSettings()

            local pencil_b = createMockPencil()
            local ok = pencil_b:loadHighlighterColorByName(saved.highlighter_color_name)

            assert.is_true(ok)
            assert.equals("Cyan", pencil_b.tool_settings[TOOL_HIGHLIGHTER].color_name)
            assert.equals(0xB3, pencil_b.tool_settings[TOOL_HIGHLIGHTER].color.r)
            assert.equals(0xE5, pencil_b.tool_settings[TOOL_HIGHLIGHTER].color.g)
            assert.equals(0xFC, pencil_b.tool_settings[TOOL_HIGHLIGHTER].color.b)
        end)

        it("loadHighlighterColorByName returns false for unknown name", function()
            local pencil = createMockPencil()

            local ok = pencil:loadHighlighterColorByName("NotARealPaletteEntry")

            assert.is_false(ok)
            -- On no-match, init defaults (Yellow) are preserved.
            assert.equals("Yellow", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)
        end)

        it("loadHighlighterColorByName returns false for nil name", function()
            local pencil = createMockPencil()

            local ok = pencil:loadHighlighterColorByName(nil)

            assert.is_false(ok)
            assert.equals("Yellow", pencil.tool_settings[TOOL_HIGHLIGHTER].color_name)
        end)

    end)

end)


-- ---------------------------------------------------------------------------
-- multiplyRectHighlighter primitive (main.lua:52-58).
-- The helper picks the host blitbuffer's fast-path: rect-multiply if
-- multiplyRectRGB is available (modern KOReader-base), else paintRect with
-- the setPixelMultiply per-pixel setter (older builds, e.g. Snowflake).
-- These tests verify dispatch against both shapes of mock blitbuffer.
-- ---------------------------------------------------------------------------

describe("multiplyRectHighlighter primitive", function()

    -- Local mirror of main.lua's file-local function. Re-implemented in the
    -- spec (mirroring the project's existing pattern — see buildPickerRows,
    -- loadPenColorByName, etc.) because the helper is not exported.
    --
    -- Review Issue 2: the fallback used to call paintRect(x,y,w,h,color,setter)
    -- relying on paintRect's 6-arg form, which Snowflake-era builds do not
    -- have — the 6th arg was silently dropped and the highlighter rendered as
    -- a luminance overwrite instead of a multiply tint. The fallback now
    -- iterates per-pixel via setPixelMultiply with no API assumption.
    local function multiplyRectHighlighter(bb, x, y, w, h, color)
        if bb.multiplyRectRGB then
            bb:multiplyRectRGB(x, y, w, h, color)
        else
            for py = y, y + h - 1 do
                for px = x, x + w - 1 do
                    bb:setPixelMultiply(px, py, color)
                end
            end
        end
    end

    local function makeBBWithMultiplyRect()
        local bb = { calls = {} }
        function bb:multiplyRectRGB(x, y, w, h, color)
            table.insert(self.calls, {
                method = "multiplyRectRGB", x = x, y = y, w = w, h = h, color = color,
            })
        end
        function bb:paintRect(x, y, w, h, color, setter)
            table.insert(self.calls, {
                method = "paintRect", x = x, y = y, w = w, h = h, color = color, setter = setter,
            })
        end
        function bb:setPixelMultiply(x, y, color)
            table.insert(self.calls, {
                method = "setPixelMultiply", x = x, y = y, color = color,
            })
        end
        return bb
    end

    local function makeBBWithoutMultiplyRect()
        -- No multiplyRectRGB and — critically — no 6-arg paintRect either,
        -- mirroring Snowflake-era ffi/blitbuffer.lua (review Issue 2).
        local bb = { calls = {} }
        function bb:setPixelMultiply(x, y, color)
            table.insert(self.calls, {
                method = "setPixelMultiply", x = x, y = y, color = color,
            })
        end
        return bb
    end

    it("dispatches to multiplyRectRGB when available", function()
        local bb = makeBBWithMultiplyRect()
        local color = MockBlitbuffer.ColorRGB32(0xFF, 0xF5, 0x9D, 0xFF)

        multiplyRectHighlighter(bb, 10, 20, 30, 40, color)

        assert.equals(1, #bb.calls)
        assert.equals("multiplyRectRGB", bb.calls[1].method)
        assert.equals(10, bb.calls[1].x)
        assert.equals(20, bb.calls[1].y)
        assert.equals(30, bb.calls[1].w)
        assert.equals(40, bb.calls[1].h)
        assert.equals(color, bb.calls[1].color)
    end)

    it("falls back to per-pixel setPixelMultiply when multiplyRectRGB is absent", function()
        -- 3x2 rect should produce exactly 6 setPixelMultiply calls covering
        -- every pixel in [x, x+w) × [y, y+h). This is the contract that
        -- protects against the Snowflake 6-arg paintRect failure mode.
        local bb = makeBBWithoutMultiplyRect()
        local color = MockBlitbuffer.ColorRGB32(0xC8, 0xE6, 0xC9, 0xFF)

        multiplyRectHighlighter(bb, 5, 6, 3, 2, color)

        assert.equals(6, #bb.calls)
        local hit = {}
        for _, call in ipairs(bb.calls) do
            assert.equals("setPixelMultiply", call.method)
            assert.equals(color, call.color)
            hit[call.x .. "," .. call.y] = true
        end
        assert.is_true(hit["5,6"])
        assert.is_true(hit["6,6"])
        assert.is_true(hit["7,6"])
        assert.is_true(hit["5,7"])
        assert.is_true(hit["6,7"])
        assert.is_true(hit["7,7"])
    end)

    it("fallback covers exactly w*h pixels for a square region", function()
        local bb = makeBBWithoutMultiplyRect()
        multiplyRectHighlighter(bb, 0, 0, 4, 4,
            MockBlitbuffer.ColorRGB32(0xFF, 0xF5, 0x9D, 0xFF))
        assert.equals(16, #bb.calls)
    end)

    it("does not call setPixelMultiply when multiplyRectRGB is available", function()
        -- Guards the dispatch order: the fast-path must win over the fallback.
        -- (Per-pixel iteration on the modern BB would defeat the whole point
        -- of the rect-multiply primitive.)
        local bb = makeBBWithMultiplyRect()

        multiplyRectHighlighter(bb, 0, 0, 100, 100,
            MockBlitbuffer.ColorRGB32(0xFF, 0xF5, 0x9D, 0xFF))

        for _, call in ipairs(bb.calls) do
            assert.not_equals("setPixelMultiply", call.method)
            assert.not_equals("paintRect", call.method)
        end
    end)

end)
