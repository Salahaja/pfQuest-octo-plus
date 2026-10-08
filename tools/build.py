#!/usr/bin/env python3
"""build.py -- the OctoWoW pfQuest database, built from the octodb inventory.

    python build.py [--octodb DIR] [--work DIR]

Reads the server inventory (octodb.py), dumps each published pfQuest database
the way the client merges it (dump.lua), resolves every quest, NPC, object and
item, and writes db/, init/ and BUILD.md in this repository.

The server decides what it can tell us: which quests exist; who starts and
who ends each one; its level, required level, race and class masks; its name;
the objective targets its page lists; which faction an NPC is friendly to;
and where an NPC stands. Everything else comes from the published databases,
in this order of trust:

    tkb   The-Kludge-Bureau/pfQuest-turtle  Turtle's 1.18.1 export -- the
                                            client OctoWoW runs is 1.18.1
    ryan  ryanmr82/pfQuest-turtle           OctoWoW, Moonwhisper Coast from
                                            in-game scans (zone 5700 -> 5642)
    octo  paokkerkir/pfQuest-octo           OctoWoW on 1.17.2 data, with
                                            hand-made objective fixes
    base  pfQuest 8.0.0 itself

For a quest, the record that agrees with the server most is the base, with
that order breaking ties. Objectives are the union of it, the server's
targets, and every other record that agrees with the server on both start
and end -- otherwise a hand-made fix in one database (an NPC you talk to, an
object you use) is lost to a newer export that never extracted it.

Every quest on the server is written in full, so the result does not lean on
whichever pfQuest base a player has; a quest the server does not have is
written as "_", which pfQuest's merge deletes. NPCs, objects and items are
written where they differ from pfQuest's own.
"""

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import octodb  # noqa: E402

ORDER = ["tkb", "ryan", "octo", "base"]
# the sources trusted to fill a start, end or prerequisite nobody else names
FILL_SOURCES = ("tkb", "ryan")
SOURCE_DIRS = {
    "tkb": "tkb-turtle",
    "ryan": "ryanmr82-turtle",
    "octo": "paokkerkir-octo",
}
BUCKET = {"npc": "U", "object": "O", "item": "I"}

# Moonwhisper Coast. 5642 is the id the 1.18.1 client's zone table and the
# server both use; ryanmr82's scans were recorded under a made-up 5700.
MW_ZONE, MW_ALIAS, PARENT_ZONE = 5642, 5700, 618
MW_AX, MW_BX = 1.106478424817805, 14.61030867841207
MW_AY, MW_BY = 1.107254346377895, -35.29587145565073
#[[ pfQuest's minimap table is {width, height} in yards (Elwynn Forest is
#   {3470.84, 2314.62}). Moonwhisper's map spans AX times Winterspring's in
#   both directions, measured in game, so it is Winterspring's {7100.003,
#   4733.33} scaled. TKB ships {5241, 7856} -- the same numbers swapped,
#   which would place every minimap node in the wrong spot. ]]
MW_MINIMAP = (round(MW_AX * 7100.003, 1), round(MW_AY * 4733.33, 1))

# zones that share a dungeon's name but hold nothing; GetMapIDByName walks
# the name table in no fixed order and can land on one (TKB's finding)
PHANTOM_ZONES = [5600, 5098, 5550, 5132, 5138, 5139, 5140, 5150, 5161,
                 5155, 5164, 5169, 5170, 5173, 5177, 5178]

#[[ NPCs that exist in the server's database but are not standing in the
#   world yet. The Ahn'Qiraj war effort commendation officers (15761-15768)
#   belong to the AQ opening, scheduled for 2027 on OctoWoW; pfQuest-octo
#   blanks them for the same reason. Their quests stay listed, with no pin
#   pointing at an empty spot. Empty this when AQ opens. ]]
HIDE_UNITS = set(range(15761, 15769))

#[[ Translations shipped besides enUS: the two pfQuest-octo loaded. Every
#   locale file is held in memory by every client whatever its language, and
#   the 32-bit client's address space is the limit that crashes it. ]]
LOCALES = ["ruRU", "zhCN"]

VERSION = "2.0.0"
DBURL = "https://octowow.st/db/?quest="


# ------------------------------------------------------------------ inputs

