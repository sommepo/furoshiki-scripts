-- reader: no hooks
-- reader: title DIGITAL DEVIL SAGA アバタール・チューナー
-- reader: reads Dialogue and narration
-- reader: version SLPM-65597
-- DIGITAL DEVIL SAGA アバタール・チューナー (Atlus, PS2, 2004), SLPM-65597. Program 44865CE1.
-- Same engine as 真・女神転生III (SLPM-65462.lua); only the addresses differ. Change both
-- together.
--
-- Text is in Atlus's message format (see SLPM-66978.lua): a character is two bytes numbering a
-- font cell. There are two fonts, large for dialogue and small for everything else, each in
-- its own order, so tables map cells to characters (reader.data("charset"), a
-- file SLPM-65597.charset beside it: UTF-8, the large font's characters from cell 0 onwards,
-- a line break after every 128, an empty line, then the small font's the same way).
--
-- All shown text is laid out as rows of characters in a pool of 513 places. A row has its
-- start (x in sixteenths of a 512-wide picture, y in eighths of a line of 448), width,
-- characters (code and step to the next), the next row of the same text and the first row;
-- a bit of its first word marks the large font.
-- Free places form a list from the pool's first place and keep their old rows, so only places
-- outside that list are read. The "scene cannot be skipped" notice is laid out for a whole
-- scene whether shown or not; it is filtered out by its text.
--
-- A message window's name is a separate text above the message; it becomes the speaker.

local BUILD = "44865CE1"
if reader.build_id ~= BUILD then
    error("this profile is for Digital Devil Saga SLPM-65597 (program " .. BUILD ..
          "), the game is " .. tostring(reader.build_id))
end

local charset = reader.data("charset")
if not charset then
    error("Digital Devil Saga needs its character table, SLPM-65597.charset, beside this profile: " ..
          "the game's text is numbers of cells in its fonts")
end
local FONTS = { {}, {} }
do
    local first, second = charset, ""
    local cut = charset:find("\n\r?\n")
    if cut then first, second = charset:sub(1, cut), charset:sub(cut + 1) end
    for index, part in ipairs({ first, second }) do
        local n = 0
        for ch in part:gmatch("[\1-\127\194-\244][\128-\191]*") do
            if ch ~= "\n" and ch ~= "\r" then
                FONTS[index][n] = ch
                n = n + 1
            end
        end
    end
end

-- The pool: its pointer, place count and place size. A place is its number, a link and the row.
local POOL_POINTER, PLACES, PLACE_SIZE, PLACE_LINK, PLACE_ROW = 0x003d70b0, 513, 0x4c, 0x04, 0x08
-- A row.
local R_FLAGS, LARGE_FONT = 0x00, 0x100
local R_X, R_Y, R_WIDTH, R_COUNT, R_FIRST, R_NEXT, R_HEAD = 0x04, 0x08, 0x0c, 0x18, 0x1c, 0x28, 0x2c
-- A character.
local C_CODE, C_ADVANCE, C_NEXT = 0x00, 0x0c, 0x28
local TOP, HEIGHT = 2, 24
local LINE, LINE_MAX = 28, 44
local ROWS_MAX, CHARS_MAX, TEXTS_MAX = 120, 300, 48
local NOTICE = "(このイベントはスキップできません)"
local NAME_MAX, NAME_ABOVE_MIN, NAME_ABOVE_MAX = 12, 16, 44
local TABLE_ROWS = 60
local SETTLED = 6    -- frames a text's rows must stay unchanged (some appear a character at a time)

local function valid(p)
    return p and p >= 0x00100000 and p < 0x02000000 and p % 4 == 0
end

local function character(code, cells)
    -- Characters of a player-given name have no code (drawn from their own picture): skipped.
    if code == 0xffff then
        return nil
    elseif code >= 0x8000 then
        return cells[((code >> 8) - 0x80) * 0x80 + (code & 0xff) - 0x80] or "?"
    elseif code >= 0x20 and code < 0x7f then
        return string.char(code)
    end
    return nil
end

-- The characters of a row: { { code, advance } }.
local function read_characters(first, count)
    local out, c = {}, first
    while valid(c) and #out < count and #out < CHARS_MAX do
        local node = mem.read(c, 0x30)
        if not node or #node < 0x30 then return nil end
        out[#out + 1] = { code = string.unpack("<I2", node, C_CODE + 1),
                          advance = string.unpack("<i4", node, C_ADVANCE + 1) }
        c = string.unpack("<I4", node, C_NEXT + 1)
    end
    return out
end

-- Text and cells of a text's rows. Consecutive rows form one text; indents are dropped.
local function compose(rows)
    local b, cells = reader.builder(), {}
    for index, row in ipairs(rows) do
        -- Rows of one list that are not consecutive on screen are separate items (a place name
        -- and a button hint): one line each. Rows can also stand side by side (menu help has
        -- a row per character).
        local gap = index > 1 and row.y - rows[index - 1].y or LINE
        if gap < -4 or gap > LINE_MAX then
            b:add("\n")
            cells[#cells + 1] = false
        end
        -- The row's width includes what the game adds to every character's step.
        local sum = 0
        for _, c in ipairs(row.chars) do sum = sum + c.advance end
        local wider = (#row.chars > 0 and row.width > 0) and (row.width - sum) / #row.chars or 0
        if wider < -8 or wider > 8 then wider = 0 end
        local x, leading = row.x, true
        for _, c in ipairs(row.chars) do
            local step = c.advance + wider
            local ch = character(c.code, row.cells)
            local skip = ch == nil
            if leading then
                if ch == "　" or ch == " " then skip = true else leading = false end
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

local cache = {}     -- per first-row place: what was read, while its rows are unchanged
local texts = {}     -- on-screen texts by content and position: { read, age, shown, up, number }
local numbers = {}   -- the numbers in use for the texts' names
local last_live = {} -- when a text of these characters was last on the screen
local serial = 0

local function drop(t)
    if t.up then
        reader.layout("text" .. t.number, nil)
        t.up = false
    end
end

reader.on_state_loaded(function()
    for _, t in pairs(texts) do drop(t) end
    cache, texts, numbers, last_live = {}, {}, {}, {}
end)

-- A text is read only if it has kana or kanji.
local function japanese(s)
    return s:find("[\227-\233][\128-\191][\128-\191]") ~= nil
end

-- What is read of the text whose first row is at `at` of the pool's bytes.
local function read_text(raw, pool, at)
    local address = pool + at
    local ats, marks, r = {}, {}, at
    while r and #ats < ROWS_MAX do
        ats[#ats + 1] = r
        marks[#marks + 1] = raw:sub(r + 1, r + R_HEAD)
        -- Follow the next row while it belongs to this text and its place is in use.
        local next_row = string.unpack("<I4", raw, r + R_NEXT + 1)
        r = nil
        if valid(next_row) then
            local n = next_row - pool
            if n >= PLACE_ROW and n + R_HEAD + 4 <= #raw and
               string.unpack("<I4", raw, n + R_HEAD + 1) == address and
               string.unpack("<I4", raw, n - PLACE_ROW + PLACE_LINK + 1) == 0 then
                r = n
            end
        end
    end
    local mark = table.concat(marks)
    local read = cache[at]
    if read and read.mark == mark then return read end
    read = { mark = mark }
    cache[at] = read
    local rows, codes = {}, {}
    for _, ra in ipairs(ats) do
        local flags, x, y, width = string.unpack("<I4i4i4i4", raw, ra + R_FLAGS + 1)
        local count, first_char = string.unpack("<I4I4", raw, ra + R_COUNT + 1)
        local chars = count <= CHARS_MAX and read_characters(first_char, count) or nil
        if not chars or #chars ~= count then return read end
        rows[#rows + 1] = { x = x / 16, y = y / 8, width = width, chars = chars,
                            cells = (flags & LARGE_FONT) ~= 0 and FONTS[1] or FONTS[2] }
        for _, c in ipairs(chars) do codes[#codes + 1] = string.pack("<I2", c.code) end
    end
    read.text, read.cells = compose(rows)
    read.x, read.y, read.rows, read.count = rows[1].x, rows[1].y, #rows, #rows[1].chars
    read.codes = table.concat(codes)
    read.key = read.codes .. string.format(":%d:%d:%d", rows[1].x, rows[1].y, #rows)
    return read
end

reader.on_frame(function()
    local frame = reader.frame()
    local pool = mem.u32(POOL_POINTER)
    if not valid(pool) then return end
    local raw = mem.read(pool, PLACES * PLACE_SIZE)
    if not raw or #raw < PLACES * PLACE_SIZE then return end
    -- Texts in use. Some are laid out twice, some anew in other places every frame, so a text
    -- is identified by its content and position, not by its pool place.
    local seen, live, found = {}, {}, 0
    for place = 1, PLACES - 1 do
        local at = place * PLACE_SIZE + PLACE_ROW
        local link = string.unpack("<I4", raw, at - PLACE_ROW + PLACE_LINK + 1)
        local first, head = string.unpack("<I4", raw, at + R_FIRST + 1), string.unpack("<I4", raw, at + R_HEAD + 1)
        if link == 0 and first ~= 0 and head == pool + at and found < TEXTS_MAX then
            found = found + 1
            live[at] = true
            local read = read_text(raw, pool, at)
            -- A character grid (name entry) is one text with very many rows: not read.
            if read.text and #read.text > 0 and read.text ~= NOTICE and read.rows <= TABLE_ROWS and japanese(read.text) then
                seen[read.key] = read
            end
        end
    end
    for at in pairs(cache) do
        if not live[at] then cache[at] = nil end
    end
    for key, t in pairs(texts) do
        if not seen[key] then
            drop(t)
            numbers[t.number] = nil
            texts[key] = nil
        end
    end
    for key, read in pairs(seen) do
        local t = texts[key]
        if not t then
            local number = 0
            while numbers[number] do number = number + 1 end
            numbers[number] = true
            t = { number = number, age = 0 }
            texts[key] = t
            -- The same text seen a moment ago elsewhere has moved (a sliding place name): not new.
            local before = last_live[read.codes]
            if before and frame - before <= 2 then t.shown, t.age = true, SETTLED end
        end
        t.read, t.age = read, t.age + 1
    end
    for _, t in pairs(texts) do last_live[t.read.codes] = frame end
    if frame % 600 == 0 then
        for codes, when in pairs(last_live) do
            if frame - when > 2 then last_live[codes] = nil end
        end
    end
    -- A message window's name: one short row just above the message's first, with no sentence-
    -- ending mark. It becomes the speaker and is not reported on its own.
    local function name_of(t)
        for _, other in pairs(texts) do
            local a, b = t.read, other.read
            if other ~= t and b.rows == 1 and b.count <= NAME_MAX and not b.text:find("[?!。…]") and
               a.y - b.y >= NAME_ABOVE_MIN and a.y - b.y <= NAME_ABOVE_MAX and b.x <= a.x then
                return other
            end
        end
    end
    local names = {}
    for _, t in pairs(texts) do
        if not t.shown and t.age >= SETTLED then
            local name = name_of(t)
            if name then
                names[t] = name
                name.shown = true
            end
        end
    end
    for key, t in pairs(texts) do
        if not t.up and t.age >= SETTLED then
            if not t.shown then
                t.shown = true
                serial = serial + 1
                reader.emit{ text = t.read.text, speaker = names[t] and names[t].read.text or nil,
                             window = "text" .. t.number, id = text.hash(key) .. ":" .. serial }
            end
            reader.layout("text" .. t.number, { space = { 512, 448 }, glyphs = t.read.cells })
            t.up = true
        end
    end
end)
