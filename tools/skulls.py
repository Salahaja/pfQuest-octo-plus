#!/usr/bin/env python3
"""skulls.py -- finds the boss skulls Turtle paints into its dungeon maps.

    electron mpqextract.js <client Data> "^interface.worldmap.[^.]*.[^.]*[.]blp$" <tiles>
    python skulls.py <tiles> <out.json> [--review <dir>]

Each dungeon map is twelve 256x256 tiles (Interface/WorldMap/<Name>/<Name>1..12),
a 1002x668 picture once stitched. The skull is the same small icon on every
map, drawn at different sizes (Blackrock Depths' are two thirds of Zul'Farrak's)
over differently tinted rooms, so it is found by normalized cross-correlation
of a grey skull cut from Zul'Farrak, at six sizes. Real skulls score 0.65 and
up; a few other shapes reach 0.71 (Blackrock Depths' round junction), so the
candidates of 0.60 and up are drawn on --review pictures and checked by eye.
tools/data/dungeon_skulls.json holds the checked result.

Needs Pillow (reads .blp) and numpy.
"""

import argparse
import json
import os
import re
import sys

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
PATCHES = ["patch-5.mpq", "patch-4.mpq", "patch-3.mpq", "patch-2.mpq", "patch-1.mpq", "patch.MPQ"]
SCALES = [0.6, 0.7, 0.8, 0.9, 1.0, 1.15]
# the skull: Zul'Farrak's Ukorz Sandscalp icon, 18 px across, at (423, 225)
TEMPLATE = ("ZulFarrak", 423, 225, 9)


def stitch(tiles, name):
    """The map picture, newest patch's tiles winning; None if none found."""
    img = Image.new("RGBA", (1024, 768))
    found = False
    for i in range(1, 13):
        for p in PATCHES:
            f = os.path.join(tiles, p, "Interface", "WorldMap", name, "%s%d.blp" % (name, i))
            if os.path.exists(f):
                t = Image.open(f).convert("RGBA")
                if t.size != (256, 256):
                    t = t.resize((256, 256))
                img.paste(t, (((i - 1) % 4) * 256, ((i - 1) // 4) * 256))
                found = True
                break
    return img.crop((0, 0, 1002, 668)) if found else None


def ncc(img, tpl):
    h, w = tpl.shape
    t = (tpl - tpl.mean()) / (tpl.std() + 1e-6)
    win = sliding_window_view(img, (h, w))
    mu = win.mean(axis=(2, 3), keepdims=True)
    sd = win.std(axis=(2, 3), keepdims=True) + 1e-6
    return ((win - mu) / sd * t).mean(axis=(2, 3))


def detect(picture, skull, floor=0.45):
    g = np.asarray(picture.convert("L"), dtype=np.float32)
    cands = []
    for sc in SCALES:
        size = max(8, int(round(18 * sc)))
        t = np.asarray(skull.resize((size, size), Image.BILINEAR), dtype=np.float32)
        r = ncc(g, t)
        while True:
            y, x = divmod(int(np.argmax(r)), r.shape[1])
            v = float(r[y, x])
            if v < floor:
                break
            cands.append((x + size / 2, y + size / 2, v, sc))
            r[max(0, y - size):y + size, max(0, x - size):x + size] = -1
    cands.sort(key=lambda c: -c[2])
    keep = []
    for c in cands:
        if all((c[0] - k[0]) ** 2 + (c[1] - k[1]) ** 2 > 100 for k in keep):
            keep.append(c)
    return keep


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tiles")
    ap.add_argument("out")
    ap.add_argument("--review", help="write a picture per map with its candidates circled")
    args = ap.parse_args()

    src = open(os.path.join(os.path.dirname(HERE), "db", "instances-turtle.lua"), encoding="utf-8").read()
    names = re.findall(r'name = "([A-Za-z0-9]+)", map', src)
    name, x, y, r = TEMPLATE
    zf = stitch(args.tiles, name)
    if zf is None:
        sys.exit("no %s tiles under %s" % (name, args.tiles))
    skull = zf.convert("L").crop((x - r, y - r, x + r, y + r))

    out = {}
    for n in names:
        pic = stitch(args.tiles, n)
        if pic is None:
            print("%-24s no tiles" % n)
            continue
        cands = [c for c in detect(pic, skull) if c[2] >= 0.60]
        out[n] = [[round(cx / 1002 * 100, 1), round(cy / 668 * 100, 1), round(v, 2)] for cx, cy, v, _ in cands]
        print("%-24s %2d candidates, %d below 0.75" % (n, len(cands), sum(1 for c in cands if c[2] < 0.75)))
        if args.review:
            os.makedirs(args.review, exist_ok=True)
            im = pic.convert("RGB")
            d = ImageDraw.Draw(im)
            for k, (cx, cy, v, sc) in enumerate(cands, 1):
                col = (0, 200, 0) if v >= 0.75 else (255, 200, 0)
                rr = 12 * sc + 5
                d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), outline=col, width=3)
                d.text((cx + rr + 2, cy - 6), str(k), fill=col)
            im.save(os.path.join(args.review, n + ".png"))
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1)


if __name__ == "__main__":
    main()
