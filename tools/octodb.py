#!/usr/bin/env python3
"""octodb -- inventory of everything on octowow.st/db that pfQuest needs.

Finds every quest the server has, then everything those quests point at
(questgivers, objective mobs, objects, items and what drops them), and keeps
it in one SQLite file. A pfQuest database is built FROM this inventory; this
script does not write Lua.

    python octodb.py run          all four stages below, resumable
    python octodb.py discover     every category: zones, subzones, sorts, custom
    python octodb.py quests       every quest page found so far
    python octodb.py sweep        quest ids one by one, for what no category lists
    python octodb.py refs         the npcs, objects and items quests point at
    python octodb.py status       what is known and what is still to fetch
    python octodb.py reparse      re-read every stored page, no network
    python octodb.py export       inventory -> octodb.json
    python octodb.py selftest     parsers against tools/fixtures, no network

Why it is built this way -- the first attempt (parse_octo.py, 2026-10-03)
fell short, and each rule below answers one way it did:

  1. It found quests by following the site's quest MENU, which links 107
     categories. The site files quests under every zone and subzone it has,
     and the menu leaves most of them out: Northshire Valley (9), Deathknell
     (154), zone 5121... Here, discovery sweeps every zone id there is, the
     custom-quest list, every quest sort, and then checks ids one by one.
  2. It only fetched quests no pfQuest database had at all, and added them
     without ever replacing anything. Every quest pfQuest-octo already had kept
     its 1.17.2 data, never compared with the server. Here, every quest on the
     server gets its own page read, whether or not anything already has it.
  3. For the quests it did build it took the start, the end and the objective
     TEXT, but no objective targets (the mobs, items and objects that pins are
     drawn on) and no prerequisites. Here, a quest page is parsed for all of
     it, and every raw Quick Facts field is kept even if nothing reads it yet.
  4. Nothing recorded which quests the server does NOT have, so 438 quests
     that exist only on Turtle shipped and could show as available. Here, an
     id is confirmed absent from its own page and stored as such -- never
     inferred from a failed request.
  5. Its scraper and cache lived inside pfExtend, a git addon that
     OctoLauncher's "Update all" resets. Here, everything lives under --data,
     outside AddOns.
  6. It was a one-off. The server adds quests (the custom list went from
     2,268 to 2,308 between Oct 3 and Oct 7), so this is incremental: pages
     older than --refresh-days are fetched again, nothing newer ever is.

No duplicates: every quest, NPC, object, item and page has exactly one row,
keyed by its id. Where a quest was found is a separate table, so finding it
through three categories is three provenance rows and still one quest.
"""

import argparse
import gzip
import html as htmllib
import json
import os
import random
import re
import sqlite3
import subprocess
import sys
import time

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

BASE = "https://octowow.st/db/"
SITE = "https://octowow.st/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_DATA = os.path.join(os.path.dirname(REPO), "octodb-data")
FIXTURES = os.path.join(HERE, "fixtures")

# page types as g_pageInfo reports them
TYPE = {"npc": "1", "object": "2", "item": "3", "quest": "5"}
LETTER = {"npc": "U", "object": "O", "item": "I"}

# Quest sorts are the negative ZoneOrSort values. Blizzard's stop near -370,
# Turtle's custom ones go past -1000 (the menu lists -1003); an empty category
# is a ~3 KB page, so the whole stretch is swept.
SORT_RANGE = range(-1, -1201, -1)
# Custom zones are added at the top of the zone table (5642, 5734...), past
# anything pfQuest's tables list (they stop at 5629), so that stretch is swept.
CUSTOM_ZONE_RANGE = range(5600, 6201)
# Quest ids are swept outright around every cluster of custom ids, this far
# past each end, to catch quests no database has heard of yet. A cluster
# needs this many known ids; a lone stray id (some databases carry a 1140820)
# is checked on its own rather than padded with 600 more requests.
ID_MARGIN = 300
CLUSTER_MIN = 5
# New quests are appended after a cluster's last id; the stretch before its
# first is only checked lightly.
ID_MARGIN_BEFORE = 50
# Below this, quest ids are Blizzard's and every database already lists the
# ones that exist; --full sweeps them anyway.
CUSTOM_ID_FLOOR = 10000


# ------------------------------------------------------------------ session

class Blocked(Exception):
    """The site stopped answering. Not a reason to keep asking."""


