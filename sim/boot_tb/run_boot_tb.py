#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""ROADMAP Phase 0, exit criterion 2: np_main's boot against MAME's, access for access.

    python sim/boot_tb/run_boot_tb.py <set> [--n 200000]

Makes what sim/boot_tb/tb_boot.sv needs and compares its trace with MAME's:
  1. MAME's trace, debug/<set>-boot/<set>_boot.trace (scripts/mame_boot_trace.py), if
     missing or shorter than --n
  2. the I/O replay from it (scripts/compare_boot_trace.py replay)
  3. bank 0 as the loader leaves it (scripts/sdram_model.py --out)
  4. the bench in Verilator, writing debug/<set>-boot/<set>_rtl.trace
  5. scripts/compare_boot_trace.py compare
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def run(cmd, **kw):
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, **kw)
    return r.returncode, (r.stdout + r.stderr).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--n", type=int, default=200000)
    a = ap.parse_args()
    g, py = a.set, sys.executable
    base = REPO / "debug" / f"{g}-boot"
    mtrace = base / f"{g}_boot.trace"
    have = 0
    if mtrace.exists():
        with open(mtrace, encoding="utf8") as f:
            have = sum(1 for ln in f if ln[:1].isdigit())
    if have < a.n:
        rc, out = run([py, "scripts/mame_boot_trace.py", g, str(a.n)])
        print(out.splitlines()[-1] if out else "")
    rc, out = run([py, "scripts/compare_boot_trace.py", "replay", g])
    print(out)
    banks = REPO / "obj_verilator" / "boot_tb_run"
    rc, out = run([py, "scripts/sdram_model.py", g, "--out", str(banks)])
    if rc:
        print(out)
        return 1
    plus = [f"+bank0={(banks / g / 'bank0.bin').as_posix()}",
            f"+replay={(base / f'{g}_replay.txt').as_posix()}",
            f"+trace={(base / f'{g}_rtl.trace').as_posix()}", f"+n={a.n}"]
    if g == "genix":
        plus.append("+genix")
    # shutil.which: a bare "bash" makes Windows run System32's, which is WSL's
    rc, out = run([shutil.which("bash"), "scripts/run_verilator.sh", "boot_tb", *plus])
    lines = [ln for ln in out.splitlines() if ln.startswith(("DONE", "ERROR", "NOTE", "VEC", "%Error", "%Warning-"))]
    print("\n".join(lines[-15:]) if lines else out[-3000:])
    if not any(ln.startswith("DONE") for ln in lines):
        return 1
    rc, out = run([py, "scripts/compare_boot_trace.py", "compare", g])
    print(out)
    return rc


if __name__ == "__main__":
    sys.exit(main())
