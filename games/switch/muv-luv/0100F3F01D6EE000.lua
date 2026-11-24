-- reader: no hooks
-- reader: title マブラヴ (Muv-Luv Remastered)
-- reader: reads Dialogue, narration, speakers, and choices
-- reader: version Base game, version 1.0.0
-- reader: touch game
-- マブラヴ (Muv-Luv Remastered), Switch.
-- Written for main build D2F7354C24BC78F0431DF69CC06C9A26ED6BDCD9 (base game, version 1.0.0).
--
-- The game runs on a framework of its maker's ("smash", with the GUI library "fz::gui") whose
-- functions and globals still have their names in the program; the game's own classes do not.
-- The GUI library keeps a list of the screens that are loaded ("menus"), each driven by an
-- object of the game's with a name. The one called "adv_msg_wnd" is the message window. It
-- cuts what it shows into short pieces, each a text node of the GUI library with a place on
-- screen, and keeps them in order, with an empty one wherever the game waits for a button.
-- Beside them it keeps the page as the script gave it, cut the same way, which also has the
-- forced line breaks and the furigana. This profile reads those lists once a frame: nothing
-- is hooked, so the game runs natively (first line of this file).
--
-- A message is read once it has stood as the newest on screen for a moment: what the game's
-- fast-forward runs through is not read, and a page found as it is (the profile loaded in the
-- middle of the story, a save loaded) is read from its first message.
--
-- Covered: narration and dialogue (the window at the bottom, the full-screen pages, the
-- window with several speakers one below another), the speakers' names, furigana, the
-- answers of a choice. Not covered: the game's own log and menus, films.

local BUILD = "D2F7354C24BC78F0431DF69CC06C9A26ED6BDCD9"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The engine (offsets into main, and into its objects).
local VIEW_SYSTEM = 0x26136e8 -- smash::fw::view::System::_instance
local SYS_FIRST, SYS_COUNT = 0x48, 0x50 -- its list of services: first node, how many
local LIST_NEXT, LIST_VALUE = 0x08, 0x10
local SERVICE_GUI = 0x70      -- smash::fw::view::Service: its fz::gui::GuiManager
local GUI_MENUS = 0x460       -- fz::gui::GuiManager: vector of GuiMenu*
local GUI_SCREEN = 0x8ac      -- its screen's width and height (ints): where its nodes are
local MENU_BEHAVIOR = 0xb8    -- fz::gui::GuiMenu: the object that drives it
local BEHAVIOR_NAME = 0x70    -- its name (characters in place)
local BEHAVIOR_COVERED = 0xb0 -- 1 while another screen has the buttons (the log, the menu)
-- fz::gui::elem::node: every node begins the same way. A component (CustomComponentNode,
-- ButtonComponentNode) is kept by a pointer 0x18 into it.
local COMPONENT = 0x18
local N_SCALE_X, N_SCALE_Y = 0x20, 0x34 -- of its matrix on the GUI's screen
local N_POS = 0x50            -- x, y of the same
local N_NAME = 0x68
local N_PARENT, N_CHILD, N_NEXT = 0x88, 0x90, 0xa0
local N_SIZE = 0xe0           -- width, height before scaling
local N_ALPHA = 0x118
local N_SHOWN = 0x127         -- 1 when it is to be drawn
local N_HEAD = 0x128          -- how much of a node is read
-- fz::gui::elem::node::TextNode
local T_TEXT = 0x150          -- std::string
local T_SPRITE = 0x168        -- its fz::gui::GuiFontSprite
local T_ALIGN = 0x1b0         -- where the text is in the node: 0 top left, 4 the middle, …
-- fz::gui::GuiFontSprite: the glyphs of a text, drawn into one texture.
local S_RECTS = 0x18          -- vector of 24 bytes a glyph: x, y, width, height in the texture
local S_SCALE = 0x174         -- x and y: texture to node
local S_EXTENT = 0x18c        -- width of the text in the texture; its height 4 further