class Session:
    """HTTP through curl, because the site's BlazingFast front end fingerprints
    TLS and re-challenges Python's own client on every request; curl, once it
    has passed the challenge, is let through on its cookie. (Same approach as
    pfExtend's questGaindb/scrape.py, which worked this out.)"""

    def __init__(self, data, delay):
        self.cookies = os.path.join(data, "cookies.txt")
        self.delay = delay
        self.last = 0.0
        self.failures = 0
        self.requests = 0
        for cand in ("curl", "curl.exe"):
            try:
                subprocess.run([cand, "--version"], capture_output=True, check=True)
                self.curl = cand
                break
            except (OSError, subprocess.CalledProcessError):
                continue
        else:
            sys.exit("curl not found (Windows 10+ ships curl.exe; Git Bash has curl)")

    def _run(self, args):
        return subprocess.run(
            [self.curl, "-s", "--compressed", "--max-time", "40",
             "-b", self.cookies, "-c", self.cookies, "-A", UA] + args,
            capture_output=True)

    def _cleared(self):
        if not os.path.exists(self.cookies):
            return False
        with open(self.cookies, encoding="utf-8", errors="replace") as f:
            return "__bf_clearance_v2" in f.read()

    def _challenge(self, page, referer):
        chal = re.search(r'name="bf_challenge" value="([0-9a-f]{64})"', page).group(1)
        bfu = re.search(r'name="bfu" value="([^"]*)"', page).group(1)
        expr = re.search(r'bf-v2-answer"\)\.value=([^;]+)', page).group(1).strip()
        m = re.fullmatch(r"(\d+)\s*\+\s*(\d+)\s*\*\s*(\d+)", expr)
        n = re.fullmatch(r"(\d+)\s*\*\s*(\d+)\s*\+\s*(\d+)", expr)
        if m:
            answer = int(m.group(1)) + int(m.group(2)) * int(m.group(3))
        elif n:
            answer = int(n.group(1)) * int(n.group(2)) + int(n.group(3))
        else:
            raise Blocked("unrecognised challenge: %r" % expr)
        # the challenge script has to be fetched first, or the answer is
        # refused (409 challenge_asset_missing); the real page waits ~5 s
        self._run(["-e", referer, SITE + "bf.jquery.max.js?bf_challenge=" + chal,
                   "-o", os.devnull])
        time.sleep(6)
        self._run(["-e", referer, "-X", "POST", SITE + "blzgfst-shark/",
                   "--data-urlencode", "bf_challenge=" + chal,
                   "--data-urlencode", "bfu=" + bfu,
                   "--data-urlencode", "blazing_answer=%d" % answer,
                   "-o", os.devnull])
        if not self._cleared():
            raise Blocked("challenge answered but no clearance cookie came back")
        print("  [passed the BlazingFast challenge]")

    def get(self, url):
        for attempt in range(5):
            wait = self.delay + random.random() * self.delay / 2 - (time.time() - self.last)
            if wait > 0:
                time.sleep(wait)
            self.last = time.time()
            self.requests += 1
            p = self._run(["-L", "-w", "\n%{http_code}", url])
            body, _, code = p.stdout.decode("utf-8", "replace").rpartition("\n")
            if p.returncode == 0 and 'name="bf_challenge"' in body:
                self._challenge(body, url)
                continue
            if p.returncode == 0 and code == "200":
                self.failures = 0
                return body
            #[[ The site sits behind DDoS scrubbing that drops traffic for
            #   minutes at a time. Backing off and then stopping is the only
            #   polite answer; the run resumes where it left off. ]]
            self.failures += 1
            if self.failures >= 8:
                raise Blocked("the site has not answered %d times running" % self.failures)
            pause = min(300, 10 * 2 ** attempt)
            print("  [no answer (%s), retrying in %ds]" % (code or p.returncode, pause))
            time.sleep(pause)
        raise Blocked("gave up on " + url)


# ------------------------------------------------------------------ storage

SCHEMA = """
CREATE TABLE IF NOT EXISTS pages (
    kind TEXT NOT NULL, ident TEXT NOT NULL,
    fetched REAL NOT NULL, present INTEGER NOT NULL,
    PRIMARY KEY (kind, ident));
CREATE TABLE IF NOT EXISTS categories (
    cat TEXT PRIMARY KEY, rows INTEGER NOT NULL, fetched REAL NOT NULL);
CREATE TABLE IF NOT EXISTS quests (
    id INTEGER PRIMARY KEY, name TEXT, level INTEGER, reqlevel INTEGER,
    side INTEGER, xp INTEGER, zone INTEGER,
    detail TEXT);                         -- parsed page, NULL until fetched
CREATE TABLE IF NOT EXISTS quest_found (
    quest INTEGER NOT NULL, source TEXT NOT NULL,
    PRIMARY KEY (quest, source));
CREATE TABLE IF NOT EXISTS absent (
    kind TEXT NOT NULL, id INTEGER NOT NULL, checked REAL NOT NULL,
    PRIMARY KEY (kind, id));
CREATE TABLE IF NOT EXISTS npcs (id INTEGER PRIMARY KEY, detail TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS objects (id INTEGER PRIMARY KEY, detail TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, detail TEXT NOT NULL);
"""

TABLE = {"npc": "npcs", "object": "objects", "item": "items"}