def git_rev(path):
    try:
        return subprocess.run(["git", "-C", path, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def dump(work, cache, pfquest, name, ext):
    rev = git_rev(os.path.join(work, ext)) if ext else "base"
    out = os.path.join(cache, "%s-%s.json" % (name, rev))
    if not os.path.exists(out):
        args = ["lua", os.path.join(HERE, "dump.lua"), pfquest]
        if ext:
            args.append(os.path.join(work, ext))
        with open(out + ".tmp", "wb") as f:
            p = subprocess.run(args, stdout=f, stderr=subprocess.PIPE)
        if p.returncode != 0:
            sys.exit("dump of %s failed:\n%s" % (name, p.stderr.decode(errors="replace")))
        if p.stderr:
            sys.exit("dump of %s reported:\n%s" % (name, p.stderr.decode(errors="replace")))
        os.replace(out + ".tmp", out)
    with open(out, encoding="utf-8") as f:
        d = json.load(f)
    return d, rev


def intkeys(d):
    return {int(k): v for k, v in d.items()}


def norm_coords(rec):
    """Coordinates as a list of [x, y, zone, respawn] -- four values, always.
    pfQuest unpacks four and compares the fourth with no nil check, so a
    three-value tuple throws inside the loop that draws every marker."""
    c = rec.get("coords")
    if isinstance(c, dict):
        c = [c[k] for k in sorted(c, key=int)]
    out = []
    for t in c or []:
        t = list(t) + [0] * (4 - len(t))
        out.append([t[0], t[1], int(t[2]), t[3] or 0])
    return out


def load_sources(work, cache, pfquest):
    src, revs = {}, {}
    for name in ORDER:
        d, rev = dump(work, cache, pfquest, name, SOURCE_DIRS.get(name))
        revs[name] = rev
        s = {}
        for kind in ("quests", "units", "objects", "items"):
            s[kind] = intkeys(d[kind]["data"])
            s[kind + "_loc"] = intkeys(d[kind]["loc"])
        for kind in ("units", "objects"):
            for rec in s[kind].values():
                if isinstance(rec, dict) and rec.get("coords") is not None:
                    rec["coords"] = norm_coords(rec)
                    if name == "ryan":
                        for t in rec["coords"]:
                            if t[2] == MW_ALIAS:
                                t[2] = MW_ZONE
        src[name] = s
    return src, revs


# ------------------------------------------------------------------ helpers

def bucket_ids(m, letter):
    v = (m or {}).get(letter) or []
    if isinstance(v, dict):
        v = list(v.values())
    return list(v)


def site_targets(s):
    """The objective targets the server lists, as (letter, id). An item with
    no count is one the quest hands you or has you deliver, not a target."""
    out = []
    for o in s.get("objectives", []):
        if o["kind"] == "item" and "count" not in o:
            continue
        out.append((BUCKET[o["kind"]], o["id"]))
    return out


def score(rec, s):
    pts = 0
    for which in ("start", "end"):
        for kind, ident in s.get(which, []):
            if ident in bucket_ids(rec.get(which), BUCKET[kind]):
                pts += 3
    for letter, ident in site_targets(s):
        if ident in bucket_ids(rec.get("obj"), letter):
            pts += 1
    if s.get("level", 0) > 0 and rec.get("lvl") == s["level"]:
        pts += 1
    if s.get("reqlevel") is not None and (rec.get("min") or 0) == s["reqlevel"]:
        pts += 1
    if s.get("racemask") is not None and (rec.get("race") or 0) == s["racemask"]:
        pts += 1
    if s.get("classmask") is not None and (rec.get("class") or 0) == s["classmask"]:
        pts += 1
    return pts


def agrees_on_ends(rec, s):
    for which in ("start", "end"):
        for kind, ident in s.get(which, []):
            if ident not in bucket_ids(rec.get(which), BUCKET[kind]):
                return False
    return bool(s.get("start") or s.get("end"))


def site_text(t):
    if not t:
        return None
    return (t.replace("<name>", "$N").replace("<race>", "$R")
             .replace("<class>", "$C").replace("<Name>", "$N"))


class Maps:
    """The client's own map table (DBFilesClient\\WorldMapArea.dbc, saved in
    tools/data/worldmaparea.json): every map's extents in world coordinates,
    which is what converts a position from one map to another exactly. It
    confirms the in-game measurement -- Moonwhisper is 7856 x 5241 yards and
    the Winterspring transform below matches it to six digits."""

    CONTINENTS = {"Kalimdor": 1, "Azeroth": 0, "Eastern Kingdoms": 0}

    def __init__(self, path):
        with open(path, encoding="utf-8") as f:
            rows = json.load(f)["rows"]
        self.continent = {r["map"]: r for r in rows if r["area"] == 0 and r["left"] != r["right"]
                          and r["name"] in ("Kalimdor", "Azeroth")}
        self.zone = {r["area"]: r for r in rows if r["area"] and r["left"] != r["right"]}

    @staticmethod
    def to_world(r, x, y):
        return r["left"] - x / 100 * (r["left"] - r["right"]), r["top"] - y / 100 * (r["top"] - r["bottom"])

    @staticmethod
    def from_world(r, wy, wx):
        x = (r["left"] - wy) / (r["left"] - r["right"]) * 100
        y = (r["top"] - wx) / (r["top"] - r["bottom"]) * 100
        if 0 <= x <= 100 and 0 <= y <= 100:
            return round(x, 2), round(y, 2)
        return None

    def continent_to_zone(self, continent, x, y, area):
        """A whole-continent position, on zone `area`'s map; None if off it."""
        c = self.continent.get(self.CONTINENTS.get(continent))
        z = self.zone.get(area)
        if not c or not z or z["map"] != c["map"]:
            return None
        return self.from_world(z, *self.to_world(c, x, y))

    def zones_containing(self, continent, x, y, custom_only=True):
        c = self.continent.get(self.CONTINENTS.get(continent))
        if not c:
            return []
        wy, wx = self.to_world(c, x, y)
        return [a for a, z in self.zone.items()
                if z["map"] == c["map"] and (a >= 5000 or not custom_only)
                and self.from_world(z, wy, wx)]


def to_moonwhisper(x, y):
    mx, my = (x - MW_BX) / MW_AX, (y - MW_BY) / MW_AY
    if 0 <= mx <= 100 and 0 <= my <= 100:
        return round(mx, 2), round(my, 2)
    return None


def site_positions(entity, moonwhisper):
    """A site entity's positions as pfQuest coordinates, junk removed. The site
    puts Moonwhisper Coast's spawns on Winterspring's map (618); for anything
    a Moonwhisper quest uses, they are also converted onto 5642."""
    out = []
    for zone, x, y in (entity or {}).get("locations", []):
        if zone <= 0 or not (0 < x <= 100 and 0 < y <= 100):
            continue
        out.append([x, y, zone, 0])
        if moonwhisper and zone == PARENT_ZONE:
            conv = to_moonwhisper(x, y)
            if conv:
                out.append([conv[0], conv[1], MW_ZONE, 0])
    return out


# ------------------------------------------------------------------ resolve

class Build:
    def __init__(self, src, inv, maps):
        self.src = src
        self.maps = maps
        self.site = {int(k): v for k, v in inv["quests"].items() if v}
        self.site_npc = {int(k): v for k, v in inv["npcs"].items()}
        self.site_obj = {int(k): v for k, v in inv["objects"].items()}
        self.site_item = {int(k): v for k, v in inv["items"].items()}
        #[[ The server's NPC and object pages list the quests each one starts
        #   and ends. Where a quest's own page names no giver, that list is
        #   the server's word on it all the same. ]]
        self.from_npc_pages = 0
        reverse = {}
        for table, kind in ((self.site_npc, "npc"), (self.site_obj, "object")):
            for ident, e in table.items():
                for which, field in (("starts", "start"), ("ends", "end")):
                    for qid in e.get(which, []):
                        reverse.setdefault((qid, field), []).append([kind, ident])
        for (qid, field), named in reverse.items():
            s = self.site.get(qid)
            if s is not None and not s.get(field):
                s[field] = sorted(named)
                self.from_npc_pages += 1
        self.absent = set(inv["absent"].get("quest", []))
        self.absent_of = {k: set(inv["absent"].get(k, [])) for k in ("npc", "object", "item")}
        self.stats = {}
        self.out = {k: {} for k in ("quests", "units", "objects", "items")}
        self.loc = {k: {} for k in ("quests", "units", "objects", "items")}
        self.removed = []
        self.mw_entities = {"U": set(), "O": set()}

    def bump(self, key, n=1):
        self.stats[key] = self.stats.get(key, 0) + n

    # --- quests

    def quests(self):
        for qid in sorted(self.site):
            s = self.site[qid]
            cands = [(n, self.src[n]["quests"][qid]) for n in ORDER
                     if isinstance(self.src[n]["quests"].get(qid), dict)]
            if cands:
                ranked = sorted(cands, key=lambda c: (-score(c[1], s), ORDER.index(c[0])))
                name, rec = ranked[0][0], copy.deepcopy(ranked[0][1])
                self.bump("quest base: " + name)
            else:
                ranked, name, rec = [], None, {}
                self.bump("quest base: server only")

            #[[ What neither the server nor the chosen record knows, the next
            #   record that does fills in. The server names no giver for 18 of
            #   Moro'gai Village's quests and TKB's export has none either --
            #   only ryanmr82's in-game scans do, and taking TKB's record whole
            #   left those quests with nothing to pin.
            #
            #   Only from FILL_SOURCES. pfQuest-octo's givers for these gaps are
            #   almost all "[Deprecated]" quests TKB leaves giverless on
            #   purpose, and base pfQuest's prerequisites contradicted the
            #   server's quest chain where it shows one. ryanmr82's
            #   prerequisites -- TKB's own from before its 1.18.1 refresh
            #   dropped them -- matched the server's chain 161 times of 161. ]]
            chain = s.get("sections", {}).get("Series") or []
            for field in ("start", "end", "pre"):
                if rec.get(field) or (field != "pre" and s.get(field)):
                    continue
                for other, orec in ranked[1:]:
                    if other not in FILL_SOURCES or not orec.get(field):
                        continue
                    if field == "pre" and qid in chain:
                        at = chain.index(qid)
                        if at == 0 or chain[at - 1] not in orec["pre"]:
                            self.bump("pre from %s refused: the server's chain disagrees" % other)
                            continue
                    rec[field] = copy.deepcopy(orec[field])
                    self.bump("%s taken from %s (the server names none)" % (field, other))
                    break

            # the server's word on who starts and ends it -- all of what it
            # names at once, so a second entry does not replace the first
            for which in ("start", "end"):
                named = s.get(which, [])
                if any(ident not in bucket_ids(rec.get(which), BUCKET[kind])
                       for kind, ident in named):
                    self.bump("%s corrected from the server" % which)
                    rec[which] = {}
                    for kind, ident in named:
                        lst = rec[which].setdefault(BUCKET[kind], [])
                        if ident not in lst:
                            lst.append(ident)

            if s.get("level", 0) > 0 and rec.get("lvl") != s["level"]:
                if "lvl" in rec:
                    self.bump("level corrected")
                rec["lvl"] = s["level"]
            if s.get("reqlevel") is not None and (rec.get("min") or 0) != s["reqlevel"]:
                self.bump("required level corrected")
                if s["reqlevel"]:
                    rec["min"] = s["reqlevel"]
                else:
                    rec.pop("min", None)
            for field, key in (("race", "racemask"), ("class", "classmask")):
                if s.get(key) is None:
                    continue
                if (rec.get(field) or 0) != s[key]:
                    self.bump("%s mask corrected" % field)
                if s[key]:
                    rec[field] = s[key]
                else:
                    rec.pop(field, None)

            # objectives: this record, the server's targets, and any other
            # record that agrees with the server on start and end
            obj = {k: list(v) for k, v in (rec.get("obj") or {}).items()
                   if isinstance(v, list)}
            before = sum(len(v) for v in obj.values())

            def add(letter, ident, why):
                lst = obj.setdefault(letter, [])
                if ident not in lst:
                    lst.append(ident)
                    self.bump("objective added: " + why)

            for letter, ident in site_targets(s):
                add(letter, ident, "server")
            for other, orec in cands:
                if other == name or not agrees_on_ends(orec, s):
                    continue
                for letter, ids in (orec.get("obj") or {}).items():
                    for ident in (ids if isinstance(ids, list) else []):
                        add(letter, ident, other)
            if obj:
                rec["obj"] = obj
            if not cands and s.get("sections", {}).get("Series"):
                chain = s["sections"]["Series"]
                if qid in chain and chain.index(qid) > 0:
                    rec["pre"] = [chain[chain.index(qid) - 1]]
            self.out["quests"][qid] = rec

            if s.get("zone") == MW_ZONE:
                for which in ("start", "end", "obj"):
                    for letter in ("U", "O"):
                        self.mw_entities[letter].update(bucket_ids(rec.get(which), letter))

            # name and texts: the source's own, under the server's title
            loc = None
            if name and isinstance(self.src[name]["quests_loc"].get(qid), dict):
                loc = dict(self.src[name]["quests_loc"][qid])
            if not loc:
                loc = {}
                for key, field in (("O", "objective_text"), ("D", "description")):
                    t = site_text(s.get(field))
                    if t:
                        loc[key] = t
            loc["T"] = s.get("name") or loc.get("T")
            self.loc["quests"][qid] = loc

        for qid in sorted(set(self.src["base"]["quests"]) - set(self.site)):
            self.removed.append(qid)

        #[[ A reference to something the server says does not exist is a
        #   leftover from another server's data -- pfQuest-octo's hand fix for
        #   40554 names 60949-60951, the server's page 60385-60387. Only a page
        #   that came back empty counts; something never asked about is kept
        #   and listed in unverified, for octodb.py refs --extra. ]]
        # everything ryanmr82's scans place on the Moonwhisper map -- seen
        # standing there in game, whatever the quest is filed under
        self.scanned_on_moonwhisper = {
            (letter, ident)
            for letter, kind in (("U", "units"), ("O", "objects"))
            for ident, rec in self.src["ryan"][kind].items()
            if isinstance(rec, dict) and any(c[2] == MW_ZONE for c in rec.get("coords") or [])}

        known = {"U": set(self.site_npc) | set(self.absent_of["npc"]),
                 "O": set(self.site_obj) | set(self.absent_of["object"]),
                 "I": set(self.site_item) | set(self.absent_of["item"])}
        gone = {"U": set(self.absent_of["npc"]), "O": set(self.absent_of["object"]),
                "I": set(self.absent_of["item"])}
        self.unverified = {"U": set(), "O": set(), "I": set()}
        for qid, rec in self.out["quests"].items():
            #[[ What the quest's own page names stays, even when that NPC's
            #   page comes back empty -- the site's NPC list leaves some out,
            #   and the quest page is the better witness. Only what another
            #   database added is dropped. ]]
            s = self.site[qid]
            named = {(BUCKET[k], i) for which in ("start", "end") for k, i in s.get(which, [])}
            named |= set(site_targets(s))
            #[[ ...and so does what ryanmr82 scanned in game for a Moonwhisper
            #   quest. The site's NPC list lacks Moro'gai Village entirely
            #   (62850, 62851, 62920... come back empty) while those NPCs stand
            #   in the world and hand out the quests -- the site's gap, which
            #   is also why its quest pages name no giver there. ]]
            named |= self.scanned_on_moonwhisper
            for which in ("start", "end", "obj"):
                part = rec.get(which)
                if not isinstance(part, dict):
                    continue
                for letter in list(part):
                    if letter not in gone or not isinstance(part[letter], list):
                        continue
                    keep = [i for i in part[letter]
                            if i not in gone[letter] or (letter, i) in named]
                    if len(keep) != len(part[letter]):
                        self.bump("reference dropped: the server has no such %s"
                                  % {"U": "npc", "O": "object", "I": "item"}[letter],
                                  len(part[letter]) - len(keep))
                    self.unverified[letter].update(i for i in keep if i not in known[letter])
                    if keep:
                        part[letter] = keep
                    else:
                        del part[letter]
                if not part:
                    del rec[which]

    # --- npcs and objects

    def referenced(self):
        ref = {"U": set(), "O": set(), "I": set()}
        for rec in self.out["quests"].values():
            for which in ("start", "end", "obj"):
                for letter in ref:
                    ref[letter].update(bucket_ids(rec.get(which), letter))
        return ref

    def repair(self, rec, continent, kind):
        """A database position that is the site's whole-continent position
        with a zone id stuck on (TKB did this for 19 spawns -- 12 on
        Moonwhisper, the rest in Grim Reaches and Gilneas) is converted onto
        that zone's map for real, through the client's map table."""
        coords = rec.get("coords")
        if not coords:
            return rec
        fixed, changed = [], False
        for c in coords:
            raw = next((p for p in continent
                        if abs(p[1] - c[0]) < 0.15 and abs(p[2] - c[1]) < 0.15), None)
            if raw is None:
                fixed.append(c)
                continue
            changed = True
            conv = self.maps.continent_to_zone(raw[0], raw[1], raw[2], c[2])
            if conv:
                fixed.append([conv[0], conv[1], c[2], c[3]])
                self.bump("%s position converted from the continent map" % kind)
            else:
                self.bump("%s position dropped: continent position off its zone's map" % kind)
        if not changed:
            return rec
        rec = copy.deepcopy(rec)
        rec["coords"] = fixed
        return rec

    def continent_positions(self, site_e, moonwhisper):
        """The site's whole-continent positions, on every custom zone's map
        that contains them -- or only Moonwhisper's, for what a Moonwhisper
        quest uses."""
        out = []
        for continent, x, y in site_e.get("continent", []):
            zones = self.maps.zones_containing(continent, x, y)
            if moonwhisper and MW_ZONE in zones:
                zones = [MW_ZONE]
            for z in zones:
                conv = self.maps.continent_to_zone(continent, x, y, z)
                if conv:
                    out.append([conv[0], conv[1], z, 0])
        return out

    def spawned(self, kind, letter, site_table, ref):
        ids = set()
        for n in ORDER:
            ids.update(i for i, r in self.src[n][kind].items() if isinstance(r, dict))
        ids.update(i for i in ref[letter] if i in site_table)
        base = self.src["base"][kind]
        for ident in sorted(ids):
            cands = [(n, self.src[n][kind][ident]) for n in ORDER
                     if isinstance(self.src[n][kind].get(ident), dict)]
            site_e = site_table.get(ident)
            if site_e and site_e.get("continent"):
                cands = [(n, self.repair(r, site_e["continent"], kind)) for n, r in cands]
            placed = [(n, r) for n, r in cands if r.get("coords")]
            chosen = None
            #[[ Positions come from the exports whenever any has one. The
            #   site's are a last resort: it draws an NPC near a zone border on
            #   the NEIGHBOURING zone's map (Archmage Xylem on Winterspring's,
            #   not Azshara's), uses another layout for dungeon maps, and lists
            #   a fraction of the spawns. Checked on 782 quest NPCs where it
            #   disagreed with every export: 705 were the wrong map, the rest
            #   dungeon layouts and patrols -- none a real move. ]]
            if not placed and ident in ref[letter] and site_e:
                sitepos = site_positions(site_e, ident in self.mw_entities[letter])
                sitepos += self.continent_positions(site_e, ident in self.mw_entities[letter])
                if sitepos:
                    rec = copy.deepcopy((cands or [(None, {})])[0][1])
                    rec["coords"] = sitepos
                    chosen = ("server", rec)
                    self.bump("%s placed by the server (no source had a position)" % kind)
            if chosen is None:
                chosen = (placed or cands or [(None, None)])[0]
                if chosen[1] is None:
                    continue
                chosen = (chosen[0], copy.deepcopy(chosen[1]))
            name, rec = chosen
            if kind == "units" and ident in HIDE_UNITS:
                rec.pop("coords", None)
                self.bump("units hidden until their event opens")
            self.bump("%s from %s" % (kind, name))

            # the server's word on who may deal with it
            if site_e and site_e.get("react") and ident in ref[letter]:
                if rec.get("fac") != site_e["react"]:
                    rec["fac"] = site_e["react"]
                    self.bump("%s faction from the server" % kind)
            if kind == "units" and "lvl" not in rec and site_e and site_e.get("level"):
                lo, hi = site_e["level"]
                rec["lvl"] = str(lo) if lo == hi else "%d-%d" % (lo, hi)

            if base.get(ident) != rec:
                self.out[kind][ident] = rec
            # name: the chosen source's, else any source's, else the server's
            nm = None
            for n in ([name] if name in self.src else []) + ORDER:
                nm = self.src[n][kind + "_loc"].get(ident)
                if nm:
                    break
            if not nm and site_e:
                nm = site_e.get("name")
            if nm and self.src["base"][kind + "_loc"].get(ident) != nm:
                self.loc[kind][ident] = nm

    # --- items

    def items(self, ref):
        ids = set()
        for n in ORDER:
            ids.update(i for i, r in self.src[n]["items"].items() if isinstance(r, dict))
        ids.update(i for i in ref["I"] if i in self.site_item)
        base = self.src["base"]["items"]
        for ident in sorted(ids):
            cands = [(n, self.src[n]["items"][ident]) for n in ORDER
                     if isinstance(self.src[n]["items"].get(ident), dict)]
            if ident in ref["I"]:
                #[[ An item a quest asks for is drawn where it drops. Every
                #   source anyone knows is kept, the server's included: a
                #   missing source is a quest with nowhere to point, while an
                #   extra one is at worst one more marker. ]]
                rec = copy.deepcopy(cands[0][1]) if cands else {}
                for n, r in cands[1:]:
                    for letter in ("U", "O", "V"):
                        for k, v in (r.get(letter) or {}).items():
                            rec.setdefault(letter, {})
                            if k not in rec[letter]:
                                rec[letter][k] = v
                                self.bump("item source added: " + n)
                site_e = self.site_item.get(ident) or {}
                for kind, letter in (("npc", "U"), ("object", "O")):
                    for k, v in (site_e.get(kind) or {}).items():
                        rec.setdefault(letter, {})
                        if str(k) not in {str(x) for x in rec[letter]}:
                            rec[letter][str(k)] = v if v is not None else 100
                            self.bump("item source added: server")
                if not rec:
                    continue
            else:
                with_src = [(n, r) for n, r in cands if r.get("U") or r.get("O") or r.get("V") or r.get("R")]
                pick = (with_src or cands)[0]
                rec = copy.deepcopy(pick[1])
            if base.get(ident) != rec:
                self.out["items"][ident] = rec
            nm = None
            for n in ORDER:
                nm = self.src[n]["items_loc"].get(ident)
                if nm:
                    break
            if not nm:
                nm = (self.site_item.get(ident) or {}).get("name")
            if nm and self.src["base"]["items_loc"].get(ident) != nm:
                self.loc["items"][ident] = nm

    def run(self):
        self.quests()
        ref = self.referenced()
        self.items(ref)
        # an item's drop sources are npcs and objects too
        for rec in list(self.out["items"].values()):
            ref["U"].update(int(k) for k in (rec.get("U") or {}))
            ref["O"].update(int(k) for k in (rec.get("O") or {}))
        self.spawned("units", "U", self.site_npc, ref)
        self.spawned("objects", "O", self.site_obj, ref)


# ------------------------------------------------------------------ output

def lua(v, top=False):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v) if v != int(v) else str(int(v))
    if isinstance(v, str):
        return '"' + (v.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "")
                      .replace("\n", "\\n")) + '"'
    if isinstance(v, list):
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        def key(k):
            if isinstance(k, int) or re.fullmatch(r"-?\d+", str(k)):
                return "[%d]" % int(k)
            return '["%s"]' % k
        items = sorted(v.items(), key=lambda kv: (not re.fullmatch(r"-?\d+", str(kv[0])),
                                                   int(kv[0]) if re.fullmatch(r"-?\d+", str(kv[0])) else 0,
                                                   str(kv[0])))
        return "{" + ",".join("%s=%s" % (key(k), lua(x)) for k, x in items) + "}"
    if v is None:
        return "nil"
    raise TypeError(type(v))


