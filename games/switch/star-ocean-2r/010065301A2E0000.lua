-- reader: no hooks
-- reader: title スターオーシャン セカンドストーリーR (STAR OCEAN THE SECOND STORY R)
-- reader: reads Dialogue, speakers, choices, captions, system messages, and party chat
-- reader: version The game with its update v131072
-- スターオーシャン セカンドストーリーR (STAR OCEAN THE SECOND STORY R), Switch.
-- Written for main build 7266AEB08847B0FA86D1B8B653D21402 (the game with its update v131072).
--
-- A Unity game (2021.3, IL2CPP) that shows its text with TextMesh Pro. Everything on screen
-- hangs off the game's UI manager, a singleton: its windows (the conversation window among
-- them) and its controllers (captions, the field's party chat, the events' echoes). The
-- profile finds the manager through a class the engine keeps at a fixed place in the program,
-- reads once a frame what each text object shows, and turns TextMesh Pro's table of
-- characters into places in the picture by following the text's transforms up to its canvas.
-- Nothing is hooked, so the game runs natively (first line of this file).
--
-- Read: the conversation balloons (with the speaker), the whole-screen and letterbox messages,
-- the captions of the scenes, the answers of a choice, the party's chat in the field, the
-- echoes of past lines, the system's message boxes. Not read: menus, lists, the conversation
-- log, help texts, names over the map, the opening film's credits (English: nothing but ASCII).

local BUILD = "7266AEB08847B0FA86D1B8B653D21402"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The way in (an offset into main): the engine's record of the generic class
-- SingletonBasicMonoBehaviour<GameUIManager>, filled in with the class once it exists. The
-- class's static fields hold the manager.
local UI_MANAGER_CLASS = 0x40d58a0
local K_NAME = 0x10              -- Il2CppClass: its name (C string)
local K_STATICS = 0xb8           -- Il2CppClass: its static fields
local SINGLETON = "SingletonBasicMonoBehaviour`1"

-- Managed objects: the class at 0, fields from 0x10.
local STR_LENGTH, STR_CHARS = 0x10, 0x14 -- System.String: UTF-16
local ARRAY_DATA = 0x20                  -- array: first element
local LIST_ITEMS, LIST_SIZE = 0x10, 0x18 -- List<T>
local DICT_ENTRIES, DICT_COUNT = 0x18, 0x20 -- Dictionary<K, V>: entries of 0x18 bytes
local ENTRY_SIZE, ENTRY_VALUE = 0x18, 0x10

-- The game's UI.
local M_WINDOWS = 0x18           -- GameUIManager: WindowController
local M_CONTROLLERS = 0x28       -- GameUIManager: Dictionary<UIControllerType, UIControllerBase>
local WC_WINDOWS = 0x10          -- WindowController: Dictionary<WindowType, WindowComponent>
local WINDOW_DIALOG, WINDOW_CONVERSATION = 1, 5          -- UIDefine.WindowType
local CONTROLLER_FIELD, CONTROLLER_EVENT, CONTROLLER_CAPTION = 1, 3, 5 -- UIControllerType
local P_SHOWING = 0x9a           -- UIAnimationPresenterBase: bool isShowing
local P_CLOSING = 0xb5           -- UIAnimationPresenterBase: bool isClosing
local P_CANVAS_GROUP = 0xd0      -- UIAnimationPresenterBase: CanvasGroup (fades)
local CW_SELECTOR = 0x98         -- UIConversationWindow: UIConversationSelector
local CW_CHOICES = 0xa8          -- UIConversationWindow: UISelectChoiceSelector
local CW_LOG = 0xd0              -- UIConversationWindow: List<UIConversationLogListItemData>, the
                                 -- log, which gets each message whole as it is begun
