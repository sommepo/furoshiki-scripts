-- reader: title ファイナルファンタジーVII (ディスク1)
-- reader: reads Field dialogue, notices, and choices
-- reader: version SLPS-00700 (boot program 61B5B75A)
-- reader: no hooks
-- reader: audio never
-- reader: touch press
-- reader: buttons up down circle
--
-- Final Fantasy VII (Square, 1997), the Japanese discs (SLPS-00700, -00701, -00702: the same
-- boot program on each, so the three profiles are the same but for their names). The field
-- module keeps up to four message windows in a table of the boot program's (48 bytes each):
-- the window's place and size, a pointer to the text typed into it so far, how far it is
-- scrolled, what it is doing, and while a choice is up where the pointing hand is. The text is
-- in the game's own encoding (not Shift-JIS): a byte for each kana, digit or sign, and two for
-- a kanji (FA-FE and its number in that page); the characters' names are already written out
-- in it. The boot program draws it glyph by glyph with widths from a table in memory, wrapping
-- a line that would run past the window's edge: the profile does the same sums to place each
-- character. The glyph numbers are the game's own, so a table of them (SLPS-00700.charset, a
-- line per glyph: its number and character; one for each disc's name, the same table) comes
-- beside this file. That table is made from
-- the game's font and is not published; without it the profile says so and reads nothing.
-- A message is reported once the window waits for a press (its page full, or its end), and
-- withdrawn while the next page is typed and when the window closes; a choice when the
-- script waits on an ASK for the window: the lines above its answers as the message, the
-- answers (the lines the ASK names) as the choice, and which one the hand is beside
-- (reader.cursor), so that a tap on an answer picks it. The buttons line above is a note of what picks an answer with the
-- controller. Battle text and the menus are not read. See docs/reader/games/ff7.md.

local BUILD = "61B5B75A"
if reader.build_id ~= BUILD then
    error("this profile is for the boot program " .. BUILD .. ", the disc has " .. tostring(reader.build_id))
end

local WINDOWS = 0x80081A0C  -- the message windows: 48 bytes each
local STRIDE = 0x30
local COUNT = 4
local WIDTHS = 0x8006F778   -- u32: the glyph width table (a byte a glyph: bearing << 5 | width)
local FIELD_SIGN = 0x800D6544 -- a word of the field module's code: the field is loaded
local FIELD_WORD = 0x97AB0010
local SCRIPT = 0x8009AE74   -- u32: the field's script
local ENTITY_POS = 0x80081994 -- u16[]: where each entity's script is
local LINE = 16             -- a line's height
local PAGES = { [0xFA] = 231, [0xFB] = 441, [0xFC] = 672, [0xFD] = 882 }
local BUTTONS = { [0xF6] = "○", [0xF7] = "△", [0xF8] = "□", [0xF9] = "×" }

local glyphs = {}
local data = reader.data("charset")
if not data then
    error(reader.game_id .. ".charset is missing: this game's glyph table is not published (see the profile's notes)")
end
for line in data:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
        local id, ch = line:match("^(%d+)\t(.+)$")
        if id then glyphs[tonumber(id)] = ch end
    end
end