HEADER = ("-- GENERATED by tools/build.py on %s -- do not edit by hand.\n"
          "-- Fix a source, the server inventory or the build, and rebuild.\n")


def write_table(path, table, rows, stamp):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(HEADER % stamp)
        f.write('pfDB%s = {\n' % "".join('["%s"]' % t for t in table))
        for ident in sorted(rows):
            f.write("  [%d] = %s,\n" % (ident, lua(rows[ident])))
        f.write("}\n")


def copy_file(src, dst, edit=None):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if edit:
        text = edit(text)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(text.replace("\r\n", "\n"))


def emit(b, work, revs, stamp):
    db = os.path.join(REPO, "db")
    if os.path.isdir(db):
        shutil.rmtree(db)
    extra = os.path.join(REPO, "extra")
    if os.path.isdir(extra):
        shutil.rmtree(extra)

    quests = dict(b.out["quests"])
    for qid in b.removed:
        quests[qid] = "_"
    write_table(os.path.join(db, "quests-turtle.lua"), ("quests", "data-turtle"), quests, stamp)
    for kind in ("units", "objects", "items"):
        write_table(os.path.join(db, "%s-turtle.lua" % kind), (kind, "data-turtle"), b.out[kind], stamp)
    for kind in ("quests", "units", "objects", "items"):
        write_table(os.path.join(db, "enUS", "%s-turtle.lua" % kind), (kind, "enUS-turtle"),
                    b.loc[kind], stamp)

    tkb = os.path.join(work, SOURCE_DIRS["tkb"])

    def fix_minimap(text):
        line = "  [%d] = { %s, %s }," % (MW_ZONE, MW_MINIMAP[0], MW_MINIMAP[1])
        new, n = re.subn(r"^\s*\[%d\]\s*=\s*\{[^}]*\},?\s*$" % MW_ZONE, line, text, flags=re.M)
        if n == 0:
            new = re.sub(r"\n\}\s*$", "\n%s\n}\n" % line, text)
        return new

    def drop_phantoms(text):
        for z in PHANTOM_ZONES:
            text = re.sub(r"^\s*\[%d\]\s*=.*\n" % z, "", text, flags=re.M)
        return text

    copy_file(os.path.join(tkb, "db", "minimap-turtle.lua"), os.path.join(db, "minimap-turtle.lua"), fix_minimap)
    copy_file(os.path.join(tkb, "db", "zones-turtle.lua"), os.path.join(db, "zones-turtle.lua"), drop_phantoms)
    for f in ("meta-turtle.lua", "refloot-turtle.lua", "areatrigger-turtle.lua",
              "quests-itemreq-turtle.lua", "patches-turtle.lua"):
        copy_file(os.path.join(tkb, "db", f), os.path.join(db, f))
    for f in ("zones-turtle.lua", "professions-turtle.lua"):
        copy_file(os.path.join(tkb, "db", "enUS", f), os.path.join(db, "enUS", f),
                  drop_phantoms if f.startswith("zones") else None)
    locale_files = {}
    for loc in LOCALES:
        d = os.path.join(tkb, "db", loc)
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            copy_file(os.path.join(d, f), os.path.join(db, loc, f),
                      drop_phantoms if f.startswith("zones") else None)
            locale_files.setdefault(loc, []).append(f)

    write_patchtable(tkb, revs["tkb"], stamp)

    init = os.path.join(REPO, "init")
    if os.path.isdir(init):
        shutil.rmtree(init)
    os.makedirs(init)
    data_files = ["items", "units", "objects", "refloot", "quests-itemreq", "quests",
                  "patches", "zones", "minimap", "areatrigger", "meta"]
    with open(os.path.join(init, "data-turtle.xml"), "w", encoding="utf-8", newline="\n") as f:
        f.write('<Ui xmlns="http://www.blizzard.com/wow/ui/">\n')
        for n in data_files:
            f.write('  <Include file="..\\db\\%s-turtle.lua"/>\n' % n)
        f.write("</Ui>\n")
    for loc, files in [("enUS", ["items-turtle.lua", "units-turtle.lua", "objects-turtle.lua",
                                 "quests-turtle.lua", "zones-turtle.lua", "professions-turtle.lua"])] + \
            sorted(locale_files.items()):
        with open(os.path.join(init, "%s-turtle.xml" % loc), "w", encoding="utf-8", newline="\n") as f:
            f.write('<Ui xmlns="http://www.blizzard.com/wow/ui/">\n')
            for n in files:
                f.write('  <Include file="..\\db\\%s\\%s"/>\n' % (loc, n))
            f.write("</Ui>\n")
    locales = ["enUS"] + sorted(locale_files)
    write_toc(locales)
    return locales


