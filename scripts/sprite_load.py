#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sprites per scanline in MAME, for the sprite engine's line budget.

    python scripts/sprite_load.py <set> [<set> ...] [--skip 600] [--frames 3600]
    python scripts/sprite_load.py <set> --coin 600 --skip 1500 --tag _play

Runs scripts/mame/sprload.lua headless. Per set: longest list, mean list
length, most sprites on one visible line (any x, and overlapping the 288
visible columns), the frame and line where that happened, and a histogram of
each frame's worst visible line. Raw results: debug/sprload/<set><tag>.txt;
closing snapshot in debug/sprload/snap<tag>/.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def run(game, skip, frames, coin, tag):
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / "sprload" / f"{game}{tag}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, **lua_runner_env("sprload.lua"), CORE_OUT=out.parent.as_posix(),
               SL_OUT=out.as_posix(), SL_SKIP=str(skip), SL_FRAMES=str(frames), SL_COIN=str(coin))
    cmd = mame_cmd(exe, game, "sprload.lua", mame_dir,
                   ["-snapshot_directory", (out.parent / f"snap{tag}").as_posix(),
                    "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    for g in a.sets:
        out = run(g, a.skip, a.frames, a.coin, a.tag)
        if not out.exists():
            print(f"{g}{a.tag}: no result (MAME failed?)")
            continue
        kv, hist = {}, []
        for line in out.read_text().splitlines():
            k, _, v = line.partition(" ")
            if k == "framemax":
                c, nfr = v.split()
                hist.append((int(c), int(nfr)))
            else:
                kv[k] = v
        print(f"{g}{a.tag}: {kv['frames']} frames, list max {kv['list_max']} mean {kv['list_mean']}, "
              f"per line max {kv['line_max_any']} (visible {kv['line_max_visible']}, "
              f"frame {kv['worst_frame']} line {kv['worst_line']})")
        print("  worst visible line per frame: " + ", ".join(f"{c}:{nfr}" for c, nfr in hist))


if __name__ == "__main__":
    sys.exit(main())
