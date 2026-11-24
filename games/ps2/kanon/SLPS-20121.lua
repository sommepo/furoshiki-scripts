-- reader: no hooks
-- reader: title Kanon
-- reader: reads Dialogue, narration, speakers, and choices
-- reader: version SLPS-20121, disc version 1.02
-- reader: touch press
-- reader: buttons start square up down circle cross
-- Touch play's buttons (found in the harness): START the title's and the system menu (save,
-- load, settings), up and down for its lists and the choices, ○ to choose, × back out (in a
-- message it goes on and cuts the effect), □ the message history; △ shows the buttons.
--
-- Kanon (NEC Interchannel, PS2, 2002), SLPS-20121. Program 050D0F4F.
--
-- The script is plain Shift-JIS. When a message begins the game puts it, the player's name put
-- in and the script's commands taken out, into a buffer at a fixed place, with `$n` where it
-- broke a row because the row was full (22 characters). A speaker's name is the text before the
-- opening 「 (or （, 『: the game draws it so, on the same row). A word says what the message
-- window is doing: 3 while the message is being typed, 4 once it waits for the button. It keeps no
-- places for the characters that would outlast a message: they are drawn 24 apart from the
-- window's left edge, rows 27.5 apart (measured in pictures of the game).

local BUILD = "050D0F4F"
if reader.build_id ~= BUILD then
    error("this profile is for Kanon SLPS-20121 (program " .. BUILD .. "), the game is " ..
          tostring(reader.build_id))
end

local TEXT = 0x00234494       -- the message, Shift-JIS, ends with a zero
local TEXT_MAX = 512
local STATE = 0x00232e8c      -- 3: typing, 4: waiting for the button
local TYPED, WAITING = 3, 4
local CHOOSING = 0x002331d8   -- 1 while a choice waits for an answer
local ANSWER_CURSOR = 0x002331ec -- the answer lit, from 0 (the first is lit at once)
local ANSWERS = 0x00233248    -- how many answers the choice has; kept after it
local ANSWER_TEXT = 0x0023324c -- the answers, each in a buffer of its own
local ANSWER_SIZE = 50

-- Where the characters are, in the 640x448 picture (measured).
local LEFT, TOP = 45, 329
local STEP_X, NARROW, STEP_Y, HEIGHT = 24, 12, 27.5, 24
local ROW_FULL = 21           -- a row of 22 characters is full (one more may hang at its end)
local BOX = { 30, 318, 580, 100 } -- the message window
-- A speaker's words are in 「」, a thought in （）, a call from afar in 『』.
local CLOSING = { ["「"] = "」", ["（"] = "）", ["『"] = "』" }
local NAME_MAX = 10           -- characters of a speaker's name at most

-- Frames a message must have waited before it is reported: what a skip runs through is not.
local SHOWN_FRAMES = 4

local function is_lead(b)
    return (b >= 0x81 and b <= 0x9f) or (b >= 0xe0 and b <= 0xfc)
end

-- The game's own codes: from 0x989F on, where Shift-JIS has the second level of kanji, the
-- game's font has kanji of its own choosing in an order of its own (0x9950 is 頷, 0x98D2 栞).
-- Its table is made from the game and is not part of this script: reader.data("charset"),
-- a file SLPS-20121.charset beside it, a code (four hex digits) and its character to a line.
-- Without it those characters are reported as 〓.
local OWN_FIRST, OWN_LAST = 0x989f, 0x9ffc
local own = {}
local charset = reader.data and reader.data("charset")
if charset then
    for code, ch in charset:gmatch("(%x%x%x%x)[ \t]+([^\r\n]+)") do
        own[tonumber(code, 16)] = ch
    end
end
local MISSING = "〓"

local function character(pair)
    local code = pair:byte(1) * 256 + pair:byte(2)
    if code >= OWN_FIRST and code <= OWN_LAST then return own[code] or MISSING end
    return text.sjis(pair)
end

local IDEOGRAPHIC_SPACE = "\x81\x40"

