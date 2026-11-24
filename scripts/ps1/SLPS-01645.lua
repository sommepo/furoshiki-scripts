-- reader: title 弟切草 蘇生篇
-- reader: reads Story text and choices
-- reader: version SLPS-01645 (boot program 48F74C1B)
-- reader: no hooks
-- reader: audio never
-- reader: touch press
-- reader: buttons up down circle
--
-- Otogirisou: Sosei-hen (Chunsoft, 1999), the Japanese disc. Every glyph on the page is a
-- sprite of the game's own, kept in a table in memory with its place and its number in the
-- game's font: the profile reads that table once a frame. The font's numbers are the game's
-- own, so a table of them (SLPS-01645.charset: a line per glyph, its number, character, width
-- and how far below the line's top it is drawn) comes beside this file. That table is made
-- from the game's font and is not published; without it the profile says so and reads
-- nothing. The game's state says whether it waits for a press (a page or a paragraph is
-- complete), shows a choice (with the range of sprites of each answer), or shows an answer's
-- preview (the story as it would go: not counted). While a choice is up the profile says which
-- answer the game's cursor is on (reader.cursor), so that a tap on an answer picks it; each
-- answer is one line of the choice's text, its two lines on screen joined. The buttons line
-- above is a note of what picks an answer with the controller. See
-- docs/reader/games/otogirisou.md.

local BUILD = "48F74C1B"
if reader.build_id ~= BUILD then
    error("this profile is for the boot program " .. BUILD .. ", the disc has " .. tostring(reader.build_id))
end

local GP = 0x8007A610
local SPRITES = 0x80082458   -- the sprite table: 24 bytes each
local FIRST = 80             -- the text's sprites begin here
local COUNT = GP + 0x318     -- u32: how many text sprites there are
local MODE = GP + 0x31C      -- u32: 3 or 6 waiting for a press, 2 a choice, 99 an ending
local PREVIEW = GP + 0x320   -- u32: not 0 while an answer's preview is shown
local ANSWERS = GP + 0x324   -- u32: how many answers the choice has
local ANSWER_FIRST = 0x80085CE8 -- u32[]: each answer's first sprite
local ANSWER_END = 0x80085D18   -- u32[]: and the one after its last
local CURSOR = GP + 0x338    -- u32: the answer the game's cursor is on, from 0
local LINE = 22              -- a line's height in the picture

local glyphs = {}
local data = reader.data("charset")
if not data then
    error("SLPS-01645.charset is missing: this game's glyph table is not published (see the profile's notes)")
end
for line in data:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
        local id, ch, width, bearing = line:match("^(%d+)\t([^\t]+)\t(%d+)\t(%d+)$")
        if id then glyphs[tonumber(id)] = { ch, tonumber(width), tonumber(bearing) } end
    end
end

-- The page as the sprite table has it: {slot, id, ch, x, y, w, h}, in the order drawn.
local function read_page()
    local count = mem.u32(COUNT) or 0
    if count > 200 then return nil end
    local page = {}
    local raw = mem.read(SPRITES + FIRST * 24, count * 24) or ""
    for i = 0, count - 1 do
        local flags, x, y, id = string.unpack("<I2i2i2xxI2", raw, i * 24 + 5)
        id = id - 256
        local g = glyphs[id]
        if flags ~= 0 and id >= 0 and g then
            local w = g[2]
            page[#page + 1] = { slot = FIRST + i, id = id, ch = g[1],
                                x = (x // 16) - (w // 2), y = (y // 16) + g[3] - 8,
                                baseline = y // 16, w = w, h = 16 - g[3] }
        end
    end
    return page
end

local shown = {}       -- slot -> "id:x:y" of what was on the page
local fresh = {}       -- glyphs new since the last paragraph, in order
local windows = 0
local last_mode = nil
local choice_key = nil

local function withdraw_all()
    for n = 1, windows do reader.layout("page" .. n, nil) end
    windows = 0
    if choice_key then reader.layout("choice", nil) end
    choice_key = nil
    reader.cursor(nil)
end

-- Glyphs into text and cells: a new line where the baseline moves down and the line before
-- ended short of the right edge (not within an answer: a choice's lines are its answers).
local function piece(list, one_line)
    local chars, cells, prev = {}, {}, nil
    for _, g in ipairs(list) do
        if prev and not one_line and g.baseline > prev.baseline + 4 and prev.x + prev.w < 280 then
            chars[#chars + 1] = "\n"; cells[#cells + 1] = false
        end
        chars[#chars + 1] = g.ch
        cells[#cells + 1] = { g.x, g.baseline - 16, g.w, LINE }
        prev = g
    end
    return table.concat(chars), cells
end

local function emit_paragraph()
    if #fresh == 0 then return end
    local body, cells = piece(fresh)
    fresh = {}
    windows = windows + 1
    reader.emit{ text = body, window = "page" .. windows, id = text.hash(body) }
    reader.layout("page" .. windows, { space = { 320, 240 }, glyphs = cells })
end

local function emit_choice(page)
    local count = mem.u32(ANSWERS) or 0
    if count < 1 or count > 10 then return end
    local by_slot = {}
    for _, g in ipairs(page) do by_slot[g.slot] = g end
    local chars, cells = {}, {}
    for n = 0, count - 1 do
        local first, stop = mem.u32(ANSWER_FIRST + n * 4), mem.u32(ANSWER_END + n * 4)
        if not first or not stop or stop - first > 200 then return end
        local answer = {}
        for slot = first, stop - 1 do
            if by_slot[slot] then answer[#answer + 1] = by_slot[slot] end
        end
        local body, list = piece(answer, true)
        if n > 0 then chars[#chars + 1] = "\n"; cells[#cells + 1] = false end
        chars[#chars + 1] = body
        for _, c in ipairs(list) do cells[#cells + 1] = c end
    end
    local body = table.concat(chars)
    if body == choice_key or body:gsub("\n", "") == "" then return end
    choice_key = body
    reader.emit{ text = body, window = "choice", channel = "choice", id = "choice:" .. text.hash(body) }
    reader.layout("choice", { space = { 320, 240 }, glyphs = cells })
end

reader.on_frame(function()
    local page = read_page()
    if not page then return end
    local mode = mem.u32(MODE) or 0
    local preview = (mem.u32(PREVIEW) or 0) ~= 0
    -- An empty page: the game cleared it.
    if #page == 0 and next(shown) then
        withdraw_all()
        shown, fresh = {}, {}
    end
    -- What is new on the page since the last frame (a sprite that came or changed). An
    -- answer's preview is shown, never counted.
    local now = {}
    for _, g in ipairs(page) do
        local key = g.id .. ":" .. g.x .. ":" .. g.y
        now[g.slot] = key
        if shown[g.slot] ~= key and not preview and mode ~= 2 then fresh[#fresh + 1] = g end
    end
    shown = now
    if mode ~= last_mode then
        -- The game waits for a press, or an ending holds: the paragraph is complete.
        if (mode == 3 or mode == 6 or mode == 99) and not preview then emit_paragraph() end
        if mode == 2 then
            emit_paragraph()
            emit_choice(page)
        elseif choice_key then
            reader.layout("choice", nil)
            choice_key = nil
            reader.cursor(nil)
        end
        last_mode = mode
    end
    -- Where the game's cursor is, so that a tap on an answer can move it there.
    if choice_key then
        local at = mem.u32(CURSOR)
        reader.cursor(at and at < (mem.u32(ANSWERS) or 0) and at or -1)
    end
end)

reader.on_state_loaded(function()
    withdraw_all()
    shown, fresh, last_mode = {}, {}, nil
end)
