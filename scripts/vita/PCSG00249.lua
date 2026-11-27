-- reader: no hooks
-- reader: api 2
-- reader: title WHITE ALBUM 2 幸せの向こう側 (White Album 2)
-- reader: reads Dialogue (ADV and NVL), speakers, furigana, and choices
-- reader: version PCSG00249, 1.00
-- reader: touch press
-- WHITE ALBUM 2 幸せの向こう側 (Aquaplus / Leaf, PS Vita, 2013), PCSG00249 v1.00,
-- eboot.bin module NID 2F62598B.
--
-- Everything is read once a frame from the data segment (PT_LOAD[1] at 0x81079000 in Vita3K,
-- or reader.module("data") on a real Vita); no hooks are installed.
--
-- Message struct at MSG (0x81452ec0):
--   +0x000  u32 active (1 while a message window is live)
--   +0x004  u32 state  (0/1 typing, 2 closed/transition, 3 waiting for button, 4 fast-skip,
--                       6 hidden by ×, 8 unhiding)
--   +0x024  u32 nvl    (0 = ADV bottom window, non-zero = NVL full-screen page)
--   +0x038  char[0x400] ADV line or accumulated NVL page (Shift-JIS, with Leaf tags)
--   +0x438  char[0x200] newest chunk in NVL mode
--   +0x650  char[0x400] full current window text including \k continuations
--   +0xa54  char[0x40]  speaker name (Shift-JIS), shown when +0xa98 ~= 0
--   +0xa98  u32 speaker_visible
--
-- Text objects at TEXT_OBJS (0x81db36f8, stride 0x34):
--   object 0 is the live message text (+0x0c pointer to current string, +0x01 font size)
-- Display layers at LAYERS (0x81db50f8, stride 0x108):
--   layer 0x444 is the live message text (+0x01 visible, +0x90 f32 x, +0xa0 f32 y)
--   layers 0x475..0x47c are the choice option text sprites
--
-- Choice struct at CHOICE (0x814a1f3c):
--   +0x000  u32 active (non-zero while a choice is up; GAME_MODE stays 5, or 9 in a special case)
--   +0x014  u32 count  (1..8)
--   +0x01c  char[8][0x100] choice strings (Shift-JIS, prefixed with fullwidth "１．" etc.)
--   +0x10a4 u32[8] locked flags (0x814a2fe0: 0 = selectable, 1 = locked/dimmed)
--   CHOICE_CUR (0x8107e600): s32 0-based cursor (-1 before D-pad moves it)
--
-- Suppression flags:
--   OVERLAY_BG (0x8144be2c): u32 non-zero while System Menu, Backlog, Save/Load or Options is open
--   GAME_MODE  (0x814cb658): u32 5 = ADV/NVL play (incl. choices), 9 = special choice, 11 = backlog, ...
--   SKIP_ACTIVE (0x8107d854): u32 non-zero while skip mode is running
--
-- Not read: pre-rendered opening/ending movies (mv01.mp4 etc.), system menus, backlog screen,
-- options, save/load, and bonus menus.

local BUILD = "2F62598B"
if reader.build_id ~= BUILD then
    error("this profile is for WHITE ALBUM 2, PCSG00249 1.00 (" .. BUILD ..
          "), the game is " .. tostring(reader.build_id))
end

local data = reader.module("data")
local DATA = data and data.base or (reader.base + 0x79000)

local SKIP_ACTIVE = DATA + 0x004854 -- 0x8107d854
local CHOICE_CUR  = DATA + 0x005600 -- 0x8107e600
local OVERLAY_BG  = DATA + 0x3d2e2c -- 0x8144be2c
local GLOBAL_FLG  = DATA + 0x3d87bc -- 0x814517bc: u32[] system clear flags (0 = IC, 5 = CC Setsuna -> Coda)
local MSG         = DATA + 0x3d9ec0 -- 0x81452ec0
local CHOICE      = DATA + 0x428f3c -- 0x814a1f3c
local GAME_MODE   = DATA + 0x452658 -- 0x814cb658
local TEXT_OBJS   = DATA + 0xd3a6f8 -- 0x81db36f8
local LAYERS      = DATA + 0xd3c0f8 -- 0x81db50f8