local LOG_MESSAGE = 0x28         -- UIConversationLogListItemData: string message
local CS_PRESENTERS = 0x90       -- UIConversationSelector: List<UIConversationPresenter>
local CS_ENTIRE = 0x98           -- UIConversationSelector: UIEntireMessagePresenter
local CS_CINEMA = 0xa0           -- UIConversationSelector: GameText (the letterbox message)
local CS_FAST_FORWARD = 0xe0     -- UIConversationSelector: bool isFastForward
local CP_MESSAGE = 0xf0          -- UIConversationPresenter: GameText message
local CP_TALKER = 0xf8           -- UIConversationPresenter: GameText talkerName
local CP_FEED = 0x138            -- UIConversationPresenter: TextFeedController
local EP_MESSAGE, EP_FEED = 0xf0, 0x108 -- UIEntireMessagePresenter
local F_FEEDER = 0x28            -- TextFeedController: TextFeeder
local F_STATE = 0x30             -- TextFeedController: State (None, TextFeeding, Completed, EndDisplay)
local COMPLETED = 2
local FD_COMPLETED = 0x10        -- TextFeeder: string completedText, the whole line
local SC_PRESENTER = 0x90        -- UISelectChoiceSelector: UISelectChoicePresenter
local SP_CHOICES = 0xf0          -- UISelectChoicePresenter: List<UIChoicePresenter>
local CH_MESSAGE = 0xf8          -- UIChoicePresenter: GameText message
local CC_SELECTOR = 0xa8         -- UICaptionController: UICaptionSelector
local CAPTION_PRESENTERS = { 0x90, 0x98 } -- UICaptionSelector: captionPresenter, movieCaptionPresenter
local CAPTION_LIST = 0xa0        -- UICaptionSelector: List<UICaptionPresenter>
local CAP_TEXT = 0xf0            -- UICaptionPresenter: GameText caption
local FC_PARTY = 0x100           -- UIFieldController: UIPartyConversationSelector
local PS_PRESENTER = 0x90        -- UIPartyConversationSelector: UIPartyConversationPresenter
local PP_MESSAGES = 0xf0         -- UIPartyConversationPresenter: List<UIPartyMessagePresenter>
local PM_MESSAGE = 0xf0          -- UIPartyMessagePresenter: GameText message
local PM_CANVAS_GROUP = 0x100    -- UIPartyMessagePresenter: CanvasGroup
local EC_ECHO = 0xb8             -- UIEventController: UIEventEchoPresenter
local ECHO_TEXT = 0xf0           -- UIEventEchoPresenter: GameText echo
local DW_PRESENTER = 0xf0        -- UIDialogWindow: UIDialogPresenter currentPresenter
local DP_TEXTS = { 0x108, 0x110 } -- UIDialogPresenter: GameText message, centerMessage

-- TextMeshPro (TMP_Text, TextMeshProUGUI).
local T_TEXT = 0xd0              -- string m_text
local T_INFO = 0x360             -- TMP_TextInfo m_textInfo
local T_DIRTY = 0x368            -- bool m_havePropertiesChanged: m_textInfo is not for m_text yet
local T_RECT = 0x378             -- RectTransform m_rectTransform
local T_CLIP = 0x6d8             -- Rect m_ClipRect: what a mask lets be seen, in the canvas's
local T_CLIPPED = 0x6e8          -- coordinates; bool m_ValidRect: there is such a mask
local T_CANVAS = 0x720           -- Canvas m_canvas
local I_COUNT = 0x18             -- TMP_TextInfo: int characterCount
local I_CHARS = 0x38             -- TMP_TextInfo: TMP_CharacterInfo[] characterInfo
local C_SIZE = 0x178             -- TMP_CharacterInfo
local C_CHAR, C_INDEX = 0x00, 0x04 -- char character, int index (into m_text, in UTF-16 units)
local C_ORIGIN = 0x120           -- floats: origin, xAdvance, ascender, baseLine, descender
local C_ALPHA = 0x147            -- byte: the alpha of Color32 color
local C_VISIBLE = 0x174          -- bool isVisible

