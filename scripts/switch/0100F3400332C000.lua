-- reader: no hooks
-- reader: title ゼノブレイド2 (Xenoblade Chronicles 2)
-- reader: reads Cutscene subtitles, field dialogue, speakers, furigana, and choices
-- reader: version The game as released (1.0.0), without an update
-- ゼノブレイド2 (Xenoblade Chronicles 2), Switch, Japanese release.
-- Written for main build 3FFAE0EA40EC563F4BA38C581215A68B (the game as released, no update).
--
-- Monolith Soft's own engine. The program keeps its names, so its UI can be followed by reading
-- memory once a frame; nothing is hooked and the game runs natively (first line of this file).
-- The menu manager keeps a table of the UI objects it has attached, by slot; a UI object is
-- found by its ID in a map; a layout's children hang in a list. A text object keeps the string
-- it shows as a ui::UIStr: mostly a pair of a text file's handle and a message's ID, which the
-- text manager turns into a row of a BDAT table with the message under its "name" column.
--
-- Read: a scene's subtitles (centred, no speaker: the game shows none), a conversation in its
-- balloon with the speaker from the balloon's tab, passing remarks in the small balloons, and
-- both kinds of choice, without places. A line counts when it has stood for a frame after the
-- one it was first seen in. A balloon lies in a duplicate of a hidden template: only a shown
-- one is read, for the template holds a placeholder. The objects keep their last string when
-- hidden, so nothing is read from an object that is not shown.
--
-- Not read: menus, quests and the map, the system's dialogs, the guide's window, item
-- and reward messages, what is written in pictures, the film's staff names.

local BUILD = "3FFAE0EA40EC563F4BA38C581215A68B"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The way in (offsets into main).
local MENU_MANAGER = 0x149de10   -- gf::GfMenuCallManager*
local OBJECT_MAP = 0x14b2408     -- fw::PointerMap of UI objects by ID
local TEXT_MANAGER = 0x14aef90   -- ui::UITextManager*

local M_ATTACHED = 0x8           -- menu manager: attached objects' IDs (u32), by slot
local SLOT_SUBTITLE = 1          -- gf::GfMenuObjEventSubtitle
local SLOT_TALK = 2              -- gf::GfMenuObjBalloon: a conversation, LAY_ev_talk_root
local SLOT_SELECT = 4            -- the same: a choice, LAY_ev_select_root
local SLOT_REMARK = 5            -- the same: passing remarks, LAY_auto_talk_root
local SLOT_FIELD_SELECT = 7      -- a choice across the screen in the field, LAY_select
local TM_FILES = 0xc10           -- text manager: fw::PointerMap of text files by handle
local TF_TABLE = 0x8             -- ui::UITextFile: its BDAT table

-- fw::PointerMap.
local PM_ENTRIES = 0x8           -- entries of 16 bytes: the pointer, then the key
local PM_SIZE = 0x20
local PM_MASK = 0x34

-- A UI object.
local O_DISP = 0x58              -- its ui::UIDisplayInfo's flag: shown
local O_NAME = 0xa0              -- its name, inline
local O_SIZE = 0x7c              -- two u16: its width and height as laid out
local O_DRAW = 0x28              -- two s16: a layout's corner on screen; a text's centre in its layout
local O_TYPE = 0xd8              -- u16: 3 for a layout, which has children
local TYPE_LAYOUT = 3
local L_CHILDREN = 0x108         -- layout: the list of its children
local C_NEXT = 0x10              -- child: the link to the next, 0x10 into the next child
local T_STRING = 0x108           -- text object: its ui::UIStr

-- A ui::UIStr.
local S_KIND = 0x10              -- 1: handle at +0 and message ID at +4; 2 and 3: a pointer at +0
local KIND_MESSAGE, KIND_POINTER, KIND_OWNED = 1, 2, 3

-- How a subtitle is laid out, in the UI's 1280x720 units: centred on this point.
local SUB_CENTRE_X, SUB_CENTRE_Y = 640, 625
local UI_W, UI_H = 1280, 720
local SUB_WINDOW, TALK_WINDOW = "subtitle", "talk"
local REMARK_WINDOW = "remark"
local MAX_ANSWERS = 8