local MSG_ACTIVE, MSG_STATE, MSG_NVL = 0x000, 0x004, 0x024
local MSG_NAME, MSG_NAME_VIS = 0xa54, 0xa98
local TEXT_STRIDE, TEXT_SIZE, TEXT_PTR = 0x34, 0x01, 0x0c
local LAYER_STRIDE, LAYER_VIS, LAYER_X, LAYER_Y = 0x108, 0x01, 0x90, 0xa0
local LAYER_MSG = 0x444
local LAYER_CHOICE0 = 0x475
local CHOICE_ACTIVE, CHOICE_COUNT, CHOICE_TEXTS, CHOICE_STRIDE = 0x000, 0x014, 0x01c, 0x100

local MODE_PLAY, MODE_CHOICE = 5, 9
local STATE_WAIT = 3
local SHOWN_FRAMES = 3

-- Layout metrics in 960x544 units (from CreateText / 0x8100e214 & 0x81029282):
-- font size 28 inside 40px box ((40 - 28)/2 = 6px left pad), ruby headroom 14, row advance 42.
local DEFAULT_FONT = 28
local GLYPH_PAD_X = 6
local RUBY_HEADROOM = 14
local ROW_STEP = 42

local function usable(addr)
    return addr ~= nil and addr >= 0x81000000 and addr < 0xA0000000
end

local function is_sjis_lead(c)
    return (c >= 0x81 and c <= 0x9f) or (c >= 0xe0 and c <= 0xfc)
end