-- The engine's objects (Unity 2021.3, 64-bit).
local O_NATIVE = 0x10            -- UnityEngine.Object: the engine's own object
local N_OBJECT = 0x30            -- component: its GameObject
local G_COMPONENTS = 0x30        -- GameObject: array of {type, component}, 16 bytes each
local G_ACTIVE = 0x57            -- GameObject: active in the hierarchy (it and all above it)
local CG_ALPHA = 0x38            -- CanvasGroup (the engine's): float alpha
local X_HIERARCHY = 0x38         -- Transform: the hierarchy it is in
local X_INDEX = 0x40             -- Transform: its index there
local X_RECT = 0xb8              -- RectTransform: x, y, width, height in its own coordinates
local H_LOCAL = 0x18             -- hierarchy: per transform 0x30 bytes: position, rotation, scale
local H_PARENT = 0x20            -- hierarchy: per transform the index of its parent, -1 at the root

-- Frames a text must have stood complete before it is read: the game's fast-forward and a
-- press of the button in the middle of the typing go through lines faster.
local STEADY = 6

local function pointer(a)
    local p = a and mem.u64(a)
    return p and p > 0x10000 and p < 0x8000000000 and p or nil
end

local function utf16(p)
    if not p then return "" end
    local n = mem.s32(p + STR_LENGTH)
    if not n or n <= 0 or n > 8192 then return "" end
    return mem.read(p + STR_CHARS, n * 2)
end

local function class_name(object)
    local class = pointer(object)
    local name = class and pointer(class + K_NAME)
    return name and mem.cstr(name, 64) or ""
end

local function list(l)
    local items, size = l and pointer(l + LIST_ITEMS), l and mem.s32(l + LIST_SIZE)
    local out = {}
    if not items or not size or size < 0 or size > 64 then return out end
    local raw = mem.read(items + ARRAY_DATA, 8 * size)
    for i = 0, #raw // 8 - 1 do
        local p = string.unpack("<I8", raw, 8 * i + 1)
        out[#out + 1] = p > 0x10000 and p or nil
    end
    return out
end

local function lookup(dict, key)
    local entries, count = dict and pointer(dict + DICT_ENTRIES), dict and mem.s32(dict + DICT_COUNT)
    if not entries or not count or count < 0 or count > 256 then return nil end
    local raw = mem.read(entries + ARRAY_DATA, ENTRY_SIZE * count)
    for i = 0, #raw // ENTRY_SIZE - 1 do
        local hash, _, k = string.unpack("<i4i4i4", raw, ENTRY_SIZE * i + 1)
        if hash >= 0 and k == key then
            return pointer(entries + ARRAY_DATA + ENTRY_SIZE * i + ENTRY_VALUE)
        end
    end
    return nil
end

-- The engine's own object of a managed one, and whether a component's GameObject is shown.
local function native(object) return object and pointer(object + O_NATIVE) end

local function active(component)
    local n = native(component)
    local game_object = n and pointer(n + N_OBJECT)
    return game_object ~= nil and mem.u8(game_object + G_ACTIVE) == 1
end

-- A presenter of the game's UI that is shown, not on its way out and not faded out.
local function presenting(presenter, group_at)
    if not presenter or mem.u8(presenter + P_SHOWING) ~= 1 or mem.u8(presenter + P_CLOSING) ~= 0 then
        return false
    end
    local group = native(pointer(presenter + (group_at or P_CANVAS_GROUP)))
    if group and (mem.f32(group + CG_ALPHA) or 1) <= 0 then return false end
    return true
end

-- ---------------------------------------------------------------------------------------
-- Text: what is shown, without TextMesh Pro's tags
-- ---------------------------------------------------------------------------------------

-- A string as the game gave it (UTF-16) taken apart: the text without tags (UTF-8), for each
-- UTF-16 unit of the string the place (code point, from 1) it has in that text or nil for a
-- unit of a tag, and the number of code points.
local function strip(raw)
    local units = {}
    for i = 1, #raw - 1, 2 do units[#units + 1] = string.unpack("<I2", raw, i) end
    local out, places, n = {}, {}, 0
    local i = 1
    while i <= #units do
        local u = units[i]
        if u == 0x3C then -- "<": a tag up to the next ">"
            local j = i + 1
            while j <= #units and units[j] ~= 0x3E and units[j] ~= 0x3C and j - i < 64 do j = j + 1 end
            if j <= #units and units[j] == 0x3E then
                i = j + 1
                goto continue
            end
        end
        if u >= 0xD800 and u <= 0xDBFF and units[i + 1] then
            n = n + 1
            places[i], places[i + 1] = n, n
            out[n] = utf8.char(0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00))
            i = i + 2
        else
            n = n + 1
            places[i] = n
            out[n] = utf8.char(u)
            i = i + 1
        end
        ::continue::
    end
    return table.concat(out), places, n
end

-- strip() of the last few strings: a text stands for many frames.
local stripped = {}
local stripped_count = 0
local function strip_once(raw)
    local known = stripped[raw]
    if known then return known[1], known[2], known[3] end
    local text, places, count = strip(raw)
    if stripped_count >= 32 then stripped, stripped_count = {}, 0 end
    stripped[raw] = { text, places, count }
    stripped_count = stripped_count + 1
    return text, places, count
end

-- ---------------------------------------------------------------------------------------
-- Where a text object is in the picture
-- ---------------------------------------------------------------------------------------

local function own_transform(component)
    local n = native(component)
    local game_object = n and pointer(n + N_OBJECT)
    local components = game_object and pointer(game_object + G_COMPONENTS)
    return components and pointer(components + 8) -- a GameObject's first component is its transform
end

-- Scale and offset that take a transform's own coordinates to its canvas's: {sx, sy, ox, oy}.
local function to_canvas(node, stop)
    local hierarchy, index = pointer(node + X_HIERARCHY), mem.s32(node + X_INDEX)
    if not hierarchy or not index then return nil end
    local locals, parents = pointer(hierarchy + H_LOCAL), pointer(hierarchy + H_PARENT)
    if not locals or not parents then return nil end
    local sx, sy, ox, oy = 1, 1, 0, 0
    for _ = 1, 64 do
        if index == stop then return { sx, sy, ox, oy } end
        if not index or index < 0 then return nil end
        local raw = mem.read(locals + index * 0x30, 0x30)
        if #raw < 0x30 then return nil end
        local tx, ty, _, _, _, _, _, _, kx, ky = string.unpack("<ffffffffff", raw)
        sx, sy, ox, oy = sx * kx, sy * ky, tx + kx * ox, ty + ky * oy
        index = mem.s32(parents + 4 * index)
    end
    return nil
end

-- What turns a text object's coordinates into pixels of the picture (y down):
-- {scale x, scale y, offset x, offset y}, or nil while that cannot be told. A text's canvas
-- covers the whole picture.
local function placement(tmp, node)
    local canvas = own_transform(pointer(tmp + T_CANVAS))
    node = node or native(pointer(tmp + T_RECT))
    if not canvas or not node or pointer(canvas + X_HIERARCHY) ~= pointer(node + X_HIERARCHY) then
        return nil
    end
    local chain = to_canvas(node, mem.s32(canvas + X_INDEX))
    local raw = mem.read(canvas + X_RECT, 16)
    if not chain or #raw < 16 then return nil end
    local rx, ry, rw, rh = string.unpack("<ffff", raw)
    local width, height = reader.picture()
    if not width or rw <= 0 or rh <= 0 then return nil end
    local px, py = width / rw, height / rh
    local sx, sy, ox, oy = table.unpack(chain)
    local place = { sx * px, -sy * py, (ox - rx) * px, height - (oy - ry) * py }
    -- What a mask over the text lets be seen: {left, top, right, bottom} in the picture.
    if mem.u8(tmp + T_CLIPPED) == 1 then
        local cx, cy, cw, ch = string.unpack("<ffff", mem.read(tmp + T_CLIP, 16))
        place.clip = { (cx - rx) * px, height - (cy + ch - ry) * py,
                       (cx + cw - rx) * px, height - (cy - ry) * py }
    end
    return place
end

-- The cells of the characters TextMesh Pro has laid out for a text object, by the place of
-- each in the text without tags (`raw`, as the object has it): {left, top, width, height} in
-- the picture, put into `out` from `offset` on. A character that is not one of the text's
-- (the game adds one to make room for its wait mark), that is transparent or that a mask
-- hides (a long message's first lines in its balloon) has no cell. Returns false while the
-- table is not for the object's text.
local function cells(tmp, raw_text, places, offset, out, state)
    if mem.u8(tmp + T_DIRTY) ~= 0 then return false end
    local info = pointer(tmp + T_INFO)
    local count = info and mem.s32(info + I_COUNT)
    local array = info and pointer(info + I_CHARS)
    if not count or count < 0 or count > 2000 or not array then return false end
    local place = placement(tmp)
    if not place then return false end
    local clip = place.clip
    -- Nothing to do when the text object, its text and its place are as they were.
    local key = string.format("%x %d %d %.2f %.2f %.1f %.1f %s", tmp, #raw_text, count, place[1], place[2],
                              place[3], place[4], clip and table.concat(clip, ",") or "-")
    if state then
        if state.cells_key == key then return "same" end
        state.cells_key = key
    end
    local raw = mem.read(array + ARRAY_DATA, count * C_SIZE)
    for i = 0, #raw // C_SIZE - 1 do
        local at = i * C_SIZE
        local code = string.unpack("<I2", raw, at + C_CHAR + 1)
        local index = string.unpack("<i4", raw, at + C_INDEX + 1)
        local spot = places[index + 1]
        local unit = 2 * index + 2 <= #raw_text and string.unpack("<I2", raw_text, 2 * index + 1)
        if spot and unit == code and raw:byte(at + C_VISIBLE + 1) ~= 0 and
            raw:byte(at + C_ALPHA + 1) ~= 0 then
            local origin, advance, ascender, _, descender = string.unpack("<fffff", raw, at + C_ORIGIN + 1)
            local left, right = place[3] + place[1] * origin, place[3] + place[1] * advance
            local top, bottom = place[4] + place[2] * ascender, place[4] + place[2] * descender
            local middle = (top + bottom) / 2
            if not clip or (middle >= clip[2] and middle <= clip[4]) then
                out[offset + spot] = { left, top, right - left, bottom - top }
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------
-- What is reported
-- ---------------------------------------------------------------------------------------

local shown = {} -- by window name: {text, since, emitted, placed}

local function close(name)
    local state = shown[name]
    if state then state.cells_key = nil end
    if state and state.placed then
        reader.layout(name, nil)
        state.placed = nil
    end
end

local function forget(name)
    close(name)
    shown[name] = nil
end

-- Reports where the characters of a text that was emitted are now (or that it is gone).
local function place(name, count, glyphs)
    local state = shown[name]
    local cells_, key = {}, {}
    for i = 1, count do
        local cell = glyphs[i]
        cells_[i] = cell or false
        if cell then key[#key + 1] = string.format("%d:%.0f,%.0f", i, cell[1], cell[2]) end
    end
    if #key == 0 then return close(name) end
    key = table.concat(key, " ")
    if key ~= state.placed then
        local width, height = reader.picture()
        reader.layout(name, { space = { width, height }, glyphs = cells_ })
        state.placed = key
    end
end

-- Something to read: not blank, and not all ASCII (the credits over the opening film are
-- captions in English).
local function readable(value)
    local rest = value:gsub("\227\128\128", "")
    return rest:find("%S") ~= nil and rest:find("[\128-\255]") ~= nil
end

local function emit(name, state)
    if readable(state.text) then
        reader.emit{ text = state.text, speaker = state.speaker, channel = state.channel, window = name }
        state.emitted = true
    else
        state.emitted = "blank"
    end
end

-- A text that was there whole, and goes before it was read (the button pressed at once), is
-- read as it goes; not when the game's fast-forward ran through it.
local function leave(name)
    local state = shown[name]
    if state and not state.emitted and not state.held then emit(name, state) end
    forget(name)
end

-- A text that has stood long enough is emitted once; a new one (or the same again after it
-- was gone) is new. While `hold` (the game's fast-forward) a text that was not read yet waits.
-- Returns whether the text has been emitted (and may be placed).
local function offer(name, text, frame, info)
    local state = shown[name]
    if not state or state.text ~= text then
        if state then leave(name) end
        state = { text = text, since = frame, speaker = info.speaker, channel = info.channel }
        shown[name] = state
    end
    if info.hold and not state.emitted then
        state.since, state.held = frame, true
    end
    if not state.emitted and frame - state.since >= STEADY then emit(name, state) end
    return state.emitted == true
end

-- One text object that shows `whole_raw` or, when the object holds less, its end.
local function show(name, tmp, frame, info)
    local whole_raw = info.whole or utf16(pointer(tmp + T_TEXT))
    if whole_raw == "" then return forget(name) end
    local whole, places, total = strip_once(whole_raw)
    if not offer(name, whole, frame, info) then return end
    local offset, raw = 0, whole_raw
    if info.whole then
        local text, count
        raw = utf16(pointer(tmp + T_TEXT))
        text, places, count = strip_once(raw)
        if whole:sub(-#text) ~= text then return close(name) end
        offset = total - count
    end
    local glyphs = {}
    local state = shown[name]
    local done = cells(tmp, raw, places, offset, glyphs, state)
    if done == true then
        place(name, total, glyphs)
    elseif not done then
        state.cells_key = nil
    end
end

-- Texts that are one (the answers of a choice): one line each.
local function show_lines(name, tmps, frame, info)
    local lines, parts = {}, {}
    for i, tmp in ipairs(tmps) do
        local raw = utf16(pointer(tmp + T_TEXT))
        local text, places, count = strip_once(raw)
        lines[i], parts[i] = text, { tmp, raw, places, count }
    end
    local whole = table.concat(lines, "\n")
    if whole == "" then return forget(name) end
    if not offer(name, whole, frame, info) then return end
    local glyphs, offset = {}, 0
    for _, part in ipairs(parts) do
        if not cells(part[1], part[2], part[3], offset, glyphs) then return end
        offset = offset + part[4] + 1
    end
    place(name, utf8.len(whole) or 0, glyphs)
end

-- ---------------------------------------------------------------------------------------
-- The texts of the game's UI
-- ---------------------------------------------------------------------------------------

local function fed(feed)
    -- A typed text, once it is complete: what the typing ended with. A message longer than its
    -- balloon has lost its first lines there by then.
    if not feed or mem.s32(feed + F_STATE) ~= COMPLETED then return nil end
    local feeder = pointer(feed + F_FEEDER)
    local whole = utf16(feeder and pointer(feeder + FD_COMPLETED))
    return whole ~= "" and whole or nil
end

-- The whole message whose end a balloon shows: the newest entry of the log that ends so.
local last_tail, last_whole
local function logged(window, tail)
    if tail == last_tail then return last_whole end
    last_tail, last_whole = tail, tail
    local entries = list(window and pointer(window + CW_LOG))
    for i = #entries, math.max(1, #entries - 7), -1 do
        local message = utf16(pointer(entries[i] + LOG_MESSAGE))
        if #message >= #tail and message:sub(-#tail) == tail then
            last_whole = message
            return message
        end
    end
    return tail
end

local function conversation(window, selector, frame, seen)
    local fast = mem.u8(selector + CS_FAST_FORWARD) == 1
    for i, presenter in ipairs(list(pointer(selector + CS_PRESENTERS))) do
        if i > 8 then break end
        local name = "message." .. i
        local message = pointer(presenter + CP_MESSAGE)
        local whole = presenting(presenter) and message and active(message) and
            fed(pointer(presenter + CP_FEED))
        if whole then
            seen[name] = true
            whole = logged(window, whole)
            local talker = pointer(presenter + CP_TALKER)
            local speaker = talker and active(talker) and text.utf16le(utf16(pointer(talker + T_TEXT))) or ""
            show(name, message, frame, { whole = whole, hold = fast, speaker = speaker ~= "" and speaker or nil })
        end
    end
    local entire = pointer(selector + CS_ENTIRE)
    local message = entire and pointer(entire + EP_MESSAGE)
    local whole = presenting(entire) and message and active(message) and fed(pointer(entire + EP_FEED))
    if whole then
        seen.entire = true
        show("entire", message, frame, { whole = whole, hold = fast })
    end
    local cinema = pointer(selector + CS_CINEMA)
    if cinema and active(cinema) then
        seen.cinema = true
        show("cinema", cinema, frame, { hold = fast })
    end
end

local function choices(selector, frame, seen)
    local presenter = selector and pointer(selector + SC_PRESENTER)
    if not presenting(presenter) then return end
    local tmps = {}
    for _, choice in ipairs(list(pointer(presenter + SP_CHOICES))) do
        local message = pointer(choice + CH_MESSAGE)
        if message and active(message) then tmps[#tmps + 1] = message end
    end
    if #tmps == 0 then return end
    seen.choice = true
    show_lines("choice", tmps, frame, { channel = "choice" })
end

local function captions(controller, frame, seen)
    local selector = controller and pointer(controller + CC_SELECTOR)
    if not selector then return end
    local presenters, known = {}, {}
    for _, at in ipairs(CAPTION_PRESENTERS) do
        local p = pointer(selector + at)
        if p and not known[p] then presenters[#presenters + 1], known[p] = p, true end
    end
    for _, p in ipairs(list(pointer(selector + CAPTION_LIST))) do
        if not known[p] then presenters[#presenters + 1], known[p] = p, true end
    end
    for i, presenter in ipairs(presenters) do
        if i > 8 then break end
        local tmp = pointer(presenter + CAP_TEXT)
        if presenting(presenter) and tmp and active(tmp) then
            local name = "caption." .. i
            seen[name] = true
            show(name, tmp, frame, {})
        end
    end
end

local function party(controller, frame, seen)
    local selector = controller and pointer(controller + FC_PARTY)
    local presenter = selector and pointer(selector + PS_PRESENTER)
    if not presenter or not active(presenter) then return end
    for i, message_presenter in ipairs(list(pointer(presenter + PP_MESSAGES))) do
        if i > 8 then break end
        local tmp = pointer(message_presenter + PM_MESSAGE)
        if presenting(message_presenter, PM_CANVAS_GROUP) and tmp and active(tmp) then
            local name = "party." .. i
            seen[name] = true
            show(name, tmp, frame, {})
        end
    end
end

local function echo(controller, frame, seen)
    local presenter = controller and pointer(controller + EC_ECHO)
    local tmp = presenter and pointer(presenter + ECHO_TEXT)
    if presenting(presenter) and tmp and active(tmp) then
        seen.echo = true
        show("echo", tmp, frame, {})
    end
end

local function dialog(window, frame, seen)
    local presenter = window and pointer(window + DW_PRESENTER)
    if not presenting(presenter) then return end
    for i, at in ipairs(DP_TEXTS) do
        local tmp = pointer(presenter + at)
        if tmp and active(tmp) then
            local name = "dialog." .. i
            seen[name] = true
            show(name, tmp, frame, {})
        end
    end
end

local manager_class

reader.on_frame(function(frame)
    -- The manager: through its class, once the engine has made it.
    local class = pointer(base + UI_MANAGER_CLASS)
    if not class or mem.cstr(pointer(class + K_NAME) or 0, 40) ~= SINGLETON then return end
    manager_class = class
    local statics = pointer(class + K_STATICS)
    local manager = statics and pointer(statics)
    if not manager or class_name(manager) ~= "GameUIManager" then return end

    local seen = {}
    local controller = pointer(manager + M_WINDOWS)
    local windows = controller and pointer(controller + WC_WINDOWS)
    local conversation_window = lookup(windows, WINDOW_CONVERSATION)
    local selector = conversation_window and pointer(conversation_window + CW_SELECTOR)
    if selector then conversation(conversation_window, selector, frame, seen) end
    if conversation_window then choices(pointer(conversation_window + CW_CHOICES), frame, seen) end
    dialog(lookup(windows, WINDOW_DIALOG), frame, seen)
    local controllers = pointer(manager + M_CONTROLLERS)
    captions(lookup(controllers, CONTROLLER_CAPTION), frame, seen)
    party(lookup(controllers, CONTROLLER_FIELD), frame, seen)
    echo(lookup(controllers, CONTROLLER_EVENT), frame, seen)

    for name in pairs(shown) do
        if not seen[name] then leave(name) end
    end
end)

-- For the harness (lua so2r_dump()): what the profile holds.
function so2r_dump()
    print(string.format("manager class %x", manager_class or 0))
    for name, state in pairs(shown) do
        print(string.format("%s: %s since %d emitted %s placed %s", name, state.text:gsub("\n", "/"),
                            state.since, tostring(state.emitted), state.placed and "yes" or "no"))
    end
end
