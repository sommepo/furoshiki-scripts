-- reader: title ファタモルガーナの館 -DREAMS OF THE REVENANTS EDITION- (The House in Fata Morgana)
-- reader: reads Dialogue, narration, furigana, and choices
-- reader: version Base game (version 0) and its update v65536
-- reader: touch game
-- The House in Fata Morgana: Dreams of the Revenants Edition (ファタモルガーナの館), Switch.
-- Written for main builds CDD56D3A353D6145A213E3C7F1D70C4D (update v65536) and
-- 1BA5E67215FB214EAFEC6223605A3679 (base game, v0): the game's own code and the layout of
-- its objects are the same in both.
--
-- A Unity game (2017.4, IL2CPP) that shows its text with TextMesh Pro. The script interpreter
-- adds text to the message window piece by piece; TextMesh Pro lays the whole text of the
-- window out and keeps, for every character, what it is and where it is in the text object's
-- own coordinates. This profile reads that table and follows the object's transforms up to
-- its canvas to turn the coordinates into pixels of the picture.

local BUILDS = {
    ["CDD56D3A353D6145A213E3C7F1D70C4D"] = true,
    ["1BA5E67215FB214EAFEC6223605A3679"] = true,
}
if not BUILDS[reader.build_id] then
    error("this profile is for the base game and update v65536, the game is build " ..
          tostring(reader.build_id))
end
local base = reader.base

-- Code (offsets into main; x0 is the object, the arguments follow).
local MESWIN_UPDATE = 0x16aac0   -- CommonMesWin.Update(): every frame the window object is active
local MESWIN_SPEAKER = 0x16b9d0  -- CommonMesWin.disp_speaker(string name)
local MESWIN_RUBY = 0x16bc40     -- CommonMesWin.AddRubyText(string str, int index)
local MESWIN_NO_RUBY = 0x16acc0  -- CommonMesWin.DeleteRubyText(): with every new page
local MENU_DISP = 0xcafc0        -- SelectionMenu.disp(int item_num): a menu of answers opens
local MENU_UPDATE = 0xd2940      -- SubMenuBase.Update(): every frame a menu is active
local MENU_SETTEXT = 0xd2f70     -- SubMenuBase.settext(int index, string str)
local MENU_HIDE = 0xd2e60        -- SubMenuBase.hide()
local TMP_SET_TEXT = 0x84d4a0    -- TMP_Text.set_text(string value)
-- NovelSceneMain: what is run once when the scene goes over to another state. The pause
-- menu's screens are drawn over the message window without the window being told.
local SCENE = {
    [0x1aaa80] = "init", [0x1aae10] = "loading", [0x1aae90] = "title", [0x1aaf00] = "running",
    [0x1ac460] = "pause", [0x1ac4e0] = "skip", [0x1ac560] = "backskip", [0x1ac5d0] = "backlog",
}
local STORY = { running = true, skip = true }

-- Managed objects (IL2CPP): the class at 0, fields from 0x10.
local O_NATIVE = 0x10            -- UnityEngine.Object: the engine's own object
local K_NAME = 0x10              -- class: its name (C string)
local STR_LENGTH, STR_CHARS = 0x10, 0x14 -- System.String: UTF-16
local ARRAY_DATA = 0x20          -- array: first element

-- TweenDispControl (CommonMesWin, the message window, is one): something that is shown and
-- hidden with a fade.
local D_SHOWN = 0x18             -- bool is_disp_
local SHOWN_BY = { TweenDispControl = true, CommonMesWin = true }
local W_TEXT = 0x40              -- CommonMesWin: GameObject text, carries the next two
local P_ORIGINAL = 0x98          -- TextPutTMPro: string original_message, the text as the
                                 -- script gave it, before lines were broken to fit

