-- Var Watch
-- A dev tool for finding game variables. Every variable the server changes is recorded in a catalogue that's kept
-- between sessions, so the more you play with it on, the more it knows. A window shows the catalogue: search it by
-- name, sort it, page through it, and pin the ones you care about so they stay at the top and update live.
--
-- It also notes what you just did when a variable changed - the menu option you picked ("Withdraw-1 Bank chest"),
-- an ability you used, or XP you gained - so you can see which action moves which variable.
--
-- Tools for documenting vars (e.g. for the RuneScape Wiki):
--  * Mark: shows only what changed after you pressed it, with the value before and after.
--  * Details: a var's last 20 values this session, and for a VarBit the variable it lives in and its bit range.
--  * Hide: keeps noisy vars (clocks) out of the list and the console; the hidden list brings them back.
--  * Click any cell to put its value in the copy box, or switch to copying a whole row as a wiki table line.
--  * Wiki export: the whole catalogue as a wiki table, saved on this computer.
--
-- Changes can also be printed to the dev console:
--   Var Watch: VarClient COMBATV2_JUST_USED_ABILITY (4098): 14710 -> 14711  (after: ability)
--
-- Found what you need? Read it in your own plugin with var.VarClient.NAME.value (or var.VarPlayer.NAME.value), or
-- listen for Event.VarTransmit.
--
-- It only listens: no permissions, and the catalogue is saved with PersistentDB on your own PC, nothing is sent.

local settings = require("settings").new("varWatch", {
    { "window", "Show the window", true },
    { "console", "Print changes in the console", true },
    -- asked for by wiki editors (varbits). 1.0.1: shown as "Negative IDs: on/off" (on = with the minus, as sent)
    { "positiveIds", "Negative IDs", false, true },
}, "Var Watch keeps a catalogue of every variable it sees.")
local Export = require("export")