class Store:
    def __init__(self, data):
        self.data = data
        os.makedirs(data, exist_ok=True)
        self.db = sqlite3.connect(os.path.join(data, "octodb.sqlite"))
        self.db.executescript(SCHEMA)

    def page_path(self, kind, ident):
        d = os.path.join(self.data, "pages", kind)
        os.makedirs(d, exist_ok=True)
        return os.path.join(d, "%s.html.gz" % ident)

    def save_page(self, kind, ident, body, present):
        with gzip.open(self.page_path(kind, ident), "wt", encoding="utf-8") as f:
            f.write(body)
        self.db.execute("INSERT OR REPLACE INTO pages VALUES (?,?,?,?)",
                        (kind, str(ident), time.time(), 1 if present else 0))

    def load_page(self, kind, ident):
        path = self.page_path(kind, ident)
        if not os.path.exists(path):
            return None
        with gzip.open(path, "rt", encoding="utf-8") as f:
            return f.read()

    def fresh(self, kind, ident, max_age):
        row = self.db.execute("SELECT fetched FROM pages WHERE kind=? AND ident=?",
                              (kind, str(ident))).fetchone()
        return row is not None and time.time() - row[0] < max_age

    def found(self, qid, source, row=None):
        self.db.execute("INSERT OR IGNORE INTO quest_found VALUES (?,?)", (qid, source))
        self.db.execute("INSERT OR IGNORE INTO quests (id) VALUES (?)", (qid,))
        self.db.execute("DELETE FROM absent WHERE kind='quest' AND id=?", (qid,))
        if row:
            self.db.execute(
                "UPDATE quests SET name=COALESCE(?,name), level=COALESCE(?,level),"
                " reqlevel=COALESCE(?,reqlevel), side=COALESCE(?,side),"
                " xp=COALESCE(?,xp), zone=COALESCE(?,zone) WHERE id=?",
                (row.get("name"), row.get("level"), row.get("reqlevel"),
                 row.get("side"), row.get("xp"), row.get("category"), qid))

    def mark_absent(self, kind, ident):
        self.db.execute("INSERT OR REPLACE INTO absent VALUES (?,?,?)",
                        (kind, int(ident), time.time()))
        if kind == "quest":
            # a page that used to exist and no longer does: the quest is gone
            self.db.execute("DELETE FROM quest_found WHERE quest=?", (int(ident),))
            self.db.execute("DELETE FROM quests WHERE id=?", (int(ident),))
        else:
            self.db.execute("DELETE FROM %s WHERE id=?" % TABLE[kind], (int(ident),))

    def commit(self):
        self.db.commit()

    def ids(self, sql, *a):
        return [r[0] for r in self.db.execute(sql, a)]


# ------------------------------------------------------------------ parsing

PAGEINFO_RE = re.compile(r"g_pageInfo\s*=\s*\{\s*type:\s*(\d+)\s*,\s*typeId:\s*(\d*)", re.S)
NAME_RE = re.compile(r"g_pageInfo\s*=\s*\{[^}]*name:\s*'((?:[^'\\]|\\.)*)'", re.S)
INITPATH_RE = re.compile(r"g_initPath\(\[([^\]]*)\]\)")


def _text(fragment):
    t = re.sub(r"<[^>]+>", " ", fragment)
    return re.sub(r"\s+", " ", htmllib.unescape(t)).strip()


def _name(page):
    m = NAME_RE.search(page)
    return htmllib.unescape(m.group(1).replace("\\'", "'")) if m else None


def page_id(page, kind):
    """The id a page is about, or None when the site has no such thing. An id
    it does not have still returns a page -- with an empty typeId."""
    m = PAGEINFO_RE.search(page)
    if not m or m.group(1) != TYPE[kind] or not m.group(2):
        return None
    return int(m.group(2))


# --- category list pages

ROW_RE = re.compile(r"\{id:\s*'(\d+)',([^{}]*)\}")
ROW_FIELDS = {
    "name": re.compile(r"name:\s*'((?:[^'\\]|\\.)*)'"),
    "level": re.compile(r"level:\s*'(-?\d+)'"),
    "reqlevel": re.compile(r"reqlevel:\s*'?(\d+)"),
    "side": re.compile(r"side:\s*'(\d+)'"),
    "xp": re.compile(r"xp:\s*(-?\d+)"),
    "category": re.compile(r"category:\s*(-?\d+)"),
    "category2": re.compile(r"category2:\s*(-?\d+)"),
}


def parse_category(page, cat):
    """-> list of quest rows, or None when the page is not the list asked for
    (an unknown parent falls back to the global list, capped at 300)."""
    m = INITPATH_RE.search(page)
    if not m:
        return None
    path = [p.strip() for p in m.group(1).split(",")]
    want = cat.split(".")
    got = [p for p in path[2:] if p != "0"] or ["0"]
    if want[-1] not in got:
        return None
    rows = []
    for mm in ROW_RE.finditer(page):
        row = {"id": int(mm.group(1))}
        for key, pat in ROW_FIELDS.items():
            v = pat.search(mm.group(2))
            if v:
                row[key] = (htmllib.unescape(v.group(1).replace("\\'", "'"))
                            if key == "name" else int(v.group(1)))
        rows.append(row)
    return rows


# --- quest pages

LINK_RE = re.compile(r'<a href="\?(npc|object|item|quest)=(\d+)"[^>]*>(.*?)</a>(.*?)(?=</td>|</li>|<a |$)', re.S)
FACT_RE = re.compile(r"<li>\s*<div>(.*?)</div>\s*</li>", re.S)
# a label cell that cannot run on into a neighbouring cell or row -- the
# Series table's own <th>1.</th> cells sit right before the next section
SECTION_RE = re.compile(
    r"<tr>\s*<th[^>]*>((?:(?!</?t[dhr][\s>]).)*?)</th>\s*</tr>\s*<tr>\s*<td>(.*?)</td>\s*</tr>", re.S)
COUNT_RE = re.compile(r"\((\d+)\)")


def _facts(page):
    """Every Quick Facts line as label -> text, plus start/end as links."""
    qf = page.find("Quick Facts")
    if qf < 0:
        return {}, []
    end = page.find("</table>", qf)
    block = page[qf:end]
    facts, ends = {}, []
    for li in FACT_RE.findall(block):
        text = _text(li)
        link = re.search(r'\?(npc|object|item)=(\d+)', li)
        label, sep, value = text.partition(":")
        label = label.strip()
        if label in ("Start", "End") and link:
            ends.append((label.lower(), link.group(1), int(link.group(2))))
        elif sep:
            facts[label] = value.strip()
        elif text:
            facts[text] = True
    return facts, ends


