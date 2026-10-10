#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""np_rom_loader through jtframe_sdram64 and Micron's model, on a sample of each set's bytes.

    python sim/loader_sdram_tb/run_loader_sdram_tb.py [<set> ...] [--random N]

The full-image check is sim/loader_tb (a stand-in for the prog port); this one puts the
production controller in the path (LESSONS_LEARNED, "Re-run the failing case with the
production transport"). Per region of the download image: offset 0, every offset with one
address bit set, and N random offsets (default 64). Expected values come from
scripts/sdram_model.py sdram_from_regions() (MAME's decryption loops) at the destination
loader_map() gives; the bench also fails on any lane written outside that list.
iverilog (MSYS2 MinGW64); work files in obj_verilator/loader_sdram_tb_run/.
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import build_mra      # noqa: E402
import sdram_model    # noqa: E402


def sample(dl, nrand, seed):
    rnd = random.Random(seed)
    spans = [(dl["DL_PRG"], dl["DL_TILES"]), (dl["DL_TILES"], dl["DL_SPRITES"]),
             (dl["DL_SPRITES"], dl["DL_OKI"]), (dl["DL_OKI"], dl["DL_END"])]
    out = set()
    for lo, hi in spans:
        size = hi - lo
        out.add(lo)
        out.update(lo + (1 << b) for b in range(size.bit_length()) if (1 << b) < size)
        out.update(lo + rnd.randrange(size) for _ in range(nrand))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--random", type=int, default=64)
    a = ap.parse_args()
    work = REPO / "obj_verilator" / "loader_sdram_tb_run"
    work.mkdir(parents=True, exist_ok=True)
    msys = Path(os.environ.get("MSYS2_ROOT", "E:/msys64")) / "mingw64" / "bin"
    env = dict(os.environ, PATH=str(msys) + os.pathsep + os.environ["PATH"])
    sim = work / "sim.vvp"
    r = subprocess.run([str(msys / "iverilog.exe"), "-g2012", "-I", str(REPO / "rtl"), "-o", str(sim),
                        "-s", "tb_loader_sdram",
                        str(REPO / "sim/loader_sdram_tb/tb_loader_sdram.sv"),
                        str(REPO / "rtl/np_rom_loader.sv"),
                        *[str(p) for p in sorted((REPO / "rtl/jtframe").glob("jtframe_sdram64*.v"))],
                        str(REPO / "sim/models/mt48lc16m16a2.v")],
                       capture_output=True, text=True, env=env)
    if r.returncode:
        print(r.stdout + r.stderr)
        return 1
    dl = build_mra.rom_map()
    bad = 0
    for g in a.sets or list(build_mra.SETS):
        img = build_mra.build(g, dl, write=False)
        banks = sdram_model.sdram_from_regions(sdram_model.decrypted(g))
        offs = sample(dl, a.random, g)
        bytes_f, expect_f = work / f"{g}_bytes.txt", work / f"{g}_expect.txt"
        bytes_f.write_text("".join(f"{i:06x} {img[i]:02x}\n" for i in offs))
        lines = []
        for i in offs:
            b, w, lane, _ = sdram_model.loader_map(i, img[i], dl)
            lines.append(f"{b} {w:06x} {lane} {banks[b][2 * w + lane]:02x}\n")
        expect_f.write_text("".join(lines))
        r = subprocess.run([str(msys / "vvp.exe"), "-n", str(sim), "-none",
                            f"+bytes={bytes_f.as_posix()}", f"+expect={expect_f.as_posix()}"],
                           cwd=work, capture_output=True, text=True, env=env)
        out = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.startswith(("PASS", "FAIL", "ERROR"))]
        print(f"{g}: " + ("\n  ".join(out) if out else (r.stdout + r.stderr)[-2000:]))
        bad += not any(ln.startswith("PASS") for ln in out)
    print("PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