-- Some vars are basically clocks. Anything that changes more than 10 times in 5 seconds stops printing to the
-- console (it's still counted in the catalogue).
local NOISY_AFTER, NOISY_WINDOW = 10, 250
local ROWS = 14                          -- rows in the window (more when it's made taller)
local SAVE_EVERY = 500                   -- save the catalogue at most every 10 seconds (client ticks, 50 a second)
local ACTION_WINDOW = 120                -- a change within 2.4 s of an action is put down to that action

local tick = 0
local catalogue, pinned = {}, {}         -- name -> { kind, id, value, changes, after, seenAt }, name -> true
local recentChanges, noisy = {}, {}
local lastAction = nil                   -- { text, tick }
local abilities = {}                     -- ability ID (as text) -> "Devotion (Defence)", learned as you play
local abilityStems, abilitySeen = {}, {}  -- verbatim cooldown stem; session time is not saved
local hidden = {}                        -- name -> true: vars hidden from the list (and the console)
local HISTORY = 20                       -- values remembered per var this session (for Details)
local markID = 0                         -- each press of Mark starts a new mark; changes after it are listed
local dirty = false

local function get(fn) local ok, v = pcall(fn); if ok then return v end end

-- Load what earlier sessions found. Anything from before this session shows as "earlier" until it changes again.
local savedPos = nil
pcall(function()
    local saved = PersistentDB:GetStructuredData("catalogue")
    if type(saved) == "table" then
        for name, e in pairs(saved) do
            if type(e) == "table" then
                catalogue[name] = { kind = e.kind, id = e.id, value = e.value, rawValue = e.rawValue, changes = e.changes or 0,
                                    after = e.after, parent = e.parent, bits = e.bits, valueType = e.valueType }
            end
        end
    end
    local savedPins = PersistentDB:GetStructuredData("pinned")
    if type(savedPins) == "table" then for _, name in ipairs(savedPins) do pinned[name] = true end end
    local savedHidden = PersistentDB:GetStructuredData("hidden")
    if type(savedHidden) == "table" then for _, name in ipairs(savedHidden) do hidden[name] = true end end
    savedPos = PersistentDB:GetStructuredData("window")
end)

local function save()
    local plain, pins = {}, {}
    for name, e in pairs(catalogue) do
        plain[name] = { kind = e.kind, id = e.id, value = e.value, rawValue = e.rawValue, changes = e.changes, after = e.after,
                        parent = e.parent, bits = e.bits, valueType = e.valueType }
    end
    for name in pairs(pinned) do pins[#pins + 1] = name end
    local hide = {}
    for name in pairs(hidden) do hide[#hide + 1] = name end
    pcall(function()
        PersistentDB:SetStructuredData("catalogue", plain)
        PersistentDB:SetStructuredData("pinned", pins)
        PersistentDB:SetStructuredData("hidden", hide)
        PersistentDB:SetStructuredData("abilities", abilities)
        PersistentDB:SetStructuredData("abilityStems", abilityStems)
    end)
    dirty = false
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- What did you just do? ------------------------------------------------------------------------------------------

local function did(text) lastAction = { text = text, tick = tick } end

-- any option picked from the game's menus (left click or right click): "Withdraw-1 Bank chest", "Attack Goblin"
Event.MiniMenuEntrySelected.Subscribe("varWatchActions", function(event)
    local text = get(function() return event.entry.fullText end)
    if not text or text == "" then
        text = (get(function() return event.entry.verbText end) or "") .. " " .. (get(function() return event.entry.subjectText end) or "")
    end
    text = tostring(text):gsub("<[^>]*>", ""):gsub("%s*%-%>%s*$", ""):gsub("%s+", " ")
    did(text)                            -- colour tags, a sub-menu arrow and double spaces dropped
end)

-- XP gained
Event.SkillTransmit.Subscribe("varWatchXp", function(event)
    if type(event.newXP) == "number" and type(event.oldXP) == "number" and event.newXP > event.oldXP then
        local skill = tostring(get(function() return SkillType.FromID(event.skill) end) or "skill")
        did(skill:lower():gsub("^%l", string.upper) .. " XP")
    end
end)

-- Recording -----------------------------------------------------------------------------------------------------------

-- The ability map ------------------------------------------------------------------------------------------------
-- Using an ability puts its ID in COMBATV2_JUST_USED_ABILITY and starts its cooldown (COMBATV2_COOLDOWN_<STYLE>_
-- <ABILITY>_START) at the same moment, so pairing the two tells us which ID is which ability. Keybinds count too.
-- A one-off scan when the plugin starts also lists every ability cooldown var in the game, used or not.
local savedAbilities = get(function() return PersistentDB:GetStructuredData("abilities") end)
if type(savedAbilities) == "table" then for k, v in pairs(savedAbilities) do
    if type(v) == "string" then abilities[tostring(k)] = v end
end end
local savedStems = get(function() return PersistentDB:GetStructuredData("abilityStems") end)
if type(savedStems) == "table" then for k, v in pairs(savedStems) do if type(v) == "string" then abilityStems[tostring(k)] = v end end end
local cooldownVars = {}                                         -- "DEFENCE_DEVOTION" -> { start = id, finish = id }
local lastUse, lastStart = nil, nil                             -- { id, tick }, { ability, tick }
local PAIR_WINDOW = 40                                          -- the two arrive within 0.8 s of each other

local function nice(ability)             -- "ATTACK_BLADED_DIVE" -> "Bladed Dive (Attack)"
    local function words(s)
        return (s:lower():gsub("_", " "):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
    end
    local style, rest = ability:match("^([^_]+)_(.+)$")
    if not style then return words(ability) end
    return words(rest) .. " (" .. words(style) .. ")"
end
local function pair()
    if not (lastUse and lastStart and math.abs(lastUse.tick - lastStart.tick) <= PAIR_WINDOW) then return end
    local key, name = tostring(lastUse.id), nice(lastStart.ability)
    if abilities[key] ~= name then
        abilities[key] = name
        dirty = true
        log("Var Watch: ability " .. key .. " is " .. name)
    end
    abilityStems[key], abilitySeen[key], dirty = lastStart.ability, tick, true
    lastUse, lastStart = nil, nil
end

-- The scan: VarPlayer IDs 0-39999, 500 a tick (under 2 seconds), looking for the cooldown vars by name
local scanNext, SCAN_TO = 0, 40000
local function scanStep()
    for i = scanNext, math.min(scanNext + 500, SCAN_TO) - 1 do
        local varName = get(function() return var.VarPlayer.FromID(i).configName end)
        local ability, edge = nil, nil
        if type(varName) == "string" then ability, edge = varName:match("^COMBATV2_COOLDOWN_(.+)_(%u+)$") end
        if ability and (edge == "START" or edge == "END") then
            local c = cooldownVars[ability] or {}
            cooldownVars[ability] = c
            if edge == "START" then c.start = i else c.finish = i end
        end
    end
    scanNext = scanNext + 500
    if scanNext >= SCAN_TO then
        pcall(function() PersistentDB:SetStructuredData("cooldownVars", cooldownVars) end)
        log("Var Watch: found cooldown vars for " .. (function() local n = 0; for _ in pairs(cooldownVars) do n = n + 1 end; return n end)() .. " abilities")
    end
end

Event.Logic.Subscribe("varWatchClock", function()
    tick = tick + 1
    if scanNext < SCAN_TO and tick > 100 then scanStep() end  -- two seconds after start-up
    if dirty and tick % SAVE_EVERY == 0 then save() end
end)

Event.VarTransmit.Subscribe("varWatchVars", function(event)
    -- The server sometimes re-sends a var without changing it. Not interesting.
    if event.oldValue == event.newValue then return end

    -- What kind of var is it? It matters, because VarPlayer and VarClient are read differently. For a VarBit we
    -- also note the variable it lives inside.
    local ok, name, kind, varID = pcall(function()
        local v = event.var
        local kind = tostring(v.typeName)
        if v.isVarBit then
            local base = get(function() return v.baseVar.id end)
            kind = kind .. " bit" .. (base and (" of " .. base) or "")
        end
        return v.configName, kind, v.id
    end)
    if not ok then name, kind, varID = tostring(event.var), "Var", "?" end
    -- for a VarBit: the variable it lives in and which of its bits it uses (what the wiki records)
    local parent, bits, valueType = nil, nil, get(function() return tostring(event.var.valueType) end)
    if get(function() return event.var.isVarBit end) then
        parent = get(function() return event.var.baseVar.id end)
        local mask = get(function() return event.var.varBitMask end)
        if type(mask) == "number" and mask > 0 then
            local low, high, m = 0, -1, mask
            while m % 2 == 0 do m = math.floor(m / 2); low = low + 1 end
            high = low
            while m > 1 do m = math.floor(m / 2); high = high + 1 end
            bits = low .. "-" .. high
        end
    end

    local after = lastAction and tick - lastAction.tick <= ACTION_WINDOW and lastAction.text or nil
    local value = tostring(event.newValue)

    -- Abilities: pair the ID with the cooldown that starts with it, and show the name once we know it.
    -- Using an ability is itself an action worth noting for the changes that follow it (not this one).
    if name == "COMBATV2_JUST_USED_ABILITY" then
        lastUse = { id = event.newValue, tick = tick }
        pair()
        local known = abilities[value]
        did("ability " .. (known or value))
        if known then value = value .. " " .. known end
        after = nil
    end
    local cooled = type(name) == "string" and name:match("^COMBATV2_COOLDOWN_(.+)_START$")
    if cooled then lastStart = { ability = cooled, tick = tick }; pair() end
    local entry = catalogue[name]
    if not entry then
        entry = { kind = kind, id = varID, changes = 0 }
        catalogue[name] = entry
    end
    entry.kind, entry.id = kind, varID
    entry.value, entry.changes, entry.seenAt = value, entry.changes + 1, tick
    entry.rawValue = tostring(event.newValue)       -- keep game data separate from our named display value
    entry.parent, entry.bits, entry.valueType = parent or entry.parent, bits or entry.bits, valueType or entry.valueType
    if after then entry.after = after end
    -- this session's history (newest last), and its value before the current mark
    entry.history = entry.history or {}
    table.insert(entry.history, { value = value, old = tostring(event.oldValue), at = tick, after = after })
    if #entry.history > HISTORY then table.remove(entry.history, 1) end
    if markID > 0 and entry.markID ~= markID then entry.markID, entry.markOld = markID, tostring(event.oldValue) end
    dirty = true

    if not settings.console or noisy[name] or hidden[name] then return end
    local times = recentChanges[name] or {}
    recentChanges[name] = times
    table.insert(times, tick)
    while times[1] and tick - times[1] > NOISY_WINDOW do table.remove(times, 1) end
    if #times > NOISY_AFTER then
        noisy[name] = true
        log("Var Watch: " .. name .. " changes too often, it won't print any more (still in the window)")
        return
    end
    log(string.format("Var Watch: %s %s (%s): %s -> %s%s", kind, name, tostring(varID), tostring(event.oldValue), value,
        after and ("  (after: " .. after .. ")") or ""))
end)

-- The window -------------------------------------------------------------------------------------------------------
-- Built to look like the game's own windows: the game's panel style (GROUPBOX_DEFAULT), the classic interface fonts,
-- orange headings and striped rows. Its background takes clicks, so clicking the window never walks you in the game.

local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
local MIN_W, MIN_H, MAX_W, MAX_H = 900, 300, 1900, 1050
local ROW_Y, ROW_H = 112, 22

-- The game's classic pixel fonts when it has them (looked up by name), otherwise its standard font
local STANDARD = id.Font.MUSEO_SANS_15PT_REGULAR
local function pickFont(names)
    for _, name in ipairs(names) do
        local font = get(function() return id.Font[name:upper()] end)
        if type(font) == "number" and get(function() return config.Font.FromID(font).configName end) then return font end
    end
    return STANDARD
end
local font = pickFont({ "P12_FULL", "P12", "P11_FULL" })
local boldFont = pickFont({ "B12_FULL", "B12" })
local fontInfo = get(function() return config.Font.FromID(font) end)

-- How wide a piece of text is, in interface units (a rough guess if the game can't say)
local function width(s)
    return get(function() return fontInfo:GetStringWidth(s, true) end) or #s * 6
end
-- Text cut to fit a column, ending in ".." if it had to be cut
local function fit(s, w)
    s = tostring(s or "")
    if width(s) <= w then return s end
    while #s > 1 and width(s .. "..") > w do s = s:sub(1, -2) end
    return s .. ".."
end

-- Size and place: as you last left them, otherwise 900 x 452 near the top right
local function clamp(n, low, high) return math.max(low, math.min(high, math.floor(n))) end
local W, H = 900, 452
local screenW = get(function() return layer.width end) or 1920
local pos = { x = screenW - W - 380, y = 110 }
if type(savedPos) == "table" then
    if tonumber(savedPos.x) and tonumber(savedPos.y) then pos.x, pos.y = tonumber(savedPos.x), tonumber(savedPos.y) end
    if tonumber(savedPos.w) and tonumber(savedPos.h) then
        W, H = clamp(tonumber(savedPos.w), MIN_W, MAX_W), clamp(tonumber(savedPos.h), MIN_H, MAX_H)
    end
end
-- 1.0.1: never further off screen than a drag can take it (the game window may be smaller than last time)
local function onScreen()
    local maxX = (get(function() return layer.width end) or 4000) - 60
    local maxY = (get(function() return layer.height end) or 4000) - 30
    pos.x = clamp(pos.x, 60 - W, maxX)
    pos.y = clamp(pos.y, 0, maxY)
end
onScreen()
local function rowsFor(height) return math.max(6, math.floor((height - ROW_Y - 24) / ROW_H)) end
ROWS = rowsFor(H)

-- The game's interface colours: orange titles and headings, cream text, grey notes, yellow for pinned rows
local ORANGE = Vector4.new(1, 0.6, 0.12, 1)
local CREAM = Vector4.new(0.94, 0.89, 0.76, 1)
local GREY = Vector4.new(0.62, 0.6, 0.55, 1)
local YELLOW = Vector4.new(1, 0.9, 0.3, 1)

-- What the window is showing, kept apart from the widgets
local query, sortBy, offset, paused, pinnedOnly, abilityView = "", "recent", 0, false, false, false
local view = "list"                               -- "list", "mark", "details" or "hidden"
local selected = nil                              -- the var last clicked
local copyWiki = false                            -- clicking copies a wiki table row instead of the cell
local copied = ""                                 -- what's in the copy box
local noticeUntil, noticeText = 0, ""
local listSize = 0                                -- how many rows the current list has (set by refresh)
local refresh                                     -- defined below

-- The widgets of the current build
local window, back, titleBar, barHandle, status, help, copyBox, selectedText, selectedRow
local sortButton, pinButton, detailsButton, hideButton, hiddenButton
local rows, headings, COLUMNS = {}, {}, {}
local PIN_X, BAR_X, BAR_W, TRACK_Y, TRACK_H = 0, 0, 10, 0, 0

local function mouse() return get(function() return Mouse.GetPosition() end) end

-- Moving the window (1.0.1): press on the title bar and drag. The window follows the mouse every client tick until the
-- button is let go. Plugins can't read the mouse button, so a drag also ends once the mouse has been off the title bar
-- for a moment. Where you leave it is saved for next time.
local drag = nil                                  -- { mouse x, mouse y, window x, window y, ticks off the bar }
local function startDrag()
    local m = mouse()
    if m then drag = { m.x, m.y, pos.x, pos.y, 0 } end
end
local function endDrag()
    if not drag then return end
    drag = nil
    pcall(function() PersistentDB:SetStructuredData("window", { x = pos.x, y = pos.y, w = W, h = H }) end)
end
local function followMouse()
    if not drag then return end
    if not window or window.hidden then endDrag(); return end
    local m = mouse()
    if not m then return end
    pos.x, pos.y = drag[3] + m.x - drag[1], drag[4] + m.y - drag[2]
    onScreen()
    window:SetPos(pos.x, pos.y)
    if get(function() return titleBar.isMouseOver end) == false then
        drag[5] = drag[5] + 1
        if drag[5] > 15 then endDrag() end
    else
        drag[5] = 0
    end
end

local function notice(message)
    noticeText, noticeUntil = message, tick + 150 -- shown for 3 seconds
    if help then help.content = message end
end

-- Exports are saved on this computer (PersistentDB), in pieces, marked incomplete until every piece is written.
-- tools/var_watch_export.py turns the last one into a file.
local function saveExport(mode)
    local parts, info = Export.build(mode, catalogue, abilities, abilityStems)
    if not parts then notice("Export too large."); log("Var Watch export: " .. info); return end
    local ok, problem = pcall(function()
        -- Mark an incomplete export first, so a failed write is never read as a successful old one.
        assert(PersistentDB:SetStructuredData("exportInfo", { complete = false }) ~= false)
        for i, part in ipairs(parts) do assert(PersistentDB:Set(string.format("exportText%03d", i), part) ~= false) end
        info.complete = true
        assert(PersistentDB:SetStructuredData("exportInfo", info) ~= false)
    end)
    notice(ok and (info.rows .. " rows exported.") or "Export failed.")
    if not ok then log("Var Watch export: " .. tostring(problem)) end
end

-- Scrolling (used by the scroll bar, the wheel and refresh)
local function maxOffset() return math.max(0, listSize - ROWS) end
local function placeHandle()
    if not barHandle then return 0 end
    local h = listSize > ROWS and math.max(20, math.floor(TRACK_H * ROWS / listSize)) or TRACK_H
    local y = maxOffset() > 0 and math.floor((TRACK_H - h) * offset / maxOffset()) or 0
    barHandle:SetPos(BAR_X, TRACK_Y + y)
    barHandle:SetSize(BAR_W, h)
    return h
end
local function scrollTo(n)
    local was = offset
    offset = math.max(0, math.min(maxOffset(), math.floor(n + 0.5)))
    if offset ~= was then refresh() end
end
-- the wheel: three rows a notch, over the rows or the empty parts of the window
local function wheel(a, b)
    local delta = type(b) == "number" and b or (type(a) == "number" and a or 0)
    if delta ~= 0 then scrollTo(offset + (delta > 0 and 3 or -3)) end
end

-- The columns for the current width: Name and After get any extra width. { title, x, width }
local function layoutColumns()
    local extra = W - MIN_W
    local nameW = 334 + math.floor(extra * 0.6)
    local afterW = 126 + (extra - math.floor(extra * 0.6))
    local spec = { { "Name", nameW, 6 }, { "Kind", 88, 4 }, { "ID", 58, 4 }, { "Value", 94, 4 }, { "Changes", 58, 4 },
                   { "Seen", 54, 4 }, { "After", afterW, 0 } }
    local list, x = {}, 10
    for i, c in ipairs(spec) do
        list[i] = { c[1], x, c[2] }
        x = x + c[2] + c[3]
    end
    return list
end

-- Widget helpers: everything is made on the current window
local function rect(x, y, w, h, colour)
    local r = ui.Rectangle.new(window)
    r:SetPos(x, y); r:SetSize(w, h)
    r.fill = true
    r.colour = colour
    return r
end
local function blocking(r) pcall(function() r.clickthrough = false end); return r end
local function text(x, y, w, content, colour, bold)
    local t = ui.Text.new(window)
    t:SetPos(x, y); t:SetSize(w, 20)
    t.font = bold and boldFont or font
    t.clickthrough = true
    t.content = content or ""
    pcall(function() t.isShadowed = true end)
    pcall(function() t.colour = colour or CREAM end)
    return t
end
local function button(label, x, y, w, onPress)
    local b = ui.Button.new(window)
    b:SetPos(x, y); b:SetSize(w, 22); b.label = label
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, function() onPress(b) end)
    return b
end

local function buildFrame()
    window = get(function()
        local g = ui.GroupBox.new(layer)
        g.stylesheetID = id.StyleSheet.GROUPBOX_DEFAULT
        return g
    end) or ui.Layer.new(layer)
    window:SetSize(W, H)
    window:SetPos(pos.x, pos.y)
    window.hidden = not settings.window
    pcall(function() window.clickthrough = false end)

    -- A dark backing inside the frame. It takes clicks (it has a click hook and isn't click-through), so the game
    -- underneath never sees them.
    back = blocking(rect(3, 3, W - 6, H - 6, Vector4.new(0.07, 0.06, 0.05, 0.94)))
    back:Subscribe(ui.Hook.ONCLICK, function() end)
    back:Subscribe(ui.Hook.ONSCROLLWHEEL, wheel)
    -- the title bar's darker strip (drag it to move the window) and the striped rows, like the game's lists
    titleBar = blocking(rect(3, 3, W - 6, 26, Vector4.new(0.13, 0.11, 0.08, 1)))
    titleBar:Subscribe(ui.Hook.ONCLICK, function() startDrag() return false end)
    titleBar:Subscribe(ui.Hook.ONRELEASE, function() endDrag() return false end)
    for r = 1, ROWS, 2 do rect(6, ROW_Y + (r - 1) * ROW_H - 1, W - 12, ROW_H, Vector4.new(1, 1, 1, 0.04)) end


    -- Title bar: the name, the counts, a short notice line, and the main switches
    text(10, 6, 100, "Var Watch", ORANGE, true)
    status = text(110, 6, 118, "", GREY)
    help = text(230, 6, 112, tick < noticeUntil and noticeText or "", YELLOW)
    -- the same switch as in the cog, here where you can see it: negative IDs (varbits) with or without the minus
    -- 1.0.1: worded like the cog, "Negative IDs: on" = shown with the minus, as the game sends them
    button(settings.positiveIds and "Negative IDs: off" or "Negative IDs: on", W - 554, 5, 126, function(b)
        settings.positiveIds = not settings.positiveIds
        pcall(function() PersistentDB:SetStructuredData("varWatch", settings) end)   -- keep the cog's saved copy in step
        b.label = settings.positiveIds and "Negative IDs: off" or "Negative IDs: on"
        refresh()
    end)
    button(paused and "Resume" or "Pause", W - 424, 5, 70, function(b)
        paused = not paused
        b.label = paused and "Resume" or "Pause"
    end)
    sortButton = button("Sort: " .. sortBy, W - 350, 5, 114, function(b)
        sortBy = abilityView and (sortBy == "recent" and "name" or "recent")
            or ({ recent = "changes", changes = "name", name = "recent" })[sortBy]
        b.label = "Sort: " .. sortBy
        offset = 0; refresh()
    end)
    pinButton = button(pinnedOnly and "All" or "Pinned", W - 232, 5, 96, function(b)
        pinnedOnly = not pinnedOnly
        b.label = pinnedOnly and "All" or "Pinned"
        offset = 0; refresh()
    end)
    pinButton.hidden = abilityView
    button("X", W - 34, 5, 26, function()
        settings.window = false
        window.hidden = true
    end)

end

local function buildToolbar()
    -- Search, the Abilities view, Export, and the copy box
    local search = ui.InputField.new(window)
    search:SetPos(10, 36); search:SetSize(330, 24)
    search.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    pcall(function() search:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NONE, 60) end)
    pcall(function() search.emptyText = "Search names and actions" end)
    search.content = query
    button("Search", 346, 37, 80, function()
        query = tostring(search.content or ""):lower()
        offset = 0; refresh()
    end)
    button("Clear", 430, 37, 64, function()
        search.content, query, offset = "", "", 0
        refresh()
    end)
    button(abilityView and "Variables" or "Abilities", 500, 37, 104, function(b)
        abilityView = not abilityView
        b.label = abilityView and "Variables" or "Abilities"
        query, offset, pinnedOnly, sortBy, search.content = "", 0, false, "recent", ""
        sortButton.label, pinButton.label, pinButton.hidden = "Sort: recent", "Pinned", abilityView
        refresh()
    end)
    button("Export", 610, 37, 104, function() saveExport(abilityView and "abilities" or "catalogue") end)
    -- The copy box: click any cell and its full value lands here, ready to select and copy (plugins can't reach the
    -- clipboard themselves)
    copyBox = ui.InputField.new(window)
    copyBox:SetPos(720, 36); copyBox:SetSize(W - 728, 24)
    copyBox.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    pcall(function() copyBox:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NONE, 400) end)
    pcall(function() copyBox.emptyText = "Click a cell to copy it" end)
    copyBox.content = copied

    -- Wiki tools: Mark (show only what changed since), Details (a var's history), Hide, the hidden list, copy mode,
    -- and an export written as a wiki table
    button(view == "mark" and "End mark" or "Mark", 10, 65, 96, function(b)
        if view == "mark" then
            view = "list"
            b.label = "Mark"
        else
            markID = markID + 1
            view, offset = "mark", 0
            b.label = "End mark"
            notice("Marked. Do one thing.")
        end
        refresh()
    end)
    detailsButton = button("Details", 110, 65, 88, function()
        if view == "details" then
            view = "list"
        elseif selected and catalogue[selected] then
            view, offset = "details", 0
        else
            notice("Click a var first.")
        end
        refresh()
    end)
    hideButton = button("Hide", 202, 65, 80, function()
        if not selected then notice("Click a var first.") return end
        hidden[selected] = not hidden[selected] or nil
        notice(hidden[selected] and "Hidden." or "Shown again.")
        dirty = true
        refresh()
    end)
    hiddenButton = button("Hidden: 0", 286, 65, 110, function()
        view = view == "hidden" and "list" or "hidden"
        offset = 0
        refresh()
    end)
    button(copyWiki and "Copy: wiki row" or "Copy: value", 400, 65, 130, function(b)
        copyWiki = not copyWiki
        b.label = copyWiki and "Copy: wiki row" or "Copy: value"
    end)
    button("Wiki export", 534, 65, 110, function() saveExport("wiki") end)

end

local function buildList()
    -- Column headings, then the rows, each with a pin button
    COLUMNS = layoutColumns()
    PIN_X, BAR_X = W - 48, W - 18
    headings = {}
    for i, c in ipairs(COLUMNS) do headings[i] = text(c[2], ROW_Y - 20, c[3], c[1], ORANGE, true) end
    selectedRow = rect(6, ROW_Y - 1, PIN_X - 10, ROW_H, Vector4.new(1, 0.6, 0.12, 0.16))   -- under the clicked var
    selectedRow.hidden = true
    rows = {}
    for r = 1, ROWS do
        local y = ROW_Y + (r - 1) * ROW_H
        local row = {}
        for i, c in ipairs(COLUMNS) do row[i] = text(c[2], y, c[3], "") end
        -- a click anywhere on the row selects that var and copies the cell under the mouse into the copy box
        row.hit = blocking(rect(6, y - 1, PIN_X - 10, ROW_H, Vector4.new(0, 0, 0, 0)))
        row.hit:Subscribe(ui.Hook.ONCLICK, function()
            local m = mouse()
            if not (m and row.full) then return end
            if row.name then selected = row.name end
            if copyWiki and row.name and catalogue[row.name] then
                copied = Export.wikiRow(row.name, catalogue[row.name]):gsub("^|%-%s*", ""):gsub("%s+$", "")
                notice("Wiki row copied to the box.")
            else
                local x = m.x - pos.x
                for i, c in ipairs(COLUMNS) do
                    if x >= c[2] and x < c[2] + c[3] and row.full[i] and row.full[i] ~= "" then
                        copied = row.full[i]
                        notice("Copied to the box.")
                    end
                end
            end
            copyBox.content = copied
            refresh()
        end)
        row.hit:Subscribe(ui.Hook.ONSCROLLWHEEL, wheel)
        row.pin = button("+", PIN_X, y - 1, 24, function()
            if row.name then
                pinned[row.name] = not pinned[row.name] or nil
                dirty = true; refresh()
            end
        end)
        rows[r] = row
    end
    selectedText = text(652, 68, W - 662, "", GREY)   -- "Selected: NAME" (made after the rows)

end

local function buildScroll()
    -- The scroll bar shows where you are in the list; click the track above or below the handle to jump a page, or
    -- use the mouse wheel anywhere on the window
    TRACK_Y, TRACK_H = ROW_Y - 2, ROWS * ROW_H
    local track = blocking(rect(BAR_X, TRACK_Y, BAR_W, TRACK_H, Vector4.new(0.02, 0.02, 0.02, 0.8)))
    barHandle = rect(BAR_X, TRACK_Y, BAR_W, TRACK_H, Vector4.new(0.55, 0.45, 0.28, 1))
    pcall(function() barHandle.clickthrough = true end)
    track:Subscribe(ui.Hook.ONCLICK, function()
        local m = mouse()
        if not m then return end
        if m.y - pos.y < barHandle.y then scrollTo(offset - ROWS) else scrollTo(offset + ROWS) end
    end)
end

local function build()
    buildFrame()
    buildToolbar()
    buildList()
    buildScroll()
end

build()


local function ago(seenAt)
    if not seenAt then return "earlier" end
    local s = math.floor((tick - seenAt) / 50)
    if s < 2 then return "now" elseif s < 60 then return s .. "s" else return math.floor(s / 60) .. "m" end
end

-- What a view shows, as { name, cells } items (name is nil for rows that aren't a var, like history lines)
local function details()
    local e = catalogue[selected]
    local bits = e.parent and ("bits " .. (e.bits or "?") .. " of " .. e.parent) or (e.valueType or "")
    local items = { { name = selected, cells = { selected, e.kind, tostring(e.id), bits, tostring(e.changes), ago(e.seenAt), e.after or "" } } }
    for i = #(e.history or {}), 1, -1 do                 -- newest first
        local h = e.history[i]
        items[#items + 1] = { cells = { h.value, "", "", h.old, "", ago(h.at), h.after or "" } }
    end
    return items
end
local function listing()
    local list = {}
    local shown = catalogue
    if abilityView then
        shown = {}
        for id, label in pairs(abilities) do
            shown[id] = { kind = "Ability", id = id, label = label, value = "", changes = 0,
                seenAt = abilitySeen[id], after = abilityStems[id] or "" }
        end
    end
    for name, e in pairs(shown) do
        local hit = query == "" or name:lower():find(query, 1, true) or (e.after and e.after:lower():find(query, 1, true))
            or (abilityView and e.label:lower():find(query, 1, true))
        local inView = abilityView or (view == "hidden" and hidden[name]) or (view == "mark" and e.markID == markID and not hidden[name])
            or (view == "list" and not hidden[name])
        if hit and inView and (not pinnedOnly or pinned[name]) then list[#list + 1] = { name = name, e = e } end
    end
    table.sort(list, function(a, b)
        local pa, pb = pinned[a.name] and 1 or 0, pinned[b.name] and 1 or 0
        if pa ~= pb then return pa > pb end
        if sortBy == "changes" and a.e.changes ~= b.e.changes then return a.e.changes > b.e.changes end
        if sortBy == "recent" and (a.e.seenAt or -1) ~= (b.e.seenAt or -1) then return (a.e.seenAt or -1) > (b.e.seenAt or -1) end
        return (a.e.label or a.name) < (b.e.label or b.name)
    end)
    local items = {}
    for _, item in ipairs(list) do
        local e = item.e
        local shownID = (settings.positiveIds and type(e.id) == "number") and math.abs(e.id) or e.id
        local value = (view == "mark" and e.markOld) and (e.markOld .. " to " .. tostring(e.value)) or e.value
        items[#items + 1] = { name = not abilityView and item.name or nil,
            cells = { e.label or item.name, e.kind, tostring(shownID), value, abilityView and "" or tostring(e.changes),
                      ago(e.seenAt), e.after or "" } }
    end
    return items
end

-- Fill the rows for the current view
refresh = function()
    if view == "details" and not (selected and catalogue[selected]) then view = "list" end
    local items = view == "details" and details() or listing()
    listSize = #items
    offset = math.max(0, math.min(maxOffset(), offset))
    selectedRow.hidden = true
    for r, row in ipairs(rows) do
        local item = items[offset + r]
        row.name = item and item.name or nil
        row.full = item and item.cells or nil
        for i, c in ipairs(COLUMNS) do row[i].content = fit(row.full and row.full[i] or "", c[3] - 6) end
        pcall(function() row[1].colour = (row.name and pinned[row.name]) and YELLOW or CREAM end)
        row.pin.hidden = not row.name or view == "details"
        row.pin.label = (row.name and pinned[row.name]) and "-" or "+"
        if row.name and row.name == selected and view ~= "details" then
            selectedRow:SetPos(6, ROW_Y + (r - 1) * ROW_H - 1)
            selectedRow.hidden = false
        end
    end
    local titles = abilityView and { "Label (derived)", "Kind", "Ability ID", "Value", "Changes", "Seen", "Game stem" }
        or view == "details" and { "Value", "Kind", "ID", "Was / bits", "Changes", "Seen", "After" }
        or view == "mark" and { "Name", "Kind", "ID", "Was to now", "Changes", "Seen", "After" } or nil
    for i, c in ipairs(COLUMNS) do headings[i].content = titles and titles[i] or c[1] end

    local what = abilityView and "abilities" or view == "details" and "lines" or view == "mark" and "changed since mark"
        or view == "hidden" and "hidden" or "vars"
    status.content = (listSize > ROWS and ((offset + 1) .. "-" .. math.min(listSize, offset + ROWS) .. " of ") or "")
        .. listSize .. " " .. what .. (paused and ", paused" or "")
    if tick >= noticeUntil then help.content = "" end
    hiddenButton.label = view == "hidden" and "Back" or ("Hidden: " .. count(hidden))
    detailsButton.label = view == "details" and "Back" or "Details"
    hideButton.label = (selected and hidden[selected]) and "Unhide" or "Hide"
    selectedText.content = selected and fit("Selected: " .. selected, W - 668) or "Click a var to select it."
    placeHandle()
end

-- Keep the window up to date every game tick (0.6 s) while it's showing
Event.ServerLogic.Subscribe("varWatchWindow", function()
    window.hidden = not settings.window
    if settings.window and not paused then refresh() end
end)
-- a drag follows the mouse every client tick (20 ms), so the window keeps up with it
Event.Logic.Subscribe("varWatchDrag", followMouse)
refresh()

-- Save and tidy up when the plugin is turned off
function PluginShutdown()
    save()
    Event.Logic.Unsubscribe("varWatchClock")
    Event.Logic.Unsubscribe("varWatchDrag")
    Event.VarTransmit.Unsubscribe("varWatchVars")
    Event.ServerLogic.Unsubscribe("varWatchWindow")
    Event.MiniMenuEntrySelected.Unsubscribe("varWatchActions")
    Event.SkillTransmit.Unsubscribe("varWatchXp")
    Event.SettingsLayerReady.Unsubscribe("varWatch")
    pcall(function() window:Destroy() end)
end

log("Var Watch is on: " .. count(catalogue) .. " vars in the catalogue so far")
