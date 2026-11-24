-- reader: no hooks
-- reader: title STEINS;GATE ELITE
-- reader: reads Dialogue, narration, speakers, furigana, and phone emails
-- reader: version Japanese release (game card), version 1.0.0
-- reader: touch press
-- STEINS;GATE ELITE, Switch, Japanese release.
-- Written for main build 1C225A74ED7AAED6C1A4947E1810129F (the game card's program, 1.0.0).
--
-- The game runs on its maker's engine for visual novels (MAGES), which keeps everything in
-- fixed places of the program's memory. The message on screen is a list of 16-bit values, one
-- per character or command, with lists beside it that have each character's place on screen,
-- its size and the moment it appears. A state says whether a message is being typed, waits
-- for the button, fades out or is gone. This profile reads those once a frame: nothing is
-- hooked, so the game runs natively (first line of this file).
--
-- The characters are not Unicode: a value is the number of a cell in the game's font
-- picture, and the cells are in an order of the game's own. Which character each cell shows
-- is a table made from the game's font, which is not part of this profile or of the
-- repository: it is a data file, 0100F160092D2000.charset, one line per cell in the cells'
-- order (a line may hold two characters: some cells do). Without it the profile cannot read
-- anything and says so. docs/reader/games/sge.md says how the table was made.
--
-- A mail on the phone is not in such a list: the game draws it straight from its script. The
-- profile reads which mail the phone shows and takes its subject, sender and text from the
-- loaded mail script. It does not know where the phone draws the characters, so a mail comes
-- without places on screen (it can be read and looked up in the reader's own panel or backlog).
--
-- A message is read once it has been up for a moment, so what the game's skip runs through
-- is not read.
--
-- Covered: narration and dialogue with the speaker's name (which the game itself does not
-- show) and furigana; mails received, the replies offered and the reply sent. Not covered:
-- the backlog, the TIPS list, the menus, calls and the phone's other screens.

local BUILD = "1C225A74ED7AAED6C1A4947E1810129F"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The message window (offsets into main).
local MSG_STATE = 0x89480c   -- 1 typing, 2 waiting for the button, 3 fading out, 4 gone
local MSG_COUNT = 0x687024   -- how many values the message has
local MSG_TOKENS = 0x687028  -- the values, 16 bits each
local MSG_SIZE = 0x68a868    -- per value: width and height in the font, then as drawn (4 x u32)
local MSG_POS = 0x695128     -- per value: left and top on screen (2 x u32)
local MSG_MAX = 2400
local WINDOW_ALPHA = 0x17e92a4 -- 0x100 while the window is shown, 0 when the player hid it
local MENU_OPEN = 0x674500     -- 1 while the backlog or the system menu covers the picture
local PLAY_MODE = 0x17e796c    -- 1 in skip mode (4 in auto mode)
local SPACE = { 1280, 720 }    -- the places are in these units, handheld and docked

-- Commands among the values (0x8000 + the script's command byte).
local T_LINE_BREAK = 0x8000
local T_NAME = 0x8001
local T_TEXT = 0x8002
local T_END = 0x8003
local T_RUBY_BASE = 0x8009
local T_RUBY_TEXT = 0x800a
local T_RUBY_END = 0x800b

-- The phone.
local PHONE_ALPHA = 0x110927c  -- above 0 while the phone is on screen
local PHONE_MAIL_UP = 0x110928c -- 1 while it shows a mail
local PHONE_MAIL = 0x1109298   -- the mail it shows (a received one)
local TRIGGER_MODE = 0x98ec88  -- 0xd: a received mail with replies to choose, 0xe: a reply, 0xff: none
local TRIGGER_COUNT = 0x98ec8c -- how many replies
local TRIGGER_MAIL = 0x98ec90  -- the mail they answer
local TRIGGER_REPLIES = 0x98ec94 -- the replies (mails), 4 bytes each
local SCRATCH_MAIL = 0x17e0e7c -- the reply the script has put on the phone (a variable of its own)
local MAIL_COUNT = 653
local SCRIPTS = 0x17e9470      -- the loaded scripts: 8-byte pointers
local SCRIPT_SLOTS = 32
-- The mail script, as it is told from the others: where its table of strings begins and ends.
local MAIL_STRINGS, MAIL_STRINGS_END = 0x5b60, 0x7bb0
local MAIL_FIRST_STRING = 109  -- a mail is three strings from here on: subject, name, text

-- How long a message must have been up before it is read (frames).
local HOLD = 8

-- ---- The character table ----

local charset
do
    local data = reader.data("charset")
    if not data then
        error("the character table of this game is missing: 0100F160092D2000.charset "
            .. "(see docs/reader/games/sge.md)")
    end
    charset = {}
    local index = 0
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        charset[index] = line
        index = index + 1
    end
    if index < 7000 then
        error("the character table of this game is cut short: " .. index .. " lines")
    end
end

local function char_of(value)
    local c = charset[value]
    if c and c ~= "" then return c end
    return "\u{3013}" -- a cell the table has nothing for: 〓
end

-- ---- The message window ----

--- A message's values taken apart: speaker, text with its ruby, and for every code point of
--- the text the number of the value it comes from (0 for a line break).
local function parse(raw, count)
    local values = { string.unpack("<" .. string.rep("H", count), raw) }
    local speaker
    local i = 1
    if values[1] == T_NAME then
        local name = {}
        i = 2
        while i <= count and values[i] ~= T_TEXT do
            if values[i] < 0x8000 then name[#name + 1] = char_of(values[i]) end
            i = i + 1
        end
        i = i + 1
        speaker = table.concat(name)
        if speaker == "" then speaker = nil end
    end
    local b = reader.builder()
    local sources = {}
    local text_len = text.len
    local function add_text(piece, source)
        b:add(piece)
        for _ = 1, text_len(piece) do sources[#sources + 1] = source end
    end
    while i <= count do
        local v = values[i]
        if v == T_END then
            break
        elseif v == T_LINE_BREAK then
            add_text("\n", 0)
        elseif v == T_RUBY_BASE then
            -- Base characters up to the reading, the reading up to the end. A base without a
            -- reading is a word the game marks (a link in a mail); it is plain text here.
            local base_text, base_sources, reading = {}, {}, {}
            i = i + 1
            while i <= count and values[i] ~= T_RUBY_TEXT and values[i] ~= T_RUBY_END
                and values[i] ~= T_END do
                if values[i] < 0x8000 then
                    local c = char_of(values[i])
                    base_text[#base_text + 1] = c
                    for _ = 1, text_len(c) do base_sources[#base_sources + 1] = i end
                end
                i = i + 1
            end
            if values[i] == T_RUBY_TEXT then
                i = i + 1
                while i <= count and values[i] ~= T_RUBY_END and values[i] ~= T_END do
                    if values[i] < 0x8000 then reading[#reading + 1] = char_of(values[i]) end
                    i = i + 1
                end
            end
            if #reading > 0 then
                b:add_ruby(table.concat(base_text), table.concat(reading))
            else
                b:add(table.concat(base_text))
            end
            for _, source in ipairs(base_sources) do sources[#sources + 1] = source end
            if values[i] == T_END then break end
        elseif v < 0x8000 then
            add_text(char_of(v), i)
        end
        i = i + 1
    end
    return speaker, b, sources
end

--- Where the text's characters are: a cell per code point from the value's place and size as
--- drawn. A value that is not drawn (a command's argument, a character of zero width) has none.
local function cells_of(sources)
    local glyphs = {}
    local left, top, right, bottom
    for k, source in ipairs(sources) do
        local cell = false
        if source > 0 then
            local at = (source - 1)
            local size = mem.read(base + MSG_SIZE + at * 16 + 8, 8)
            local pos = mem.read(base + MSG_POS + at * 8, 8)
            if #size == 8 and #pos == 8 then
                local w, h = string.unpack("<I4I4", size)
                local x, y = string.unpack("<I4I4", pos)
                if w > 0 and h > 0 and w <= 200 and h <= 200 and x < 4000 and y < 4000 then
                    cell = { x, y, w, h }
                    left = math.min(left or x, x)
                    top = math.min(top or y, y)
                    right = math.max(right or x + w, x + w)
                    bottom = math.max(bottom or y + h, y + h)
                end
            end
        end
        glyphs[k] = cell
    end
    local box
    if left then
        box = { left - 8, top - 8, right - left + 16, bottom - top + 16 }
    end
    return glyphs, box
end

local message = {
    raw = nil,       -- the values of the message that is up
    frames = 0,      -- for how many frames it has been
    emitted = nil,   -- the values of the message last read
    gap = true,      -- the window was gone since
    sources = nil,   -- of the message read: where each code point comes from
    placed = nil,    -- what the layout was made from, or nil while none is reported
}

local function withdraw_message()
    if message.placed then
        reader.layout("message", nil)
        message.placed = nil
    end
end

local function message_frame()
    local state = mem.u32(base + MSG_STATE)
    local count = mem.u32(base + MSG_COUNT)
    if (state ~= 1 and state ~= 2) or not count or count == 0 or count > MSG_MAX then
        if state ~= 1 and state ~= 2 then
            message.gap = true
        end
        message.raw, message.frames = nil, 0
        withdraw_message()
        return
    end
    local raw = mem.read(base + MSG_TOKENS, count * 2)
    if #raw ~= count * 2 then return end
    if raw ~= message.raw then
        message.raw, message.frames = raw, 0
    end
    message.frames = message.frames + 1

    if message.frames >= HOLD and mem.u32(base + PLAY_MODE) ~= 1
        and (raw ~= message.emitted or message.gap) then
        local speaker, b, sources = parse(raw, count)
        local line = b:text()
        message.emitted, message.gap = raw, false
        message.sources = sources
        message.placed = nil
        reader.layout("message", nil)
        if line ~= "" then
            reader.emit{ text = line, speaker = speaker, ruby = b:ruby(), window = "message" }
        else
            message.sources = nil
        end
    end

    -- The places, while the message read is the one on screen and nothing covers it.
    local shown = message.sources and raw == message.emitted
        and (mem.u32(base + WINDOW_ALPHA) or 0) > 0 and mem.u32(base + MENU_OPEN) == 0
    if not shown then
        withdraw_message()
        return
    end
    local key = raw .. mem.read(base + MSG_POS, 16)
    if message.placed ~= key then
        local glyphs, box = cells_of(message.sources)
        reader.layout("message", { space = SPACE, box = box, glyphs = glyphs })
        message.placed = key
    end
end

-- ---- Mails ----

local mail_script -- where the mail script is loaded, once found

local function find_mail_script()
    if mail_script and mem.u32(mail_script) == 0x00334353
        and mem.u32(mail_script + 4) == MAIL_STRINGS then
        return mail_script
    end
    mail_script = nil
    for slot = 0, SCRIPT_SLOTS - 1 do
        local p = mem.u64(base + SCRIPTS + slot * 8)
        if p and p ~= 0 and mem.u32(p) == 0x00334353 -- "SC3"
            and mem.u32(p + 4) == MAIL_STRINGS and mem.u32(p + 8) == MAIL_STRINGS_END then
            mail_script = p
            return p
        end
    end
    return nil
end

--- A string of the mail script as text: two bytes per character, commands below 0x80.
local function script_string(script, number)
    local count = (MAIL_STRINGS_END - MAIL_STRINGS) // 4
    if number < 0 or number >= count then return nil end
    local offset = mem.u32(script + MAIL_STRINGS + number * 4)
    if not offset or offset == 0 then return nil end
    local raw = mem.read(script + offset, 4096)
    local out = {}
    local i = 1
    while i <= #raw do
        local byte = raw:byte(i)
        if byte == 0xff then
            break
        elseif byte >= 0x80 then
            local low = raw:byte(i + 1)
            if not low then break end
            out[#out + 1] = char_of(((byte & 0x7f) << 8) | low)
            i = i + 2
        elseif byte == 0x00 then
            out[#out + 1] = "\n"
            i = i + 1
        elseif byte == 0x04 or byte == 0x15 then
            -- A command with an expression: up to its zero byte, numbers keeping their bytes.
            i = i + 1
            while i <= #raw and raw:byte(i) ~= 0 do
                local c = raw:byte(i)
                if c >= 0x80 then
                    local kind = c & 0x60
                    i = i + (kind == 0 and 1 or kind == 0x20 and 2 or kind == 0x40 and 3 or 5)
                else
                    i = i + 2
                end
            end
            i = i + 1
        elseif byte == 0x0c or byte == 0x11 or byte == 0x12 or byte == 0x13 then
            i = i + 3 -- a command with two bytes
        else
            i = i + 1 -- a command by itself (a marked word's start and end among them)
        end
    end
    return table.concat(out)
end

local phone = {
    shown = nil,   -- the mail that is up
    frames = 0,
    read = {},     -- the mails read since the phone came up: going back and forth between a
                   -- mail and its replies does not read them again
    reply = nil,   -- the reply that is up, kept while the phone still shows it
    trigger = nil, -- the mail that reply answers
}

local function mail_frame()
    local alpha = mem.u32(base + PHONE_ALPHA) or 0
    if alpha == 0 or mem.u32(base + PHONE_MAIL_UP) ~= 1 then
        phone.shown, phone.frames, phone.reply, phone.trigger = nil, 0, nil, nil
        if next(phone.read) then phone.read = {} end
        return
    end
    local shown = mem.u32(base + PHONE_MAIL)
    local mode = mem.u32(base + TRIGGER_MODE)
    local trigger = mem.u32(base + TRIGGER_MAIL)
    if trigger ~= phone.trigger or mode == 0xd then
        phone.reply, phone.trigger = nil, trigger
    end
    if (mode == 0xe or mode == 0xff) and trigger == shown then
        -- A reply is put up by the script, which names it in a variable of its own: taken for
        -- one when it is among the replies this mail offers.
        local candidate = mem.u32(base + SCRATCH_MAIL)
        local replies = math.min(mem.u32(base + TRIGGER_COUNT) or 0, 8)
        for k = 0, replies - 1 do
            if mem.u32(base + TRIGGER_REPLIES + k * 4) == candidate then
                phone.reply = candidate
            end
        end
        if phone.reply then shown = phone.reply end
    end
    if not shown or shown >= MAIL_COUNT then return end
    if shown ~= phone.shown then
        phone.shown, phone.frames = shown, 0
    end
    phone.frames = phone.frames + 1
    if phone.frames < HOLD or phone.read[shown] then return end
    phone.read[shown] = true

    local script = find_mail_script()
    if not script then return end
    local first = MAIL_FIRST_STRING + shown * 3
    local subject = script_string(script, first)
    local name = script_string(script, first + 1)
    local body = script_string(script, first + 2)
    if not body or body == "" then return end
    local lines = body
    if subject and subject ~= "" then lines = subject .. "\n" .. body end
    local is_reply = phone.reply == shown
    reader.emit{
        text = lines,
        -- A received mail is its sender's; a reply is the player's, to that name.
        speaker = (not is_reply and name ~= "") and name or nil,
        channel = "mail",
        id = "mail-" .. shown,
        window = "mail",
        meta = { mail = shown, kind = is_reply and "reply" or "received", to = is_reply and name or nil },
    }
end

reader.on_frame(function()
    message_frame()
    mail_frame()
end)
