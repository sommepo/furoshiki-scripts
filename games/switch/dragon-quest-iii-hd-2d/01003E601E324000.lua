-- reader: no hooks
-- reader: title ドラゴンクエストIII そして伝説へ… (DRAGON QUEST III HD-2D Remake)
-- reader: reads Dialogue, battle text, and system messages
-- reader: version Base game, version 1.0.0
-- ドラゴンクエストIII そして伝説へ… (DRAGON QUEST III HD-2D Remake), Switch.
-- Written for main build 6F49452BD0B343B17A77EE5B60C46233 (base game, version 1.0.0).
--
-- An Unreal Engine 4.27 game. Its message window is driven by an object of the game's own
-- (UIMessageWindow) that the engine knows by name, like every object: the profile finds it in
-- the engine's list of objects and reads, once a frame, what its three windows (top, centre,
-- bottom) show: up to three lines each, every line a rich text block of its own. Where the
-- characters are comes from the text layout Slate keeps for each line, with the advance of
-- every glyph. Only the message window is read: no menus, lists or item texts.
--
-- Nothing is hooked, so the game need not run on the recompiler (first line of this file).

local BUILD = "6F49452BD0B343B17A77EE5B60C46233"
if reader.build_id ~= BUILD then
    error("this profile is for build " .. BUILD .. ", the game is " .. tostring(reader.build_id))
end
local base = reader.base

-- The engine's globals (offsets into main).
local NAME_BLOCKS = 0x5AE8968 -- the name table's blocks: FNamePool, Blocks[]
local OBJECTS = 0x5B27C20     -- GUObjectArray.ObjObjects: chunks, -, max, count, max chunks, chunks

-- UObject.
local O_FLAGS, O_CLASS, O_NAME = 0x08, 0x10, 0x18
local RF_DEFAULT_OBJECT = 0x10
-- The game's objects, as the engine's reflection data has them. Two objects drive message
-- windows: the usual one with three windows, and one with a single window of the same kind.
local ROOTS = {
    UIMessageWindow = { { 0x70, "top" }, { 0x78, "centre" }, { 0x80, "bottom" } },
    UIMessageWindowXRMessageRoot = { { 0x70, "other" } },
}
local DRIVER_VIEW = 0x40     -- UIDriverBase.View: the widget it drives
local MAIN_LIST = 0x78       -- UIMessageWindowMain.List (UIMessageWindowListText)
local MAIN_NAME_BOX = 0x88   -- .OverlayName: the name plate
local MAIN_NAME = 0x90       -- .TextName (a TextBlock)
local MAIN_ARROW = 0xa0      -- .ImageArrow: shown when the game waits for a button
local MAIN_SIZE_BOX = 0xa8   -- .SizeBox: the room the lines are in
local LIST_ITEMS = 0x58      -- UIMessageWindowListText.WindowItems: TArray of UIWindowItemRich
local ITEM_RICH = 0x40       -- UIWindowItemRich.RichTextItem (a RichTextBlock)
-- UMG widgets.
local W_VISIBILITY = 0xc3    -- UWidget.Visibility: 1 collapsed, 2 hidden, else shown
local W_SLATE = 0xd8         -- UWidget.MyWidget: the Slate widget
local W_TEXT = 0x128         -- TextBlock.Text and RichTextBlock.Text (FText)
-- Slate.
local S_GEOMETRY = 0x98      -- SWidget: size (2 floats), scale, absolute position (2 floats)
local S_LAYOUT = 0x288       -- SRichTextBlock: its FSlateTextBlockLayout, whose first member
                             -- is the FTextLayout
local L_MODELS, L_VIEWS = 0x20, 0x30 -- FTextLayout: line models and line views (TArrays)
local MODEL_SIZE = 0x80      -- FLineModel: the text at 0 (a shared FString)
local VIEW_SIZE = 0x58       -- FLineView: blocks at 0, offset 0x30, size 0x38, model 0x54
local B_RANGE, B_SIZE, B_OFFSET, B_SHAPED = 0x18, 0x20, 0x28, 0x38 -- a block of a line view
local CACHE_ELEMENTS = 0x10  -- FShapedTextCache: its map's elements (data, count)
local ELEMENT_SIZE, ELEMENT_RANGE, ELEMENT_GLYPHS = 0x80, 0x00, 0x68
local GLYPH_SIZE, GLYPH_SOURCE, GLYPH_ADVANCE = 0x68, 0x14, 0x18

