-- reader: no hooks
-- reader: title METAL GEAR SOLID 3 SNAKE EATER
-- reader: reads Codec conversations, radio calls, and cutscene subtitles
-- reader: version SLPM-65790
-- METAL GEAR SOLID 3 SNAKE EATER (Konami, PS2, 2004), SLPM-65790. Program 0481AD8A.
--
-- METAL GEAR SOLID 2's text and drawing (SLPM-67002.lua says how; a change to one belongs in
-- the other), at this program's places. The game's text is two bytes a character: 80 xx
-- ASCII, 81 xx hiragana and 82 xx katakana in Unicode order without ゐゑ/ヰヱ, 83 xx signs.
-- Kanji have no codes: each text resource brings the pictures of the kanji it uses (24x24,
-- two bits a pixel, 144 bytes), and a kanji is the number of its picture there, 255 to a first
-- byte: 8C-8F in the codec, 90-93 in subtitles. So a kanji is known by its picture, through a
-- table made from the game's files (SLPM-65790.charset: a hash of the picture and the
-- character), which is not part of this script. #{base、gloss}# puts a gloss over a word.
--
-- The codec: a conversation bank's texts are one block (0x213A80 points to its header: size,
-- table, texts, pictures; on the disc its texts are enciphered, here they are not), and while
-- a line is up the script command that shows it is the one running, whose arguments
-- (0x498CE0) are a tag, 0x61D3F4, and the line.
-- Subtitles (cutscenes, films, radio calls while playing): a subtitle object (4, its clock,
-- ..., the entries' length at +0x28, the entries from +0x2c, then the pictures) holds entries
-- (start, end, -, length and kind); the pictures in use are at 0x1D30EC, the clock's time at
-- +8, and the entry up is the one whose start and end hold the time.
--
-- Not read: the menus, the survival viewer and the camouflage index, item names and help,
-- texts drawn as pictures.

local BUILD = "0481AD8A"
if reader.build_id ~= BUILD then
    error("this profile is for METAL GEAR SOLID 3 SNAKE EATER SLPM-65790 (program " .. BUILD ..
          "), the game is " .. tostring(reader.build_id))
end

local charset = reader.data("charset")
if not charset then
    error("METAL GEAR SOLID 3 needs its character table, SLPM-65790.charset, beside this profile: " ..
          "it is made from the game and not part of this script")
end
local KANJI = {}
for hash, ch in charset:gmatch("(%x%x%x%x%x%x%x%x) ([^\n]+)") do
    KANJI[tonumber(hash, 16)] = ch
end

local CODEC_ARGS = 0x00498ce0    -- pointer to the running script command's arguments
local CODEC_TAG = 0x0061d3f4     -- the argument tag of a codec line
local CODEC_BLOCK = 0x00213a80   -- pointer to the codec block's header
local CODEC_FONT = 0x001d30e8    -- the codec block's kanji pictures
local SUB_FONT = 0x001d30ec      -- the subtitle object's kanji pictures
local SUB_TAG = "\4\0\0\0"
local CLOCK_MARK = 0x00209618    -- a subtitle clock has this at +0x0c
local ENTRIES = 0x2c             -- where a subtitle object's entries begin
local GLYPH = 144

local function valid(p) return p and p >= 0x100000 and p < 0x2000000 end

local SIGNS = { [0x01] = "　", [0x02] = "○", [0x03] = "△", [0x04] = "□", [0x05] = "×",
                [0x06] = "！", [0x07] = "？", [0x08] = "、", [0x09] = "。", [0x0a] = "」",
                [0x0b] = "』", [0x12] = "ー", [0x13] = "―", [0x14] = "…", [0x16] = "「",
                [0x17] = "『" }

local function kana(base, t)
    if t > 0x4f then t = t + 2 end
    return utf8.char(base + t)
end

-- FNV-1a over a picture's 32-bit words; what the table is keyed by.
local function picture_hash(bytes)
    local h = 2166136261
    for i = 1, GLYPH, 4 do
        h = ((h ~ string.unpack("<I4", bytes, i)) * 16777619) & 0xffffffff
    end
    return h
end

-- The pictures already made out, for the line being read only: the next conversation is
-- loaded into the same place with other pictures.
local seen_pictures = {}

local function kanji(font, index)
    local at = font + index * GLYPH
    local ch = seen_pictures[at]
    if not ch then
        local bytes = mem.read(at, GLYPH)
        ch = bytes and #bytes == GLYPH and KANJI[picture_hash(bytes)] or "〓"
        seen_pictures[at] = ch
    end
    return ch
end

local WIDTHS = 0x001d30d8       -- pointer to the ASCII font's table: width - 1 in bits 20-25

-- How wide an ASCII character is drawn.
local function ascii_width(c)
    local table_at = mem.u32(WIDTHS)
    local entry = valid(table_at) and mem.u32(table_at + (c - 0x20) * 4)
    return entry and ((entry >> 20) & 0x3f) + 1 or 12
end

-- The tokens of a text: { s = character, w = width } for what is drawn, { mark = "#", "{",
-- "}", "\n" } for the markup and line breaks. `page` is the first byte of its kanji (0x8C or
-- 0x90), `font` where their pictures are.
local function tokens(raw, page, font)
    local out, i = {}, 1
    local function put(s, w) out[#out + 1] = { s = s, w = w } end
    while i <= #raw do
        local c = raw:byte(i)
        if c == 0 then break end
        if c < 0x80 then
            if c == 0x0a then out[#out + 1] = { mark = "\n" } else put(string.char(c), ascii_width(c)) end
            i = i + 1
        else
            local t = raw:byte(i + 1) or 0
            if c >= page and c <= page + 3 then
                put(font and kanji(font, (c - page) * 255 + t - 1) or "〓", 24)
            else
                local kind = c & 0x8f
                if kind == 0x80 then
                    if t == 0x7c then out[#out + 1] = { mark = "\n" }
                    elseif t == 0x23 or t == 0x7b or t == 0x7d then out[#out + 1] = { mark = string.char(t) }
                    else put(string.char(t), ascii_width(t)) end
                elseif kind == 0x81 then
                    put(kana(0x3040, t), 24)
                elseif kind == 0x82 then
                    put(kana(0x30a0, t), 24)
                elseif kind == 0x83 and SIGNS[t] then
                    put(SIGNS[t], 24)
                end
            end
            i = i + 2
        end
    end
    return out
end

local function hiragana(s)
    if s == "" then return false end
    for _, code in utf8.codes(s) do
        if not ((code >= 0x3041 and code <= 0x3096) or code == 0x30fc) then return false end
    end
    return true
end

local BREAK = 22   -- what a line break adds to its row's width when the block is centred

local BUTTONS = { ["○"] = true, ["△"] = true, ["□"] = true, ["×"] = true }

-- Rows of drawn characters, each { s, w, gloss = text read in its place or nil, reading }:
-- #{base、gloss}# draws the base with the gloss above it.
local function rows_of(list)
    local rows, row = {}, {}
    local i = 1
    while i <= #list do
        local t = list[i]
        if t.mark == "#" and list[i + 1] and list[i + 1].mark == "{" then
            local base, gloss, into = {}, {}, nil
            into = base
            local k = i + 2
            while k <= #list and list[k].mark ~= "}" do
                local x = list[k]
                if x.s == "、" and into == base then into = gloss elseif x.s then into[#into + 1] = x end
                k = k + 1
            end
            local over = {}
            for _, x in ipairs(gloss) do over[#over + 1] = x.s end
            over = table.concat(over)
            if #base == 1 and BUTTONS[base[1].s] and over ~= "" then
                row[#row + 1] = { s = base[1].s, w = base[1].w, gloss = over }
            elseif hiragana(over) then
                for n, x in ipairs(base) do row[#row + 1] = { s = x.s, w = x.w, reading = n == 1 and over or nil, group = #base } end
            else
                for _, x in ipairs(base) do row[#row + 1] = x end
            end
            i = k + 1
            if list[i] and list[i].mark == "#" then i = i + 1 end
        elseif t.mark == "\n" then
            row.broken = true
            rows[#rows + 1] = row
            row = {}
            i = i + 1
        else
            if t.s then row[#row + 1] = t end
            i = i + 1
        end
    end
    if #row > 0 then rows[#rows + 1] = row end
    -- A row's trailing spaces are not text.
    for _, r in ipairs(rows) do
        while #r > 0 and (r[#r].s == " " or r[#r].s == "　") do r[#r] = nil end
    end
    return rows
end

-- The text as read and a cell for each of its characters. The rows are left-aligned in a block
-- centred at 320, in which a row ended by a line break counts 22 wider (measured: a subtitle
-- of one row is centred at 320, the codec's rows and a subtitle's broken ones at 309); `top`
-- is the first row's top, `pitch` the rows' step, in the 640x448 picture. `joiner` goes
-- between rows.
local function compose(rows, top, pitch, joiner)
    local widest = 0
    for _, r in ipairs(rows) do
        local w = 0
        for _, x in ipairs(r) do w = w + x.w end
        if r.broken then w = w + BREAK end
        widest = math.max(widest, w)
    end
    local left = 320 - widest / 2
    local b, cells = reader.builder(), {}
    local skip = 0
    for n, r in ipairs(rows) do
        if n > 1 and joiner ~= "" and b:length() > 0 then
            b:add(joiner)
            cells[#cells + 1] = false
        end
        local x, y = left, top + (n - 1) * pitch
        for k, ch in ipairs(r) do
            if ch.gloss then
                local count = text.len(ch.gloss)
                b:add(ch.gloss)
                for j = 0, count - 1 do cells[#cells + 1] = { x + ch.w * j / count, y, ch.w / count, 24 } end
            elseif ch.reading then
                local base = {}
                for j = k, math.min(#r, k + ch.group - 1) do base[#base + 1] = r[j].s end
                b:add_ruby(table.concat(base), ch.reading)
                skip = ch.group - 1
                cells[#cells + 1] = { x, y, ch.w, 24 }
            elseif skip > 0 then
                skip = skip - 1
                cells[#cells + 1] = { x, y, ch.w, 24 }
            else
                b:add(ch.s)
                cells[#cells + 1] = ch.s ~= " " and { x, y, ch.w, 24 } or false
            end
            x = x + ch.w
        end
    end
    return b, cells
end

-- The codec line up, as { key, raw, font }, or nil.
local function codec_line()
    local args = mem.u32(CODEC_ARGS)
    if not valid(args) or mem.u32(args + 4) ~= CODEC_TAG then return nil end
    local line, block = mem.u32(args + 8), mem.u32(CODEC_BLOCK)
    if not valid(line) or not valid(block) then return nil end
    local texts, pictures = mem.u32(block + 8), mem.u32(block + 12)
    if not texts or not pictures or line < block + texts or line >= block + pictures then return nil end
    local raw = mem.cstr(line, 0x400)
    if not raw or raw == "" then return nil end
    return { key = "c" .. line .. ":" .. block, raw = raw, font = mem.u32(CODEC_FONT) }
end

local sub_object, sub_font

-- The subtitle object whose pictures start at `font`: the tag is before its entries, the
-- nearest one that fits.
local function find_object(font)
    local from = math.max(0x100000, font - 0x4000)
    local area = mem.read(from, font - from)
    if not area then return nil end
    local found, start = {}, 1
    while true do
        local k = area:find(SUB_TAG, start, true)
        if not k then break end
        found[#found + 1] = k
        start = k + 1
    end
    for n = #found, 1, -1 do
        local object = from + found[n] - 1
        local length = mem.u32(object + ENTRIES - 4)
        if length and object + ENTRIES + length + 4 == font then return object end
    end
    return nil
end

-- The subtitle up, as { key, raw, font }, or nil.
local function subtitle_line()
    local font = mem.u32(SUB_FONT)
    if not valid(font) then return nil end
    if font ~= sub_font then sub_font, sub_object = font, find_object(font) end
    local object = sub_object
    if not object or mem.read(object, 4) ~= SUB_TAG then return nil end
    local clock = mem.u32(object + 4)
    if not valid(clock) or mem.u32(clock + 0x0c) ~= CLOCK_MARK then return nil end
    local now = mem.u32(clock + 8)
    local length = mem.u32(object + ENTRIES - 4) or 0
    local entries = mem.read(object + ENTRIES, length)
    if not now or not entries or #entries ~= length then return nil end
    local at = 1
    while at + 16 <= #entries + 1 do
        local first, last, _, size = string.unpack("<I4I4I4I4", entries, at)
        size = size & 0xffff
        if size < 16 then break end
        if now >= first and now < last then
            return { key = "s" .. (object + ENTRIES + at - 1) .. ":" .. first, raw = entries:sub(at + 16, at + size - 1),
                     font = font }
        end
        at = at + size
    end
    return nil
end

local reported = {}        -- window -> key of the line reported last
local missing = {}         -- window -> frames since its line went
local layouts = {}         -- window -> the cells of the line reported last
local serial = 0
-- A line that goes and comes back within this many frames is the same line (another script
-- command can run between two of a conversation's lines); after it, the line is new.
local SAME_LINE = 120
-- Where each kind of text stands: first row's top, the rows' step, what joins rows.
local PLACE = { codec = { 274.5, 34, "" }, subtitle = { 369, 36, " " } }

reader.on_state_loaded(function()
    for window in pairs(reported) do reader.layout(window, nil) end
    reported, missing, layouts, sub_object, sub_font = {}, {}, {}, nil, nil
end)

local function report(window, line, page)
    if not line then
        local frames = (missing[window] or 0) + 1
        missing[window] = frames
        if frames == 1 then reader.layout(window, nil) end
        if frames >= SAME_LINE then reported[window] = nil end
        return
    end
    local back = (missing[window] or 0) > 0
    missing[window] = 0
    if reported[window] == line.key then
        if back then reader.layout(window, layouts[window]) end
        return
    end
    reported[window] = line.key
    seen_pictures = {}
    local place = PLACE[window]
    local b, cells = compose(rows_of(tokens(line.raw, page, line.font)), place[1], place[2], place[3])
    local whole = b:text()
    if whole:gsub("[%s　]", "") == "" then
        reader.layout(window, nil)
        return
    end
    serial = serial + 1
    reader.emit{ text = whole, ruby = b:ruby(), window = window, id = text.hash(line.key) .. ":" .. serial }
    local layout = { space = { 640, 448 }, glyphs = cells }
    layouts[window] = layout
    reader.layout(window, layout)
end

reader.on_frame(function()
    report("codec", codec_line(), 0x8c)
    report("subtitle", subtitle_line(), 0x90)
end)