-- The game's message window ("adv_msg_wnd") and its control bar ("control1").
local WINDOW, CONTROL = "adv_msg_wnd", "control1"
local CONTROL_OPEN = 0x280    -- float: 1 while the bar is over the window
local W_LAYOUTS = 0xe8        -- vector of layouts, 0x218 bytes each: one a way of showing text
local W_PARSED = 0x118        -- pointer to a pointer to the page as the script gave it
local P_PIECES = 0x98         -- its vector of pieces, 0x68 bytes each
local PIECE_SIZE = 0x68
local PIECE_BASE, PIECE_READING, PIECE_TEXT = 0x00, 0x18, 0x30 -- std::string each
local LAYOUT_SIZE = 0x218
-- A layout shows text in one of two ways, each with a vector of the pieces' nodes
-- (components) and one of their texts (std::string, 24 bytes each): with one name plate (a
-- component), or with a vector of plates, one for every speaker, each beside its lines.
local STREAMS = {
    { nodes = 0xc0, segments = 0x108, plate = 0xb8 },
    { nodes = 0x38, segments = 0x80, plates = 0x20 },
}
local L_BRANCH_ROOT = 0x150   -- what the answers of a choice hang on (a component)
local L_BUTTONS = 0x160       -- vector of the answers' buttons (components)

-- Frames a message must have stood unchanged before it is reported: when the page as the
-- script gave it says it is whole, when that cannot be told, and when it says more is to come.
-- Fast-forward shows a message for a frame or two, now and then for four.
local STEADY, STEADY_UNKNOWN, STEADY_GROWING = 6, 15, 45
local STEADY_CHOICE = 4 -- the answers of a choice: the game stops at them
local KEY_WAIT = "\\k"        -- the piece that stands for a wait for a button

local function pointer(a)
    local p = a and mem.u64(a)
    return p and p > 0x10000 and p < 0x8000000000 and p or nil
end

-- ---------------------------------------------------------------------------------------
-- Finding the game's screens
-- ---------------------------------------------------------------------------------------

local function find_screens()
    local found = {}
    local system = pointer(base + VIEW_SYSTEM)
    if not system then return found end
    local count, node = mem.u64(system + SYS_COUNT), pointer(system + SYS_FIRST)
    for _ = 1, math.min(count or 0, 8) do
        if not node then break end
        local service = pointer(node + LIST_VALUE)
        local gui = service and pointer(service + SERVICE_GUI)
        local first, last = gui and pointer(gui + GUI_MENUS), gui and pointer(gui + GUI_MENUS + 8)
        if first and last and last > first and last - first <= 8 * 256 then
            local raw = mem.read(first, last - first)
            for i = 0, #raw // 8 - 1 do
                local menu = string.unpack("<I8", raw, 8 * i + 1)
                local behavior = menu > 0x10000 and pointer(menu + MENU_BEHAVIOR)
                local name = behavior and mem.cstr(behavior + BEHAVIOR_NAME, 16)
                if name == WINDOW or name == CONTROL then
                    found[name] = behavior
                    found.gui = gui
                end
            end
        end
        node = pointer(node + LIST_NEXT)
    end
    return found
end

-- ---------------------------------------------------------------------------------------
-- Strings and nodes
-- ---------------------------------------------------------------------------------------

-- A std::string (libc++) out of bytes that hold it at an offset: a short text is in the
-- object itself, a long one behind a pointer.
local function string_in(raw, at)
    local head = raw:byte(at + 1)
    if not head then return "" end
    if head & 1 == 0 then return raw:sub(at + 2, at + 1 + (head >> 1)) end
    local size, data = string.unpack("<I8I8", raw, at + 9)
    return size > 0 and size <= 1024 and mem.read(data, size) or ""
end

