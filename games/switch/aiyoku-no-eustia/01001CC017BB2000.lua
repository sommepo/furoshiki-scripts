-- reader: title 穢翼のユースティア (Aiyoku no Eustia)
-- reader: reads Dialogue, narration, speakers, furigana, and choices
-- reader: version Base game (version 0)
-- reader: touch game
-- 穢翼のユースティア (Aiyoku no Eustia, August), Switch, 2022. Written for main build
-- D04A06CF236A6A3BBD657495C8BF1792 (the base game, v0).
--
-- The game's script interpreter hands every page of the message window, and the speaker's
-- name before it, to two calls of one routine, as the script's own text with its tags in it
-- (@v voice, @r ruby, @k wait, @n new line...). The places of those calls are the ones a
-- community Agent script (Koukdw's, for texthookers) hooks; this profile hooks the same two
-- places and the routine that takes the answers of a choice, decodes the tags itself, and
-- reports a page once it has stayed for a few frames, so that what a skip runs through is
-- not read. Whether the window is up, and whether the text is the window's, is read from the
-- game's text objects each frame. Where each character is drawn is worked out from the
-- window's grid (the game sets its text on a grid of fixed cells), not read from the game.
-- Notes: docs/reader/games/eustia.md.

local BUILD = "D04A06CF236A6A3BBD657495C8BF1792"
if reader.build_id:sub(1, #BUILD) ~= BUILD then
    error("this profile is for the base game (main build " .. BUILD .. "), the game is build " ..
          tostring(reader.build_id))
end
local base = reader.base

-- Code (offsets into main).
local AT_NAME = 0x4BAFD0    -- x0: the speaker's name of the next page, "" for narration
local AT_PAGE = 0x4BAFE8    -- x0: the page's text, with its tags
local AT_CHOICE = 0x4CC43C  -- x0: the text of one answer of a choice, called once per answer

-- Timings, in frames.
local STEADY = 8            -- a page counts once it has been up this long (a skip shows one a frame)
local CHOICE_GATHER = 4     -- the answers of a choice come one call each, close together
local HIDDEN_FOR = 3        -- the window counts as hidden after this long (it blinks between pages)

-- The message window's grid, in pixels of a 1280x720 picture (scaled for 1920x1080).
local GRID = {
    x = 321,        -- left edge of the first cell
    y = 568,        -- top of the first row of text (the speaker's name is the row above)
    w = 29,         -- a cell's width: every character takes one
    h = 34,         -- a cell's height
    pitch = 40,     -- from one row to the next
    columns = 26,   -- cells in a row
    box = { 300, 520, 820, 175 },  -- the window's text area, taps there never reach the game
}

-- Characters that may not begin a row: the game lets them hang past the last cell.
local NO_START = {}
for _, c in utf8.codes("、。，．」』）】〉》！？…‥ー") do NO_START[c] = true end
-- Characters a dialogue line opens with: its next rows are indented by a cell.
local OPENERS = { [0x300C] = true, [0x300E] = true, [0xFF08] = true }  -- 「 『 （

---------------------------------------------------------------------------------------------
-- The script's tags

-- Decodes a page's text: the text as shown (rows separated by \n), its ruby, and the voice.
local function decode(raw)
    local b = reader.builder()
    local voice
    local i, n = 1, #raw
    local plain_from = 1
    local function flush(to)
        if to >= plain_from then b:add(raw:sub(plain_from, to)) end
    end
    while i <= n do
        if raw:byte(i) == 0x40 and i < n then  -- '@'
            flush(i - 1)
            local tag = raw:sub(i + 1, i + 1)
            local j = i + 2
            if tag == "v" or tag == "h" then           -- @vID voice, @hID: an ID of letters, digits, _
                local s, e = raw:find("^[%w_%-]+", j)
                if tag == "v" and s then voice = raw:sub(s, e) end
                j = e and e + 1 or j
            elseif tag == "s" or tag == "t" then       -- four digits
                j = j + 4
            elseif tag == "m" then                     -- two digits
                j = j + 2
            elseif tag == "n" then                     -- a new row
                b:add("\n")
            elseif tag == "r" then                     -- @rBASE@READING@
                local s1 = raw:find("@", j, true)
                local s2 = s1 and raw:find("@", s1 + 1, true)
                if s2 then
                    b:add_ruby(raw:sub(j, s1 - 1), raw:sub(s1 + 1, s2 - 1))
                    j = s2 + 1
                end
            elseif tag == "I" then                     -- @I<digits>TEXT ... @I@: drawn alike
                if raw:sub(j, j) == "@" then
                    j = j + 1
                else
                    local _, e = raw:find("^%d+", j)
                    j = e and e + 1 or j
                end
            elseif tag == "@" then                     -- a lone '@' written twice
                b:add("@")
            end
            -- @k @p @a @b @d and anything else: a mark without text
            i = j
            plain_from = j
        else
            i = i + 1
        end
    end
    flush(n)
    return b:text(), b:ruby(), voice
end

---------------------------------------------------------------------------------------------
-- Where the characters are

local function scale()
    local w = reader.picture()
    return (w and w > 0) and w / 1280 or 1
end

-- One cell per code point of `text` (false for a row break), on the window's grid.
local function cells_of(text)
    local k = scale()
    local glyphs = {}
    local row, col = 0, 0
    local indent = 0
    local first = true
    for _, c in utf8.codes(text) do
        if c == 10 then
            glyphs[#glyphs + 1] = false
            row, col = row + 1, indent
        else
            if first and OPENERS[c] then indent = 1 end
            first = false
            if col >= GRID.columns and not NO_START[c] then
                row, col = row + 1, indent
            end
            glyphs[#glyphs + 1] = {
                (GRID.x + col * GRID.w) * k, (GRID.y + row * GRID.pitch) * k,
                GRID.w * k, GRID.h * k,
            }
            col = col + 1
        end
    end
    return glyphs
end

local function box()
    local k = scale()
    return { GRID.box[1] * k, GRID.box[2] * k, GRID.box[3] * k, GRID.box[4] * k }
end

---------------------------------------------------------------------------------------------
-- Whether the message window is shown

-- The message window draws its text with text objects (one class, its vtable at TEXT_VTABLE), which
-- main keeps in a table of slots (SLOTS, SLOT_COUNT of them); which slot holds the window's object
-- changes from scene to scene. Each object's byte at TEXT_SHOWN is 1 while it is up and 0 while
-- the window is hidden (B), under the system menu (Y), the backlog (X, up) and the save, load and
-- config screens.
local SLOTS = 0x74FC80
local SLOT_COUNT = 26
local TEXT_VTABLE = 0x5B8FF8
local TEXT_SHOWN = 0x16D
-- Where the object's text begins, in the game's own 1920x1080 units: the message window's text is
-- at WINDOW_AT; other text (the opening's lines in the middle of a black screen) is elsewhere and
-- is read without places, the grid being the window's.
local TEXT_X, TEXT_Y = 0x48, 0x4C
local WINDOW_AT = { 0x1E3, 0x348 }

-- Whether a text object is up, and whether that is the message window's.
local function window_shown()
    local shown = false
    for i = 0, SLOT_COUNT - 1 do
        local o = mem.u64(base + SLOTS + i * 8)
        if o and o ~= 0 and mem.u64(o) == base + TEXT_VTABLE and mem.u8(o + TEXT_SHOWN) == 1 then
            if mem.u32(o + TEXT_X) == WINDOW_AT[1] and mem.u32(o + TEXT_Y) == WINDOW_AT[2] then
                return true, true
            end
            shown = true
        end
    end
    return shown, false
end

---------------------------------------------------------------------------------------------
-- Pages

local speaker = nil   -- the name handed over for the next page
local pending = nil   -- the page last handed over, until it has stayed long enough
local page = nil      -- the page on screen: { text, glyphs }
local answers = nil   -- the choice: { list, last, emitted, glyphs }
local placed = {}     -- window -> its layout is up
local hidden_for = 0  -- frames the window has been away

local function place(window, glyphs)
    reader.layout(window, { space = { reader.picture() }, box = window == "message" and box() or nil,
                            glyphs = glyphs })
    placed[window] = true
end

local function unplace(window)
    if placed[window] then reader.layout(window, nil) end
    placed[window] = false
end

reader.hook(base + AT_NAME, function(cpu)
    local name = mem.cstr(cpu.x0, 200) or ""
    speaker = name ~= "" and name or nil
end)

reader.hook(base + AT_PAGE, function(cpu)
    local raw = mem.cstr(cpu.x0, 4000)
    if not raw then return end
    pending = { raw = raw, speaker = speaker, since = reader.frame() }
    speaker = nil
end)

local function emit_page(p, in_window)
    unplace("message")
    page = nil
    local text, ruby, voice = decode(p.raw)
    if text:gsub("%s", "") == "" then return end
    reader.emit{
        text = text, speaker = p.speaker, ruby = ruby, window = "message",
        meta = voice and { voice = voice } or nil,
    }
    if in_window then
        page = { glyphs = cells_of(text) }
        place("message", page.glyphs)
    end
end

---------------------------------------------------------------------------------------------
-- Choices

-- The answers stand in the middle of the picture, one under another, on cells as wide as the
-- message window's.
local CHOICE = { cx = 641, cy = 394, pitch = 67, h = 34 }

local function choice_cells(list)
    local k = scale()
    local glyphs = {}
    local n = #list
    for i, text in ipairs(list) do
        local len = utf8.len(text) or 0
        local x = CHOICE.cx - len * GRID.w / 2
        local y = CHOICE.cy + (i - 1 - (n - 1) / 2) * CHOICE.pitch - CHOICE.h / 2
        if i > 1 then glyphs[#glyphs + 1] = false end  -- the \n between answers
        for c = 0, len - 1 do
            glyphs[#glyphs + 1] = { (x + c * GRID.w) * k, y * k, GRID.w * k, CHOICE.h * k }
        end
    end
    return glyphs
end

reader.hook(base + AT_CHOICE, function(cpu)
    local raw = mem.cstr(cpu.x0, 1000)
    if not raw then return end
    local text = decode(raw)
    local now = reader.frame()
    if not answers or answers.emitted then
        answers = { list = {}, last = now }
    end
    answers.list[#answers.list + 1] = text
    answers.last = now
end)

---------------------------------------------------------------------------------------------

reader.on_frame(function(frame)
    local shown, in_window = window_shown()
    hidden_for = shown and 0 or hidden_for + 1
    if not shown and hidden_for < HIDDEN_FOR then
        return
    end
    if not shown then
        -- Nothing counts while the window is not up; what is placed is taken away.
        if pending then pending.since = frame end
        unplace("message")
        unplace("choice")
        return
    end
    local choosing = answers and not answers.emitted and frame - answers.last >= CHOICE_GATHER
    -- The game stops at a choice: the page under it is read then, however short its stay.
    if pending and (frame - pending.since >= STEADY or choosing) then
        local p = pending
        pending = nil
        if answers and answers.emitted then unplace("choice"); answers = nil end
        emit_page(p, in_window)
    end
    if choosing then
        reader.emit{ text = table.concat(answers.list, "\n"), channel = "choice", window = "choice" }
        answers.emitted = true
        answers.glyphs = choice_cells(answers.list)
    end
    -- Put back what a hidden window took away.
    if page and in_window and not placed.message then place("message", page.glyphs) end
    if answers and answers.emitted and not placed.choice then place("choice", answers.glyphs) end
end)
