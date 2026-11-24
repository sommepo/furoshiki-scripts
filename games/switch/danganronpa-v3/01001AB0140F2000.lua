-- reader: no hooks
-- reader: title ニューダンガンロンパV3 みんなのコロシアイ新学期 超高校級の決定版 (Danganronpa V3: Killing Harmony Anniversary Edition)
-- reader: reads Dialogue and narration (no speaker names)
-- reader: version Version 0
-- reader: touch press
-- reader: audio never
-- ニューダンガンロンパV3 みんなのコロシアイ新学期 超高校級の決定版
-- (Danganronpa V3: Killing Harmony Anniversary Edition), Switch.
-- Written for main build 09F57ACEA21909B977F07F7E5CBC7BBC (version 0, the only one).
--
-- A Unity game (2020.1, IL2CPP) that runs the PC game's own engine underneath: every frame
-- that engine hands Unity what to draw, among it a list of texts (the characters of each
-- text, with the corner points of every character in a 1920x1080 picture) and the state of
-- each of its screens. The profile reads the list the text manager was given last, takes
-- the message window's text from it (the one whose lines end in a line feed) and reports it
-- once the window waits for the button. Nothing is hooked, so the game runs natively (first
-- line of this file).
--
-- Read: the message window (events, talks, narration, what Kaede says of what she examines);
-- in class trials and in the virtual world by the same rules. Not read: who speaks (a picture
-- of the name), menus, the e-Handbook, the backlog, help pages, names over the map and of
-- what the cursor is on, the floating statements of a debate.

local BUILD = "09F57ACEA21909B977F07F7E5CBC7BBC"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The ways in (offsets into main): where the program keeps, once used, the class record of
-- the text manager and that of the singleton class that holds the game manager.
local TEXT_MANAGER_CLASS = 0x4394b58
local GAME_MANAGER_SINGLETON = 0x40c6020
local K_NAME, K_PARENT, K_STATICS = 0x10, 0x58, 0xb8 -- Il2CppClass
local SINGLETON = "SerializedMonoSingleton`1"

-- Managed objects: the class at 0, fields from 0x10.
local LIST_ITEMS, LIST_SIZE, ARRAY_DATA = 0x10, 0x18, 0x20 -- List<T> and its array

-- TextManager (a RenderManager<TextManager, TextList>): the last list of texts it was given.
local TM_MESSAGE = 0x60
local TL_TEXTS = 0x20                -- Msg.TextList: List<TextList.Types.TextInfo>
local TI_POS, TI_VIEWPORT, TI_VCOLOR, TI_CODES = 0x28, 0x30, 0x38, 0x40 -- TextInfo: lists
-- Codes are code points, tags included (<CLT=…> colours), a line feed after every line. Pos
-- has four numbers per character drawn (left, top, right, bottom in a 1920x1080 picture),
-- Vcolor two colours (RGBA, alpha in the low byte). Viewport is empty unless the text is
-- clipped (help pages, the names that scroll over the map).
local SPACE = { 1920, 1080 }

-- GameManager: the frame the engine sent last, and the state of its message screens.
local GM_UPDATE_FRAME = 0xc8
local UF_WRD = 0x28                  -- Msg.UpdateFrame: WrdScriptManager
local WRD_TRIAL, WRD_TANSAKU = 0x20, 0x28 -- TrialFlashManager, TansakuFlashManager
local TRF_MESSAGE = 0x10             -- TrialFlashManager: TrialMessage
local TAF_ADV, TAF_VR = 0x10, 0x20   -- TansakuFlashManager: AdvFlashManager, VrFlashManager
local ADV_MESSAGE, VR_MESSAGE = 0x10, 0x10 -- AdvMessage, VrMessage
local MODE = 0x10
-- A message is typed out, then whole while it waits for the button and while it goes after the
-- press.
local ADV_TYPING, ADV_WAIT, ADV_GOING = 2, 3, 4 -- AdvMessage, VrMessage: EAmmStart, …ButtonWait, …Animwaite
local TRIAL_TYPING, TRIAL_WAIT, TRIAL_GOING = 1, 2, 3 -- TrialMessage: Start, ButtonWait, Animwaite
-- A message is read once it has been whole for this many frames: the lines that the message
-- skip (B held) runs through are there for a frame at most.
local STEADY = 2
-- While a message goes, the next one's first characters can already be there, for two frames
-- on the device: a text that appears while a message goes counts once the screen has moved on
-- (typing it, or waiting for the button). One that appears while the screen waits (the first
-- line of a scene comes whole, without being typed) counts at once.