-- Frames a text must have stood unchanged to be read when the game shows no arrow (a question
-- with answers, a line of a battle that goes away by itself). The game types text out; it
-- draws thirty frames a second.
local STEADY = 15
-- Objects looked at per frame while searching for the objects that drive the windows.
local SEARCH_STEP = 6000

local function pointer(a)
    local p = a and mem.u64(a)
    return p and p > 0x10000 and p < 0x8000000000 and p or nil
end

-- ---------------------------------------------------------------------------------------
-- The engine's names and strings
-- ---------------------------------------------------------------------------------------

local names = {}
local function name_of(id)
    local known = names[id]
    if known then return known end
    local block = pointer(base + NAME_BLOCKS + 8 * (id >> 16))
    local header = block and mem.u16(block + 2 * (id & 0xffff))
    if not header then return "" end
    local length = header >> 6
    local raw = mem.read(block + 2 * (id & 0xffff) + 2, (header & 1) == 1 and length * 2 or length)
    local s = (header & 1) == 1 and text.utf16le(raw) or raw
    names[id] = s
    return s
end

local function fstring(a)
    local data, count = pointer(a), mem.s32(a + 8)
    if not data or not count or count <= 1 or count > 1024 then return "" end
    return text.utf16le(mem.read(data, (count - 1) * 2))
end

-- What an FText shows.
local function ftext(a)
    local data = pointer(a)
    if not data then return "" end
    local shared = pointer(data + 0x08) -- a localised text: the string it shares
    if shared then return fstring(shared) end
    local shown = fstring(data + 0x38)  -- a generated text: its own string
    return shown ~= "" and shown or fstring(data + 0x28)
end

local function shown(widget)
    local v = widget and mem.u8(widget + W_VISIBILITY)
    return v ~= nil and v ~= 1 and v ~= 2
end

-- ---------------------------------------------------------------------------------------
-- Finding the message window among the engine's objects
-- ---------------------------------------------------------------------------------------

local roots = {}   -- class name -> { object, class object }
local missing = 0  -- how many of ROOTS are not found yet
for _ in pairs(ROOTS) do missing = missing + 1 end
local search_at = 0
local search_wait = 0 -- frames to let pass before the list is gone through again
local classes = {} -- class object -> its name if it is one of ROOTS, else false

