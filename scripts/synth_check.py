#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile a standalone block from rtl/synth_check/<name>/ and report Fmax and area.

    python scripts/synth_check.py [np_cpu] [--seed N]

The block's .qpf/.qsf/.sdc and top live in rtl/synth_check/<name>/. The compile runs in
obj_synth/<name>/ on rtl/ as committed at HEAD (git archive), never on the working tree, and
refuses when rtl/ has uncommitted changes, so a number always belongs to a commit. Like
scripts/build_staged.py it will not start while a JTAG session holds or waits for the
Blaster (scripts/hwlock.py). Prints each clock's setup and hold slack, the Fmax summary and
the fit's resource totals, and writes obj_synth/<name>/RESULT.txt.
"""
import argparse
import io
import re
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import quartus_bin  # noqa: E402
from hwlock import require_no_jtag  # noqa: E402


def git(*args):
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, check=True).stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name", nargs="?", default="np_cpu")
    ap.add_argument("--seed", type=int)
    a = ap.parse_args()
    src = REPO / "rtl" / "synth_check" / a.name
    if not src.is_dir():
        sys.exit(f"no {src}")
    if git("status", "--porcelain", "--", "rtl").strip():
        sys.exit("rtl/ has uncommitted changes: commit first, the result must belong to a commit")
    head = git("rev-parse", "--short", "HEAD").decode().strip()

    out = REPO / "obj_synth" / a.name
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    tarfile.open(fileobj=io.BytesIO(git("archive", "--format=tar", "HEAD", "rtl")), mode="r").extractall(out)
    qpf = next(src.glob("*.qpf"))
    rev = qpf.stem
    for f in src.glob(f"{rev}.*"):
        if f.suffix in (".qpf", ".qsf", ".sdc"):
            shutil.copy2(out / "rtl" / "synth_check" / a.name / f.name, out / f.name)
    if a.seed is not None:
        q = out / f"{rev}.qsf"
        q.write_text(re.sub(r"(?m)^set_global_assignment -name SEED \d+", f"set_global_assignment -name SEED {a.seed}",
                            q.read_text()))

    require_no_jtag(f"synth_check {a.name}")
    qb = Path(quartus_bin())
    print(f"compiling {rev} at {head} in {out.relative_to(REPO)} ...", flush=True)
    t0 = time.time()
    with open(out / "compile.log", "w") as log:
        r = subprocess.run([str(qb / "quartus_sh"), "--flow", "compile", rev], cwd=out, stdout=log,
                           stderr=subprocess.STDOUT)
    mins = (time.time() - t0) / 60
    if r.returncode:
        tail = (out / "compile.log").read_text(errors="replace").splitlines()[-30:]
        sys.exit("compile failed:\n" + "\n".join(ln for ln in tail if "Error" in ln or "error" in ln))

    of = out / "output_files"
    lines = [f"{rev} at {head}, {mins:.1f} min"]
    sta = (of / f"{rev}.sta.summary").read_text(errors="replace")
    for blk in re.findall(r"Type\s*:\s*(.*?)\nSlack\s*:\s*(\S+)\nTNS\s*:\s*(\S+)", sta):
        lines.append(f"  {blk[0].strip():45s} slack {blk[1]:>8s}  TNS {blk[2]}")
    rpt = (of / f"{rev}.sta.rpt").read_text(errors="replace")
    # the table, not the report's contents list ("6. Fmax Summary")
    m = re.search(r"\n; Fmax Summary.*?\n(.*?)\nThis panel", rpt, re.S)
    if m:
        for ln in m.group(1).splitlines():
            if "MHz" in ln and ";" in ln:
                cells = [c.strip() for c in ln.split(";") if c.strip()]
                lines.append("  Fmax " + "  ".join(cells))
    fit = (of / f"{rev}.fit.summary").read_text(errors="replace")
    for key in ("Logic utilization", "Total registers", "Total block memory bits", "Total RAM Blocks",
                "Total DSP Blocks"):
        m = re.search(re.escape(key) + r"[^:]*:\s*(.*)", fit)
        if m:
            lines.append(f"  {key}: {m.group(1).strip()}")
    text = "\n".join(lines)
    (out / "RESULT.txt").write_text(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