def _int(facts, key):
    v = facts.get(key)
    try:
        return int(str(v).split()[0])
    except (TypeError, ValueError, IndexError):
        return None


def parse_quest(page):
    qid = page_id(page, "quest")
    if qid is None:
        return None
    q = {"id": qid, "name": _name(page)}
    facts, ends = _facts(page)
    q["facts"] = facts
    for key, label in (("level", "Level"), ("reqlevel", "Requires level"),
                       ("racemask", "Race Mask"), ("classmask", "Class Mask"),
                       ("zone", "ZoneOrSort"), ("xp", "RewXP")):
        v = _int(facts, label)
        if v is not None:
            q[key] = v
    for which, kind, ident in ends:
        q.setdefault(which, [])
        if [kind, ident] not in q[which]:
            q[which].append([kind, ident])

    #[[ The infobox's other sections: "Series" lists the chain in order, with
    #   this quest as the one entry that is not a link; "Open Quests" and any
    #   others the template grows list related quests. Kept by label. ]]
    q["sections"] = {}
    series = re.search(r'<table class="series">(.*?)</table>', page, re.S)
    if series:
        # the chain is its own nested table, which a <td>...</td> match would
        # cut off at its first cell
        chain = []
        for cell in re.findall(r"<th>\d+\.</th>\s*<td>(.*?)</td>", series.group(1), re.S):
            link = re.search(r'\?quest=(\d+)', cell)
            chain.append(int(link.group(1)) if link else qid)
        q["sections"]["Series"] = chain
    for label, body in SECTION_RE.findall(page):
        label = _text(label)
        if not label or label in ("Quick Facts", "Series"):
            continue
        ids = [int(i) for i in re.findall(r'\?quest=(\d+)', body)]
        if ids:
            q["sections"][label] = ids

    #[[ Objectives: the iconlist between the objective text and the
    #   Description heading. Rewards use the same markup further down, which
    #   is why the search stops at Description. ]]
    text_at = page.find('<div class="text">')
    desc_at = page.find("<h3>Description", text_at if text_at >= 0 else 0)
    zone = page[text_at:desc_at] if text_at >= 0 and desc_at > text_at else ""
    objectives = []
    for tbl in re.findall(r'<table class="iconlist">(.*?)</table>', zone, re.S):
        for kind, ident, label, rest in LINK_RE.findall(tbl):
            if kind == "quest":
                continue
            entry = {"kind": kind, "id": int(ident), "name": _text(label)}
            tail = _text(rest)
            n = COUNT_RE.search(tail)
            if n:
                entry["count"] = int(n.group(1))
            if tail:
                entry["text"] = tail
            if entry not in objectives:
                objectives.append(entry)
    q["objectives"] = objectives

    # the objective sentence: after the quest's own title, before Description
    h1 = re.search(r"<h1[^>]*>.*?</h1>(.*)", zone, re.S)
    if h1:
        obj_text = _text(re.sub(r'<table class="iconlist">.*?</table>', " ", h1.group(1), flags=re.S))
        if obj_text:
            q["objective_text"] = obj_text
    for head in ("Description", "Progress", "Completion"):
        m = re.search(r"<h3>%s</h3>(.*?)(?=<h3>|<h2>|<div class=\"pad\">)" % head, page, re.S)
        if m:
            q[head.lower()] = _text(m.group(1))
    return q


# --- npc / object / item pages

MAPPER_RE = re.compile(r"myMapper\.update\(\{zone:\s*(\d+)\s*,\s*coords:\s*(\[\[.*?\]\])\}\)", re.S)
COORD_RE = re.compile(r"\[\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)")


def parse_spawned(page, kind):
    """NPC or object: name, level, reaction and every map position, the zone
    travelling WITH each position because one NPC can stand on several maps."""
    ident = page_id(page, kind)
    if ident is None:
        return None
    out = {"id": ident, "name": _name(page), "locations": []}
    seen = set()
    for m in MAPPER_RE.finditer(page):
        zone = int(m.group(1))
        for x, y in COORD_RE.findall(m.group(2)):
            key = (zone, round(float(x), 2), round(float(y), 2))
            if key not in seen:
                seen.add(key)
                out["locations"].append(list(key))
    text = _text(re.sub(r"<script.*?</script>", " ", page, flags=re.S))
    lvl = re.search(r"Level\s*:\s*(\d+)(?:\s*-\s*(\d+))?", text)
    if lvl:
        out["level"] = [int(lvl.group(1)), int(lvl.group(2) or lvl.group(1))]
    react = re.search(r"React\s*:\s*([AH\s]+?)(?:Faction|Health|Class|$)", text)
    if react:
        out["react"] = "".join(c for c in "AH" if c in react.group(1)) or None
    return out


LISTVIEW_RE = re.compile(r"new Listview\(\{(.*?)\}\);", re.S)
SOURCE_RE = re.compile(
    r"\{[^{}]*?\bid:\s*(\d+)[^{}]*?\}", re.S)
