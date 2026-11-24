-- reader: no hooks
-- reader: title 逆転裁判456 王泥喜セレクション (Apollo Justice: Ace Attorney Trilogy)
-- reader: reads Dialogue, speakers, and choices (all three games)
-- reader: version Version 0, with 日本語 chosen as the game's language
-- reader: touch game
-- reader: audio never
-- 逆転裁判456 王泥喜セレクション (Apollo Justice: Ace Attorney Trilogy), Switch.
-- Written for main build DBE49182FBCA27691C65B23C9E105D1FD5AF06CB (version 0).
--
-- An RE Engine game: three games in one program, each with its own classes. The program has
-- the engine's whole type database (every class with its fields by name), which is where the
-- offsets below come from; static fields are at fixed places in main. The profile reads,
-- once a frame, the text element each game types its message into (the whole page is there
-- from the first character, with a record of where every character is drawn) and the name
-- plate, whose text is a message ID looked up in the engine's table of messages. Nothing is
-- hooked, so the game runs natively (first line of this file).
--
-- Read: the message window of all three games (dialogue, narration, thoughts, testimony) with
-- the speaker, and the answers of a choice (without places). Not read: the court record, the
-- games' own backlog, menus, the options, films and what is drawn as pictures.

local BUILD = "DBE49182FBCA27691C65B23C9E105D1FD5AF06CB"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The ways in (offsets into main): static fields of the game's classes, and an engine singleton.
local GS4_APP_CORE = 0xa45b6c0    -- app.gs4.AppCore: SharedInstance
local MESSAGE_MANAGER = 0xa4302a0 -- the engine's table of messages by ID
local OPTION_MANAGER = 0xa451fe0  -- app.OptionManager, which has the options menu of all three games

-- Managed objects: fields of a plain object from 0x10, of a behaviour from 0x50.
local STRING_LENGTH, STRING_CHARS = 0x10, 0x14

-- The first game (逆転裁判4): app.gs4.AppCore, app.gs4.GS4 (a NitroLayer), MsgWndTextGS4,
-- MessageWindowGUI.
local CORE_APP = 0x110
local APP_WINDOW, APP_TEXT, APP_BACKLOG = 0x10, 0x20, 0xc0
local TEXT_ELEMENT, TEXT_FILE, TEXT_PAGE, TEXT_DRAWN = 0x138, 0x14c, 0x164, 0x184
local GS4_NAME_TAG = 0x1b0
local APP_CHOICE = 0x70                         -- ChoiceGUIGS4
local GS4_CHOICE = { state = 0x174, count = 0x178, texts = 0x198 } -- mState, mButtonNum, Text_Jpn

-- The second and third game (逆転裁判5, 6) are built alike: sScenario with its two script
-- players, each a GUI with a script analyser that types a page of the script into a text
-- element, and the message window with the name plate.
local ARRAY_ITEMS = 0x20
local ANALYSER, AN_TEXT = 0x1a8, 0x20          -- uScriptPlayerBase.mpScriptObj; ScriptAnalyze.ScriptText
local GAMES = {
    { windows = { "gs5.1", "gs5.2" }, scenario = 0xa4575c0, players = 0x90, window = 0x70, backlog = 0x138,
      file = 0x1c0, label = 0x1c8, page = 0x1cc, drawn = 0x1d4, name_tag = 0x218,
      panels = 0x80, choice = 0x110, choices = { state = 0x1b0, count = 0x1b4, buttons = 0x1c8, button_text = 0x50 } },
    { windows = { "gs6.1", "gs6.2" }, scenario = 0xa4530d0, players = 0x98, window = 0xb0, backlog = 0xf0,
      file = 0x1c0, label = 0x1d0, page = 0x1d4, drawn = 0x1dc, name_tag = 0x228,
      panels = 0xa8, choice = 0x150, choices = { state = 0x1bc, count = 0x1c0, buttons = 0x1d0, button_text = 0x50 } },
}
local OM_GUI, GUI_STATE = 0x80, 0xa0             -- OptionManager.mpOptionGUI; GUIBase._BaseState: 0 while it waits
local BACKLOG_STATE = 0x1a0                     -- uBackLogGuiBase.mState: 0 while it is closed

-- GUI elements (native): parent, flags, and for a panel its place in the 1920x1080 screen.
local E_PARENT, E_FLAGS = 0x30, 0x50
local VISIBLE = 1
local P_WORLD = 0xd0                -- 4x4, rows of four floats; the last row is the translation
-- via.gui.Text
local T_STRING, T_MESSAGE_ID = 0x60, 0x68
local T_SELF = 0x1e8                -- a text that is typed out points back at itself here
local T_GLYPHS, T_GLYPH_COUNT, GLYPH_SIZE = 0x1c8, 0x1d0, 0x70 -- per character: x, y, -, -, width, height
local SPACE = { 1920, 1080 }

