-- reader: title 大逆転裁判1&2 -成歩堂龍ノ介の冒險と覺悟- (The Great Ace Attorney Chronicles)
-- reader: reads Dialogue, testimony, choices, and court record
-- reader: version Base game, version 0
-- reader: touch game
-- reader: audio never
-- The Great Ace Attorney Chronicles (大逆転裁判1&2 -成歩堂龍ノ介の冒險と覺悟-), Switch.
-- Written for main build D871B992E95B71C541DDC834F63C664BE8A15786 (base game, v0).
--
-- The game lays a whole message out before showing it: a linked list of elements (characters
-- with their positions, line starts, ruby, colours, script commands, page ends) held by a
-- text object. Dialogue is typed out by a "player", a text object that walks its list; the
-- labels of a choice are plain text objects that are simply drawn. This profile reads both
-- from their lists: the text, its readings and where every character is drawn.

local BUILD = "D871B992E95B71C541DDC834F63C664BE8A15786"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- Code (offsets into main).
local PLAYER_MOVE = 0x53fb00   -- text player: per-frame step (x0 player), while its window is live
local TEXT_DRAW = 0x53d660     -- text object: drawn (x0 text object), every frame it is part of
                               -- the screen, seen or not
local REQUEST_NAME = 0x265190  -- name plate: change the speaker (x0 plate, w1 name number)
local SET_NAME = 0x264b90      -- name plate: put a name on it (x0 plate, w1 name number)

-- Text object, and the player that is one.
local P_MATRIX = 0x10   -- 4x4 floats: element space to the pixels of the game's picture
                        -- (1280x720 handheld, 1920x1080 docked); the identity until the
                        -- window has been placed
local P_LISTENER = 0x88 -- the window the text belongs to
local P_HEAD = 0xc8     -- first element of the message
local P_COLOUR = 0xe8   -- the colour it is drawn in; the top byte is the opacity
local P_STATE = 0x1d0   -- 0 idle, 1 typing, 2 waiting at a page end, ...
local P_PAGE = 0x1e0    -- where the current page began
local P_CURRENT = 0x1e8 -- the element to be handled next

-- Element types (low byte; bit 8 marks a closing tag).
local T_CHAR, T_PAGE_END, T_RUBY, T_RB, T_RT, T_LINE = 0x04, 0x0b, 0x0d, 0x0e, 0x0f, 0x16

-- Windows whose text is read, by the listener's class (vtable offset in main).
local WINDOWS = {
    [0xb9d6d0] = "talk", -- the first game's dialogue window
    [0xb68500] = "talk", -- the second game's
}

-- Windows whose texts are all there at once, drawn rather than typed: the answers to choose
-- from, the court record's page for an exhibit or a person, the pages of an exhibit that
-- can be looked at closely, and the card of an exhibit that is added to the record. `scene`: the window is part
-- of the scene the dialogue is in, and is covered when that is. `steady`: for how many frames
-- the texts must have been there before they are read (a page of the record that is only
-- passed on the way to another is not read).
local LISTS = {
    [0xb9eca0] = { name = "choice", channel = "choice", scene = true, steady = 3 },
    [0xb8f830] = { name = "record", channel = "record", steady = 20 },
    [0xba1ad0] = { name = "document", channel = "record", steady = 20 },
    [0xb8fae0] = { name = "exhibit", channel = "record", scene = true, steady = 10 },
}

-- The dialogue window's frame: reached from a global, it says whether the window is open
-- and owns the name plate.
local MANAGER = 0xbd7c80 -- pointer to the pointer to the object that keeps the game's windows
local M_TALK = 0x1c8     -- its dialogue window frame
local F_OPEN = 0x358     -- float: 1 open, 0 closed, in between while it opens or closes
local F_PLATE = 0x378

-- Name plate. The second game has names of its own after the first 0x6a, in a second table.
local N_TABLE, N_TABLE2, N_SHOWN = 0x2f0, 0x2f8, 0x308
local N_SHARED = 0x6a
local G_COUNT, G_STRINGS = 0xe0, 0x100
local GAME = 0xbd7d90 -- pointer to the pointer to the object that knows which game is played
local GAME_NUMBER = 0x2c -- 1 or 2

local players = {}
local windows_used = {}
local lists = {}
local story = 0   -- counts the dialogue texts
local live = -1   -- the last frame the dialogue's text players were stepped: they are not
                  -- while a menu covers the scene
local wanted = {} -- name plate -> the number of the name last put on it or asked for

local function game_number()
    local holder = mem.u64(base + GAME)
    local object = holder and holder ~= 0 and mem.u64(holder)
    return object and object ~= 0 and mem.u32(object + GAME_NUMBER) or 0
