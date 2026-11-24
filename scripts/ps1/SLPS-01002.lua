-- reader: title ムーンライトシンドローム
-- reader: reads Dialogue, narration, and speakers
-- reader: version SLPS-01002, disc 2 (boot program 6AA67A0C)
-- reader: no hooks
-- reader: touch press
--
-- Moonlight Syndrome (Human, 1997), the Japanese release, disc 2. Disc 1 (SLPS-01001) has the
-- same boot program, and its profile is this file under the other name.
--
-- The game is in chapters, one file each on the discs (PROLOGUE.DAT, MOWDEI.DAT, ...): a
-- script, the chapter's kanji (256 or 512 glyphs, in the order the chapter first needs them)
-- and a strip of its speakers' names drawn as pictures. The script's text is 16-bit codes,
-- big-endian: 0x00-0xFF the fixed font (signs, digits, Latin, hiragana and katakana in the
-- order of the kana table), 0x100 and up the chapter's kanji, so 0x104 is one kanji in one
-- chapter and another in the next. The loaded chapter is known by its file's table, copied to
-- 0x8008BF04 (sector, size of each part): the script's size (0x8008BF08) differs in every one.
--
-- The window's page is drawn every frame from a list of 16-pixel sprites, one per glyph, in
-- the order they are revealed (0x8008F640, 16 bytes each), chained under three texture page
-- commands (0x80091640: the fixed font, the first and the second page of the chapter's
-- kanji), each sprite with its place in the 320x240 picture and the glyph's place on its page.
-- The page's ▼ (0x8008B180) is bright while the game waits for ○, dim while it writes. The
-- speaker's name is a quad (0x8008EBA4) showing one 128x16 slot of the chapter's name strip.
--
-- The kanji and the names are a table read from the game's own pictures, SLPS-0100x.charset
-- (private, as tables made from a game's font are: see the game's note); without it the
-- profile stops and says so. See docs/reader/games/moonlight-syndrome.md.

local BUILD = "6AA67A0C"
if reader.build_id ~= BUILD then
    error("this profile is for the boot program " .. BUILD .. ", the disc has " .. tostring(reader.build_id))
end

local CHAPTER    = 0x8008BF08 -- u32: the size of the loaded chapter's script
local SPRITES    = 0x8008F640 -- the page's glyph sprites, 16 bytes each
local SPRITE_END = 0x80090640 -- the first buffer's 256 (the second follows)
local PAGES      = 0x80091640 -- three links with texture page commands: fixed font, kanji 1, kanji 2
local ARROW      = 0x8008B184 -- u8: the ▼'s brightness, 0x80 while the game waits for ○
local NAME_QUAD  = 0x8008EBA4 -- the speaker's name: +4 colour (0 while none), +8 u, +9 v
local CELL       = 16
-- Where the game draws and where the glyphs are seen differ vertically (DuckStation's overscan
-- cut; measured in the pictures on Linux): the rows are seen 5 lines higher than drawn.
local SHIFT      = -5

-- The fixed font: its codes in order.
local FIXED = {}
do
    local function put(from, s)
        local i = from
        for _, c in utf8.codes(s) do FIXED[i] = utf8.char(c); i = i + 1 end
    end
    put(0x00, "：！？・ー、。〜「」　　　　　　")
    put(0x10, "０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ")
    put(0x34, "ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ")
    put(0x50, "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん")
    put(0x7E, "がぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽぁぃぅぇぉゃゅょっ")
    put(0xA0, "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン")
    put(0xCE, "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポァィゥェォャュョッ")
end

-- The chapters' kanji and names: K<script size>\t<one character per code from 0x100>,
-- N<script size>\t<names|by|slot>.
local kanji, names = {}, {}
local data = reader.data("charset")
if not data then
    error(reader.game_id .. ".charset is missing: this game's kanji table is not published (see the profile's notes)")
