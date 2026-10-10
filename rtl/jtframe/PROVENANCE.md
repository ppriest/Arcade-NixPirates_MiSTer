# jtframe modules provenance

From jotego's jtcores, `modules/jtframe/hdl/`, GPL-3.0-or-later (SPDX headers in each file). Taken
from the local checkout `E:/jtcores` (github.com/ppriest/jtcores, a fork of
github.com/jotego/jtcores), branch `master` at `18d1ae7468428a7c94e2790c65f5392acb6de6e6`. No commit
by the fork's owner touches these files; their last upstream changes are jotego's `09d4e7637`
(`jtframe_68kdtack_cen.v`), `3278a82b9` and the commits in the table, all his. **Verbatim.**

| file | upstream path | SHA-1 | used for |
|---|---|---|---|
| `jtframe_68kdtack_cen.v` | `hdl/cpu/` | `ab6bfc87396e933a7c9787d634045f7ed12b2c94` | fx68k clock enables at 16 MHz from 48 MHz, DTACK, repaying clocks withheld for SDRAM waits |
| `jtframe_freqinfo.v` | `hdl/clocking/` | `23577c4a2fa8538af6337f6dc2f7e924c1fd6199` | pulled in by `jtframe_68kdtack_cen` (delivered CPU frequency) |
| `jtframe_bcd_cnt.v` | `hdl/` | `b2df7b7a99f0b743b859c22bcab09fc5bce146e6` | pulled in by `jtframe_freqinfo` |
| `jtframe_sdram64.v` | `hdl/sdram/` | `12857403a243b1fd52f72ba2a51c0aec008de9e2` | SDRAM controller, four banks, prog port |
| `jtframe_sdram64_bank.v` | `hdl/sdram/` | `d880e191521fbd5b4d8b643c0a2d2daabc868989` | per-bank state machine |
| `jtframe_sdram64_init.v` | `hdl/sdram/` | `911a8d46c97abad4c2ea13b0abcaa073c4854783` | power-up sequence |
| `jtframe_sdram64_latch.v` | `hdl/sdram/` | `97f3df6097e65bfbfaa753a9d7f4b217fc92ba05` | request latching |
| `jtframe_sdram64_rfsh.v` | `hdl/sdram/` | `9d78756191d11e47b825915c17c6a419cf6ed3e0` | refresh |
| `jtframe_rom_1slot.v` | `hdl/sdram/` | `4b0d1ca555dccc6eee21b302a7509f2d58206963` | program-ROM slot on bank 0 (last change `164d75524`) |
| `jtframe_rom_2slots.v` | `hdl/sdram/` | `1a3618cd71ce84acd8838bfe506c25c7264457d3` | under `jtframe_rom_1slot` |
| `jtframe_romrq.v` | `hdl/sdram/` | `af44169108b9375aacdc8fa553884812935a76bb` | slot requester; `CACHE_LARGE` selects the line cache (`4cdfe8172`) |
| `jtframe_romrq_lcache.v` | `hdl/sdram/` | `ad60eade5abe669bdd28f5625d574b97ba4fde95` | direct-mapped cache, one line per `jtframe_sdram64` burst (`d91503fa7`) |
| `jtframe_romrq_bcache.v` | `hdl/sdram/` | `6693b07b7aaa5a391f9cd978312f679dace3a422` | `jtframe_romrq`'s other branch (`881576a82`) |
| `jtframe_romrq_xscache.v` | `hdl/sdram/` | `771e838d712a05acc0cf4f13dae37acb6fd8a14f` | `jtframe_romrq`'s other branch (`881576a82`) |
| `jtframe_ramslot_ctrl.v` | `hdl/sdram/` | `32216843fc4713f1a9dbfd436a7092cd352af2b8` | slot to bank: `rd` held until `ack` |
| `jtframe_rpwp_ram.v` | `hdl/ram/` | `29e9f5e5412b6bb0f01b79ed3109eaea05e7f51c` | the cache's data RAM |
| `jtframe_dual_ram.v` | `hdl/ram/` | `a397db9e69abb6f01029636b1277c472309785fa` | the cache's tag RAM (`TAG_RAM=1`) |
| `jtframe_rom_3slots.v` | `hdl/sdram/` | `fe52abfad10a0e68d652b0459e2f1ffd9f9fa3dd` | the three tile layers' slots on bank 1 (`164d75524`) |
| `jtframe_scroll.v` | `hdl/video/tilemap/` | `e9d10d1a723c6466959fd6d69664f4863f1cf48d` | tile layer (bg, fg, tx) |
| `jtframe_scroll_offset.v` | `hdl/video/tilemap/` | `896c26a9f66ae677c7a84ebad05cc3d77e3344a6` | under `jtframe_scroll` |
| `jtframe_tilemap.v` | `hdl/video/tilemap/` | `96c38c350cdd0eeb36043df84620e70c7db4903e` | under `jtframe_scroll` |
| `jtframe_objdraw.v` | `hdl/video/` | `01719d3757771cc282c6ac3c7c57702223445f03` | sprites |
| `jtframe_objdraw_gate.v` | `hdl/video/` | `1b3f642ada871928f960816746598d99a2dd84d8` | under `jtframe_objdraw` |
| `jtframe_draw.v` | `hdl/video/` | `b255da877208ffb2002c1abad329f6d96d8c1dad` | under `jtframe_objdraw_gate`; last changed by "niknak" in jtcores (`3f0e80b34`) |
| `jtframe_obj_buffer.v` | `hdl/ram/` | `29ba16299c7fb48e065858c95c0a868ae935cc4e` | sprite double line buffer |
| `jtframe_sh.v` | `hdl/` | `fefd4f2290ffc908c56d214d2fdd7d94f9a28fd7` | under `jtframe_objdraw_gate` |

