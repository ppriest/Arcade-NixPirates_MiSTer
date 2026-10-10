#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's four NIX decryptions, and the load-time form the RTL loader uses.

    python scripts/decrypt_model.py <set> [<set> ...]     # check against MAME
    python scripts/decrypt_model.py --tables              # print the RTL tables

For each set: builds the encrypted regions from the ROM zips (names, offsets
and CRCs from `mame -listxml`), decrypts them two ways, and compares both with
the regions MAME holds after init_pirates()/init_genix() (scripts/mame/
dumpregions.lua):

  gather   MAME's own loops, transcribed from src/mame/nix/pirates.cpp
           decrypt_68k(), decrypt_p(), decrypt_s(), decrypt_oki()
  scatter  what the loader can do with the HPS byte stream: encrypted byte i
           of a region is written, data bit-permuted, to address dst(i), where
           dst is a pure bit permutation of i -- wiring, no logic

pirates' MAME region also carries the protection patch at 0x62c0 (init_pirates);
the comparison reports it rather than failing on it.

ROM parts are found by CRC in <set>.zip and its parent's on the rompath.
"""
import argparse
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths, rompath  # noqa: E402


def bitswap(v, bits):
    """MAME bitswap<N>(v, b[N-1], ..., b[0]): output bit N-1-k is input bit bits[k]."""
    n = len(bits)
    out = 0
    for k, b in enumerate(bits):
        out |= ((v >> b) & 1) << (n - 1 - k)
    return out


# Address permutations (24 bits, MSB first) and data permutations (8 bits), from pirates.cpp.
A68K_L = (23, 22, 21, 20, 19, 18, 4, 8, 3, 14, 2, 15, 17, 0, 9, 13, 10, 5, 16, 7, 12, 6, 1, 11)
D68K_L = (4, 2, 7, 1, 6, 5, 0, 3)
A68K_R = (23, 22, 21, 20, 19, 18, 4, 10, 1, 11, 12, 5, 9, 17, 14, 0, 13, 6, 15, 8, 3, 16, 7, 2)
D68K_R = (1, 4, 7, 0, 3, 5, 6, 2)
A_P = (23, 22, 21, 20, 19, 18, 10, 2, 5, 9, 7, 13, 16, 14, 11, 4, 1, 6, 12, 17, 3, 0, 15, 8)
D_P = ((2, 3, 4, 0, 7, 5, 1, 6), (4, 2, 7, 1, 6, 5, 0, 3), (1, 4, 7, 0, 3, 5, 6, 2), (2, 3, 4, 0, 7, 5, 1, 6))
A_S = (23, 22, 21, 20, 19, 18, 17, 5, 12, 14, 8, 3, 0, 7, 9, 16, 4, 2, 6, 11, 13, 1, 10, 15)
D_S = ((4, 2, 7, 1, 6, 5, 0, 3), (1, 4, 7, 0, 3, 5, 6, 2), (2, 3, 4, 0, 7, 5, 1, 6), (4, 2, 7, 1, 6, 5, 0, 3))
A_OKI = (23, 22, 21, 20, 19, 10, 16, 13, 8, 4, 7, 11, 14, 17, 12, 6, 2, 0, 5, 18, 15, 3, 1, 9)
D_OKI = (2, 3, 4, 0, 7, 5, 1, 6)


def inverse(bits):
    """The permutation p' with bitswap(bitswap(v, p), p') == v."""
    n = len(bits)
    inv = [0] * n
    for k, b in enumerate(bits):          # output bit n-1-k <- input bit b
        inv[n - 1 - b] = n - 1 - k        # so input bit b <- output bit n-1-k
    return tuple(inv)


# --- gather: MAME's loops -------------------------------------------------------------

def gather_68k(enc):
    words = [enc[2 * i] << 8 | enc[2 * i + 1] for i in range(len(enc) // 2)]
    out = bytearray(len(enc))
    for i in range(len(words)):
        vl = bitswap(words[bitswap(i, A68K_L)] & 0xff, D68K_L)
        vr = bitswap(words[bitswap(i, A68K_R)] >> 8, D68K_R)
        out[2 * i], out[2 * i + 1] = vr, vl
    return out


def gather_quarters(enc, abits, dbits):
    q = len(enc) // 4
    out = bytearray(len(enc))
    for i in range(q):
        adr = bitswap(i, abits)
        for k in range(4):
            out[adr + k * q] = bitswap(enc[i + k * q], dbits[k])
    return out


def gather_oki(enc):
    out = bytearray(len(enc))
    for i in range(len(enc)):
        out[bitswap(i, A_OKI)] = bitswap(enc[i], D_OKI)
    return out


# --- scatter: byte i of the download goes to dst(i) ------------------------------------

def scatter(enc, dst, data):
    out = bytearray(len(enc))
    for i, v in enumerate(enc):
        out[dst(i)] = data(i, v)
    return out


def scatter_68k(enc):
    # byte 2w is the high (r) lane of encrypted word w, byte 2w+1 the low (l) lane.
    # MAME gathers word i's lanes from words A68K_R(i) and A68K_L(i); invert per lane.
    inv_r, inv_l = inverse(A68K_R), inverse(A68K_L)
    return scatter(enc,
                   lambda i: 2 * bitswap(i >> 1, inv_r if i & 1 == 0 else inv_l) + (i & 1),
                   lambda i, v: bitswap(v, D68K_R if i & 1 == 0 else D68K_L))


def scatter_quarters(enc, abits, dbits):
    q = len(enc) // 4
    qb = q.bit_length() - 1
    return scatter(enc,
                   lambda i: (i >> qb) << qb | bitswap(i & (q - 1), abits),
                   lambda i, v: bitswap(v, dbits[i >> qb]))


def scatter_oki(enc):
    return scatter(enc, lambda i: bitswap(i, A_OKI), lambda i, v: bitswap(v, D_OKI))


# --- ROM images from the zips -----------------------------------------------------------

def listxml(game):
    mame_dir, exe = mame_paths()
    xml = subprocess.run([str(exe), "-listxml", game], cwd=str(mame_dir), capture_output=True,
                         text=True, **NO_WINDOW).stdout
    m = next(m for m in ET.fromstring(xml).findall("machine") if m.get("name") == game)
    return m, m.get("cloneof")


def find_crc(crc, zips):
    for z in zips:
        with zipfile.ZipFile(z) as f:
            for info in f.infolist():
                if info.CRC == crc:
                    return f.read(info)
    raise SystemExit(f"no ROM with CRC {crc:08x} in {[str(z) for z in zips]}")


def regions(game):
    m, parent = listxml(game)
    mame_dir, _ = mame_paths()
    zips = [Path(d) / f"{n}.zip" for d in rompath(mame_dir).split(";") for n in (game, parent) if n]
    zips = [z for z in zips if z.exists()]
    size = {"maincpu": 0x100000, "tiles": 0x200000, "sprites": 0x200000, "oki": 0x80000}
    out = {k: bytearray(v) for k, v in size.items()}
    for rom in m.findall("rom"):
        data = find_crc(int(rom.get("crc"), 16), zips)
        rgn, off = rom.get("region"), int(rom.get("offset"), 16)
        if rgn == "maincpu":              # ROM_LOAD16_BYTE: even offset = high byte
            out[rgn][off::2] = data
        else:
            out[rgn][off:off + len(data)] = data
    return out


def mame_regions(game):
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / "regions" / game
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, **lua_runner_env("dumpregions.lua"), CORE_OUT=out.as_posix(),
               DR_OUT=out.as_posix(), DR_REGIONS="maincpu,tiles,sprites,oki")
    subprocess.run(mame_cmd(exe, game, "dumpregions.lua", mame_dir), cwd=str(mame_dir), env=env,
                   capture_output=True, timeout=600, **NO_WINDOW)
    return {k: (out / f"{k}.bin").read_bytes() for k in ("maincpu", "tiles", "sprites", "oki")}


def diff(a, b):
    return [i for i in range(len(a)) if a[i] != b[i]]


def check(game):
    enc = regions(game)
    ref = mame_regions(game)
    ways = {
        "maincpu": (gather_68k, scatter_68k),
        "tiles": (lambda e: gather_quarters(e, A_P, D_P), lambda e: scatter_quarters(e, A_P, D_P)),
        "sprites": (lambda e: gather_quarters(e, A_S, D_S), lambda e: scatter_quarters(e, A_S, D_S)),
        "oki": (gather_oki, scatter_oki),
    }
    ok = True
    for rgn, (g, s) in ways.items():
        gd, sd = g(enc[rgn]), s(enc[rgn])
        dg, ds = diff(gd, ref[rgn]), diff(sd, ref[rgn])
        note = ""
        if rgn == "maincpu" and dg == ds and dg and all(0x62c0 <= i <= 0x62c1 for i in dg):
            note = (f"  differs only at the 0x62c0 patch: unpatched {gd[0x62c0]:02x}{gd[0x62c1]:02x}, "
                    f"MAME {ref[rgn][0x62c0]:02x}{ref[rgn][0x62c1]:02x}")
            dg = ds = []
        ok &= not dg and not ds
        print(f"  {rgn:8s} gather {'equal' if not dg else f'{len(dg)} bytes differ'}, "
              f"scatter {'equal' if not ds else f'{len(ds)} bytes differ'}{note}")
    return ok


def tables():
    def fmt(bits):
        return "{" + ",".join(str(b) for b in bits) + "}"
    print("Load-time scatter: destination address bit k (MSB first) = source index bit listed.")
    print(f"maincpu even (r) byte: word dst = bitswap(word src, {fmt(inverse(A68K_R))}), data {fmt(D68K_R)}")
    print(f"maincpu odd  (l) byte: word dst = bitswap(word src, {fmt(inverse(A68K_L))}), data {fmt(D68K_L)}")
    print(f"tiles   within a quarter: {fmt(A_P)}, data per quarter {[fmt(d) for d in D_P]}")
    print(f"sprites within a quarter: {fmt(A_S)}, data per quarter {[fmt(d) for d in D_S]}")
    print(f"oki: {fmt(A_OKI)}, data {fmt(D_OKI)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--tables", action="store_true")
    a = ap.parse_args()
    if a.tables:
        tables()
    bad = 0
    for g in a.sets:
        print(f"{g}:")
        bad += not check(g)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
