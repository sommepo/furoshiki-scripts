-- reader: no hooks
-- reader: title ファイナルファンタジーX インターナショナル
-- reader: reads Dialogue, speakers, subtitles, notices, and choices
-- reader: version SLPS-25088
--
-- FINAL FANTASY X INTERNATIONAL (Square, PS2, 2002), SLPS-25088. Program 658597E2.
--
-- The game's text is in a code of its own. A byte from 0x30 on is a character, and a pair whose
-- first byte is 0x2B to 0x2F one more: (first - 0x2B) * 0xD0 + second. The game keeps a table of
-- the Shift-JIS character of each code in its program's data (998 codes from 0x30: digits, signs,
-- kana, Latin letters and some 700 kanji), which this script reads. Below 0x30 are commands, most
-- with one byte after them: 0x03 a line break, 0x07 a space of (byte - 0x30) pixels, 0x0A a colour,
-- 0x10 an answer of a choice (0x30 the first; 0xFF ends it), 0x12 a number put in, 0x13 with a byte
-- up to 0x43 a party member's name, 0x13 to 0x22 otherwise a word of the game's dictionary (its
-- section and line), and 0x26 to 0x2A with a byte a kanji of the scene's own:
-- (0x2A - first) * 0xD0 + second - 0x30.
--
-- The scene's own kanji. Each scene (an event file) brings a small font of the kanji it uses that
-- the program's table lacks, as pictures only (FTCX: 14 by 18 pixels, two bits a pixel, two
-- pictures sharing each four-bit texel). So a kanji is known by its picture: the script needs a
-- table, reader.data("charset") (SLPS-25088.charset beside it: the FNV-1a hash of a picture's
-- 252 pixels, one byte each, and its character), made from the 327 scenes on the disc and read
-- against their sentences. Without it those kanji are reported as 〓.
--
-- The windows. The game has sixteen text windows, 0x110 bytes each from 0x667140: the first word
-- is 1 while the window is up, then where the text is (the whole string, the part shown and its
-- end), how many characters have been typed out, and the rectangle the text fills, in a picture
-- 512 wide. Every character stands its width (a table of a byte per code in the game's memory)
-- plus 2 from the one before; rows are 20 apart. Speech is "speaker⏎text" (the name on the first
-- row, empty for nobody); notices and subtitles begin with the command 0x09 and have no speaker.

local BUILD = "658597E2"
if reader.build_id ~= BUILD then
    error("this profile is for FINAL FANTASY X INTERNATIONAL SLPS-25088 (program " .. BUILD ..
          "), the game is " .. tostring(reader.build_id))
end

local CODE_TABLE = 0x003235e8 -- Shift-JIS of each code from 0x30, two bytes each
local CODE_COUNT = 998
local WIDTHS = 0x0068e070     -- a byte per code: the character's width in pixels
local SCENE_FONT = 0x0058f4b4 -- pointer to the scene's own font (FTCX)
local DICTIONARY = 0x0066aa00 -- pointer to the dictionary: sixteen pointers to its sections
local WINDOWS, WINDOW_SIZE, WINDOW_COUNT = 0x00667140, 0x110, 16
local CURSOR = 0x005803c0     -- the answer lit in a choice, from 0
local TEXT_MAX = 1024

-- Places: the windows' rectangles are in a picture 512 by 416 (measured against pictures).
local SPACE = { 512, 416 }
local ROW, GAP, HEIGHT = 20, 2, 18
local LOCAL_WIDTH = 14

-- Frames a window's text must have stood typed out before it is reported; a window whose count
-- of typed characters stands still this long short of the text's is reported all the same.
local SHOWN_FRAMES = 4
local STILL_FRAMES = 45

-- The party's names as the game has them before the player renames anyone ({13:30} on): the
-- game's own copy of a changed name was not found, so a renamed character reads as the default.
local PARTY = { "ティーダ", "ユウナ", "アーロン", "キマリ", "ワッカ", "ルールー", "リュック",
                "シーモア", "ヴァルファーレ", "イフリート", "イクシオン", "シヴァ", "バハムート",
                "アニマ", "ヨウジンボウ", "シンディ", "サンディ", "ミンディ" }

local MISSING = "〓"

-- The scene kanji's table: picture hash -> character.
local KANJI = {}
local charset = reader.data and reader.data("charset")
if charset then
    for hash, ch in charset:gmatch("(%x%x%x%x%x%x%x%x) ([^\r\n]+)") do
        KANJI[tonumber(hash, 16)] = ch
    end
end

-- The program's code table and the widths, read once the game has loaded them.
local fixed, widths, code_of
local function load_tables()
    if fixed then return true end
    local raw = mem.read(CODE_TABLE, CODE_COUNT * 2)
    if not raw or raw:sub(1, 2) ~= "\x82\x4f" then return false end -- ０
    local w = mem.read(WIDTHS, 0x30 + CODE_COUNT)
    if not w or w:byte(0x30 + 1) == 0 then return false end
    fixed, code_of = {}, {}
    for i = 0, CODE_COUNT - 1 do
        local ch = text.sjis(raw:sub(2 * i + 1, 2 * i + 2))
        fixed[0x30 + i] = ch
        if not code_of[ch] then code_of[ch] = 0x30 + i end
    end
    widths = w
    return true
end

local function width_of(code)
    return (widths and widths:byte(code + 1)) or LOCAL_WIDTH
end

-- The scene's own kanji, made out once per font.
local scene_font, scene_kanji = nil, {}

local function fnv(bytes)
    local h = 2166136261
    for i = 1, #bytes do
        h = ((h ~ bytes:byte(i)) * 16777619) & 0xffffffff
    end
    return h
end

local function load_scene_font()
    local at = mem.u32(SCENE_FONT) or 0
    if at == 0 or at >= 0x2000000 then
        scene_font, scene_kanji = nil, {}
        return
    end
    local header = mem.read(at, 0x30)
    if not header or header:sub(1, 4) ~= "FTCX" then return end
    local count = string.unpack("<I4", header, 0x11)
    local key = at .. ":" .. count .. ":" .. text.hash(header)
    if key == scene_font then return end
    scene_font, scene_kanji = key, {}
    local gw, gh = string.unpack("<I2I2", header, 0x15)
    local toff, tsize = string.unpack("<I4I4", header, 0x21)
    local tw = string.unpack("<I2", header, 0x29)
    if count > 0x340 or gw == 0 or tw < gw or tsize > 0x40000 then return end
    local texture = mem.read(at + toff, tsize)
    if not texture then return end
    local per_row = tw // gw
    for k = 0, count - 1 do
        local shift = 2 * (k % 2)
        local pos = k // 2
        local gx, gy = (pos % per_row) * gw, (pos // per_row) * gh
        local pixels = {}
        for y = 0, gh - 1 do
            for x = gx, gx + gw - 1 do
                local i = (gy + y) * tw + x
                local b = texture:byte(i // 2 + 1) or 0
                local nib = (i & 1 == 1) and (b >> 4) or (b & 15)
                pixels[#pixels + 1] = string.char((nib >> shift) & 3)
            end
        end
        scene_kanji[k] = KANJI[fnv(table.concat(pixels))] or MISSING
    end
end

-- The dictionary's word: section, line -> its string's bytes.
local function dictionary_word(section, line)
    local dict = mem.u32(DICTIONARY) or 0
    if dict == 0 or dict >= 0x2000000 then return nil end
    local sec = mem.u32(dict + 4 * section) or 0
    if sec == 0 or sec >= 0x2000000 then return nil end
    local first = mem.u16(sec) or 0
    if line * 4 >= first then return nil end
    local off = mem.u16(sec + 4 * line) or 0
    local raw = mem.read(sec + off, 64)
    return raw and raw:match("^[^%z]*")
end

-- The text as tokens: { text, width } for a character, "\n" for a line break, { answer = n }
-- for the start of a choice's answer, { space = n } for a space of n pixels.
local function tokens(raw, out, depth)
    out = out or {}
    local at = 1
    while at <= #raw do
        local b = raw:byte(at)
        local c = raw:byte(at + 1) or 0
        if b == 0 then
            break
        elseif b >= 0x30 then
            out[#out + 1] = { text = fixed[b] or MISSING, width = width_of(b) }
            at = at + 1
        elseif b >= 0x2b and b <= 0x2f then
            local code = (b - 0x2b) * 0xd0 + c
            out[#out + 1] = { text = fixed[code] or MISSING, width = width_of(code) }
            at = at + 2
        elseif b >= 0x26 and b <= 0x2a then
            local k = (0x2a - b) * 0xd0 + c - 0x30
            out[#out + 1] = { text = scene_kanji[k] or MISSING, width = LOCAL_WIDTH }
            at = at + 2
        elseif b == 0x03 then
            out[#out + 1] = "\n"
            at = at + 1
        elseif b == 0x01 or b == 0x02 or b == 0x05 or b == 0x0c or b == 0x0f or b == 0x11 then
            at = at + 1 -- waits and the like: nothing drawn
        elseif b == 0x04 then
            -- A code of the five sections after the first five: the program's table has none.
            if c >= 0x30 then
                out[#out + 1] = { text = MISSING, width = LOCAL_WIDTH }
                at = at + 2
            else
                at = at + 3
            end
        elseif b == 0x07 then
            out[#out + 1] = { space = c - 0x30 }
            at = at + 2
        elseif b == 0x10 then
            if c ~= 0xff then out[#out + 1] = { answer = c - 0x30 } end
            at = at + 2
        elseif b == 0x13 and c <= 0x43 then
            local name = PARTY[c - 0x30 + 1]
            if name then
                for _, ch in utf8.codes(name) do
                    local t = utf8.char(ch)
                    out[#out + 1] = { text = t, width = code_of[t] and width_of(code_of[t]) or 12 }
                end
            end
            at = at + 2
        elseif b >= 0x13 and b <= 0x22 then
            local word = (depth or 0) < 2 and dictionary_word(b - 0x13, c - 0x30)
            if word then tokens(word, out, (depth or 0) + 1) end
            at = at + 2
        else
            at = at + 2 -- 0x09 window kind, 0x0A colour, 0x0B button, 0x12 number, 0x23 item...
        end
    end
    return out
end

-- Lines of tokens; each a list of characters with their x in the window.
local function lines_of(list)
    local lines, line, x = {}, { chars = {} }, 0
    for _, t in ipairs(list) do
        if t == "\n" then
            lines[#lines + 1] = line
            line, x = { chars = {} }, 0
        elseif t.space then
            x = x + t.space
        elseif t.answer then
            line.answer = t.answer
        else
            line.chars[#line.chars + 1] = { text = t.text, x = x, width = t.width }
            x = x + t.width + GAP
        end
    end
    lines[#lines + 1] = line
    return lines
end

local function count_chars(lines)
    local n = 0
    for _, l in ipairs(lines) do n = n + #l.chars end
    return n
end

local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local shown = {}  -- per window: the text reported, how long it has stood, the last typed count
local layouts = {}
local cursor_said

local function withdraw(i)
    for _, name in ipairs({ "w" .. i, "w" .. i .. "c" }) do
        if layouts[name] then
            reader.layout(name, nil)
            layouts[name] = nil
        end
    end
end

local function cells_for(line, row, rect)
    local out = {}
    for _, ch in ipairs(line.chars) do
        out[#out + 1] = { rect[1] + ch.x, rect[2] + row * ROW, ch.width + GAP, HEIGHT }
    end
    return out
end

-- Text of a line without the spaces that set it in.
local function line_text(line, b, cells, row, rect)
    local started = false
    local cs = cells_for(line, row, rect)
    for n, ch in ipairs(line.chars) do
        if started or ch.text ~= "　" then
            started = true
            b:add(ch.text)
            cells[#cells + 1] = cs[n]
        end
    end
    return started
end

local function report(i, raw, whole, rect)
    local list = tokens(raw)
    local lines = lines_of(list)
    -- Rows the window shows: leading empty lines that do not fit are not drawn (subtitles).
    local rows = (rect[4] - rect[2] + GAP) // ROW
    while #lines > rows and #lines > 1 and #lines[1].chars == 0 and not lines[1].answer do
        table.remove(lines, 1)
    end
    -- Speech: the first line is the speaker's name.
    local speaker
    local first_body = 1
    if whole and raw:byte(1) ~= 0x09 and #lines > 1 then
        local name = {}
        for _, ch in ipairs(lines[1].chars) do name[#name + 1] = ch.text end
        name = table.concat(name)
        if name ~= "" then speaker = name end
        first_body = 2
    end
    local b, cells = reader.builder(), {}
    local answers = {}
    for n = first_body, #lines do
        local line = lines[n]
        if line.answer then
            answers[#answers + 1] = { line = line, row = n - 1 }
        else
            if #cells > 0 then
                b:add("\n")
                cells[#cells + 1] = false
            end
            line_text(line, b, cells, n - 1, rect)
        end
    end
    -- An empty speaker row stays a row: the text below it is placed by the window.
    local box = { rect[1] - 8, rect[2] - 6, rect[3] - rect[1] + 16, rect[4] - rect[2] + 12 }
    local body = b:text()
    if body:gsub("\n", ""):gsub("　", "") ~= "" then
        local name = "w" .. i
        reader.emit{ text = body, speaker = speaker, window = name,
                     id = "ffx:" .. text.hash(raw) }
        reader.layout(name, { space = SPACE, box = box, glyphs = cells })
        layouts[name] = true
    end
    if #answers > 0 then
        local cb, ccells = reader.builder(), {}
        local real = 0
        for n, a in ipairs(answers) do
            if n > 1 then
                cb:add("\n")
                ccells[#ccells + 1] = false
            end
            if line_text(a.line, cb, ccells, a.row, rect) then real = real + 1 end
        end
        if real > 0 then
            local name = "w" .. i .. "c"
            reader.emit{ text = cb:text(), channel = "choice", window = name,
                         id = "ffx:choice:" .. text.hash(raw) }
            reader.layout(name, { space = SPACE, box = box, glyphs = ccells })
            layouts[name] = true
            return #answers
        end
    end
    return nil
end

local choosing = {}

reader.on_frame(function()
    if not load_tables() then return end
    load_scene_font()
    local any_choice
    for i = 0, WINDOW_COUNT - 1 do
        local s = WINDOWS + WINDOW_SIZE * i
        local head = mem.read(s, 0x90)
        local up = head and string.unpack("<I4", head, 1) == 1
        local whole, from, to = 0, 0, 0
        if up then
            whole, from, to = string.unpack("<I4I4I4", head, 0x4c + 1)
        end
        if not up or from == 0 or to <= from or to - from > TEXT_MAX or to >= 0x2000000 then
            if shown[i] then
                withdraw(i)
                shown[i] = nil
                choosing[i] = nil
            end
        else
            local raw = mem.read(from, to - from) or ""
            local typed = string.unpack("<I4", head, 0x8c + 1)
            local rect = { s16(string.unpack("<I2", head, 0x31)), s16(string.unpack("<I2", head, 0x33)),
                           s16(string.unpack("<I2", head, 0x35)), s16(string.unpack("<I2", head, 0x37)) }
            local key = from .. ":" .. text.hash(raw)
            local st = shown[i]
            if not st or st.key ~= key then
                if st then withdraw(i) end
                st = { key = key, frames = 0, typed = -1, done = false }
                shown[i] = st
                choosing[i] = nil
            end
            if not st.done then
                -- Typed out: as many characters as the text has (a wait in the middle stops
                -- the count short of it), or none more for a long while.
                local total = count_chars(lines_of(tokens(raw)))
                if typed == st.typed and typed > 0 then
                    st.frames = st.frames + 1
                else
                    st.frames = 0
                end
                st.typed = typed
                if (typed >= total and st.frames >= SHOWN_FRAMES) or st.frames >= STILL_FRAMES then
                    st.done = true
                    choosing[i] = report(i, raw, whole == from, rect)
                end
            end
            if choosing[i] then any_choice = choosing[i] end
        end
    end
    -- Touch play: the answer the cursor is on.
    local at = nil
    if any_choice then
        at = mem.u32(CURSOR) or 0
        if at >= any_choice then at = -1 end
    end
    if at ~= cursor_said then
        cursor_said = at
        if reader.cursor then reader.cursor(at) end
    end
end)

reader.on_state_loaded(function()
    for i = 0, WINDOW_COUNT - 1 do withdraw(i) end
    shown, choosing, cursor_said = {}, {}, nil
    scene_font, scene_kanji = nil, {}
    if reader.cursor then reader.cursor(nil) end
end)