PERCENT_RE = re.compile(r"\bpercent:\s*(-?\d+(?:\.\d+)?)")


def parse_item(page):
    """Item: name, and every NPC or object it comes from, with the chance."""
    ident = page_id(page, "item")
    if ident is None:
        return None
    out = {"id": ident, "name": _name(page), "npc": {}, "object": {}}
    for lv in LISTVIEW_RE.finditer(page):
        blk = lv.group(1)
        lid = re.search(r"id:\s*'([\w-]+)'", blk)
        if not lid or lid.group(1) not in ("dropped-by", "contained-in-object",
                                           "contained-in", "pickpocketed-by",
                                           "skinned-by", "gathered-from"):
            continue
        tpl = re.search(r"template:\s*'(\w+)'", blk)
        kind = "object" if tpl and tpl.group(1) == "object" else "npc"
        data = re.search(r"data:\s*(\[.*)", blk, re.S)
        if not data:
            continue
        for m in SOURCE_RE.finditer(data.group(1)):
            pct = PERCENT_RE.search(m.group(0))
            out[kind][str(int(m.group(1)))] = float(pct.group(1)) if pct else None
    return out


# ------------------------------------------------------------------ crawler

class Crawler:
    def __init__(self, store, session, refresh_days):
        self.store = store
        self.sess = session
        self.max_age = refresh_days * 86400

    def fetch(self, kind, ident, url):
        """Stored page if fresh, else fetched and stored. -> page text."""
        if self.store.fresh(kind, ident, self.max_age):
            page = self.store.load_page(kind, ident)
            if page is not None:
                return page, False
        page = self.sess.get(url)
        self.store.save_page(kind, ident, page, True)
        return page, True

    # --- discovery

    def zone_candidates(self, pfquest_dirs):
        cats = {}
        for d in pfquest_dirs:
            for root, _, files in os.walk(d):
                for f in files:
                    if re.fullmatch(r"zones(-\w+)?\.lua", f):
                        src = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
                        for z in re.findall(r"\[(\d+)\]\s*=", src):
                            cats["0.%d" % int(z)] = "zone-table"
        for z in CUSTOM_ZONE_RANGE:
            cats.setdefault("0.%d" % z, "custom-zone-range")
        for s in SORT_RANGE:
            cats.setdefault("0.%d" % s, "sort-range")
        # zones the site's own rows and pages name
        for z in self.store.ids("SELECT DISTINCT zone FROM quests WHERE zone IS NOT NULL"):
            cats.setdefault("0.%d" % z, "seen")
        return cats

    def menu(self):
        """The quest menu's categories. A group with children is listed as its
        children ("0.<zone>", the parent half is ignored by the site); a group
        without (the custom list -44) is asked for on its own. Asking for a
        group that has children, or for a child as if it were a group, gets
        the site's global list of 300 instead -- which is how this first went
        wrong."""
        page, _ = self.fetch("menu", "locale_enus", BASE + "templates/wowhead/js/locale_enus.js")
        i = page.find("var mn_quests")
        if i < 0:
            return {}
        start = page.index("[", i)
        depth = 0
        for end in range(start, len(page)):
            depth += {"[": 1, "]": -1}.get(page[end], 0)
            if depth == 0:
                break
        body = page[start + 1:end]
        entries, depth, last = [], 0, 0
        for n, ch in enumerate(body):
            depth += {"[": 1, "]": -1}.get(ch, 0)
            if ch == "," and depth == 0:
                entries.append(body[last:n])
                last = n + 1
        entries.append(body[last:])
        cats = {}
        for e in entries:
            head = re.match(r"\s*\[\s*(-?\d+)\s*,\s*\"", e)
            if not head:
                continue
            children = re.findall(r"\[\s*(-?\d+)\s*,\s*\"[^\"]*\"\s*\]", e[head.end():])
            if children:
                for c in children:
                    cats["0.%d" % int(c)] = "menu"
            else:
                cats[str(int(head.group(1)))] = "menu"
        return cats

    def sweep_category(self, cat, source):
        page, new = self.fetch("category", cat, BASE + "?quests=" + cat)
        rows = parse_category(page, cat)
        if rows is None or ("." not in cat and len(rows) == 300):
            # not the list asked for: the site answered with its global one
            return 0, new
        for row in rows:
            self.store.found(row["id"], "category:" + cat, row)
        self.store.db.execute("INSERT OR REPLACE INTO categories VALUES (?,?,?)",
                              (cat, len(rows), time.time()))
        if len(rows) == 300:
            print("  [category %s returned exactly 300 rows -- may be capped; "
                  "the id sweep covers it]" % cat)
        return len(rows), new

    @staticmethod
    def id_spans(ids):
        """Clusters of custom quest ids worth sweeping around: [first, last]."""
        spans = []
        for i in sorted(i for i in ids if i >= CUSTOM_ID_FLOOR):
            if spans and i - spans[-1][1] <= ID_MARGIN:
                spans[-1][1] = i
                spans[-1][2] += 1
            else:
                spans.append([i, i, 1])
        return [(a, b) for a, b, n in spans if n >= CLUSTER_MIN]

    def discover(self, pfquest_dirs):
        before = len(self.store.ids("SELECT id FROM quests"))
        # 1. the custom-quest list and every top-level group the menu shows
        cats = self.menu()
        cats.setdefault("-44", "custom-list")
        # 2. every zone and sort id there is
        rounds = 0
        while True:
            rounds += 1
            todo = {c: s for c, s in self.zone_candidates(pfquest_dirs).items()}
            todo.update(cats)
            todo = {c: s for c, s in todo.items()
                    if not self.store.fresh("category", c, self.max_age)}
            if not todo:
                break
            print("discover: %d categories to read (round %d)" % (len(todo), rounds))
            for n, (cat, source) in enumerate(sorted(todo.items()), 1):
                rows, new = self.sweep_category(cat, source)
                if new and (n % 50 == 0 or rows):
                    self.store.commit()
                if new and rows:
                    print("  %-12s %5d quests  (%d/%d)" % (cat, rows, n, len(todo)))
            self.store.commit()
            cats = {}
        after_cats = len(self.store.ids("SELECT id FROM quests"))
        print("discover: %d quests from categories (%d new this run)"
              % (after_cats, after_cats - before))

    def sweep_ids(self, known_ids, full):
        """Id by id: every id any pfQuest database knows, and the custom
        clusters with a margin -- for quests no category lists."""
        have = set(self.store.ids("SELECT id FROM quests"))
        checked = set(self.store.ids("SELECT id FROM absent WHERE kind='quest'"))
        candidates = set(known_ids)
        for a, b in self.id_spans(known_ids | have):
            candidates.update(range(max(CUSTOM_ID_FLOOR, a - ID_MARGIN_BEFORE), b + ID_MARGIN + 1))
        if full:
            candidates.update(range(1, CUSTOM_ID_FLOOR))
        todo = sorted(c for c in candidates - have - checked)
        print("sweep: %d quest ids to check one by one" % len(todo))
        hits = 0
        for n, qid in enumerate(todo, 1):
            q = self.quest_page(qid)
            if q:
                hits += 1
                self.store.found(qid, "id-sweep")
                print("  quest %d exists but no category lists it: %s" % (qid, q.get("name")))
            if n % 50 == 0:
                self.store.commit()
                print("  ... %d/%d checked, %d found" % (n, len(todo), hits))
        self.store.commit()
        print("sweep: found %d quest(s) no category lists" % hits)

    # --- pages

    def quest_page(self, qid):
        page, new = self.fetch("quest", qid, BASE + "?quest=%d" % qid)
        q = parse_quest(page)
        if q is None:
            self.store.mark_absent("quest", qid)
            return None
        self.store.found(qid, "page")
        self.store.db.execute(
            "UPDATE quests SET name=?, level=?, reqlevel=?, zone=?, xp=?, detail=? WHERE id=?",
            (q.get("name"), q.get("level"), q.get("reqlevel"), q.get("zone"), q.get("xp"),
             json.dumps(q, ensure_ascii=False, sort_keys=True), qid))
        return q

    def quests(self, limit=None):
        todo = self.store.ids("SELECT id FROM quests WHERE detail IS NULL ORDER BY id")
        stale = [q for q in self.store.ids("SELECT id FROM quests WHERE detail IS NOT NULL ORDER BY id")
                 if not self.store.fresh("quest", q, self.max_age)]
        todo = (todo + stale)[:limit] if limit else todo + stale
        print("quests: %d page(s) to read" % len(todo))
        for n, qid in enumerate(todo, 1):
            self.quest_page(qid)
            if n % 50 == 0:
                self.store.commit()
                print("  ... %d/%d" % (n, len(todo)))
        self.store.commit()

    def referenced(self):
        """Every npc/object/item a quest or an item points at, not yet read."""
        want = {"npc": set(), "object": set(), "item": set()}
        for (detail,) in self.store.db.execute("SELECT detail FROM quests WHERE detail IS NOT NULL"):
            q = json.loads(detail)
            for which in ("start", "end"):
                for kind, ident in q.get(which, []):
                    want[kind].add(ident)
            for o in q.get("objectives", []):
                want[o["kind"]].add(o["id"])
        for (detail,) in self.store.db.execute("SELECT detail FROM items"):
            it = json.loads(detail)
            for kind in ("npc", "object"):
                want[kind].update(int(i) for i in it.get(kind, {}))
        for kind in want:
            done = set(self.store.ids("SELECT id FROM %s" % TABLE[kind]))
            done |= set(self.store.ids("SELECT id FROM absent WHERE kind=?", kind))
            want[kind] -= done
        return want

    def refs(self, limit=None):
        rounds = 0
        while True:
            rounds += 1
            want = self.referenced()
            total = sum(len(v) for v in want.values())
            if not total:
                break
            print("refs: round %d -- %d item(s), %d npc(s), %d object(s) to read"
                  % (rounds, len(want["item"]), len(want["npc"]), len(want["object"])))
            # items first: what drops them is the next round's npcs
            n = 0
            for kind in ("item", "npc", "object"):
                for ident in sorted(want[kind]):
                    if limit is not None and n >= limit:
                        self.store.commit()
                        return
                    self.ref_page(kind, ident)
                    n += 1
                    if n % 50 == 0:
                        self.store.commit()
                        print("  ... %d/%d" % (n, total))
            self.store.commit()

    def ref_page(self, kind, ident):
        page, _ = self.fetch(kind, ident, BASE + "?%s=%d" % (kind, ident))
        parsed = parse_item(page) if kind == "item" else parse_spawned(page, kind)
        if parsed is None:
            self.store.mark_absent(kind, ident)
            return
        self.store.db.execute("INSERT OR REPLACE INTO %s VALUES (?,?)" % TABLE[kind],
                              (ident, json.dumps(parsed, ensure_ascii=False, sort_keys=True)))


