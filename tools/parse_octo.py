#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse cached octowow.st pages into pfQuest database entries.

Deliberately offline. Fetching lives in pfExtend/questGaindb/scrape.py, which
owns the site session; this reads only what that has already written to
cache/html/ and emits Lua. The split matters for two reasons: this half can be
tested and re-run freely without touching the site at all, and a parser bug
costs a re-parse rather than another crawl.

Usage:
    python parse_octo.py selftest    check the parsers against cached samples
    python parse_octo.py plan        work out which pages are still needed
    python parse_octo.py build       cache/html/*.html -> db/octo*.lua

The crawl alternates between this and the fetcher, because what has to be
fetched is only known once the previous round has been read: a quest names its
questgiver, an item names what drops it. "plan" writes fetch.txt and says
whether another round is needed.
"""

import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HTML_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "pfExtend", "questGaindb", "cache", "html"))


def _read(path):
    return io.open(path, encoding="utf-8", errors="replace").read()


def _strip(html):
    """Readable text, scripts and comments removed."""
    body = re.sub(r"<script.*?</script>", " ", html, flags=re.S)
    body = re.sub(r"<style.*?</style>", " ", body, flags=re.S)
    body = re.sub(r"<!--.*?-->", " ", body, flags=re.S)
    return body


def _text(html):
    """Tags removed and runs of whitespace collapsed, so Quick Facts reads as
    "Level : 56 Class: Normal" and one regex per field is enough. The labels
    and their values sit in sibling elements, which is why matching the raw
    markup needs a different pattern on nearly every page."""
    return _unescape(re.sub(r"<[^>]+>", " ", _strip(html)))


def _unescape(s):
    for a, b in (("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                 ("&gt;", ">"), ("&quot;", '"'), ("&#039;", "'"),
                 ("&#39;", "'")):
        s = s.replace(a, b)
    return re.sub(r"\s+", " ", s).strip()


# --------------------------------------------------------------------- quests

#[[ The item template breaks this across several lines while the quest and
#   NPC ones keep it on one, so every gap has to tolerate newlines. ]]
PAGEINFO_RE = re.compile(
    r"g_pageInfo\s*=\s*\{\s*type:\s*(\d+)\s*,\s*typeId:\s*(\d*)", re.S)

#[[ The Quick Facts list is a flat <li><div>Label: value</div></li> run, so one
#   label-to-value pass covers level, the masks and the zone. Named groups
#   rather than positions, because the order is not promised anywhere. ]]
FACTS = {
    "level":     r"Level:\s*(-?\d+)",
    "reqlevel":  r"Requires level:\s*(\d+)",
    "racemask":  r"Race Mask:\s*(\d+)",
    "classmask": r"Class Mask:\s*(\d+)",
    "zone":      r"ZoneOrSort:\s*(-?\d+)",
    "xp":        r"RewXP:\s*(\d+)",
}

#[[ Start and End each name exactly one thing, but it can be an NPC, an object
#   or an item -- 42079 starts from a scroll, not a person. The kind decides
#   which of pfQuest's U/O/I buckets it lands in, so it has to be captured, not
#   assumed. ]]
#   The markup is:  <div>Start : <a href="?item=42385" ...>Name</a></div>
#   and for End a <span> wrapper sits in between, so any run of tags is
#   skipped rather than a specific one matched.
ENDPOINT_RE = re.compile(
    r'(Start|End)\s*:\s*(?:<[^>]*>\s*)*<a href="\?(npc|object|item)=(\d+)',
    re.S)

LETTER = {"npc": "U", "object": "O", "item": "I"}


def parse_quest(html):
    """-> dict, or None when the page is not a real quest."""
    m = PAGEINFO_RE.search(html)
    if not m or m.group(1) != "5" or not m.group(2):
        return None
    out = {"id": int(m.group(2))}

    name = re.search(r"g_pageInfo\s*=\s*\{[^}]*name:\s*'((?:[^'\\]|\\.)*)'", html)
    if name:
        out["name"] = _unescape(name.group(1).replace("\\'", "'"))

    body = _strip(html)
    for key, pat in FACTS.items():
        mm = re.search(pat, body)
        if mm:
            out[key] = int(mm.group(1))

    #[[ Scoped to the Quick Facts table. The page links the same NPC again
    #   further down (in See also, in the reward list), and a document-wide
    #   search would pick whichever came first. ]]
    facts = body
    qf = body.find("Quick Facts")
    if qf >= 0:
        end = body.find("Wowhead", qf)
        facts = body[qf:end if end > qf else qf + 4000]

    for mm in ENDPOINT_RE.finditer(facts):
        which = "start" if mm.group(1) == "Start" else "end"
        if which not in out:
            out[which] = {LETTER[mm.group(2)]: [int(mm.group(3))]}

    #[[ The objective line is the one pfQuest shows in its tracker. It sits
    #   between the title and the Description heading, which is the only thing
    #   that reliably delimits it on this template. ]]
    text = re.sub(r"<[^>]+>", "\n", facts if False else _strip(html))
    lines = [_unescape(l) for l in text.split("\n")]
    lines = [l for l in lines if l]
    if "name" in out and out["name"] in lines:
        i = lines.index(out["name"])
        if i + 1 < len(lines) and lines[i + 1] != "Description":
            out["objective"] = lines[i + 1]
    try:
        d = lines.index("Description")
        if d + 1 < len(lines):
            out["description"] = lines[d + 1]
    except ValueError:
        pass

    return out


# ------------------------------------------------------------- npcs/objects

#[[ Every place the thing stands, as the page's own map control is told it:
#
#     myMapper.update({zone: 618,coords: [[89.06,10.89,{label:...}]]})
#
#   The zone travels WITH the coordinates rather than being a property of the
#   NPC, because one NPC can appear on several maps -- and it is the map id
#   pfQuest draws on, so taking it from anywhere else is how a pin ends up in
#   the wrong country. ]]
LOCATION_RE = re.compile(
    r"myMapper\.update\(\{zone:\s*(\d+)\s*,\s*coords:\s*(\[\[.*?\]\])\}\)",
    re.S)
COORD_RE = re.compile(r"\[\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)")


def parse_locations(html):
    """-> [(zone, x, y), ...] in page order, duplicates removed."""
    out, seen = [], {}
    for m in LOCATION_RE.finditer(html):
        zone = int(m.group(1))
        for x, y in COORD_RE.findall(m.group(2)):
            key = (zone, round(float(x), 2), round(float(y), 2))
            if key not in seen:
                seen[key] = True
                out.append(key)
    return out


def parse_npc(html, expect_type="1"):
    """-> dict, or None when the page holds no such NPC.

    An id that does not exist still returns a page, with an empty typeId --
    which is how a Turtle NPC id that Octo never had looks. Treating that as a
    nameless NPC at no coordinates would put an entry in the database that
    draws nothing and hides the fact that it is missing."""
    m = PAGEINFO_RE.search(html)
    if not m or m.group(1) != expect_type or not m.group(2):
        return None
    out = {"id": int(m.group(2))}

    name = re.search(r"g_pageInfo\s*=\s*\{[^}]*name:\s*'((?:[^'\\]|\\.)*)'",
                     html, re.S)
    if name:
        out["name"] = _unescape(name.group(1).replace("\\'", "'"))

    text = _text(html)
    lvl = re.search(r"Level\s*:\s*(\d+)", text)
    if lvl:
        out["level"] = int(lvl.group(1))

    #[[ Which faction may deal with it, in pfQuest's spelling: "A", "H" or
    #   "AH". Taken from React, not from the faction name -- "Thunder Bluff"
    #   says who it belongs to, React says who it is friendly to, and the
    #   filter cares about the latter. ]]
    react = re.search(r"React\s*:\s*([AH\s]+?)(?:Faction|Health|Class|$)", text)
    if react:
        fac = ""
        if "A" in react.group(1):
            fac = fac + "A"
        if "H" in react.group(1):
            fac = fac + "H"
        if fac:
            out["fac"] = fac

    out["locations"] = parse_locations(html)
    return out


def parse_object(html):
    return parse_npc(html, expect_type="2")


# -------------------------------------------------------------------- items

#[[ The "dropped-by" Listview, which is where a quest that starts from an item
#   gets its marker: pfQuest points at whatever drops the item, so without this
#   such a quest has a start it cannot draw. ]]
LISTVIEW_RE = re.compile(
    r"new Listview\(\{(.{0,4000}?)\}\);", re.S)
LV_ID_RE = re.compile(r"id:\s*'([\w-]+)'")
LV_DATA_RE = re.compile(r"data:\s*(\[.*)", re.S)
SOURCE_RE = re.compile(
    r"\{[^{}]*?\bpercent:\s*(\d+(?:\.\d+)?)[^{}]*?\bid:\s*(\d+)|"
    r"\{[^{}]*?\bid:\s*(\d+)[^{}]*?\bpercent:\s*(\d+(?:\.\d+)?)")


def parse_item(html):
    """-> dict with the NPCs (and objects) that yield the item."""
    m = PAGEINFO_RE.search(html)
    if not m or m.group(1) != "3" or not m.group(2):
        return None
    out = {"id": int(m.group(2)), "npc": {}, "object": {}}

    name = re.search(r"g_pageInfo\s*=\s*\{[^}]*name:\s*'((?:[^'\\]|\\.)*)'",
                     html, re.S)
    if name:
        out["name"] = _unescape(name.group(1).replace("\\'", "'"))

    for lv in LISTVIEW_RE.finditer(html):
        blk = lv.group(1)
        lid = LV_ID_RE.search(blk)
        tpl = re.search(r"template:\s*'(\w+)'", blk)
        if not lid or lid.group(1) not in ("dropped-by", "contained-in-object",
                                           "contained-in"):
            continue
        kind = "object" if tpl and tpl.group(1) == "object" else "npc"
        data = LV_DATA_RE.search(blk)
        if not data:
            continue
        for mm in SOURCE_RE.finditer(data.group(1)):
            if mm.group(2):
                sid, pct = int(mm.group(2)), float(mm.group(1))
            else:
                sid, pct = int(mm.group(3)), float(mm.group(4))
            out[kind][sid] = pct
    return out


# --------------------------------------------------------------------- plan

QUESTGAIN = os.path.normpath(os.path.join(HERE, "..", "..", "pfExtend", "questGaindb"))
CATALOG = os.path.join(QUESTGAIN, "catalog.json")
FETCH_LIST = os.path.join(QUESTGAIN, "fetch.txt")
KNOWN = os.path.join(HERE, "known_quests.txt")


def _catalog():
    quests = {}

    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("id"), int) and isinstance(o.get("name"), str):
                quests[o["id"]] = o
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(json.load(io.open(CATALOG, encoding="utf-8")))
    return quests


def _cached(kind, ident):
    return os.path.join(HTML_DIR, "probe_%s%s.html" % (kind, ident))


def _have(kind, ident):
    return os.path.exists(_cached(kind, ident))


def cmd_plan():
    if not os.path.exists(CATALOG):
        sys.exit("no catalog.json -- run: python scrape.py catalog")
    if not os.path.exists(KNOWN):
        sys.exit("no known_quests.txt -- run: lua tools/dump_known.lua "
                 "from the AddOns directory")

    known = set(int(l) for l in io.open(KNOWN) if l.strip())
    site = _catalog()

    #[[ The quests the client cannot draw. Everything else already has an
    #   entry from the vanilla database, from pfQuest-octo, or from the
    #   turtle gap-fill, and re-fetching those would be a few hundred
    #   requests to confirm what is already known. ]]
    targets = sorted(set(site) - known)

    want = []
    for qid in targets:
        if not _have("quest", qid):
            want.append(("quest", qid))

    #[[ Second and later rounds: whatever the quest pages already fetched turn
    #   out to point at. This is why one pass cannot be enough -- the ids are
    #   inside the pages. ]]
    refs = {"npc": set(), "object": set(), "item": set()}
    REV = {"U": "npc", "O": "object", "I": "item"}
    for qid in targets:
        path = _cached("quest", qid)
        if not os.path.exists(path):
            continue
        q = parse_quest(_read(path))
        if not q:
            continue
        for section in ("start", "end"):
            for letter, ids in (q.get(section) or {}).items():
                for i in ids:
                    refs[REV[letter]].add(i)

    # Third round: an item's drop sources are more NPCs.
    for iid in sorted(refs["item"]):
        path = _cached("item", iid)
        if not os.path.exists(path):
            continue
        it = parse_item(_read(path))
        if not it:
            continue
        for nid in it.get("npc", {}):
            refs["npc"].add(int(nid))
        for oid in it.get("object", {}):
            refs["object"].add(int(oid))

    for kind in ("item", "npc", "object"):
        for i in sorted(refs[kind]):
            if not _have(kind, i):
                want.append((kind, i))

    with io.open(FETCH_LIST, "w", encoding="utf-8") as f:
        for kind, i in want:
            f.write("%s=%s\n" % (kind, i))

    cached_quests = len([q for q in targets if _have("quest", q)])
    print("quests with no marker data : %d" % len(targets))
    print("  quest pages fetched      : %d" % cached_quests)
    print("  referenced npcs known    : %d (%d fetched)"
          % (len(refs["npc"]), len([i for i in refs["npc"] if _have("npc", i)])))
    print("  referenced items known   : %d (%d fetched)"
          % (len(refs["item"]), len([i for i in refs["item"] if _have("item", i)])))
    print("  referenced objects known : %d (%d fetched)"
          % (len(refs["object"]), len([i for i in refs["object"] if _have("object", i)])))
    print()
    if want:
        print("%d page(s) still to fetch -- written to fetch.txt" % len(want))
        print("next:  python scrape.py fetchlist")
        print("       then run this again (the pages just fetched name more)")
    else:
        print("nothing left to fetch.")
        print("next:  python parse_octo.py build")


# ------------------------------------------------------- moonwhisper coast

#[[ octowow.st reports Moonwhisper Coast's NPCs in WINTERSPRING map space,
#   because that is the map its data computes against. The game gives the zone
#   a map of its own, so those positions are right on one map and absent from
#   the other -- and pfQuest's minimap, which looks a zone up by its real name,
#   finds no id at all and shows nothing.
#
#   The relationship between the two maps was measured in game by the
#   MoonwhisperMap addon: three positions read on both maps at once, fitted per
#   axis. The residual came back at ~1.4e-6, i.e. exactly linear, so this is a
#   measurement rather than an approximation.
#
#     winterspring = AX * moonwhisper + BX   (and likewise for y)
#
#   Inverted below, since what we have is the Winterspring value. ]]
MW_ZONE = 5642                 # free in pfQuest's zone table; matches the
                               # quest category the site uses for the zone
MW_NAME = "Moonwhisper Coast"  # exactly what GetMapZones() calls it
PARENT_ZONE = 618              # Winterspring

MW_AX, MW_BX = 1.106478424817805, 14.61030867841207
MW_AY, MW_BY = 1.107254346377895, -35.29587145565073

#[[ pfQuest needs each zone's size in yards to place minimap nodes. Winterspring
#   is 7100.0 x 4733.33 in its own table, and one unit of the Moonwhisper map
#   spans AX units of Winterspring's, so Moonwhisper's full width is that much
#   larger. Derived rather than read from the client, which has no API for it. ]]
PARENT_SIZE = (7100.0, 4733.33)
MW_SIZE = (round(MW_AX * PARENT_SIZE[0], 2), round(MW_AY * PARENT_SIZE[1], 2))


def to_moonwhisper(x, y):
    """Winterspring map position -> Moonwhisper map position, or None when it
    falls outside Moonwhisper's map rectangle (the two overlap only partly)."""
    mx = (x - MW_BX) / MW_AX
    my = (y - MW_BY) / MW_AY
    if mx < 0 or mx > 100 or my < 0 or my > 100:
        return None
    return round(mx, 2), round(my, 2)


# -------------------------------------------------------------------- build

def _lua_str(v):
    out = v.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\r", "").replace("\n", "\\n")
    return '"' + out + '"'


def _num(v):
    f = float(v)
    return ("%d" % f) if f == int(f) else ("%g" % f)


def cmd_build(outdir=None):
    outdir = outdir or os.path.normpath(os.path.join(HERE, ".."))
    if not os.path.exists(KNOWN):
        sys.exit("no known_quests.txt -- run: lua tools/dump_known.lua")

    known = set(int(l) for l in io.open(KNOWN) if l.strip())
    site = _catalog()
    targets = sorted(set(site) - known)

    quests, units, objects, items = {}, {}, {}, {}
    names = {"quests": {}, "units": {}, "objects": {}, "items": {}}
    REV = {"U": "npc", "O": "object", "I": "item"}
    wanted = {"npc": set(), "object": set(), "item": set()}
    #[[ Only things a Moonwhisper quest points at get a Moonwhisper coordinate.
    #   The two map rectangles overlap, so converting every Winterspring NPC
    #   would scatter pins across the Moonwhisper map for creatures that are
    #   nowhere near the zone. ]]
    in_moonwhisper = {"npc": set(), "object": set(), "item": set()}

    skipped_nopage, skipped_nostart = [], []

    for qid in targets:
        path = _cached("quest", qid)
        if not os.path.exists(path):
            skipped_nopage.append(qid)
            continue
        q = parse_quest(_read(path))
        if not q:
            skipped_nopage.append(qid)
            continue

        entry = {}
        if q.get("level"):
            entry["lvl"] = q["level"]
        if q.get("reqlevel"):
            entry["min"] = q["reqlevel"]
        if q.get("racemask"):
            entry["race"] = q["racemask"]
        #[[ A class mask of 0 means "any class" on this template. pfQuest reads
        #   a present "class" field as a restriction, so writing the zero would
        #   hide the quest from every class instead of showing it to all. ]]
        if q.get("classmask"):
            entry["class"] = q["classmask"]
        is_mw = (q.get("zone") == MW_ZONE)
        for section in ("start", "end"):
            if q.get(section):
                entry[section] = q[section]
                for letter, ids in q[section].items():
                    for i in ids:
                        wanted[REV[letter]].add(i)
                        if is_mw:
                            in_moonwhisper[REV[letter]].add(i)
        if not entry.get("start") and not entry.get("end"):
            #[[ Kept anyway. Without a start or end pfQuest draws no pin, but
            #   the entry still gives the quest a name, a level and a place in
            #   the log and in pfExtend's chain browser -- which is strictly
            #   better than the quest being unknown. ]]
            skipped_nostart.append(qid)

        quests[qid] = entry
        loc = {}
        if q.get("name"):
            loc["T"] = q["name"]
        if q.get("objective"):
            loc["O"] = q["objective"]
        if q.get("description"):
            loc["D"] = q["description"]
        if loc:
            names["quests"][qid] = loc

    # Referenced pages, and the NPCs an item's drop list adds.
    for iid in sorted(wanted["item"]):
        path = _cached("item", iid)
        if not os.path.exists(path):
            continue
        it = parse_item(_read(path))
        if not it:
            continue
        row = {}
        mw_item = iid in in_moonwhisper["item"]
        if it.get("npc"):
            row["U"] = {int(k): v for k, v in it["npc"].items()}
            for k in row["U"]:
                wanted["npc"].add(int(k))
                if mw_item:
                    in_moonwhisper["npc"].add(int(k))
        if it.get("object"):
            row["O"] = {int(k): v for k, v in it["object"].items()}
            for k in row["O"]:
                wanted["object"].add(int(k))
                if mw_item:
                    in_moonwhisper["object"].add(int(k))
        if row:
            items[iid] = row
        if it.get("name"):
            names["items"][iid] = it["name"]

    for kind, store, parser in (("npc", units, parse_npc),
                                ("object", objects, parse_object)):
        for i in sorted(wanted[kind]):
            path = _cached(kind, i)
            if not os.path.exists(path):
                continue
            n = parser(_read(path))
            if not n:
                continue
            row = {}
            if n.get("locations"):
                #[[ Four values, not three. pfQuest reads a unit coordinate as
                #   "local x, y, zone, respawn = unpack(data)" and then does
                #   "respawn > 0" WITHOUT a nil check (database.lua:1039), so a
                #   three-value tuple throws inside its map node loop -- which
                #   aborts the whole pass and leaves the map with no markers at
                #   all, not merely missing mine. Every one of the 71,159
                #   coordinates in pfQuest's own unit database carries four.
                #
                #   Zero means "no respawn known", which is what its own
                #   entries use and what octowow.st does not tell us. ]]
                coords = [[x, y, z, 0] for z, x, y in n["locations"]]
                #[[ The same NPC listed twice, once per map, so a pin shows
                #   whichever of the two you happen to be looking at. pfQuest
                #   stores coordinates as a flat list and filters by the zone
                #   you are viewing, so this costs nothing anywhere else. ]]
                if i in in_moonwhisper[kind]:
                    for z, x, y in n["locations"]:
                        if z == PARENT_ZONE:
                            conv = to_moonwhisper(x, y)
                            if conv:
                                coords.append([conv[0], conv[1], MW_ZONE, 0])
                row["coords"] = coords
            if n.get("fac"):
                row["fac"] = n["fac"]
            if n.get("level"):
                row["lvl"] = n["level"]
            store[i] = row
            if n.get("name"):
                names["units" if kind == "npc" else "objects"][i] = n["name"]

    # ------------------------------------------------------------ emit
    HEADER = ("--[[ GENERATED -- do not edit by hand.\n\n"
              "     Quests on octowow.st that no published pfQuest database\n"
              "     carries, built from cached pages by tools/parse_octo.py.\n"
              "]]\n\n")

    #[[ Additive, not an assignment. db/data.lua (the turtle gap-fill) writes
    #   the same tables, and whichever of the two loads second would otherwise
    #   erase the first. ]]
    PRELUDE = (
        "pfQuestOctoExtra = pfQuestOctoExtra or {}\n"
        "pfQuestOctoExtra.%s = pfQuestOctoExtra.%s or {}\n"
        "local T = pfQuestOctoExtra.%s\n"
        'for _, k in ipairs({"quests","units","objects","items"}) do\n'
        "  T[k] = T[k] or {}\n"
        "end\n\n")

    def ser(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (int, float)):
            return _num(v)
        if isinstance(v, str):
            return _lua_str(v)
        if isinstance(v, dict):
            return "{" + ",".join(
                "[%s]=%s" % (ser(k), ser(val)) for k, val in sorted(v.items(),
                    key=lambda kv: (str(type(kv[0])), kv[0]))) + "}"
        if isinstance(v, (list, tuple)):
            return "{" + ",".join(ser(x) for x in v) + "}"
        return "nil"

    f = io.open(os.path.join(outdir, "db", "octo.lua"), "w", encoding="utf-8",
                newline="\n")
    f.write(HEADER)
    f.write(PRELUDE % ("data", "data", "data"))
    #[[ Without the name, pfQuest has no id for this map at all: GetMapID
    #   resolves a map by looking its name up here, and the minimap does the
    #   same with GetRealZoneText(). Without the size, minimap nodes have no
    #   scale to be placed at. ]]
    f.write('pfQuestOctoExtra.zones = { [%d] = %s }\n' % (MW_ZONE, _lua_str(MW_NAME)))
    f.write('pfQuestOctoExtra.minimap = { [%d] = { %s, %s } }\n'
            % (MW_ZONE, _num(MW_SIZE[0]), _num(MW_SIZE[1])))
    for kind, store in (("quests", quests), ("units", units),
                        ("objects", objects), ("items", items)):
        for i in sorted(store):
            f.write('T["%s"][%d]=%s\n' % (kind, i, ser(store[i])))
    f.close()

    g = io.open(os.path.join(outdir, "db", "octo-enUS.lua"), "w",
                encoding="utf-8", newline="\n")
    g.write(HEADER)
    g.write(PRELUDE % ("enUS", "enUS", "enUS"))
    for kind in ("quests", "units", "objects", "items"):
        for i in sorted(names[kind]):
            g.write('T["%s"][%d]=%s\n' % (kind, i, ser(names[kind][i])))
    g.close()

    mwcoords = 0
    for store in (units, objects):
        for row in store.values():
            for c in row.get("coords", []):
                if c[2] == MW_ZONE:
                    mwcoords = mwcoords + 1

    withpin = len([q for q in quests.values() if q.get("start") or q.get("end")])
    print("built db/octo.lua and db/octo-enUS.lua")
    print("  quests  : %d  (%d with a questgiver to point at)" % (len(quests), withpin))
    print("  npcs    : %d" % len(units))
    print("  objects : %d" % len(objects))
    print("  items   : %d" % len(items))
    print("  %s: zone %d registered, %d coordinate(s) converted onto its map"
          % (MW_NAME, MW_ZONE, mwcoords))
    if skipped_nopage:
        print("  %d quest(s) had no cached page -- run plan/fetchlist again"
              % len(skipped_nopage))
    if skipped_nostart:
        print("  %d quest(s) name no start or end; they get a name but no pin"
              % len(skipped_nostart))


# ----------------------------------------------------------------- selftest

def selftest():
    failures = [0]

    def check(label, got, want):
        if got != want:
            failures[0] += 1
            print("  FAIL %s:\n    got  %r\n    want %r" % (label, got, want))

    def safe(fn, *a):
        """A parser that raises is a failed check, not the end of the run --
        otherwise the first broken parser hides every check after it, and a
        crash reads as "the tool is broken" rather than "this page shape is
        not handled"."""
        try:
            return fn(*a)
        except Exception as e:
            return "raised %s: %s" % (type(e).__name__, e)

    path = os.path.join(HTML_DIR, "probe_quest42079.html")
    if not os.path.exists(path):
        sys.exit("missing sample: %s\nrun: python scrape.py probe" % path)

    q = safe(parse_quest, _read(path))
    if q is None:
        sys.exit("  FAIL parse_quest returned None for a real quest page")

    check("id", q.get("id"), 42079)
    check("name", q.get("name"), "Secrets of Moonwhisper")
    check("level", q.get("level"), 57)
    check("required level", q.get("reqlevel"), 51)
    check("race mask", q.get("racemask"), 32)
    check("class mask", q.get("classmask"), 16)
    check("zone", q.get("zone"), 5642)
    check("xp", q.get("xp"), 1800)
    # Starts from an item, ends at an NPC -- the case that breaks a parser
    # which assumes a questgiver is always a person.
    check("start", q.get("start"), {"I": [42385]})
    check("end", q.get("end"), {"U": [62976]})
    check("objective", q.get("objective"),
          "Take the Half-Burnt Journal to Mhulf Nightorn in Moonhoof "
          "Village, Moonwhisper Coast.")

    # An empty page must be refused rather than yielding a half-built quest.
    empty = os.path.join(HTML_DIR, "probe_npc48608.html")
    if os.path.exists(empty):
        check("an NPC page is not parsed as a quest", safe(parse_quest, _read(empty)), None)

    #[[ A second quest, because 42079 is the unusual one -- it starts from an
    #   item. A parser tuned to it alone would be perfectly happy and wrong
    #   about the ordinary case. ]]
    path = os.path.join(HTML_DIR, "probe_quest41973.html")
    if os.path.exists(path):
        q2 = safe(parse_quest, _read(path))
        check("41973 name", (q2 or {}).get("name"), "Contracts in Moonwhisper Coast")
        check("41973 starts at an NPC, not an item",
              (q2 or {}).get("start"), {"U": [61111]})
        check("41973 ends at a different NPC", (q2 or {}).get("end"), {"U": [63095]})
        check("41973 zone", (q2 or {}).get("zone"), 5642)
        check("41973 race mask", (q2 or {}).get("racemask"), 434)

    # ---------------------------------------------------------------- npcs
    path = os.path.join(HTML_DIR, "probe_npc62976.html")
    if not os.path.exists(path):
        sys.exit("missing sample: %s" % path)
    n = safe(parse_npc, _read(path))
    check("npc id", (n or {}).get("id"), 62976)
    check("npc name", (n or {}).get("name"), "Mhulf Nighthorn")
    check("npc level", (n or {}).get("level"), 56)
    check("npc faction", (n or {}).get("fac"), "AH")
    #[[ The whole point of the crawl. A coordinate on the wrong map draws a pin
    #   in the wrong part of the world, so the zone is checked as hard as the
    #   position: 618 is Winterspring, which pfQuest already has a map for --
    #   Moonwhisper Coast does not need one of its own. ]]
    check("npc location", (n or {}).get("locations"), [(618, 89.06, 10.89)])

    #[[ An id Octo does not have still answers with a page, and its typeId is
    #   empty. Parsing that into a nameless NPC at no coordinates would put a
    #   row in the database that draws nothing while looking present. ]]
    check("an id that does not exist is refused", safe(parse_npc, _read(empty)), None)

    # --------------------------------------------------------------- items
    path = os.path.join(HTML_DIR, "probe_item42385.html")
    if os.path.exists(path):
        it = safe(parse_item, _read(path))
        check("item id", (it or {}).get("id"), 42385)
        check("item name", (it or {}).get("name"), "Half-Burnt Scroll")
        #[[ 42079 starts from this item, so this mapping IS that quest's
        #   marker: pfQuest points at whatever drops it. Lose this and the
        #   quest is in the database with nowhere to show. ]]
        check("item drop source", (it or {}).get("npc"), {63067: 100.0})
        check("an NPC page is not parsed as an item", safe(parse_item, _read(
            os.path.join(HTML_DIR, "probe_npc62976.html"))), None)

    if failures[0]:
        print("\n%d check(s) failed" % failures[0])
        sys.exit(1)
    print("  parsers: all checks passed")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "selftest"
    if cmd == "selftest":
        selftest()
    elif cmd == "plan":
        cmd_plan()
    elif cmd == "build":
        cmd_build(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        sys.exit("unknown command: %s" % cmd)
