# pfQuest-octo-plus

The OctoWoW quest database for [pfQuest](https://github.com/The-Kludge-Bureau/pfQuest),
checked quest by quest against the server's own database at
[octowow.st/db](https://octowow.st/db/).

One addon. It replaces `pfQuest-octo` and `pfQuest-turtle` — do not run
either alongside it.

## Install

1. Install [pfQuest](https://github.com/The-Kludge-Bureau/pfQuest) 8.0.0 or
   newer (the maintained one; Shagu's 7.x works but misses the faster name
   index this rebuilds).
2. Download this repository (**Code → Download ZIP**), unzip it, and rename
   the folder `pfQuest-octo-plus-main` to **`pfQuest-octo-plus`**.
3. Put it in `Interface\AddOns`.
4. **Disable `pfQuest-octo` and `pfQuest-turtle`** if you have either.
5. Restart WoW.

## What is in it

Every quest the server has — 6,552 of them — and nothing it does not. For
each one, the server decides who gives it and who takes it, its level and
required level, which races and classes can take it, its name, and the
objective targets its page lists. What the server's pages cannot tell, comes
from the published databases:

| source | used for |
|---|---|
| [The-Kludge-Bureau/pfQuest-turtle](https://github.com/The-Kludge-Bureau/pfQuest-turtle) | Turtle's 1.18.1 export — the client OctoWoW runs. First choice for every quest, NPC, object and item. |
| [ryanmr82/pfQuest-turtle](https://github.com/ryanmr82/pfQuest-turtle) | A fork of shagu's Turtle export, plus OctoWoW's Moonwhisper Coast auto-built by the Hydra guild from players' in-game captures (spawns, givers, turn-ins, loot) and hand fixes. |
| [paokkerkir/pfQuest-octo](https://github.com/paokkerkir/pfQuest-octo) | Hand-made objective fixes (NPCs you talk to, objects you use) the exports never extracted. |
| pfQuest itself | Everything above leaves out. |

Compared with the server (`python tools/check.py`):

| | pfQuest-octo | ryanmr82 | TKB 1.18.1 | v1 of this | **v2 (this)** |
|---|---|---|---|---|---|
| quests | 6,238 | 6,608 | 6,701 | 6,658 | **6,552** |
| server quests missing | 415 | 54 | 5 | 4 | **0** |
| quests the server does not have | 101 | 110 | 154 | 110 | **0** |
| start / end differs | 5 / 36 | 5 / 33 | 108 / 103 | 2 / 30 | **0 / 0** |
| objective targets missing | 32 | 18 | 835 | 127 | **0** |
| level / required level differs | 11 / 17 | 10 / 15 | 10 / 16 | 11 / 23 | **0 / 0** |
| race / class mask differs | 4 / 0 | 22 / 1 | 1 / 288 | 5 / 0 | **0 / 0** |
| start cannot draw a pin | 111 | 118 | 214 | 125 | **106** |
| no start on the map at all | 332 | 369 | 493 | — | **352** |

Checked 2026-10-08 against the server inventory of the same day. "Start cannot
draw a pin" counts quests whose page names a giver; "no start on the map" counts
every server quest pfQuest can draw no start for. pfQuest-octo's lower figure
is over its 6,137 server quests, and the 23 it draws that this does not are 19
`[Deprecated]` quests given a giver by hand, 2 hand-pinned to a poster, and the
AQ officers. Everything ryanmr82 draws and this does not is the 16 AQ officer
quests; its 110 quests the server lacks are unreleased raid rewards (Naxxramas
rings, Karazhan and Emerald Sanctum set pieces), Scourge Invasion turn-ins and
test or GM quests.

Holiday and profession quests are flagged the way pfQuest expects, so they
stay hidden unless you ask for them. TKB's 1.18.1 export dropped those flags.
Since 2.0.2, a quest gets its holiday flag when the other databases agree
on it: that covers the 62 Lunar Festival Elders, 36 Darkmoon Faire quests and
5 fishing-contest quests. 39 more are flagged by hand: Children's Week,
Midsummer's flame thefts, Winter Veil, Scourge Invasion, the Darkmoon decks
and fortunes, and Noblegarden. A profession requirement is restored when two
databases agree on it, which brings back 28, including the engineering
specialisations. Holiday quests show only with **Display Event & Daily
Quests** on. pfQuest cannot tell whether a holiday is running right now.

## Instance quests

`/db instances` (or `/instq`) opens a list of every dungeon and raid,
Turtle's own included, with how many of its quests this character has done.
Pick one to see:

- **Key / attunement**: the whole chain in the order it is done, for
  Onyxia, Molten Core, Blackwing Lair, upper Blackrock Spire, the Shadowforge
  Key, Scholomance, Maraudon, Naxxramas and Karazhan.
- **Quests**: everything the instance has for your race and class. A chain
  is one row with its progress (2/5) and the step to do now; click it to
  open the steps. Each step is marked *done*, *in log*, *ready*, *level*
  (too low) or *locked*, with its giver, zone and map coordinates. Clicking
  a step pins it on the map; shift-click links it.

Only steps your character can reach count: the other faction's half of a
chain does not, and quests that share a name are one step. A quest you have
done, or have in your log, counts the single-path steps before it as done
too, so a history that started late still adds up. **Query server** at the
top runs `/db query` and redraws when the answer arrives.

Clicking a quest opens the map it is on, a dungeon's own map included, and
flashes a **!** with an arrow over it for five seconds: on the quest giver, or
once the quest is in your log, on whoever you speak to or turn it in to.

**Dungeon maps.** Inside a dungeon, pfQuest now draws its pins on Turtle's
dungeon map, and hovering a boss icon names the boss. A dungeon map can't be
opened from outside the dungeon: Turtle's client crashes on it. A quest whose
targets are inside a dungeon you aren't in says so in chat and shows its giver.

A quest counts as an instance's when the server files it there, when its
giver stands inside, or when what it asks for (a mob, an object, a drop)
exists only inside. That last rule finds the ones filed elsewhere, such as Red
Silk Bandanas under Westfall or the Thorium Brotherhood's Molten Core turn-ins.
"Done" comes from pfQuest's quest history, so run `/db query` once per
character to load what the server knows you have finished.

## What it cannot fix

- **106 quests whose giver has no position anywhere.** 63 event NPCs that
  only spawn during their event (the Children's Week orphans), 21 dungeon NPCs
  the site places at 0,0 (Dire Maul), 7 givers the server does not have, and
  the 15 Ahn'Qiraj war effort officer quests — the officers are in the
  server's database but not in the world until AQ opens (2027 on OctoWoW).
  Their quests are listed; they just have no pin.
- **141 of the 255 quests that start from an item.** The other 114 start
  from a drop or a vendor item and pin whatever drops or sells it. For these
  141, neither the server nor any database knows a place: 72 starting items
  come out of another item (Sayge's fortunes, the Cenarion Circle's task
  briefings — only one of those containers drops anywhere), 22 are crafted
  or combined, 16 are rewards of an earlier quest, 13 have no source
  recorded, and the rest drop from something with no position.
- **Objectives the server's pages leave out.** Some quests complete by a
  script or an area event (Trial of the Lake's Shrine Bauble); those come
  from the exports, where they exist at all.

## Moonwhisper Coast

The 1.18.1 client's zone table calls it **5642**, as does the server.
ryanmr82's scans were recorded under a made-up 5700, and are moved onto 5642.
The site places Moonwhisper spawns on Winterspring's map; the transform onto
Moonwhisper's own, measured in game with `tools/MoonwhisperMap` (three points
on both maps at once, residual ~1.4e-6), is

```
winterspring_x = 1.106478424817805 * moonwhisper_x + 14.61030867841207
winterspring_y = 1.107254346377895 * moonwhisper_y - 35.29587145565073
```

and it reproduces TKB's official positions exactly (Mhulf Nighthorn: 67.29,
41.71). The minimap size is Winterspring's scaled by it, `{7856, 5241}`; TKB
ships those two numbers swapped, which would put every minimap node in the
wrong spot.

## Rebuilding

Needs `python3`, `lua` (5.1+), `curl` and `git`. Clone the three source
databases next to this repository (`tkb-turtle`, `ryanmr82-turtle`,
`paokkerkir-octo`), then:

```bash
python tools/octodb.py run          # inventory the server (first run ~11 h; later runs refresh what is older than a week)
python tools/build.py               # resolve everything, write db/, init/, patchtable.lua, the .toc and BUILD.md
python tools/octodb.py refs --extra ../build-cache/unverified.txt   # if build.py lists unchecked ids
lua tools/test_build.lua <pfQuest dir> ../build-cache               # load it the way the client does
lua tools/test_window.lua <pfQuest dir> ../build-cache              # drive the instance window as Alliance and as Horde
python tools/check.py               # compare it with the server
```

Or all of it in one go, on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File tools\update.ps1             # quick: new quests only, ~15 min
powershell -ExecutionPolicy Bypass -File tools\update.ps1 -Mode Full  # re-read everything older than a week
```

`update.ps1` pulls the source databases, asks the server what changed, builds,
tests, and stops at the first check that fails (`check.py --strict`). If the
database really changed, it bumps the patch version, commits, pushes and
fast-forwards the installed copy in AddOns. `-NoPush` commits only;
`-DryRun` leaves git alone. Logs go to `../update-logs`.

`octodb.py selftest` checks the page parsers against real pages in
`tools/fixtures`. `BUILD.md` records every decision the build made and the
source revisions it used.

### Why it is built this way

Version 1 missed quests, and each rule in `octodb.py` and `build.py` answers
one way it did:

1. It found quests through the site's quest **menu**, which links 107
   categories. The site files quests under every zone and subzone it has
   (Northshire Valley, Deathknell, Tel'Abim…); 182 hold quests.
2. It only fetched quests no database had, and **added** them — never
   replacing anything, so every quest pfQuest-octo had kept its 1.17.2 data.
3. It took a quest's start, end and objective **text**, but not its objective
   targets or prerequisites — so Moonwhisper's quests were listed and drew no
   objective pins.
4. It never recorded what the server **lacks**, so 110 Turtle-only quests
   shipped and could show as available.
5. Its scraper lived inside a git addon that OctoLauncher's "Update all"
   resets.
6. It was a one-off; the server adds quests every week.

Two more found while building v2: the site draws NPCs near a zone border on
the **neighbouring** zone's map (705 of 782 disagreements checked), so
positions come from the exports and only fall back to the site; and its
"React" letters are coloured per side — only the green ones mean friendly.

And one found in 2.0.1: the site's **NPC list has holes**. Moro'gai Village
and the Harborage's draenei (Magtoor, Masat T'andr and their Turtle
neighbours) come back as empty pages, so the quest pages name no giver for
their quests. An empty NPC page proves nothing on its own; a giver is dropped
only when the quest's page names someone else. 2.0.0 dropped those givers,
which cost 18 quests their start pin.

## Credits

- **[Shagu](https://github.com/shagu)** — pfQuest and pfQuest-turtle.
- **[txtsd / The-Kludge-Bureau](https://github.com/The-Kludge-Bureau)** — the
  maintained pfQuest 8 and the 1.18.1 database.
- **[paokkerkir](https://github.com/paokkerkir/pfQuest-octo)** — pfQuest-octo,
  with Gurky and contributors Antealis, HumbleKagu, KasVital, Haaxor1689,
  IcemanHHW and fatpowaranga.
- **[ryanmr82](https://github.com/ryanmr82/pfQuest-turtle)** and the Hydra
  guild — Moonwhisper Coast from in-game scans.
- The Turtle WoW team, whose database export all of this derives from, and
  the OctoWoW team, whose database is the reference.

MIT, as upstream. See `LICENSE`.