local WINDOW = "message"
local LINE_END = "\n" -- after every line of a message

-- ---------------------------------------------------------------------------------------
-- Reading the game's objects
-- ---------------------------------------------------------------------------------------

local function pointer(a)
    local p = a and mem.u64(a)
    if p and p > 0x10000 and p < 0x10000000000 then return p end
end

local function class_name(object)
    local class = pointer(object)
    local name = class and pointer(class + K_NAME)
    return name and mem.cstr(name, 64)
end

-- The items of a List<T> of objects.
local function objects(list)
    local out = {}
    local items, size = pointer(list and list + LIST_ITEMS), list and mem.s32(list + LIST_SIZE)
    if not items or not size or size <= 0 or size > 256 then return out end
    local raw = mem.read(items + ARRAY_DATA, 8 * size)
    if not raw or #raw < 8 * size then return out end
    for i = 1, size do out[i] = string.unpack("<I8", raw, 8 * i - 7) end
    return out
end

-- The raw bytes of a List<int> or List<float>, and how many items it has.
local function numbers(list)
    local items, size = pointer(list and list + LIST_ITEMS), list and mem.s32(list + LIST_SIZE)
    if not items or not size or size <= 0 or size > 8192 then return "", 0 end
    local raw = mem.read(items + ARRAY_DATA, 4 * size)
    if not raw or #raw < 4 * size then return "", 0 end
    return raw, size
end

-- The singleton held in the statics of `class`'s grandparent (RenderManager, then
-- SerializedMonoSingleton<T>).
local function text_manager()
    local class = pointer(base + TEXT_MANAGER_CLASS)
    if not class or mem.cstr(pointer(class + K_NAME) or 0, 32) ~= "TextManager" then return nil end
    local render = pointer(class + K_PARENT)
    local single = pointer(render and render + K_PARENT)
    if not single or mem.cstr(pointer(single + K_NAME) or 0, 40) ~= SINGLETON then return nil end
    local manager = pointer(pointer(single + K_STATICS))
    if manager and pointer(manager) == class then return manager end
end

local function game_manager()
    local single = pointer(base + GAME_MANAGER_SINGLETON)
    if not single or mem.cstr(pointer(single + K_NAME) or 0, 40) ~= SINGLETON then return nil end
    local manager = pointer(pointer(single + K_STATICS))
    if manager and class_name(manager) == "GameManager" then return manager end
end

local function mode_of(message)
    return message and mem.s32(message + MODE)
end