end

local function name_of(plate, id)
    if not plate or not id or id < 0 then return "" end
    local table_at = N_TABLE
    if game_number() == 2 and id >= N_SHARED then
        table_at, id = N_TABLE2, id - N_SHARED
    end
    local gmd = mem.u64(plate + table_at)
    if not gmd or gmd == 0 or id >= (mem.u32(gmd + G_COUNT) or 0) then return "" end
    local strings = mem.u64(gmd + G_STRINGS)
    local pointer = strings and mem.u64(strings + id * 8)
    if not pointer or pointer == 0 then return "" end
    local name = mem.cstr(pointer, 96)
    -- A plate that is not shown has a blank name.
    if name:gsub("[ \227\128\128]", "") == "" then return "" end -- U+3000 is E3 80 80
    return name
end

local function talk_frame()
    local holder = mem.u64(base + MANAGER)
    local manager = holder and holder ~= 0 and mem.u64(holder)
    local frame = manager and manager ~= 0 and mem.u64(manager + M_TALK)
    return frame and frame ~= 0 and frame or nil
end

-- The speaker of the text in the dialogue window: the name its plate was last given or asked
-- to change to, which is ahead of the plate while the name is being changed.
local function speaker(frame)
    local plate = frame and mem.u64(frame + F_PLATE)
    if not plate or plate == 0 then return "" end
    return name_of(plate, wanted[plate] or mem.s32(plate + N_SHOWN))
end

local NODE = "<I8 f f I8 f f f f f f I4"

