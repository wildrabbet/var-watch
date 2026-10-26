-- Data Dump
-- Saves the name and config name of every item and every variable in the game, so they can be searched outside it.
-- It tries every ID with the plugin API's own lookups and keeps the ones that exist:
--   items     config.Obj.FromID(id)
--   varps     var.VarPlayer.FromID(id)
--   varbits   var.VarPlayer.FromID(-(varbit + 1))
--   varcs     var.VarClient.FromID(id)
-- A table ends at its last ID, or after a long run of IDs that don't exist. Lines are saved in pieces ("items_1",
-- "items_2", ...) and a "summary" after each table, so a reload carries on where it stopped.
-- When the console says it's done, run make_search_files.py. Nothing is clicked or sent.

local VERSION = "1.0.0"
local PIECE = 50000   -- characters per saved piece

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function field(cfg, name) return get(function() return cfg[name] end) end

-- one value as text that can't break a line or a column
local function txt(v)
    if v == nil then return "" end
    return (tostring(v):gsub("[|\r\n]", " "))
end

local function line(...)
    local out = {}
    for i = 1, select("#", ...) do out[i] = txt((select(i, ...))) end
    return table.concat(out, "|")
end

-- key, where the lookup lives, last ID to try, missing IDs in a row before it stops, IDs per tick, columns, one line
local TABLES = {
    { key = "items", src = function() return config.Obj end, to = 100000, gap = 25000, per = 150,
      header = "id|name|config_name",
      row = function(n, c) return line(n, field(c, "name"), field(c, "configName")) end },
    { key = "varps", src = function() return var.VarPlayer end, to = 40000, gap = 40001, per = 600,
      header = "id|config_name",
      row = function(n, c) return line(n, field(c, "configName")) end },
    { key = "varbits", src = function() return var.VarPlayer end, idFor = function(n) return -(n + 1) end,
      to = 120000, gap = 120001, per = 600,
      header = "varbit|config_name",
      row = function(n, c) return line(n, field(c, "configName")) end },
    { key = "varcs", src = function() return var.VarClient end, to = 20000, gap = 20001, per = 600,
      header = "id|config_name",
      row = function(n, c) return line(n, field(c, "configName")) end },
}

-- the lookup found something with a config name
local function exists(c)
    if c == nil then return false end
    local name = field(c, "configName")
    return type(name) == "string" and name ~= ""
end

local summary = { version = VERSION, done = "" }
local doneKeys = {}
local saveError, saveLogged
local t, at, misses, rows, last, pieces, piece, pieceSize, lookup
local index = 0
local finished = false

local function save(key, value)
    local ok, result = pcall(function() return PersistentDB:SetStructuredData(key, value) end)
    if (not ok or result == false) and not saveError then saveError = key .. ": " .. tostring(result) end
end

local function savePiece()
    if #piece == 0 then return end
    pieces = pieces + 1
    save(t.key .. "_" .. pieces, { header = t.header, count = #piece, lines = table.concat(piece, "\n") })
    piece, pieceSize = {}, 0
end

local function startNext()
    repeat
        index = index + 1
        t = TABLES[index]
    until t == nil or not doneKeys[t.key]
    if t == nil then return false end
    at, misses, rows, last, pieces, piece, pieceSize = 0, 0, 0, nil, 0, {}, 0
    local src = get(t.src)
    lookup = src and get(function() return src.FromID end) or nil
    return true
end

local function finishTable()
    savePiece()
    doneKeys[t.key] = true
    summary.done = summary.done == "" and t.key or (summary.done .. "," .. t.key)
    summary[t.key] = rows .. " rows, last id " .. txt(last)
    save("summary", summary)
end

-- carry on after a reload: tables this version already saved are skipped
local saved = get(function() return PersistentDB:GetStructuredData("summary") end)
if type(saved) == "table" and saved.version == VERSION and type(saved.done) == "string" then
    for key in saved.done:gmatch("[^,]+") do doneKeys[key], summary[key] = true, saved[key] end
    summary.done = saved.done
end

local alreadyDone = 0
for _, spec in ipairs(TABLES) do if doneKeys[spec.key] then alreadyDone = alreadyDone + 1 end end
local hasWork = startNext()

-- one client tick: up to t.per IDs of the current table; returns a line to log when a table ends
local function work()
    if lookup == nil then
        local key = t.key
        finishTable()
        return "Data Dump: " .. key .. " isn't in the API on this client, skipped."
    end
    for _ = 1, t.per do
        if at > t.to or misses >= t.gap then
            finishTable()
            return "Data Dump: " .. t.key .. " done, " .. rows .. " rows (last ID " .. txt(last) .. ")."
        end
        local n = at
        local c = get(function() return lookup(t.idFor and t.idFor(n) or n) end)
        -- only nothing at all counts as missing: the API knows some IDs without their names
        if c == nil then misses = misses + 1 else misses = 0 end
        if exists(c) then
            last = n
            local text = get(function() return t.row(n, c) end)
            if type(text) == "string" then
                rows = rows + 1
                piece[#piece + 1] = text
                pieceSize = pieceSize + #text + 1
                if pieceSize >= PIECE then savePiece() end
            end
        end
        at = at + 1
    end
end

Event.Logic.Subscribe("dataDump", function()
    if finished then return end
    local ok, said = pcall(work)
    if not ok then
        said = "Data Dump: " .. t.key .. " stopped at ID " .. at .. " (" .. tostring(said) .. "), moving on."
        finishTable()
    end
    if said then log(said) end
    if doneKeys[t.key] and not startNext() then
        finished = true
        log("Data Dump: done. Run make_search_files.py.")
    end
    if saveError and not saveLogged then
        saveLogged = true
        log("Data Dump: a save failed (" .. saveError .. ").")
    end
end)

function PluginShutdown()
    if not finished and t then
        savePiece()
        save("summary", summary)
    end
    Event.Logic.Unsubscribe("dataDump")
end

if not hasWork then
    finished = true
    log("Data Dump " .. VERSION .. ": already done. Run make_search_files.py.")
elseif alreadyDone > 0 then
    log("Data Dump " .. VERSION .. ": carrying on from " .. t.key .. ".")
else
    log("Data Dump " .. VERSION .. ": on. Saving every item and variable name. Leave the game open until it says done.")
end
