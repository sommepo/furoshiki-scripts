-- reader: no hooks
-- reader: api 3
-- reader: title 逆転裁判123 成歩堂セレクション (Phoenix Wright: Ace Attorney Trilogy)
-- reader: reads Dialogue (all three games)
-- reader: version The first release (v0)
-- reader: touch game
-- reader: audio never
-- 逆転裁判123 成歩堂セレクション (Phoenix Wright: Ace Attorney Trilogy), Switch.
-- Written for main build 12B57556658E4F4482F043BBBD2DA73B (the first release, v0).
--
-- A Unity game (2017.4, IL2CPP) around the old games' own script machine. The message window
-- is three lines of Unity's own Text, typed out a character at a time, and the machine's
-- state says when it waits for the button. The profile finds both through classes the engine
-- keeps at fixed places in the program, reads them once a frame, and takes each character's
-- place from the vertices Unity made for the text. Nothing is hooked, so the game runs
-- natively (first line of this file).
--
-- Read: the message window. Not read: the speaker (a picture), the answers of a choice, the
-- court record, menus. The lines have no voices (fifth line of this file).

local BUILD = "12B57556658E4F4482F043BBBD2DA73B"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The ways in (offsets into main): the engine's records of two classes, filled in with the
-- class once it has been used.
local BOARD_CLASS = 0x24b43b8    -- messageBoardCtrl
local STATE_CLASS = 0x24b43a8    -- GSStatic
local K_STATICS = 0xa0           -- Il2CppClass (Unity 2017): its static fields

-- Managed objects: the class at 0, fields from 0x10.
local STR_LENGTH, STR_CHARS = 0x10, 0x14 -- System.String: UTF-16
local ARRAY_DATA = 0x20                  -- array: first element
local LIST_ITEMS, LIST_SIZE = 0x10, 0x18 -- List<T>

-- The game.
local B_INSTANCE = 0x00          -- messageBoardCtrl statics: instance_
local B_LINES = 0x40             -- messageBoardCtrl: List<Text> line_list_
local S_MESSAGE = 0x18           -- GSStatic statics: MessageWork message_work_
local M_STATUS = 0x10            -- MessageWork: MessageSystem.Status status_
local WAITING = 0x1              -- Status.RT_WAIT: the message is all there and waits for the button

-- Unity's Text (UnityEngine.UI, 2017.4).
local T_RECT = 0x38              -- Graphic: RectTransform m_RectTransform
local T_CANVAS = 0x48            -- Graphic: Canvas m_Canvas
local T_TEXT = 0xb8              -- Text: string m_Text
local T_CACHE = 0xc0             -- Text: TextGenerator m_TextCache
local G_LAST = 0x18              -- TextGenerator: string m_LastString, what the vertices are for
local G_SCALE = 0x44             -- TextGenerator: m_LastSettings.scaleFactor: the vertices are in
                                 -- pixels of the canvas as it is drawn, this many to one of the
                                 -- text object's own units (1 docked, two thirds handheld)
local G_VERTS = 0x88             -- TextGenerator: List<UIVertex> m_Verts, four to a character
local V_SIZE = 76                -- UIVertex: its position (three floats) first

-- The engine's objects (Unity 2017.4, 64-bit).
local O_NATIVE = 0x10            -- UnityEngine.Object: the engine's own object
local N_OBJECT = 0x30            -- component: its GameObject
local G_COMPONENTS = 0x30        -- GameObject: array of {type, component}, 16 bytes each
local X_HIERARCHY = 0x38         -- Transform: the hierarchy it is in
local X_INDEX = 0x40             -- Transform: its index there
local X_RECT = 0xb8              -- RectTransform: x, y, width, height in its own coordinates
local H_LOCAL = 0x08             -- hierarchy: per transform 0x30 bytes: position, rotation, scale
local H_PARENT = 0x10            -- hierarchy: per transform the index of its parent, -1 at the root