-- The message manager: a tree of messages by ID (left, right, parent, -, the ID, resource, index),
-- and a resource's entries (the ID, …, the text in each language from 0x28, Japanese first).
local MM_ROOT = 0x40
local N_LEFT, N_RIGHT, N_KEY, N_RESOURCE, N_INDEX = 0x00, 0x08, 0x20, 0x30, 0x38
local R_ENTRIES, ENTRY_TEXT = 0x38, 0x28

local function pointer(a)
    local p = a and mem.u64(a)
    if p and p > 0x10000 and p < 0x10000000000 then return p end
end

local function managed_string(s)
    local n = s and mem.s32(s + STRING_LENGTH)
    if not n or n <= 0 or n > 65536 then return "" end
    return text.utf16le(mem.read(s + STRING_CHARS, 2 * n) or "")
end

-- IDs are ordered as GUIDs: the first four bytes as a number, then two and two, then the rest
-- byte by byte.
local function id_parts(lo, hi)
    return { lo & 0xffffffff, (lo >> 32) & 0xffff, (lo >> 48) & 0xffff,
             hi & 0xff, (hi >> 8) & 0xff, (hi >> 16) & 0xff, (hi >> 24) & 0xff,
             (hi >> 32) & 0xff, (hi >> 40) & 0xff, (hi >> 48) & 0xff, (hi >> 56) & 0xff }
end
local function id_less(a, b)
    for i = 1, #a do
        if a[i] ~= b[i] then return a[i] < b[i] end
    end
    return false
end

-- The Japanese text of the message with this ID, or nil.
local names = {}
local function message(lo, hi)
    if lo == 0 and hi == 0 then return nil end
    local key = string.format("%x:%x", lo, hi)
    if names[key] then return names[key] end
    local manager = pointer(base + MESSAGE_MANAGER)
    local node = manager and pointer(manager + MM_ROOT)
    local wanted = id_parts(lo, hi)
    for _ = 1, 64 do
        if not node then return nil end
        local nlo, nhi = mem.u64(node + N_KEY), mem.u64(node + N_KEY + 8)
        if not nlo then return nil end
        if nlo == lo and nhi == hi then
            local resource, index = pointer(node + N_RESOURCE), mem.u32(node + N_INDEX)
            local entry = resource and index and pointer(resource + R_ENTRIES + 8 * index)
            local s = entry and pointer(entry + ENTRY_TEXT)
            if not s then return nil end
            local found = text.utf16le(mem.wstr(s, 128) or "")
            names[key] = found
            return found
        end
        node = pointer(node + (id_less(wanted, id_parts(nlo, nhi)) and N_LEFT or N_RIGHT))
    end
end

-- Whether an element and everything it is in is switched on.
local function visible(element)
    for _ = 1, 24 do
        if not element then return true end
        local flags = mem.u32(element + E_FLAGS)
        if not flags or flags & VISIBLE == 0 then return false end
        element = pointer(element + E_PARENT)
    end
    return true
end

