-- reader: title ファイナルファンタジーIX
-- reader: reads Dialogue, speech bubbles, speakers, and choices
-- reader: version SCPS-45501 (boot program AA3684E8; disc 2 of 4)
-- reader: audio never
-- reader: touch press
-- reader: buttons up down circle
--
-- Final Fantasy IX (Square, 2000), the Japanese discs. Their boot files name them SLPS-02000
-- to 02003 (the name Furoshiki's core goes by); the app's game list (DuckStation's database)
-- names them SCPS-45500 to 45503. The four discs have the same boot program and the same text
-- routines, so the eight scripts are the same but for this header.
--
-- The game draws every window's text each time it draws the window, through one routine
-- (DrawWindowText(window, text)) that walks the window's bytes from where its page begins to
-- where the typing has come, and draws each glyph through a second routine, with the pen (its
-- place on the screen) in a register. The profile hooks both: it sees each glyph's code and
-- place as drawn, the player's own names (written out by the game from its tokens) included.
-- A window's page is complete when the game waits for a press (a flag in the window).
--
-- The text is in the game's own encoding: one byte for the 247 commonest characters (digits,
-- letters, kana, punctuation, a few kanji), two bytes (FA xx, FB xx) for the other glyphs of
-- the font that is always there, and FC xx for the glyphs of the place's own font, which the
-- game loads with each place's text (about 200 kanji). A table made from the game's fonts (not
-- published: SCPS-45501.charset) turns each into a character: one line for each of the 711
-- glyphs of the fixed font, one line for each of the places' fonts (found by a hash of the table
-- of their glyphs, which the game keeps in memory).
--
-- A first line that is a name (the next line opens with 「) is the speaker. While a choice is
-- up (a flag of the window's, and the game counts the answers and keeps the cursor) the window's
-- last lines are its answers, reported as a choice with the cursor (reader.cursor), so that a
-- tap on an answer picks it. See docs/reader/games/ff9.md.

local BUILD = "AA3684E8"
if reader.build_id ~= BUILD then
    error("this profile is for the boot program " .. BUILD .. ", the disc has " .. tostring(reader.build_id))
end

local DRAW_TEXT  = 0x8004CA40 -- DrawWindowText(window a0, text a1)
local DRAW_END   = 0x8004D3A0 -- its epilogue: every way out of it passes here
local DRAW_GLYPH = 0x80050F5C -- draws one byte: a0 the byte, t5 the pen (x | y << 16)
local CODES      = 0x8007B05C -- u16: the first two-byte code, u16: its glyph number
local DYN_CODE   = 0x8007B060 -- u16: the first code of the place's own font
local FIXED      = 0x8007B08C -- u32: the fixed font's glyph table (4 bytes a glyph)
local PLACE      = 0x8007B090 -- u32: the place's font's glyph table (its count 12 bytes before)
local CHOICE_AT  = 0x8007AE18 -- u32: the answer the cursor is on, from 0
local CHOICES    = 0x8007AE1C -- u32: how many answers the choice has (0: none)
local WINDOWS    = 0x8007AEAC -- the game's windows, 0x2C bytes each; +0x28 has 0x02 while it asks
local WINDOW_SIZE = 0x2C
local DEBUG = false
local LINE = 16               -- a line's height (the font is 13 high)

-- The character table.
local fixed, places = {}, {}
local data = reader.data("charset")
if not data then
    error("SCPS-45501.charset is missing: this game's character table is not published (see the profile's notes)")
end
for line in data:gmatch("[^\n]+") do
    local kind, key, value = line:match("^([SD])([%x]+)\t(.*)$")
    if kind == "S" then
        fixed[tonumber(key)] = value
    elseif kind == "D" then
        local list = {}
        for _, c in utf8.codes(value) do list[#list + 1] = utf8.char(c) end
        places[key] = list
    end
end

local place_ptr, place_list, place_warned = nil, nil, {}
local function place_font()
    local ptr = mem.u32(PLACE)
    if not ptr or ptr < 0x80000000 then return nil end
    local count = mem.u32(ptr - 4)
    if not count or count > 1024 then return nil end
    if ptr ~= place_ptr or not place_list or #place_list ~= count then
        place_ptr = ptr
        local key = text.hash(mem.read(ptr - 12, 12 + 4 * count) or "")
        place_list = places[key]
        if not place_list and not place_warned[key] then
            place_warned[key] = true
            reader.warn("no characters for the place's font " .. key .. " (" .. count .. " glyphs)")
        end
    end
    return place_list
end

local function char_of(code)
    local first = mem.u16(CODES) or 0xFA00
    local dyn = mem.u16(DYN_CODE) or 0xFC00
    if code >= dyn then
        local list = place_font()
        return list and list[code - dyn + 1] or "〓"
    elseif code >= first then
        return fixed[code - first + (mem.u16(CODES + 2) or 247)] or "〓"
    end
    return fixed[code] or "〓"
end

-- What the game draws this frame: one entry a window, with its glyphs.
local drawing = nil
local drawn = {}
local prefix = nil

reader.hook(DRAW_TEXT, function(cpu)
    local w = cpu.a0
    drawing = { win = w, id = (w - WINDOWS) // WINDOW_SIZE, txt = cpu.a1,
                stop = mem.u16(w + 0x20) or 0, start = mem.u16(w + 0x22) or 0,
                done = (mem.u8(w + 0x26) or 0) == 0xFF,
                asks = ((mem.u8(w + 0x28) or 0) & 0x02) ~= 0, glyphs = {} }
    prefix = nil
end)

-- Only a window drawn whole counts (a frame may end while the game is drawing one).
reader.hook(DRAW_END, function()
    if drawing then drawn[#drawn + 1] = drawing end
    drawing = nil
end)

reader.hook(DRAW_GLYPH, function(cpu)
    if not drawing then return end
    local b = cpu.a0 & 0xFF
    if b >= 0xFA and b <= 0xFD and not prefix then
        prefix = b
        return
    end
    local code = prefix and ((prefix << 8) | b) or b
    prefix = nil
    local pen = cpu.t5
    local g = drawing.glyphs
    g[#g + 1] = { code = code, x = pen & 0xFFFF, y = (pen >> 16) & 0xFFFF }
end)

-- The glyphs as lines: {text, cells, first character}.
local function lines_of(glyphs)
    local lines, cur, prev = {}, nil, nil
    for _, g in ipairs(glyphs) do
        if not cur or g.y > prev.y + LINE / 2 or g.y < prev.y - LINE / 2 then
            cur = { chars = {}, cells = {} }
            lines[#lines + 1] = cur
        elseif prev and cur.cells[#cur.cells] then
            -- The cell before reaches to this glyph.
            local c = cur.cells[#cur.cells]
            if g.x > c[1] then c[3] = math.min(g.x - c[1], 14) end
        end
        local ch = char_of(g.code)
        cur.chars[#cur.chars + 1] = ch
        cur.cells[#cur.cells + 1] = { g.x, g.y - 1, 10, LINE }
        prev = g
    end
    for _, l in ipairs(lines) do
        -- Spaces at either end (an answer is indented for the cursor) are not text.
        while l.chars[1] == " " do table.remove(l.chars, 1); table.remove(l.cells, 1) end
        while l.chars[#l.chars] == " " do table.remove(l.chars); table.remove(l.cells) end
        l.text = table.concat(l.chars)
    end
    local kept = {}
    for _, l in ipairs(lines) do if l.text ~= "" then kept[#kept + 1] = l end end
    return kept
end

local function join(lines, from, to)
    local chars, cells = {}, {}
    for i = from, to do
        if i > from then chars[#chars + 1] = "\n"; cells[#cells + 1] = false end
        chars[#chars + 1] = lines[i].text
        for _, c in ipairs(lines[i].cells) do cells[#cells + 1] = c end
    end
    return table.concat(chars), cells
end

local OPEN = { ["「"] = true, ["『"] = true, ["（"] = true }

local shown = {}      -- window number -> {key, names of its layouts, choice}
local missing = 0     -- frames without a window drawn
local stable = {}     -- window number -> {key, frames}
local space = { 320, 224 }

local function withdraw(id)
    local s = shown[id]
    if not s then return end
    for _, name in ipairs(s.layouts) do reader.layout(name, nil) end
    if s.choice then reader.cursor(nil) end
    shown[id] = nil
end

local function withdraw_all()
    for id in pairs(shown) do withdraw(id) end
    stable = {}
end

local function signature(glyphs, count)
    local parts = {}
    for i = 1, count do
        local g = glyphs[i]
        parts[i] = g.code .. "," .. g.x .. "," .. g.y
    end
    return table.concat(parts, ";")
end

-- Whether what the window shows now goes on from what was reported of it: the same page, the
-- glyphs reported then still there (the game waited for a press within the page).
local function goes_on(s, w)
    return s and s.page == w.txt .. ":" .. w.start and #w.glyphs >= s.count
        and signature(w.glyphs, s.count) == s.sig
end

local function report(w, key)
    if DEBUG then reader.log(string.format("report w%d %08X %s done=%s", w.id, w.win, key, tostring(w.done))) end
    local s = shown[w.id]
    local from = 1
    if goes_on(s, w) then
        from = s.count + 1
    else
        withdraw(w.id)
        s = { layouts = {}, page = w.txt .. ":" .. w.start, count = 0, sig = "" }
    end
    s.key = key
    s.count = #w.glyphs
    s.sig = signature(w.glyphs, #w.glyphs)
    shown[w.id] = s
    local glyphs = {}
    for i = from, #w.glyphs do glyphs[#glyphs + 1] = w.glyphs[i] end
    local lines = lines_of(glyphs)
    if #lines == 0 then return end
    local first, speaker = 1, s.speaker
    if from == 1 and #lines >= 2 and not OPEN[lines[1].chars[1]] and OPEN[lines[2].chars[1]] then
        speaker = lines[1].text
        first = 2
        s.speaker = speaker
    end
    local answers = 0
    local count = mem.u32(CHOICES) or 0
    if w.asks and count > 0 and count <= #lines - first + 1 then
        answers = count
    end
    local name = "w" .. w.id .. "." .. (#s.layouts + 1)
    if #lines - answers >= first then
        local body, cells = join(lines, first, #lines - answers)
        reader.emit{ text = body, speaker = speaker, window = name, id = text.hash(key .. body) }
        reader.layout(name, { space = space, glyphs = cells })
        s.layouts[#s.layouts + 1] = name
    end
    if answers > 0 then
        name = "w" .. w.id .. "." .. (#s.layouts + 1)
        local body, cells = join(lines, #lines - answers + 1, #lines)
        reader.emit{ text = body, window = name, channel = "choice", id = "choice:" .. text.hash(key .. body) }
        reader.layout(name, { space = space, glyphs = cells })
        s.layouts[#s.layouts + 1] = name
        s.choice = true
    end
end

reader.on_frame(function()
    local pw, ph = reader.picture()
    if pw then space = { pw, ph } end
    if #drawn == 0 then
        -- The field draws its windows every other frame; a few frames without any: gone.
        missing = missing + 1
        if missing >= 4 then withdraw_all() end
        return
    end
    missing = 0
    local seen = {}
    for _, w in ipairs(drawn) do
        if not seen[w.id] then
            seen[w.id] = true
            local key = string.format("%08X:%d:%d:%d", w.txt, w.start, w.stop, #w.glyphs)
            local st = stable[w.id]
            if st and st.key == key then st.frames = st.frames + 1 else st = { key = key, frames = 0 }; stable[w.id] = st end
            local s = shown[w.id]
            -- A page is read once it is complete: the game waits for a press, or it stood
            -- unchanged for a while (a line the game takes away by itself).
            if (w.done or st.frames >= 40) and #w.glyphs > 0 and (not s or s.key ~= key) then
                report(w, key)
            elseif s and s.key ~= key and not goes_on(s, w) then
                withdraw(w.id)
            end
            s = shown[w.id]
            if s and s.choice then
                local at = mem.u32(CHOICE_AT)
                local count = mem.u32(CHOICES) or 0
                if count > 0 then
                    reader.cursor(at and at < count and at or -1)
                end
            end
        end
    end
    -- A window that was not drawn this time is closed.
    for id in pairs(shown) do
        if not seen[id] then withdraw(id) end
    end
    drawn = {}
end)

reader.on_state_loaded(function()
    withdraw_all()
    drawn, drawing, prefix = {}, nil, nil
    place_ptr, place_list = nil, nil
end)