def write_patchtable(tkb, rev, stamp):
    """TKB's patchtable.lua -- the merge, the quest-chain tooltips, the cache
    reset when the quest count changes -- with two edits. Each must match
    exactly once; if TKB rewrites those lines the build stops rather than
    shipping a merge that half-applies."""
    with open(os.path.join(tkb, "patchtable.lua"), encoding="utf-8") as f:
        text = f.read().replace("\r\n", "\n")

    def once(pattern, repl, what):
        nonlocal text
        text, n = re.subn(pattern, repl, text, flags=re.M)
        if n != 1:
            sys.exit("patchtable.lua: expected one %s, found %d" % (what, n))

    once(r'^pfQuest\.dburl = "[^"]*"$', 'pfQuest.dburl = "%s"' % DBURL, "dburl line")
    once(r"^pfDatabase:Reload\(\)$",
         "pfDatabase:Reload()\n\n"
         "-- pfQuest 8 indexes names when it loads, before this merge, and again\n"
         "-- only once its locale check finishes; without this, objectives on\n"
         "-- anything new are unmatched until then. Older pfQuest has no index.\n"
         "if pfDatabase.BuildNameIndex then pfDatabase:BuildNameIndex() end\n"
         "if pfDatabase.BuildStaticRejectSet then pfDatabase:BuildStaticRejectSet() end",
         "pfDatabase:Reload() line")
    with open(os.path.join(REPO, "patchtable.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("-- GENERATED by tools/build.py on %s from The-Kludge-Bureau/pfQuest-turtle\n"
                "-- patchtable.lua at %s: database links point at octowow.st, and the\n"
                "-- name index is rebuilt after the merge. Do not edit by hand.\n\n" % (stamp, rev))
        f.write(text)


def write_toc(locales):
    with open(os.path.join(REPO, "pfQuest-octo-plus.toc"), "w", encoding="utf-8", newline="\n") as f:
        f.write("## Interface: 11200\n"
                "## Title: |cff33ffccpf|cffffffffQuest |cffcccccc[Octo DB+]\n"
                "## Author: Shagu, Gurky, txtsd, paokkerkir, ryanmr82; built by Salahaja\n"
                "## Notes: The OctoWoW quest database for pfQuest, checked against the "
                "server's own. Replaces pfQuest-octo and pfQuest-turtle - do not run them alongside.\n"
                "## Version: %s\n"
                "## Dependencies: pfQuest\n"
                "## SavedVariables: pfQuest_turtlecount\n\n" % VERSION)
        for loc in ["data"] + locales:
            f.write("init\\%s-turtle.xml\n" % loc)
        f.write("\npatchtable.lua\n")


def report(b, revs, stamp, inv_stamp):
    lines = ["# Build report", "",
             "Built %s from the server inventory exported %s." % (stamp, inv_stamp), "",
             "| source | revision |", "|---|---|"]
    for n in ORDER:
        lines.append("| %s | `%s` |" % (n, revs[n]))
    lines += ["", "| | count |", "|---|---|",
              "| quests on the server | %d |" % len(b.site),
              "| quests written | %d |" % len(b.out["quests"]),
              "| quests removed (not on the server) | %d |" % len(b.removed),
              "| npcs written | %d |" % len(b.out["units"]),
              "| objects written | %d |" % len(b.out["objects"]),
              "| items written | %d |" % len(b.out["items"]), ""]
    lines += ["| decision | count |", "|---|---|"]
    for k in sorted(b.stats):
        lines.append("| %s | %d |" % (k, b.stats[k]))
    with open(os.path.join(REPO, "BUILD.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--octodb", default=os.environ.get("OCTODB_DATA", octodb.DEFAULT_DATA))
    ap.add_argument("--work", default=os.path.dirname(REPO),
                    help="folder holding the source clones (default: %(default)s)")
    ap.add_argument("--pfquest", default=r"D:\stuff\client - Copy (2)\Interface\AddOns\pfQuest",
                    help="pfQuest 8.0.0 folder (the base database)")
    args = ap.parse_args()

    inv_path = os.path.join(args.octodb, "octodb.json")
    store = octodb.Store(args.octodb)
    octodb.cmd_export(store, inv_path)
    with open(inv_path, encoding="utf-8") as f:
        inv = json.load(f)

    cache = os.path.join(args.work, "build-cache")
    os.makedirs(cache, exist_ok=True)
    src, revs = load_sources(args.work, cache, args.pfquest)
    stamp = time.strftime("%Y-%m-%d %H:%M")
    b = Build(src, inv, Maps(os.path.join(HERE, "data", "worldmaparea.json")))
    b.bump("quest starts/ends taken from the server's npc and object pages", b.from_npc_pages)
    b.run()
    emit(b, args.work, revs, stamp)
    # what tools/test_build.lua checks the merged result against
    with open(os.path.join(cache, "expected-quests.txt"), "w") as f:
        f.write("\n".join(str(q) for q in sorted(b.out["quests"])) + "\n")
    with open(os.path.join(cache, "removed-quests.txt"), "w") as f:
        f.write("\n".join(str(q) for q in b.removed) + "\n")
    names = {"U": "npc", "O": "object", "I": "item"}
    pending = ["%s=%d" % (names[l], i) for l in "UOI" for i in sorted(b.unverified[l])]
    with open(os.path.join(cache, "unverified.txt"), "w") as f:
        f.write("\n".join(pending) + ("\n" if pending else ""))
    if pending:
        print("\n%d referenced id(s) the server was never asked about; to check them:\n"
              "  python tools/octodb.py refs --extra %s\nthen build again."
              % (len(pending), os.path.join(cache, "unverified.txt")))
    report(b, revs, stamp, inv["exported"])


if __name__ == "__main__":
    main()
