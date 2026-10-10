#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The SDRAM banks of rtl/np_sdram_map.svh, two ways, and the loader's mapping.

    python scripts/sdram_model.py <set> [<set> ...]          # both routes must agree
    python scripts/sdram_model.py <set> --out DIR            # also write DIR/bank{0..3}.bin
    python scripts/sdram_model.py --map 0x123456             # one download byte's destination
    python scripts/sdram_model.py --emit-sv                  # regenerate rtl/np_decrypt.svh

  regions   MAME's decryption loops (decrypt_model gather_*, checked against MAME's own regions)
            applied to the -listxml regions, then laid out per np_sdram_map.svh
  download  loader_map() applied to every byte of the .mra image (build_mra.py): what
            rtl/np_rom_loader.sv does, one byte to one (bank, word, lane) with permuted data

The SDRAM holds the program unpatched: MAME's 0x62c0 patch (init_pirates) is applied on the CPU's
read path. bank{n}.bin: 4M 16-bit words, little-endian, the format sim/loader_tb dumps.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra                     # noqa: E402
from decrypt_model import (A68K_L, A68K_R, A_OKI, A_P, A_S, D68K_L, D68K_R, D_OKI, D_P, D_S,  # noqa: E402
                           bitswap, gather_68k, gather_oki, gather_quarters, inverse, regions)

BANK_WORDS = 1 << 22


def perm(bits):
    """bitswap(v, bits) for v < 2^24, by three byte-wide tables (a permutation is bitwise)."""
    t = [[bitswap(b << (8 * c), bits) for b in range(256)] for c in range(3)]
    return lambda v: t[0][v & 0xff] | t[1][(v >> 8) & 0xff] | t[2][v >> 16]


def dperm(bits):
    t = [bitswap(b, bits) for b in range(256)]
    return lambda v: t[v]


REV8 = [int(f"{b:08b}"[::-1], 2) for b in range(256)]
P_PRG_R, P_PRG_L = perm(inverse(A68K_R)), perm(inverse(A68K_L))
P_TILE, P_SPR, P_OKI = perm(A_P), perm(A_S), perm(A_OKI)
D_PRG_R, D_PRG_L, D_OK = dperm(D68K_R), dperm(D68K_L), dperm(D_OKI)
D_TILE = [dperm(d) for d in D_P]
D_SPR = [dperm(d) for d in D_S]


def tile_word(t, y, p):
    return (t << 4) | (y << 1) | (p >> 1)


def sprite_word(s, y, h, p):
    return (s << 6) | (y << 2) | (h << 1) | (p >> 1)


def loader_map(i, v, dl):
    """Download byte i (value v) -> (bank, word, lane, data). lane 1 is [15:8]."""
    if i < dl["DL_TILES"]:
        j = i >> 1
        if i & 1 == 0:
            return 0, P_PRG_R(j), 1, D_PRG_R(v)
        return 0, P_PRG_L(j), 0, D_PRG_L(v)
    if i < dl["DL_SPRITES"]:
        o = i - dl["DL_TILES"]
        p, d = o >> 19, P_TILE(o & 0x7ffff)
        return 1, tile_word(d >> 3, d & 7, p), p & 1, REV8[D_TILE[p](v)]
    if i < dl["DL_OKI"]:
        o = i - dl["DL_SPRITES"]
        p, d = o >> 19, P_SPR(o & 0x7ffff)
        return 2, sprite_word(d >> 5, (d >> 1) & 15, d & 1, p), p & 1, D_SPR[p](v)
    d = P_OKI(i - dl["DL_OKI"])
    return 3, d >> 1, d & 1, D_OK(v)


def sdram_from_download(img, dl):
    banks = [bytearray(2 * BANK_WORDS) for _ in range(4)]
    seen = [bytearray(2 * BANK_WORDS) for _ in range(4)]
    for i, v in enumerate(img):
        b, w, lane, data = loader_map(i, v, dl)
        k = 2 * w + lane
        if seen[b][k]:
            sys.exit(f"download bytes collide at bank {b} word 0x{w:x} lane {lane} (byte 0x{i:x})")
        seen[b][k] = 1
        banks[b][k] = data
    return banks