-- TextMeshProUGUI.
local T_TEXT = 0xb0              -- string m_text: what was last asked for
local T_INFO = 0x330             -- TMP_TextInfo m_textInfo
local T_DIRTY = 0x338            -- bool m_havePropertiesChanged: m_textInfo is not for m_text yet
local T_RECT = 0x348             -- RectTransform m_rectTransform
local T_CANVAS = 0xae0           -- Canvas m_canvas
local I_COUNT = 0x18             -- TMP_TextInfo: int characterCount
local I_CHARS = 0x38             -- TMP_CharacterInfo[] characterInfo
-- TMP_CharacterInfo, 0x148 bytes each.
local C_SIZE = 0x148
local C_CHAR = 0x00              -- char character
local C_ORIGIN = 0x114           -- floats: origin, ascender, baseLine, descender, xAdvance
local C_VISIBLE = 0x144          -- bool isVisible

-- The engine's objects (Unity 2017.4, 64-bit).
local N_MANAGED = 0x28           -- component: its managed object
local N_OBJECT = 0x30            -- component: its GameObject
local G_COMPONENTS = 0x30        -- GameObject: array of {type, component}, 16 bytes each
local G_COUNT = 0x40             -- GameObject: how many
local X_HIERARCHY = 0x38         -- Transform: the hierarchy it is in
local X_INDEX = 0x40             -- Transform: its index there
local X_RECT = 0xb8              -- RectTransform: x, y, width, height in its own coordinates
local H_LOCAL = 0x08             -- hierarchy: per transform 0x30 bytes: position, rotation, scale
local H_PARENT = 0x10            -- hierarchy: per transform the index of its parent, -1 at the root
local H_NODES = 0x20             -- hierarchy: per transform the Transform itself

-- Frames without new text after which what was added is one piece to read. The interpreter
-- adds the parts of a sentence a few frames apart (its pauses are part of the typing), and
-- then waits for a button.
local GAP = 8

local function str_raw(p)
    if not p or p == 0 then return "" end
    local n = mem.s32(p + STR_LENGTH)
    if not n or n <= 0 or n > 8192 then return "" end
    return mem.read(p + STR_CHARS, n * 2)
end

local function str(p)
    return text.utf16le(str_raw(p))
end

local function class_name(object)
    local class = object and object ~= 0 and mem.u64(object)
    local name = class and class ~= 0 and mem.u64(class + K_NAME)
    return name and name ~= 0 and mem.cstr(name, 64) or ""
end

-- Calls visit(managed object, its class name) for the scripts and other components with a
-- managed side on a GameObject (the engine's own object).
local function each_component(native, visit)
    local list, count = mem.u64(native + G_COMPONENTS), mem.s32(native + G_COUNT)
    if not list or list == 0 or not count or count < 1 or count > 64 then return end
    for i = 0, count - 1 do
        local c = mem.u64(list + 16 * i + 8)
        local managed = c and c ~= 0 and mem.u64(c + N_MANAGED)
        if managed and managed ~= 0 then visit(managed, class_name(managed)) end
    end
end

-- The managed component of class `name` on a GameObject (managed), or nil.
local function component(game_object, name)
    local native = game_object and game_object ~= 0 and mem.u64(game_object + O_NATIVE)
    if not native or native == 0 then return nil end
    local found
    each_component(native, function(managed, class)
        if class == name then found = found or managed end
    end)
    return found
end

-- The text object's own transform (the engine's), or nil.
local function transform(tmp)
    local rect = mem.u64(tmp + T_RECT)
    local node = rect and rect ~= 0 and mem.u64(rect + O_NATIVE)
    return node and node ~= 0 and node or nil
end

