#!/usr/bin/env python3
"""check.py -- how a pfQuest database differs from the server.

    python check.py [--octodb DIR] [--pfquest DIR] [EXTENSION_DIR ...]

With no extension given, checks this repository's build. Each extension is
dumped the way the client merges it (dump.lua) and compared, quest by quest,
with the octodb inventory: what is missing, what the server does not have,
starts and ends that disagree, objective targets the server lists that the
database lacks, levels and masks, and quests whose start cannot draw a pin.
Positions are not compared -- the site under-reports and mis-maps spawns.
"""

import argparse
import collections
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import octodb  # noqa: E402

BUCKET = {"npc": "U", "object": "O", "item": "I"}
ROWS = ["missing", "not on the server", "start differs", "end differs",
        "objective target missing", "level differs", "required level differs",
        "race mask differs", "class mask differs", "start cannot pin",
        "no start on the map"]


def ids(part, letter):
    v = (part or {}).get(letter) or []
    return set(v.values() if isinstance(v, dict) else v)


def check(dump, inv):
    site = {int(k): v for k, v in inv["quests"].items() if v}
    quests = {int(k): v for k, v in dump["quests"]["data"].items() if isinstance(v, dict)}
    placed = {letter: {int(k) for k, v in dump[kind]["data"].items()
                       if isinstance(v, dict) and v.get("coords")}
              for letter, kind in (("U", "units"), ("O", "objects"))}
    items = dump["items"]["data"]
    c = collections.Counter()
    examples = collections.defaultdict(list)

    def drawable(start):
        if any(i in placed[l] for l in ("U", "O") for i in ids(start, l)):
            return True
        for it in ids(start, "I"):
            src = items.get(str(it)) or {}
            if any(int(i) in placed["U" if l != "O" else "O"]
                   for l in ("U", "O", "V") for i in (src.get(l) or {})):
                return True
        return False

    def hit(key, qid):
        c[key] += 1
        if len(examples[key]) < 10:
            examples[key].append(qid)

    for qid, s in site.items():
        q = quests.get(qid)
        if q is None:
            hit("missing", qid)
            continue
        for which in ("start", "end"):
            if any(i not in ids(q.get(which), BUCKET[k]) for k, i in s.get(which, [])):
                hit(which + " differs", qid)
        for o in s.get("objectives", []):
            if o["kind"] == "item" and "count" not in o:
                continue
            if o["id"] not in ids(q.get("obj"), BUCKET[o["kind"]]):
                hit("objective target missing", qid)
        if s.get("level", 0) > 0 and q.get("lvl") is not None and q["lvl"] != s["level"]:
            hit("level differs", qid)
        if s.get("reqlevel") is not None and (q.get("min") or 0) != s["reqlevel"]:
            hit("required level differs", qid)
        if s.get("racemask") is not None and (q.get("race") or 0) != s["racemask"]:
            hit("race mask differs", qid)
        if s.get("classmask") is not None and (q.get("class") or 0) != s["classmask"]:
            hit("class mask differs", qid)
        st = s.get("start", [])
        if st and st[0][0] in ("npc", "object"):
            if not any(i in placed[l] for l in ("U", "O") for i in ids(q.get("start"), l)):
                hit("start cannot pin", qid)
        # whatever the server names: can pfQuest draw a start at all? (the
        # row above skips quests whose page names no giver -- where the site
        # lacks the NPC, which is exactly where givers went missing before)
        if not drawable(q.get("start")):
            hit("no start on the map", qid)
    for qid in set(quests) - set(site):
        hit("not on the server", qid)
    return len(quests), c, examples


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("extensions", nargs="*", default=[REPO])
    ap.add_argument("--octodb", default=os.environ.get("OCTODB_DATA", octodb.DEFAULT_DATA))
    ap.add_argument("--pfquest", default=r"D:\stuff\client - Copy (2)\Interface\AddOns\pfQuest")
    ap.add_argument("--examples", action="store_true", help="list quest ids for each row")
    args = ap.parse_args()

    with open(os.path.join(args.octodb, "octodb.json"), encoding="utf-8") as f:
        inv = json.load(f)
    results = []
    for ext in args.extensions:
        p = subprocess.run(["lua", os.path.join(HERE, "dump.lua"), args.pfquest, ext],
                           capture_output=True)
        if p.returncode != 0 or p.stderr:
            sys.exit("dump of %s failed:\n%s" % (ext, p.stderr.decode(errors="replace")))
        results.append((os.path.basename(os.path.normpath(ext)),) + check(json.loads(p.stdout), inv))

    print("server: %d quests\n" % sum(1 for v in inv["quests"].values() if v))
    print("%-26s" % "" + "".join("%14s" % r[0][:13] for r in results))
    print("%-26s" % "quests in database" + "".join("%14d" % r[1] for r in results))
    for row in ROWS:
        print("%-26s" % row + "".join("%14d" % r[2][row] for r in results))
    if args.examples:
        for name, _, c, ex in results:
            print("\n%s:" % name)
            for row in ROWS:
                if ex[row]:
                    print("  %-26s %s" % (row, ", ".join(map(str, sorted(ex[row])))))


if __name__ == "__main__":
    main()
