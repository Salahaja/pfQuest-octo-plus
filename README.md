# pfQuest-octo-plus

The OctoWoW quest database for [pfQuest](https://github.com/shagu/pfQuest),
with **Moonwhisper Coast** and the quests `pfQuest-octo` is missing.

One addon. You do not need `pfQuest-octo` as well — it is in here.

## Install

1. Install [pfQuest](https://github.com/shagu/pfQuest) if you have not already.
2. Download this repository (**Code → Download ZIP**).
3. Unzip it, rename the folder `pfQuest-octo-plus-main` to **`pfQuest-octo-plus`**.
4. Put it in `Interface\AddOns`.
5. **Disable `pfQuest-octo` and `pfQuest-turtle`** if you have either.
6. Restart WoW.

`/pfoe` reports what it added.

> **Do not run this alongside `pfQuest-octo` or `pfQuest-turtle`.** All three
> assign the same database tables, so whichever loads last silently wins and
> the others are discarded — nothing errors, the counts are just quietly wrong.
> The addon checks for this and tells you in chat, but it is easier to just
> disable them.

## What it adds over pfQuest-octo

| | quests |
|---|---|
| pfQuest (vanilla) | 4,433 |
| with the Octo database | 6,238 |
| **with this addon** | **6,658** |

- **103 Moonwhisper Coast quests** — in no published pfQuest database at all,
  and the zone registered as a map so pins show on it *and* on the minimap.
- **260 quests** that `pfQuest-turtle` carries and `pfQuest-octo` does not,
  with the 169 NPCs, 12 objects and 160 items they point at.
- **57 more** from other zones that nothing had, including 5641 and 5734.

Upstream [`pfQuest-octo`](https://github.com/paokkerkir/pfQuest-octo) has not
moved since **2026-05-12** and its last two commits are *"revert to 1.17.2
data"*, so none of the above is coming from there.

## Where the data comes from

The Octo database is `pfQuest-octo` as published, unmodified — `db/`,
`init/`, `overwrites.lua` and `patchtable.lua` are theirs.

The additions are built two ways:

- The 260 are lifted from `pfQuest-turtle`, which already had them with
  coordinates. Only the quests that are actually missing are taken, so Octo's
  own corrections are left alone and no Turtle-only content comes along.
- Moonwhisper Coast and the rest are built from
  [octowow.st/db](https://octowow.st/db/), the server's own database, by the
  scripts in `tools/`.

Injection is **add-only**. Anything already present came from vanilla or from
Octo's own corrections, and both are better authorities on this server than a
Turtle export, so a future `pfQuest-octo` release wins automatically.

## Moonwhisper Coast is its own map

Worth explaining, because it is the part that is not just data.

octowow.st reports Moonwhisper NPCs in **Winterspring** map space, since that
is the map its data computes against. The game gives the zone a map of its own.
So pins land correctly on Winterspring and the Moonwhisper map is blank.

**pfQuest identifies a map by name, not by number.** `pfMap:GetMapID` asks the
client what the zone is called and looks that string up in
`pfDB["zones"]["loc"]`. A name that is not in that table has no id, so nothing
can be stored against it and nothing drawn on it. The minimap does the same
lookup with `GetRealZoneText()`, and then needs the zone's size in yards to
place nodes — so registering the name alone fixes the world map and leaves the
minimap empty.

This addon registers the name under id **5642**, the zone's dimensions, and a
second coordinate per NPC in Moonwhisper's own space, so pins show on whichever
map you have open.

The conversion between the two map spaces is not in any data file. It was
measured in game, three positions read on both maps at once and fitted per
axis:

```
winterspring_x = 1.106478424817805 * moonwhisper_x + 14.61030867841207
winterspring_y = 1.107254346377895 * moonwhisper_y - 35.29587145565073
```

Residuals came back at ~1.4e-6, so the relationship is exactly linear — a
measurement, not an approximation. `tools/MoonwhisperMap` is the addon that
took it, kept here in case Octo adds another zone this way.

Only NPCs a Moonwhisper quest actually points at get a converted coordinate;
the two map rectangles overlap, so converting everything in Winterspring would
scatter pins across Moonwhisper for creatures nowhere near it.

## What it does not fix

Of the 160 quests built from octowow.st, **119 draw a pin**. The rest are a
limit of the source data, not of the addon:

- **30** have no Start or End on their page at all — mostly repeatable item
  turn-ins, which the site does not record a giver for.
- **11** name a questgiver the site has no location for: 8 ids with no page at
  all, and 3 NPCs whose pages record no spawn.

Those 41 still get a name, a level and requirements in the quest log and in
pfExtend's chain browser, which beats being unknown. They just have no pin.

## Rebuilding

Needs `lua` and `python3`. From your `AddOns` directory:

```bash
lua pfQuest-octo-plus/tools/dump_known.lua          # what pfQuest already resolves
python pfQuest-octo-plus/tools/parse_octo.py plan   # -> fetch.txt
```

Fetching is a separate program on purpose — `tools/scrape.py.patch` applies to
`pfExtend/questGaindb/scrape.py`, which owns the site session and does no
parsing, while `parse_octo.py` does all the parsing and never touches the
network. A parser bug then costs a re-parse rather than another crawl.

Alternate `plan` and `scrape.py fetchlist` until `plan` reports nothing left —
about three rounds, because the ids are *inside* the pages: a quest names its
questgiver, an item names what drops it. Then:

```bash
python pfQuest-octo-plus/tools/parse_octo.py build
lua pfQuest-octo-plus/tools/test_bundle.lua
```

### Tests

```bash
lua pfQuest-octo-plus/tools/test_bundle.lua    # the package on its own
python pfQuest-octo-plus/tools/parse_octo.py selftest   # parsers vs cached pages
```

One trap the tests exist to catch: **unit coordinates must be four values**,
`{x, y, zone, respawn}`. pfQuest does `respawn > 0` with no nil check, so a
three-value tuple throws inside the loop that builds *all* of the map's nodes
— the result is a completely blank map, which points nowhere near the cause.

The checks run on the **generated** tables rather than the merged database,
because injection is add-only: a malformed entry for a unit pfQuest already
knows never gets installed, and a check against the merged tables then reads
pfQuest's own correct entry and passes while the bug sits in the file.

## Note on locales

Only **enUS** is supported, as upstream states. `db/esES` and `db/ptBR` ship
with `pfQuest-octo` but its TOC never loads them — they are vestigial from
the Turtle export it derives from — so they are dropped here. That is 12MB
of the download that no client could have used. `ruRU` and `zhCN` are loaded
upstream and are kept.

## Credits

- **[Shagu](https://github.com/shagu)** — pfQuest itself.
- **[paokkerkir](https://github.com/paokkerkir/pfQuest-octo)** — the OctoWoW
  database extension this is built on, with Gurky and contributors Antealis,
  HumbleKagu, KasVital, Haaxor1689, IcemanHHW and fatpowaranga.
- The Turtle WoW team, whose database export the Octo data derives from.

MIT, as upstream. See `LICENSE`.