-- What shows and hides a text object: the TweenDispControls on it and on what it is part of.
-- All of them have to be shown for the text to be seen.
local function controls(tmp)
    local out = {}
    local node = transform(tmp)
    local hierarchy = node and mem.u64(node + X_HIERARCHY)
    if not hierarchy or hierarchy == 0 then return out end
    local index = mem.s32(node + X_INDEX)
    local parents, nodes = mem.u64(hierarchy + H_PARENT), mem.u64(hierarchy + H_NODES)
    local steps = 0
    while index and index >= 0 and steps < 64 do
        local at = mem.u64(nodes + 8 * index)
        local object = at and at ~= 0 and mem.u64(at + N_OBJECT)
        if object and object ~= 0 then
            each_component(object, function(managed, class)
                if SHOWN_BY[class] then out[#out + 1] = managed end
            end)
        end
        index = mem.s32(parents + 4 * index)
        steps = steps + 1
    end
    return out
end

local function shown(list)
    for _, control in ipairs(list) do
        if mem.u8(control + D_SHOWN) ~= 1 then return false end
    end
    return true
end

-- Where a text object is in the picture: {scale x, scale y, offset x, offset y, width, height}
-- that turn its coordinates into pixels (y down) of a picture of that size, or nil while that
-- cannot be told. The canvas is drawn over the whole picture, so its rectangle is the picture.
local function placement(tmp)
    local node, canvas = transform(tmp), mem.u64(tmp + T_CANVAS)
    if not node or not canvas or canvas == 0 then return nil end
    local native_canvas = mem.u64(canvas + O_NATIVE)
    if not native_canvas or native_canvas == 0 then return nil end
    local object = mem.u64(native_canvas + N_OBJECT)
    local list = object and object ~= 0 and mem.u64(object + G_COMPONENTS)
    -- A GameObject's first component is its transform.
    local top = list and list ~= 0 and mem.u64(list + 8)
    if not top or top == 0 then return nil end
    local hierarchy, index = mem.u64(node + X_HIERARCHY), mem.s32(node + X_INDEX)
    local stop = mem.s32(top + X_INDEX)
    if not hierarchy or hierarchy == 0 or mem.u64(top + X_HIERARCHY) ~= hierarchy then
        return nil
    end
    local locals, parents = mem.u64(hierarchy + H_LOCAL), mem.u64(hierarchy + H_PARENT)
    local sx, sy, ox, oy = 1, 1, 0, 0
    local steps = 0
    while index ~= stop do
        if not index or index < 0 or steps > 64 then return nil end
        local raw = mem.read(locals + index * 0x30, 0x30)
        if #raw < 0x30 then return nil end
        local tx, ty, _, _, _, _, _, _, kx, ky = string.unpack("<ffffffffff", raw)
        sx, sy, ox, oy = sx * kx, sy * ky, tx + kx * ox, ty + ky * oy
        index = mem.s32(parents + 4 * index)
        steps = steps + 1
    end
    local raw = mem.read(top + X_RECT, 16)
    if #raw < 16 then return nil end
    local rx, ry, rw, rh = string.unpack("<ffff", raw)
    local width, height = reader.picture()
    if not width or rw <= 0 or rh <= 0 then return nil end
    local px, py = width / rw, height / rh
    -- canvas x = ox + sx * x, picture x = (canvas x - rx) * px; y likewise, upside down
    return { sx * px, -sy * py, (ox - rx) * px, height - (oy - ry) * py, width, height }
end

local function place_key(place)
    return table.concat(place, " ")
end

-- The text object's own rectangle in the picture, cut to it: what taps are kept from the game in.
local function box_of(tmp, place)
    local node = transform(tmp)
    local raw = node and mem.read(node + X_RECT, 16) or ""
    if #raw < 16 then return nil end
    local x, y, w, h = string.unpack("<ffff", raw)
    local left, right = place[3] + place[1] * x, place[3] + place[1] * (x + w)
    local top, bottom = place[4] + place[2] * (y + h), place[4] + place[2] * y
    left, top = math.max(left, 0), math.max(top, 0)
    right, bottom = math.min(right, place[5]), math.min(bottom, place[6])
    if right <= left or bottom <= top then return nil end
    return { left, top, right - left, bottom - top }
end

-- The characters TextMesh Pro has laid out for a text object: a list of
-- {code, left, top, right, bottom, visible}, positions in the object's own coordinates (y up).
local function characters(tmp)
    local info = mem.u64(tmp + T_INFO)
    local count = info and info ~= 0 and mem.s32(info + I_COUNT)
    local array = info and info ~= 0 and mem.u64(info + I_CHARS)
    if not count or count <= 0 or count > 2000 or not array or array == 0 then return {} end
    local raw = mem.read(array + ARRAY_DATA, count * C_SIZE)
    local out = {}
    for i = 0, #raw // C_SIZE - 1 do
        local at = i * C_SIZE
        local code = string.unpack("<H", raw, at + C_CHAR + 1)
        local origin, ascender, _, descender, advance =
            string.unpack("<fffff", raw, at + C_ORIGIN + 1)
        local visible = raw:byte(at + C_VISIBLE + 1) ~= 0
        out[#out + 1] = { code, origin, ascender, advance, descender, visible }
    end
    return out
end

local function is_break(code)
    return code == 10 or code == 13 or code == 0
end

-- Latin letters and the like are kept apart by spaces; a line break between two of them
-- stands for one.
local function spaced(code)
    return code ~= nil and code > 0x20 and code < 0x2e80
end

-- Adds the characters first..last of `chars` to a builder: without the breaks between lines
-- (most were put there to fit the box), with the readings in `ruby` (by place in `chars`).
-- Marks what is left out with `skip`, what is put in with `add`.
local function add_text(b, chars, first, last, ruby)
    local before
    for i = first, last do
        local c = chars[i]
        local code = c[1]
        c.skip, c.add = nil, nil
        if is_break(code) then
            c.skip = true
            local after
            for k = i + 1, last do
                if not is_break(chars[k][1]) then after = chars[k][1] break end
            end
            if spaced(before) and spaced(after) then
                c.skip, c.add = nil, " "
                b:add(" ")
                before = 0x20
            end
        else
            local reading = ruby and ruby[i]
            if reading then
                b:add_ruby(utf8.char(code), reading)
            else
                b:add(utf8.char(code))
            end
            before = code
        end
    end
end

-- The cells of the characters first..last as picture pixels, one for each that was emitted.
local function cells(chars, first, last, place, out)
    out = out or {}
    for i = first, last do
        local c = chars[i]
        if c.skip then
            -- not part of the text that was emitted
        elseif c[6] and not c.add then
            local left, top = place[3] + place[1] * c[2], place[4] + place[2] * c[3]
            local right, bottom = place[3] + place[1] * c[4], place[4] + place[2] * c[5]
            out[#out + 1] = { left, top, right - left, bottom - top }
        else
            out[#out + 1] = false
        end
    end
    return out
end

local scene = "running" -- until told otherwise: a profile can be loaded in the middle of the story
for address, name in pairs(SCENE) do
    reader.hook(base + address, function() scene = name end)
end

-- ---------------------------------------------------------------------------------------
-- The message window
-- ---------------------------------------------------------------------------------------

local windows = {} -- by CommonMesWin
local window_count = 0

local function window_state(win)
    local state = windows[win]
    if not state then
        window_count = window_count + 1
        state = {
            name = window_count == 1 and "message" or "message" .. window_count,
            speaker = "", ruby = {}, pieces = {}, done = 0, count = 0, grown = 0, seen = 0,
            tried = -1000,
        }
        windows[win] = state
    end
    return state
end

-- Takes the window's text off the screen; the pieces stay, for when it is shown again.
local function close(state)
    if state.placed then
        for _, piece in ipairs(state.pieces) do reader.layout(piece.window, nil) end
        state.placed = nil
    end
end

local function forget(state)
    close(state)
    state.pieces = {}
    state.done, state.count, state.chars = 0, 0, nil
end

-- Readings are given for a place in the text as the script gave it (in UTF-16 units). What
-- TextMesh Pro shows is that text without its tags and with line breaks added to fit the box:
-- going through both side by side gives the readings by character shown.
local function readings(state)
    if not next(state.ruby) then return nil end
    local original = str_raw(state.put and mem.u64(state.put + P_ORIGINAL))
    local units = #original // 2
    local function unit(j)
        return j < units and string.unpack("<H", original, 2 * j + 1) or nil
    end
    local out = {}
    local j = 0
    for k, c in ipairs(state.chars) do
        local code = c[1]
        while unit(j) == 0x3c and code ~= 0x3c do -- a tag: up to its >
            repeat j = j + 1 until unit(j) == nil or unit(j - 1) == 0x3e
        end
        if unit(j) == code then
            out[k] = state.ruby[j]
            j = j + 1
        elseif not is_break(code) then
            break -- not the same text after all
        end
    end
    return out
end

reader.hook(base + MESWIN_UPDATE, function(cpu)
    local win = cpu.x0
    local state = window_state(win)
    local frame = reader.frame()
    state.seen = frame
    if not state.tmp then
        if frame - state.tried < 60 then return end
        state.tried = frame
        local object = mem.u64(win + W_TEXT)
        state.tmp = component(object, "TextMeshProUGUI")
        if not state.tmp then return end
        state.put = component(object, "TextPutTMPro")
        state.controls = controls(state.tmp)
    end
    local tmp = state.tmp
    if mem.u8(tmp + T_DIRTY) ~= 0 then return end -- laid out again later in this frame

    local source = mem.u64(tmp + T_TEXT)
    if source ~= state.source then
        state.source = source
        local chars = characters(tmp)
        -- The same page with more on it, or another page?
        local same = state.chars ~= nil and #chars >= state.done
        if same then
            for i = 1, state.done do
                if chars[i][1] ~= state.chars[i][1] then same = false break end
            end
        end
        if not same then forget(state) end
        for i = 1, state.done do
            chars[i].skip, chars[i].add = state.chars[i].skip, state.chars[i].add
        end
        state.chars = chars
        if #chars > state.count then
            state.grown = frame
            scene = STORY[scene] and scene or "running" -- text is only added while the story runs
        end
        state.count = #chars
        close(state)
    end
    if not state.chars then return end
    if not STORY[scene] or not shown(state.controls) then return close(state) end

    if state.count > state.done and frame - state.grown >= GAP then
        -- A new piece: what was added since the last one.
        local first, last = state.done + 1, state.count
        local b = reader.builder()
        add_text(b, state.chars, first, last, readings(state))
        state.done = last
        local line = b:text()
        if line:find("%S") then
            local piece = {
                window = state.name .. "." .. (#state.pieces + 1), first = first, last = last,
            }
            state.pieces[#state.pieces + 1] = piece
            reader.emit{
                text = line,
                ruby = b:ruby(),
                speaker = state.speaker ~= "" and state.speaker or nil,
                window = piece.window,
            }
            close(state)
        end
    end

    if #state.pieces > 0 then
        local place = placement(tmp)
        if not place then
            close(state)
        elseif place_key(place) ~= state.placed then
            local box = box_of(tmp, place)
            for _, piece in ipairs(state.pieces) do
                reader.layout(piece.window, {
                    space = { place[5], place[6] },
                    box = box,
                    glyphs = cells(state.chars, piece.first, piece.last, place),
                })
            end
            state.placed = place_key(place)
        end
    end
end)

reader.hook(base + MESWIN_SPEAKER, function(cpu)
    local name = str(cpu.x1):gsub("^%s+", ""):gsub("%s+$", "")
    window_state(cpu.x0).speaker = name
end)

-- A reading for the character that comes next: the index is where the text as the script
-- gave it ends so far. Dots over a word for emphasis are written the same way.
reader.hook(base + MESWIN_RUBY, function(cpu)
    local reading = str(cpu.x1)
    if reading ~= "" and not reading:find("^[・･﹅﹆•●]+$") then
        window_state(cpu.x0).ruby[cpu.w2] = reading
    end
end)

reader.hook(base + MESWIN_NO_RUBY, function(cpu)
    window_state(cpu.x0).ruby = {}
end)

-- ---------------------------------------------------------------------------------------
-- Answers to choose from
-- ---------------------------------------------------------------------------------------

local menus = {} -- by SelectionMenu
local setting    -- the settext call in progress: its menu, the answer's number and the string

local function close_menu(menu)
    if menu.placed then
        reader.layout("choice", nil)
        menu.placed = nil
    end
end

reader.hook(base + MENU_DISP, function(cpu)
    if menus[cpu.x0] then close_menu(menus[cpu.x0]) end
    menus[cpu.x0] = { items = {}, count = cpu.w1, seen = reader.frame() }
end)

reader.hook(base + MENU_SETTEXT, function(cpu)
    local menu = menus[cpu.x0]
    setting = menu and { menu = menu, index = cpu.w1, string = cpu.x2 } or nil
end)

-- The button's text object is the one the answer's string is handed to.
reader.hook(base + TMP_SET_TEXT, function(cpu)
    if setting and cpu.x1 == setting.string then
        setting.menu.items[setting.index + 1] = { tmp = cpu.x0 }
        setting = nil
    end
end)

reader.hook(base + MENU_HIDE, function(cpu)
    local menu = menus[cpu.x0]
    if menu then
        close_menu(menu)
        menus[cpu.x0] = nil
    end
end)

reader.hook(base + MENU_UPDATE, function(cpu)
    local menu = menus[cpu.x0]
    if not menu then return end
    menu.seen = reader.frame()
    for i = 1, menu.count do
        local item = menu.items[i]
        if not item or mem.u8(item.tmp + T_DIRTY) ~= 0 then return end
    end
    if menu.count < 1 then return end
    if not menu.text then
        local b = reader.builder()
        for i = 1, menu.count do
            local item = menu.items[i]
            item.chars = characters(item.tmp)
            if i > 1 then b:add("\n") end
            add_text(b, item.chars, 1, #item.chars)
        end
        menu.text = b:text()
        menu.controls = controls(menu.items[1].tmp)
        if menu.text:find("%S") then
            reader.emit{ text = menu.text, channel = "choice", window = "choice" }
        end
    end
    if not menu.text:find("%S") then return end
    if not STORY[scene] or not shown(menu.controls) then return close_menu(menu) end
    local glyphs, where = {}, {}
    local space
    for i = 1, menu.count do
        local item = menu.items[i]
        local place = placement(item.tmp)
        if not place then return close_menu(menu) end
        if i > 1 then glyphs[#glyphs + 1] = false end
        cells(item.chars, 1, #item.chars, place, glyphs)
        where[i] = place_key(place)
        space = { place[5], place[6] }
    end
    where = table.concat(where, " ")
    if where ~= menu.placed then
        reader.layout("choice", { space = space, glyphs = glyphs })
        menu.placed = where
    end
end)

-- A window whose object is switched off is not updated any more: its text is gone.
reader.on_frame(function(frame)
    for _, state in pairs(windows) do
        if frame - state.seen > 3 then close(state) end
    end
    for _, menu in pairs(menus) do
        if frame - menu.seen > 3 then close_menu(menu) end
    end
end)

-- For the harness (lua fata_dump()): what the profile holds.
function fata_dump()
    print("scene " .. scene)
    for win, state in pairs(windows) do
        local out = {}
        for _, c in ipairs(state.chars or {}) do
            out[#out + 1] = (c[1] == 10 and "⏎" or utf8.char(c[1])) .. (c[6] and "" or "°")
        end
        local ruby = {}
        for index, reading in pairs(state.ruby) do ruby[#ruby + 1] = index .. "=" .. reading end
        print(string.format("%s %x: speaker '%s', %d of %d characters in %d pieces, %s, ruby {%s}",
                            state.name, win, state.speaker, state.done, state.count, #state.pieces,
                            state.placed and "placed" or "not placed", table.concat(ruby, " ")))
        print(table.concat(out))
        if state.tmp then print("as asked for: " .. str(mem.u64(state.tmp + T_TEXT))) end
    end
    for menu, state in pairs(menus) do
        print(string.format("menu %x: %d answers, %s: %s", menu, state.count,
                            state.placed and "placed" or "not placed", tostring(state.text)))
    end
end
