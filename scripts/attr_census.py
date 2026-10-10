#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Which bits of the tile and sprite attribute words the games use, in MAME.

    python scripts/attr_census.py <set> [<set> ...] [--frames 3600] [--coin 600]

Runs scripts/mame/attrcensus.lua from power-on: per word kind (tx/fg/bg code
and colour, sprite colour/x/code/y), the OR and maximum of every value
written. Decides how wide the RTL's fields need to be and whether MAME's
colour wrap (rawcolor % 384, emu/tilemap.h) is ever reached. Raw results:
debug/attrcensus/<set><tag>.txt.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    for g in a.sets:
        out = REPO / "debug" / "attrcensus" / f"{g}{a.tag}.txt"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.unlink(missing_ok=True)
        env = dict(os.environ, **lua_runner_env("attrcensus.lua"), CORE_OUT=out.parent.as_posix(),
                   AC_OUT=out.as_posix(), AC_FRAMES=str(a.frames), AC_COIN=str(a.coin))
        subprocess.run(mame_cmd(exe, g, "attrcensus.lua", mame_dir), cwd=str(mame_dir), env=env,
                       capture_output=True, timeout=3600, **NO_WINDOW)
        print(f"{g}{a.tag}:")
        print(out.read_text() if out.exists() else "  no result (MAME failed?)\n")


if __name__ == "__main__":
    sys.exit(main())
