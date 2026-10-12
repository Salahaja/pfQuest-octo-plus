"""instances.py -- which quests belong to which instance, for instances.lua.

A quest belongs to an instance when the server files it there, when its
giver or taker stands only inside, or when one of its targets -- a mob, an
object, an item that only drops inside -- exists only there. Filing alone
misses most of them: Red Silk Bandanas is filed under Westfall, Molten Core's
Thorium Brotherhood turn-ins under Searing Gorge.

Keys and attunements are listed by their last quest; the chain before it is
walked back through the prerequisites, so it follows the server's.
"""

import json
import os
import statistics

# name, kind (d dungeon / r raid), zones the server files quests under,
# zones its spawns are placed in. Turtle renumbered some: The Deadmines'
# spawns are on 5138, Zul'Farrak's on 1176, Gilneas City's on 5208.
INSTANCES = [
    ("Ragefire Chasm", "d", [2437], [2437]),
    ("Wailing Caverns", "d", [718], [718]),
    ("The Deadmines", "d", [1581], [1581, 5138]),
    ("Shadowfang Keep", "d", [209], [209]),
    ("Blackfathom Deeps", "d", [719], [719]),
    ("The Stockade", "d", [717], [717]),
    ("Gnomeregan", "d", [133, 721], [721]),
    ("Razorfen Kraul", "d", [491, 1717], [491]),
    ("Scarlet Monastery", "d", [796], [796, 5135, 5136, 5153, 5163]),
    ("Razorfen Downs", "d", [722], [722]),
    ("Uldaman", "d", [1337, 1517], [1337]),
    ("Zul'Farrak", "d", [978], [1176]),
    ("Maraudon", "d", [2100], [2100]),
    ("Sunken Temple", "d", [1417, 1477], [1477]),
    ("Blackrock Depths", "d", [1584], [1584]),
    ("Blackrock Spire", "d", [1583], [1583]),
    ("Dire Maul", "d", [2557, 2577], [2557]),
    ("Stratholme", "d", [2017], [2017]),
    ("Scholomance", "d", [2057], [2057]),
    ("Crescent Grove", "d", [5077], [5077]),
    ("Stormwind Vault", "d", [5087], [5087]),
    ("Gilneas City", "d", [5180], [5208]),
    ("Hateforge Quarry", "d", [5098], [5103]),
    ("Dragonmaw Retreat", "d", [5601], [5601]),
    ("Karazhan Crypt", "d", [], [5086]),
    ("The Black Morass", "d", [], [5204, 2366]),
    ("Zul'Gurub", "r", [19, 1977], [1977]),
    ("Molten Core", "r", [2717], [2717]),
    ("Onyxia's Lair", "r", [2159], [2159]),
    ("Blackwing Lair", "r", [2677], [2677]),
    ("Ruins of Ahn'Qiraj", "r", [3429], [3429]),
    ("Temple of Ahn'Qiraj", "r", [3428], [3428, 5147]),
    ("Naxxramas", "r", [3456], [3456, 5148]),
    ("Lower Karazhan Halls", "r", [3457, 2562], [3457]),
    ("Emerald Sanctum", "r", [], [5097]),
    ("Upper Karazhan", "r", [], [5557]),
]

# the last quest of each key or attunement; both factions' where they differ
KEYS = {
    "Blackrock Depths": [3802],              # Dark Iron Legacy: the Shadowforge Key
    "Blackrock Spire": [4743],               # Seal of Ascension: upper Spire
    "Scholomance": [5505, 5511],             # The Key to Scholomance
    "Maraudon": [7046],                      # The Scepter of Celebras
    "Molten Core": [7848, 7487],             # Attunement to the Core
    "Onyxia's Lair": [6502, 6602],           # Drakefire Amulet / Blood of the Black Dragon Champion
    "Blackwing Lair": [7761],                # Blackhand's Command
    "Naxxramas": [9121, 9122, 9123],         # The Dread Citadel
    "Lower Karazhan Halls": [40829],         # The Key to Karazhan X
}


def build(b):
    """b: a finished build.Build. -> list of instance records."""
    base = b.src["base"]
    quests = b.out["quests"]

    def merged(kind):
        out = dict(base[kind])
        out.update(b.out[kind])
        return out

    zones = {}
    for letter, kind in (("U", "units"), ("O", "objects")):
        zones[letter] = {i: {t[2] for t in r.get("coords") or []}
                         for i, r in merged(kind).items() if isinstance(r, dict)}
    items = {i: r for i, r in merged("items").items() if isinstance(r, dict)}

    def where(letter, ident):
        if letter in zones:
            return zones[letter].get(ident, set())
        z = set()
        for src in ("U", "O"):
            for i in (items.get(ident) or {}).get(src) or {}:
                z |= zones[src].get(int(i), set())
        return z

    def filed(qid):
        s = b.site[qid]
        return int((s.get("facts") or {}).get("ZoneOrSort", s.get("zone") or 0) or 0)

    def junk(qid):
        name = (b.loc["quests"].get(qid) or {}).get("T") or ""
        return name.upper().startswith(("[DEPRECATED]", "DND", "[DND]"))

    def chain(last):
        """last's prerequisites, oldest first, then last."""
        order, seen = [], set()

        def walk(q):
            if q in seen or q not in quests:
                return
            seen.add(q)
            for p in quests[q].get("pre") or []:
                walk(p)
            order.append(q)
        walk(last)
        return order

    out = []
    for name, kind, filed_in, spawns in INSTANCES:
        spawns = set(spawns)
        key = []
        for last in KEYS.get(name, []):
            key += [q for q in chain(last) if q not in key]
        member = []
        for qid, rec in quests.items():
            if junk(qid) or qid in key:
                continue
            hit = filed(qid) in filed_in
            for part in ("start", "end", "obj"):
                for letter, ids in (rec.get(part) or {}).items():
                    for ident in ids if isinstance(ids, list) else []:
                        z = where(letter, ident)
                        if z and z <= spawns:
                            hit = True
            if hit:
                member.append(qid)
        if not member and not key:
            continue
        levels = [quests[q]["lvl"] for q in member if quests[q].get("lvl")] or [0]
        out.append({"name": name, "kind": kind, "lvl": int(statistics.median(levels)),
                    "quests": sorted(member), "key": key})
        b.bump("instance quests listed", len(member))
        b.bump("instance key quests listed", len(key))
    return out


