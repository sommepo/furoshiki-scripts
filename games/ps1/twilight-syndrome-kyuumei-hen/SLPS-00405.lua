-- reader: title トワイライトシンドローム 究明編
-- reader: reads Dialogue, narration, and speakers
-- reader: version SLPS-00405 (boot program 9ECCD178)
-- reader: no hooks
-- reader: touch press
--
-- Twilight Syndrome: Kyuumei-hen (Human, 1996), the Japanese disc. Tansaku-hen (SLPS-00102) is the same engine on a disc of its own, its profile this file with its own chapters.
--
-- Every chapter is a program of its own (CAP0.EXE, CAP1.EXE, ...), loaded over the one before,
-- each with its own copy of the message engine and of the font's code table, at addresses of
-- its own (listed below; the profile sees which is loaded by the engine's first instructions
-- that name the message, 0x801FE800). The message being written is copied to 0x801FE800: a
-- word, then 16-bit codes. A narration's text follows its header (Tansaku-hen's after a
-- 0x8301), 0x8Dnn opens a speech (one an utterance,
-- ended by 0x8600), 0x8100 breaks a line (a code 0 after it is the line's indent, drawn as
-- nothing), 0x84nn pauses, 0x8500 waits for ○ (▼), 0x8300 ends (□); a word 0xCnnn takes one
-- word after it. The engine keeps how many codes it has written
-- (pos) and, six bytes before, what it does (0xFFFE waiting for ○, 0xFFFC the window closed).
-- The window shows a narration's last four lines, 20 lines apart, or an utterance on its own
-- (its lines after the first under the text after "name："), each glyph advancing by the width
-- the code table gives it.
--
-- The code table (8 bytes a code: the width, then where the glyph's picture is in the font
-- loaded at 0x8001A200, a run-length picture of its own) is what names a character: the
-- chapters' fonts hold different kanji under the same codes, and this disc's two games draw
-- the kana differently, so a glyph is known by the FNV-1a hash of its picture's bytes
-- (text.hash), looked up in SLPS-00405.charset, a table read from the game's own glyphs (private, as
-- tables made from a game's font are). Without it the profile stops and says so. See
-- docs/reader/games/twilight-syndrome.md.

local BUILD = "9ECCD178"
if reader.build_id ~= BUILD then
    error("this profile is for the boot program " .. BUILD .. ", the disc has " .. tostring(reader.build_id))
end

-- Each chapter's program: where its engine names the message (two instructions), its code
-- table (the entry of code 0) and its count of codes written.
local CHAPTERS = {
    { name = "CAP5", sig = 0x8003A570, table = 0x800959D0, pos = 0x800AAABE },
    { name = "CAP6", sig = 0x8003A284, table = 0x80092BE4, pos = 0x800A80E2 },
    { name = "CAP7", sig = 0x80039724, table = 0x80092A10, pos = 0x800A5B02 },
    { name = "CAP8", sig = 0x80039210, table = 0x8009989C, pos = 0x800AF726 },
    { name = "CAP9", sig = 0x80038BE8, table = 0x80090628, pos = 0x800A5D96 },
    { name = "CAPA", sig = 0x80039260, table = 0x800926F8, pos = 0x800A86A2 },
    { name = "CAPH", sig = 0x80039160, table = 0x80083934, pos = 0x80096742 },
}
local SIG1, SIG2 = 0x3C03801F, 0x3463E800  -- lui v1,0x801F; ori v1,v1,0xE800
local MESSAGE = 0x801FE802                 -- the message's codes
local MESSAGE_MAX = 0x400                  -- codes looked at, at most
local WAITING, CLOSED = 0xFFFE, 0xFFFC

local X0, Y0, LINE, ROWS, CELL = 23, 151, 20, 4, 16
-- Where the game draws and where the glyphs are seen differ vertically (DuckStation's overscan
-- cut), measured in the pictures on Linux.
local SHIFT = -3

-- The glyphs: <hash of the picture's bytes><TAB><character>.
local chars = {}
local data = reader.data("charset")
if not data then
    error(reader.game_id .. ".charset is missing: this game's glyph table is not published (see the profile's notes)")
end
for hash, ch in data:gmatch("(%x+)\t([^\n]+)") do chars[hash] = ch end

local chapter = nil
local function find_chapter()
    if chapter and mem.u32(chapter.sig) == SIG1 and mem.u32(chapter.sig + 4) == SIG2 then return chapter end
    chapter = nil
    for _, c in ipairs(CHAPTERS) do
        if mem.u32(c.sig) == SIG1 and mem.u32(c.sig + 4) == SIG2 then
            local w = mem.u32(c.table + 8) or 99
            if w <= 16 then chapter = c; break end
        end
    end
    return chapter
end

-- A code's character and width, through the hash of its glyph's picture (cached per chapter).
local cache, cache_for, warned = {}, nil, {}
local function glyph(code)
    if cache_for ~= chapter then cache, cache_for = {}, chapter end
    local hit = cache[code]
    if hit then return hit[1], hit[2] end
    local width = mem.u32(chapter.table + 8 * code) or CELL
    local at = mem.u32(chapter.table + 8 * code + 4) or 0
    local ch
    if code == 0 then
        ch = ""
    elseif at < 0x80010000 or at >= 0x80200000 then
        ch = "〓"
    else
        -- The picture's bytes: 0x00-0x7F n+1 literal bytes, 0x80-0xBF one byte repeated,
        -- 0xC0-0xFE a copy (two bytes), 0xFF the end.
        local p, len = at, 0
        for _ = 1, 400 do
            local c = mem.u8(p + len) or 0xFF
            len = len + 1
            if c == 0xFF then break
            elseif c < 0x80 then len = len + c + 1
            elseif c < 0xC0 then len = len + 1
            else len = len + 2 end
        end
        local bytes = mem.read(at, len)
        ch = bytes and chars[text.hash(bytes)]
        if not ch then
            ch = "〓"
            if not warned[code] then
                warned[code] = true
                reader.warn(string.format("%s: code %X has a glyph the table does not know", chapter.name, code))
            end
        end
    end
    cache[code] = { ch, width }
    return ch, width