# ------------------------------------------------------------------ commands

def known_quest_ids(paths):
    """Quest ids from tsv dumps (first column) or plain id lists."""
    ids = set()
    for p in paths:
        for line in open(p, encoding="utf-8", errors="replace"):
            head = line.split("\t", 1)[0].strip()
            if head.isdigit():
                ids.add(int(head))
    return ids


def cmd_status(store):
    q = store.db.execute("SELECT COUNT(*), SUM(detail IS NOT NULL) FROM quests").fetchone()
    a = dict(store.db.execute("SELECT kind, COUNT(*) FROM absent GROUP BY kind").fetchall())
    c = store.db.execute("SELECT COUNT(*), SUM(rows > 0) FROM categories").fetchone()
    print("categories read : %d (%d with quests)" % (c[0], c[1] or 0))
    print("quests found    : %d (%d pages read)" % (q[0], q[1] or 0))
    print("ids confirmed absent: %s" % (", ".join("%s %d" % kv for kv in sorted(a.items())) or "none"))
    for kind, table in TABLE.items():
        n = store.db.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
        print("%-7s read   : %d" % (kind, n))
    src = store.db.execute(
        "SELECT CASE WHEN source LIKE 'category:%' THEN 'category' ELSE source END s,"
        " COUNT(DISTINCT quest) FROM quest_found GROUP BY s").fetchall()
    print("found through   : " + ", ".join("%s %d" % kv for kv in src))
    only_sweep = store.db.execute(
        "SELECT COUNT(*) FROM quests WHERE id NOT IN"
        " (SELECT quest FROM quest_found WHERE source LIKE 'category:%')").fetchone()[0]
    print("in no category  : %d" % only_sweep)