-- What the engine's message screens say of their text: "typing", "waiting" (all there, for
-- the button), "going" (all there, after the press), or nil.
local function message_state(update)
    local wrd = pointer(update and update + UF_WRD)
    if not wrd then return nil end
    local modes = {}
    local tansaku = pointer(wrd + WRD_TANSAKU)
    if tansaku then
        local adv, vr = pointer(tansaku + TAF_ADV), pointer(tansaku + TAF_VR)
        modes[1] = { mode_of(adv and pointer(adv + ADV_MESSAGE)), ADV_TYPING, ADV_WAIT, ADV_GOING }
        modes[2] = { mode_of(vr and pointer(vr + VR_MESSAGE)), ADV_TYPING, ADV_WAIT, ADV_GOING }
    end
    local trial = pointer(wrd + WRD_TRIAL)
    modes[#modes + 1] = { mode_of(trial and pointer(trial + TRF_MESSAGE)), TRIAL_TYPING, TRIAL_WAIT, TRIAL_GOING }
    local state
    for _, m in ipairs(modes) do
        if m[1] == m[3] then return "waiting" end
        if m[1] == m[4] then return "going" end
        if m[1] == m[2] then state = "typing" end
    end
    return state
end

local function whole(state) return state == "waiting" or state == "going" end

-- ---------------------------------------------------------------------------------------
-- The message window's text
-- ---------------------------------------------------------------------------------------

-- A text from the list: its code points as UTF-8 with the tags, and its bytes (for caching).
-- A surrogate pair, should one come, is one character.
local decoded, decoded_count = {}, 0
local function codes_of(info)
    local raw, count = numbers(pointer(info + TI_CODES))
    local known = decoded[raw]
    if known then return known, raw end
    local out = {}
    local i = 1
    while i <= count do
        local code = string.unpack("<i4", raw, 4 * i - 3)
        if code >= 0xD800 and code < 0xDC00 and i < count then
            local low = string.unpack("<i4", raw, 4 * i + 1)
            if low >= 0xDC00 and low < 0xE000 then
                code, i = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00), i + 1
            end
        end
        if code >= 0xD800 and code < 0xE000 then code = 0xFFFD end
        out[#out + 1] = (code >= 0x20 and code < 0x110000 or code == 0x0a) and utf8.char(code) or ""
        i = i + 1
    end
    local tagged = table.concat(out)
    if decoded_count >= 16 then decoded, decoded_count = {}, 0 end
    decoded[raw], decoded_count = tagged, decoded_count + 1
    return tagged, raw
end

-- The message: the text without its tags, a line a line, and where each character is.
local parsed_key, parsed
local function parse(info, tagged, raw_codes)
    local raw_pos, pos_count = numbers(pointer(info + TI_POS))
    local raw_colour, colour_count = numbers(pointer(info + TI_VCOLOR))
    local key = raw_codes .. "|" .. raw_pos .. "|" .. raw_colour
    if key == parsed_key then return parsed end
    local lines, line = {}, {}
    local at, drawn = 1, 0
    while at <= #tagged do
        local first = tagged:sub(at, at)
        if first == "<" then -- a tag, up to its ">"
            local close = tagged:find(">", at, true)
            if not close then break end
            at = close + 1
        elseif first == LINE_END then
            lines[#lines + 1], line = line, {}
            at = at + 1
        else
            local length = #utf8.char(utf8.codepoint(tagged, at))
            local ch = tagged:sub(at, at + length - 1)
            drawn = drawn + 1
            local quad, seen
            if 4 * drawn <= pos_count then
                quad = { string.unpack("<ffff", raw_pos, 16 * drawn - 15) }
                quad[5] = nil
                local alpha = 2 * drawn <= colour_count and string.byte(raw_colour, 8 * drawn - 7) or 0xff
                seen = alpha ~= 0
            end
            line[#line + 1] = { ch = ch, quad = quad, seen = seen }
            at = at + length
        end
    end
    if #line > 0 then lines[#lines + 1] = line end
    -- The text: the lines joined; a cell for every character that can be seen, as wide as from
    -- its left to the next one's (the last one of a line as wide as the line's characters
    -- usually are) and as high as its line.
    local texts, glyphs = {}, {}
    for l, chars_of in ipairs(lines) do
        local parts, top, bottom, steps = {}, math.huge, -math.huge, {}
        for i, c in ipairs(chars_of) do
            parts[#parts + 1] = c.ch
            local q, next_quad = c.quad, chars_of[i + 1] and chars_of[i + 1].quad
            if q then
                top, bottom = math.min(top, q[2]), math.max(bottom, q[4])
                if next_quad and next_quad[1] > q[1] then steps[#steps + 1] = next_quad[1] - q[1] end
            end
        end
        table.sort(steps)
        local step = steps[(#steps + 1) // 2] or 0
        texts[l] = table.concat(parts)
        if l > 1 then glyphs[#glyphs + 1] = false end -- the line break
        for i, c in ipairs(chars_of) do
            local q = c.quad
            if q and c.seen and bottom > top then
                local next_quad = chars_of[i + 1] and chars_of[i + 1].quad
                local right = next_quad and next_quad[1] > q[1] and next_quad[1] or math.max(q[3], q[1] + step)
                glyphs[#glyphs + 1] = { q[1], top, right - q[1], bottom - top }
            else
                glyphs[#glyphs + 1] = false
            end
        end
    end
    parsed_key, parsed = key, { text = table.concat(texts, "\n"), glyphs = glyphs }
    return parsed
end

-- The message window's entry in the list: a text whose lines end in a line feed and that is
-- not clipped; of several, the one that begins with a colour.
local function message_text(manager)
    local list = pointer(manager + TM_MESSAGE)
    if not list or class_name(list) ~= "TextList" then return nil end
    local found
    for _, info in ipairs(objects(pointer(list + TL_TEXTS))) do
        local _, clipped = numbers(pointer(info + TI_VIEWPORT))
        if clipped == 0 then
            local tagged, raw = codes_of(info)
            if tagged:find(LINE_END, 1, true) then
                if tagged:sub(1, 5) == "<CLT=" then return parse(info, tagged, raw) end
                found = found or { info, tagged, raw }
            end
        end
    end
    if found then return parse(found[1], found[2], found[3]) end
end

-- ---------------------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------------------

local shown -- {text, born (the state it appeared in), settled, since, emitted, placed}
local last_emitted -- the text emitted last, forgotten once the next message is typed: a window
                   -- hidden and shown again (L) is not read twice

local function withdraw()
    if shown and shown.placed then reader.layout(WINDOW, nil) end
    if shown then shown.placed = nil end
end

local function place(message)
    local key = {}
    for i, cell in ipairs(message.glyphs) do
        if cell then key[#key + 1] = string.format("%d:%.0f,%.0f,%.0f", i, cell[1], cell[2], cell[3]) end
    end
    if #key == 0 then return withdraw() end
    key = table.concat(key, " ")
    if key == shown.placed then return end
    local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
    for _, cell in ipairs(message.glyphs) do
        if cell then
            left, top = math.min(left, cell[1]), math.min(top, cell[2])
            right, bottom = math.max(right, cell[1] + cell[3]), math.max(bottom, cell[2] + cell[4])
        end
    end
    local margin = 16
    reader.layout(WINDOW, {
        space = SPACE,
        box = { left - margin, top - margin, right - left + 2 * margin, bottom - top + 2 * margin },
        glyphs = message.glyphs,
    })
    shown.placed = key
end

reader.on_frame(function(frame)
    local manager = text_manager()
    local game = game_manager()
    local state = game and message_state(pointer(game + GM_UPDATE_FRAME))
    if state == "typing" then last_emitted = nil end
    local message = manager and message_text(manager)
    if not message or message.text == "" then
        withdraw()
        shown = nil
        return
    end
    if not shown or shown.text ~= message.text then
        withdraw()
        shown = { text = message.text, born = state, settled = state ~= "going" }
    end
    if state ~= shown.born then shown.settled = true end
    if not shown.emitted then
        if message.text == last_emitted then
            shown.emitted = true -- shown again (the window hidden with L): read already
        else
            if not (whole(state) and shown.settled) then
                shown.since = nil
                return
            end
            shown.since = shown.since or frame
            if frame - shown.since + 1 < STEADY then return end
            reader.emit{ text = message.text, window = WINDOW }
            last_emitted = message.text
            shown.emitted = true
        end
    end
    place(message)
end)

-- For the harness: what the profile sees now.
function dr3_dump()
    local manager, game = text_manager(), game_manager()
    print(string.format("text manager %x, game manager %x", manager or 0, game or 0))
    local message = manager and message_text(manager)
    print(string.format("message %s, state %s", message and message.text or "-",
                        tostring(game and message_state(pointer(game + GM_UPDATE_FRAME)))))
    print(string.format("shown %s, read %s, placed %s; read last %s", shown and shown.text or "-",
                        tostring(shown and shown.emitted), tostring(shown and shown.placed ~= nil),
                        tostring(last_emitted)))
end
