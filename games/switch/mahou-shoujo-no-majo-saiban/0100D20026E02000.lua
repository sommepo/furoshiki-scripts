-- reader: no hooks
-- reader: title 魔法少女ノ魔女裁判 (Magical Girl Witch Trials)
-- reader: reads Dialogue, speakers, and furigana
-- reader: version The game as released on Switch (2.0.0a)
-- 魔法少女ノ魔女裁判 (Magical Girl Witch Trials, 2025), Switch.
-- Written for main build 1B1734E731DB2C16B234F685FA738349 (the game as released, 2.0.0a).
--
-- A Unity 6 game (6000.0, IL2CPP) built on Naninovel, a visual novel framework, which shows
-- its text with TextMesh Pro. Naninovel's static class Engine keeps a list of its services;
-- one of them, the TextPrinterManager, keeps the printers by name, and a printer's panel has
-- the text object the message is revealed in. The profile finds Engine through its class,
-- which the runtime keeps at a fixed place in the program, reads once a frame what each
-- printer shows, and turns TextMesh Pro's table of characters into places in the picture by
-- following the text's transforms up to its canvas. Nothing is hooked, so the game runs
-- natively (first line of this file).
--
-- Naninovel writes readings as <ruby="かんじ">漢字</ruby> in the message as the script gave it
-- (kept beside what TextMesh Pro shows), and turns each into a link of small characters after
-- the word for TextMesh Pro: those are the furigana and are not part of the text.
--
-- Not read: menus, the backlog, the witch book, the trials' flying statements and their
-- choices, the title's options.

local BUILD = "1B1734E731DB2C16B234F685FA738349"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The way in (an offset into main): where the runtime keeps the class Naninovel.Engine once it
-- exists. Its static fields hold the list of services.
local ENGINE_CLASS = 0x49ebab0
local K_NAME = 0x10              -- Il2CppClass: its name (C string)
local K_NAMESPACE = 0x18         -- Il2CppClass: its namespace (C string)
local K_PARENT = 0x58            -- Il2CppClass: the class it derives from
local K_STATICS = 0xb8           -- Il2CppClass: its static fields
local E_SERVICES = 0x48          -- Engine (static): List<IEngineService> services

-- Managed objects: the class at 0, fields from 0x10.
local STR_LENGTH, STR_CHARS = 0x10, 0x14 -- System.String: UTF-16
local ARRAY_DATA = 0x20                  -- array: first element
local LIST_ITEMS, LIST_SIZE = 0x10, 0x18 -- List<T>
local DICT_ENTRIES, DICT_COUNT = 0x18, 0x20 -- Dictionary<K, V>: entries {hash, next, key, value}
local ENTRY_SIZE, ENTRY_KEY, ENTRY_VALUE = 0x18, 0x08, 0x10

-- Naninovel.
local UM_CONTAINER = 0x90        -- UIManager: CanvasGroup containerGroup (over every UI of the game)
local M_ACTORS = 0x28            -- ActorManager: Dictionary<string, T> ManagedActors
local A_PANEL = 0x80             -- UITextPrinter: UITextPrinterPanel PrinterPanel
local U_CANVAS_GROUP = 0x28      -- ScriptableUIBehaviour: CanvasGroup
local U_VISIBLE = 0x78           -- ScriptableUIBehaviour: bool visibleSelf
local R_AUTHOR_ID = 0x130        -- RevealableTextPrinterPanel: MessageAuthor Author (string id first)
local R_AUTHOR_META = 0x140      -- RevealableTextPrinterPanel: CharacterMetadata AuthorMeta
local R_TEXT = 0x148             -- RevealableTextPrinterPanel: the RevealableText (a MonoBehaviour)
local R_NAME_PANEL = 0x150       -- RevealableTextPrinterPanel: AuthorNamePanel authorNamePanel
local NP_TEXT = 0x20             -- AuthorNameTMProPanel: TextMeshProUGUI textCompCache
local CM_DISPLAY = 0x78          -- CharacterMetadata: string DisplayName
local RT_UNPROCESSED = 0x810     -- NaninovelTMProText: string unprocessedText (with <ruby>)
local RT_STATE = 0x820           -- RevealableText: RevealState
local RS_LAST = 0x18             -- RevealState: int LastRevealedCharIndex

