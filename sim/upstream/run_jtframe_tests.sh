#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Upstream's own tests for the vendored jtframe modules (rtl/jtframe/PROVENANCE.md),
# compiled against the vendored copies, at this core's 48 MHz.
#
#   bash sim/upstream/run_jtframe_tests.sh            # from the repository root
#
# The test benches are jtcores' own, read from JTCORES (default E:/jtcores) at the commit
# PROVENANCE.md records, and are not copied or edited. Each compile line is the one
# upstream's runner builds (ver/cpu/68kdtack_cen via bin/simunit.sh; ver/sdram/sdram_bank64/
# {rw_test,prog_test}/sim.sh), with the options moved before the file names: MSYS2's
# iverilog stops reading options at the first file, so upstream's order fails there.
# Prints PASS or FAIL per test; exit status is the number of failures.

set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
JTCORES=${JTCORES:-E:/jtcores}
JT=$JTCORES/modules/jtframe
MSYS=${MSYS2_ROOT:-E:/msys64}
export PATH="$(cygpath -u "$MSYS")/mingw64/bin:$PATH"   # a drive letter's colon would split PATH
RTL=$REPO/rtl/jtframe
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0

result() {  # name log pass-marker
    if grep -q "$3" "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; tail -20 "$2"; FAILS=$((FAILS + 1)); fi
}

# --- ver/cpu/68kdtack_cen: dividers at 8-16 MHz, phase ledger, waits, bus ownership
d=$WORK/68kdtack_cen; mkdir -p "$d"; cd "$d"
iverilog -g2012 -I"$JT/ver/inc" -s test -o sim -D SIMULATION -D JTFRAME_MCLK=48000000 \
    "$JT/ver/cpu/68kdtack_cen/test.v" \
    "$RTL/jtframe_68kdtack_cen.v" "$RTL/jtframe_freqinfo.v" "$RTL/jtframe_bcd_cnt.v" \
    "$JT/hdl/video/jtframe_vtimer.v" "$JT/hdl/ver/jtframe_test_clocks.v" > build.log 2>&1 \
  && vvp sim -none > sim.log 2>&1
cat build.log >> sim.log
result "68kdtack_cen" sim.log PASS

# --- ver/sdram/sdram_bank64: random reads and writes on four banks, and the prog port,
#     against Micron's command-level model, at 20.833 ns (48 MHz), MiSTer DQM constraint.
#     rw_test checks every read against the bank files and fails on a stalled bank.
sdram_test() {  # name testdir extra-rtl defines...
    local name=$1 tdir=$2 extra=$3; shift 3
    local d=$WORK/$name; mkdir -p "$d"; cd "$d"
    for b in 0 1 2 3; do head -c 8388608 /dev/urandom > sdram_bank$b.bin; done
    iverilog -o sim -DJTFRAME_SDRAM_test.BANKS -DSIMULATION -DSDRAM_SHIFT=0 -DPERIOD=20.833 "$@" \
        "$JT/ver/sdram/sdram_bank64/$tdir/test.v" "$RTL"/jtframe_sdram64*.v $extra \
        "$REPO/sim/models/mt48lc16m16a2.v" > build.log 2>&1 \
      && vvp sim -none > sim.log 2>&1
    cat build.log >> sim.log
    result "$name" sim.log PASSED
}
M="-DSIM_TIME=5_000_000 -DMISTER -DJTFRAME_SDRAM_ADQM"
# rw_test/sim.sh defaults (IDLE 80)
sdram_test rw_default       rw_test "" $M
# rw_test/short.sh: -len 0 32 -len 1 16
sdram_test rw_short         rw_test "" $M -Ptest.BA0_LEN=32 -Ptest.BA1_LEN=16
# corners of rw_test/long.sh's matrix: -idle 90|99, bank lengths 16-64, -prech 0
sdram_test rw_long_90       rw_test "" $M -Ptest.IDLE=90 -Ptest.BA0_AUTOPRECH=1
sdram_test rw_long_99       rw_test "" $M -Ptest.IDLE=99 -Ptest.BA0_LEN=16 -Ptest.BA1_LEN=32 \
                                          -Ptest.BA0_AUTOPRECH=1
# prog_test/sim.sh also compiles jtframe_dwnld: a test dependency, not vendored
sdram_test prog_test        prog_test "$JT/hdl/sdram/jtframe_dwnld.v"

# --- simunit benches (bin/simunit.sh's compile line): the program-ROM cache.
#     Their clocks are their own (romrq_interface runs at 100 MHz).
simunit_test() {  # name upstream-dir vendored-files...
    local name=$1 tdir=$2; shift 2
    local d=$WORK/$name; mkdir -p "$d"; cd "$d"
    iverilog -g2012 -I"$JT/ver/inc" -s test -o sim -D SIMULATION -D JTFRAME_MCLK=48000000 \
        "$JT/ver/$tdir/test.v" "$@" \
        "$JT/hdl/video/jtframe_vtimer.v" "$JT/hdl/ver/jtframe_test_clocks.v" > build.log 2>&1 \
      && vvp sim -none > sim.log 2>&1
    cat build.log >> sim.log
    result "$name" sim.log PASS
}
simunit_test romrq_lcache    sdram/romrq_lcache    "$RTL/jtframe_romrq_lcache.v" "$RTL/jtframe_rpwp_ram.v"
simunit_test romrq_interface sdram/romrq_interface "$RTL/jtframe_romrq.v" "$RTL/jtframe_romrq_bcache.v" \
    "$RTL/jtframe_romrq_lcache.v" "$RTL/jtframe_rpwp_ram.v" "$RTL"/jtframe_sdram64*.v \
    "$REPO/sim/models/mt48lc16m16a2.v"

exit $FAILS
