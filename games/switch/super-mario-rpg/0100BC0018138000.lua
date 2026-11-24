-- reader: no hooks
-- reader: title スーパーマリオRPG (Super Mario RPG)
-- reader: reads Field and battle dialogue, speakers, furigana, choices, and cutscene subtitles
-- reader: version The game as released (1.0.0)
-- reader: audio never
-- スーパーマリオRPG (Super Mario RPG, 2023), Switch.
-- Written for main build E968832CADE2AD7CBD85B6C6DFE1D9C1 (the game as released, 1.0.0).
--
-- A Unity game (2021.3, IL2CPP) that shows its text with TextMesh Pro. Every message goes
-- through one object, the game's MessageWindow (a singleton), which has a panel for the field,
-- one for battles and one for the captions of the films. A panel has a text object per line,
-- one for the speaker's name and one per answer of a choice. The profile finds the window
-- through its class, which the engine keeps at a fixed place in the program, reads once a
-- frame what the panels show, and turns TextMesh Pro's table of characters into places in the
-- picture by following the text's transforms up to its canvas. Nothing is hooked, so the game
-- runs natively (first line of this file).
--
-- The game writes a reading after its word, as a run in a style of its own
-- (漢字<style=p24>かんじ</style>): those runs are the furigana and are not part of the text.
--
-- Not read: menus, lists, item and skill texts, the names over enemies, the title's questions.

local BUILD = "E968832CADE2AD7CBD85B6C6DFE1D9C1"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The way in (an offset into main): where the engine keeps the class MessageWindow once it
-- exists. Its parent is SingletonMonoBehaviour<MessageWindow>, whose static fields hold the
-- window.
local WINDOW_CLASS = 0x32a6bf8
local K_NAME = 0x10              -- Il2CppClass: its name (C string)
local K_PARENT = 0x58            -- Il2CppClass: the class it derives from
local K_STATICS = 0xb8           -- Il2CppClass: its static fields

-- Managed objects: the class at 0, fields from 0x10.
local STR_LENGTH, STR_CHARS = 0x10, 0x14 -- System.String: UTF-16
local ARRAY_DATA = 0x20                  -- array: first element
local LIST_ITEMS, LIST_SIZE = 0x10, 0x18 -- List<T>