-- Frames a message must have waited for the button before it is read (the game's skip goes
-- through messages faster), and frames one that never waits must have stood unchanged.
local STEADY, UNCHANGED = 3, 45

local function pointer(a)
    local p = a and mem.u64(a)
    return p and p > 0x10000 and p < 0x8000000000 and p or nil
end

local function str_raw(p)
    if not p then return "" end
    local n = mem.s32(p + STR_LENGTH)
    if not n or n <= 0 or n > 2048 then return "" end
    return mem.read(p + STR_CHARS, n * 2)
end

-- A class's static fields, or nil while the game has not used the class yet.
local function statics(slot)
    local class = pointer(base + slot)
    return class and pointer(class + K_STATICS)
end

-- Where a text object is in the picture: {scale x, scale y, offset x, offset y, width, height}
-- that turn its coordinates into pixels (y down) of a picture of that size, or nil while that
-- cannot be told. The canvas is drawn over the whole picture, so its rectangle is the picture.
local function placement(object)
    local rect, canvas = pointer(object + T_RECT), pointer(object + T_CANVAS)
    local node = rect and pointer(rect + O_NATIVE)
    local native_canvas = canvas and pointer(canvas + O_NATIVE)
    if not node or not native_canvas then return nil end
    local game_object = pointer(native_canvas + N_OBJECT)
    local list = game_object and pointer(game_object + G_COMPONENTS)
    -- A GameObject's first component is its transform.
    local top = list and pointer(list + 8)
    if not top then return nil end
    local hierarchy, index = pointer(node + X_HIERARCHY), mem.s32(node + X_INDEX)
    local stop = mem.s32(top + X_INDEX)
    if not hierarchy or pointer(top + X_HIERARCHY) ~= hierarchy then return nil end
    local locals, parents = pointer(hierarchy + H_LOCAL), pointer(hierarchy + H_PARENT)
    if not locals or not parents then return nil end
    local sx, sy, ox, oy = 1, 1, 0, 0
    local steps = 0
    while index ~= stop do
        if not index or index < 0 or steps > 64 then return nil end
        local raw = mem.read(locals + index * 0x30, 0x30)
        if #raw < 0x30 then return nil end
        local tx, ty, _, _, _, _, _, _, kx, ky = string.unpack("<ffffffffff", raw)
        sx, sy, ox, oy = sx * kx, sy * ky, tx + kx * ox, ty + ky * oy
        index = mem.s32(parents + 4 * index)
        steps = steps + 1
    end
    local raw = mem.read(top + X_RECT, 16)
    if #raw < 16 then return nil end
    local rx, ry, rw, rh = string.unpack("<ffff", raw)
    local width, height = reader.picture()
    if not width or rw <= 0 or rh <= 0 then return nil end
    local px, py = width / rw, height / rh
    -- canvas x = ox + sx * x, picture x = (canvas x - rx) * px; y likewise, upside down
    local own = mem.read(node + X_RECT, 16)
    if #own < 16 then return nil end
    return { sx * px, -sy * py, (ox - rx) * px, height - (oy - ry) * py, width, height,
             rect = { string.unpack("<ffff", own) } }
end

