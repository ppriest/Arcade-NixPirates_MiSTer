#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The video as MAME draws it, from captured state, compared with MAME's own frames.

    python scripts/render_model.py <capdir> [<capdir> ...]     # e.g. debug/vidcap/pirates
    python scripts/render_model.py debug/vidcap/genix --png    # also write model and diff images

A transcription of src/mame/nix/pirates.cpp screen_update (279-285), draw_sprites (247-275),
get_*_tile_info (186-210), the layouts (405-431) and the xRGB_555 palette (456), drawn from
scripts/vid_capture.py's dumps and the graphics decrypted by MAME's own loops
(scripts/decrypt_model.py gather_quarters). Every captured frame is compared pixel for pixel with
MAME's snapshot of it; the RTL is then compared with this model (sim/video_tb).

The tilemap shares are MAME's split of one RAM; MAME's fg and bg tilemaps are 64 columns over
46 columns of share. Past a share the model reads on in the same RAM, as the RTL does, and
counts the visible pixels that came from there: where MAME reads outside its share, a
difference there is MAME's, not the model's.
"""
import argparse
import sys
from functools import lru_cache
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import decrypt_model as dm  # noqa: E402

W, H, VIS_TOP, VIS_BOT = 288, 256, 16, 239
TX_BASE, FG_BASE, BG_BASE = 0x180 // 2, 0x1380 // 2, 0x2a80 // 2     # words, prg_map 353-356
FG_WORDS, BG_WORDS = (0x2a80 - 0x1380) // 2, (0x4188 - 0x2a80) // 2


def words(path):
    b = Path(path).read_bytes()
    return [b[i] << 8 | b[i + 1] for i in range(0, len(b), 2)]


def pal5(v):
    return (v << 3) | (v >> 2)


class Gfx:
    """MAME's decrypted 'tiles' and 'sprites' regions, decoded per the layouts on demand."""

    def __init__(self, game):
        enc = dm.regions(game)
        self.tiles = dm.gather_quarters(enc["tiles"], dm.A_P, dm.D_P)
        self.sprites = dm.gather_quarters(enc["sprites"], dm.A_S, dm.D_S)
        self.qt, self.qs = len(self.tiles) // 4, len(self.sprites) // 4

    @lru_cache(maxsize=None)
    def tile(self, code):
        # charlayout: plane p (pen bit p) in quarter p, 8 bytes a tile, pixel x in bit x
        code %= self.qt // 8
        return [[sum(((self.tiles[p * self.qt + code * 8 + y] >> x) & 1) << p for p in range(4))
                 for x in range(8)] for y in range(8)]

    @lru_cache(maxsize=None)
    def sprite(self, code):
        # spritelayout: 32 bytes a sprite a plane, two bytes a row, pixel x in byte x>>3 bit x&7
        code %= self.qs // 32
        return [[sum(((self.sprites[p * self.qs + code * 32 + y * 2 + (x >> 3)] >> (x & 7)) & 1) << p
                      for p in range(4)) for x in range(16)] for y in range(16)]


def render(gfx, vram, pal, spr, scroll, index=False):
    """288 x 224 RGB tuples, or palette indices with index=True."""
    rgb = list(range(len(pal))) if index else [(pal5((w >> 10) & 31), pal5((w >> 5) & 31), pal5(w & 31)) for w in pal]
    img = [[None] * W for _ in range(H)]
    beyond = 0

    def tilemap(base, share_words, cols, colr_add, opaque, sx):
        nonlocal beyond
        for y in range(VIS_TOP, VIS_BOT + 1):
            row = y >> 3
            for x in range(W):
                mx = (x + sx) % (cols * 8)
                idx = (mx >> 3) * 32 + row                       # TILEMAP_SCAN_COLS
                w = base + idx * 2
                code = vram[w] if w < len(vram) else 0
                colr = vram[w + 1] if w + 1 < len(vram) else 0
                pen = gfx.tile(code)[y & 7][mx & 7]
                if not opaque and pen == 0:
                    continue
                if idx * 2 + 1 >= share_words:
                    beyond += 1
                img[y][x] = rgb[((colr + colr_add) % 384) * 16 + pen]

    tilemap(BG_BASE, BG_WORDS, 64, 0x100, True, scroll)
    tilemap(FG_BASE, FG_WORDS, 64, 0x80, False, scroll)
    # draw_sprites: entry k from word 4k, its y in word 4k-1; later entries over earlier ones
    for k in range(1, 255):
        yraw = spr[4 * k - 1]
        if yraw & 0x8000:
            break
        x0 = spr[4 * k + 1] - 32
        y0 = 0xf2 - yraw
        code, colour = spr[4 * k + 2] >> 2, (spr[4 * k] & 0xff) % 128
        fx, fy = spr[4 * k + 2] & 2, spr[4 * k + 2] & 1
        pix = gfx.sprite(code)
        for sy in range(16):
            y = y0 + sy
            if y < VIS_TOP or y > VIS_BOT:
                continue
            for sx in range(16):
                x = x0 + sx
                if x < 0 or x >= W:
                    continue
                pen = pix[15 - sy if fy else sy][15 - sx if fx else sx]
                if pen:
                    img[y][x] = rgb[0x1800 + colour * 16 + pen]
    tilemap(TX_BASE, 36 * 32 * 2, 36, 0, False, 0)
    return [row for row in img[VIS_TOP:VIS_BOT + 1]], beyond


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capdirs", nargs="+")
    ap.add_argument("--png", action="store_true")
    a = ap.parse_args()
    from PIL import Image
    gfx_cache = {}
    bad = 0
    for d in map(Path, a.capdirs):
        game = d.name.split("_")[0]
        gfx = gfx_cache.setdefault(game, Gfx(game))
        for png in sorted(d.glob("f*.png"), key=lambda p: int(p.stem[1:])):
            f = png.stem
            if f.endswith(("_model", "_diff")):
                continue
            img, beyond = render(gfx, words(d / f"{f}_vram.bin"), words(d / f"{f}_palette.bin"),
                                 words(d / f"{f}_spriteram.bin"), words(d / f"{f}_scroll.bin")[0])
            ref = Image.open(png).convert("RGB")
            if ref.size != (W, VIS_BOT - VIS_TOP + 1):
                print(f"{d.name} {f}: MAME snapshot is {ref.size}")
                bad += 1
                continue
            rp = ref.load()
            diff = [(x, y) for y in range(len(img)) for x in range(W) if img[y][x] != rp[x, y]]
            note = f", {beyond} visible tile pixels from past a share" if beyond else ""
            print(f"{d.name} {f}: {'equal' if not diff else f'{len(diff)} pixels differ, first at {diff[0]}'}{note}")
            bad += bool(diff)
            if a.png:
                out = Image.new("RGB", (W, len(img)))
                out.putdata([px or (0, 0, 0) for row in img for px in row])
                out.save(d / f"{f}_model.png")
                dimg = Image.new("RGB", (W, len(img)))
                dimg.putdata([(255, 0, 0) if img[y][x] != rp[x, y] else (0, 0, 0)
                              for y in range(len(img)) for x in range(W)])
                dimg.save(d / f"{f}_diff.png")
    print("PASS" if not bad else f"FAIL ({bad} frames)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