def sdram_from_regions(dec):
    banks = [bytearray(2 * BANK_WORDS) for _ in range(4)]
    prg = dec["maincpu"]
    for w in range(len(prg) // 2):
        banks[0][2 * w + 1], banks[0][2 * w] = prg[2 * w], prg[2 * w + 1]
    for rgn, b in (("tiles", 1), ("sprites", 2)):
        data = dec[rgn]
        q = len(data) // 4
        for p in range(4):
            for d in range(q):
                v = data[p * q + d]
                if rgn == "tiles":
                    w, v = tile_word(d >> 3, d & 7, p), REV8[v]
                else:
                    w = sprite_word(d >> 5, (d >> 1) & 15, d & 1, p)
                banks[b][2 * w + (p & 1)] = v
    oki = dec["oki"]
    banks[3][:len(oki)] = oki
    return banks


def decrypted(game):
    enc = regions(game)
    return {"maincpu": gather_68k(enc["maincpu"]),
            "tiles": gather_quarters(enc["tiles"], A_P, D_P),
            "sprites": gather_quarters(enc["sprites"], A_S, D_S),
            "oki": gather_oki(enc["oki"])}


def sv_addr(name, bits, width):
    """A Verilog function: bitswap<24>'s low `width` output bits from a `width`-bit input."""
    src = bits[24 - width:]
    assert all(x < width for x in src), (name, src)
    cat = ", ".join(f"a[{x}]" for x in src)
    return (f"function automatic [{width - 1}:0] {name}(input [{width - 1}:0] a);\n"
            f"    {name} = {{{cat}}};\nendfunction\n")


def sv_data(name, bits):
    cat = ", ".join(f"d[{x}]" for x in bits)
    return f"function automatic [7:0] {name}(input [7:0] d);\n    {name} = {{{cat}}};\nendfunction\n"


def emit_sv(path):
    """rtl/np_decrypt.svh: the loader's permutations, from the same tables as this model."""
    parts = [
        "// SPDX-License-Identifier: GPL-3.0-or-later\n",
        "// Generated by scripts/sdram_model.py --emit-sv from scripts/decrypt_model.py's tables\n",
        "// (pirates.cpp decrypt_68k, decrypt_p, decrypt_s, decrypt_oki). Do not edit by hand.\n",
        "// Each function is bitswap<N> as MAME writes it: the first listed bit is the output MSB.\n\n",
        "// Program: encrypted word index -> decrypted word index, per byte lane (the inverse of\n",
        "// decrypt_68k's gather), and the lane's data permutation.\n",
        sv_addr("np_prg_hi_addr", inverse(A68K_R), 19), sv_data("np_prg_hi_data", D68K_R),
        sv_addr("np_prg_lo_addr", inverse(A68K_L), 19), sv_data("np_prg_lo_data", D68K_L),
        "\n// Tiles and sprites: within a 512 KB plane quarter, encrypted -> decrypted byte index;\n",
        "// data permutation per quarter.\n",
        sv_addr("np_tile_addr", A_P, 19),
        *[sv_data(f"np_tile_data{q}", D_P[q]) for q in range(4)],
        sv_addr("np_spr_addr", A_S, 19),
        *[sv_data(f"np_spr_data{q}", D_S[q]) for q in range(4)],
        "\n// Samples: encrypted -> decrypted byte index, and the data permutation.\n",
        sv_addr("np_oki_addr", A_OKI, 19), sv_data("np_oki_data", D_OKI),
    ]
    Path(path).write_text("".join(parts), encoding="utf-8", newline="\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--out")
    ap.add_argument("--map")
    ap.add_argument("--emit-sv", action="store_true")
    a = ap.parse_args()
    if a.emit_sv:
        emit_sv(Path(__file__).resolve().parent.parent / "rtl" / "np_decrypt.svh")
        print("wrote rtl/np_decrypt.svh")
    dl = build_mra.rom_map()
    if a.map:
        print(loader_map(int(a.map, 0), 0, dl)[:3])
    bad = 0
    for g in a.sets:
        img = build_mra.build(g, dl, write=False)
        via_dl = sdram_from_download(img, dl)
        via_rg = sdram_from_regions(decrypted(g))
        for b in range(4):
            same = via_dl[b] == via_rg[b]
            bad += not same
            print(f"{g}: bank {b} {'equal' if same else 'DIFFERS'}")
        if a.out:
            out = Path(a.out) / g
            out.mkdir(parents=True, exist_ok=True)
            for b in range(4):
                (out / f"bank{b}.bin").write_bytes(via_rg[b])
            print(f"{g}: banks written to {out}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
