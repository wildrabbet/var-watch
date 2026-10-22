-- Export: the catalogue (or the ability names) as plain tab-separated text, built only when you press the button.
-- No automatic export, no clipboard, no network. The text is saved with PersistentDB in pieces small enough to store.
local M = {}

-- One cell of the table: tabs and line breaks are written as \t and \n so they can't break the columns
local function cell(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub("\t", "\\t")
    text = text:gsub("\r", "\\r")
    text = text:gsub("\n", "\\n")
    return text
end

-- One var as a row of the wiki table (MediaWiki markup): name, kind, ID, parent var and bits for a VarBit, last value,
-- and the action seen just before it last changed
M.WIKI_HEAD = '{| class="wikitable sortable"\n! Name !! Kind !! ID !! Parent !! Bits !! Last value !! Changed after\n'
function M.wikiRow(name, e)
    local kind = tostring(e.kind or ""):match("^(%a+)") or ""
    if e.parent then kind = "VarBit" end
    local function c(v) return (tostring(v or ""):gsub("|", "&#124;")) end   -- a "|" would break the table
    return "|-\n| " .. c(name) .. " || " .. c(kind) .. " || " .. c(e.id) .. " || " .. c(e.parent) .. " || " .. c(e.bits)
        .. " || " .. c(e.rawValue or e.value) .. " || " .. c(e.after) .. "\n"
end

function M.build(mode, catalogue, abilities, stems)
    local source = mode == "abilities" and abilities or catalogue
    local keys = {}
    for key in pairs(source) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local lines = {}
    if mode == "wiki" then
        lines[1] = M.WIKI_HEAD
        for _, key in ipairs(keys) do lines[#lines + 1] = M.wikiRow(key, catalogue[key]) end
        lines[#lines + 1] = "|}\n"
        local text = table.concat(lines)
        if #text > 8 * 1024 * 1024 then return nil, "Export is over 8 MB; nothing was saved." end
        return { text }, { mode = mode, rows = #keys, parts = 1, bytes = #text, format = "MediaWiki table" }
    elseif mode == "abilities" then
        lines[1] = "ability_id\tderived_label\tgame_var_stem\n"
    else
        lines[1] = "game_var_name\tkind\tgame_var_id\traw_value_if_recorded\tstored_display_value\tchanges\tafter_action\n"
    end
    local bytes = #lines[1]

    for _, key in ipairs(keys) do
        local values
        if mode == "abilities" then
            values = { key, abilities[key], stems[key] or "" }
        else
            local e = catalogue[key]
            values = { key, e.kind or "", e.id or "", e.rawValue or "", e.value or "", e.changes or "", e.after or "" }
        end
        for i = 1, #values do values[i] = cell(values[i]) end
        local line = table.concat(values, "\t") .. "\n"
        bytes = bytes + #line
        if bytes > 8 * 1024 * 1024 then return nil, "Export is over 8 MB; nothing was saved." end
        lines[#lines + 1] = line
    end

    -- Split the text into pieces of at most 32 KB, never cutting a UTF-8 character in half
    local text = table.concat(lines)
    local parts = {}
    local first = 1
    while first <= #text do
        local last = math.min(#text, first + 32767)
        local nextByte = text:byte(last + 1)
        while nextByte and nextByte >= 128 and nextByte < 192 do
            last = last - 1
            nextByte = text:byte(last + 1)
        end
        parts[#parts + 1] = text:sub(first, last)
        first = last + 1
    end
    return parts, { mode = mode, rows = #keys, parts = #parts, bytes = #text, format = "TSV; backslash escapes tabs/newlines" }
end

return M
