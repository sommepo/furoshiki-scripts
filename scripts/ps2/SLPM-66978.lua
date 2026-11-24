-- reader: no hooks
-- reader: title ペルソナ4
-- reader: reads Dialogue, narration, speakers, system messages, and choices
-- reader: version SLPM-66978
-- ペルソナ4 (Atlus, PS2, 2008), SLPM-66978. Program 4E63E63C.
--
-- Messages are Atlus message files (a character is one byte below 0x80, or two bytes from
-- 0x80 numbering a font cell; commands start at 0xf0). They are not parsed: each page is
-- read from the rows of characters the game lays out for drawing, with commands applied and
-- names filled in.
--
-- Font cells are in the game's own order, so a table maps cells to characters. It is made
-- from the game and not part of the script: reader.data("charset"), a file SLPM-66978.charset
-- beside it (UTF-8; the characters from cell 0x20 in font order, a line break every 128).

local BUILD = "4E63E63C"
if reader.build_id ~= BUILD then
    error("this profile is for Persona 4 SLPM-66978 (program " .. BUILD ..
          "), the game is " .. tostring(reader.build_id))
end

local charset = reader.data("charset")
if not charset then
    error("Persona 4 needs its character table, SLPM-66978.charset, beside this profile: " ..
          "the game's text is numbers of cells in its font")
end
local CELLS = {}
do
    local n = 0
    for ch in charset:gmatch("[\1-\127\194-\244][\128-\191]*") do
        if ch ~= "\n" and ch ~= "\r" then
            CELLS[n] = ch
            n = n + 1
        end
    end
end

-- The game's message windows: a table of 64 places, 32 bytes each, with a pointer to the
-- window that has the place (at +8) or nothing.
local PLACES, PLACES_COUNT, PLACE_SIZE, PLACE_WINDOW = 0x008900c0, 64, 0x20, 0x08
-- A message window.
local W_STATE = 0x00     -- a byte: 2 and 3 while a page is typed out, 4 when it waits for the
                         -- button; bit 0x20 while a choice is up
local W_OPEN = 0x01      -- a byte: bit 2 while the window's box is up with its text
local W_FILE = 0x04      -- the message file
local W_MESSAGE = 0x1c   -- the message's header in it
local W_ROW = 0x20       -- the last row of the page on the screen
local W_ANSWER = 0x40    -- a row of the choice's answers
local TYPING_A, TYPING_B, CHOICE_BIT, OPEN_BIT = 2, 3, 0x20, 0x02
-- A message's header: its name (24 bytes), how many pages (u16), the speaker's number (u16).
local M_SPEAKER = 0x1a
-- The message file: after the table of messages (8 bytes each, from 0x20) a pointer to the
-- speakers' names and their count.
local F_COUNT = 0x18
local F_TABLE = 0x20
-- A row: where it begins in the picture (x in sixteenths of a column, y in eighths of a
-- line of the 640 by 448 picture), its width, how many characters, its first character, and
-- the rows before and after it and the first one.
local R_X, R_Y, R_WIDTH, R_COUNT, R_FIRST, R_NEXT, R_HEAD = 0x04, 0x08, 0x0c, 0x18, 0x1c, 0x28, 0x2c
-- A character: its code (u16, the two bytes as one number), for how many ticks it has been
-- there (a byte that goes round), how far to the next one, the next character.
local C_CODE, C_AGE, C_ADVANCE, C_NEXT = 0x00, 0x02, 0x0c, 0x28
local TOP, HEIGHT = 7, 22     -- a row's characters stand this far below its y and are this high
local ROWS_MAX, CHARS_MAX = 12, 400
local SHOWN_TICKS = 8      -- a character's count stays 0 until it has come up

local function valid(p)
    return p and p >= 0x00100000 and p < 0x02000000 and p % 4 == 0
end

local function character(code)
    if code >= 0x8000 then
        local cell = ((code >> 8) - 0x80) * 0x80 + (code & 0xff) - 0x80
        return CELLS[cell] or "?"
    elseif code >= 0x20 and code < 0x7f then
        return string.char(code)
    end
    return nil