def cmd_reparse(store):
    """Re-read every stored page with the current parsers. No network."""
    n = 0
    for kind, ident in store.db.execute("SELECT kind, ident FROM pages").fetchall():
        page = store.load_page(kind, ident)
        if page is None:
            continue
        if kind == "quest":
            q = parse_quest(page)
            if q is None:
                store.mark_absent("quest", ident)
            else:
                store.found(int(ident), "page")
                store.db.execute(
                    "UPDATE quests SET name=?, level=?, reqlevel=?, zone=?, xp=?, detail=? WHERE id=?",
                    (q.get("name"), q.get("level"), q.get("reqlevel"), q.get("zone"), q.get("xp"),
                     json.dumps(q, ensure_ascii=False, sort_keys=True), int(ident)))
        elif kind in TABLE:
            p = parse_item(page) if kind == "item" else parse_spawned(page, kind)
            if p is None:
                store.mark_absent(kind, ident)
            else:
                store.db.execute("INSERT OR REPLACE INTO %s VALUES (?,?)" % TABLE[kind],
                                 (int(ident), json.dumps(p, ensure_ascii=False, sort_keys=True)))
        elif kind == "category":
            rows = parse_category(page, ident) or []
            for row in rows:
                store.found(row["id"], "category:" + ident, row)
        n += 1
    store.commit()
    print("reparsed %d page(s)" % n)


def cmd_export(store, out):
    inv = {"exported": time.strftime("%Y-%m-%d %H:%M:%S"),
           "quests": {}, "npcs": {}, "objects": {}, "items": {}, "absent": {}}
    for qid, detail in store.db.execute("SELECT id, detail FROM quests ORDER BY id"):
        inv["quests"][qid] = json.loads(detail) if detail else None
    for kind, table in TABLE.items():
        for ident, detail in store.db.execute("SELECT id, detail FROM %s ORDER BY id" % table):
            inv[table][ident] = json.loads(detail)
    for kind, ident in store.db.execute("SELECT kind, id FROM absent ORDER BY kind, id"):
        inv["absent"].setdefault(kind, []).append(ident)
    for qid, source in store.db.execute("SELECT quest, source FROM quest_found ORDER BY quest"):
        if inv["quests"].get(qid) is not None:
            inv["quests"][qid].setdefault("found", []).append(source)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(inv, f, ensure_ascii=False, indent=1, sort_keys=True)
    print("wrote %s: %d quests, %d npcs, %d objects, %d items"
          % (out, len(inv["quests"]), len(inv["npcs"]), len(inv["objects"]), len(inv["items"])))