local function u64(a) return mem.u64(a) or 0 end

-- A pointer that cannot be an address is not followed.
local function ok(a) return a and a >= 0x1000 and a < 0x8000000000 end

local function pointer_map(map, key)
    local size = mem.u32(map + PM_SIZE) or 0
    if key == 0 or size == 0 then return nil end
    key = key & (mem.u32(map + PM_MASK) or 0)
    local entries = u64(map + PM_ENTRIES)
    if not ok(entries) then return nil end
    local entry = entries + (key % size) * 16
    if mem.u32(entry + 8) ~= key then return nil end
    local p = u64(entry)
    return ok(p) and p or nil
end

local function ui_object(id) return pointer_map(base + OBJECT_MAP, id) end

local function attached(slot)
    local manager = u64(base + MENU_MANAGER)
    if not ok(manager) then return nil end
    return ui_object(mem.u32(manager + M_ATTACHED + 4 * slot) or 0)
end

local function children(layout)
    local out = {}
    local list = u64(layout + L_CHILDREN)
    if not ok(list) then return out end
    local stop = list - 8
    local link = u64(list + 8)
    while ok(link) and link - 0x10 ~= stop and #out < 64 do
        out[#out + 1] = link - 0x10
        link = u64(link - 0x10 + C_NEXT)
    end
    return out
end

local function shown(object) return mem.u8(object + O_DISP) == 1 end

-- A message of a BDAT table: the table has a column "name", a string's offset from its start.
local function table_message(file, id)
    if not ok(file) then return nil end
    if mem.read(file, 4) ~= "BDAT" then return nil end
    local names_at = mem.u16(file + 0x20)
    local columns = mem.u16(file + 0x22) or 0
    local item_size, items = mem.u16(file + 0x8), mem.u16(file + 0xe)
    local count, first = mem.u16(file + 0x10), mem.u16(file + 0x12)
    if not (names_at and item_size and items and count and first) then return nil end
    if id < first or id >= first + count then return nil end
    for i = 0, columns - 1 do
        local column = file + names_at + i * 6
        local info, name = mem.u16(column), mem.u16(column + 4)
        if info and name and mem.cstr(file + name, 8) == "name" then
            local offset = mem.u16(file + info + 2)
            local at = offset and mem.u32(file + items + (id - first) * item_size + offset)
            return at and mem.cstr(file + at, 4096)
        end
    end
    return nil
end

local function ui_string(at)
    local kind = mem.u16(at + S_KIND)
    if kind == KIND_MESSAGE then
        local manager = u64(base + TEXT_MANAGER)
        if not ok(manager) then return nil end
        local file = pointer_map(manager + TM_FILES, mem.u32(at) or 0)
        if not file then return nil end
        return table_message(u64(file + TF_TABLE), mem.u32(at + 4) or 0)
    elseif kind == KIND_POINTER or kind == KIND_OWNED then
        local p = u64(at)
        return ok(p) and mem.cstr(p, 4096) or nil
    end
    return nil
end

-- A line as the game writes it: tags in square brackets. [System:Ruby rt=よみ ]漢字[/System:Ruby]
-- is furigana, [ML:Dash ] a long dash; the others draw nothing that is text.
local function decode(raw)
    local b = reader.builder()
    local at = 1
    while at <= #raw do
        local open = raw:find("[", at, true)
        if not open then b:add(raw:sub(at)); break end
        if open > at then b:add(raw:sub(at, open - 1)) end
        local close = raw:find("]", open, true)
        if not close then b:add(raw:sub(open)); break end
        local tag = raw:sub(open + 1, close - 1)
        at = close + 1
        local reading = tag:match("^System:Ruby%s+rt=(.-)%s*$")
        if reading then
            local stop, after = raw:find("[/System:Ruby]", at, true)
            if stop then
                b:add_ruby(raw:sub(at, stop - 1), reading)
                at = after + 1
            end
        elseif tag:match("^ML:Dash") then
            b:add("――")
        end
    end
    return b
end

-- Half-width characters take half a cell of the game's proportional font.
local function cell_width(code)
    return code < 0x80 and 0.5 or 1
end

-- The cells of a text the game has laid out in a box, by its lines: each line is centred in
-- the box or starts at its left edge.
local function cells(textual, left, top, width, height, centred)
    local lines, longest = {}, 0
    for line in (textual .. "\n"):gmatch("(.-)\n") do
        local units = 0
        for _, code in utf8.codes(line) do units = units + cell_width(code) end
        lines[#lines + 1] = { text = line, units = units }
        longest = math.max(longest, units)
    end
    if longest == 0 or width == 0 or height == 0 then return nil end
    local advance = width / longest
    local pitch = height / #lines
    local glyphs = {}
    for row, line in ipairs(lines) do
        local x = left
        if centred then x = left + (width - line.units * advance) / 2 end
        for _, code in utf8.codes(line.text) do
            local w = cell_width(code) * advance
            glyphs[#glyphs + 1] = { x, top + (row - 1) * pitch, w, pitch }
            x = x + w
        end
        if row < #lines then glyphs[#glyphs + 1] = false end
    end
    return glyphs
end

local function size_of(object)
    return mem.u16(object + O_SIZE) or 0, mem.u16(object + O_SIZE + 2) or 0
end

local function s16(a)
    local v = mem.u16(a) or 0
    return v >= 0x8000 and v - 0x10000 or v
end

-- The first child of that name, at any depth.
local function find(layout, name, depth)
    depth = depth or 0
    if depth > 6 then return nil end
    for _, child in ipairs(children(layout)) do
        if mem.cstr(child + O_NAME, 32) == name then return child end
        if mem.u16(child + O_TYPE) == TYPE_LAYOUT then
            local below = find(child, name, depth + 1)
            if below then return below end
        end
    end
    return nil
end

-- Where a string is: what tells one line from the next, without reading it.
local function identity(text_object)
    local at = text_object + T_STRING
    return (mem.u16(at + S_KIND) or 0) .. ":" .. (mem.u32(at) or 0) .. ":" .. (mem.u32(at + 4) or 0)
end

-- A window the game shows one line at a time. A line counts once it has been up for a frame
-- after the one it was first seen in.
local windows = {}

local function window_of(name)
    local w = windows[name]
    if not w then w = {}; windows[name] = w end
    return w
end

local function clear(name)
    local w = window_of(name)
    if w.current then reader.layout(name, nil) end
    w.current, w.pending, w.place = nil, nil, nil
end

-- Reports what a window shows now. `place` is the frame's {left, top, width, height, box}, when
-- it has moved the cells are reported again.
local function show(name, key, read, place)
    local w = window_of(name)
    if key ~= w.current then
        if key ~= w.pending then
            if w.current then reader.layout(name, nil); w.current = nil end
            w.pending = key
            return
        end
        local raw, speaker = read()
        if not raw then return end
        local b = decode(raw)
        local textual = b:text()
        w.current, w.pending, w.textual, w.place = key, nil, textual, nil
        if textual:gsub("%s", "") == "" then w.textual = nil; return end
        reader.emit{ text = textual, ruby = b:ruby(), speaker = speaker, window = name,
                     id = text.hash((speaker or "") .. raw) }
    end
    if not w.textual then return end
    local where = table.concat(place, ",", 1, 4)
    if where == w.place then return end
    w.place = where
    local glyphs = cells(w.textual, place[1], place[2], place[3], place[4], place.centred)
    if glyphs then
        reader.layout(name, { space = { UI_W, UI_H }, box = place.box, glyphs = glyphs })
    end
end

local function subtitle()
    local root = attached(SLOT_SUBTITLE)
    if not root or not shown(root) then clear(SUB_WINDOW); return end
    local line
    for _, child in ipairs(children(root)) do
        local name = mem.cstr(child + O_NAME, 16)
        if name and name:match("^TXT_str") and shown(child) then line = child; break end
    end
    if not line then clear(SUB_WINDOW); return end
    local width, height = size_of(line)
    show(SUB_WINDOW, identity(line), function() return ui_string(line + T_STRING) end, {
        SUB_CENTRE_X - width / 2, SUB_CENTRE_Y - height / 2, width, height, centred = true })
end

-- The balloon's own copy of a layout: the game keeps the original hidden and shows duplicates.
local function live(root, name)
    for _, child in ipairs(children(root)) do
        if mem.cstr(child + O_NAME, 32) == name and shown(child) then return child end
    end
    return nil
end

-- Where a text of a balloon is: `main` has its corner on screen, the text its centre in `main`.
local function balloon_place(main, message)
    local x, y = s16(main + O_DRAW), s16(main + O_DRAW + 2)
    local width, height = size_of(message)
    local box_w, box_h = size_of(main)
    local cx, cy = s16(message + O_DRAW), s16(message + O_DRAW + 2)
    return { x + cx - width / 2, y + cy - height / 2, width, height, box = { x, y, box_w, box_h } }
end

local function talk()
    local root = attached(SLOT_TALK)
    local balloon = root and shown(root) and live(root, "LAY_ev_talk")
    local main = balloon and find(balloon, "LAY_ev_talk_main")
    local message = main and find(main, "TXT_ev_talk_msg")
    if not message or not shown(message) then clear(TALK_WINDOW); return end
    local name = find(main, "TXT_ev_talk_name")
    show(TALK_WINDOW, identity(message), function()
        return ui_string(message + T_STRING), name and ui_string(name + T_STRING) or nil
    end, balloon_place(main, message))
end

local function remark()
    local root = attached(SLOT_REMARK)
    local seen = {}
    if root and shown(root) then
        for _, balloon in ipairs(children(root)) do
            local main = shown(balloon) and mem.cstr(balloon + O_NAME, 32) == "LAY_auto_talk"
                and find(balloon, "LAY_auto_talk_main")
            local message = main and find(main, "TXT_auto_talk_msg")
            if message and shown(message) then
                local name = REMARK_WINDOW .. ("%x"):format(balloon)
                seen[name] = true
                show(name, identity(message), function() return ui_string(message + T_STRING) end,
                     balloon_place(main, message))
            end
        end
    end
    for name in pairs(windows) do
        if name:sub(1, #REMARK_WINDOW) == REMARK_WINDOW and not seen[name] then
            clear(name)
            windows[name] = nil
        end
    end
end

-- A choice: its answers, each a text in a row of its own that is shown or not. Two kinds of
-- box do this, by these names: the one over a character in a scene, and the one across the
-- screen in the field.
local CHOICES = {
    { slot = SLOT_SELECT, box = "LAY_ev_select", row = "LAY_ev_select_msg", answer = "TXT_ev_select_msg",
      question = "TXT_ev_select_msg_title", speaker = "TXT_ev_select_name" },
    { slot = SLOT_FIELD_SELECT, row = "LAY_sel_item", answer = "TXT_sel_item",
      question = "TXT_sel_title" },
}

local function choice(kind)
    local root = attached(kind.slot)
    local box = root and shown(root) and root
    if box and kind.box then box = live(root, kind.box) end
    if not box then kind.asked = nil; return end
    local answers, key = {}, {}
    for i = 1, MAX_ANSWERS do
        local suffix = ("@%02d"):format(i)
        local row = find(box, kind.row .. suffix)
        local answer = row and shown(row) and find(box, kind.answer .. suffix)
        local raw = answer and ui_string(answer + T_STRING)
        if raw then
            answers[#answers + 1] = decode(raw):text()
            key[#key + 1] = identity(answer)
        end
    end
    if #answers == 0 then kind.asked = nil; return end
    key = table.concat(key, "|")
    if key == kind.asked then return end
    kind.asked = key
    local title = find(box, kind.question)
    local name = kind.speaker and find(box, kind.speaker)
    local question = title and ui_string(title + T_STRING)
    local speaker = name and ui_string(name + T_STRING) or nil
    if question then
        local b = decode(question)
        if b:text():gsub("%s", "") ~= "" then
            reader.emit{ text = b:text(), ruby = b:ruby(), speaker = speaker, id = text.hash(question) }
        end
    end
    reader.emit{ text = table.concat(answers, "\n"), channel = "choice", id = text.hash(key) }
end

reader.on_frame(function()
    subtitle()
    talk()
    remark()
    for _, kind in ipairs(CHOICES) do choice(kind) end
end)