local function search()
    local chunks = pointer(base + OBJECTS)
    local count = mem.s32(base + OBJECTS + 0x14)
    if not chunks or not count or count <= 0 then return end
    if search_wait > 0 then
        search_wait = search_wait - 1
        return
    end
    if search_at >= count then search_at = 0 end
    local last = math.min(search_at + SEARCH_STEP, count) - 1
    local i = search_at
    while i <= last do
        local chunk = pointer(chunks + 8 * (i // 65536))
        local first = i % 65536
        local n = math.min(last - i + 1, 65536 - first)
        local raw = chunk and mem.read(chunk + 0x18 * first, 0x18 * n) or ""
        for k = 0, #raw // 0x18 - 1 do
            local object = string.unpack("<I8", raw, k * 0x18 + 1)
            if object > 0x10000 then
                local class = mem.u64(object + O_CLASS)
                local wanted = class and classes[class]
                if class and wanted == nil then
                    local name = name_of(mem.u32(class + O_NAME) or 0)
                    wanted = ROOTS[name] and name or false
                    classes[class] = wanted
                end
                local flags = wanted and mem.u32(object + O_FLAGS) or RF_DEFAULT_OBJECT
                if flags & RF_DEFAULT_OBJECT == 0 and not roots[wanted] then
                    roots[wanted] = { object, class }
                    missing = missing - 1
                end
            end
        end
        i = i + n
    end
    search_at = last + 1
    if search_at >= count then search_wait = 120 end -- not all there (yet): look again in a while
end

-- ---------------------------------------------------------------------------------------
-- Reading a line
-- ---------------------------------------------------------------------------------------

-- The text of a line as it was given to its rich text block: the characters, and the readings
-- its ruby tags give (<ruby label="reading">word</>). Returns the plain text, a list of
-- {first, length, reading} (in characters, from 0) and, per character of the plain text,
-- which piece of the laid-out text it is in: 0 for ordinary text, n for the n-th ruby.
local function parse(raw)
    if not raw:find("<", 1, true) then return raw, {}, nil end
    local out, ruby, pieces = {}, {}, {}
    local count, at = 0, 1
    while at <= #raw do
        local open, close, reading = raw:find('^<ruby%s+label="([^"]*)">', at)
        if open then
            local stop = raw:find("</>", close + 1, true)
            local word = raw:sub(close + 1, (stop or #raw + 1) - 1)
            local length = utf8.len(word) or 0
            ruby[#ruby + 1] = { count, length, reading }
            for _ = 1, length do pieces[#pieces + 1] = #ruby end
            out[#out + 1] = word
            count = count + length
            at = (stop and stop + 3) or #raw + 1
        else
            local tag_end = raw:match("^<[^>]*>()", at)
            if tag_end then
                at = tag_end -- another tag: not shown
            else
                local next_tag = raw:find("<", at + 1, true) or #raw + 1
                local plain = raw:sub(at, next_tag - 1)
                local length = utf8.len(plain) or 0
                for _ = 1, length do pieces[#pieces + 1] = 0 end
                out[#out + 1] = plain
                count = count + length
                at = next_tag
            end
        end
    end
    return table.concat(out), ruby, pieces
end

-- The advances of the glyphs of a block's text, by index into the line's laid-out text.
local function advances(block, first, last)
    local cache = pointer(block + B_SHAPED)
    local elements = cache and pointer(cache + CACHE_ELEMENTS)
    local count = cache and mem.s32(cache + CACHE_ELEMENTS + 8)
    if not elements or not count or count < 1 or count > 64 then return nil end
    for e = 0, count - 1 do
        local element = elements + e * ELEMENT_SIZE
        local from, to = mem.s32(element + ELEMENT_RANGE), mem.s32(element + ELEMENT_RANGE + 4)
        local sequence = pointer(element + ELEMENT_GLYPHS)
        if from and to and sequence and from <= first and to >= last then
            local glyphs, n = pointer(sequence), mem.s32(sequence + 8)
            if glyphs and n and n > 0 and n <= 512 then
                local raw = mem.read(glyphs, n * GLYPH_SIZE)
                local out = {}
                for g = 0, #raw // GLYPH_SIZE - 1 do
                    local source, advance =
                        string.unpack("<i4f", raw, g * GLYPH_SIZE + GLYPH_SOURCE + 1)
                    out[source] = (out[source] or 0) + advance
                end
                return out
            end
        end
    end
    return nil
end

-- Where the characters of a line are, in the pixels of the picture: a list with one
-- {left, top, width, height} per character of the plain text (false where nothing is drawn),
-- or nil while it cannot be told. `pieces` says which characters are inside a ruby (see
-- parse), `blank` which are spaces.
--
-- In the text Slate has laid out, a word with a reading is a single place: a zero-width
-- character that stands for the small widget that draws the word and its reading. The block
-- of the layout it is in has the widget's size; its word's characters share it.
local PLACEHOLDER = 0x200b
local function cells_of(rich, length, pieces, blank)
    local slate = pointer(rich + W_SLATE)
    local raw = slate and mem.read(slate + S_GEOMETRY, 20) or ""
    if #raw < 20 then return nil end
    local _, _, scale, ax, ay = string.unpack("<fffff", raw)
    local holder = pointer(slate + S_LAYOUT)
    local layout = holder and pointer(holder)
    local views = layout and pointer(layout + L_VIEWS)
    local view_count = layout and mem.s32(layout + L_VIEWS + 8)
    local models = layout and pointer(layout + L_MODELS)
    local model = models and pointer(models)
    local units = model and mem.s32(model + 8)
    if not views or not view_count or view_count < 1 or view_count > 8 or scale <= 0 or
        not units or units < 1 or units > 1024 then
        return nil
    end
    local laid = mem.read(pointer(model) or 0, (units - 1) * 2) -- the laid-out text, UTF-16
    local function unit(i)
        return 2 * i + 2 <= #laid and string.unpack("<H", laid, 2 * i + 1) or nil
    end
    local places = {} -- index in the laid-out text -> {left, top, width, height}
    for v = 0, view_count - 1 do
        local view = views + v * VIEW_SIZE
        local blocks, block_count = pointer(view), mem.s32(view + 8)
        local vraw = mem.read(view + 0x30, 16)
        if not blocks or not block_count or block_count > 64 or #vraw < 16 then return nil end
        local _, view_y, _, view_h = string.unpack("<ffff", vraw)
        for b = 0, block_count - 1 do
            local block = pointer(blocks + 16 * b)
            local braw = block and mem.read(block + B_RANGE, 24) or ""
            if #braw < 24 then return nil end
            local first, last, width, _, x = string.unpack("<i4i4fff", braw)
            local count = last - first
            if count == 1 and unit(first) == PLACEHOLDER then
                places[first] = { ax + x, ay + view_y, width, view_h }
            elseif count > 0 and count <= 256 then
                local each = advances(block, first, last)
                local left = ax + x
                for i = first, last - 1 do
                    local advance = each and each[i] or width / count
                    places[i] = { left, ay + view_y, advance, view_h }
                    left = left + advance
                end
            end
        end
    end
    local out = {}
    local at = 0 -- index in the laid-out text
    local i = 1
    while i <= length do
        local piece = pieces and pieces[i] or 0
        local n = 1
        if piece ~= 0 then
            while pieces[i + n] == piece do n = n + 1 end -- the characters of this ruby's word
        end
        if piece ~= 0 and unit(at) == PLACEHOLDER then
            local place = places[at]
            for k = 0, n - 1 do
                out[i + k] = place and
                    { place[1] + place[3] / n * k, place[2], place[3] / n, place[4] } or false
            end
            at = at + 1
        else
            -- Ordinary characters, one place each. A placeholder here is for something that is
            -- not text (a picture of a button, say).
            for k = 0, n - 1 do
                while unit(at) == PLACEHOLDER do at = at + 1 end
                out[i + k] = not blank[i + k] and places[at] or false
                at = at + 1
            end
        end
        i = i + n
    end
    return out
end

-- ---------------------------------------------------------------------------------------
-- The three windows
-- ---------------------------------------------------------------------------------------

local states = {}
local serial = 0

local function close(unit)
    if unit.placed then
        reader.layout(unit.window, nil)
        unit.placed = nil
    end
end

local function reset(state)
    for _, unit in ipairs(state.units or {}) do close(unit) end
    state.units, state.read, state.key, state.read_key, state.spots = {}, {}, nil, nil, nil
    state.lines = nil
end

-- A line of a window as it was read: its text as given to the rich text block, and what that
-- is made of.
local function record(raw)
    local plain, ruby, pieces = parse(raw)
    local line = { raw = raw, plain = plain, ruby = ruby, pieces = pieces, blank = {}, length = 0 }
    for _, code in utf8.codes(plain) do
        line.length = line.length + 1
        -- Nothing is drawn for a space.
        if code == 0x3000 or code == 0x20 then line.blank[line.length] = true end
    end
    return line
end

-- How many of the lines read so far are still at the top of what is shown, and whether the
-- last of them has more on it now. The window scrolls: what was read is what is shown minus
-- what came in at the bottom. A line that was read while the game paused in the middle of it
-- goes on where it was.
local function kept(read, lines)
    for k = math.min(#read, #lines), 1, -1 do
        local same = true
        for i = 1, k - 1 do
            if read[#read - k + i].raw ~= lines[i].raw then same = false break end
        end
        if same then
            local was, is = read[#read].raw, lines[k].raw
            if was == is then return k, false end
            if #is > #was and is:sub(1, #was) == was then return k, true end
        end
    end
    return 0, false
end

-- Whether what a window shows now is what it showed a frame ago with more typed or scrolled
-- in, rather than something else in its place.
local function continues(before, now)
    if #before == 0 then return true end
    for k = math.min(#before, #now), 1, -1 do
        local same = true
        for i = 1, k - 1 do
            if before[#before - k + i].raw ~= now[i].raw then same = false break end
        end
        local was, is = before[#before].raw, now[k].raw
        if same and #is >= #was and is:sub(1, #was) == was then return true end
    end
    return false
end

-- Reads what a window shows and has not been read yet: emits it as one event and remembers
-- its lines. `placed`: the text is on screen to stay, so where it is will be reported.
local function read_now(state, lines, speaker, placed)
    local k, grown = kept(state.read, lines)
    local read = {}
    for i = 1, k do read[i] = state.read[#state.read - k + i] end
    serial = serial % 9 + 1
    local unit = { window = "message." .. state.name .. "." .. serial, parts = {} }
    local b = reader.builder()
    local annotations = {}
    -- A part of the unit: the characters of a line from `offset` on.
    local function add(line, offset)
        if #unit.parts > 0 then b:add("\n") end
        local start = b:length()
        local at = 0
        for _, code in utf8.codes(line.plain) do
            at = at + 1
            if at > offset then b:add(utf8.char(code)) end
        end
        for _, r in ipairs(line.ruby) do
            if r[1] >= offset then
                annotations[#annotations + 1] = { start + r[1] - offset, r[2], r[3] }
            end
        end
        unit.parts[#unit.parts + 1] =
            { line = line, offset = offset, length = line.length - offset }
    end
    if grown then
        local before = read[k].length
        read[k] = record(lines[k].raw)
        add(read[k], before)
        -- What was read of this line before is now part of the new line's record.
        for _, other in ipairs(state.units) do
            for _, part in ipairs(other.parts) do
                if part.line == state.read[#state.read] then part.line = read[k] end
            end
        end
    end
    for i = k + 1, #lines do
        read[#read + 1] = record(lines[i].raw)
        add(read[#read], 0)
    end
    if #unit.parts > 0 and b:text():find("%S") then
        reader.emit{
            text = b:text(),
            ruby = annotations,
            speaker = speaker ~= "" and speaker or nil,
            window = placed and unit.window or nil,
        }
        if placed then state.units[#state.units + 1] = unit end
    end
    state.read, state.spots = read, nil
end

-- main: the window (a UIMessageWindowMain), or nil when it cannot be seen at all.
local function update(state, main, frame)
    local view = main and pointer(main + DRIVER_VIEW)
    local list = main and pointer(main + MAIN_LIST)
    local items = list and pointer(list + LIST_ITEMS)
    local count = list and mem.s32(list + LIST_ITEMS + 8)
    -- What is shown: the lines from the top, without the empty ones at the bottom.
    local lines = {}
    if view and shown(view) and items and count and count >= 1 and count <= 8 then
        for i = 0, count - 1 do
            local item = pointer(items + 8 * i)
            local rich = item and pointer(item + ITEM_RICH)
            local raw = rich and shown(rich) and ftext(rich + W_TEXT) or ""
            lines[i + 1] = { raw = raw, rich = rich }
        end
        while #lines > 0 and lines[#lines].raw == "" do lines[#lines] = nil end
    end
    local parts = {}
    for i, line in ipairs(lines) do parts[i] = line.raw end
    local key = table.concat(parts, "\n")
    if key ~= state.key then
        -- A text that went away before it was read was still shown: the lines of a battle
        -- are there for a moment only. It is read as it goes, without a place on screen.
        local before = state.lines
        local unread = before and #before > 0 and state.key ~= state.read_key
        if unread and not continues(before, lines) then
            read_now(state, before, state.speaker or "", false)
        end
        state.key, state.changed = key, frame
    end
    state.lines = lines
    if #lines == 0 then
        if #state.units > 0 or #state.read > 0 then
            reset(state)
            state.key, state.lines = key, lines
        end
        return
    end
    local name_box = pointer(main + MAIN_NAME_BOX)
    local name = name_box and shown(name_box) and pointer(main + MAIN_NAME)
    state.speaker = name and ftext(name + W_TEXT):gsub("^%s+", ""):gsub("%s+$", "") or ""

    -- Read what is new once the game has finished typing it.
    local arrow = pointer(main + MAIN_ARROW)
    local waiting = arrow and shown(arrow) and frame - state.changed >= 2
    if key ~= state.read_key and (waiting or frame - state.changed >= STEADY) then
        read_now(state, lines, state.speaker, true)
        state.read_key = key
    end

    -- Where the lines that were read are now.
    local k = kept(state.read, lines)
    local where = {}
    for i = 1, k do where[state.read[#state.read - k + i]] = lines[i].rich end
    local width, height = reader.picture()
    -- Nothing has moved since the last frame: nothing to say.
    local spots = { key, width or 0, height or 0, #state.units }
    for i = 1, k do
        local slate = lines[i].rich and pointer(lines[i].rich + W_SLATE)
        spots[#spots + 1] = slate and mem.read(slate + S_GEOMETRY, 20) or ""
    end
    spots = table.concat(spots, "|")
    if spots == state.spots then return end
    state.spots = spots
    -- The room the lines are in: the text box.
    local box
    local size_box = pointer(main + MAIN_SIZE_BOX)
    local slate = size_box and pointer(size_box + W_SLATE)
    local graw = slate and mem.read(slate + S_GEOMETRY, 20) or ""
    if #graw == 20 then
        local w, h, scale, x, y = string.unpack("<fffff", graw)
        if w > 0 and h > 0 and scale > 0 then box = { x, y, w * scale, h * scale } end
    end
    local cells = {} -- line record -> its characters' cells
    for u = #state.units, 1, -1 do
        local unit = state.units[u]
        local glyphs, any, present, signature = {}, false, false, {}
        for n, part in ipairs(unit.parts) do
            if n > 1 then glyphs[#glyphs + 1] = false end
            local line = part.line
            local rich = where[line]
            present = present or rich ~= nil
            if rich and width and cells[line] == nil then
                cells[line] = cells_of(rich, line.length, line.pieces, line.blank) or false
            end
            local of_line = rich and cells[line]
            for i = part.offset + 1, part.offset + part.length do
                local cell = of_line and of_line[i] or false
                glyphs[#glyphs + 1] = cell
                if cell then
                    any = true
                    if i == part.offset + 1 or i == part.offset + part.length then
                        signature[#signature + 1] =
                            string.format("%.1f,%.1f,%.1f", cell[1], cell[2], cell[3])
                    end
                end
            end
        end
        if not present then
            close(unit)
            table.remove(state.units, u) -- scrolled out of the window
        elseif not any then
            close(unit)
            state.spots = nil -- shown but not laid out yet: look again next frame
        else
            local placed = table.concat(signature, " ") .. " " .. width .. "x" .. height
            if box then placed = placed .. " " .. table.concat(box, ",") end
            if placed ~= unit.placed then
                reader.layout(unit.window,
                              { space = { width, height }, box = box, glyphs = glyphs })
                unit.placed = placed
            end
        end
    end
end

reader.on_frame(function(frame)
    for name, root in pairs(roots) do
        if mem.u64(root[1] + O_CLASS) ~= root[2] then
            -- The object is gone: so is what its windows showed.
            for _, entry in ipairs(ROOTS[name]) do
                if states[entry[2]] then update(states[entry[2]], nil, frame) end
            end
            roots[name] = nil
            missing = missing + 1
        end
    end
    if missing > 0 then search() end
    for name, root in pairs(roots) do
        local view = pointer(root[1] + DRIVER_VIEW)
        local view_shown = view and shown(view)
        for _, entry in ipairs(ROOTS[name]) do
            local main = view_shown and pointer(root[1] + entry[1]) or nil
            local state = states[entry[2]]
            if not state then
                state = { name = entry[2], units = {}, read = {} }
                states[entry[2]] = state
            end
            update(state, main, frame)
        end
    end
end)

-- For the harness (lua dq3_dump()): what the profile holds.
function dq3_dump()
    for name, root in pairs(roots) do print(string.format("%s %x", name, root[1])) end
    for name, state in pairs(states) do
        print(string.format("%s: %d units, %d lines read, key '%s'", name, #state.units,
                            #state.read,
                            (state.key or "-"):gsub("\n", " / ")))
        for _, unit in ipairs(state.units) do
            print("  " .. unit.window .. (unit.placed and " placed" or " not placed"))
        end
    end
end