def selftest():
    fails = []

    def check(label, got, want):
        if got != want:
            fails.append(label)
            print("  FAIL %s\n    got  %r\n    want %r" % (label, got, want))

    def fx(name):
        path = os.path.join(FIXTURES, name)
        with (gzip.open(path, "rt", encoding="utf-8") if path.endswith(".gz")
              else open(path, encoding="utf-8")) as f:
            return f.read()

    q = parse_quest(fx("quest_7.html.gz"))
    check("quest 7 id", q and q["id"], 7)
    check("quest 7 name", q and q["name"], "Kobold Camp Cleanup")
    check("quest 7 zone (a subzone the menu never lists)", q and q.get("zone"), 9)
    check("quest 7 start", q and q.get("start"), [["npc", 197]])
    check("quest 7 end", q and q.get("end"), [["npc", 197]])
    check("quest 7 race mask", q and q.get("racemask"), 589)
    check("quest 7 objective target", q and [(o["kind"], o["id"], o.get("count")) for o in q["objectives"]],
          [("npc", 6, 10)])
    check("quest 7 chain", q and q["sections"].get("Series", [None])[:2], [783, 7])
    check("quest 7 opens", q and q["sections"].get("Open Quests", [None])[:2], [15, 3100])
    check("quest 7 section labels", q and sorted(q["sections"]), ["Open Quests", "Series"])
    check("quest 7 objective sentence", q and q.get("objective_text", "")[:21], "Kill 10 Kobold Vermin")

    q = parse_quest(fx("quest_2.html.gz"))
    check("quest 2 starts from an item", q and q.get("start"), [["item", 16305]])
    check("quest 2 ends at an npc", q and q.get("end"), [["npc", 12696]])

    q = parse_quest(fx("quest_28.html.gz"))
    check("quest 28 class mask", q and q.get("classmask"), 1024)
    check("quest 28 sort (negative ZoneOrSort)", q and q.get("zone"), -263)
    check("quest 28 chain position", q and q["sections"].get("Series"), [27, 28, 30, 31])

    check("an id the site lacks is absent, not an empty quest",
          parse_quest(fx("quest_absent.html.gz")), None)

    rows = parse_category(fx("category_0.9.html.gz"), "0.9")
    check("category 9 lists quest 7", rows is not None and 7 in [r["id"] for r in rows], True)
    check("category 9 row count", rows and len(rows), 13)
    check("category 9 rows carry their zone", rows and {r.get("category") for r in rows} >= {9}, True)
    check("an empty category is empty, not refused",
          parse_category(fx("category_0.99999.html.gz"), "0.99999"), [])

    n = parse_spawned(fx("npc_62976.html.gz"), "npc")
    check("npc name", n and n["name"], "Mhulf Nighthorn")
    check("npc location keeps its zone", n and n["locations"], [[618, 89.06, 10.89]])
    check("npc reaction", n and n.get("react"), "AH")
    #[[ The site lists 4 Kobold Vermin where pfQuest's export has 33. Its NPC
    #   pages under-report spawns, which is why a build takes positions from
    #   the exports first and from here only for NPCs no export has. ]]
    n = parse_spawned(fx("npc_6.html.gz"), "npc")
    check("kobold vermin as the site lists them", n and [len(n["locations"]), {l[0] for l in n["locations"]}],
          [4, {12}])
    check("npc page is not an object", parse_spawned(fx("npc_6.html.gz"), "object"), None)

    it = parse_item(fx("item_42385.html.gz"))
    check("item drop source", it and it["npc"], {"63067": 100.0})

    if fails:
        sys.exit("%d check(s) failed" % len(fails))
    print("selftest: all %s checks passed" % "parser")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=["run", "discover", "quests", "sweep", "refs", "status",
                                        "reparse", "export", "selftest"])
    ap.add_argument("--data", default=os.environ.get("OCTODB_DATA", DEFAULT_DATA),
                    help="where the inventory lives (default: %(default)s)")
    ap.add_argument("--delay", type=float, default=1.2,
                    help="seconds between requests, plus up to half again at random")
    ap.add_argument("--refresh-days", type=float, default=7,
                    help="fetch a page again once it is older than this")
    ap.add_argument("--pfquest", action="append", default=[],
                    help="pfQuest or extension folder whose zone tables seed the sweep (repeatable)")
    ap.add_argument("--known", action="append", default=[],
                    help="file of quest ids some database has (tsv first column); repeatable")
    ap.add_argument("--full", action="store_true",
                    help="also check every Blizzard quest id one by one (~10k requests)")
    ap.add_argument("--limit", type=int, default=None, help="stop after this many pages")
    ap.add_argument("--out", default=None, help="export file (default: <data>/octodb.json)")
    args = ap.parse_args()

    if args.command == "selftest":
        return selftest()

    store = Store(args.data)
    if args.command == "status":
        return cmd_status(store)
    if args.command == "reparse":
        return cmd_reparse(store)
    if args.command == "export":
        return cmd_export(store, args.out or os.path.join(args.data, "octodb.json"))

    crawler = Crawler(store, Session(args.data, args.delay), args.refresh_days)
    started = time.time()
    try:
        #[[ In order of value, so a run cut short still leaves the most useful
        #   part done: what exists, then what each quest says, then the ids no
        #   category lists, then what the quests point at. ]]
        if args.command in ("run", "discover"):
            crawler.discover(args.pfquest)
        if args.command in ("run", "quests"):
            crawler.quests(args.limit)
        if args.command in ("run", "sweep"):
            crawler.sweep_ids(known_quest_ids(args.known), args.full)
        if args.command in ("run", "refs"):
            crawler.refs(args.limit)
    except Blocked as e:
        store.commit()
        print("\nstopped: %s\nEverything fetched so far is kept; run the same command "
              "again later and it carries on." % e)
        sys.exit(2)
    except KeyboardInterrupt:
        store.commit()
        print("\ninterrupted; progress kept.")
        sys.exit(130)
    finally:
        store.commit()
    print("\n%d request(s) in %.0f min" % (crawler.sess.requests, (time.time() - started) / 60))
    cmd_status(store)


if __name__ == "__main__":
    main()