`jtframe_68kdtack_cen` takes `MFREQ` from the `JTFRAME_MCLK` macro by default; this core passes
`MFREQ=48000` explicitly or defines `JTFRAME_MCLK=48000000`.

## Upstream tests, on arrival

`bash sim/upstream/run_jtframe_tests.sh` compiles jtcores' own benches against these copies with
iverilog (MSYS2 MinGW64), Micron's model (`sim/models/`) for the SDRAM:

| test | upstream bench | configuration | result |
|---|---|---|---|
| `68kdtack_cen` | `ver/cpu/68kdtack_cen` | as `simunit.sh`, `JTFRAME_MCLK=48000000` | PASS |
| `rw_default` | `ver/sdram/sdram_bank64/rw_test` | `sim.sh` defaults, `-mister`, 20.833 ns | PASS |
| `rw_short` | same | `short.sh` (`-len 0 32 -len 1 16`), `-mister`, 20.833 ns | PASS |
| `rw_long_90`, `rw_long_99` | same | two corners of `long.sh`'s matrix, `-mister`, 20.833 ns | PASS |
| `prog_test` | `ver/sdram/sdram_bank64/prog_test` | `sim.sh` defaults, 20.833 ns | PASS |
| `romrq_lcache` | `ver/sdram/romrq_lcache` | as `simunit.sh` | PASS |
| `romrq_interface` | `ver/sdram/romrq_interface` | as `simunit.sh` (its own 100 MHz clock), through `jtframe_sdram64` and Micron's model | PASS |

The runner reorders upstream's command lines only: options before file names, which MSYS2's
iverilog requires.

## Facts worth not rediscovering

- **Bank priority is fixed** with `BAPRIO=1` (the default): bank 0 first, bank 3 last
  (`jtframe_sdram64.v`, the `bg` case). `rw_test` with `-Ptest.IDLE=0`, every bank requesting
  on every cycle (not one of upstream's configurations), fails with "Bank 3 stall without any
  access": bank 3 starves under saturation. This core's banks are ordered by what a stall costs
  (ROADMAP, Memory plan), and its estimated load is well under saturation.
- `rw_test` and `prog_test` read `sdram_bank{0..3}.bin` from the working directory.
- jotego's `881576a82` introduced the large cache for 68000 cores, "This allows the M68000 to run
  on time even at 16MHz on a 48MHz SDRAM". `sim/boot_tb` on this core: 16 KB, `TAG_RAM=1`, bank
  stand-in at 4-11 clocks, 2M accesses at nominal 16 MHz to one clock.
- `scripts/cache_model.py` sized it on MAME's own fetch stream: 16 KB of 8-byte lines hits 99.65%
  (pirates) and 99.42% (genix) over the first 2M accesses; 4 KB hits 99.49% and 98.90%.
- The video modules are taken from jtcores, not from Arcade-KonamiGX_MiSTer's copies: those carry
  GX-only changes (5 bpp, first-pixel zoom, two pixels a clock) this board does not need.
- `jtframe_objdraw`'s `HFIX` assumes an hdump that runs on to 511 through blanking; with this
  core's 384-pixel line it is off (`rtl/np_video.sv`).
- `jtframe_tilemap` fetches a tile when bit 3 of its map x changes; an hdump that jumps by 384 at
  the line start can skip the first visible tile's fetch. `rtl/np_video.sv` counts the layers'
  hdump on modulo 512 through the end of blanking.