-- TextMeshPro (TMP_Text, TextMeshProUGUI) of this build.
local T_TEXT = 0xd8              -- string m_text
local T_INFO = 0x3a8             -- TMP_TextInfo m_textInfo
local T_DIRTY = 0x3b0            -- bool m_havePropertiesChanged: m_textInfo is not for m_text yet
local T_RECT = 0x3c0             -- RectTransform m_rectTransform
local T_CLIP = 0x704             -- Rect m_ClipRect: what a mask lets be seen, in the canvas's
local T_CLIPPED = 0x714          -- coordinates; bool m_ValidRect: there is such a mask
local T_CANVAS = 0x748           -- Canvas m_canvas
local I_COUNT = 0x18             -- TMP_TextInfo: int characterCount
local I_CHARS = 0x38             -- TMP_TextInfo: TMP_CharacterInfo[] characterInfo
local C_SIZE = 0x178             -- TMP_CharacterInfo
local C_CHAR, C_INDEX = 0x04, 0x08 -- char character, int index (into m_text, in UTF-16 units)
local C_ORIGIN = 0x118           -- floats: origin, xAdvance, ascender, baseLine, descender
local C_ALPHA = 0x143            -- byte: the alpha of Color32 color
local C_VISIBLE = 0x170          -- bool isVisible

