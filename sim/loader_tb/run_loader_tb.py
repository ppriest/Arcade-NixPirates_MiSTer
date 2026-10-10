#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""ROADMAP Phase 0, exit criterion 5: np_rom_loader's SDRAM image equals the model's.

    python sim/loader_tb/run_loader_tb.py [<set> ...]        # default: every set

For each set: the .mra's download image (scripts/build_mra.py), streamed through
rtl/np_rom_loader.sv in Verilator (sim/loader_tb/tb_loader.sv); the four banks it
leaves are compared word for word with scripts/sdram_model.py's sdram_from_regions(),
which is built from MAME's decryption loops, not from the loader's mapping.
Work files in obj_verilator/loader_tb_run/.
"""
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import build_mra      # noqa: E402
import sdram_model    # noqa: E402


def main():
    sets = sys.argv[1:] or list(build_mra.SETS)
    work = REPO / "obj_verilator" / "loader_tb_run"
    work.mkdir(parents=True, exist_ok=True)
    dl = build_mra.rom_map()
    bad = 0
    for g in sets:
        img = build_mra.build(g, dl, write=False)
        image = work / f"{g}.bin"
        image.write_bytes(img)
        # shutil.which: a bare "bash" makes Windows run System32's, which is WSL's
        r = subprocess.run([shutil.which("bash"), "scripts/run_verilator.sh", "loader_tb",
                            f"+image={image.as_posix()}", f"+out={(work / g).as_posix()}_"],
                           cwd=REPO, capture_output=True, text=True)
        log = (r.stdout + r.stderr).strip()
        tail = [ln for ln in log.splitlines() if ln.startswith(("DONE", "FAIL", "ERROR", "%Error"))]
        print(f"{g}: " + ("; ".join(tail) if tail else log[-2000:]))
        if not any(ln.startswith("DONE") for ln in tail):
            bad += 1
            continue
        want = sdram_model.sdram_from_regions(sdram_model.decrypted(g))
        for b in range(4):
            got = (work / f"{g}_bank{b}.bin").read_bytes()
            if got == bytes(want[b]):
                print(f"  bank {b}: equal ({len(got)} bytes)")
            else:
                k = next(i for i in range(len(got)) if got[i] != want[b][i])
                print(f"  bank {b}: DIFFERS from word 0x{k // 2:x} lane {k & 1}: "
                      f"got {got[k]:02x}, model {want[b][k]:02x}")
                bad += 1
    print("PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
