#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hit rates of a direct-mapped program-ROM cache on MAME's own fetch stream.

    python scripts/cache_model.py <set> [--line 8] [--sizes 512,1024,...]

Reads debug/<set>-boot/<set>_boot.trace (scripts/mame_boot_trace.py) and replays its
program-ROM reads (regions.json "trace" "rom") through direct-mapped caches of each size
with --line-byte lines: jtframe_romrq_lcache's shape, whose line is one jtframe_sdram64 burst
(8 bytes at BAx_LEN 64). Prints hits, misses, and misses per 1000 bus accesses of any kind,
for the whole trace and for its second half (past the boot's RAM clearing).
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import regions  # noqa: E402


def stream(path):
    rom = [(int(lo, 16), int(hi, 16)) for lo, hi in regions()["trace"]["rom"]]
    acc = []
    with open(path, encoding="utf8") as f:
        for ln in f:
            if not ln[:1].isdigit():
                continue
            _, rw, a, _, _ = ln.split()
            a = int(a, 16)
            acc.append(a if rw == "r" and any(lo <= a <= hi for lo, hi in rom) else -1)
    return acc


def run(acc, size, line):
    lines = size // line
    tags = [-1] * lines
    hits = miss = 0
    for a in acc:
        if a < 0:
            continue
        ln = a // line
        i = ln % lines
        if tags[i] == ln:
            hits += 1
        else:
            miss += 1
            tags[i] = ln
    return hits, miss


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--line", type=int, default=8)
    ap.add_argument("--sizes", default="8,512,1024,2048,4096,8192,16384,32768")
    a = ap.parse_args()
    acc = stream(REPO / "debug" / f"{a.set}-boot" / f"{a.set}_boot.trace")
    half = acc[len(acc) // 2:]
    nrom = sum(1 for x in acc if x >= 0)
    print(f"{a.set}: {len(acc)} accesses, {nrom} program-ROM reads, {a.line}-byte lines")
    print(f"  {'bytes':>6} {'hit%':>6} {'miss/1k acc':>11} {'2nd half hit%':>13} {'miss/1k':>8}")
    for s in (int(x) for x in a.sizes.split(",")):
        h, m = run(acc, s, a.line)
        h2, m2 = run(half, s, a.line)
        print(f"  {s:6d} {100 * h / (h + m):6.2f} {1000 * m / len(acc):11.1f} "
              f"{100 * h2 / max(1, h2 + m2):13.2f} {1000 * m2 / len(half):8.1f}")


if __name__ == "__main__":
    sys.exit(main())