-- The engine's objects (Unity 6, 64-bit): 0x10 lower than Unity 2021's.
local O_NATIVE = 0x10            -- UnityEngine.Object: the engine's own object
local N_OBJECT = 0x20            -- component: its GameObject
local G_COMPONENTS = 0x20        -- GameObject: array of {type, component}, 16 bytes each
local G_ACTIVE = 0x47            -- GameObject: active in the hierarchy (it and all above it)
local CG_ALPHA = 0x2c            -- CanvasGroup (the engine's): float alpha
local CG_INTERACTABLE = 0x30     -- CanvasGroup (the engine's): bool interactable
local X_HIERARCHY = 0x28         -- Transform: the hierarchy it is in
local X_INDEX = 0x30             -- Transform: its index there
local X_RECT = 0xa8              -- RectTransform: x, y, width, height in its own coordinates
local H_LOCAL = 0x18             -- hierarchy: per transform 0x30 bytes: position, rotation, scale
local H_PARENT = 0x20            -- hierarchy: per transform the index of its parent, -1 at the root

-- Frames a text must have stood complete before it is read: skipping and a press of the
-- button in the middle of the typing go through lines faster.
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

local function class_name(object)
    local class = pointer(object)
    local name = class and pointer(class + K_NAME)
    return name and mem.cstr(name, 64) or ""
end

local function list(l)
    local items, size = l and pointer(l + LIST_ITEMS), l and mem.s32(l + LIST_SIZE)
    local out = {}
    if not items or not size or size < 0 or size > 256 then return out end
    local raw = mem.read(items + ARRAY_DATA, 8 * size)
    for i = 0, #raw // 8 - 1 do
        local p = string.unpack("<I8", raw, 8 * i + 1)
        out[#out + 1] = p > 0x10000 and p or nil
    end
    return out
end

-- The entries of a Dictionary<string, T> as {key, value} (in use: a hash that is not negative).
local function entries_of(d)
    local entries, count = d and pointer(d + DICT_ENTRIES), d and mem.s32(d + DICT_COUNT)
    local out = {}
    if not entries or not count or count < 0 or count > 64 then return out end
    local raw = mem.read(entries + ARRAY_DATA, ENTRY_SIZE * count)
    for i = 0, #raw // ENTRY_SIZE - 1 do
        local at = i * ENTRY_SIZE
        local hash = string.unpack("<i4", raw, at + 1)
        local key = string.unpack("<I8", raw, at + ENTRY_KEY + 1)
        local value = string.unpack("<I8", raw, at + ENTRY_VALUE + 1)
        if hash >= 0 and value > 0x10000 then out[#out + 1] = { key, value } end
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

-- A UI of Naninovel's that is up: shown by its own word, active, and not faded out.
local function ui_shown(ui)
    if not ui or mem.u8(ui + U_VISIBLE) ~= 1 or not active(ui) then return false end
    local group = native(pointer(ui + U_CANVAS_GROUP))
    local alpha = group and mem.f32(group + CG_ALPHA)
    return alpha == nil or alpha > 0.01
end

-- ---------------------------------------------------------------------------------------
-- Text: what is shown, without tags, and the readings
-- ---------------------------------------------------------------------------------------

local function units_of(raw)
    local units = {}
    for i = 1, #raw - 1, 2 do units[#units + 1] = string.unpack("<I2", raw, i) end
    return units
end

-- The tag at units[i] ("<" ... ">"): its text and the index after it, or nil when it is none.
local function tag_at(units, i)
    local j = i + 1
    while j <= #units and units[j] ~= 0x3E and units[j] ~= 0x3C and j - i < 128 do j = j + 1 end
    if j > #units or units[j] ~= 0x3E then return nil end
    local tag = {}
    for k = i + 1, j - 1 do tag[#tag + 1] = utf8.char(units[k]) end
    return table.concat(tag), j + 1
end

-- The code point at units[i] and how many units it takes.
local function code_at(units, i)
    local u = units[i]
    if u >= 0xD800 and u <= 0xDBFF and units[i + 1] then
        return 0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00), 2
    end
    return u, 1
end

-- The message as the script gave it (UTF-16, with <ruby="reading">word</ruby> and <br>): the
-- text (UTF-8, a line break for <br>, no other tags) and its readings as {first place (from 0),
-- places, reading}.
local function script_text(raw)
    local units = units_of(raw)
    local out, ruby, n = {}, {}, 0
    local open -- {first place, reading} of the ruby being gone through
    local i = 1
    while i <= #units do
        if units[i] == 0x3C then
            local tag, after = tag_at(units, i)
            if tag then
                local reading = tag:match('^ruby="(.*)"$') or tag:match("^ruby=(.*)$")
                if reading then
                    open = { n, reading }
                elseif tag == "/ruby" and open then
                    if n > open[1] and open[2] ~= "" then ruby[#ruby + 1] = { open[1], n - open[1], open[2] } end
                    open = nil
                elseif tag == "br" then
                    n = n + 1
                    out[n] = "\n"
                end
                i = after
                goto continue
            end
        end
        do
            local code, width = code_at(units, i)
            n = n + 1
            out[n] = utf8.char(code)
            i = i + width
        end
        ::continue::
    end
    return table.concat(out), ruby, n
end

-- What TextMesh Pro was given (UTF-16, with its own tags, a reading as a link of small
-- characters after its word, <br> for a line break): for each UTF-16 unit of it the place
-- (code point, from 1) it has in the text without tags and readings, and that text.
local function shown_places(raw)
    local units = units_of(raw)
    local places, out, n = {}, {}, 0
    local in_ruby = false
    local i = 1
    while i <= #units do
        if units[i] == 0x3C then
            local tag, after = tag_at(units, i)
            if tag then
                if tag:match('^link="NANINOVEL%.RUBY"') then
                    in_ruby = true
                elseif tag == "/link" then
                    in_ruby = false
                elseif tag == "br" then
                    n = n + 1
                    out[n] = "\n"
                end
                i = after
                goto continue
            end
        end
        do
            local code, width = code_at(units, i)
            if not in_ruby then
                n = n + 1
                out[n] = utf8.char(code)
                for k = i, i + width - 1 do places[k] = n end
            end
            i = i + width
        end
        ::continue::
    end
    return places, table.concat(out)
end

-- Both of the last few strings: a text stands for many frames.
local memo, memo_count = {}, 0
local function once(fn, raw)
    local key = (fn == script_text and "s" or "p") .. raw
    local known = memo[key]
    if known then return table.unpack(known, 1, 3) end
    local a, b, c = fn(raw)
    if memo_count >= 32 then memo, memo_count = {}, 0 end
    memo[key] = { a, b, c }
    memo_count = memo_count + 1
    return a, b, c
end

-- A name as TextMesh Pro shows it, without its tags.
local function plain(raw)
    local units = units_of(raw)
    local out = {}
    local i = 1
    while i <= #units do
        local tag, after
        if units[i] == 0x3C then tag, after = tag_at(units, i) end
        if tag then
            i = after
        else
            local code, width = code_at(units, i)
            out[#out + 1] = utf8.char(code)
            i = i + width
        end
    end
    return (table.concat(out):gsub("^%s+", ""):gsub("%s+$", ""))
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
local function placement(tmp)
    local canvas = own_transform(pointer(tmp + T_CANVAS))
    local node = native(pointer(tmp + T_RECT))
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
    if mem.u8(tmp + T_CLIPPED) == 1 then
        local cx, cy, cw, ch = string.unpack("<ffff", mem.read(tmp + T_CLIP, 16))
        place.clip = { (cx - rx) * px, height - (cy + ch - ry) * py,
                       (cx + cw - rx) * px, height - (cy - ry) * py }
    end
    return place
end

-- The cells of the characters TextMesh Pro has laid out for a text object, by the place of
-- each in the text without tags and readings: {left, top, width, height} in the picture. A
-- reading's characters, a transparent character and one a mask hides have none. Returns nil
-- while the table is not for the object's text.
local function cells(tmp, raw_text, places)
    if mem.u8(tmp + T_DIRTY) ~= 0 then return nil end
    local info = pointer(tmp + T_INFO)
    local count = info and mem.s32(info + I_COUNT)
    local array = info and pointer(info + I_CHARS)
    if not count or count < 0 or count > 2000 or not array then return nil end
    local place = placement(tmp)
    if not place then return nil end
    local clip = place.clip
    local out = {}
    local raw = mem.read(array + ARRAY_DATA, count * C_SIZE)
    for i = 0, #raw // C_SIZE - 1 do
        local at = i * C_SIZE
        local code = string.unpack("<I2", raw, at + C_CHAR + 1)
        local index = string.unpack("<i4", raw, at + C_INDEX + 1)
        local spot = places[index + 1]
        local unit = index >= 0 and 2 * index + 2 <= #raw_text and string.unpack("<I2", raw_text, 2 * index + 1)
        if spot and unit == code and raw:byte(at + C_VISIBLE + 1) ~= 0 and
            raw:byte(at + C_ALPHA + 1) ~= 0 then
            local origin, advance, ascender, _, descender = string.unpack("<fffff", raw, at + C_ORIGIN + 1)
            local left, right = place[3] + place[1] * origin, place[3] + place[1] * advance
            local top, bottom = place[4] + place[2] * ascender, place[4] + place[2] * descender
            local middle = (top + bottom) / 2
            if not clip or (middle >= clip[2] and middle <= clip[4]) then
                out[spot] = { left, top, right - left, bottom - top }
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------
-- What is reported
-- ---------------------------------------------------------------------------------------

local shown = {} -- by window name: {text, since, emitted, placed}

local function close(name)
    local state = shown[name]
    if state and state.placed then
        reader.layout(name, nil)
        state.placed = nil
    end
end

local function forget(name)
    close(name)
    shown[name] = nil
end

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
        reader.emit{ text = state.text, speaker = state.speaker, window = name, ruby = state.ruby }
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
        state = { text = text, since = frame, speaker = info.speaker, ruby = info.ruby }
        shown[name] = state
    end
    if info.hold and not state.emitted then
        state.since, state.held = frame, true
    elseif not info.hold then
        state.held = nil
        if not state.emitted then state.speaker = info.speaker end
    end
    if not state.emitted and frame - state.since >= STEADY then emit(name, state) end
    return state.emitted == true
end

-- ---------------------------------------------------------------------------------------
-- The printers
-- ---------------------------------------------------------------------------------------

-- The speaker of a printer's message: the name on its plate, or the character's name.
local function speaker_of(panel)
    if utf16(pointer(panel + R_AUTHOR_ID)) == "" then return nil end
    local name_panel = pointer(panel + R_NAME_PANEL)
    local name_text = name_panel and pointer(name_panel + NP_TEXT)
    if name_text and active(name_text) then
        local name = plain(utf16(pointer(name_text + T_TEXT)))
        if name ~= "" then return name end
    end
    local meta = pointer(panel + R_AUTHOR_META)
    local name = meta and plain(utf16(pointer(meta + CM_DISPLAY)))
    return name ~= "" and name or nil
end

local function printer(name, panel, frame, seen)
    if not ui_shown(panel) then return end
    local tmp = pointer(panel + R_TEXT)
    if not tmp or not active(tmp) then return end
    local script_raw = utf16(pointer(tmp + RT_UNPROCESSED))
    if script_raw == "" then return end
    local text, ruby = once(script_text, script_raw)
    if not readable(text) then return end
    -- All there once the last character TextMesh Pro has is revealed.
    local revealed = pointer(tmp + RT_STATE) and mem.s32(pointer(tmp + RT_STATE) + RS_LAST)
    local info = pointer(tmp + T_INFO)
    local count = info and mem.s32(info + I_COUNT)
    local ready = revealed and count and count > 0 and revealed >= count - 1 and mem.u8(tmp + T_DIRTY) == 0
    seen[name] = true
    if not offer(name, text, frame, { speaker = speaker_of(panel), hold = not ready,
                                       ruby = #ruby > 0 and ruby or nil }) then
        return
    end
    local shown_raw = utf16(pointer(tmp + T_TEXT))
    local places, shown_text = once(shown_places, shown_raw)
    if shown_text ~= text then return close(name) end
    local glyphs = cells(tmp, shown_raw, places)
    if glyphs then place(name, utf8.len(text) or 0, glyphs) end
end

-- A printer's window by the printer's name: "message" for the game's own, "Normal".
local names = {}
local function printer_name(key)
    local known = names[key]
    if known then return known end
    local id = plain(utf16(key))
    known = (id == "Normal" or id == "") and "message" or "message." .. id
    names[key] = known
    return known
end

local engine_class_ok

reader.on_frame(function(frame)
    local class = pointer(base + ENGINE_CLASS)
    if not class then return end
    if engine_class_ok ~= class then
        if mem.cstr(pointer(class + K_NAME) or 0, 16) ~= "Engine" or
            mem.cstr(pointer(class + K_NAMESPACE) or 0, 16) ~= "Naninovel" then return end
        engine_class_ok = class
    end
    local statics = pointer(class + K_STATICS)
    local services = statics and pointer(statics + E_SERVICES)
    local seen = {}
    local all = list(services)
    -- The game's UIs are taken out of reach under the log, the help pages and while the player
    -- has hidden them (B): the container they are all in is then not interactable. The lines
    -- stay as they are (not read again when they come back), without places.
    for _, service in ipairs(all) do
        local name = class_name(service)
        if name == "UiManagerExtended" or name == "UIManager" then
            local group = native(pointer(service + UM_CONTAINER))
            if group and (mem.u8(group + CG_INTERACTABLE) == 0 or mem.f32(group + CG_ALPHA) < 0.01) then
                for window in pairs(shown) do close(window) end
                return
            end
            break
        end
    end
    for _, service in ipairs(all) do
        if class_name(service) == "TextPrinterManager" then
            for _, entry in ipairs(entries_of(pointer(service + M_ACTORS))) do
                local actor = entry[2]
                local panel = class_name(actor) == "UITextPrinter" and pointer(actor + A_PANEL)
                -- Only the panels that reveal a message (the trials' statements are another kind).
                if panel and class_name(pointer(panel + R_TEXT)):find("RevealableText", 1, true) then
                    printer(printer_name(entry[1]), panel, frame, seen)
                end
            end
            break
        end
    end
    for name in pairs(shown) do
        if not seen[name] then leave(name) end
    end
end)

-- For the harness (lua mgwt_dump()): what the profile holds.
function mgwt_dump()
    for name, state in pairs(shown) do
        print(string.format("%s: %s since %d emitted %s placed %s", name, state.text:gsub("\n", "/"),
                            state.since, tostring(state.emitted), state.placed and "yes" or "no"))
    end
end
