-- reader: title メモリーズオフ
-- reader: reads Dialogue, narration, speakers, and choices
-- reader: version SLPS-02296 (boot program D5FB86B4)
-- reader: no hooks
-- reader: touch press
-- reader: buttons up down circle
--
-- Memories Off (KID, 1999), the Japanese disc. The script's text command lays a paragraph out
-- at once in a page of nine rows of Shift-JIS (57 bytes a row, 22 characters at most), with a
-- count of characters per row; the game reveals the rows a character at a time, and keeps how
-- many rows are out and a counter of the characters revealed. A paragraph that goes on (the
-- next text command adds to the page) is put in the rows below. The text window draws row r's
-- j-th character at (16 + 19j, 160 + 17r) of the 512-wide picture, 16 pixels square.
--
-- A choice's answers are laid out by the choice command as further rows of the same page,
-- one answer a row, from a first row on; while the choice is up they are drawn centred, one
-- under the other, the one the game's cursor is on bright. The profile reports them as a
-- choice and says which one the cursor is on (reader.cursor), so a tap on one picks it.
--
-- The game's font has 36 kanji of its own in Shift-JIS's Greek slots (0x839F...); a table of
-- them, read from the font, is SLPS-02296.charset (private: see the game's note); without it
-- those characters come out as 〓. See docs/reader/games/memoriesoff.md.

local BUILD = "D5FB86B4"
if reader.build_id ~= BUILD then
    error("this profile is for the boot program " .. BUILD .. ", the disc has " .. tostring(reader.build_id))
end

local ROWS_TEXT  = 0x800F6018 -- 9 rows of 57 bytes: the page's Shift-JIS
local ROW_BYTES  = 57
local ROW_COUNT  = 0x800F7220 -- u8[9]: characters in each row (0x63: an empty row)
local ROWS       = 0x80074E28 -- u8: rows laid out on the page
local ROWS_OUT   = 0x80074EF7 -- u8: rows revealed (the last one still being revealed)
local REVEALED   = 0x80074C64 -- u16: the reveal counter; 0 while no text is drawn
local MODE       = 0x80072530 -- u8: 3 while a choice is up
local FIRST      = 0x80074E4A -- s8: the row of a choice's first answer
local CURSOR     = 0x80074E30 -- s8: the answer the cursor is on (from 0)
local HEIGHT     = 0x80074E2D -- s8: what centres a choice's answers vertically
local NAME       = 0x800F3750 -- the speaker's name, Shift-JIS, zero-ended
local NAME_SHOWN = 0x8007253D -- u8: the name is drawn
local OVERLAID   = 0x80072505 -- u8: not 0 while the backlog (△) is shown in the window instead
local EMPTY_ROW  = 0x63

local X0, STEP, Y0, LINE, CELL = 16, 19, 160, 17, 16
-- Where the game draws and where the glyphs are seen differ vertically: the picture is the
-- console's 224 lines with the overscan cut (and bent by the CRT glass). Measured in the
-- pictures on Linux: the window's rows are seen 4 lines higher than drawn, a choice's
-- answers (in the upper half) 7.
local TEXT_SHIFT, CHOICE_SHIFT = -4, -7

-- The font's own kanji (Shift-JIS code -> character).
local own = {}
local table_text = reader.data("charset")
if table_text then
    for code, ch in table_text:gmatch("([0-9A-Fa-f]+)\t([^\n]+)") do
        own[tonumber(code, 16)] = ch
    end
else
    reader.warn("SLPS-02296.charset is missing: the font's 36 kanji of its own come out as 〓")
end

-- One row's characters, as a list of strings (one per character).
local function row_chars(r)
    local n = mem.u8(ROW_COUNT + r) or 0
    if n == 0 or n == EMPTY_ROW or n > 23 then return {} end
    local raw = mem.read(ROWS_TEXT + r * ROW_BYTES, n * 2)
    if not raw then return {} end
    local chars = {}
    for i = 1, #raw - 1, 2 do
        local hi, lo = raw:byte(i, i + 1)
        local code = hi * 256 + lo
        local ch
        if own[code] then
            ch = own[code]
        elseif hi == 0x83 and lo >= 0x9F and lo <= 0xD6 then
            ch = "〓" -- one of the font's own kanji, without the table
        else
            ch = text.sjis(raw:sub(i, i + 1))
        end
        chars[#chars + 1] = ch
    end
    return chars
end

local page = {}       -- the rows laid out, as their raw bytes (to see a new page)
local said = 0        -- rows reported as paragraphs
local windows = 0
local layouts = {}    -- what was reported for each window, to put back after the backlog
local hidden = false  -- the layouts are withdrawn while the backlog is shown
local choice_key = nil
local last_revealed = 0

local function withdraw_all()
    for n = 1, windows do reader.layout("page" .. n, nil) end
    windows = 0
    if choice_key then
        reader.layout("choice", nil)
        reader.cursor(nil)
    end
    choice_key = nil
    layouts = {}
end

local function layout(window, value)
    layouts[window] = value
    if not hidden then reader.layout(window, value) end
end

local function clear_page()
    withdraw_all()
    page, said = {}, 0
end

local function row_key(r)
    local n = mem.u8(ROW_COUNT + r) or 0
    return tostring(n) .. ":" .. (mem.read(ROWS_TEXT + r * ROW_BYTES, 44) or "")
end

-- Rows from..to (0-based) as a paragraph: a row that ends short of the window's width ends a
-- line of the text; a full one (the game wraps anywhere, padding a row it ends early for
-- punctuation with a space) goes on. Spaces at a row's start (the indent of a quotation's
-- next lines) and end are layout, no text.
local function emit_rows(from, to)
    local chars, cells = {}, {}
    for r = from, to do
        local list = row_chars(r)
        local first, last = 1, #list
        while first <= last and list[first] == "　" do first = first + 1 end
        while last >= first and list[last] == "　" do last = last - 1 end
        if #chars > 0 and last >= first and #row_chars(r - 1) < 20 then
            chars[#chars + 1] = "\n"; cells[#cells + 1] = false
        end
        for j = first, last do
            chars[#chars + 1] = list[j]
            cells[#cells + 1] = { X0 + STEP * (j - 1), Y0 + LINE * r + TEXT_SHIFT, CELL + 2, CELL + 1 }
        end
    end
    local body = table.concat(chars)
    if body == "" then return end
    windows = windows + 1
    local window = "page" .. windows
    local w, h = reader.picture()
    local event = { text = body, window = window, id = text.hash(body) }
    if (mem.u8(NAME_SHOWN) or 0) ~= 0 then
        local name = mem.cstr(NAME, 32)
        if name and name ~= "" then event.speaker = text.sjis(name) end
    end
    reader.emit(event)
    layout(window, { space = { w or 512, h or 224 }, glyphs = cells })
end

local function s8(a)
    local v = mem.u8(a) or 0
    return v >= 128 and v - 256 or v
end

local function emit_choice(first, rows)
    local height = s8(HEIGHT)
    local top = 0x60 - (height + 33) // 2 + CHOICE_SHIFT
    local chars, cells, lines = {}, {}, {}
    for r = first, rows - 1 do
        local list = row_chars(r)
        local n = mem.u8(ROW_COUNT + r) or 0
        if #lines > 0 then chars[#chars + 1] = "\n"; cells[#cells + 1] = false end
        local line = {}
        for j = 1, #list do
            if not (list[j] == "　" and (j == 1 or j == #list)) then
                chars[#chars + 1] = list[j]
                line[#line + 1] = list[j]
                cells[#cells + 1] = { 256 - 10 * n + 20 * (j - 1), top + 16 * (r - first), CELL + 4, CELL }
            end
        end
        lines[#lines + 1] = table.concat(line)
    end
    local body = table.concat(lines, "\n")
    if body == "" or body == choice_key then return end
    choice_key = body
    local w, h = reader.picture()
    reader.emit{ text = body, window = "choice", channel = "choice", id = "choice:" .. text.hash(body) }
    layout("choice", { space = { w or 512, h or 224 }, glyphs = cells })
end

reader.on_frame(function()
    -- The backlog is shown in the window: the page's places are withdrawn until it is gone.
    local overlaid = (mem.u8(OVERLAID) or 0) ~= 0
    if overlaid ~= hidden then
        hidden = overlaid
        for window, value in pairs(layouts) do reader.layout(window, (not hidden) and value or nil) end
        if choice_key and hidden then reader.cursor(nil) end
    end
    if hidden then return end
    local rows = mem.u8(ROWS) or 0
    local revealed = mem.u16(REVEALED) or 0
    -- No text drawn (the window is closed, a scene changes): nothing is on screen.
    if revealed == 0 or rows == 0 or rows > 9 then
        if windows > 0 or choice_key then clear_page() end
        page, said, last_revealed = {}, 0, 0
        return
    end
    -- A new page: the reveal began again, a row already seen changed, or there are fewer rows.
    local again = revealed < last_revealed
    last_revealed = revealed
    if again or rows < #page then
        clear_page()
    else
        for r = 0, #page - 1 do
            if page[r + 1] ~= row_key(r) then clear_page(); break end
        end
    end
    for r = #page, rows - 1 do page[r + 1] = row_key(r) end
    local choosing = (mem.u8(MODE) or 0) == 3
    local first = s8(FIRST)
    local text_rows = rows
    if choosing and first >= 0 and first < rows then text_rows = first end
    -- A paragraph, once all its rows are out.
    local out = mem.u8(ROWS_OUT) or 0
    if text_rows > said and (out >= rows or choosing) then
        emit_rows(said, text_rows - 1)
        said = text_rows
    end
    if choosing then
        emit_choice(first, rows)
        if choice_key then reader.cursor(s8(CURSOR)) end
    elseif choice_key then
        layout("choice", nil)
        reader.cursor(nil)
        choice_key = nil
    end
end)

reader.on_state_loaded(function()
    clear_page()
    last_revealed = 0
end)
