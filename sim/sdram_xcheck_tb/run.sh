#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# np_sdram_model against Micron's model under jtframe_sdram64 (tb_sdram_xcheck.v).
#
#   bash sim/sdram_xcheck_tb/run.sh [ms] [load%]  # from the repository root; 4 ms, 35%
#
# iverilog from MSYS2 MinGW64; work files in a temporary directory.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MSYS=${MSYS2_ROOT:-E:/msys64}
export PATH="$(cygpath -u "$MSYS")/mingw64/bin:$PATH"   # a drive letter's colon would split PATH
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
for b in 0 1 2 3; do head -c 8388608 /dev/urandom > sdram_bank$b.bin; done
iverilog -g2012 -DSIMULATION -o sim -s tb_sdram_xcheck \
    "$REPO/sim/sdram_xcheck_tb/tb_sdram_xcheck.v" "$REPO"/rtl/jtframe/jtframe_sdram64*.v \
    "$REPO/sim/models/mt48lc16m16a2.v" "$REPO/sim/models/np_sdram_model.v" || exit 1
B="+sdram_be"
for b in 0 1 2 3; do B="$B +sdram_bank$b=sdram_bank$b.bin"; done
vvp -n sim -none +ms=${1:-4} +load=${2:-35} $B > sim.log 2>&1
mkdir -p "$REPO/obj_verilator"; cp sim.log "$REPO/obj_verilator/sdram_xcheck.log"
grep -E "PASS|FAIL|MISMATCH|MISSED|DATA ERROR|SHORT|SDRAM ERROR" sim.log | head -30
echo "Micron model errors: $(grep -c "ERROR:" sim.log)"
grep "ERROR:" sim.log | sed "s/at time *[0-9.]* ns//" | sort | uniq -c | head
