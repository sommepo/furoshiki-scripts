-- reader: no hooks
-- reader: title HUNDRED LINE -最終防衛学園- (The Hundred Line -Last Defense Academy-)
-- reader: reads Dialogue, narration, and speakers
-- reader: version Version 1.0.0 (the base game)
-- reader: touch press
-- HUNDRED LINE -最終防衛学園- (The Hundred Line -Last Defense Academy-), Switch.
-- Written for main build 2680EC19C1C5A76D1A206268D3E1AEF5E19EC8E9 (the base game, no update).
--
-- Media.Vision's own engine; the program keeps no names. Its UI is a list of screens kept by
-- the UI manager (a std::deque of pointers reached from main's data), each with a type number.
-- A screen holds layouts (each a record with its name, "ui_e_talk_window"), a layout keeps its
-- text nodes by name ("textMsg", "textName"), and a text node has a flag that says whether it
-- is drawn and its text (UTF-8, the game's tags in it, every row). The message text is also
-- built into a text mesh (a quad per character), which gives the characters' places. The profile reads all of this once
-- a frame; nothing is hooked.
--
-- Read: the talk window (dialogue and narration, the speaker when the window shows one). Not
-- read: the films' subtitles (see the notes: what the program keeps of them runs ahead of the
-- picture), choices, menus, the backlog, tutorials, the names of places, the battles' texts,
-- system messages.

local BUILD = "2680EC19C1C5A76D1A206268D3E1AEF5E19EC8E9"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- Offsets into main.
local UI_MANAGER = 0xc9e718     -- pointer to the UI manager
local TEXT_HANDLE = 0x611e80    -- first word of a screen's handle on a text mesh

-- The UI manager's screens: a std::deque of pointers (map +0x58, first +0x70, count +0x78).
local DQ_MAP, DQ_START, DQ_SIZE, DQ_BLOCK = 0x58, 0x70, 0x78, 512
local SCREEN_TYPE = 0x8

-- The screens read, and where each keeps the record of its layout.
local TALK_WINDOW = {type = 0x47, record = 0x98, name = "ui_e_talk_window"}
local MESSAGE_TEXT = {type = 0x1, handle = 0x60} -- the message text's mesh

-- A layout record: itself at +0, its name (a std::string) at +0x80, the layout at +0x98. A
-- layout's named text nodes: a vector at +0xe0 of 0x48-byte entries (the name, 64 bytes; the
-- node at +0x40). A node: drawn when the byte at +0x48 is 1; its text as given (a std::string)
-- at +0xa0; its first row's characters in a std::vector<char32_t> at +0x120.
local R_NAME, R_LAYOUT = 0x80, 0x98
local L_NAMED, NAMED_SIZE, NAMED_NODE = 0xe0, 0x48, 0x40
local N_SHOWN, N_STRING, N_CHARS = 0x48, 0xa0, 0x120

-- A text mesh: the characters at +0x30, four corners per character at +0x48 (x y z floats).
local M_CHARS, M_VERTS, QUAD = 0x30, 0x48, 48

-- Where the mesh's units fall in the picture (measured on 1280x720 pictures: a unit is
-- 664/720 of the picture's height); the talk window's text starts at its origin.
local UNIT = 664 / 720
local TALK_ORIGIN = {267.4 / 1280, 565.7 / 720}

local SETTLE = 6        -- frames a talk line is left before it counts

local function valid(p)
    return p ~= nil and p > 0x10000 and p < 0x8000000000 and p % 4 == 0
end