-- The characters of a text element: its string, and a cell for each character.
local page_of
local cuts = {} -- by element: the page cut out of its script last
local function read_text(element, page)
    -- A script is long and stays the same object while its pages are shown: cut it up once.
    local object = pointer(element + T_STRING)
    local length = object and mem.s32(object + STRING_LENGTH) or 0
    local cut = cuts[element]
    if not cut or cut.object ~= object or cut.length ~= length or cut.page ~= page then
        local script = managed_string(object)
        local s = page_of(script, page or 0)
        cut = { object = object, length = length, page = page, text = s, tagged = s ~= script }
        if s then
            local _, breaks = s:gsub("\n", "")
            cut.breaks = breaks
        end
        cuts[element] = cut
    end
    local s, tagged, breaks = cut.text, cut.tagged, cut.breaks
    if not s then return nil end
    local count = mem.u32(element + T_GLYPH_COUNT) or 0
    local glyphs = pointer(element + T_GLYPHS)
    local parent = pointer(element + E_PARENT)
    if s == "" or not glyphs or not parent or count ~= text.len(s) - breaks or count > 512 then
        -- A page cut out of a script counts only when it is the page laid out.
        if tagged then return nil end
        return s, nil
    end
    local raw = mem.read(parent + P_WORLD, 64)
    if not raw or #raw < 64 then return s, nil end
    local sx, sy, tx, ty = string.unpack("<f", raw, 1), string.unpack("<f", raw, 21), string.unpack("<f", raw, 49), string.unpack("<f", raw, 53)
    local data = mem.read(glyphs, count * GLYPH_SIZE)
    if not data or #data < count * GLYPH_SIZE then return s, nil end
    -- Lines: the cell of a character is from its left to the next one's, as high as its line.
    local cells, line = {}, {}
    local function flush()
        local top, bottom, steps = math.huge, -math.huge, {}
        for i, g in ipairs(line) do
            top, bottom = math.min(top, g.y), math.max(bottom, g.y + g.h)
            if line[i + 1] and line[i + 1].x > g.x then steps[#steps + 1] = line[i + 1].x - g.x end
        end
        table.sort(steps)
        local step = steps[(#steps + 1) // 2] or 0
        for i, g in ipairs(line) do
            local next_x = line[i + 1] and line[i + 1].x
            local right = next_x and next_x > g.x and next_x or g.x + math.max(g.w, step)
            cells[#cells + 1] = { tx + sx * g.x, ty + sy * top, sx * (right - g.x), sy * (bottom - top) }
        end
        line = {}
    end
    local i = 0
    for _, code in utf8.codes(s) do
        if code == 0x0a then -- a line break has no record
            flush()
            cells[#cells + 1] = false
        else
            local x, y, _, _, w, h = string.unpack("<ffffff", data, i * GLYPH_SIZE + 1)
            line[#line + 1] = { x = x, y = y, w = w, h = h }
            i = i + 1
        end
    end
    flush()
    return s, cells
end

-- The page of a script that a text element shows: the script has the game's commands in it
-- (<XXXX …>) and <PAGE> between pages; nil when the script has no such page. A page's line
-- breaks at its ends are dropped (the first game ends some pages with one).
function page_of(script, page)
    if not script:find("<", 1, true) then
        return (script:gsub("\r", ""):gsub("^\n+", ""):gsub("\n+$", ""))
    end
    local at, index = 1, 0
    while index < page do
        local _, close = script:find("<PAGE>", at, true)
        if not close then return nil end
        at, index = close + 1, index + 1
    end
    local stop = script:find("<PAGE>", at, true)
    local s = script:sub(at, stop and stop - 1 or -1):gsub("<[^>]*>", ""):gsub("\r", "")
    s = s:gsub("^\n+", ""):gsub("\n+$", "")
    return s
end

local windows = {} -- by name: {key, placed}
local read = {}    -- by name: the key of what was emitted last; a window that was covered and
                   -- comes back with the same page is not read twice

local function withdraw(name)
    local shown = windows[name]
    if shown and shown.placed then reader.layout(name, nil) end
    windows[name] = nil
end

local function place(name, cells)
    local shown = windows[name]
    local key, left, top, right, bottom = {}, math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs(cells) do
        if c then
            key[#key + 1] = string.format("%.0f,%.0f", c[1], c[2])
            left, top = math.min(left, c[1]), math.min(top, c[2])
            right, bottom = math.max(right, c[1] + c[3]), math.max(bottom, c[2] + c[4])
        end
    end
    key = table.concat(key, " ")
    if key == "" or key == shown.placed then return end
    local margin = 16
    reader.layout(name, { space = SPACE, glyphs = cells,
        box = { left - margin, top - margin, right - left + 2 * margin, bottom - top + 2 * margin } })
    shown.placed = key
end

local function speaker_of(tag)
    if tag and visible(tag) then return message(mem.u64(tag + T_MESSAGE_ID), mem.u64(tag + T_MESSAGE_ID + 8)) end
end

-- One message window: the text element, how many of its characters are typed, the page of its
-- script, what tells this page from the same words elsewhere, the name plate, the backlog.
local function report(name, element, drawn, page, where, tag, backlog)
    if not element or drawn <= 0 or mem.u64(element + T_SELF) ~= element or not visible(element) then
        return withdraw(name)
    end
    if backlog and (mem.u32(backlog + BACKLOG_STATE) or 0) ~= 0 then return withdraw(name) end
    local s, cells = read_text(element, page)
    if not s or s == "" then return withdraw(name) end
    local key = where .. ":" .. s
    if not windows[name] or windows[name].key ~= key then
        withdraw(name)
        if read[name] ~= key then reader.emit{ text = s, speaker = speaker_of(tag), window = name } end
        read[name] = key
        windows[name] = { key = key }
    end
    if cells then place(name, cells) end
end

-- The answers of a choice: a GUI with a state (0 while there is none), the number of answers
-- and a text element each (in an array, or one in each button object of an array). They are
-- reported as one text, without places.
local function element_text(element)
    local lo, hi = mem.u64(element + T_MESSAGE_ID), mem.u64(element + T_MESSAGE_ID + 8)
    local s = lo and hi and message(lo, hi)
    if s and s ~= "" then return s end
    return (managed_string(pointer(element + T_STRING)):gsub("\r", ""))
end

local asked = {} -- by name: the answers reported last
local function choices(name, gui, layout)
    local state = gui and mem.s32(gui + layout.state) or 0
    local count = gui and mem.s32(gui + layout.count) or 0
    if state == 0 or count <= 0 or count > 8 then
        asked[name] = nil
        return
    end
    local array = pointer(gui + (layout.texts or layout.buttons))
    local answers = {}
    for i = 1, count do
        local item = array and pointer(array + ARRAY_ITEMS + 8 * (i - 1))
        local element = item and (layout.texts and item or pointer(item + layout.button_text))
        local s = element and element_text(element) or ""
        if s == "" then return end -- not all there yet
        answers[i] = s
    end
    local all = table.concat(answers, "\n")
    if asked[name] == all then return end
    asked[name] = all
    reader.emit{ text = all, channel = "choice", window = name }
end

local GS4_WINDOW = "gs4"
local function gs4()
    local core = pointer(base + GS4_APP_CORE)
    local app = core and pointer(core + CORE_APP)
    local window, holder = app and pointer(app + APP_WINDOW), app and pointer(app + APP_TEXT)
    if not window or not holder then return withdraw(GS4_WINDOW) end
    report(GS4_WINDOW, pointer(holder + TEXT_ELEMENT), mem.s32(holder + TEXT_DRAWN) or 0, 0,
           string.format("%d:%d", mem.s32(holder + TEXT_FILE) or 0, mem.s32(holder + TEXT_PAGE) or 0),
           pointer(window + GS4_NAME_TAG), pointer(app + APP_BACKLOG))
    choices("gs4.choice", pointer(app + APP_CHOICE), GS4_CHOICE)
end

-- A game that was left keeps its scenario, but its players have no text element any more.
local function scenario_game(game)
    local scenario = pointer(base + game.scenario)
    local players = scenario and pointer(scenario + game.players)
    local window = scenario and pointer(scenario + game.window)
    local tag = window and pointer(window + game.name_tag)
    for i, name in ipairs(game.windows) do
        local player = players and pointer(players + ARRAY_ITEMS + 8 * (i - 1))
        local analyser = player and pointer(player + ANALYSER)
        if analyser then
            report(name, pointer(analyser + AN_TEXT), mem.s32(player + game.drawn) or 0, mem.s32(player + game.page) or 0,
                   string.format("%s:%d:%d", managed_string(pointer(player + game.file)), mem.s32(player + game.label) or 0, mem.s32(player + game.page) or 0),
                   tag, pointer(scenario + game.backlog))
        else
            withdraw(name)
        end
    end
    local panels = scenario and pointer(scenario + game.panels)
    choices(game.windows[1] .. ".choice", panels and pointer(panels + game.choice), game.choices)
end

-- The options menu (and the questions it asks) lies over everything.
local function options_open()
    local manager = pointer(base + OPTION_MANAGER)
    local gui = manager and pointer(manager + OM_GUI)
    return gui ~= nil and (mem.s32(gui + GUI_STATE) or 0) ~= 0
end

reader.on_frame(function()
    if options_open() then
        for name in pairs(windows) do withdraw(name) end
        return
    end
    gs4()
    for _, game in ipairs(GAMES) do scenario_game(game) end
end)

-- For the harness: what the profile sees now.
function aj_dump()
    for name, shown in pairs(windows) do print(name, shown.key, shown.placed and "placed" or "not placed") end
    for _, game in ipairs(GAMES) do
        local scenario = pointer(base + game.scenario)
        local players = scenario and pointer(scenario + game.players)
        print(string.format("scenario %x players %x", scenario or 0, players or 0))
        for i = 1, 2 do
            local player = players and pointer(players + ARRAY_ITEMS + 8 * (i - 1))
            local analyser = player and pointer(player + ANALYSER)
            local element = analyser and pointer(analyser + AN_TEXT)
            if element then
                local s, cells = read_text(element, mem.s32(player + game.page) or 0)
                print(string.format("player %d page %d drawn %d visible %s glyphs %d text %q cells %s", i, mem.s32(player + game.page) or -1,
                    mem.s32(player + game.drawn) or -1, tostring(visible(element)), mem.u32(element + T_GLYPH_COUNT) or -1, tostring(s), tostring(cells and #cells)))
            end
        end
    end
end
