#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files and prove each one byte for byte.

    python scripts/build_mra.py                          # every set -> releases/
    python scripts/build_mra.py genix                    # one set
    python scripts/build_mra.py --check                  # verify only, write nothing
    python scripts/build_mra.py --image pirates out.bin  # the download image, for the benches

The download image is rtl/np_rom_map.svh's DL_* layout: each region as dumped (encrypted), the
program ROM as big-endian 68000 words. It is built three ways and all three must agree:

  1. from the driver's ROM_START records (scripts/extract_romstart.py), as MAME's loader
     places them, zero fill;
  2. from `mame -listxml` (names, offsets, CRCs) by scripts/decrypt_model.py, whose decrypted
     form is checked against MAME's own regions;
  3. by re-reading the written .mra with scripts/mra.py (mra-tools-c's semantics).

The ROM_LOAD16_BYTE pair's interleave map is not reasoned about: each candidate is tried
against image 1 and the one that reproduces it is written. After Arcade-Eolith_MiSTer's
scripts/build_mra.py.
"""
import argparse
import re
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import decrypt_model                 # noqa: E402
import extract_romstart as ers       # noqa: E402
import mra as mra_lib                # noqa: E402
from coretools import mame_version, setting  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER = Path(setting("MAME_SRC") or "E:/mame/src/mame/nix/pirates.cpp")
ROMDIRS = [Path(p) for p in (setting("MAME_ROMPATH") or "F:/Emulation/roms/MAME ROMs").split(";")]
OUT_DIR = REPO / "releases"

# --- core-specific ---------------------------------------------------------------------------
# set: (parent or None, mod byte, primary .mra for its game)
SETS = {
    "pirates":  (None, 0x00, True),
    "piratesb": ("pirates", 0x00, False),
    "genix":    (None, 0x01, True),
}
# Per game (parent), buttons 1-3. Pirates: pressed one at a time in MAME 0.289 play: button 1
# flashes a hit at the crosshair, button 2 rolls the player aside, button 3 throws a bomb and
# takes one from the bomb counter. Genix Family: the cabinet test labels them A, B, C; button 3
# circles the player with cards; buttons 1 and 2 were not told apart (ROADMAP, open items).
BUTTONS = {
    "pirates": ["Shoot", "Slide", "Bomb"],
    "genix": ["Button A", "Button B", "Special"],
}
# The J1 line's layout (NixPirates.sv): six button slots, then Start 10, Coin 11, Pause 12,
# Service 13, as KonamiGX and Seta.
BUTTON_SLOTS = 6
CATEGORY = "Shooter"   # MiSTer-MAME-Coverage genre (catver): "Shooter / 3rd Person", both games
REGIONS = ("maincpu", "tiles", "sprites", "oki")
DL_KEY = {"maincpu": "DL_PRG", "tiles": "DL_TILES", "sprites": "DL_SPRITES", "oki": "DL_OKI"}
EEPROM_BYTES = 128     # 93C46, 64 x 16 (pirates.cpp 444)
# Per game: MAME's plugins/hiscore/hiscore.dat entries (address, length, start byte, end byte),
# read from the MAME 0.289 install. The .nvm is the EEPROM, then these, in order (NixPirates.sv).
HISCORE = {
    "pirates": [(0x10a544, 0x76, 0x4e, 0x10), (0x10a5b0, 0x01, 0x4e, 0x4e)],
    "genix":   [(0x10bd2c, 0x64, 0x4e, 0x10)],
}
# hiscore.v's 16-byte header: START_WAIT, CHECK_WAIT, CHECK_HOLD (2 or more: the RAM byte is
# registered, rtl/hiscore/PROVENANCE.md), WRITE_HOLD, WRITE_REPEATCOUNT, WRITE_REPEATWAIT,
# ACCESS_PAUSEPAD, CHANGEMASK; Arcade-Psikyo_MiSTer's values
HISCORE_HEADER = "19 9A 57 EF 3F FF 00 02 00 02 00 01 00 0F 10 00"
# ---------------------------------------------------------------------------------------------


def rom_map():
    text = (REPO / "rtl" / "np_rom_map.svh").read_text(encoding="utf-8")
    m = {k: int(v, 16) for k, v in re.findall(r"localparam \[23:0\] (DL_\w+)\s*=\s*24'h([0-9a-fA-F]+);", text)}
    for k in list(DL_KEY.values()) + ["DL_END"]:
        if k not in m:
            sys.exit(f"{k} missing from rtl/np_rom_map.svh")
    return m


def game_info(text, setname):
    """GAME( year, set, parent, machine, input, class, init, rotation, company, title, flags )."""
    m = re.search(r"GAME\(\s*(\d+)\s*,\s*" + setname + r"\s*,\s*(\w+)\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,"
                  r"\s*\w+\s*,\s*(\w+)\s*,\s*\"([^\"]*)\"\s*,\s*\"([^\"]*)\"", text)
    if not m:
        sys.exit(f"no GAME line for {setname}")
    rot = m.group(3)
    if rot not in ("0", "ROT0"):
        sys.exit(f"{setname}: rotation {rot}; this generator writes horizontal only")
    return {"year": m.group(1), "manufacturer": m.group(4), "title": m.group(5)}


def zips_for(setname):
    names = [setname + ".zip"] + ([SETS[setname][0] + ".zip"] if SETS[setname][0] else [])
    found = []
    for n in names:
        for d in [REPO / "roms"] + ROMDIRS:
            if (d / n).exists():
                found.append(d / n)
                break
    return names, found


def region_size(body, region):
    m = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + re.escape(region) + '"', body)
    if not m:
        sys.exit(f"no ROM_REGION {region}")
    return int(m.group(1), 16)


def load_region(zs, records, size):
    """ROM_START records -> region bytes as MAME's loader puts them, big-endian words for
    ROM_LOAD16_BYTE (dest & 1 = 0 is the high byte), zero fill."""
    out = bytearray(size)
    for kind, name, dest, length, crc, *rest in records:
        data = mra_lib._zip_read(zs, name, crc)
        assert len(data) == length, (name, len(data), length)
        if kind == "load":
            out[dest:dest + length] = data
        elif kind == "load16_byte":
            out[dest:dest + 2 * length:2] = data
        else:
            sys.exit(f"record kind {kind} not handled")
    return bytes(out)


def buttons_xml(game):
    have = BUTTONS[game]
    names = have + ["-"] * (BUTTON_SLOTS - len(have)) + ["Start", "Coin", "Pause", "Service"]
    default = ["A", "B", "X", "Y", "L", "R"][:len(have)] + ["Start", "Select", "L", "R"]
    return f'    <buttons names="{",".join(names)}" default="{",".join(default)}" count="{len(have)}"/>'


def build(setname, dl, write=True):
    parent, mod, primary = SETS[setname]
    text = DRIVER.read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    info = game_info(text, setname)
    names, paths = zips_for(setname)
    if not paths:
        print(f"{setname}: no zip found ({' / '.join(names)}); skipped")
        return False
    zs = [zipfile.ZipFile(p) for p in paths]
    rec = {}
    for r in REGIONS:
        recs, unknown = ers.region_records(body, r)
        if unknown:
            sys.exit(f"{setname}: region {r}: unparsed {unknown}")
        rec[r] = recs

    # image 1: ROM_START
    img = bytearray(dl["DL_END"])
    for r in REGIONS:
        data = load_region(zs, rec[r], region_size(body, r))
        base = dl[DL_KEY[r]]
        end = min((dl[k] for k in list(DL_KEY.values()) + ["DL_END"] if dl[k] > base))
        assert len(data) == end - base, (r, hex(len(data)), hex(end - base))
        img[base:base + len(data)] = data
    img = bytes(img)

    # image 2: -listxml through decrypt_model
    lx = decrypt_model.regions(setname)
    for r in REGIONS:
        base = dl[DL_KEY[r]]
        if bytes(lx[r]) != img[base:base + len(lx[r])]:
            sys.exit(f"{setname}: region {r} from ROM_START differs from -listxml's")

    # the .mra, part by part, in download order
    L = []
    pos = 0

    def pad_to(addr, why):
        nonlocal pos
        if addr > pos:
            L.append(f'        <part repeat="0x{addr - pos:X}">00</part>  <!-- {why} -->')
            pos = addr
        assert pos == addr, (why, hex(pos), hex(addr))

    for r in REGIONS:
        base = dl[DL_KEY[r]]
        pad_to(base, f"{r} start")
        L.append(f"        <!-- {r} -->")
        recs = sorted(rec[r], key=lambda x: x[2])
        if recs[0][0] == "load16_byte":
            hi, lo = recs
            assert hi[2] == 0 and lo[2] == 1 and hi[3] == lo[3] and len(recs) == 2, recs
            want = img[base:base + 2 * hi[3]]
            dhi, dlo = mra_lib._zip_read(zs, hi[1], hi[4]), mra_lib._zip_read(zs, lo[1], lo[4])
            chosen = next(((a, b) for a, b in (("10", "01"), ("01", "10"), ("12", "21"), ("21", "12"))
                           if mra_lib.interleave([(dhi, a), (dlo, b)], 16) == want), None)
            if not chosen:
                sys.exit(f"{setname}: no interleave map reproduces {r}")
            L.append('        <interleave output="16">')
            L.append(f'            <part name="{escape(hi[1])}" crc="{hi[4]:08x}" map="{chosen[0]}"/>')
            L.append(f'            <part name="{escape(lo[1])}" crc="{lo[4]:08x}" map="{chosen[1]}"/>')
            L.append('        </interleave>')
            pos += 2 * hi[3]
            continue
        for kind, name, dest, length, crc, *rest in recs:
            if kind != "load":
                sys.exit(f"{setname}: {r}: {kind} where a plain load was expected")
            pad_to(base + dest, f"{r} 0x{dest:x}")
            L.append(f'        <part name="{escape(name)}" crc="{crc:08x}"/>')
            pos += length
    pad_to(dl["DL_END"], "end")

    game = parent or setname
    xml = [
        "<misterromdescription>",
        f"    <!-- Generated by scripts/build_mra.py from MAME {DRIVER.name}; the layout is",
        "         rtl/np_rom_map.svh. Do not edit by hand. -->",
        f"    <name>{escape(info['title'])}</name>",
        f"    <setname>{setname}</setname>",
        "    <rbf>NixPirates</rbf>",
        f"    <mameversion>{mame_version()}</mameversion>",
        f"    <year>{info['year']}</year>",
        f"    <manufacturer>{escape(info['manufacturer'])}</manufacturer>",
        f"    <category>{CATEGORY}</category>",
        "    <rotation>horizontal</rotation>",
        buttons_xml(game),
        "",
        "    <!-- the board has no DIPs; bit 0 is the core's own flip (rtl/np_video.sv) -->",
        '    <switches default="00" base="0">',
        '        <dip name="Flip Screen" bits="0" ids="Off,On"/>',
        "    </switches>",
        "",
        "    <!-- mod byte (rtl/np_rom_map.svh): [0] 0 pirates protection patch, 1 genix -->",
        f'    <rom index="1"><part>{mod:02X}</part></rom>',
        "",
        # address=: the HPS writes the image into DDR3 and the core copies it (rtl/np_ddr_loader.sv)
        f'    <rom index="0" zip="{"|".join(names)}" md5="none" address="0x30000000">',
        *L,
        "    </rom>",
        "",
        "    <!-- hiscore.v's configuration: MAME's hiscore.dat entries -->",
        '    <rom index="3">',
        "        <part>",
        f"        {HISCORE_HEADER}",
        *[f"        {a >> 24:02X} {(a >> 16) & 0xff:02X} {(a >> 8) & 0xff:02X} {a & 0xff:02X} "
          f"{n:02X} {st:02X} {en:02X} 00" for a, n, st, en in HISCORE[game]],
        "        </part>",
        "    </rom>",
        "",
        "    <!-- the 93C46 (128 bytes), then the hiscore table -->",
        f'    <nvram index="2" size="{EEPROM_BYTES + sum(n for _, n, _, _ in HISCORE[game])}"/>',
        "</misterromdescription>",
        "",
    ]
    title = re.sub(r'[\\/:*?"<>|]', "-", info["title"])
    if primary:
        fname = OUT_DIR / f"{title}.mra"
    else:
        ptitle = re.sub(r"\s*\(.*\)$", "", game_info(text, parent)["title"])
        fname = OUT_DIR / "_alternatives" / f"_{ptitle}" / f"{title}.mra"
    fname.parent.mkdir(parents=True, exist_ok=True)
    tmp = fname.with_suffix(".mra.tmp")
    tmp.write_text("\n".join(xml), encoding="utf-8", newline="\n")
    got = mra_lib.build_image(str(tmp), [str(p) for p in paths])
    for z in zs:
        z.close()
    if got != img:
        diff = next((i for i in range(min(len(got), len(img))) if got[i] != img[i]), min(len(got), len(img)))
        tmp.unlink()
        sys.exit(f"{setname}: the .mra image differs from the ROM_START image at 0x{diff:x} "
                 f"({len(got)} vs {len(img)} bytes)")
    rel = fname.relative_to(REPO)
    if write:
        tmp.replace(fname)
        print(f"{setname}: {rel}, image {len(img)} bytes, equal to ROM_START and -listxml")
    else:
        tmp.unlink()
        print(f"{setname}: image {len(img)} bytes, equal to ROM_START and -listxml (not written)")
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--image", nargs=2, metavar=("SET", "OUT"))
    a = ap.parse_args()
    dl = rom_map()
    if a.image:
        img = build(a.image[0], dl, write=False)
        if img is False:
            return 1
        Path(a.image[1]).write_bytes(img)
        print(f"wrote {a.image[1]}")
        return 0
    ok = True
    for s in a.sets or list(SETS):
        if s not in SETS:
            sys.exit(f"unknown set {s}")
        ok = build(s, dl, write=not a.check) is not False and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
