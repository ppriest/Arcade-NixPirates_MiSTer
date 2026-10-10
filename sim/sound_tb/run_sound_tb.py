#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""ROADMAP Phase 3: np_sound's output against MAME's, from the same command writes.

    python sim/sound_tb/run_sound_tb.py pirates genix [--seconds 30]

MAME runs the set with scripts/mame/okitrace.lua and -wavwrite; the writes are replayed in
sim/sound_tb on the 48 MHz clock they were made, with bank 3 from scripts/sdram_model.py, and
the chip's samples are compared with MAME's output per half second (compare()). The ROM
mapping, the decryption, the bank bit or the sample rate being wrong show as low correlation.
What is left is MAME's resampling to 48 kHz, which the comparison undoes only approximately.
Work files in obj_verilator/sound_tb_run/.
"""
import argparse
import os
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_runner_env, mame_cmd, mame_paths  # noqa: E402

CLK = 48_000_000
MAME_SR = 1333333 // 165
WORK = REPO / "obj_verilator" / "sound_tb_run"


def capture(game, seconds):
    mame_dir, exe = mame_paths()
    out = WORK / game
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, **lua_runner_env("okitrace.lua"), CORE_OUT=out.as_posix(),
               OT_OUT=(out / "writes.txt").as_posix(), OT_SECONDS=str(seconds))
    cmd = mame_cmd(exe, game, "okitrace.lua", mame_dir,
                   ["-wavwrite", (out / "mame.wav").as_posix(), "-sound", "none",
                    "-cfg_directory", (out / "cfg").as_posix(), "-nvram_directory", (out / "nvram").as_posix()])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=1800, **NO_WINDOW)
    with open(out / "writes.txt") as f, open(out / "writes_clk.txt", "w") as o:
        for line in f:
            t, k, v = line.split()
            o.write(f"{round(float(t) * CLK)} {k} {v}\n")
    subprocess.run([sys.executable, "scripts/sdram_model.py", game, "--out", str(WORK / "banks")], cwd=REPO,
                   check=True, capture_output=True)
    return out


def compare(game, out, seconds):
    """Per half second of MAME's samples: the best correlation within +-30 samples, and the level.

    MAME's M6295 stream runs at clock() / 165 in integers, 1333333 / 165 = 8080 Hz
    (okim6295.cpp 121), 100 ppm slower than the chip's 8080.81 Hz, which the core keeps. So the
    two are compared by sample index, MAME's 48 kHz output averaged over each of its own sample
    periods: within a sound the lag is constant, and it steps at each command by the time MAME
    has fallen behind (0.81 samples a second).
    """
    with wave.open(str(out / "mame.wav")) as w:
        ch, rate = w.getnchannels(), w.getframerate()
        m = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)[::ch]
    r = np.fromfile(out / "rtl.raw", dtype="<i2").astype(float) * 16    # 14 bits; MAME's gain is 4
    n = int(len(m) / rate * MAME_SR) - 1
    edges = (np.arange(n + 1) * rate / MAME_SR).astype(int)
    cs = np.concatenate([[0], np.cumsum(m)])
    mi = (cs[edges[1:]] - cs[edges[:-1]]) / np.maximum(np.diff(edges), 1)
    win = MAME_SR // 2
    corr, level, lags = [], [], []
    for k in range(2, len(mi) // win - 1):
        a, b = k * win, (k + 1) * win
        mm = mi[a:b]
        if mm.std() < 50:
            continue
        c, lag = max((float(np.corrcoef(mm, r[a - L:b - L])[0, 1]), L) for L in range(-30, 31))
        corr.append(c)
        lags.append(lag)
        level.append(float(np.sqrt(np.mean(r[a - lag:b - lag] ** 2)) / np.sqrt(np.mean(mm ** 2))))
    if not corr:
        print(f"{game}: silent ({len(r)} chip samples, MAME peak {abs(m).max():.0f})")
        return False
    med, lev = float(np.median(corr)), float(np.median(level))
    print(f"{game}: {len(corr)} sounding half-seconds; correlation median {med:.3f}, "
          f"{sum(c >= 0.9 for c in corr)} at 0.9 or more, lowest {min(corr):.3f}; core/MAME level {lev:.3f}; "
          f"lag {lags[0]:+d} to {lags[-1]:+d} samples")
    return med >= 0.9 and abs(lev - 1) < 0.1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--seconds", type=int, default=30)
    a = ap.parse_args()
    bad = 0
    for game in a.sets:
        out = capture(game, a.seconds)
        rel = lambda p: p.relative_to(REPO).as_posix()   # noqa: E731  (short paths: MAX_PATH)
        run = subprocess.run([shutil.which("bash"), "scripts/run_verilator.sh", "sound_tb",
                              f"+writes={rel(out / 'writes_clk.txt')}",
                              f"+sdram_bank3={rel(WORK / 'banks' / game / 'bank3.bin')}",
                              f"+cycles={a.seconds * CLK}", f"+out={rel(out / 'rtl.raw')}"],
                             cwd=REPO, capture_output=True, text=True)
        print("  " + "; ".join(ln for ln in (run.stdout + run.stderr).splitlines()
                               if ln.startswith(("DONE", "%Error", "SDRAM ERROR"))))
        bad += not compare(game, out, a.seconds)
    print("PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