-- The window's characters as the boot program draws them (0x8001D534): {ch, x, y, w, h}
-- relative to the window, and {ch = "\n"} where a line ends or wraps. A glyph that has no
-- character in the table (a blank one) takes its room and is not reported.
local function lay_out(raw, widths, scroll, limit)
    local out = {}
    local x, y = 8, scroll + 6
    local spaced = false
    local i = 1
    local function newline() x = 8; y = y + LINE end
    while i <= #raw do
        local b = raw:byte(i)
        local index, button = nil, nil
        if b == 0xFF or b == 0xE8 or b == 0xE9 then
            break
        elseif b == 0xE7 then
            newline()
            out[#out + 1] = { ch = "\n" }
        elseif PAGES[b] then
            i = i + 1
            index = PAGES[b] + (raw:byte(i) or 0)
        elseif b == 0xFE then
            i = i + 1
            local n = raw:byte(i) or 0
            if n < 0xD2 then index = 1092 + n
            elseif n == 0xE9 then spaced = not spaced end
        elseif BUTTONS[b] then
            button = BUTTONS[b]
        elseif b < 0xE7 then
            index = b
        end
        if button then
            out[#out + 1] = { ch = button, x = x, y = y - 2, w = 16, h = 16 }
            x = x + 16
        elseif index then
            local wb = widths:byte(index + 1) or 12
            local bearing, width = wb >> 5, wb & 31
            if x + bearing + width > limit then
                newline()
                out[#out + 1] = { ch = "\n", wrap = true }
            end
            if not spaced then x = x + bearing end
            local ch = glyphs[index]
            if ch then
                -- One glyph may stand for several characters (Red XIII's "XIII"): its cell is
                -- shared out among them.
                local n = utf8.len(ch) or 1
                local k = 0
                for _, code in utf8.codes(ch) do
                    out[#out + 1] = { ch = utf8.char(code), x = x + width * k / n, y = y,
                                      w = width / n, h = 12 }
                    k = k + 1
                end
            end
            x = x + (spaced and 13 or width)
        end
        i = i + 1
    end
    return out
end

local shown = {}     -- window -> key of what was reported
local choice = {}    -- window -> key of the choice reported

local function withdraw(w)
    if shown[w] then reader.layout("message" .. w, nil) end
    if choice[w] then
        reader.layout("choice" .. w, nil)
        reader.cursor(nil)
    end
    shown[w], choice[w] = nil, nil
end

local function withdraw_all()
    for w = 0, COUNT - 1 do withdraw(w) end
end

-- The ASK the script waits on for window w: its first and last answer lines.
local function asked(w)
    local script = mem.u32(SCRIPT)
    if not script or script < 0x80000000 then return nil end
    for e = 0, 63 do
        local pos = mem.u16(ENTITY_POS + e * 2)
        if pos then
            local op = mem.read(script + pos, 6)
            if op and #op == 6 and op:byte(1) == 0x48 and op:byte(3) == w
                and op:byte(5) <= op:byte(6) and op:byte(6) < 16 then
                return op:byte(5), op:byte(6)
            end
        end
    end
    return nil
end

-- Lines of laid-out characters into text and cells (on the picture); `keep` picks lines.
local function piece(chars, wx, wy, height, keep)
    local text, cells, line, prev_line = {}, {}, 0, nil
    for _, c in ipairs(chars) do
        if c.ch == "\n" then
            line = line + 1
        elseif c.y >= 0 and c.y + 12 <= height and (not keep or keep(line)) then
            if prev_line and line ~= prev_line then
                text[#text + 1] = "\n"; cells[#cells + 1] = false
            end
            text[#text + 1] = c.ch
            cells[#cells + 1] = { wx + c.x, wy + c.y, c.w, c.h }
            prev_line = line
        end
    end
    return table.concat(text), cells
end

reader.on_frame(function()
    if mem.u32(FIELD_SIGN) ~= FIELD_WORD then
        withdraw_all()
        return
    end
    local wptr = mem.u32(WIDTHS)
    local widths = wptr and mem.read(wptr, 1302) or ""
    local space = { reader.picture() }
    if #space < 2 then space = { 320, 240 } end
    for w = 0, COUNT - 1 do
        local base = WINDOWS + w * STRIDE
        local raw = mem.read(base, STRIDE) or ""
        if #raw < STRIDE then return end
        local ptr, wx, wy, ww, wh, cw, ch, scroll =
            string.unpack("<I4i2i2i2i2i2i2i2", raw, 1)
        local state = string.unpack("<i2", raw, 0x2C + 1)
        local hand = raw:byte(0x1A + 1)
        local hand_y = string.unpack("<i2", raw, 0x26 + 1)
        local open = state ~= 0 and cw == ww and ch == wh and ptr >= 0x80000000
        local waiting = state == 6 or state == 14
        local first, last = nil, nil
        if open and (waiting or hand ~= 0) then first, last = asked(w) end
        if not open or not (waiting or hand ~= 0) then
            -- Closed, opening, closing, or still typing its text: nothing to read yet.
            withdraw(w)
        else
            -- (0xFF ends the text only where a character begins: it is also a kanji's number.)
            local bytes = mem.read(ptr, 256) or ""
            local chars = lay_out(bytes, widths, scroll, ww - 3)
            -- A choice when the script waits on an ASK for this window (the hand comes a frame
            -- or two after the window is complete): its question is the message.
            local body, cells = piece(chars, wx, wy, wh, first and function(l) return l < first end)
            local key = body .. "@" .. wx .. "," .. wy
            if body ~= "" and key ~= shown[w] then
                shown[w] = key
                reader.emit{ text = body, window = "message" .. w, id = text.hash(body) }
                reader.layout("message" .. w, { space = space, box = { wx, wy, ww, wh }, glyphs = cells })
            end
            if first then
                local lines, line_cells = {}, {}
                for l = first, last do
                    local b, c = piece(chars, wx, wy, wh, function(n) return n == l end)
                    -- The answers begin with full-width spaces where the hand stands.
                    while b:sub(1, 3) == "\u{3000}" do b = b:sub(4); table.remove(c, 1) end
                    if l > first then lines[#lines + 1] = "\n"; line_cells[#line_cells + 1] = false end
                    lines[#lines + 1] = b
                    for _, cell in ipairs(c) do line_cells[#line_cells + 1] = cell end
                end
                local answers = table.concat(lines)
                local ckey = answers .. "@" .. wx .. "," .. wy
                if ckey ~= choice[w] then
                    choice[w] = ckey
                    reader.emit{ text = answers, window = "choice" .. w, channel = "choice",
                                 id = "choice:" .. text.hash(answers) }
                    reader.layout("choice" .. w, { space = space, glyphs = line_cells })
                end
                local at = hand ~= 0 and (hand_y - 6) // LINE - first or -1
                reader.cursor((at >= 0 and at <= last - first) and at or -1)
            elseif choice[w] then
                reader.layout("choice" .. w, nil)
                reader.cursor(nil)
                choice[w] = nil
            end
        end
    end
end)

reader.on_state_loaded(function()
    withdraw_all()
end)
