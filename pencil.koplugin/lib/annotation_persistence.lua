--[[--
Serialize / deserialize / round-trip helpers for the `{version,
strokes, annotation_groups}` state shape that main.lua's saveStrokes
(main.lua:4616-4664) and loadStrokes (main.lua:4514-..) read and write
on disk.

Per Goal-3 plan §G3-6 (PER3-1..PER3-5 specs), this module gives the
tap-delete lifecycle a deterministic, pure-Lua persistence target so
the eraser-tap → save → reload round-trip can be exercised under busted
without pulling main.lua. The on-disk wire format is the same Lua-
literal `return {...}` shape produced by KOReader's `dump` module
(saveStrokes calls `require("dump")` at line 4658), so a file written
by this module is bit-for-bit loadable by the existing loadStrokes
path, and vice versa.

----------------------------------------------------------------------
Public API
----------------------------------------------------------------------

    serialize(state)
        → string    Lua source of the form `return { ... }` suitable
                    for io.write to disk. Determinism: integer-keyed
                    array parts are emitted in numeric order; string-
                    keyed map parts are emitted in alphabetical key
                    order so round-trip output is byte-stable.

    deserialize(source)
        → table     loadstring(source)() with pcall protection.
        → nil       on parse/eval failure.

    round_trip(state)
        → table     deserialize(serialize(state)) — convenience for
                    PER3 specs.

The serializer handles:
- nil (omitted from output)
- boolean, number (integer + float), string
- table (mixed array + map parts)
- functions / userdata / threads are NOT supported (deliberately —
  saved state must be plain data).

@module pencil.lib.annotation_persistence
--]]--

local AnnotationPersistence = {}

----------------------------------------------------------------------
-- Internal: scalar emitter.
----------------------------------------------------------------------

local function emit_scalar(v)
    local t = type(v)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        -- Preserve integers vs floats faithfully. Lua's %.14g matches
        -- the standard `dump` module's numeric precision.
        if v ~= v then
            return "0/0"   -- NaN
        elseif v == math.huge then
            return "1/0"
        elseif v == -math.huge then
            return "-1/0"
        elseif math.type and math.type(v) == "integer" then
            return string.format("%d", v)
        else
            return string.format("%.14g", v)
        end
    elseif t == "string" then
        return string.format("%q", v)
    end
    error("annotation_persistence: cannot serialize value of type " .. t)
end

----------------------------------------------------------------------
-- Internal: table emitter with deterministic key ordering.
-- Array part (1..#t consecutive integer keys) is emitted positionally
-- without explicit `[i] =` prefixes; remaining keys are emitted in
-- key-sorted order with explicit `[key] =` prefixes so the output is
-- both compact and reload-stable across Lua's unordered hash table.
----------------------------------------------------------------------

local emit_value  -- forward decl (recursive)

local function emit_table(t, indent, seen)
    if seen[t] then
        error("annotation_persistence: cyclic table detected")
    end
    seen[t] = true

    local parts = {}
    local n_array = #t  -- positional array length

    -- Array part: indices 1..n_array
    for i = 1, n_array do
        parts[#parts + 1] = emit_value(t[i], indent, seen)
    end

    -- Map part: every key that is NOT a 1..n_array integer.
    local map_keys = {}
    for k, _ in pairs(t) do
        local is_array_key = (type(k) == "number"
                              and k >= 1 and k <= n_array
                              and math.type and math.type(k) == "integer")
        if not is_array_key then
            map_keys[#map_keys + 1] = k
        end
    end
    table.sort(map_keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(map_keys) do
        local key_repr
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            key_repr = k
        else
            key_repr = "[" .. emit_scalar(k) .. "]"
        end
        parts[#parts + 1] = key_repr .. " = " .. emit_value(t[k], indent, seen)
    end

    seen[t] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

emit_value = function(v, indent, seen)
    if type(v) == "table" then
        return emit_table(v, indent, seen)
    else
        return emit_scalar(v)
    end
end

----------------------------------------------------------------------
-- Public API.
----------------------------------------------------------------------

function AnnotationPersistence.serialize(state)
    if state == nil then return "return nil" end
    if type(state) ~= "table" then
        error("annotation_persistence: state must be a table or nil")
    end
    return "return " .. emit_value(state, "", {})
end

function AnnotationPersistence.deserialize(source)
    if type(source) ~= "string" then return nil end
    local chunk, err
    if loadstring then  -- Lua 5.1 / LuaJIT path
        chunk, err = loadstring(source, "annotation_persistence")
    else
        chunk, err = load(source, "annotation_persistence", "t")
    end
    if not chunk then return nil, err end
    local ok, data = pcall(chunk)
    if not ok then return nil, data end
    return data
end

function AnnotationPersistence.round_trip(state)
    return AnnotationPersistence.deserialize(
        AnnotationPersistence.serialize(state))
end

return AnnotationPersistence
