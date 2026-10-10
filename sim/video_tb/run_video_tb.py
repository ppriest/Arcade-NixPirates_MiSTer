#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""ROADMAP Phase 1: np_video's frames against scripts/render_model.py and MAME's.

    python sim/video_tb/run_video_tb.py <capdir> [<capdir> ...] [--frames f900,f1500] [--flip] [-G...]

For each captured frame (scripts/vid_capture.py) the bench renders the second frame from the
captured RAM, and its 288 x 224 pixels are compared with the model's rendering of the same
state, which equals MAME's snapshot (render_model.py). On a mismatch it also reports the best
whole-image shift, which is the usual sign of a pipeline offset (np_video LEAD_*). Bank images
and outputs in obj_verilator/video_tb_run/.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm   # noqa: E402

W, H = 288, 224


def best_shift(got, want):
    best = None
    for dy in range(-2, 3):
        for dx in range(-12, 13):
            bad = 0
            for y in range(4, H - 4, 3):
                for x in range(16, W - 16, 3):
                    if got[y][x] != want[y + dy][x + dx]:
                        bad += 1
            if best is None or bad < best[0]:
                best = (bad, dx, dy)
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capdirs", nargs="+")
    ap.add_argument("--frames", default="")
    ap.add_argument("--flip", action="store_true", help="flipped, against the model turned 180 degrees")
    a, gen = ap.parse_known_args()
    if a.flip:
        gen.append("-GFLIP=1")
    work = REPO / "obj_verilator" / "video_tb_run"
    work.mkdir(parents=True, exist_ok=True)
    pick = [f for f in a.frames.split(",") if f]
    bad = 0
    gfx_cache = {}
    for d in map(Path, a.capdirs):
        game = d.name.split("_")[0]
        banks = work / game
        if not (banks / "bank1.bin").exists():
            subprocess.run([sys.executable, "scripts/sdram_model.py", game, "--out", str(work)], cwd=REPO,
                           check=True, capture_output=True)
        gfx = gfx_cache.setdefault(game, rm.Gfx(game))
        for png in sorted(d.glob("f*.png"), key=lambda p: int(p.stem[1:].split("_")[0])):
            f = png.stem
            if "_" in f or (pick and f not in pick):
                continue
            out = work / f"{d.name}_{f}{'_flip' if a.flip else ''}.rgb"
            plus = [f"+vram={(d / f'{f}_vram.bin').as_posix()}", f"+pal={(d / f'{f}_palette.bin').as_posix()}",
                    f"+spr={(d / f'{f}_spriteram.bin').as_posix()}", f"+scroll={(d / f'{f}_scroll.bin').as_posix()}",
                    f"+sdram_bank1={(banks / 'bank1.bin').as_posix()}", f"+sdram_bank2={(banks / 'bank2.bin').as_posix()}",
                    f"+out={out.as_posix()}"]
            r = subprocess.run([shutil.which("bash"), "scripts/run_verilator.sh", "video_tb", *gen, *plus],
                               cwd=REPO, capture_output=True, text=True)
            log = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.startswith(("DONE", "%Error", "SDRAM ERROR"))]
            want, _ = rm.render(gfx, rm.words(d / f"{f}_vram.bin"), rm.words(d / f"{f}_palette.bin"),
                                rm.words(d / f"{f}_spriteram.bin"), rm.words(d / f"{f}_scroll.bin")[0])
            if a.flip:
                want = [row[::-1] for row in want[::-1]]
            raw = out.read_bytes() if out.exists() else b""
            if len(raw) != W * H * 5:
                print(f"{d.name} {f}: {len(raw) // 5} pixels, expected {W * H}; {'; '.join(log)}")
                bad += 1
                continue
            got = [[tuple(raw[5 * (y * W + x):5 * (y * W + x) + 3]) for x in range(W)] for y in range(H)]
            gpen = [[raw[5 * (y * W + x) + 3] << 8 | raw[5 * (y * W + x) + 4] for x in range(W)] for y in range(H)]
            diff = [(x, y) for y in range(H) for x in range(W) if got[y][x] != want[y][x]]
            if not diff:
                print(f"{d.name} {f}: equal to the model ({'; '.join(log)})")
                continue
            bad += 1
            sh = best_shift(got, want)
            print(f"{d.name} {f}: {len(diff)} pixels differ, first at {diff[0]}; best shift dx={sh[1]} dy={sh[2]} "
                  f"leaves {sh[0]} of {((H - 8) // 3 + 1) * ((W - 32) // 3 + 1)} samples")
            # by layer: the top two bits of the palette index say which layer won (tx 0, fg 1, bg 2, sprite 3)
            wpen, _ = rm.render(gfx, rm.words(d / f"{f}_vram.bin"), rm.words(d / f"{f}_palette.bin"),
                                rm.words(d / f"{f}_spriteram.bin"), rm.words(d / f"{f}_scroll.bin")[0], index=True)
            names = ("tx", "fg", "bg", "spr")
            for dx in range(-3, 4):
                cnt = [[0, 0] for _ in range(4)]
                for y in range(H):
                    for x in range(4, W - 4):
                        lw = wpen[y][x + dx] >> 11
                        cnt[lw][0] += 1
                        cnt[lw][1] += gpen[y][x] == wpen[y][x + dx]
                print(f"    dx={dx:+d} " + "  ".join(f"{names[i]} {c[1]}/{c[0]}" for i, c in enumerate(cnt)))
            from PIL import Image
            img = Image.new("RGB", (W, H)); img.putdata([p for row in got for p in row]); img.save(work / f"{d.name}_{f}_rtl.png")
    print("PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