end

-- The rows that begin with `head`: { rows = { { x, y, width, chars = { {text, advance} } } },
-- key = the codes as a string, last_age }.
local function read_rows(row)
    if not valid(row) then return nil end
    local head = mem.u32(row + R_HEAD)
    if not valid(head) then return nil end
    local rows, all, codes, last_age = {}, {}, {}, 0
    local r, total = head, 0
    while valid(r) and #rows < ROWS_MAX do
        local raw = mem.read(r, 0x30)
        if not raw or #raw < 0x30 then return nil end
        local x, y, width = string.unpack("<i4i4i4", raw, R_X + 1)
        local count, first = string.unpack("<I4I4", raw, R_COUNT + 1)
        if count > CHARS_MAX then return nil end
        rows[#rows + 1] = { x = x / 16, y = y / 8, width = width, count = count, chars = {} }
        local c, k = first, 0
        while valid(c) and k < CHARS_MAX do
            local node = mem.read(c, 0x30)
            if not node or #node < 0x30 then return nil end
            local code, age = string.unpack("<I2B", node, C_CODE + 1)
            local advance, next_one = string.unpack("<i4", node, C_ADVANCE + 1), string.unpack("<I4", node, C_NEXT + 1)
            all[#all + 1] = { code = code, advance = advance }
            codes[#codes + 1] = string.pack("<I2", code)
            last_age = age
            c, k = next_one, k + 1
        end
        total = total + count
        r = string.unpack("<I4", raw, R_NEXT + 1)
    end
    -- A row's list and its count can disagree on where a character belongs (a space starting
    -- a row hangs on the previous row's list): the counts decide.
    if total == #all then
        local at = 0
        for _, one in ipairs(rows) do
            for k = 1, one.count do one.chars[k] = all[at + k] end
            at = at + one.count
        end
    else
        return nil
    end
    return { rows = rows, key = table.concat(codes), last_age = last_age, head = head, count = #all }
end

-- The speaker of the window's message, or nil.
local function speaker_of(window)
    local file, message = mem.u32(window + W_FILE), mem.u32(window + W_MESSAGE)
    if not valid(file) or not valid(message) then return nil end
    local number = mem.u16(message + M_SPEAKER)
    local count = mem.u32(file + F_COUNT)
    if not number or not count or count > 4096 then return nil end
    local names = mem.u32(file + F_TABLE + count * 8)
    local names_count = mem.u32(file + F_TABLE + count * 8 + 4)
    if not valid(names) or not names_count or number >= names_count then return nil end
    local name = mem.u32(names + number * 4)
    if not name or name < 0x00100000 or name >= 0x02000000 then return nil end
    local raw = mem.read(name, 64)
    if not raw then return nil end
    local out, at = {}, 1
    while at <= #raw do
        local b = raw:byte(at)
        if b == 0 then break end
        if b >= 0xf0 then
            at = at + math.max((b & 0x0f) * 2, 2)
        elseif b >= 0x80 and at < #raw then
            out[#out + 1] = character(b << 8 | raw:byte(at + 1)) or ""
            at = at + 2
        else
            out[#out + 1] = character(b) or ""
            at = at + 1
        end
    end
    local text_ = table.concat(out)
    return #text_ > 0 and text_ or nil
end

-- Text and cells of rows. A message's rows form one text; the narration mark and later rows'
-- indent are dropped. A choice's answers are one line each.
local function compose(page, lines)
    local b, cells = reader.builder(), {}
    for index, row in ipairs(page.rows) do
        if lines and index > 1 then
            b:add("\n")
            cells[#cells + 1] = false
        end
        -- The row's width includes what the game subtracts from every character's step.
        local sum = 0
        for _, c in ipairs(row.chars) do sum = sum + c.advance end
        local tighter = #row.chars > 0 and (sum - row.width) / #row.chars or 0
        local x, leading = row.x, true
        for _, c in ipairs(row.chars) do
            local step = c.advance - tighter
            local ch = character(c.code)
            local skip = ch == nil
            if leading and not lines then
                if ch == "　" or ch == " " or (index == 1 and ch == ">") then
                    skip = true
                else
                    leading = false
                end
            end
            if not skip then
                b:add(ch)
                cells[#cells + 1] = { x, row.y + TOP, step, HEIGHT }
            end
            x = x + step
        end
    end
    return b:text(), cells
end

local shown = {}     -- per window: what was reported of it
local layouts = {}   -- the layouts that are up

local function put(name, cells)
    reader.layout(name, { space = { 640, 448 }, glyphs = cells })
    layouts[name] = true
end

local function drop(name)
    if layouts[name] then
        reader.layout(name, nil)
        layouts[name] = nil
    end
end

local function window(slot, w)
    local state = shown[slot]
    if not valid(w) then
        if state then
            drop("message" .. slot)
            drop("choice" .. slot)
            shown[slot] = nil
        end
        return
    end
    if not state or state.window ~= w then
        drop("message" .. slot)
        drop("choice" .. slot)
        state = { window = w, fresh = true }
        shown[slot] = state
    end
    local flags = mem.u8(w + W_STATE) or 0
    local typing = flags == TYPING_A or flags == TYPING_B

    -- The page, read only while the window's box is up (the window holds its last page after
    -- the box closes and the next one before it opens). A page that advances by itself never
    -- waits for the button: it is complete once its last character has been up SHOWN_TICKS.
    local open = ((mem.u8(w + W_OPEN) or 0) & OPEN_BIT) ~= 0
    local page = open and read_rows(mem.u32(w + W_ROW)) or nil
    if flags == TYPING_B and page and page.last_age >= SHOWN_TICKS then typing = false end
    if typing then state.fresh = true end
    if not page or page.count == 0 then
        drop("message" .. slot)
        state.key, state.fresh = nil, true
    elseif page.key ~= state.key or state.fresh then
        if page.key ~= state.key then drop("message" .. slot) end
        if not typing and flags ~= 0 then
            local whole, cells = compose(page, false)
            if #whole > 0 then
                local message = mem.u32(w + W_MESSAGE) or 0
                state.number = (state.number or 0) + 1
                reader.emit{ text = whole, speaker = speaker_of(w), window = "message" .. slot,
                             id = text.hash(page.key) .. ":" .. string.format("%x", message) ..
                                  ":" .. state.number }
                put("message" .. slot, cells)
            end
            state.key, state.fresh = page.key, false
        end
    end

    -- A choice.
    local answers = open and (flags & CHOICE_BIT) ~= 0 and read_rows(mem.u32(w + W_ANSWER)) or nil
    if not answers or answers.count == 0 then
        drop("choice" .. slot)
        state.answers = nil
    elseif answers.key ~= state.answers then
        local whole, cells = compose(answers, true)
        state.answers = answers.key
        reader.emit{ text = whole, channel = "choice", window = "choice" .. slot,
                     id = "choice:" .. text.hash(answers.key) .. ":" .. reader.frame() }
        put("choice" .. slot, cells)
    end
end

-- After a loaded savestate, nothing shown before it counts.
reader.on_state_loaded(function()
    for place in pairs(shown) do
        drop("message" .. place)
        drop("choice" .. place)
    end
    shown = {}
end)

reader.on_frame(function()
    local places = mem.read(PLACES, PLACES_COUNT * PLACE_SIZE)
    if not places or #places < PLACES_COUNT * PLACE_SIZE then return end
    local live = {}
    for place = 0, PLACES_COUNT - 1 do
        local w = string.unpack("<I4", places, place * PLACE_SIZE + PLACE_WINDOW + 1)
        if valid(w) and (mem.u8(w + W_STATE) or 0) ~= 0 then
            window(place, w)
            live[place] = true
        end
    end
    for place in pairs(shown) do
        if not live[place] then window(place, nil) end
    end
end)