-- Decode Leaf text (Shift-JIS + <Rbase|ruby> / <Fnn> / <Cnn> / \n / \k / ~ ^ ` / 0xf040..42 dashes)
-- into text, ruby spans, and per-codepoint screen cells. If only_last_k is true, earlier \k
-- segments still advance the (x, y) cursor so cells of the newly revealed tail land on screen.
local function parse_leaf(raw, origin_x, origin_y, base_font, only_last_k)
    local b = reader.builder()
    local cells = {}
    local last_k = 0
    if only_last_k then
        local idx = 1
        while idx <= #raw do
            local c = raw:byte(idx)
            if is_sjis_lead(c) and idx < #raw then
                idx = idx + 2
            elseif c == 0x5c and idx < #raw then
                if raw:byte(idx + 1) == 0x6b then last_k = idx + 2 end
                idx = idx + 2
            else
                idx = idx + 1
            end
        end
    end

    local x, y = origin_x + GLYPH_PAD_X, origin_y + RUBY_HEADROOM
    local font = base_font or DEFAULT_FONT
    local stack = {}
    local pending_break = false
    local i = 1

    local function emitting()
        return (not only_last_k) or i >= last_k
    end

    local function add_char(ch, half)
        local w = half and (font * 0.5) or font
        if emitting() then
            if pending_break then
                b:add("\n")
                cells[#cells + 1] = false
                pending_break = false
            end
            b:add(ch)
            cells[#cells + 1] = { x, y, w, font }
        end
        x = x + w
    end

    local function newline()
        if emitting() and b:length() > 0 then
            pending_break = true
        end
        x = origin_x + GLYPH_PAD_X
        y = y + ROW_STEP
    end

    while i <= #raw do
        local c = raw:byte(i)
        if c == 0x0a then
            newline()
            i = i + 1
        elseif c == 0x5c and i < #raw then
            local n = raw:byte(i + 1)
            if n == 0x6e then -- \n
                newline()
            elseif n == 0x6b then -- \k
                -- inline key-wait marker
            elseif n == 0x5e or n == 0x5c or n == 0x3e or n == 0x3c or n == 0x7e or n == 0x7c then
                add_char(string.char(n), true)
            end
            i = i + 2
        elseif c == 0x3c and i < #raw then -- '<'
            local tag = raw:byte(i + 1)
            local lo = (tag >= 0x41 and tag <= 0x5a) and (tag + 0x20) or tag
            if lo == 0x72 then -- <Rbase|reading>
                stack[#stack + 1] = { kind = "ruby", start = b:length(), emitting = emitting() }
                i = i + 2
            elseif lo == 0x66 or lo == 0x63 or lo == 0x62 or lo == 0x6b or lo == 0x77 or
                   lo == 0x73 or lo == 0x64 or lo == 0x61 then
                local j = i + 2
                local num = 0
                local has_num = false
                while j <= #raw do
                    local d = raw:byte(j)
                    if d >= 0x30 and d <= 0x39 then
                        num = num * 10 + (d - 0x30)
                        has_num = true
                        j = j + 1
                    else
                        break
                    end
                end
                if j <= #raw and raw:byte(j) == 0x3a then j = j + 1 end
                if lo == 0x66 then
                    stack[#stack + 1] = { kind = "font", prev = font }
                    if has_num and num > 0 then font = num end
                else
                    stack[#stack + 1] = { kind = "other" }
                end
                i = j
            else
                i = i + 2
            end
        elseif c == 0x7c and #stack > 0 and stack[#stack].kind == "ruby" then -- '|'
            local close = raw:find(">", i + 1, true)
            local frame = stack[#stack]
            stack[#stack] = nil
            if close then
                local reading = text.sjis(raw:sub(i + 1, close - 1))
                local count = b:length() - frame.start
                if frame.emitting and count > 0 and #reading > 0 then
                    local spans = b:ruby()
                    spans[#spans + 1] = { frame.start, count, reading }
                end
                i = close + 1
            else
                i = i + 1
            end
        elseif c == 0x3e then -- '>'
            local frame = stack[#stack]
            if frame then
                stack[#stack] = nil
                if frame.kind == "font" then font = frame.prev end
            end
            i = i + 1
        elseif c == 0x7e then -- '~' -> ','
            add_char(",", true)
            i = i + 1
        elseif c == 0x5e then -- '^' -> ' '
            add_char(" ", true)
            i = i + 1
        elseif c == 0x60 then -- '`' -> "'"
            add_char("'", true)
            i = i + 1
        elseif c == 0xf0 and i < #raw then
            local c2 = raw:byte(i + 1)
            if c2 >= 0x40 and c2 <= 0x42 then
                add_char("―", false)
            end
            i = i + 2
        elseif is_sjis_lead(c) and i < #raw then
            add_char(text.sjis(raw:sub(i, i + 1)), false)
            i = i + 2
        elseif c >= 0x20 and c < 0x7f then
            add_char(string.char(c), true)
            i = i + 1
        elseif c >= 0xa1 and c <= 0xdf then
            add_char(text.sjis(raw:sub(i, i)), true)
            i = i + 1
        else
            i = i + 1
        end
    end

    return b:text(), b:ruby(), cells
end

local function layer_addr(id) return LAYERS + id * LAYER_STRIDE end
local function text_obj_addr(idx) return TEXT_OBJS + idx * TEXT_STRIDE end

local msg_shown_key, msg_stood = nil, 0
local msg_emitted_key = nil
local choice_shown_key, choice_stood = nil, 0
local choice_emitted_key = nil
local last_cursor = nil

local function withdraw_msg()
    if msg_shown_key then
        reader.layout("message", nil)
        msg_shown_key = nil
    end
    msg_stood = 0
end

local function withdraw_choice(clear_emitted)
    if choice_shown_key then
        reader.layout("choice", nil)
        choice_shown_key = nil
    end
    if clear_emitted then
        choice_emitted_key = nil
    end
    if last_cursor ~= nil and reader.cursor then
        reader.cursor(nil)
        last_cursor = nil
    end
    choice_stood = 0
end

reader.on_frame(function()
    local overlay = mem.u32(OVERLAY_BG) or 0
    local mode = mem.u32(GAME_MODE) or 0
    local skipping = (mem.u32(SKIP_ACTIVE) or 0) ~= 0

    if overlay ~= 0 or skipping then
        withdraw_msg()
        withdraw_choice(false)
        return
    end

    -- 1. Choices (normal choices keep mode == 5 while CHOICE.active == 1; mode == 9 is a special case)
    local ch_active = (mem.u32(CHOICE + CHOICE_ACTIVE) or 0) ~= 0
    local ch_vis = (mem.u8(layer_addr(LAYER_CHOICE0) + LAYER_VIS) or 0) ~= 0
    if (mode == MODE_PLAY or mode == MODE_CHOICE) and ch_active and ch_vis then
        local count = mem.u32(CHOICE + CHOICE_COUNT) or 0
        if count >= 1 and count <= 8 then
            local raw_items = {}
            for k = 0, count - 1 do
                raw_items[#raw_items + 1] = mem.cstr(CHOICE + CHOICE_TEXTS + k * CHOICE_STRIDE, CHOICE_STRIDE) or ""
            end
            local ckey = table.concat(raw_items, "\0")
            if ckey ~= choice_shown_key then
                choice_stood = choice_stood + 1
                if choice_stood >= SHOWN_FRAMES then
                    choice_stood = 0
                    choice_shown_key = ckey
                    local lines, cells = {}, {}
                    for k = 0, count - 1 do
                        local la = layer_addr(LAYER_CHOICE0 + k)
                        local lx = mem.f32(la + LAYER_X) or 158
                        local ly = mem.f32(la + LAYER_Y) or (134 + k * 84)
                        -- Choice sprites draw 28px glyphs at (lx + 14, ly + 20) in 960x544 space.
                        local txt, _, c = parse_leaf(raw_items[k + 1], lx + 8, ly + 6, DEFAULT_FONT, false)
                        if #lines > 0 then cells[#cells + 1] = false end
                        lines[#lines + 1] = txt
                        for _, cell in ipairs(c) do cells[#cells + 1] = cell end
                    end
                    local full = table.concat(lines, "\n")
                    if #full > 0 then
                        if ckey ~= choice_emitted_key then
                            choice_emitted_key = ckey
                            reader.emit{
                                text = full,
                                channel = "choice",
                                window = "choice",
                                id = "choice:" .. text.hash(ckey),
                            }
                        end
                        reader.layout("choice", { space = { 960, 544 }, glyphs = cells })
                    end
                end
            end
            if choice_shown_key then
                local cur = mem.u32(CHOICE_CUR) or 0xffffffff
                if cur >= count then cur = -1 end
                if cur ~= last_cursor and reader.cursor then
                    reader.cursor(cur)
                    last_cursor = cur
                end
            end
        end
    else
        withdraw_choice(not ch_active)
    end

    -- 2. Message window (ADV or NVL)
    if mode ~= MODE_PLAY and mode ~= MODE_CHOICE then
        withdraw_msg()
        return
    end
    local active = (mem.u32(MSG + MSG_ACTIVE) or 0) ~= 0
    local state = mem.u32(MSG + MSG_STATE) or 0
    local la = layer_addr(LAYER_MSG)
    local vis = (mem.u8(la + LAYER_VIS) or 0) ~= 0
    if not active or state ~= STATE_WAIT or not vis then
        withdraw_msg()
        return
    end

    local t0 = text_obj_addr(0)
    local ptr = mem.u32(t0 + TEXT_PTR)
    if not usable(ptr) then
        withdraw_msg()
        return
    end
    local raw = mem.cstr(ptr, 1024) or ""
    if #raw == 0 then
        withdraw_msg()
        return
    end

    local nvl = (mem.u32(MSG + MSG_NVL) or 0) ~= 0
    local lx = mem.f32(la + LAYER_X) or (nvl and 88 or 116)
    local ly = mem.f32(la + LAYER_Y) or (nvl and 14 or 392)
    local font = mem.u8(t0 + TEXT_SIZE)
    if not font or font < 8 or font > 64 then font = DEFAULT_FONT end

    local speaker = nil
    if not nvl and (mem.u32(MSG + MSG_NAME_VIS) or 0) ~= 0 then
        local sraw = mem.cstr(MSG + MSG_NAME, 64) or ""
        if #sraw > 0 then speaker = text.sjis(sraw) end
    end

    local key = string.format("%d:%d:%d:%s:%s", nvl and 1 or 0, math.floor(lx), math.floor(ly), speaker or "", raw)
    if key == msg_shown_key then return end

    msg_stood = msg_stood + 1
    if msg_stood < SHOWN_FRAMES then return end
    msg_stood = 0
    msg_shown_key = key

    local line, ruby, cells = parse_leaf(raw, lx, ly, font, not nvl)
    if #line == 0 then return end

    if key ~= msg_emitted_key then
        msg_emitted_key = key
        reader.emit{ text = line, ruby = ruby, speaker = speaker, window = "message" }
    end
    reader.layout("message", { space = { 960, 544 }, glyphs = cells })
end)

local PROGRESS_FLAGS = { ic = 0, cc_setsuna = 5 }
if reader.progress then
    reader.progress{
        title = "Chapters",
        note = "Unlocks chapter selection on the title screen (saved when the game writes system data).",
        items = {
            { id = "ic",         label = "introductory chapter cleared (unlocks closing chapter)", group = "Chapters" },
            { id = "cc_setsuna", label = "closing chapter cleared (unlocks coda)",                 group = "Chapters" },
        },
        done = function(id)
            local idx = PROGRESS_FLAGS[id]
            return idx ~= nil and (mem.u32(GLOBAL_FLG + idx * 4) or 0) ~= 0
        end,
        mark = function(id, on)
            local idx = PROGRESS_FLAGS[id]
            if idx ~= nil then mem.w32(GLOBAL_FLG + idx * 4, on and 1 or 0) end
        end,
    }
end
