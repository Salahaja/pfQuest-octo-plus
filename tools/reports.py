#!/usr/bin/env python3
"""reports.py -- testers' in-game reports, turned into map corrections.

    python reports.py <report.txt | pfQuest-octo-plus.lua> ... [--write]

Reads what /instq report shows (pasted into a text file) or a tester's saved
variables (WTF\\Account\\<ACCOUNT>\\SavedVariables\\pfQuest-octo-plus.lua,
which keeps the marks as the same lines). For every mark -- an NPC a tester
targeted inside a dungeon, with the map and floor they stood on -- it shows
where the database puts that NPC and how far off it is.

A floor whose marked NPCs the database files under another zone is a floor
mapped to the wrong spawns; --write puts the zone they agree on into
tools/data/map_overrides.json, which the build reads. Positions are only
reported: the painted skulls (tools/data/dungeon_skulls.json) place the boss
names, and a pin's spawn data is the export's.
"""

import argparse
import collections
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OVERRIDES = os.path.join(HERE, "data", "map_overrides.json")
FINDS = os.path.join(HERE, "data", "finds.json")

# find: <zone>|<npc>|<ids>|<x>|<y>|<npc/start/end>|<quest ids>|<title>|<why>
FIND = re.compile(r'find: (-?\d+)\|([^|]*)\|([\d,]*)\|([-\d.]+)\|([-\d.]+)\|(npc|start|end)\|([\d,]*)\|([^|]*)\|([^"]*)"?,?\s*$')


def finds(paths):
    out = []
    for p in paths:
        for line in open(p, encoding="utf-8", errors="replace"):
            m = FIND.search(line)
            if not m:
                continue
            zone, name, ids, x, y, kind, qids, title, why = m.groups()
            if x == "-":
                continue
            out.append({"zone": int(zone), "name": name, "ids": [int(i) for i in ids.split(",") if i],
                        "x": float(x), "y": float(y), "kind": kind,
                        "quests": [int(q) for q in qids.split(",") if q], "title": title, "why": why})
    return out


def apply_finds(fs, write):
    """NPC positions and quest givers/turn-ins players saw; only what names one
    NPC and one quest goes in, the rest is listed to look at by hand"""
    data = {"units": {}, "start": {}, "end": {}}
    if os.path.exists(FINDS):
        with open(FINDS, encoding="utf-8") as f:
            data.update(json.load(f))
    sure, unsure = 0, []
    for k in fs:
        if len(k["ids"]) != 1:
            unsure.append(k)
            continue
        npc = str(k["ids"][0])
        u = data["units"].setdefault(npc, {"name": k["name"], "coords": []})
        spot = [k["x"], k["y"], k["zone"]]
        if not any(c[2] == spot[2] and abs(c[0] - spot[0]) < 2 and abs(c[1] - spot[1]) < 2 for c in u["coords"]):
            u["coords"].append(spot)
        if k["kind"] in ("start", "end"):
            if len(k["quests"]) != 1:
                unsure.append(k)
                continue
            lst = data[k["kind"]].setdefault(str(k["quests"][0]), [])
            if k["ids"][0] not in lst:
                lst.append(k["ids"][0])
        sure += 1
    print("\nfinds: %d usable, %d to look at by hand" % (sure, len(unsure)))
    for k in unsure:
        print("  %-24s %-6s %-30s ids %s quests %s  (%s)" % (k["name"], k["kind"], k["title"],
              k["ids"] or "-", k["quests"] or "-", k["why"]))
    if write and sure:
        data["_how"] = ("Players' finds from capture.lua via tools/reports.py: NPC positions "
                        "(x, y, zone) and quest givers/turn-ins by npc id. The build adds them.")
        with open(FINDS, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=1, sort_keys=True)
            f.write("\n")
        print("wrote %s; rebuild with build.py" % FINDS)

# mark: <map>|<our zone>|<name>|<ids>|<x>|<y>|<game c/z>|<subzone>|db <id>@<zone>:<x>,<y> ...
MARK = re.compile(r'mark: ([^|]*)\|(-?\d+)\|([^|]*)\|([\d,]*)\|([-\d.]+)\|([-\d.]+)\|([^|]*)\|([^|]*)\|db ?(.*?)"?,?\s*$')
DB = re.compile(r"(\d+)@(\d+):([-\d.]+),([-\d.]+)")


def marks(paths):
    out = []
    for p in paths:
        for line in open(p, encoding="utf-8", errors="replace"):
            m = MARK.search(line)
            if not m:
                continue
            mp, ours, name, ids, x, y, game, sub, db = m.groups()
            out.append({
                "map": mp, "ours": int(ours), "name": name,
                "ids": [int(i) for i in ids.split(",") if i],
                "x": None if x == "-" else float(x), "y": None if y == "-" else float(y),
                "game": game, "sub": sub, "src": os.path.basename(p),
                "db": [(int(i), int(z), float(a), float(b)) for i, z, a, b in DB.findall(db)],
            })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--write", action="store_true", help="put agreed floor zones into map_overrides.json")
    args = ap.parse_args()

    fs = finds(args.files)
    if fs:
        apply_finds(fs, args.write)
    ms = marks(args.files)
    if not ms:
        print("no marks found")
        return
    votes = collections.defaultdict(collections.Counter)
    for name, group in sorted(_group(ms).items()):
        print("\n%s  (our zone %s)" % (name, group[0]["ours"]))
        for k in group:
            where = ", ".join("%d on %d at %.1f,%.1f" % d for d in k["db"]) or "not in the database"
            off = ""
            same = [d for d in k["db"] if d[1] == k["ours"]]
            if same and k["x"] is not None:
                d = min(((k["x"] - a) ** 2 + (k["y"] - b) ** 2) ** .5 for _, _, a, b in same)
                off = "  %.1f map units from it" % d
            print("  %-28s at %s,%s  db: %s%s" % (k["name"], k["x"], k["y"], where, off))
            for z in {d[1] for d in k["db"]}:
                votes[name][z] += 1
    print("\nfloor zones the marks agree on:")
    agreed = {}
    for name, c in sorted(votes.items()):
        zone, n = c.most_common(1)[0]
        ours = next(k["ours"] for k in ms if k["map"] == name)
        flag = "" if zone == ours else "   <-- differs from ours (%s)" % ours
        print("  %-24s zone %s, %d of %d marks%s" % (name, zone, n, sum(c.values()), flag))
        if zone != ours and n >= 2:
            agreed[name] = zone
    if args.write and agreed:
        with open(OVERRIDES, encoding="utf-8") as f:
            data = json.load(f)
        data.setdefault("floors", {}).update(agreed)
        with open(OVERRIDES, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=1)
            f.write("\n")
        print("\nwrote %d floor(s) to %s; rebuild with build.py" % (len(agreed), OVERRIDES))
    elif agreed:
        print("\n%d floor(s) to correct; --write puts them in map_overrides.json" % len(agreed))


def _group(ms):
    g = collections.defaultdict(list)
    for k in ms:
        g[k["map"]].append(k)
    return g


if __name__ == "__main__":
    main()