end
for kind, key, value in data:gmatch("([KN])(%x+)\t([^\n]*)") do
    local list = {}
    if kind == "K" then
        for _, c in utf8.codes(value) do list[#list + 1] = utf8.char(c) end
        kanji[tonumber(key, 16)] = list
    else
        for name in value:gmatch("[^|]+") do list[#list + 1] = name end
        names[tonumber(key, 16)] = list
    end
end

local warned = {}
local function chapter_tables()
    local key = mem.u32(CHAPTER) or 0
    return kanji[key], names[key], key
end

local function warn_unknown(key)
    if warned[key] then return end
    warned[key] = true
    reader.warn(string.format("a chapter the table does not know (script size %X): its kanji read as 〓", key))
end

local function addr(link)
    return 0x80000000 | (link & 0xFFFFFF)
end

-- The page's glyphs as the game draws them: { index, x, y, character }, in the order revealed.
local function page_glyphs(chapter_kanji)
    local list = {}
    for page = 0, 2 do
        local head = PAGES + page * 8
        local tp = mem.u32(head + 4) or 0
        if (tp >> 24) ~= 0xE1 or (tp & 0x1F) ~= 0x10 + page then return nil end
        local a = addr(mem.u32(head) or 0)
        for _ = 1, 256 do
            if a < SPRITES or a >= SPRITE_END then break end
            local cmd = mem.u32(a + 4) or 0
            if (cmd >> 24) ~= 0x7E then break end
            local xy = mem.u32(a + 8) or 0
            local u, v = mem.u8(a + 12) or 0, mem.u8(a + 13) or 0
            local code = (v // 16) * 16 + u // 16
            local ch
            if page == 0 then
                ch = FIXED[code] or "〓"
            else
                ch = chapter_kanji and chapter_kanji[(page - 1) * 256 + code + 1] or "〓"
            end
            list[#list + 1] = { (a - SPRITES) // 16, xy & 0xFFFF, xy >> 16, ch }
            a = addr(mem.u32(a) or 0)
        end
    end
    table.sort(list, function(p, q) return p[1] < q[1] end)
    return list
end

local function speaker(list)
    if ((mem.u32(NAME_QUAD + 4) or 0) & 0xFFFFFF) == 0 then return nil end
    local u, v = mem.u8(NAME_QUAD + 8) or 0, mem.u8(NAME_QUAD + 9) or 0
    local slot = (v // 16) * 2 + (u >= 128 and 1 or 0)
    return list and list[slot + 1]
end

local said = 0        -- glyphs of the page reported
local windows = 0
local first = nil     -- the page's first glyph, to see a new page
local still = 0       -- frames the page has not grown

local function clear_page()
    for n = 1, windows do reader.layout("page" .. n, nil) end
    windows, said, first, still = 0, 0, nil, 0
end

local function emit(list, from, who)
    local chars, cells = {}, {}
    for i = from, #list do
        local g = list[i]
        if i > from and g[3] ~= list[i - 1][3] then
            chars[#chars + 1] = "\n"; cells[#cells + 1] = false
        end
        local width = CELL
        local nxt = list[i + 1]
        if nxt and nxt[3] == g[3] and nxt[2] > g[2] and nxt[2] - g[2] < CELL then width = nxt[2] - g[2] end
        if g[4] ~= "　" then
            chars[#chars + 1] = g[4]
            cells[#cells + 1] = { g[2], g[3] + SHIFT, width, CELL }
        end
    end
    local body = table.concat(chars):gsub("^\n+", ""):gsub("\n+$", "")
    if body == "" then return end
    windows = windows + 1
    local window = "page" .. windows
    local w, h = reader.picture()
    local event = { text = body, window = window, id = text.hash(body) }
    if who then event.speaker = who end
    reader.emit(event)
    reader.layout(window, { space = { w or 320, h or 240 }, glyphs = cells })
end

local last_n = 0
reader.on_frame(function()
    local table_k, table_n, key = chapter_tables()
    local list = page_glyphs(table_k)
    if not list or #list == 0 then
        if windows > 0 or said > 0 then clear_page() end
        last_n = 0
        return
    end
    if not table_k then warn_unknown(key) end
    local page_key = string.format("%d,%d,%s", list[1][2], list[1][3], list[1][4])
    if page_key ~= first or #list < said then
        clear_page()
        first = page_key
    end
    if #list == last_n then still = still + 1 else still = 0 end
    last_n = #list
    -- What is out once the game waits for ○ (or has written nothing more for two seconds).
    local waiting = (mem.u8(ARROW) or 0) >= 0x60
    if #list > said and (waiting or still >= 120) then
        emit(list, said + 1, speaker(table_n))
        said = #list
    end
end)

reader.on_state_loaded(function()
    clear_page()
    last_n = 0
end)
