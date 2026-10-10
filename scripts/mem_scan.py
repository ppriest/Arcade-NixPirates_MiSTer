#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Every address range the main CPU touches in MAME, against the driver's map.

    python scripts/mem_scan.py <set> [<set> ...] [--frames 3600] [--coin 600]

Runs scripts/mame/memscan.lua from power-on and prints the touched 256-byte
pages merged into ranges, writes and reads (program-ROM reads excluded), each
tagged with the regions.json region it falls in, or UNMAPPED; every access
outside the driver's mapped ranges by exact address, with the PC and frame of
its first occurrence (ROM writes included); then the 68000
vector table read from the decrypted "maincpu" region. Raw results:
debug/memscan/<set><tag>.txt.

Answers: what RAM the power-on test walks (back it at the declared size), and
where the interrupt vectors point (LESSONS_LEARNED, "[Seta] Read the interrupt
vectors before trusting a board's interrupt config").
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402

VECTORS = {2: "bus error", 3: "address error", 4: "illegal", 24: "spurious",
           **{24 + i: f"autovector {i}" for i in range(1, 8)}}


def named(addr):
    r = regions()
    table = {**r.get("read", {}), **r.get("wtap", {})}
    for name, (lo, hi) in table.items():
        if int(lo, 16) <= addr <= int(hi, 16):
            return name
    for lo, hi in r["trace"]["io"]:
        if int(lo, 16) <= addr <= int(hi, 16):
            return "io"
    if addr <= 0x0fffff:
        return "rom"
    return "UNMAPPED"


def mapped_spec():
    """The driver's mapped ranges, for the Lua side: regions.json read, wtap, io, rom."""
    r = regions()
    spans = [tuple(v) for v in {**r.get("read", {}), **r.get("wtap", {})}.values()]
    spans += [tuple(v) for v in r["trace"]["io"]]
    spans += [tuple(v) for v in r["trace"]["rom"]]
    return ",".join(f"{int(lo, 16):x}:{int(hi, 16):x}" for lo, hi in spans)


def ranges(pages):
    out = []
    for p in sorted(pages):
        if out and p == out[-1][1] + 0x100:
            out[-1][1] = p
            out[-1][2] += pages[p]
        else:
            out.append([p, p, pages[p]])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    for g in a.sets:
        out = REPO / "debug" / "memscan" / f"{g}{a.tag}.txt"
        out.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, **lua_runner_env("memscan.lua"), CORE_OUT=out.parent.as_posix(),
                   MS_OUT=out.as_posix(), MS_FRAMES=str(a.frames), MS_COIN=str(a.coin),
                   MS_MAPPED=mapped_spec())
        subprocess.run(mame_cmd(exe, g, "memscan.lua", mame_dir), cwd=str(mame_dir), env=env,
                       capture_output=True, timeout=3600, **NO_WINDOW)
        if not out.exists():
            print(f"{g}{a.tag}: no result (MAME failed?)")
            continue
        wr, rd, vec, odd = {}, {}, [], []
        for line in out.read_text().splitlines():
            k, _, v = line.partition(" ")
            if k in ("w", "r"):
                addr, cnt = v.split()
                (wr if k == "w" else rd)[int(addr, 16)] = int(cnt)
            elif k == "odd":
                odd.append(v.split())
            elif k == "vec":
                vec = [int(x, 16) for x in v.split(",")]
        print(f"{g}{a.tag}: {a.frames} frames from power-on")
        for tag, pages in (("write", wr), ("read", rd)):
            for lo, hi, cnt in ranges(pages):
                print(f"  {tag:5s} {lo:06x}-{hi + 0xff:06x} {cnt:10d}  {named(lo)}"
                      + ("" if named(lo) == named(hi + 0xff) else f" .. {named(hi + 0xff)}"))
        # ROM-region writes are odd too, but ROM reads are untapped, so rom
        # addresses only ever show as writes here
        print("  outside the driver's map (kind addr count first-pc first-frame):")
        for kind, addr, cnt, pc, fr in odd:
            print(f"    {kind} {addr} {int(cnt):8d}  pc {pc}  frame {fr}")
        print("  vectors:")
        for i, name in sorted(VECTORS.items()):
            print(f"    {i:3d} {name:14s} {vec[2 * i] << 16 | vec[2 * i + 1]:08x}")
        print(f"    reset SSP {vec[0] << 16 | vec[1]:08x} PC {vec[2] << 16 | vec[3]:08x}")
        print()


if __name__ == "__main__":
    sys.exit(main())
