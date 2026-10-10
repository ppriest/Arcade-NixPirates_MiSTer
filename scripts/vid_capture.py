#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture MAME's video state and frame at several frames, for the video model and benches.

    python scripts/vid_capture.py <set> [--frames 900,1500,2100] [--coin 600] [--tag play]

Runs scripts/mame/vidcap.lua and writes debug/vidcap/<set><_tag>/:
f<frame>_vram.bin (0x900000-0x904187), f<frame>_palette.bin, f<frame>_spriteram.bin,
f<frame>_scroll.bin (big-endian words, as the 68000 sees them) and f<frame>.png, MAME's
snapshot of the frame drawn from them.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def capture(game, frames, coin=0, tag=""):
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / "vidcap" / (game + (f"_{tag}" if tag else ""))
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    snaps = out / "snap"
    env = dict(os.environ, **lua_runner_env("vidcap.lua"), CORE_OUT=out.as_posix(), VC_OUT=out.as_posix(),
               VC_FRAMES=",".join(str(f) for f in frames), VC_COIN=str(coin))
    cmd = mame_cmd(exe, game, "vidcap.lua", mame_dir,
                   ["-snapshot_directory", snaps.as_posix(), "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    pngs = sorted((snaps / game).glob("*.png"))
    if len(pngs) != len(frames):
        sys.exit(f"{game}: {len(pngs)} snapshots for {len(frames)} frames")
    for f, png in zip(sorted(frames), pngs):
        png.replace(out / f"f{f}.png")
    shutil.rmtree(snaps)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", default="900,1500,2100,2700,3300")
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    frames = sorted(int(x) for x in a.frames.split(","))
    out = capture(a.set, frames, a.coin, a.tag)
    print(f"{a.set}: {len(frames)} frames in {out.relative_to(REPO)}")


if __name__ == "__main__":
    sys.exit(main())