-- Reads the page that starts at `node` into the builder `b` and into `cells`: for every
-- character of the text, where it is in the text object's own units (false for a line break).
-- `current` is the element a player has come to, 0 for text that is not typed out. Returns
-- false while none of the page's text has been reached.
local function read_page(node, current, b, cells)
    local in_rt, reading, ruby_start, ruby_end = false, nil, nil, nil
    local reached = false
    local has_text = false
    for _ = 1, 4000 do
        if node == 0 then break end
        if node == current then reached = has_text end
        local data = mem.read(node, 0x38)
        if #data < 0x38 then break end
        local nxt, advance, height, glyph, x, y, _, _, bx, by, kind = string.unpack(NODE, data)
        local t = kind & 0xff
        if t == T_PAGE_END then
            if node == current or current == 0 then reached = has_text end
            break
        elseif t == T_LINE then
            if has_text then
                b:add("\n")
                cells[#cells + 1] = false
            end
        elseif t == T_RUBY or t == T_RB then
            -- One ruby element can hold several words, each with its reading after it.
            if kind & 0x100 == 0 then
                ruby_start, ruby_end = b:length(), nil
            elseif t == T_RB then
                ruby_end = b:length()
            end
        elseif t == T_RT then
            if kind & 0x100 == 0 then
                in_rt, reading = true, {}
            else
                in_rt = false
                local finish = ruby_end or b:length()
                if ruby_start and reading and #reading > 0 and finish > ruby_start then
                    b.spans[#b.spans + 1] = { ruby_start, finish - ruby_start, table.concat(reading) }
                end
                ruby_start, ruby_end, reading = nil, nil, nil
            end
        elseif t == T_CHAR and glyph ~= 0 then
            local code = mem.u32(glyph)
            if code and code >= 0x20 then
                local char = utf8.char(code)
                if in_rt then
                    reading[#reading + 1] = char
                else
                    has_text = true
                    b:add(char)
                    cells[#cells + 1] = { x - bx, y - by, advance, height }
                end
            end
        end
        node = nxt
    end
    if has_text and current == 0 then reached = true end
    return has_text and reached
end

-- The size of the picture the positions are in: the game draws its screen at the size it
-- hands over for display.
local function screen()
    local width, height = reader.picture()
    return { width or 1280, height or 720 }
end

-- The four numbers of a text object's transform that matter: scale and place. Nil while the
-- object has not been placed.
local function transform(object)
    local data = mem.read(object + P_MATRIX, 64)
    if #data < 64 then return nil end
    local sx, _, _, _, _, sy, _, _, _, _, _, _, tx, ty = string.unpack("<ffffffffffffff", data)
    if tx == 0 and ty == 0 then return nil end
    return sx, sy, tx, ty
end

local function page_start(player)
    local node = mem.u64(player + P_PAGE)
    if not node or node == 0 then return mem.u64(player + P_HEAD) or 0 end
    local kind = mem.u32(node + 0x30)
    if kind and (kind & 0xff) == T_PAGE_END then return mem.u64(node) or 0 end
    return node
end

-- A change of speaker goes through REQUEST_NAME when the window stays open and straight to
-- SET_NAME when it opens or a save is loaded: whichever was called last for a plate names the
-- speaker of the text that follows there. (There is more than one plate.)
local function on_name(cpu)
    wanted[cpu.x0] = cpu.w1
end
reader.hook(base + REQUEST_NAME, on_name)
reader.hook(base + SET_NAME, on_name)

-- Says where the page's text is, when the window is open and that has not been said for where
-- it is now. A window moves: it is placed a moment after its text is there, and it shakes.
local function place(state, player, open)
    local sx, sy, tx, ty = transform(player)
    if not sx then return end
    if state.sx ~= sx or state.sy ~= sy or state.tx ~= tx or state.ty ~= ty then
        state.sx, state.sy, state.tx, state.ty = sx, sy, tx, ty
        local glyphs = {}
        for i, cell in ipairs(state.cells) do
            glyphs[i] = cell and { cell[1] * sx + tx, cell[2] * sy + ty, cell[3] * sx, cell[4] * sy }
        end
        state.glyphs = glyphs
        -- The window's frame, as drawn around the text area: the lines sit 454 units either
        -- side of the centre and start 72 above it.
        state.box = { tx - 520 * sx, ty - 86 * sy, 1040 * sx, 180 * sy }
        state.shown = false
    end
    if open and not state.shown then
        -- A window's texts come from more than one player, by turns: what another one showed
        -- in this place is no longer there.
        for _, other in pairs(players) do
            if other ~= state and other.shown and other.tx == tx and other.ty == ty then
                reader.layout(other.window, nil)
                other.shown = false
            end
        end
        reader.layout(state.window, { space = screen(), box = state.box, glyphs = state.glyphs })
        state.shown = true
    end
end

reader.hook(base + PLAYER_MOVE, function(cpu)
    local player = cpu.x0
    local listener = mem.u64(player + P_LISTENER)
    if not listener or listener == 0 then return end
    local class = mem.u64(listener)
    local kind = class and WINDOWS[class - base]
    if not kind then return end
    local state = players[player]
    if not state then
        state = {}
        players[player] = state
    end
    state.seen = reader.frame()
    live = state.seen
    -- The text can be pointed at while its window is open and it is drawn: it is not under an
    -- exhibit that is looked at closely.
    local frame = talk_frame()
    local open = frame ~= nil and (mem.f32(frame + F_OPEN) or 0) > 0.5 and
        state.seen - (state.drawn or -100) <= 3
    if state.shown and not open then
        reader.layout(state.window, nil)
        state.shown = false
    end

    local start = page_start(player)
    if start == 0 then
        -- The player's text is gone.
        if state.shown then
            reader.layout(state.window, nil)
            state.shown = false
        end
        state.start, state.done = nil, false
        return
    end
    if state.start ~= start then
        state.start = start
        state.done = false
    end
    if not state.done then
        local b, cells = reader.builder(), {}
        if not read_page(start, mem.u64(player + P_CURRENT) or 0, b, cells) then return end
        state.done = true
        story = story + 1
        if not state.window then
            -- The window's name for the reader: the first text player of a kind has the plain
            -- name, a further one that shows text of its own a numbered one.
            local used = (windows_used[kind] or 0) + 1
            windows_used[kind] = used
            state.window = used == 1 and kind or kind .. used
        end
        state.cells = cells
        state.sx = nil -- placed anew
        reader.emit({
            text = b:text(),
            ruby = b:ruby(),
            speaker = speaker(frame),
            window = state.window,
        })
    end
    place(state, player, open)
end)

-- For finding out what else the game shows as text. In the harness, `lua census_on()` makes
-- every text object that is drawn, can be seen and is not read by this profile report itself
-- once per text, on the channel "census", with its window's class and where it is.
census = nil
function census_on()
    local told = {}
    census = function(object, class)
        if (mem.u32(object + P_COLOUR) or 0) >> 24 < 0x80 then return end
        local head = mem.u64(object + P_HEAD) or 0
        local sx, sy, tx, ty = transform(object)
        if head == 0 or not sx or told[object] == head then return end
        told[object] = head
        local start = head
        local kind = mem.u32(start + 0x30)
        if kind and (kind & 0xff) == T_PAGE_END then start = mem.u64(start) or 0 end
        local b, cells = reader.builder(), {}
        if not read_page(start, 0, b, cells) then return end
        local first
        for _, cell in ipairs(cells) do
            if cell then
                first = cell
                break
            end
        end
        reader.emit({ text = b:text(), channel = "census", meta = {
            class = string.format("%x", class), size = (first[4] * sy) // 1,
            x = (first[1] * sx + tx) // 1, y = (first[2] * sy + ty) // 1,
        } })
    end
end

-- The labels of a list are drawn, not typed: which of them are on screen is known from their
-- being drawn. The dialogue's text is not drawn while something covers its window.
reader.hook(base + TEXT_DRAW, function(cpu)
    local object = cpu.x0
    local listener = mem.u64(object + P_LISTENER)
    if not listener or listener == 0 then return end
    local class = mem.u64(listener)
    if class and WINDOWS[class - base] then
        local state = players[object]
        if state then state.drawn = reader.frame() end
        return
    end
    local kind = class and LISTS[class - base]
    if not kind then
        if census and class then census(object, class - base) end
        return
    end
    local list = lists[kind]
    if not list then
        list = { drawn = {}, steady = 0 }
        lists[kind] = list
    end
    list.drawn[object] = reader.frame()
end)

-- What a list shows now: its labels that are drawn and can be seen, from the top down.
local function labels_of(list, frame)
    local labels = {}
    for object, seen in pairs(list.drawn) do
        if frame - seen > 2 then
            list.drawn[object] = nil
        elseif (mem.u32(object + P_COLOUR) or 0) >> 24 >= 0x80 then
            local head = mem.u64(object + P_HEAD) or 0
            local sx, sy, tx, ty = transform(object)
            if head ~= 0 and sx then
                labels[#labels + 1] = { object = object, head = head, sx = sx, sy = sy, tx = tx, ty = ty }
            end
        end
    end
    table.sort(labels, function(a, b)
        if a.ty ~= b.ty then return a.ty < b.ty end
        if a.tx ~= b.tx then return a.tx < b.tx end
        return a.object < b.object
    end)
    return labels
end

local function show_list(kind, list, frame)
    local labels = labels_of(list, frame)
    -- Under a menu the labels are drawn as before, and covered.
    if #labels == 0 or (kind.scene and frame - live > 3) then
        if list.shown then
            reader.layout(kind.name, nil)
            list.shown = false
        end
        list.steady = 0
        return
    end
    -- Labels that all belong to the text last read are that text still, or what is left of
    -- it: when an answer is picked the others go first.
    local parts, places, known = {}, {}, list.members ~= nil
    for i, label in ipairs(labels) do
        label.part = string.format("%x:%x", label.object, label.head)
        parts[i] = label.part
        places[i] = string.format("%s:%g,%g,%g,%g", label.part, label.sx, label.sy, label.tx, label.ty)
        if known and not list.members[label.part] then known = false end
    end
    if not known then
        -- Labels come one after another: the list is read once it has stopped changing.
        local key = table.concat(parts, " ")
        if key == list.coming then
            list.steady = list.steady + 1
        else
            list.coming, list.steady = key, 1
        end
        if list.steady < kind.steady then return end
        local b, cells, members = reader.builder(), {}, {}
        for _, label in ipairs(labels) do
            if b:length() > 0 then
                b:add("\n")
                cells[#cells + 1] = false
            end
            local start = label.head
            local kind_of = mem.u32(start + 0x30)
            if kind_of and (kind_of & 0xff) == T_PAGE_END then start = mem.u64(start) or 0 end
            local first = #cells + 1
            read_page(start, 0, b, cells)
            members[label.part] = { first, #cells }
        end
        list.cells, list.members = cells, members
        list.where = nil
        local text = b:text()
        -- The same labels again with nothing said in between are the same list, back from
        -- under a menu.
        if text ~= "" and (text ~= list.text or story ~= list.story) then
            reader.emit({ text = text, ruby = b:ruby(), channel = kind.channel, window = kind.name })
        end
        list.text, list.story = text, story
        list.shown = false
    end
    if list.text == "" then return end
    local where = table.concat(places, " ")
    if where ~= list.where or not list.shown then
        local glyphs = {}
        for n = 1, #list.cells do glyphs[n] = false end
        for _, label in ipairs(labels) do
            local range = list.members[label.part]
            for n = range[1], range[2] do
                local cell = list.cells[n]
                glyphs[n] = cell and { cell[1] * label.sx + label.tx, cell[2] * label.sy + label.ty,
                    cell[3] * label.sx, cell[4] * label.sy }
            end
        end
        reader.layout(kind.name, { space = screen(), glyphs = glyphs })
        list.where = where
        list.shown = true
    end
end

reader.on_frame(function(frame)
    -- A window that is covered by a menu, or gone, is no longer advanced: its text is not
    -- there to be pointed at.
    for _, state in pairs(players) do
        if state.shown and frame - state.seen > 3 then
            reader.layout(state.window, nil)
            state.shown = false
        end
    end
    for kind, list in pairs(lists) do
        show_list(kind, list, frame)
    end
end)