-- The game's message window.
local W_PANEL = 0x18             -- MessageWindow: MessagePanel messagePanel (the field's)
local W_BATTLE = 0x20            -- MessageWindow: MessagePanel battleMessagePanel
local W_MOVIE = 0x28             -- MessageWindow: MessageMovie massageMoviePanel
local P_MAIN = 0x88              -- MessagePanel: GameObject mainPanel
local P_NAME_FRAME = 0x90        -- MessagePanel: GameObject nameTextFrame
local P_NAME = 0x98              -- MessagePanel: TextMeshProUGUI nameText
local P_LINES = 0xa0             -- MessagePanel: List<TextMeshProUGUI> lineTexts
local P_SELECT_MAIN = 0xd8       -- MessagePanel: GameObject selectMainPanel
local P_SELECT_LINES = 0xe8      -- MessagePanel: List<TextMeshProUGUI> selectLineTexts
local P_PAUSING = 0x170          -- MessagePanel: bool _pausing (waiting for the button)
local P_FINISHED = 0x173         -- MessagePanel: bool _textFinished
local MV_LINES = 0x18            -- MessageMovie: List<TextMeshProUGUI> lineTexts

-- TextMeshPro (TMP_Text, TextMeshProUGUI).
local T_TEXT = 0xd0              -- string m_text
local T_INFO = 0x360             -- TMP_TextInfo m_textInfo
local T_DIRTY = 0x368            -- bool m_havePropertiesChanged: m_textInfo is not for m_text yet
local T_RECT = 0x378             -- RectTransform m_rectTransform
local T_CLIP = 0x6d8             -- Rect m_ClipRect: what a mask lets be seen, in the canvas's
local T_CLIPPED = 0x6e8          -- coordinates; bool m_ValidRect: there is such a mask
local T_CANVAS = 0x720           -- Canvas m_canvas
local I_COUNT = 0x18             -- TMP_TextInfo: int characterCount
local I_CHARS = 0x38             -- TMP_TextInfo: TMP_CharacterInfo[] characterInfo
local C_SIZE = 0x178             -- TMP_CharacterInfo
local C_CHAR, C_INDEX = 0x00, 0x04 -- char character, int index (into m_text, in UTF-16 units)
local C_ORIGIN = 0x120           -- floats: origin, xAdvance, ascender, baseLine, descender
local C_ALPHA = 0x147            -- byte: the alpha of Color32 color
local C_VISIBLE = 0x174          -- bool isVisible

-- The engine's objects (Unity 2021.3, 64-bit).
local O_NATIVE = 0x10            -- UnityEngine.Object: the engine's own object
local N_OBJECT = 0x30            -- component: its GameObject
local G_COMPONENTS = 0x30        -- GameObject: array of {type, component}, 16 bytes each
local G_ACTIVE = 0x57            -- GameObject: active in the hierarchy (it and all above it)
local CG_ALPHA = 0x38            -- CanvasGroup (the engine's): float alpha
local X_HIERARCHY = 0x38         -- Transform: the hierarchy it is in
local X_INDEX = 0x40             -- Transform: its index there
local X_RECT = 0xb8              -- RectTransform: x, y, width, height in its own coordinates
local H_LOCAL = 0x18             -- hierarchy: per transform 0x30 bytes: position, rotation, scale
local H_PARENT = 0x20            -- hierarchy: per transform the index of its parent, -1 at the root

-- Frames a text must have stood complete before it is read: the game's fast-forward and a
-- press of the button in the middle of the typing go through lines faster.
local STEADY = 6

local function pointer(a)
    local p = a and mem.u64(a)
    return p and p > 0x10000 and p < 0x8000000000 and p or nil
end

local function utf16(p)
    if not p then return "" end
    local n = mem.s32(p + STR_LENGTH)
    if not n or n <= 0 or n > 8192 then return "" end
    return mem.read(p + STR_CHARS, n * 2)
end

local function list(l)
    local items, size = l and pointer(l + LIST_ITEMS), l and mem.s32(l + LIST_SIZE)
    local out = {}
    if not items or not size or size < 0 or size > 64 then return out end
    local raw = mem.read(items + ARRAY_DATA, 8 * size)
    for i = 0, #raw // 8 - 1 do
        local p = string.unpack("<I8", raw, 8 * i + 1)
        out[#out + 1] = p > 0x10000 and p or nil
    end
    return out
end

-- The engine's own object of a managed one, and whether a component's GameObject is shown.
local function native(object) return object and pointer(object + O_NATIVE) end

local function active(component)
    local n = native(component)
    local game_object = n and pointer(n + N_OBJECT)
    return game_object ~= nil and mem.u8(game_object + G_ACTIVE) == 1
end


-- A GameObject (managed) that is shown: active, with everything above it.
local function object_active(game_object)
    local n = native(game_object)
    return n ~= nil and mem.u8(n + G_ACTIVE) == 1
end

-- ---------------------------------------------------------------------------------------
-- Text: what is shown, without TextMesh Pro's tags, and the readings
-- ---------------------------------------------------------------------------------------

local function kanji(code)
    return (code >= 0x4E00 and code <= 0x9FFF) or (code >= 0x3400 and code <= 0x4DBF) or
        code == 0x3005 or code == 0x3006 or code == 0x30F6
end

-- A string as the game gave it (UTF-16) taken apart: the text without tags and readings
-- (UTF-8), for each UTF-16 unit of the string the place (code point, from 1) it has in that
-- text or nil for a unit of a tag or a reading, the number of code points, and the readings
-- as {first place (from 0), places, reading}.
local function strip(raw)
    local units = {}
    for i = 1, #raw - 1, 2 do units[#units + 1] = string.unpack("<I2", raw, i) end
    local out, codes, places, n = {}, {}, {}, 0
    local ruby = {}
    local reading -- the characters of the reading being gone through, or nil
    local i = 1
    while i <= #units do
        local u = units[i]
        if u == 0x3C then -- "<": a tag up to the next ">"
            local j = i + 1
            while j <= #units and units[j] ~= 0x3E and units[j] ~= 0x3C and j - i < 64 do j = j + 1 end
            if j <= #units and units[j] == 0x3E then
                local tag = {}
                for k = i + 1, j - 1 do tag[#tag + 1] = units[k] < 0x80 and string.char(units[k]) or "?" end
                tag = table.concat(tag)
                if tag:match("^style=p%d+$") then
                    reading = {}
                elseif tag == "/style" and reading then
                    -- The word a reading belongs to: the kanji right before it.
                    local first = n
                    while first > 0 and kanji(codes[first]) do first = first - 1 end
                    if first < n and #reading > 0 then
                        ruby[#ruby + 1] = { first, n - first, table.concat(reading) }
                    end
                    reading = nil
                end
                i = j + 1
                goto continue
            end
        end
        do
            local code, width = u, 1
            if u >= 0xD800 and u <= 0xDBFF and units[i + 1] then
                code, width = 0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00), 2
            end
            if reading then
                reading[#reading + 1] = utf8.char(code)
            else
                n = n + 1
                for k = i, i + width - 1 do places[k] = n end
                out[n], codes[n] = utf8.char(code), code
            end
            i = i + width
        end
        ::continue::
    end
    return table.concat(out), places, n, ruby
end

-- strip() of the last few strings: a text stands for many frames.
local stripped = {}
local stripped_count = 0
local function strip_once(raw)
    local known = stripped[raw]
    if known then return known[1], known[2], known[3], known[4] end
    local text, places, count, ruby = strip(raw)
    if stripped_count >= 32 then stripped, stripped_count = {}, 0 end
    stripped[raw] = { text, places, count, ruby }
    stripped_count = stripped_count + 1
    return text, places, count, ruby
end

-- ---------------------------------------------------------------------------------------
-- Where a text object is in the picture
-- ---------------------------------------------------------------------------------------

local function own_transform(component)
    local n = native(component)
    local game_object = n and pointer(n + N_OBJECT)
    local components = game_object and pointer(game_object + G_COMPONENTS)
    return components and pointer(components + 8) -- a GameObject's first component is its transform
end

-- Scale and offset that take a transform's own coordinates to its canvas's: {sx, sy, ox, oy}.
local function to_canvas(node, stop)
    local hierarchy, index = pointer(node + X_HIERARCHY), mem.s32(node + X_INDEX)
    if not hierarchy or not index then return nil end
    local locals, parents = pointer(hierarchy + H_LOCAL), pointer(hierarchy + H_PARENT)
    if not locals or not parents then return nil end
    local sx, sy, ox, oy = 1, 1, 0, 0
    for _ = 1, 64 do
        if index == stop then return { sx, sy, ox, oy } end
        if not index or index < 0 then return nil end
        local raw = mem.read(locals + index * 0x30, 0x30)
        if #raw < 0x30 then return nil end
        local tx, ty, _, _, _, _, _, _, kx, ky = string.unpack("<ffffffffff", raw)
        sx, sy, ox, oy = sx * kx, sy * ky, tx + kx * ox, ty + ky * oy
        index = mem.s32(parents + 4 * index)
    end
    return nil
end

-- What turns a text object's coordinates into pixels of the picture (y down):
-- {scale x, scale y, offset x, offset y}, or nil while that cannot be told. A text's canvas
-- covers the whole picture.
local function placement(tmp, node)
    local canvas = own_transform(pointer(tmp + T_CANVAS))
    node = node or native(pointer(tmp + T_RECT))
    if not canvas or not node or pointer(canvas + X_HIERARCHY) ~= pointer(node + X_HIERARCHY) then
        return nil
    end
    local chain = to_canvas(node, mem.s32(canvas + X_INDEX))
    local raw = mem.read(canvas + X_RECT, 16)
    if not chain or #raw < 16 then return nil end
    local rx, ry, rw, rh = string.unpack("<ffff", raw)
    local width, height = reader.picture()
    if not width or rw <= 0 or rh <= 0 then return nil end
    local px, py = width / rw, height / rh
    local sx, sy, ox, oy = table.unpack(chain)
    local place = { sx * px, -sy * py, (ox - rx) * px, height - (oy - ry) * py }
    -- What a mask over the text lets be seen: {left, top, right, bottom} in the picture.
    if mem.u8(tmp + T_CLIPPED) == 1 then
        local cx, cy, cw, ch = string.unpack("<ffff", mem.read(tmp + T_CLIP, 16))
        place.clip = { (cx - rx) * px, height - (cy + ch - ry) * py,
                       (cx + cw - rx) * px, height - (cy - ry) * py }
    end
    return place
end

-- The cells of the characters TextMesh Pro has laid out for a text object, by the place of
-- each in the text without tags (`raw`, as the object has it): {left, top, width, height} in
-- the picture, put into `out` from `offset` on. A character that is not one of the text's
-- (the game adds one to make room for its wait mark), that is transparent or that a mask
-- hides (a long message's first lines in its balloon) has no cell. Returns false while the
-- table is not for the object's text.
local function cells(tmp, raw_text, places, offset, out, state)
    if mem.u8(tmp + T_DIRTY) ~= 0 then return false end
    local info = pointer(tmp + T_INFO)
    local count = info and mem.s32(info + I_COUNT)
    local array = info and pointer(info + I_CHARS)
    if not count or count < 0 or count > 2000 or not array then return false end
    local place = placement(tmp)
    if not place then return false end
    local clip = place.clip
    -- Nothing to do when the text object, its text and its place are as they were.
    local key = string.format("%x %d %d %.2f %.2f %.1f %.1f %s", tmp, #raw_text, count, place[1], place[2],
                              place[3], place[4], clip and table.concat(clip, ",") or "-")
    if state then
        if state.cells_key == key then return "same" end
        state.cells_key = key
    end
    local raw = mem.read(array + ARRAY_DATA, count * C_SIZE)
    for i = 0, #raw // C_SIZE - 1 do
        local at = i * C_SIZE
        local code = string.unpack("<I2", raw, at + C_CHAR + 1)
        local index = string.unpack("<i4", raw, at + C_INDEX + 1)
        local spot = places[index + 1]
        local unit = 2 * index + 2 <= #raw_text and string.unpack("<I2", raw_text, 2 * index + 1)
        if spot and unit == code and raw:byte(at + C_VISIBLE + 1) ~= 0 and
            raw:byte(at + C_ALPHA + 1) ~= 0 then
            local origin, advance, ascender, _, descender = string.unpack("<fffff", raw, at + C_ORIGIN + 1)
            local left, right = place[3] + place[1] * origin, place[3] + place[1] * advance
            local top, bottom = place[4] + place[2] * ascender, place[4] + place[2] * descender
            local middle = (top + bottom) / 2
            if not clip or (middle >= clip[2] and middle <= clip[4]) then
                out[offset + spot] = { left, top, right - left, bottom - top }
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------
-- What is reported
-- ---------------------------------------------------------------------------------------

local shown = {} -- by window name: {text, since, emitted, placed}

local function close(name)
    local state = shown[name]
    if state then state.cells_key = nil end
    if state and state.placed then
        reader.layout(name, nil)
        state.placed = nil
    end
end

local function forget(name)
    close(name)
    shown[name] = nil
end

-- Reports where the characters of a text that was emitted are now (or that it is gone).
local function place(name, count, glyphs)
    local state = shown[name]
    local cells_, key = {}, {}
    for i = 1, count do
        local cell = glyphs[i]
        cells_[i] = cell or false
        if cell then key[#key + 1] = string.format("%d:%.0f,%.0f", i, cell[1], cell[2]) end
    end
    if #key == 0 then return close(name) end
    key = table.concat(key, " ")
    if key ~= state.placed then
        local width, height = reader.picture()
        reader.layout(name, { space = { width, height }, glyphs = cells_ })
        state.placed = key
    end
end

-- Something to read: not blank.
local function readable(value)
    local rest = value:gsub("\227\128\128", "")
    return rest:find("%S") ~= nil
end

local function emit(name, state)
    if readable(state.text) then
        reader.emit{ text = state.text, speaker = state.speaker, channel = state.channel, window = name,
                     ruby = state.ruby }
        state.emitted = true
    else
        state.emitted = "blank"
    end
end

-- A text that was there whole, and goes before it was read (the button pressed at once), is
-- read as it goes; not one that was still being typed.
local function leave(name)
    local state = shown[name]
    if state and not state.emitted and not state.held then emit(name, state) end
    forget(name)
end

-- A text that has stood long enough is emitted once; a new one (or the same again after it
-- was gone) is new. While `hold` (the text is still being typed) it waits. Returns whether
-- the text has been emitted (and may be placed).
local function offer(name, text, frame, info)
    local state = shown[name]
    if not state or state.text ~= text then
        if state then leave(name) end
        state = { text = text, since = frame, speaker = info.speaker, channel = info.channel, ruby = info.ruby }
        shown[name] = state
    end
    if info.hold and not state.emitted then
        state.since, state.held = frame, true
    elseif not info.hold then
        state.held = nil
        -- The name's box may come up a frame after the text.
        if not state.emitted then state.speaker = info.speaker end
    end
    if not state.emitted and frame - state.since >= STEADY then emit(name, state) end
    return state.emitted == true
end

-- Text objects that are one text, a line each (the lines of a message, the answers of a
-- choice).
local function show_lines(name, tmps, frame, info)
    local lines, parts, ruby = {}, {}, {}
    local offset = 0
    for i, tmp in ipairs(tmps) do
        local raw = utf16(pointer(tmp + T_TEXT))
        local text, places, count, readings = strip_once(raw)
        lines[i], parts[i] = text, { tmp, raw, places, count }
        for _, each in ipairs(readings) do ruby[#ruby + 1] = { offset + each[1], each[2], each[3] } end
        offset = offset + count + 1
    end
    local whole = table.concat(lines, "\n")
    if whole == "" then return forget(name) end
    info.ruby = #ruby > 0 and ruby or nil
    if not offer(name, whole, frame, info) then return end
    local glyphs = {}
    offset = 0
    for _, part in ipairs(parts) do
        if not cells(part[1], part[2], part[3], offset, glyphs) then return end
        offset = offset + part[4] + 1
    end
    place(name, utf8.len(whole) or 0, glyphs)
end

-- ---------------------------------------------------------------------------------------
-- The game's message window
-- ---------------------------------------------------------------------------------------

-- The text objects of a list that are shown and have something in them.
local function texts(l)
    local out = {}
    for i, tmp in ipairs(list(l)) do
        if i > 8 then break end
        if active(tmp) and utf16(pointer(tmp + T_TEXT)) ~= "" then out[#out + 1] = tmp end
    end
    return out
end

local function panel(name, p, frame, seen)
    if not p or not object_active(pointer(p + P_MAIN)) then return end
    local lines = texts(pointer(p + P_LINES))
    if #lines > 0 then
        local speaker
        local name_text = pointer(p + P_NAME)
        if object_active(pointer(p + P_NAME_FRAME)) and name_text and active(name_text) then
            speaker = strip_once(utf16(pointer(name_text + T_TEXT)))
            if speaker == "" then speaker = nil end
        end
        -- A message is all there when the game waits for the button or says it is finished.
        local ready = mem.u8(p + P_PAUSING) == 1 or mem.u8(p + P_FINISHED) == 1
        seen[name] = true
        show_lines(name, lines, frame, { speaker = speaker, hold = not ready })
    end
    if object_active(pointer(p + P_SELECT_MAIN)) then
        local answers = texts(pointer(p + P_SELECT_LINES))
        if #answers > 0 then
            seen[name .. ".choice"] = true
            show_lines(name .. ".choice", answers, frame, { channel = "choice" })
        end
    end
end

local window_at

reader.on_frame(function(frame)
    -- The window: through its class, once the engine has made it.
    local class = pointer(base + WINDOW_CLASS)
    if not class or mem.cstr(pointer(class + K_NAME) or 0, 40) ~= "MessageWindow" then return end
    local parent = pointer(class + K_PARENT)
    local statics = parent and pointer(parent + K_STATICS)
    local window = statics and pointer(statics)
    if not window or pointer(window) ~= class then return end
    window_at = window

    local seen = {}
    panel("message", pointer(window + W_PANEL), frame, seen)
    panel("battle", pointer(window + W_BATTLE), frame, seen)
    local movie = pointer(window + W_MOVIE)
    if movie and active(movie) then
        local lines = texts(pointer(movie + MV_LINES))
        if #lines > 0 then
            seen.movie = true
            show_lines("movie", lines, frame, {})
        end
    end

    for name in pairs(shown) do
        if not seen[name] then leave(name) end
    end
end)

-- For the harness (lua smrpg_dump()): what the profile holds.
function smrpg_dump()
    print(string.format("window %x", window_at or 0))
    for name, state in pairs(shown) do
        print(string.format("%s: %s since %d emitted %s placed %s", name, state.text:gsub("\n", "/"),
                            state.since, tostring(state.emitted), state.placed and "yes" or "no"))
    end
end