-- The texts of a vector of std::string and how many are in use (up to the last one that is
-- not empty). They are taken apart again only when the vector has changed; a long text may
-- have been written over in place, so those in use are read every time.
local function strings(state, first, last)
    local raw = mem.read(first, last - first)
    if raw ~= state.raw then
        local all, used = {}, 0
        for i = 0, #raw // 24 - 1 do
            local text = string_in(raw, 24 * i)
            all[i + 1] = text
            if text ~= "" then used = i + 1 end
        end
        state.raw, state.all, state.used = raw, all, used
    else
        for i = 1, state.used do
            if raw:byte(24 * i - 23) & 1 == 1 then state.all[i] = string_in(raw, 24 * (i - 1)) end
        end
    end
    return state.all, state.used
end

-- A node: where it is and whether it is drawn, or nil.
local function node_at(a)
    local raw = mem.read(a, N_HEAD)
    if #raw < N_HEAD then return nil end
    local x, y = string.unpack("<ff", raw, N_POS + 1)
    local w, h = string.unpack("<ff", raw, N_SIZE + 1)
    return {
        at = a, x = x, y = y, w = w, h = h,
        sx = string.unpack("<f", raw, N_SCALE_X + 1), sy = string.unpack("<f", raw, N_SCALE_Y + 1),
        shown = raw:byte(N_SHOWN + 1) == 1 and string.unpack("<f", raw, N_ALPHA + 1) > 0,
        parent = string.unpack("<I8", raw, N_PARENT + 1),
        child = string.unpack("<I8", raw, N_CHILD + 1),
        next = string.unpack("<I8", raw, N_NEXT + 1),
        name = raw:match("^[^\0]*", N_NAME + 1),
    }
end

-- Whether a node and everything it hangs on is drawn. What was found out about a node this
-- frame is kept: the texts of a page hang on the same few nodes.
local seen = {}
local function visible(node, depth)
    if not node or not node.shown then return false end
    if node.parent < 0x10000 then return true end
    local known = seen[node.parent]
    if known == nil then
        known = (depth or 0) < 16 and visible(node_at(node.parent), (depth or 0) + 1)
        seen[node.parent] = known
    end
    return known
end

local function child_named(node, name)
    local a = node.child
    for _ = 1, 16 do
        if a < 0x10000 then return nil end
        local child = node_at(a)
        if not child then return nil end
        if child.name == name then return child end
        a = child.next
    end
    return nil
end

-- Where the characters of a text node are: one {left, top, width, height} per character
-- from the one after `skip` on, on the GUI's screen, or nil while that cannot be told. A
-- glyph's place in its sprite's texture is where its ink is; the cells are widened to meet
-- halfway between neighbours and are as high as the node.
local function cells_of(node, count, skip)
    local sprite = pointer(node.at + T_SPRITE)
    if not sprite then return nil end
    local first, last = pointer(sprite + S_RECTS), pointer(sprite + S_RECTS + 8)
    local kx = mem.f32(sprite + S_SCALE)
    local total = count + skip
    if not first or not last or last - first ~= 24 * total or not kx or kx <= 0 then return nil end
    local rects = mem.read(first, 24 * total)
    if #rects < 24 * total then return nil end
    -- Text that is not at the left of its node starts further in.
    local align = mem.u32(node.at + T_ALIGN) or 0
    local start = 0
    if align % 3 ~= 0 then
        local extent = mem.u32(sprite + S_EXTENT) or 0
        start = (node.w - extent * kx) * (align % 3) / 2
    end
    local edges = {}
    for i = 0, total - 1 do
        local rx, _, rw = string.unpack("<fff", rects, 24 * i + 1)
        edges[i + 1] = { node.x + (start + rx * kx) * node.sx, node.x + (start + (rx + rw) * kx) * node.sx }
    end
    local out = {}
    for i = skip + 1, total do
        if edges[i][2] - edges[i][1] < 1 then
            out[i - skip] = false -- a space: nothing is drawn
        else
            local before, after = edges[i - 1], edges[i + 1]
            local left = before and before[2] > before[1] and (before[2] + edges[i][1]) / 2 or edges[i][1]
            local right = after and after[2] > after[1] and (edges[i][2] + after[1]) / 2 or edges[i][2]
            out[i - skip] = { left, node.y, right - left, node.h * node.sy }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------
-- The page as the script gave it
-- ---------------------------------------------------------------------------------------

