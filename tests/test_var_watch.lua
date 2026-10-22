-- Offline check for Var Watch on a stand-in of the game API: a changed variable is printed and added to the catalogue
-- with the action just before it, unchanged sends are ignored, noisy vars stop printing but keep counting, the window
-- lists the catalogue (search, sort, pin, scroll, wiki tools), it can be dragged by its title bar, and the catalogue,
-- pins and window position are saved and loaded again. The stand-in is our guess of the API, not proof.
--   lua tests/test_var_watch.lua      (Lua 5.1 / LuaJIT or 5.4)
local here = arg[0]:match("^(.*)[/\\]") or "."
local checks = 0
local function check(ok, what) assert(ok, "Var Watch: " .. what); checks = checks + 1 end

local HOOK = { ONBUTTONPRESSED = 1, ONCLICK = 2, ONHOLD = 3, ONRELEASE = 4, ONSCROLLWHEEL = 5, ONDRAG = 6, ONDRAGCOMPLETE = 7 }
local function run(store)
    local subs, logs, texts, buttons, fields, rects, layers = {}, {}, {}, {}, {}, {}, {}
    local mousePos = { x = 0, y = 0 }
    local function event(name) return { Subscribe = function(_, fn) subs[name] = fn end, Unsubscribe = function() subs[name] = nil end } end
    local function widget(list) return function() local w = { text = {}, hooks = {} }
        function w:SetPos(x, y) self.x, self.y = x, y end; function w:SetSize() end; function w:Setup() end
        function w:Destroy() self.gone = true end
        function w:Subscribe(hook, fn) self.hooks[hook] = fn; if hook == HOOK.ONBUTTONPRESSED then self.press = fn end end
        if list then list[#list + 1] = w end; return w end end
    local env
    env = setmetatable({
        require = function(name) return assert(loadfile(here .. "/../var-watch/" .. name .. ".lua", "t", env))() end,
        ui = { Interfaces = { GetComponent = function() return { width = 1920 } end }, Layer = { new = widget(layers) },
               Rectangle = { new = widget(rects) }, Text = { new = widget(texts) }, Button = { new = widget(buttons) },
               InputField = { new = widget(fields) }, Hook = HOOK,
               TextContentVisibilityMode = { VISIBLE = 0 }, InputFieldFilterMode = { NONE = 0 } },
        id = { Component = {}, Font = {}, StyleSheet = {} },
        Vector4 = { new = function(...) return { ... } end },
        Mouse = { GetPosition = function() return { x = mousePos.x, y = mousePos.y } end },
        SkillType = { FromID = function() return "WOODCUTTING" end },
        var = { VarPlayer = { FromID = function(i)
            local names = { [958] = "COMBATV2_COOLDOWN_DEFENCE_RESONANCE_START", [959] = "COMBATV2_COOLDOWN_DEFENCE_RESONANCE_END",
                            [6960] = "COMBATV2_COOLDOWN_ATTACK_BLADED_DIVE_START", [6961] = "COMBATV2_COOLDOWN_ATTACK_BLADED_DIVE_END" }
            if names[i] then return { configName = names[i] } end
            error("no var") end } },
        PersistentDB = { GetStructuredData = function(_, k) return store[k] end,
            SetStructuredData = function(_, k, v) if store.failExport and k == 'exportInfo' then return false end; store[k] = v; return true end,
            Set = function(_, k, v) if store.failExport then return false end; store[k] = v; return true end },
        Event = { Logic = { Subscribe = function(_, fn) subs.ticks = subs.ticks or {}; table.insert(subs.ticks, fn) end, Unsubscribe = function() end },
                  ServerLogic = event("server"), VarTransmit = event("var"), SettingsLayerReady = event("settings"),
                  MiniMenuEntrySelected = event("menu"), SkillTransmit = event("xp") },
        log = function(text) logs[#logs + 1] = text end,
    }, { __index = _G })
    assert(loadfile(here .. "/../var-watch/main.lua", "t", env))()
    local function tick(n) for _ = 1, n or 1 do for _, fn in ipairs(subs.ticks) do fn() end end end
    local function find(label) for _, b in ipairs(buttons) do if b.label == label then return b end end end
    local function rowText(r, col) return texts[3 + 7 + (r - 1) * 7 + col].content end   -- title, status, help, 7 headings
    return { subs = subs, logs = logs, find = find, rowText = rowText, fields = fields, shutdown = env.PluginShutdown,
             buttons = buttons, rects = rects, window = layers[1], layers = layers, mouse = mousePos, tick = tick }
end

local ability = { configName = "COMBATV2_JUST_USED_ABILITY", typeName = "VarClient", isVarBit = false, id = 4098 }
local bank = { configName = "BANK_SOMETHING", typeName = "VarPlayer", isVarBit = true, id = -123, baseVar = { id = 456 } }
local clock = { configName = "SOME_CLOCK", typeName = "VarPlayer", isVarBit = false, id = 7 }
local store = {}
local g = run(store)

g.subs.var({ var = ability, oldValue = 14710, newValue = 14711 })
check(g.logs[#g.logs] == "Var Watch: VarClient COMBATV2_JUST_USED_ABILITY (4098): 14710 -> 14711", "a change prints: " .. g.logs[#g.logs])
local before = #g.logs
g.subs.var({ var = ability, oldValue = 14711, newValue = 14711 })
check(#g.logs == before, "an unchanged send prints nothing")

-- An action, then a change: the change is put down to it (colour tags dropped); a VarBit shows its parent
g.subs.menu({ entry = { fullText = "Withdraw-1 <col=ff9040>Bank chest</col>" } })
g.tick(10)
g.subs.var({ var = bank, oldValue = 0, newValue = 1 })
check(g.logs[#g.logs] == "Var Watch: VarPlayer bit of 456 BANK_SOMETHING (-123): 0 -> 1  (after: Withdraw-1 Bank chest)",
      "a change after a menu action names it, and a VarBit names its parent: " .. g.logs[#g.logs])
g.tick(200)                                                            -- 4 s later: too long ago to blame
g.subs.var({ var = bank, oldValue = 1, newValue = 2 })
check(not g.logs[#g.logs]:find("after", 1, true), "a change long after the action isn't put down to it")

for i = 1, 12 do g.subs.var({ var = clock, oldValue = i, newValue = i + 1 }); g.tick() end
local quiet = 0
for _, line in ipairs(g.logs) do if line:find("SOME_CLOCK changes too often", 1, true) then quiet = quiet + 1 end end
check(quiet == 1, "a fast-changing var stops printing, once")

-- The window: most recent first, with kind, ID, value and the action
g.subs.server()
check(g.rowText(1, 1) == "SOME_CLOCK" and g.rowText(1, 5) == "12", "the window shows the most recent var first, with its changes")
check(g.rowText(2, 1) == "BANK_SOMETHING" and g.rowText(2, 2) == "VarPlayer b.." and g.rowText(2, 7) == "Withdraw-1 Bank ch..",
      "with its kind and the action before it: " .. g.rowText(2, 2) .. " / " .. g.rowText(2, 7))
-- search also looks at actions
g.fields[1].content = "bank chest"
g.find("Search").press(g.find("Search"))
check(g.rowText(1, 1) == "BANK_SOMETHING" and g.rowText(2, 1) == "", "search finds vars by the action that moved them")
g.find("Clear").press(g.find("Clear"))
-- pin the second row: it goes to the top
for _, b in ipairs(g.buttons) do if b.label == "+" and b.y and b.y > 128 and b.y < 140 then b.press(b) end end
check(g.rowText(1, 1) == "BANK_SOMETHING", "a pinned var stays at the top")

-- The window's background takes clicks, so they never reach the game underneath
local blockers = 0
for _, r in ipairs(g.rects) do if r.clickthrough == false and r.hooks[HOOK.ONCLICK] then blockers = blockers + 1 end end
check(blockers >= 2, "the background and title bar take clicks instead of the game: " .. blockers)


-- The ability map: an ability ID arriving with a cooldown start is named after it, and shown from then on
local divestart = { configName = "COMBATV2_COOLDOWN_ATTACK_BLADED_DIVE_START", typeName = "VarPlayer", isVarBit = false, id = 6960 }
g.subs.var({ var = ability, oldValue = 14711, newValue = 47129 })
g.tick(3)
g.subs.var({ var = divestart, oldValue = 0, newValue = 55000 })
local named = false
for _, line in ipairs(g.logs) do if line == "Var Watch: ability 47129 is Bladed Dive (Attack)" then named = true end end
check(named, "ability 47129 is learned as Bladed Dive from its cooldown var")
g.tick(200)
g.subs.var({ var = ability, oldValue = 47129, newValue = 14711 })
g.subs.var({ var = ability, oldValue = 14711, newValue = 47129 })
check(g.logs[#g.logs]:find("14711 -> 47129 Bladed Dive (Attack)", 1, true), "and shown by name from then on: " .. g.logs[#g.logs])
-- the start-up scan lists every cooldown var in the game
g.tick(200)
check(store.cooldownVars and store.cooldownVars.DEFENCE_RESONANCE and store.cooldownVars.DEFENCE_RESONANCE.start == 958
      and store.cooldownVars.ATTACK_BLADED_DIVE.finish == 6961, "the scan finds every ability cooldown var")

-- Saved: the catalogue, pins and position come back next time
g.shutdown()
check(store.catalogue and store.catalogue.BANK_SOMETHING.after == "Withdraw-1 Bank chest" and store.catalogue.SOME_CLOCK.changes == 12,
      "the catalogue is saved with the actions")
local again = run(store)
again.subs.server()
check(again.logs[#again.logs]:find("4 vars in the catalogue", 1, true), "it loads the catalogue next time: " .. again.logs[#again.logs])
check(again.rowText(1, 1) == "BANK_SOMETHING" and again.rowText(1, 6) == "earlier", "pins load too, old ones show as earlier")
check(store.abilities and store.abilities["47129"] == "Bladed Dive (Attack)", "the ability names are saved")
-- The new view keeps derived labels separate from the verbatim cooldown stem and ability ID.
again.find('Abilities').press()
check(again.rowText(1,1) == 'Bladed Dive (Attack)' and again.rowText(1,3) == '47129', 'Abilities lists the learned ID and derived label')
check(again.rowText(1,7):find('ATTACK_BLADED_',1,true), 'Abilities includes the raw stem, shortened only for display')
again.fields[1].content = 'bladed dive';again.find('Search').press()
check(again.rowText(1,1) == 'Bladed Dive (Attack)', 'ability search finds the derived name')
again.fields[1].content = 'ATTACK_BLADED_DIVE';again.find('Search').press()
check(again.rowText(1,3) == '47129', 'ability search finds the verbatim stem')
again.fields[1].content = '47129';again.find('Search').press()
check(again.rowText(1,1) == 'Bladed Dive (Attack)', 'ability search finds the game ID')
again.find('Export').press()
check(store.exportInfo.complete and store.exportInfo.mode == 'abilities' and store.exportInfo.rows == 1, 'manual ability export reports completion')
check(store.exportText001 == 'ability_id\tderived_label\tgame_var_stem\n47129\tBladed Dive (Attack)\tATTACK_BLADED_DIVE\n', 'ability export separates game values and labels')
again.find('Variables').press();again.fields[1].content = 'bank chest';again.find('Search').press()
local idsButton = again.find('Negative IDs: on')
check(idsButton, 'the window says "Negative IDs: on" by default (shown with the minus)')
idsButton.press(idsButton)
check(idsButton.label == 'Negative IDs: off' and store.varWatch.positiveIds == true, 'pressing it turns them off and saves it')
again.find('Export').press()
check(store.exportInfo.complete and store.exportInfo.mode == 'catalogue' and store.exportInfo.rows == 4, 'catalogue export covers all records, not the filtered page')
check(store.exportText001:find('BANK_SOMETHING\tVarPlayer bit of 456\t-123\t2\t2',1,true), 'export keeps the original negative ID and raw value')
check(store.catalogue.COMBATV2_JUST_USED_ABILITY.rawValue == '47129', 'saved raw ability value excludes the derived display label')
store.failExport = true;again.find('Export').press()
check(again.logs[#again.logs]:find('Var Watch export:',1,true), 'failed export is reported instead of claiming success')
store.failExport = false
-- The cog says the same: "Negative IDs: off" now (it was turned off above), "on" again after a press
local cogStart = #again.buttons
again.subs.settings({ component = {} })
local negative
for i = cogStart + 1, #again.buttons do if again.buttons[i].label:find('^Negative IDs') then negative = again.buttons[i] end end
check(negative and negative.label == 'Negative IDs: off', 'the cog shows "Negative IDs: off": ' .. tostring(negative and negative.label))
negative.press(negative)
check(negative.label == 'Negative IDs: on', 'and "Negative IDs: on" after a press: ' .. negative.label)
local plainSwitch
for i = cogStart + 1, #again.buttons do if again.buttons[i].label:find('^Show the window') then plainSwitch = again.buttons[i] end end
check(plainSwitch and plainSwitch.label == 'Show the window: on', 'the other switches still read as before')
again.shutdown()

-- Dragging (1.0.1): press on the title bar, move the mouse, and the window follows; letting go saves where it is
local dstore = {}
local d = run(dstore)
local bar = d.rects[2]
check(bar.hooks[HOOK.ONCLICK] and bar.hooks[HOOK.ONRELEASE] and bar.clickthrough == false and bar.y == 3,
      'the title bar takes the press and the release')
local x0, y0 = d.window.x, d.window.y
d.mouse.x, d.mouse.y = x0 + 200, y0 + 10
bar.hooks[HOOK.ONCLICK]()
d.mouse.x, d.mouse.y = x0 + 200 - 150, y0 + 10 + 80
d.tick()
check(d.window.x == x0 - 150 and d.window.y == y0 + 80, 'the window follows the mouse: ' .. d.window.x .. ',' .. d.window.y)
d.mouse.x, d.mouse.y = d.mouse.x + 5000, d.mouse.y - 5000
d.tick()
check(d.window.x == 1920 - 60 and d.window.y == 0, 'but stays reachable on screen: ' .. d.window.x .. ',' .. d.window.y)
d.mouse.x, d.mouse.y = x0 + 200 - 300, y0 + 10 + 40
d.tick()
bar.hooks[HOOK.ONRELEASE]()
check(dstore.window and dstore.window.x == x0 - 300 and dstore.window.y == y0 + 40 and dstore.window.w == 900,
      'letting go saves the place')
d.mouse.x = d.mouse.x + 100
d.tick()
check(d.window.x == x0 - 300, 'after letting go the window stays put')
-- a click on a row still copies the right cell after a move (the window's new place is used)
d.subs.var({ var = clock, oldValue = 1, newValue = 2 }); d.tick(); d.subs.server()
local rowHit1
for _, r in ipairs(d.rects) do if r.hooks[HOOK.ONCLICK] and r.y == 111 then rowHit1 = r end end
d.mouse.x, d.mouse.y = d.window.x + 20, d.window.y + 118
rowHit1.hooks[HOOK.ONCLICK]()
check(d.fields[2].content == 'SOME_CLOCK', 'cell clicks follow the moved window: ' .. tostring(d.fields[2].content))
d.shutdown()
local d2 = run(dstore)
check(d2.window.x == x0 - 300 and d2.window.y == y0 + 40, 'the window opens where it was left')
-- a place saved on a bigger screen is pulled back on
dstore.window = { x = 5000, y = 3000 }
local d3 = run(dstore)
check(d3.window.x == 1920 - 60, 'a place off the screen is pulled back: ' .. d3.window.x)
-- the drag is also dropped when the mouse has been off the title bar a while (the button can't be read)
local d4 = run({})
local bar4 = d4.rects[2]
bar4.isMouseOver = true
d4.mouse.x, d4.mouse.y = d4.window.x + 100, d4.window.y + 10
bar4.hooks[HOOK.ONCLICK]()
bar4.isMouseOver = false
d4.tick(17)
local stopped = d4.window.x
d4.mouse.x = d4.mouse.x - 40
d4.tick()
check(d4.window.x == stopped, 'a drag ends after the mouse is off the title bar for 16 ticks')
-- Scrolling and the copy box, on a fresh catalogue of 30 vars
local big = run({})
for i = 1, 30 do
    big.subs.var({ var = { configName = string.format("VAR_%02d", i), typeName = "VarPlayer", isVarBit = false, id = 1000 + i },
                   oldValue = 0, newValue = i })
    big.tick()
end
big.find("Sort: recent").press(big.find("Sort: recent")); big.find("Sort: changes").press(big.find("Sort: changes"))   -- sort by name
big.subs.server()
check(big.rowText(1, 1) == "VAR_01" and big.rowText(14, 1) == "VAR_14", "the list starts at the top")
local function rectWith(test) for _, r in ipairs(big.rects) do if test(r) then return r end end end
local back = big.rects[1]
back.hooks[HOOK.ONSCROLLWHEEL](back, 1)
check(big.rowText(1, 1) == "VAR_04", "the mouse wheel scrolls three rows: " .. big.rowText(1, 1))
back.hooks[HOOK.ONSCROLLWHEEL](back, -1)
check(big.rowText(1, 1) == "VAR_01", "and back up")
-- click the scroll track below the handle: a page down each time, stopping at the end
local track = rectWith(function(r) return r.hooks[HOOK.ONCLICK] and r.x == 882 end)
local wx, wy = big.window.x, big.window.y
big.mouse.x, big.mouse.y = wx + 886, wy + 110 + 14 * 22 - 5
track.hooks[HOOK.ONCLICK]()
check(big.rowText(1, 1) == "VAR_15", "clicking the track pages down: " .. big.rowText(1, 1))
track.hooks[HOOK.ONCLICK]()
check(big.rowText(14, 1) == "VAR_30", "and stops at the last rows: " .. big.rowText(14, 1))
-- click the Kind cell of the first row: its value goes into the copy box
local hit = rectWith(function(r) return r.hooks[HOOK.ONCLICK] and r.y == 111 end)
big.mouse.x, big.mouse.y = wx + 360, wy + 118
hit.hooks[HOOK.ONCLICK]()
check(big.fields[2].content == "VarPlayer", "clicking a cell puts its full value in the copy box: " .. tostring(big.fields[2].content))
big.mouse.x = wx + 20
hit.hooks[HOOK.ONCLICK]()
check(big.fields[2].content == "VAR_17", "clicking the name copies the full name: " .. tostring(big.fields[2].content))
-- The wiki tools, on a fresh catalogue: a VarBit (bits 3-5 of var 77) and a busy VarClient
local wstore = {}
local w = run(wstore)
local bitVar = { configName = "QUEST_BITS", typeName = "VarPlayer", isVarBit = true, id = -500, baseVar = { id = 77 }, varBitMask = 56 }
local ticker = { configName = "TICKER", typeName = "VarClient", isVarBit = false, id = 9 }
w.subs.var({ var = bitVar, oldValue = 0, newValue = 2 }); w.tick()
w.subs.var({ var = ticker, oldValue = 1, newValue = 2 }); w.tick()
w.subs.server()
local function rowHit(r)
    for _, x in ipairs(w.rects) do if x.hooks[HOOK.ONCLICK] and x.y == 111 + (r - 1) * 22 then return x end end
end
local function clickName(r) w.mouse.x, w.mouse.y = w.window.x + 20, w.window.y + 118 + (r - 1) * 22; rowHit(r).hooks[HOOK.ONCLICK]() end
local function press(label) local b = w.find(label); assert(b, "no button " .. label); b.press(b) end
check(w.rowText(1, 1) == "TICKER" and w.rowText(2, 1) == "QUEST_BITS", "newest first")
-- Details: select QUEST_BITS, see its parent var and bits, then its history
clickName(2)
press("Details")
check(w.rowText(1, 1) == "QUEST_BITS" and w.rowText(1, 4) == "bits 3-5 of 77", "Details shows a VarBit's parent and bit range: " .. w.rowText(1, 4))
check(w.rowText(2, 1) == "2" and w.rowText(2, 4) == "0", "and its history, value and the value before")
press("Back")
-- Copy as a wiki row
press("Copy: value")
clickName(2)
check(w.fields[2].content == "| QUEST_BITS || VarBit || -500 || 77 || 3-5 || 2 ||",
      "in wiki mode a click copies the row as a wiki table line: " .. tostring(w.fields[2].content))
press("Copy: wiki row")
-- Mark: only what changes after it, with the old and new value
press("Mark")
w.subs.var({ var = ticker, oldValue = 2, newValue = 3 }); w.tick(); w.subs.server()
check(w.rowText(1, 1) == "TICKER" and w.rowText(1, 4) == "2 to 3" and w.rowText(2, 1) == "", "Mark lists only what changed since, was to now")
press("End mark")
-- Hide: TICKER disappears from the list and the console; the hidden list brings it back
clickName(1)
press("Hide")
check(w.rowText(1, 1) == "QUEST_BITS" and w.rowText(2, 1) == "", "a hidden var leaves the list")
local logged = #w.logs
w.subs.var({ var = ticker, oldValue = 3, newValue = 4 }); w.tick()
check(#w.logs == logged, "and stops printing in the console")
press("Hidden: 1")
check(w.rowText(1, 1) == "TICKER", "the hidden list shows it, to unhide")
press("Back")
-- Wiki export: the whole catalogue as a wiki table
press("Wiki export")
local wiki = wstore.exportText001 or ""
check(wiki:sub(1, 30) == '{| class="wikitable sortable"\n' and wiki:find("| QUEST_BITS || VarBit || -500 || 77 || 3-5 || 2 ||", 1, true)
      and wiki:sub(-3) == "|}\n" and wstore.exportInfo.mode == "wiki" and wstore.exportInfo.complete,
      "Wiki export writes the catalogue as a wiki table")
print("Var Watch: " .. checks .. " checks passed (" .. _VERSION .. ")")