end

-- The message's lines up to what is written, of the part the window shows: a narration
-- (opened by 0x8301) keeps its lines and scrolls; a speech (opened by 0x8Dnn, one for each
-- utterance, ended by 0x8600) is a window of its own, its lines after the first hanging under
-- the text after the speaker's "name：". Returns the part's number and its lines, each a list
-- of { character, x }.
local function message_lines(written)
    local part, lines, cur, x = 1, { {} }, nil, X0
    cur = lines[1]
    local open, speech, hang, i = true, false, nil, 0
    local closed = false   -- a control word follows the last glyph
    while i < written and i < MESSAGE_MAX do
        local code = mem.u16(MESSAGE + 2 * i) or 0
        i = i + 1
        closed = code >= 0x8000
        if code >= 0x8000 then
            if code >= 0x8D00 and code <= 0x8DFF then
                -- Waiting at an utterance's end, the engine has already read the next one's
                -- opening: that part begins only once some of it is written.
                if i >= written then break end
                part = part + 1; lines = {}; cur = {}; lines[1] = cur; x = X0
                open, speech, hang = true, true, nil
            elseif code >= 0xC000 then i = i + 1                     -- takes an argument
            elseif code == 0x8301 then
                -- Opens the text (Tansaku-hen; Kyuumei-hen's begins after the header).
                if #lines > 1 or #lines[1] > 0 then
                    part = part + 1; lines = {}; cur = {}; lines[1] = cur
                end
                x, open, speech, hang = X0, true, false, nil
            elseif code == 0x8100 and open then
                cur = {}; lines[#lines + 1] = cur; x = (speech and hang) or X0
                if (mem.u16(MESSAGE + 2 * i) or 1) == 0 then i = i + 1 end   -- the indent
            elseif code == 0x8600 or code == 0x8300 then open = false end
        elseif open and cur and not (code == 0 and #cur == 0) then   -- an indent takes no room
            local ch, w = glyph(code)
            if ch ~= "" then cur[#cur + 1] = { ch, x } end
            x = x + w
            if speech and not hang and #lines == 1 and ch == "：" then hang = x end
        end
    end
    return part, lines, closed
end

local said = {}       -- lines reported, by their number in the part
local shown = {}      -- window names laid out
local message_key, part_now, speaker = nil, nil, nil

-- The window's places are withdrawn whenever it is not shown; what was reported is forgotten
-- only for another message or part (the engine closes the window for a frame between two).
local function withdraw()
    for window in pairs(shown) do reader.layout(window, nil) end
    shown = {}
end

local function clear()
    withdraw()
    said, speaker = {}, nil
end

local function line_text(line, from)
    local t = {}
    for k = from or 1, #line do t[#t + 1] = line[k][1] end
    return table.concat(t)
end

reader.on_frame(function()
    if not find_chapter() then
        if next(shown) then withdraw() end
        return
    end
    local state = mem.u16(chapter.pos - 6) or CLOSED
    local written = mem.u16(chapter.pos) or 0
    if state == CLOSED or written == 0 then
        if next(shown) then withdraw() end
        return
    end
    local part, lines, closed = message_lines(written)
    -- Another message (its first codes changed) or another part of it: a window of its own.
    local key = (mem.read(MESSAGE, 24) or "") .. ":" .. part
    if key ~= message_key then
        clear()
        message_key = key
    end
    local w, h = reader.picture()
    local first = math.max(1, #lines - ROWS + 1)
    local visible = {}
    for n = first, #lines do
        local line = lines[n]
        -- A line is done once the next one has begun, or the game waits for ○ after it (waiting,
        -- the engine may have read a code of what follows).
        local done = n < #lines or (state == WAITING and closed)
        if done and #line > 0 and not said[n] then
            local body = line_text(line)
            local skip = 0
            if n == 1 then
                local name, rest = body:match("^([^：]+)：(.+)$")
                if name and utf8.len(name) and utf8.len(name) <= 8 then
                    speaker, body, skip = name, rest, utf8.len(name) + 1
                end
            end
            said[n] = { skip = skip }
            reader.emit({ text = body, window = "line" .. n, id = text.hash(body), speaker = speaker })
        end
        if said[n] then
            local row = n - first
            local cells = {}
            for k = said[n].skip + 1, #line do
                local g, nxt = line[k], line[k + 1]
                local width = nxt and (nxt[2] - g[2]) or 14
                cells[#cells + 1] = { g[2], Y0 + LINE * row + SHIFT, width, CELL }
            end
            visible["line" .. n] = { row = row .. ":" .. #cells, value = { space = { w or 320, h or 240 }, glyphs = cells } }
        end
    end
    for window in pairs(shown) do
        if not visible[window] then reader.layout(window, nil); shown[window] = nil end
    end
    for window, v in pairs(visible) do
        if shown[window] ~= v.row then
            reader.layout(window, v.value)
            shown[window] = v.row
        end
    end
end)

reader.on_state_loaded(function()
    clear()
    message_key = nil
    chapter = nil
end)