-- The pieces that have a node, in order: {text, base, reading, breaks}, breaks being true
-- when the script forces a new line before the piece. nil when it cannot be read.
local function read_pieces(window)
    local holder = pointer(window + W_PARSED)
    local parsed = holder and pointer(holder)
    local first, last = parsed and pointer(parsed + P_PIECES), parsed and pointer(parsed + P_PIECES + 8)
    if not first or not last or last <= first or last - first > PIECE_SIZE * 512 or
        (last - first) % PIECE_SIZE ~= 0 then
        return nil
    end
    local raw = mem.read(first, last - first)
    local out, breaks = {}, false
    for i = 0, #raw // PIECE_SIZE - 1 do
        local at = PIECE_SIZE * i
        local text = string_in(raw, at + PIECE_TEXT)
        if text == "\n" then
            breaks = true
        else
            out[#out + 1] = {
                text = text, breaks = breaks,
                base = string_in(raw, at + PIECE_BASE), reading = string_in(raw, at + PIECE_READING),
            }
            breaks = false
        end
    end
    return out
end

-- What the page as the script gave it says of the message in segments from..to: "whole",
-- "growing" (more of it is to come) or nil (it is not that message's).
local function verdict(pieces, texts, from, to)
    if not pieces then return nil end
    local shown, script = {}, {}
    for i = from, to do shown[#shown + 1] = texts[i] end
    local i = from
    while pieces[i] and pieces[i].text ~= KEY_WAIT do
        script[#script + 1] = pieces[i].text
        i = i + 1
    end
    shown, script = table.concat(shown), table.concat(script)
    if shown == script then return "whole" end
    if script:sub(1, #shown) == shown then return "growing" end
    return nil
end

-- ---------------------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------------------

local window, control, gui
local space = { 1280, 720 } -- the GUI's screen: 1280x720 handheld, 1920x1080 docked
local layouts = {} -- by index, then by way of showing text: what was read of each
local serial = 0

local function close(unit)
    if unit.placed then
        reader.layout(unit.window, nil)
        unit.placed = nil
    end
end

local function reset(state)
    for _, unit in ipairs(state.units) do close(unit) end
    state.units, state.texts, state.done, state.changed = {}, {}, 0, nil
end

local function new_state()
    return { units = {}, texts = {}, done = 0, used = 0, fresh = true }
end

-- The name on a plate (a component) and how far down the screen the plate is, when it is
-- shown.
local function plate_name(component)
    local plate = component and component > 0x10000 and node_at(component - COMPONENT)
    if not plate or not visible(plate) then return nil end
    local label = child_named(plate, "text")
    local raw = label and mem.read(label.at + T_TEXT, 24)
    local name = raw and #raw == 24 and string_in(raw, 0) or ""
    if name == "" then return nil end
    return name, plate.y
end

-- Who says the message in segments from..to: a list of {from, to, name}. With several
-- plates a line is its speaker's whose plate is beside it or, when the line was wrapped,
-- above it.
local function speakers_of(stream, layout, nodes, from, to)
    if not stream.plates then
        return { { from, to, (plate_name(pointer(layout + stream.plate))) } }
    end
    local rows = {}
    local first, last = pointer(layout + stream.plates), pointer(layout + stream.plates + 8)
    if first and last and last > first and last - first <= 8 * 16 then
        local raw = mem.read(first, last - first)
        for i = 0, #raw // 8 - 1 do
            local name, y = plate_name(string.unpack("<I8", raw, 8 * i + 1))
            if name then rows[#rows + 1] = { y = y, name = name } end
        end
    end
    table.sort(rows, function(one, other) return one.y < other.y end)
    local raw = mem.read(nodes + 8 * (from - 1), 8 * (to - from + 1))
    local out = {}
    for i = from, to do
        local component = #raw >= 8 * (i - from + 1) and string.unpack("<I8", raw, 8 * (i - from) + 1) or 0
        local y = component > 0x10000 and mem.f32(component - COMPONENT + N_POS + 4)
        local name
        for _, row in ipairs(rows) do
            if y and row.y <= y + 8 then name = row.name end
        end
        local part = out[#out]
        if part and part[3] == name then
            part[2] = i
        else
            out[#out + 1] = { i, i, name }
        end
    end
    return out
end

-- Reports the message in segments from..to. With the page as the script gave it, when its
-- pieces are these segments: the forced line breaks and the furigana as well.
local function emit(state, texts, from, to, pieces, speaker)
    local exact = pieces ~= nil
    for i = from, to do
        if not pieces or not pieces[i] or pieces[i].text ~= texts[i] then exact = false break end
    end
    local unit = { first = from, last = to, counts = {}, breaks = {} }
    local b = reader.builder()
    for i = from, to do
        local piece = exact and pieces[i]
        if piece and piece.breaks and i > from then
            b:add("\n")
            unit.breaks[i] = true
        end
        -- A reading of nothing but dots is a mark of emphasis.
        if piece and piece.base ~= "" and piece.reading:gsub("\227\131\187", ""):find("%S") then
            local at = texts[i]:find(piece.base, 1, true)
            if at then
                b:add(texts[i]:sub(1, at - 1))
                b:add_ruby(piece.base, piece.reading)
                b:add(texts[i]:sub(at + #piece.base))
            else
                b:add(texts[i])
            end
        else
            b:add(texts[i])
        end
        unit.counts[i] = utf8.len(texts[i]) or 0
    end
    local line = b:text()
    if not line:gsub("\227\128\128", ""):find("%S") then return end -- nothing but spaces
    serial = serial % 99 + 1
    unit.window = "message." .. serial
    reader.emit{ text = line, speaker = speaker, ruby = b:ruby(), window = unit.window }
    state.units[#state.units + 1] = unit
end

-- Where a message that was reported is now, or that it cannot be seen.
local function place(unit, nodes, hidden)
    if hidden then
        unit.where = nil
        return close(unit)
    end
    local raw = mem.read(nodes + 8 * (unit.first - 1), 8 * (unit.last - unit.first + 1))
    if #raw < 8 * (unit.last - unit.first + 1) then return close(unit) end
    local function label_of(i)
        local component = string.unpack("<I8", raw, 8 * (i - unit.first) + 1)
        local node = component > 0x10000 and node_at(component - COMPONENT)
        local label = node and node.shown and node.child > 0x10000 and node_at(node.child)
        return label and label.shown and label or nil
    end
    local first = label_of(unit.first)
    if not (first and visible(first)) then
        unit.where = nil
        return close(unit)
    end
    -- Everything is looked at only when the first or the last piece has moved, or when
    -- not every piece could be placed the last time.
    local last = unit.last > unit.first and label_of(unit.last) or first
    local where = last and string.format("%.1f,%.1f %.1f,%.1f %.2f", first.x, first.y, last.x, last.y, first.sx)
    if where and where == unit.where then return end
    local glyphs, parts, any, all = {}, {}, false, true
    for i = unit.first, unit.last do
        local count = unit.counts[i]
        local label = i == unit.first and first or label_of(i)
        local cells = label and cells_of(label, count, 0)
        if count > 0 and not cells then all = false end
        if unit.breaks[i] then glyphs[#glyphs + 1] = false end
        local head, tail
        for k = 1, count do
            local cell = cells and cells[k] or false
            glyphs[#glyphs + 1] = cell
            if cell then
                head = head or cell
                tail = cell
            end
        end
        if head then
            any = true
            parts[#parts + 1] = string.format("%.1f,%.1f,%.1f", head[1], head[2], tail[1] + tail[3])
        else
            parts[#parts + 1] = "-"
        end
    end
    unit.where = all and where or nil
    if not any then return close(unit) end
    local placed = table.concat(parts, " ")
    if placed ~= unit.placed then
        reader.layout(unit.window, { space = space, glyphs = glyphs })
        unit.placed = placed
    end
end

local function update(state, stream, layout, frame, hidden)
    local first, last = pointer(layout + stream.segments), pointer(layout + stream.segments + 8)
    local nodes = pointer(layout + stream.nodes)
    if not first or not last or not nodes or last <= first or last - first > 24 * 1024 then
        if #state.units > 0 or state.done > 0 then reset(state) end
        return
    end
    local texts, used = strings(state, first, last)
    -- Another page when what was reported is no longer as it was.
    local same = used >= state.done
    for i = 1, same and state.done or 0 do
        if texts[i] ~= state.texts[i] then same = false break end
    end
    if not same then reset(state) end
    for i = state.done + 1, math.max(used, #state.texts) do
        if texts[i] ~= state.texts[i] then state.changed = frame break end
    end
    local now = {}
    for i = 1, used do now[i] = texts[i] end
    state.texts = now

    -- A message: the segments up to the next empty one. Of the last one the page as the script
    -- gave it tells whether it is whole. One with another after it was not read while it was
    -- the last: the game went past it at once (its fast-forward), unless the page was there
    -- already when this way of showing was first looked at.
    local pieces, unseen
    local from = state.done + 1
    while from <= used do
        while from <= used and now[from] == "" do from = from + 1 end
        if from > used then break end
        local to = from
        while to < used and now[to + 1] ~= "" do to = to + 1 end
        -- Text that is not drawn (left over in the way of showing that is not in use) is not
        -- a message.
        local component = pointer(nodes + 8 * (from - 1))
        local node = component and node_at(component - COMPONENT)
        local label = node and node.child > 0x10000 and node_at(node.child)
        if not (label and visible(label)) then
            unseen = true
            break
        end
        if pieces == nil then pieces = read_pieces(window) or false end
        if to < used then
            if state.fresh then emit(state, now, from, to, pieces or nil, nil) end
        else
            local steady = frame - (state.changed or frame)
            local what = steady >= STEADY and verdict(pieces or nil, now, from, to)
            if not (what == "whole" or steady >= STEADY_GROWING or
                    (what ~= "growing" and steady >= STEADY_UNKNOWN)) then
                break
            end
            for _, part in ipairs(speakers_of(stream, layout, nodes, from, to)) do
                emit(state, now, part[1], part[2], pieces or nil, part[3])
            end
        end
        state.done = to
        from = to + 1
    end

    if not unseen then state.fresh = false end
    for _, unit in ipairs(state.units) do place(unit, nodes, hidden) end
end

-- ---------------------------------------------------------------------------------------
-- The answers of a choice
-- ---------------------------------------------------------------------------------------

local choice -- what was read of the choice on screen

local function close_choice()
    if choice and choice.placed then reader.layout("choice", nil) end
    choice = nil
end

local function update_choice(layout, frame, hidden)
    local root = pointer(layout + L_BRANCH_ROOT)
    root = root and node_at(root - COMPONENT)
    local first, last = pointer(layout + L_BUTTONS), pointer(layout + L_BUTTONS + 8)
    if not root or not first or not last or last <= first or last - first > 8 * 16 or not visible(root) then
        return false
    end
    -- The buttons that are shown, with the texts on them: "1. " and so on, then the answer.
    local raw = mem.read(first, last - first)
    local labels, texts = {}, {}
    for i = 0, #raw // 8 - 1 do
        local button = node_at(string.unpack("<I8", raw, 8 * i + 1) - COMPONENT)
        local label = button and button.shown and child_named(button, "text")
        local text = label and mem.read(label.at + T_TEXT, 24)
        text = text and #text == 24 and string_in(text, 0) or ""
        if label and label.shown and text ~= "" then
            labels[#labels + 1] = label
            texts[#texts + 1] = text
        end
    end
    if #texts == 0 then return false end
    local key = table.concat(texts, "\n")
    if not choice or choice.key ~= key then
        if choice and choice.placed then reader.layout("choice", nil) end
        choice = { key = key, since = frame }
    end
    if not choice.emitted then
        if frame - choice.since < STEADY_CHOICE then return true end
        choice.skips, choice.counts = {}, {}
        local answers = {}
        for i, text in ipairs(texts) do
            local number = text:match("^%d+%. ") or ""
            answers[i] = text:sub(#number + 1)
            choice.skips[i], choice.counts[i] = #number, utf8.len(answers[i]) or 0
        end
        reader.emit{ text = table.concat(answers, "\n"), channel = "choice", window = "choice" }
        choice.emitted = true
    end
    local glyphs, parts = {}, {}
    for i, label in ipairs(labels) do
        local cells = not hidden and cells_of(label, choice.counts[i], choice.skips[i])
        if i > 1 then glyphs[#glyphs + 1] = false end
        for k = 1, choice.counts[i] do glyphs[#glyphs + 1] = cells and cells[k] or false end
        parts[i] = cells and cells[1] and string.format("%.1f,%.1f", cells[1][1], cells[1][2]) or "-"
    end
    local placed = table.concat(parts, " ")
    if not placed:find("%d") then
        if choice.placed then reader.layout("choice", nil) end
        choice.placed = nil
    elseif placed ~= choice.placed then
        reader.layout("choice", { space = space, glyphs = glyphs })
        choice.placed = placed
    end
    return true
end

-- ---------------------------------------------------------------------------------------

reader.on_frame(function(frame)
    if window and mem.cstr(window + BEHAVIOR_NAME, 16) ~= WINDOW then window = nil end
    if control and mem.cstr(control + BEHAVIOR_NAME, 16) ~= CONTROL then control = nil end
    if not window then
        for _, states in pairs(layouts) do
            for _, state in ipairs(states) do reset(state) end
        end
        layouts = {}
        close_choice()
        if frame % 30 ~= 0 then return end
        local found = find_screens()
        window, control, gui = found[WINDOW], found[CONTROL], found.gui
        if not window then return end
    end
    -- The size of the GUI's screen, which follows the picture's; a layout that was reported
    -- in another is reported again.
    local width, height = mem.s32(gui + GUI_SCREEN), mem.s32(gui + GUI_SCREEN + 4)
    if width and height and width > 0 and height > 0 and width <= 8192 and height <= 8192 and
        (width ~= space[1] or height ~= space[2]) then
        space = { width, height }
        for _, states in pairs(layouts) do
            for _, state in ipairs(states) do
                for _, unit in ipairs(state.units) do unit.where, unit.placed = nil, nil end
            end
        end
        if choice then choice.placed = nil end
    end
    local first, last = pointer(window + W_LAYOUTS), pointer(window + W_LAYOUTS + 8)
    if not first or not last or last < first or (last - first) % LAYOUT_SIZE ~= 0 then return end
    -- Under the game's log, its menu or its control bar the text is not to be tapped.
    seen = {}
    local hidden = mem.u8(window + BEHAVIOR_COVERED) == 1 or
        (control ~= nil and (mem.f32(control + CONTROL_OPEN) or 0) > 0)
    local asked = false
    for i = 0, math.min((last - first) // LAYOUT_SIZE, 4) - 1 do
        local states = layouts[i]
        if not states then
            states = {}
            for k = 1, #STREAMS do states[k] = new_state() end
            layouts[i] = states
        end
        for k, stream in ipairs(STREAMS) do
            update(states[k], stream, first + LAYOUT_SIZE * i, frame, hidden)
        end
        asked = update_choice(first + LAYOUT_SIZE * i, frame, hidden) or asked
    end
    if not asked then close_choice() end
end)

-- For the harness (lua muvluv_dump()): what the profile holds.
function muvluv_dump()
    print(string.format("window %x control %x", window or 0, control or 0))
    for i, states in pairs(layouts) do
        for k, state in ipairs(states) do
            local out = {}
            for n, s in ipairs(state.texts) do out[n] = s == "" and "|" or s end
            print(string.format("layout %d way %d: %d segments, %d read, %d units: %s", i, k,
                                #state.texts, state.done, #state.units, table.concat(out, " ")))
        end
    end
    if choice then print("choice: " .. choice.key:gsub("\n", " / ")) end
end
