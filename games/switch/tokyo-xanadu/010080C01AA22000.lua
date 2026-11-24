-- reader: no hooks
-- reader: title 東京ザナドゥ eX+ for Nintendo Switch (Tokyo Xanadu eX+)
-- reader: reads Dialogue, speakers, furigana, and party chatter (active voice)
-- reader: version The game as released (1.0.0)
-- 東京ザナドゥ eX+ for Nintendo Switch (Tokyo Xanadu eX+), Switch, Japanese release.
-- Written for main build 7596A9357FB9925AB33C87E6B3AEFD2CE19A4B42 (the game as released, 1.0.0).
--
-- Nihon Falcom's own engine on PhyreEngine, with no names left in the program. Three things of
-- the game's are read once a frame, all reached from one global of the program:
--
-- * The backlog: a ring of 1000 records, each a page of what a character said as the game
--   shows it (UTF-8, with the speaker's name beside it and the game's tags still in it:
--   furigana as 漢字#2Rかんじ#, where the number is the base's width in half-width cells). A
--   page is added the moment it starts to be typed out. This is where the text comes from.
-- * The speech balloons: four of them, each a node of the game's UI with its place and size
--   in 1920x1080 units, a state (opening, typing, waiting, closing, gone), the speaker's name
--   and a timer that tells a page still being typed from one that is all there. This is where
--   the places come from, and what says that a page can be read.
-- * The active voice window: what the party says while walking and fighting, at the bottom
--   left with a portrait and no name, its text inside it.
--
-- A page is read once it is all there in its balloon and has been for a few frames, so the
-- pages the game's fast-forward runs through are not read. The characters' places are worked
-- out from the balloon's corner: the game lays the text out on a fixed grid inside it. Nothing
-- is hooked, so the game runs natively (first line of this file).
--
-- Not read: menus, item and skill texts, the quest and map screens, the tutorial pages, the
-- system's messages, choices, the opening's captions (pictures). A page the backlog has but
-- that no balloon shows (none was met) is read without places once it has stood for half a
-- second.

local BUILD = "7596A9357FB9925AB33C87E6B3AEFD2CE19A4B42"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The way in (an offset into main): a slot of the program's that holds the address of the
-- pointer to the game's main object. From there:
local GAME_SLOT = 0x8d4cd8
local GAME_EVENT = 0x1438        -- game object: its event side (scenes, talk, the backlog)
local GAME_ACTIVE_VOICE = 0x64b6b0 -- game object: the active voice window (a UI node)
local EVENT_BACKLOG = 0x535a8    -- event side: the backlog
local EVENT_BALLOONS = 0x4d4f0   -- event side: the first of the speech balloons
local BALLOONS = 4
local BALLOON_STRIDE = 0xc50

-- The backlog.
local LOG_CAPACITY = 1000
local LOG_STRIDE = 0x150
local LOG_START = 0x7530c        -- the oldest record's place in the ring
local LOG_COUNT = 0x75310        -- how many records there are
local R_VOICE = 0x0c             -- record: the voice played with it (0: none)
local R_NAME = 0x10              -- record: the speaker (UTF-8, 32 bytes)
local R_TEXT = 0x30              -- record: the page (UTF-8 with the game's tags)
local R_TEXT_MAX = 0x120

-- A speech balloon (a UI node).
local B_ALPHA = 0x4c             -- float: how opaque
local B_SIZE = 0x60              -- 2 floats: width and height
local B_POS = 0x68               -- 2 floats: top left corner
local B_FLAGS = 0x8c             -- 0x10 while open (not while closing), 0x02 while typing
local B_TIMER = 0x5b0            -- float: grows while typing; 10000 once the page is all there
local B_NAME = 0x5c8             -- the speaker (UTF-8)
local F_OPEN, F_TYPING = 0x10, 0x02
local TYPED = 9999

-- The active voice window: what the party says while walking and fighting, at the bottom left
-- with a portrait and no name. A node like a balloon's, with its own text.
local AV_TEXT = 0x17c            -- UTF-8, lines broken with \n
local AV_TEXT_MAX = 0x200
local AV_SHOWN = 0xff            -- flags: some of these while it is up
local AV_PAD_X, AV_PAD_Y = 246, 42
local AV_ADVANCE, AV_LINE, AV_CELL = 24.3, 30, 30

-- The grid the text is laid out on inside a balloon (units of the UI).
local SPACE = { 1920, 1080 }
local PAD = 60                   -- from the balloon's corner to the first character
local ADVANCE = 33.86            -- from one full-width character to the next
local LINE = 48                  -- from one line to the next
local CELL_TOP, CELL_HEIGHT = -6, 40

-- How long a page must have been all there before it is read (frames), and how long a page
-- that no balloon shows must stand.
local HOLD = 6
local HOLD_UNSHOWN = 30

-- ---------------------------------------------------------------------------------------

--- An address the game could have put there: not a small number, not past what the Switch
--- maps (a read of unmapped memory is slow, so none is attempted).
local function plausible(address)
    return address and address >= 0x1000000 and address < 0x10000000000 and address % 8 == 0
end

local function game_object()
    local slot = mem.u64(base + GAME_SLOT)
    local game = plausible(slot) and mem.u64(slot)
    if not plausible(game) then return nil end
    return game
end

--- The game's page as text: the tags taken out, the furigana apart (in code points, from 0),
--- and where each character goes: its line and its column in full-width cells (false for a
--- line break).
local function decode(raw)
    local chars, cells, ruby = {}, {}, {}
    local line, column, line_start = 0, 0, true
    local function put(ch)
        chars[#chars + 1] = ch
        cells[#cells + 1] = { line, column }
        column = column + ((#ch == 1) and 0.5 or 1)
        line_start = false
    end
    local i, n = 1, #raw
    while i <= n do
        local c = raw:byte(i)
        if c == 0x23 then -- '#': a tag, or a '#' of the text
            local digits, letter = raw:match("^#(%d*)(%a)", i)
            local after = i + 1 + (digits and #digits or 0) + 1
            if not letter then
                put("#"); i = i + 1
            elseif letter == "R" and digits ~= "" then
                -- furigana over the characters just before, as wide as the number says
                local close = raw:find("#", after, true)
                local reading = raw:sub(after, (close or n + 1) - 1)
                local want, width, k = tonumber(digits) / 2, 0, #chars
                while k >= 1 and width < want and chars[k] ~= "\n" do
                    width = width + ((#chars[k] == 1) and 0.5 or 1)
                    k = k - 1
                end
                if k < #chars and reading ~= "" then
                    ruby[#ruby + 1] = { k, #chars - k, reading }
                end
                i = (close or n) + 1
            elseif (letter == "E" or letter == "M" or letter == "H" or letter == "e")
                and digits == "" and raw:sub(after, after) == "[" then
                local close = raw:find("]", after, true)
                i = (close or n) + 1
            elseif (letter == "E" or letter == "M") and digits == ""
                and raw:sub(after, after) == "_" then
                i = after + 2
            else
                i = after
            end
        elseif c == 0x01 or c == 0x0a then -- a line break
            chars[#chars + 1] = "\n"
            cells[#cells + 1] = false
            line, column, line_start = line + 1, 0, true
            i = i + 1
        elseif c < 0x20 then -- 0x02 ends the page; other commands
            i = i + 1
        elseif c == 0x20 and line_start then
            -- indentation: it moves the line along, it is not text
            column = column + 0.5
            i = i + 1
        else
            local len = c < 0x80 and 1 or c < 0xe0 and 2 or c < 0xf0 and 3 or 4
            put(raw:sub(i, i + len - 1))
            i = i + len
        end
    end
    -- no line break at either end
    while chars[#chars] == "\n" do chars[#chars] = nil; cells[#cells] = nil end
    return table.concat(chars), ruby, cells
end

--- What the four balloons show: the open ones, with their state.
local function balloons(event)
    local out = {}
    for k = 0, BALLOONS - 1 do
        local node = event + EVENT_BALLOONS + k * BALLOON_STRIDE
        local flags = mem.u32(node + B_FLAGS) or 0
        if flags & F_OPEN ~= 0 then
            local x, y = mem.f32(node + B_POS), mem.f32(node + B_POS + 4)
            local w, h = mem.f32(node + B_SIZE), mem.f32(node + B_SIZE + 4)
            local timer = mem.f32(node + B_TIMER) or 0
            out[#out + 1] = {
                index = k,
                name = mem.cstr(node + B_NAME, 32) or "",
                typed = flags & F_TYPING == 0 and timer >= TYPED,
                x = x or 0, y = y or 0, w = w or 0, h = h or 0,
            }
        end
    end
    return out
end

local function cells_of(balloon, cells)
    local glyphs = {}
    for k, cell in ipairs(cells) do
        if cell then
            glyphs[k] = { balloon.x + PAD + cell[2] * ADVANCE, balloon.y + PAD + cell[1] * LINE + CELL_TOP,
                          ADVANCE, CELL_HEIGHT }
        else
            glyphs[k] = false
        end
    end
    return glyphs
end

-- ---------------------------------------------------------------------------------------

local last = nil        -- the backlog as last seen: {start, count}
local pending = {}      -- pages not read yet, oldest first
local shown = {}        -- balloon index -> the page read in it (its layout is up)
local MAX_PENDING = 4   -- more pages than this at once are a loaded save's backlog, not reading

local function newest_record(event)
    local log = mem.u64(event + EVENT_BACKLOG)
    if not plausible(log) then return nil end
    local count = mem.u32(log + LOG_COUNT)
    local start = mem.u32(log + LOG_START)
    if not count or not start or count > 1000000 then return nil end
    return log, start, count
end

local function read_record(log, start, serial)
    local record = log + ((start + serial) % LOG_CAPACITY) * LOG_STRIDE
    local raw = mem.cstr(record + R_TEXT, R_TEXT_MAX) or ""
    local text_, ruby, cells = decode(raw)
    return {
        serial = serial,
        name = mem.cstr(record + R_NAME, 32) or "",
        voice = mem.u32(record + R_VOICE) or 0,
        raw = raw,
        text = text_, ruby = ruby, cells = cells,
    }
end

local function withdraw(index)
    if shown[index] then
        reader.layout("balloon" .. index, nil)
        shown[index] = nil
    end
end

local function emit(page, balloon, frame)
    if page.text == "" then return end
    local window = balloon and ("balloon" .. balloon.index) or "balloon"
    reader.emit{
        text = page.text,
        speaker = page.name ~= "" and page.name or nil,
        ruby = #page.ruby > 0 and page.ruby or nil,
        id = text.hash(page.serial .. "\0" .. page.raw),
        window = window,
        meta = { voice = page.voice },
    }
    if balloon then
        reader.layout(window, {
            space = SPACE,
            box = { balloon.x, balloon.y, balloon.w, balloon.h },
            glyphs = cells_of(balloon, page.cells),
        })
        shown[balloon.index] = page
    end
end

--- How many records were added since the last look (the ring drops its oldest once full; a
--- new game or a loaded save starts it again).
local function added(start, count)
    if not last then return count > 0 and 1 or 0 end -- loaded mid-game: the page up now
    if start == last.start then
        if count >= last.count then return count - last.count end
        return count -- started again
    end
    return ((start - last.start) % LOG_CAPACITY) + (count - last.count)
end

-- The active voice window: read once it has been up for a moment; its places go when it does.
local voice = { raw = nil, since = 0, read = false }

local function active_voice(game, frame)
    local node = game + GAME_ACTIVE_VOICE
    local flags = mem.u32(node + B_FLAGS) or 0
    local up = flags & AV_SHOWN ~= 0 and (mem.f32(node + B_ALPHA) or 0) >= 0.99
    local raw = up and (mem.cstr(node + AV_TEXT, AV_TEXT_MAX) or "") or nil
    if raw == "" then raw = nil end
    if raw ~= voice.raw then
        if voice.read then reader.layout("active", nil) end
        voice.raw, voice.since, voice.read = raw, frame, false
    end
    if not raw or voice.read or frame - voice.since < HOLD then return end
    voice.read = true
    local text_, ruby, cells = decode(raw)
    if text_ == "" then return end
    local x, y = (mem.f32(node + B_POS) or 0) + AV_PAD_X, (mem.f32(node + B_POS + 4) or 0) + AV_PAD_Y
    local glyphs, columns, lines = {}, 0, 0
    for k, cell in ipairs(cells) do
        if cell then
            glyphs[k] = { x + cell[2] * AV_ADVANCE, y + cell[1] * AV_LINE, AV_ADVANCE, AV_CELL }
            columns = math.max(columns, cell[2] + 1)
            lines = math.max(lines, cell[1] + 1)
        else
            glyphs[k] = false
        end
    end
    reader.emit{
        text = text_,
        ruby = #ruby > 0 and ruby or nil,
        id = text.hash("active\0" .. frame .. "\0" .. raw),
        window = "active",
    }
    reader.layout("active", {
        space = SPACE,
        box = { x - 8, y - 6, columns * AV_ADVANCE + 16, (lines - 1) * AV_LINE + AV_CELL + 12 },
        glyphs = glyphs,
    })
end

reader.on_frame(function(frame)
    local game = game_object()
    if not game then return end
    active_voice(game, frame)
    local event = mem.u64(game + GAME_EVENT)
    if not plausible(event) then return end
    local log, start, count = newest_record(event)
    if not log then return end
    local open = balloons(event)

    -- balloons that closed, or that show another speaker now, take their places with them
    local still = {}
    for _, b in ipairs(open) do still[b.index] = b end
    for index, page in pairs(shown) do
        local b = still[index]
        if not b or b.name ~= page.name then withdraw(index) end
    end

    local new = added(start, count)
    local first_look = last == nil
    last = { start = start, count = count }
    if new > 0 and new <= MAX_PENDING then
        for serial = count - new, count - 1 do
            local page = read_record(log, start, serial)
            page.first = frame
            page.only_in_balloon = first_look -- up before the profile was: read it only if it still is
            -- a speaker's new page replaces the one before, read or not
            for k = #pending, 1, -1 do
                if pending[k].name == page.name then table.remove(pending, k) end
            end
            for index, old in pairs(shown) do
                if old.name == page.name then withdraw(index) end
            end
            pending[#pending + 1] = page
        end
        while #pending > MAX_PENDING do table.remove(pending, 1) end
    end

    local k = 1
    while k <= #pending do
        local page = pending[k]
        -- its balloon: an open one with its speaker that shows nothing read yet
        local balloon = nil
        for _, b in ipairs(open) do
            if b.name == page.name and not shown[b.index] then balloon = b end
        end
        local done = false
        if balloon then
            if balloon.typed then
                page.since = page.since or frame
                if frame - page.since >= HOLD then
                    emit(page, balloon, frame)
                    done = true
                end
            else
                page.since = nil
            end
        elseif page.only_in_balloon then
            done = true
        elseif #open == 0 and frame - page.first >= HOLD_UNSHOWN then
            emit(page, nil, frame)
            done = true
        end
        if done then table.remove(pending, k) else k = k + 1 end
        page.only_in_balloon = false
    end
end)