local function screens()
    local out = {}
    local m = mem.u64(base + UI_MANAGER)
    if not valid(m) then return out end
    local map, start, size = mem.u64(m + DQ_MAP), mem.u64(m + DQ_START), mem.u64(m + DQ_SIZE)
    if not valid(map) or not start or not size or size > 400 then return out end
    for i = start, start + size - 1 do
        local block = mem.u64(map + (i // DQ_BLOCK) * 8)
        local s = valid(block) and mem.u64(block + (i % DQ_BLOCK) * 8)
        if valid(s) then out[#out + 1] = s end
    end
    return out
end

local function find_screen(list, kind)
    for _, s in ipairs(list) do
        if mem.u32(s + SCREEN_TYPE) == kind then return s end
    end
end

-- A libc++ std::string.
local function cxx_string(a)
    local first = mem.u8(a)
    if not first then return nil end
    if first % 2 == 0 then return mem.read(a + 1, first // 2) end
    local size, data = mem.u64(a + 8), mem.u64(a + 16)
    if not size or size > 256 or not valid(data) then return nil end
    return mem.read(data, size)
end

-- UTF-32 from a std::vector<char32_t>: the codes, or nil when it does not look like text.
local function codes_at(v)
    local b, e = mem.u64(v), mem.u64(v + 8)
    if b == 0 and e == 0 then return {} end
    if not valid(b) or not e or e < b or (e - b) % 4 ~= 0 or e - b > 4 * 800 then return nil end
    local n = (e - b) // 4
    local raw = mem.read(b, 4 * n)
    if not raw or #raw < 4 * n then return nil end
    local codes = {}
    for i = 1, n do
        local c = string.unpack("<I4", raw, 4 * i - 3)
        if c == 0 or c > 0x10ffff then return nil end
        codes[i] = c
    end
    return codes
end

-- The game's tags: {fc(rrggbb)…} a colour, {ftN…} a font, {fsNN} a size, {isNN}{image(…)} an
-- icon. The text inside a colour or a font is kept.
local function untagged(s)
    s = s:gsub("{image%([^)]*%)}", ""):gsub("{is%d+}", ""):gsub("{fs%d+}", "")
    s = s:gsub("{fc%(%x+%)", ""):gsub("{ft%d", ""):gsub("}", "")
    return s
end

local function codes_of(s)
    local codes = {}
    if not utf8.len(s) then return nil end
    for _, c in utf8.codes(s) do codes[#codes + 1] = c end
    return codes
end

local function text_of(codes)
    local t = {}
    for i, c in ipairs(codes) do t[i] = utf8.char(c) end
    return table.concat(t)
end

local function trimmed(codes)
    local first, last = 1, #codes
    local function blank(c) return c == 0x20 or c == 0x3000 or c == 0x0a end
    while first <= last and blank(codes[first]) do first = first + 1 end
    while last >= first and blank(codes[last]) do last = last - 1 end
    local t = {}
    for i = first, last do t[#t + 1] = utf8.char(codes[i]) end
    return table.concat(t)
end

-- The named text nodes of a screen's layout, when the layout is the one expected.
local function named_nodes(screen, where)
    local record = mem.u64(screen + where.record)
    if not valid(record) or mem.u64(record) ~= record then return nil end
    if cxx_string(record + R_NAME) ~= where.name then return nil end
    local layout = mem.u64(record + R_LAYOUT)
    if not valid(layout) then return nil end
    local b, e = mem.u64(layout + L_NAMED), mem.u64(layout + L_NAMED + 8)
    if not valid(b) or not e or e < b or (e - b) % NAMED_SIZE ~= 0 or e - b > NAMED_SIZE * 200 then
        return nil
    end
    local nodes = {}
    for p = b, e - NAMED_SIZE, NAMED_SIZE do
        local name = mem.cstr(p, 64)
        local node = mem.u64(p + NAMED_NODE)
        if name and valid(node) then nodes[name] = node end
    end
    return nodes
end

local function shown(node)
    return node ~= nil and mem.u8(node + N_SHOWN) == 1
end

-- The message mesh: its characters and the corners of the quads drawn for them (one a
-- character, a line break included or not).
local function message_mesh(list)
    local s = find_screen(list, MESSAGE_TEXT.type)
    if not s or mem.u64(s + MESSAGE_TEXT.handle) ~= base + TEXT_HANDLE then return nil end
    local m = mem.u64(s + MESSAGE_TEXT.handle + 8)
    if not valid(m) then return nil end
    local codes = codes_at(m + M_CHARS)
    if not codes then return nil end
    local quads
    local vb, ve = mem.u64(m + M_VERTS), mem.u64(m + M_VERTS + 8)
    local n = valid(vb) and ve and ve > vb and (ve - vb) % QUAD == 0 and (ve - vb) // QUAD
    if n and n <= #codes then
        local raw = mem.read(vb, n * QUAD)
        if raw and #raw == n * QUAD then
            quads = {}
            for i = 0, n - 1 do
                -- corners: top left (x y z), top right, bottom left, bottom right
                local x0, y0, _, x1, _, _, _, y1 = string.unpack("<ffffffff", raw, i * QUAD + 1)
                quads[i + 1] = {x0, y0, x1, y1}
            end
        end
    end
    return {codes = codes, quads = quads}
end

local function same(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- The emitted text: the characters without the blanks and line breaks at the end.
local function shown_codes(codes)
    local last = #codes
    while last > 0 and (codes[last] == 0x0a or codes[last] == 0x20 or codes[last] == 0x3000) do
        last = last - 1
    end
    local out = {}
    for i = 1, last do out[i] = codes[i] end
    return out
end

-- A cell for every character of `codes` from the mesh's quads, which come one a character,
-- with or without one for each line break; nil when they do not match the text.
local function cells(codes, quads, origin)
    local w, h = reader.picture()
    if not w or not quads then return nil end
    local breaks = 0
    for _, c in ipairs(codes) do if c == 0x0a then breaks = breaks + 1 end end
    local with_breaks
    if #quads >= #codes then with_breaks = true
    elseif #quads >= #codes - breaks then with_breaks = false
    else return nil end
    local k, ox, oy = UNIT * h, origin[1] * w, origin[2] * h
    local glyphs, q = {}, 0
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i, c in ipairs(codes) do
        if c == 0x0a then
            glyphs[i] = false
            if with_breaks then q = q + 1 end
        else
            q = q + 1
            local quad = quads[q]
            local left, right = ox + quad[1] * k, ox + quad[3] * k
            local top, bottom = oy - quad[2] * k, oy - quad[4] * k
            if right - left < 1 or bottom - top < 1 then
                glyphs[i] = false
            else
                glyphs[i] = {left, top, right - left, bottom - top}
                x0, y0 = math.min(x0, left), math.min(y0, top)
                x1, y1 = math.max(x1, right), math.max(y1, bottom)
            end
        end
    end
    if x0 == math.huge then return nil end
    return {space = {w, h}, box = {x0 - 10, y0 - 8, x1 - x0 + 20, y1 - y0 + 16}, glyphs = glyphs}
end

-- State of each window: the codes seen, since when, whether reported, whether laid out.
local talk = {key = nil, since = 0, done = false, placed = false}

local function withdraw(state, window)
    if state.placed then reader.layout(window, nil) end
    state.placed = false
end

local function key_of(codes) return table.concat(codes, ",") end

local function read_talk(frame, list, mesh)
    local s = find_screen(list, TALK_WINDOW.type)
    local nodes = s and named_nodes(s, TALK_WINDOW)
    local msg = nodes and nodes.textMsg
    if not shown(msg) then
        withdraw(talk, "talk")
        talk = {since = frame}
        return false
    end
    local raw = cxx_string(msg + N_STRING)
    local codes = raw and codes_of(untagged(raw))
    if not codes or #codes == 0 then return true end
    local key = key_of(codes)
    if key ~= talk.key then
        withdraw(talk, "talk")
        talk = {key = key, since = frame}
        return true
    end
    if frame - talk.since < SETTLE then return true end
    if not talk.done then
        talk.done = true
        local speaker
        local name = nodes.textName
        if shown(name) then
            local n = cxx_string(name + N_STRING)
            n = n and codes_of(untagged(n))
            speaker = n and trimmed(n) or nil
            if speaker == "" then speaker = nil end
        end
        talk.text = shown_codes(codes)
        if #talk.text == 0 then return true end
        reader.emit{text = text_of(talk.text), speaker = speaker, window = "talk"}
    end
    -- Places: from the mesh, while it holds this text (a line of one row; a second row is
    -- built elsewhere).
    if talk.text and #talk.text > 0 and not talk.placed and mesh and mesh.quads
        and same(shown_codes(mesh.codes), talk.text) then
        local layout = cells(talk.text, mesh.quads, TALK_ORIGIN)
        if layout then
            reader.layout("talk", layout)
            talk.placed = true
        end
    end
    return true
end

reader.on_frame(function(frame)
    local list = screens()
    if #list == 0 then return end
    read_talk(frame, list, message_mesh(list))
end)
