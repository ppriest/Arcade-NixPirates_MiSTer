# Simulation models provenance

| file | source | SHA-1 | licence |
|---|---|---|---|
| `mt48lc16m16a2.v` | Micron's MT48LC16M16A2 bus-functional model v2.1, as adapted in jotego's jtcores `modules/jtframe/hdl/ver/mt48lc16m16a2.v` (extra `downloading`, `VS`, `frame_cnt` ports and bank-file loading), `E:/jtcores` `master` at `18d1ae7468428a7c94e2790c65f5392acb6de6e6` | `ab1bb7eaf912f156aad9d0b30893e349b3e3af4c` | "Copyright 2001 Micron Semiconductor Products, Inc. All rights reserved", provided as is (its header); simulation only, never in `files.qip` |

Verbatim. A command-decoding model, so a controller's timing faults and DQM use show
(LESSONS_LEARNED, "Verify a burst extension against a command-decoding chip model").

`np_sdram_model.v` is this core's own (GPL-3.0-or-later): a cycle-based MT48LC16M16 for Verilator,
where Micron's model does not run. `bash sim/sdram_xcheck_tb/run.sh` runs it beside Micron's on
the pins of one `jtframe_sdram64` at 48 MHz under random reads and writes on four banks, with a
quiet window at each line start: PASS, 89,939 words driven and compared over 4 ms, 0 mismatches,
0 missed, 0 timing errors from either model.

Without the quiet window (requests at 35% or 70% a clock on every bank), `jtframe_sdram64` defers
refresh until its debt forces it after eight lines, and Micron's model stops on tRAS-max (a row
open 407 us against 120 us). Refresh still totals 8192 in 64 ms; a core's own load decides
whether the window exists, which is measured with the video.