-- The message's characters with their cells. `$n` (the game's row break) begins a new row
-- and is no character: the rows of a message are one text. A row (the first too) may be set in
-- with ideographic spaces (three under 祐一「, more for a line centred), which are left out.
local function characters(raw)
    local out, at, x, row = {}, 1, 0, 0
    local indent = true -- spaces that set the first row in are no text either
    while at <= #raw do
        local b = raw:byte(at)
        if raw:sub(at, at + 1) == "$n" then
            -- A row that ended short was broken by the script, not the game: a line break.
            if x < ROW_FULL * STEP_X and #out > 0 and out[#out].text ~= "\n" then
                out[#out + 1] = { text = "\n", cell = false }
            end
            x, row = 0, row + 1
            indent = true
            at = at + 2
        elseif indent and raw:sub(at, at + 1) == IDEOGRAPHIC_SPACE then
            x = x + STEP_X
            at = at + 2
        elseif is_lead(b) and at < #raw then
            indent = false
            out[#out + 1] = { text = character(raw:sub(at, at + 1)),
                              cell = { LEFT + x, TOP + row * STEP_Y, STEP_X, HEIGHT } }
            x = x + STEP_X
            at = at + 2
        else
            indent = false
            out[#out + 1] = { text = string.char(b),
                              cell = { LEFT + x, TOP + row * STEP_Y, NARROW, HEIGHT } }
            x = x + NARROW
            at = at + 1
        end
    end
    return out
end

local shown_raw    -- the message that was reported, as bytes
local reported = 0 -- how many of its characters were
local parts = 0
local waited = 0
local windows = {}

local function withdraw()
    for name in pairs(windows) do reader.layout(name, nil) end
    windows = {}
end

local function reset()
    withdraw()
    shown_raw, reported, parts, waited = nil, 0, 0, 0
end

-- A choice: its answers stand in the message window's rows, one to a row, in place of the
-- message. One event, an answer to a line.
local answers_shown, choice_waited, cursor_said = nil, 0, nil

local function choice()
    local number = mem.u32(ANSWERS) or 0
    if mem.u32(CHOOSING) ~= 1 or number < 1 or number > 8 then
        choice_waited = 0
        if answers_shown then
            reader.layout("choice", nil)
            answers_shown = nil
        end
        if cursor_said ~= nil then
            cursor_said = nil
            if reader.cursor then reader.cursor(nil) end
        end
        return
    end
    local raw = mem.read(ANSWER_TEXT, number * ANSWER_SIZE)
    if not raw then return end
    if raw ~= answers_shown then
        choice_waited = choice_waited + 1
        if choice_waited < SHOWN_FRAMES then return end
        local b, cells = reader.builder(), {}
        for row = 1, number do
            local answer = raw:sub((row - 1) * ANSWER_SIZE + 1, row * ANSWER_SIZE):match("^[^%z]*")
            if row > 1 then
                b:add("\n")
                cells[#cells + 1] = false
            end
            for _, c in ipairs(characters(answer)) do
                if c.cell then
                    b:add(c.text)
                    cells[#cells + 1] = { c.cell[1], c.cell[2] + (row - 1) * STEP_Y, c.cell[3], c.cell[4] }
                end
            end
        end
        answers_shown = raw
        reader.emit{ text = b:text(), channel = "choice", window = "choice",
                     id = "choice:" .. text.hash(raw) }
        reader.layout("choice", { space = { 640, 448 }, box = BOX, glyphs = cells })
    end
    -- Touch play: the answer the cursor is on.
    local at = mem.u32(ANSWER_CURSOR) or 0
    if at >= number then at = -1 end
    if at ~= cursor_said then
        cursor_said = at
        if reader.cursor then reader.cursor(at) end
    end
end

reader.on_frame(function()
    choice()
    local state = mem.u32(STATE)
    if state ~= TYPED and state ~= WAITING then
        if shown_raw then reset() end
        return
    end
    local buffer = mem.read(TEXT, TEXT_MAX)
    if not buffer then return end
    local raw = buffer:match("^[^%z]*")
    if raw == "" then return end
    if state ~= WAITING then
        waited = 0
        return
    end
    if raw == shown_raw then return end
    waited = waited + 1
    if waited < SHOWN_FRAMES then return end
    waited = 0

    local chars = characters(raw)
    local count = #chars
    -- A message that goes on after a wait begins with the text before: only what is new is
    -- reported.
    local first = 1
    if shown_raw and #raw > #shown_raw and raw:sub(1, #shown_raw) == shown_raw then
        first = reported + 1
    else
        withdraw()
        parts = 0
    end

    local speaker, said = nil, 1
    if count > 2 then
        for index = 2, math.min(count - 1, NAME_MAX + 1) do
            if CLOSING[chars[index].text] == chars[count].text then
                speaker = {}
                for n = 1, index - 1 do speaker[n] = chars[n].text end
                speaker = table.concat(speaker)
                said = index
                break
            end
        end
    end
    -- The name stands in the window; only the words said are the text.
    if first < said then first = said end
    if first > said then speaker = nil end -- said already, with the first part

    local b, cells = reader.builder(), {}
    for index = first, count do
        b:add(chars[index].text)
        cells[#cells + 1] = chars[index].cell
    end
    shown_raw, reported = raw, count
    if #cells == 0 then return end
    parts = parts + 1
    local window = "message" .. parts
    reader.emit{ text = b:text(), speaker = speaker, window = window,
                 id = text.hash(raw) .. ":" .. parts }
    reader.layout(window, { space = { 640, 448 }, box = BOX, glyphs = cells })
    windows[window] = true
end)

reader.on_state_loaded(function()
    reset()
    if answers_shown then reader.layout("choice", nil) end
    answers_shown, choice_waited, cursor_said = nil, 0, nil
    if reader.cursor then reader.cursor(nil) end
end)