-- A line of the window as the game wrote it: its characters without the colour marks around
-- them ("<color=#68c0f0>…</color>"), each with its place among everything written.
local function visible(raw)
    local out = {}
    local i, n = 0, #raw // 2
    while i < n do
        local unit = raw:sub(i * 2 + 1, i * 2 + 2)
        if unit == "<\0" then
            local close = i
            while close < n and raw:sub(close * 2 + 1, close * 2 + 2) ~= ">\0" do close = close + 1 end
            if close < n then
                i = close + 1
            else
                out[#out + 1] = { unit = unit, at = i }
                i = i + 1
            end
        else
            out[#out + 1] = { unit = unit, at = i }
            i = i + 1
        end
    end
    return out
end

-- The left edge of every character Unity laid out for a text object, by the character's
-- place in the text: four vertices to a character, the first its top left corner.
local function edges(object, raw, chars)
    local cache = pointer(object + T_CACHE)
    if not cache or str_raw(pointer(cache + G_LAST)) ~= raw then return nil end
    local verts = pointer(cache + G_VERTS)
    local items, size = verts and pointer(verts + LIST_ITEMS), verts and mem.s32(verts + LIST_SIZE)
    if not items or not size or size < 4 or size > 4096 then return nil end
    local quads = size // 4
    local by_place = quads >= #raw // 2 -- a quad for every character written, marks included
    if not by_place and quads < #chars then return nil end
    local data = mem.read(items + ARRAY_DATA, size * V_SIZE)
    if #data < size * V_SIZE then return nil end
    local scale = mem.f32(cache + G_SCALE)
    if not scale or scale <= 0 or scale > 16 then return nil end
    local out = {}
    for index, char in ipairs(chars) do
        local quad = by_place and char.at or index - 1
        local left = string.unpack("<f", data, quad * 4 * V_SIZE + 1)
        local right = string.unpack("<f", data, (quad * 4 + 1) * V_SIZE + 1)
        out[index] = { left / scale, right / scale }
    end
    return out
end

local last          -- what the window's lines held when last looked at
local since         -- the frame they came to hold it
local waited = 0    -- frames the message has waited for the button
local reported      -- what was reported, as the lines held it
local shown = false

local function withdraw()
    if shown then
        reader.layout("message", nil)
        shown = false
    end
end

reader.on_frame(function(frame)
    local board_statics, state_statics = statics(BOARD_CLASS), statics(STATE_CLASS)
    local board = board_statics and pointer(board_statics + B_INSTANCE)
    local work = state_statics and pointer(state_statics + S_MESSAGE)
    local lines = board and pointer(board + B_LINES)
    local items, count = lines and pointer(lines + LIST_ITEMS), lines and mem.s32(lines + LIST_SIZE)
    if not work or not items or not count or count < 1 or count > 8 then
        last, reported = nil, nil
        withdraw()
        return
    end
    local objects, raws = {}, {}
    for i = 0, count - 1 do
        local object = pointer(items + ARRAY_DATA + 8 * i)
        local raw = object and str_raw(pointer(object + T_TEXT)) or ""
        if #raw > 0 then
            objects[#objects + 1] = object
            raws[#raws + 1] = raw
        end
    end
    local now = table.concat(raws, "\n\0")
    if now == "" then
        last, reported = nil, nil
        waited = 0
        withdraw()
        return
    end
    if now ~= last then
        last = now
        since = frame
        waited = 0
        if reported and reported ~= now then withdraw() end
    end
    local status = mem.u32(work + M_STATUS) or 0
    waited = (status & WAITING) ~= 0 and waited + 1 or 0
    if reported == now then return end
    if waited < STEADY and frame - since < UNCHANGED then return end

    local b = reader.builder()
    local cells = {}
    local box
    for index, object in ipairs(objects) do
        if index > 1 then
            b:add("\n")
            cells[#cells + 1] = false
        end
        local chars = visible(raws[index])
        local place = placement(object)
        local at = place and edges(object, raws[index], chars)
        local top, bottom
        if place then
            local x, y, w, h = place.rect[1], place.rect[2], place.rect[3], place.rect[4]
            top, bottom = place[4] + place[2] * (y + h), place[4] + place[2] * y
            local left, right = place[3] + place[1] * x, place[3] + place[1] * (x + w)
            if box then
                local l, t = math.min(box[1], left), math.min(box[2], top)
                local r, bt = math.max(box[1] + box[3], right), math.max(box[2] + box[4], bottom)
                box = { l, t, r - l, bt - t }
            else
                box = { left, top, right - left, bottom - top }
            end
        end
        for i, char in ipairs(chars) do
            b:add(text.utf16le(char.unit))
            if at and top then
                local left = place[3] + place[1] * at[i][1]
                local right = at[i + 1] and at[i + 1][1] > at[i][1] and place[3] + place[1] * at[i + 1][1]
                    or place[3] + place[1] * math.max(at[i][2], at[i][1] + 1)
                cells[#cells + 1] = { left, top, right - left, bottom - top }
            else
                cells[#cells + 1] = false
            end
        end
    end
    local line = b:text()
    reported = now
    if line == "" then return end
    reader.emit{ text = line, speaker = "", window = "message", id = text.hash(now) }
    local width, height = reader.picture()
    reader.layout("message", { space = { width, height }, box = box, glyphs = cells })
    shown = true
end)

-- ---- Chapters ----------------------------------------------------------------------------
--
-- What the reader's menu offers under "In this game": every episode of the three games opened,
-- and a start at the first day of any trial. Nothing here runs unless the player chooses it.
--
-- The game opens an episode once the one before it is cleared, and starts an episode at its
-- beginning. Each game keeps how far it was played in one byte (GSStatic.open_sce_): the
-- furthest episode reached in the upper half, 0xf in the lower once that one is cleared too.
-- Inside the game an episode is a run of numbered parts, each a script of its own, and the part
-- table (GSScenario.GSn_scenario_part_data) says which are in court (4) and which investigate
-- (5). advCtrl, which starts a new game's part, takes advCtrl.DebugOverrideScenario instead of
-- the part the episode begins with whenever it is not negative: set while the player chooses
-- that episode in the game's own menu, the episode begins at the trial.

local ADV_CLASS = 0x24b4308      -- advCtrl
local SERIES_CLASS = 0x24b5b08   -- seriesTitleSelectCtrl: the choice of game
local EPISODES_CLASS = 0x24b59e8 -- scenarioSelectCtrl: the choice of episode
local TITLE_CLASS = 0x24b5288    -- mainTitleCtrl: the title menu
local SCRIPT_CLASS = 0x24b43b0   -- GSScenario: the part tables
local S_GLOBAL = 0x08            -- GSStatic statics: GlobalWork global_work_
local S_OPEN = 0xa8              -- GSStatic statics: OpenScenarioData open_sce_ (bytes at 0x10..0x12)
local W_TITLE, W_PART, W_EPISODE = 0xa4, 0xa8, 0xa9 -- GlobalWork: title, scenario, story
local A_OVERRIDE = 0x28          -- advCtrl: int DebugOverrideScenario, -1 unless set
local SCENE_RUNNING = 0x28       -- sceneCtrl: enumerator_state_, set while the scene runs
local EPISODE_CURSOR = 0x3c      -- scenarioSelectCtrl: current_num_, the episode chosen
local SERIES_TITLE = 0x68        -- seriesTitleSelectCtrl: title_no_, the game chosen
local PART_TABLES = 0x60         -- GSScenario statics: byte[] GS1/2/3_scenario_part_data
local IN_COURT = 4               -- a part in court, in the part table

-- Every game's episodes, opened and cleared: 5, 4 and 5 episodes.
local OPEN = { 0x5f, 0x4f, 0x5f }

-- The first part of every trial day: game, episode, day, part. From the part tables (a run of
-- parts in court is one day; a day the game splits in two is one run).
local TRIALS = {
    { 1, 1, 1, 0 },
    { 1, 2, 1, 2 }, { 1, 2, 2, 4 },
    { 1, 3, 1, 6 }, { 1, 3, 2, 8 }, { 1, 3, 3, 10 },
    { 1, 4, 1, 12 }, { 1, 4, 2, 14 }, { 1, 4, 3, 16 },
    { 1, 5, 1, 19 }, { 1, 5, 2, 25 }, { 1, 5, 3, 31 },
    { 2, 1, 1, 0 },
    { 2, 2, 1, 3 }, { 2, 2, 2, 6 },
    { 2, 3, 1, 9 }, { 2, 3, 2, 12 },
    { 2, 4, 1, 16 }, { 2, 4, 2, 20 },
    { 3, 1, 1, 0 },
    { 3, 2, 1, 3 }, { 3, 2, 2, 5 },
    { 3, 3, 1, 8 }, { 3, 3, 2, 10 },
    { 3, 4, 1, 12 },
    { 3, 5, 1, 16 }, { 3, 5, 2, 20 },
}

local function instance(slot)
    local s = statics(slot)
    return s and pointer(s)
end

local function running(slot)
    local scene = instance(slot)
    return scene ~= nil and pointer(scene + SCENE_RUNNING) ~= nil
end

local function open_all()
    local s = statics(STATE_CLASS)
    local open = s and pointer(s + S_OPEN)
    if not open then return false end
    for game = 1, 3 do
        local at = open + 0x0f + game
        local now = mem.u8(at)
        if not now then return false end
        -- Never less than the game itself has opened.
        if now < OPEN[game] and not mem.w8(at, OPEN[game]) then return false end
    end
    return true
end

-- The part table's word on a part, or nil before the game has loaded its tables.
local function in_court(game, part)
    local s = statics(SCRIPT_CLASS)
    local table_ = s and pointer(s + PART_TABLES + 8 * (game - 1))
    local length = table_ and mem.s32(table_ + LIST_SIZE)
    if not length or part >= length then return nil end
    return mem.u8(table_ + ARRAY_DATA + part) == IN_COURT
end

local pending -- the trial chosen in the menu and not begun yet: {game, episode, day, part}
-- Asked to open every episode. The game reads its progress again when its title menu comes
-- up, so they are kept open from frame to frame while its menus run.
local opened = false

reader.action("Open every episode of the three games", function()
    opened = true
    open_all()
    return "Every episode of the three games can now be chosen after はじめから."
end)

for _, trial in ipairs(TRIALS) do
    local game, episode, day, part = trial[1], trial[2], trial[3], trial[4]
    reader.action(string.format("Start game %d, episode %d at trial day %d", game, episode, day), function()
        if in_court(game, part) == false then
            return "This build of the game has no trial where this profile expects one."
        end
        opened = true
        open_all()
        pending = trial
        return string.format("Now choose はじめから, then 逆転裁判%d and episode %d: it begins at its "
            .. "trial day %d. Any other episode begins as usual.", game, episode, day)
    end)
end

local function set_override(adv, value)
    if mem.s32(adv + A_OVERRIDE) ~= value then mem.w32(adv + A_OVERRIDE, value) end
end

reader.on_frame(function()
    if opened and (running(TITLE_CLASS) or running(SERIES_CLASS) or running(EPISODES_CLASS)) then
        open_all()
    end
    if not pending then return end
    local adv = instance(ADV_CLASS)
    if not adv then return end
    local game, episode, part = pending[1], pending[2], pending[4]
    local s = statics(STATE_CLASS)
    local work = s and pointer(s + S_GLOBAL)
    if work and mem.s32(work + W_TITLE) == game - 1 and mem.u8(work + W_EPISODE) == episode - 1
        and mem.u8(work + W_PART) == part then
        -- Begun: everything starts as the game would again.
        set_override(adv, -1)
        pending = nil
        return
    end
    if running(TITLE_CLASS) then
        set_override(adv, -1) -- back at the title: a save loaded from here must not be touched
    elseif running(EPISODES_CLASS) then
        local series, episodes = instance(SERIES_CLASS), instance(EPISODES_CLASS)
        local chosen = series and episodes and mem.s32(series + SERIES_TITLE) == game - 1
            and mem.s32(episodes + EPISODE_CURSOR) == episode - 1
        set_override(adv, chosen and part or -1)
    end
    -- Between the choice and the start the override stays as it was left.
end)
