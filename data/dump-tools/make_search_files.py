"""Turns what the Data Dump plugin saved into item and variable search lists (the files the Dev Kit loads).

    python make_search_files.py [PluginData.db] [output folder]

PluginData.db is where the game keeps plugin saves; the beta client's is the default. The game can stay open, the
script reads a copy. It writes search_items_1.lua, search_items_2.lua ... and search_vars_1.lua ... into the output
folder (default: here). Each one is a Lua module that returns { "<lines>" }, one entry per line, tab-separated:
    items   name, config name, id
    vars    config name, kind (p = VarPlayer, b = varbit, c = VarClient), id
"""
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile

DB = r"C:\ProgramData\Jagex\RuneScape-BETA\plugins\PluginData.db"
PART = 180000   # bytes per file at most


def plain(node):
    # the game saves a Lua table as a list of {"key": ..., "value": ...}
    if isinstance(node, list) and node and all(isinstance(e, dict) and set(e) == {"key", "value"} for e in node):
        return {e["key"]: plain(e["value"]) for e in node}
    if isinstance(node, list):
        return [plain(e) for e in node]
    return node


def decode(value):
    text = value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)
    return plain(json.JSONDecoder().raw_decode(text.strip())[0])


def load(db):
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "PluginData.db")
        shutil.copy2(db, copy)
        con = sqlite3.connect(copy)
        saved = dict(con.execute("select Key, Value from DataStore where PluginID = ?", ["Data Dump"]))
        con.close()
    return saved


def table(saved, key):
    # every saved line of one table, as {column: value}
    rows, n = [], 1
    while "%s_%d" % (key, n) in saved:
        piece = decode(saved["%s_%d" % (key, n)])
        header = piece["header"].split("|")
        for line in piece["lines"].split("\n"):
            cells = line.split("|")
            if len(cells) == len(header):
                rows.append(dict(zip(header, cells)))
        n += 1
    return rows


def clean(text):
    return re.sub(r"[\t\r\n]+", " ", text or "").strip()


def write(folder, base, header, lines):
    for old in os.listdir(folder):
        if re.match(r"^%s_\d+\.lua$" % base, old):
            os.remove(os.path.join(folder, old))
    parts, chunk, size = [], [], 0
    for line in lines:
        if chunk and size + len(line.encode("utf-8")) + 1 > PART:
            parts.append(chunk)
            chunk, size = [], 0
        chunk.append(line)
        size += len(line.encode("utf-8")) + 1
    if chunk:
        parts.append(chunk)
    for i, chunk in enumerate(parts, 1):
        body = "\n".join(chunk)
        level = 0
        while ("]" + "=" * level + "]") in body:   # a long string the text can't close early
            level += 1
        eq = "=" * level
        with open(os.path.join(folder, "%s_%d.lua" % (base, i)), "w", encoding="utf-8", newline="\n") as f:
            f.write("-- %s (part %d)\n-- Made by make_search_files.py from a Data Dump save.\nreturn { [%s[\n%s\n]%s] }\n"
                    % (header, i, eq, body, eq))
    print("%-13s %6d entries in %d files" % (base, len(lines), len(parts)))


def main():
    db = sys.argv[1] if len(sys.argv) > 1 else DB
    out = sys.argv[2] if len(sys.argv) > 2 else "."
    saved = load(db)
    if "summary" not in saved:
        sys.exit("No Data Dump save in %s. Run the plugin in game first." % db)
    done = decode(saved["summary"]).get("done", "").split(",")
    missing = [k for k in ("items", "varps", "varbits", "varcs") if k not in done]
    if missing:
        sys.exit("Data Dump hasn't finished yet (still to do: %s). Leave it running until it says done." % ", ".join(missing))
    os.makedirs(out, exist_ok=True)
    items = ["%s\t%s\t%s" % (clean(r["name"]), clean(r["config_name"]), r["id"]) for r in table(saved, "items")]
    variables = (["%s\tp\t%s" % (clean(r["config_name"]), r["id"]) for r in table(saved, "varps")]
                 + ["%s\tb\t%s" % (clean(r["config_name"]), r["varbit"]) for r in table(saved, "varbits")]
                 + ["%s\tc\t%s" % (clean(r["config_name"]), r["id"]) for r in table(saved, "varcs")])
    variables = [v for v in variables if not v.startswith("\t")]
    write(out, "search_items", "Every item: name, config name, item id", items)
    write(out, "search_vars", "Every variable: config name, kind (p VarPlayer, b varbit, c VarClient), id", variables)


main()