def dungeon_maps():
    """Every map that is not a continent's, from the client's own map table
    (tools/data/worldmaparea.json): its file name, which GetMapInfo() returns
    when it is open; its map id and floor (floors in row order -- Scarlet
    Monastery has four); the zone pfQuest's positions on it are filed under;
    and the instance's name. The map id is NOT a SetMapZoom continent: 2.2.0
    passed it as one and crashed the client."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "data", "worldmaparea.json"), encoding="utf-8") as f:
        rows = json.load(f)["rows"]
    out, floors = [], {}
    for r in sorted(rows, key=lambda r: (r["map"], r["id"])):
        if r["map"] in (0, 1) or r["left"] == r["right"]:
            continue
        floors[r["map"]] = floors.get(r["map"], 0) + 1
        # the instance's name, as the game's zone lists would show it
        title = next((n for n, k, f, sp in INSTANCES if r["area"] in sp), None)
        out.append({"name": r["name"], "map": r["map"], "floor": floors[r["map"]],
                    "zone": r["area"], "title": title})
    return out


def boss_spots(b):
    """Where to put a boss's hover spot on each dungeon map: on the skull the
    map's art paints for it (tools/data/dungeon_skulls.json), which can sit a
    good way from where the boss stands -- Antu'sul's is 5 map units off. A
    boss is elite or a boss by rank (not a rare), stands once on the map and
    respawns weekly; it goes to the nearest skull within 10 units, and a skull
    nobody reaches gets no spot. A map with no skulls painted (Scholomance)
    keeps the bosses where they stand, close ones sharing a spot."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "data", "dungeon_skulls.json"), encoding="utf-8") as f:
        skulls = json.load(f)["maps"]
    units = dict(b.src["base"]["units"])
    units.update(b.out["units"])
    names = dict(b.src["base"]["units_loc"])
    names.update(b.loc["units"])

    def bosses(zone):
        out = []
        for ident, u in units.items():
            if not isinstance(u, dict) or str(u.get("rnk")) not in ("1", "3"):
                continue
            here_ = [c for c in u.get("coords") or [] if c[2] == zone]
            if len(here_) == 1 and (here_[0][3] or 0) >= 86400 and names.get(ident):
                out.append({"name": names[ident], "lvl": str(u.get("lvl") or ""),
                            "x": here_[0][0], "y": here_[0][1]})
        return sorted(out, key=lambda o: o["name"])

    out = {}
    for m in dungeon_maps():
        bs = bosses(m["zone"])
        if not bs:
            continue
        spots = []
        painted = skulls.get(m["name"]) or []
        if painted:
            at = {}
            for boss in bs:
                d, k = min(((boss["x"] - x) ** 2 + (boss["y"] - y) ** 2, k) for k, (x, y) in enumerate(painted))
                if d <= 100:
                    at.setdefault(k, []).append((d, boss))
            for k in sorted(at):
                x, y = painted[k]
                group = [boss for _, boss in sorted(at[k], key=lambda t: t[0])]
                spots.append({"x": x, "y": y, "bosses": group})
            b.bump("boss spots on painted skulls", len(spots))
        else:
            for boss in bs:
                home = next((s for s in spots if (s["x"] - boss["x"]) ** 2 + (s["y"] - boss["y"]) ** 2 < 9), None)
                if home:
                    home["bosses"].append(boss)
                else:
                    spots.append({"x": boss["x"], "y": boss["y"], "bosses": [boss]})
            b.bump("boss spots where the boss stands (no skulls painted)", len(spots))
        out[m["name"]] = spots
    return out


def write(path, insts, header, spots=None):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(header)
        f.write("-- Read by instances.lua and maps.lua.\n\npfQuestOcto_Instances = {\n")
        for i in insts:
            f.write('  { name = %s, kind = "%s", lvl = %d,\n    quests = {%s},\n    key = {%s} },\n'
                    % (json.dumps(i["name"]), i["kind"], i["lvl"],
                       ",".join(map(str, i["quests"])), ",".join(map(str, i["key"]))))
        f.write("}\n\n-- the client's dungeon maps: file name, map id and floor, zone, instance\n"
                "pfQuestOcto_DungeonMaps = {\n")
        for m in dungeon_maps():
            title = ", title = %s" % json.dumps(m["title"]) if m["title"] else ""
            f.write('  { name = "%s", map = %d, floor = %d, zone = %d%s },\n'
                    % (m["name"], m["map"], m["floor"], m["zone"], title))
        f.write("}\n\n-- boss hover spots per dungeon map: x, y (0-100), names and levels\n"
                "pfQuestOcto_BossSpots = {\n")
        for name in sorted(spots or {}):
            f.write('  ["%s"] = {\n' % name)
            for s in spots[name]:
                f.write("    { x = %s, y = %s, n = {%s}, l = {%s} },\n" % (
                    s["x"], s["y"], ", ".join(json.dumps(o["name"]) for o in s["bosses"]),
                    ", ".join(json.dumps(o["lvl"]) for o in s["bosses"])))
            f.write("  },\n")
        f.write("}\n")
