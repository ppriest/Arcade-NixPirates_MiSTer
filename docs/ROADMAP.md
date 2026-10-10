# NIX Pirates hardware — MiSTer Core Roadmap

**Approved, with `jtframe_sdram64` as the SDRAM controller and the recommendations below as
written. A phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for the NIX board of Pirates and Genix Family, emulated by MAME's
`src/mame/nix/pirates.cpp` and the devices it instantiates (`cpu/m68000`, `machine/eepromser`,
`sound/okim6295`) — a Quartus 17.0.2 SystemVerilog project producing one `.rbf` and a `.mra` per
supported set, reusing proven open components where they exist.

Every chip but the video has tested open RTL: the 68000 (fx68k, in three sibling cores), the
M6295 (jt6295, in Fuuki and Vamphalf) and the 93C46 (jotego's jt5911). The video is four
undocumented Altera EPM7064 CPLDs and is written from MAME's model on standard engines. New work:

1. The video: three 8x8 tilemaps and a 255-entry 16x16 sprite list, from `pirates.cpp` 186-285,
   on jtframe_scroll and jtframe_objdraw.
2. The ROM loader's decryption: four address-and-data scrambles, already modelled and checked
   byte for byte against MAME (`scripts/decrypt_model.py`).
3. MAME's two protection kludges, per set.

Facts and their sources are in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md). Cross-cutting findings
from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**; working practice is
in **[`WORKFLOW.md`](WORKFLOW.md)**.

## Progress

**Phase 0 is under way: modules vendored and their upstream tests passing, the ROM loader done
(criterion 5 met), the 68000 booting both games against MAME's trace (criterion 2 met to the
first interrupt fx68k takes an instruction later than MAME). Fmax (criterion 4) and CPI with the
real controller (criterion 3) are open.**

- Repository bootstrapped from Template_MiSTer (`NixPirates`, `NixPirates_stp`).
- `scripts/mame/regions.json` transcribed from `prg_map` (340-359).
- Video-write sweep, attract and play, three sets: `docs/write_timing_mame.txt`.
- Sprites per line, attract and play: max 52 (`scripts/sprite_load.py`).
- Address census from power-on, attract and play: `scripts/mem_scan.py` (HARDWARE_NOTES, "Memory map").
- Attribute-word census: `scripts/attr_census.py` (HARDWARE_NOTES, "Video").
- Decryption model, gather and load-time scatter, equal to MAME's regions for 3 of 3 sets.
- `.mra` files for 3 of 3 sets (`scripts/build_mra.py`): each image equal to the ROM_START build,
  to `-listxml`'s and to mra.py's re-read; `validate_mra.py` passes all three. Layout
  `rtl/np_rom_map.svh`.
- fx68k, `jtframe_68kdtack_cen`, `jtframe_sdram64` vendored; jtcores' own benches against the
  copies at 48 MHz, 6 of 6 PASS (`sim/upstream/run_jtframe_tests.sh`, `rtl/jtframe/PROVENANCE.md`).
- `rtl/np_rom_loader.sv`: download to SDRAM, decrypted, in the formats of `rtl/np_sdram_map.svh`;
  permutations generated from the model (`rtl/np_decrypt.svh`).
- `rtl/np_main.sv`: fx68k, `jtframe_68kdtack_cen`, the memory map, RAMs, IRQ1, MAME's protection
  kludges. Program ROM through jtframe's ROM slot and line cache (`jtframe_rom_1slot`,
  `CACHE0_LARGE`, 16 KB): jotego's stack for a 16 MHz 68000 on 48 MHz SDRAM (`881576a82`).

## Game scope

| Set | Game | Board | Loaded | MAME |
|---|---|---|---|---|
| `pirates` | Pirates (set 1) | `pirates` config, `init_pirates` | prog 1 MB, tiles 2 MB, sprites 2 MB, OKI 512 KB | good |
| `piratesb` | Pirates (set 2), clone | same | same sizes; own program, one sprite ROM 1 bit different | good |
| `genix` | Genix Family | same, `init_genix` | prog 1 MB, tiles 1 MB, sprites 1 MB in 2 MB regions, OKI 512 KB | good |

### Scope decision

- **In scope:** all three sets. One memory map, one screen, one chipset; 5.5 MB a set against the
  32 MB module.
- **Out of the first scope:** nothing. `fitfight.cpp` (NIX's other driver) is different hardware
  (68000 plus uPD7810 sound) and is not part of this core.
- **First target:** `pirates`, the parent with the heaviest sprite load (52 a line, MAME).
- **Second target:** `genix`, the other protection kludge and the half-filled graphics regions.

## Hardware reality (from the driver, not assumption)

Line numbers are `pirates.cpp`'s. A value from the PCB notes says so.

### Chips

| Part | Clock | Source | RTL |
|---|---|---|---|
| MC68000 | 16 MHz (32 MHz / 2), "verified on PCB" | 440 | fx68k |
| OKI M6295, pin 7 low | 1.3333 MHz (24 MHz / 18), "verified on PCB" | 460 | jt6295 |
| 93C46, 16-bit | bit-banged by `out_w` | 289-294, 444 | jt5911 |
| Video: 4 x EPM7064 | unknown | PCB layout, 59-89 | from MAME's model |

### Clocks

| Clock | Rate | Derivation from `clk_sys` = 48 MHz | Exact |
|---|---|---|---|
| `clk_sys`, SDRAM | 48 MHz | PLL; SDRAM multiple 1 | |
| pixel (`ce_pix`) | 6 MHz (assumed) | every 8th clock | yes |
| 68000 | 16 MHz | 1 CPU clock per 3; fx68k phases at 2 per 3 clocks through `jtframe_68kdtack_cen` (num/den), which also repays clocks lost to SDRAM waits | yes |
| M6295 | 1.3333 MHz | every 36th clock | yes |

The pixel clock is not in the driver (no `set_raw`, 449-452). 6 MHz is the 24 MHz crystal beside
the video CPLDs divided by 4; HARDWARE_NOTES lists the alternatives. The video timing is **384 x 262
at 6 MHz: 15.625 kHz, 59.64 Hz**, against the PCB notes' 15.69 kHz and 60 Hz (87-88) and MAME's
256 lines at 60 Hz. 384 x 262 is a parameter pair; 382 x 262 (15.707 kHz, 59.95 Hz) is the other
6 MHz fit. Either goes in `docs/HACKS.md` with its error against the PCB notes when the timing
generator lands. Visible area 288 x 224 at lines 16-239, as MAME. 48 MHz is the lowest `clk_sys`
that is a multiple of 6 MHz (8x) and of 16 MHz, and above every board clock. Every candidate pixel
clock in HARDWARE_NOTES except 6.4 MHz also divides 48 MHz.

### Interrupts

Level 1 autovector (VPA in the acknowledge cycle) at vblank start, line 240, `irq1_line_hold`
(442): asserted until the CPU acknowledges, acknowledge wins. Vectors read from the decrypted ROM:
level 1 handler at `0x00bf84` (pirates) and `0x00ddf6` (genix); levels 2-7 have their own handlers
and are never raised. No interrupt enable or ack register.

### Memory map

HARDWARE_NOTES, "Memory map": ROM 1 MB, work RAM 64 KB, two input words, sprite list 2 KB
(write-only), `out_w`, scroll (write-only), palette 16 KB, tile RAM 0x900000-0x904187, M6295.
Unmapped reads return 0 and writes are ignored, as MAME. Accesses the games make outside the map
are listed there (`0x5008xx`, `0x880000`, `0x500fxx`, `0xc02000`); each stays unmapped.

### Video

- **bg, fg, tx**: 8x8 4bpp, column-major maps (64 x 32, 64 x 32, 36 x 32), code word then colour
  word. fg and bg take one X scroll (`0x700000`); tx is fixed. bg opaque, fg and tx pen 0
  transparent. Colour bases 0x000, 0x800, 0x1000 (7-bit colour field; the games never set bit 7,
  `attr_census.py`).
- **Sprites**: 16x16 4bpp, 128 colours at 0x1800, list walked from entry 1 to the first Y with bit
  15 set or entry 254; later entries over earlier ones.
- **Order**: bg, fg, sprites, tx.
- **Palette**: 8192 x xRGB_555.
- MAME emulates no flip, no Y scroll, no line scroll, no sprite priority bits.

### Sound

One M6295, mono, 8.08 kHz sample clock, two 256 KB banks by `out_w` bit 6 (297). No sound CPU.

### Protection

MAME's kludges, reproduced as MAME does them:

- `pirates`, `piratesb`: program word 0x62c0 reads `0x6006` (bra) instead of `0x6706` (618);
  SYSTEM bit 7 reads 1 (`prot_r`).
- `genix`: reads of 0x109e98 return `0x0004`, of 0x109e9a `0x0000`; writes reach work RAM (621, 632).

### Per-game configuration

The `.mra` mod byte selects the protection variant (pirates/piratesb or genix). Nothing else differs:
same map, same video, same sound.

## Component reuse map

Every row's source was located and its header or PROVENANCE read.

| block | plan | source |
|---|---|---|
| 68000 | Sibling core's fx68k, kernel instantiated directly behind our bus logic | `E:/Arcade-KonamiGX_MiSTer/rtl/cpu/fx68k` (ijor/fx68k via SegaXBoard and Seta; KonamiGX's packed structs for Verilator), GPL-3.0. Seta's and BallySente's copies looked at: Seta's lacks the Verilator fix, BallySente's keeps two revisions |
| 68000 clock enables, DTACK, stall recovery | Port `jtframe_68kdtack_cen` | `E:/jtcores` (ppriest/jtcores fork of jotego/jtcores) `modules/jtframe/hdl/cpu/jtframe_68kdtack_cen.v`, last changed `09d4e7637` (Jose Tejada), GPL-3.0-or-later. Seta's `maincpu.sv` looked at: integer clocks a phase only, and 16 MHz from 48 MHz needs 1.5 |
| SDRAM controller | Port `jtframe_sdram64` and its bank, init, latch and refresh files (approved) | `E:/jtcores` `modules/jtframe/hdl/sdram/`, `3278a82b9`, GPL-3.0-or-later. Not taken: Seta's Sorgelig-derived `sdram.sv` stack (`E:/Arcade-Seta_MiSTer/rtl/memory/sdram`, PROVENANCE read), one bank in flight at a time |
| ROM loading, DDR3 at load time | MS32's byte-replay loader, so the decrypting scatter is one path | `E:/Arcade-JalecoMS32_MiSTer/rtl/memory/ms32_rom_loader.sv` and `ddram_phy.sv` (skill `ddr_rom_loading.md`) |
| Decryption | Written from MAME, address and data wiring | `scripts/decrypt_model.py`, checked against MAME |
| M6295 | Sibling core's jt6295 with `sample_cache.sv` and `oki_rom_bridge.sv` | `E:/Arcade-Vamphalf_MiSTer/rtl/sound` (jotego/jt6295 `7d76b0be` via Fuuki), GPL-3.0 |
| 93C46 | Port jt5911 | `E:/jtcores/modules/jteeprom/hdl/jt5911.sv`, GPL-3.0-or-later; external memory port, so the contents can be saved to SD |
| Tilemaps | Port jtframe_scroll (+ `jtframe_scroll_offset`), one per layer, MAME's map addressing outside it | `E:/jtcores` `modules/jtframe/hdl/video/tilemap/`, `3278a82b9`, GPL-3.0-or-later; takes 8x8 4bpp as four plane bytes, which the loader's scatter produces. Psikyo/Fuuki `tilemap_line_engine` looked at: built for 16x16 and their VRAM formats |
| Sprites | Sibling core's jtframe_objdraw, objdraw_gate, draw, obj_buffer, local changes at their defaults | `E:/Arcade-KonamiGX_MiSTer/rtl/jtframe` (jotego/jtcores `e7958c86`), GPL-3.0-or-later |
| Sprite list scan, mixer, video timing | From scratch, MAME as spec | `pirates.cpp` 247-285 |
| CRT Adjust | Sibling core's | rmonic79 `crt_adjust.sv`, via Fuuki |
| High scores | Sibling core's | `E:/Arcade-KonamiGX_MiSTer/rtl/hiscore` (JimmyStones/Hiscores_MiSTer) |
| Pause | Sibling core's | `E:/Arcade-Fuuki_MiSTer/rtl/pause_control.sv` |
| Debug probe, counters, tracer | Sibling core's | Seta `rtl/debug/` |
| Template, `sys/` | as cloned | MiSTer-devel/Template_MiSTer, GPL-2.0-or-later |

No other MiSTer core or jtcores core implements this board: `E:/jtcores/cores` has none, and
MiSTer-MAME-Coverage `docs/data/coverage.json` lists `pirates` and `genix` with `"covered": false`
and no cores. Licence: GPL-3.0-or-later, from fx68k, jt6295 and jtframe.

## On-chip RAM budget

M10K blocks of the 5CSEBA6's 553, at the width each is read. Framework baseline measured at the
first build.

| Memory | Size | Ports | M10K |
|---|---|---|---|
| Work RAM | 32K x 16 | CPU | 64 |
| Palette | 8K x 16 | CPU, mixer | 16 |
| Tile RAM, 0x900000-0x904187 | 16K x 16 (an 8388-deep RAM was not inferred) | CPU, three layers by time slot | 32 |
| Sprite list and its snapshot | 2 x 1K x 16 | CPU / copy, scan | 4 |
| Sprite line buffers | 2 x 512 x 11 | draw, mixer | 2 |
| EEPROM | 64 x 16 | jt5911, HPS | 1 |
| fx68k micro- and nanorom | 1K x 17, 336 x 68 | CPU | ~6, to measure |
| Program-ROM cache, 16 KB, and its tags | 2048 x 64, 2048 x 9 | CPU | 20 |
| **Core total** | | | **~150 (27%)**; the CPU path alone measured 135 (`np_cpu_synth`) |

None to watch. CRT V-Size and the rotation buffers fit alongside.

## Memory plan

**ROM in SDRAM, one copy, one region per bank** (32 MB module, four 8 MB banks):

| Bank | Region | Size | Client |
|---|---|---|---|
| 0 | program | 1 MB | 68000 |
| 1 | tiles, planes interleaved per row (4 bytes a tile row) | 2 MB | bg, fg, tx |
| 2 | sprites, planes interleaved per row (8 bytes a sprite row) | 2 MB | sprite draw |
| 3 | samples | 512 KB | M6295 |

RAM is all in BRAM. DDR3 is used at load time only. The loader writes each downloaded byte to its
decrypted and plane-interleaved address; both permutations are wiring. MAME's 0x62c0 patch is
applied on the CPU read path, so the SDRAM holds the dumped ROM.

**Fetch arithmetic, per line: 384 pixels x 8 = 3072 clocks at 48 MHz.**

| Client | Per line | Words each | Source |
|---|---|---|---|
| tx | 36 tile rows | 2 | 288 / 8 |
| fg, bg | 37 tile rows each | 2 | 288 / 8 + 1 for the unaligned scroll |
| sprites | 52 sprite rows | 4 | most measured on one line, MAME |
| 68000 | at most 256 bus cycles, ROM share not measured | 1 | 16 MHz / 4 clocks a cycle / 15.625 kHz |
| M6295 | about 2 | 1 | 4 voices x 8.08 kHz / 15.625 kHz, fewer through the cache |
| refresh | about 8 | | 8192 rows / 64 ms |

Cost per access, estimated (no measurement yet): a controller with one bank open at a time takes
about 6 clocks a word read, 7 for two words and 9 for four. Totals: 770 for tiles, 468 for
sprites, 56 for refresh, and up to 1536 for the 68000 if every bus cycle read SDRAM. That is 92%
of the line in the worst case and about 73% if 60% of the CPU's cycles are ROM reads. A
controller that overlaps one bank's activate with another bank's data costs about the burst
length plus one: about 1170 clocks worst case, 38%.

**Chosen: `jtframe_sdram64` at 48 MHz, one region per bank.** jotego's Toki core runs a
68000 at 10 MHz (`toki.cpp:889`), three layers and sprites at a 6 MHz pixel clock (`toki.cpp:904`)
on it at 48 MHz: jtframe's default `JTFRAME_MCLK` is 48000000 (`macros.go:393`), and Toki's
`macros.def` sets the bank starts and not `JTFRAME_SDRAM96`. The alternative, Seta's controller,
would be the first time this family runs it at 48 MHz, and on these estimates the 68000 would wait
behind video fetches most of the time. Phase 0 measures the 68000's CPI against MAME with the
chosen controller (exit criterion 3).

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately. Each
goes in `docs/MAME_KLUDGES.md` when it is implemented, with what MAME does, what the hardware is
suspected to do, and what would settle it.

**Where a vendored module and MAME disagree, record it and keep the module.** It goes in
`docs/MAME_KLUDGES.md`, not into a "fix", until one side is shown to describe the chip.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct.

**Transcribe the reference literally first, then look for the chip.** Pixel-exact against MAME
first; experiments on an OSD switch.

**One `.rbf` for all games.** Per-set differences are `.mra` mod-byte configuration.

**Two Quartus revisions, `NixPirates_stp` and `NixPirates`,** differing only by a `DEBUG_ISSP` macro.

**Licence: GPL-3.0-or-later.** Every dependency, what it obliges and the release checklist go in
`THIRD-PARTY.md`. `sys/` is never edited.

**Per-scanline rendering from buffered sprite RAM.** The board has no frame buffer in the driver.

**No multiplies, no divides, in 2D pipelines.** Shifts, masks, adds and accumulators; WORKFLOW §14.
MAME's colour `% 384` (`tilemap.h:393`) is never reached by these games and is not built.

**The sprite list and the scroll are taken at the same point: the line before the renderer starts
line 16.** The sweep puts 98.7-100% of sprite writes and 93-100% of scroll writes in the vblank
handler. MAME draws frame N at line 240 from what that handler wrote during frame N-1's vblank,
which is what this point captures. The copy is 1K words, about a third of a line, with
write-through for any write that lands during it. Writes between that point and line 240 (under
1%, `pirates` attract only) reach the screen a frame later than in MAME: a `MAME_KLUDGES.md` entry.

**Tile RAM and palette are read live.** Both are written across the frame in attract (palette 41
writes a frame in `pirates`, 80 in `genix`). MAME draws every line at line 240 and looks the
palette up after that, so a mid-frame write shows in all of MAME's frame and only below the write
on the core. Live is what a board reading its RAM per line does and costs nothing. A queue released
at vblank (Seta's) would put the same writes a frame late instead and still not match MAME.
Comparison against MAME uses paused frames, where the two agree.

**Decryption is load-time wiring, not fetch-time.** Fetch-time decryption scatters each tile row
and splits every program word across two addresses; load-time keeps bursts.

**The core starts the EEPROM erased, as MAME, and saves it to SD.** MAME's driver says the EEPROM
"doesn't work" (11); the core reproduces the 93C46 MAME models.

## Pitfalls that already bind decisions here

| Entry | What it binds here |
|---|---|
| "[Seta] A region whose base is not aligned to its size must be indexed by subtraction, not masking" | tx, fg, bg bases at 0x180, 0x1380, 0x2a80 within tile RAM |
| "[Seta] Back the RAM a power-on test walks at the size the map declares" | tile RAM is backed whole, 0x900000-0x904187, including MAME's unused first 0x180 bytes |
| "[Seta] A snapshot is a race with whoever writes the thing being copied" | the sprite-list copy runs when the handler is quiet, with write-through |
| "[Seta] Latch the sprite list and the video registers at the same point unless evidence separates them" | the sprite list and scroll share one point; tile RAM and palette are live, for the reason above |
| "[Seta] A double buffer puts the renderer TWO lines ahead, not one" | sprite line buffers |
| "Read both halves of a mechanism before changing it: the draw loop AND the pixel op" | `transpen` overwrites, so later entries are on top; an overrun drops the last entries, which are the topmost |
| "Give a held interrupt line's acknowledge priority" | IRQ1, `irq1_line_hold` |
| "[Seta] Read the interrupt vectors before trusting a board's interrupt config" | done: only level 1 is used |
| "[MS32] A T80 waiting on SDRAM is a slow Z80: repay the lost clock enables" | 68000 behind SDRAM: `jtframe_68kdtack_cen` recovery, measured in Phase 0 |
| "DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU" | 68000 bus logic |
| "Never hold the memory path in the core reset" | SDRAM and loader |
| "Prove the interleave against MAME's disassembly offline, before building" | done for the decryption; the plane interleave is checked the same way before the loader is built |
| "[GX] A game that reads its EEPROM without writing it needs the driver's default image" | MAME has none for these sets; the core starts erased like MAME |
| "Find a ROM by its CRC, not by its filename, everywhere" | `piratesb` shares 9 parts with `pirates` under other names |

## Phased roadmap

**Phase 0 — Vendoring spike and the measurements. The gate.**

Vendor every module in the reuse map into `rtl/` with a `PROVENANCE.md` per directory. Run every
upstream testbench unchanged before editing anything. Stand the 68000, its bus logic, the SDRAM
controller and the loader up in `rtl/synth_check/` and a bench, nothing else.
Exit criteria:

1. **Every vendored module's own tests pass unchanged, on arrival.**
2. **The 68000 boots `pirates` from decrypted SDRAM and matches MAME's bus trace**
   (`scripts/mame_boot_trace.py`, `compare_boot_trace.py`), every peripheral stubbed to MAME's values.
   — Met, to the first interrupt fx68k recognises an instruction later than MAME:
   `sim/boot_tb/run_boot_tb.py`, 2,000,000 accesses a set, I/O reads replayed, IRQ1 at MAME's
   times in 68000 clocks. pirates: 183,965 writes, every non-ROM read before them and two
   interrupts identical, then the third interrupt one instruction later (MAME_KLUDGES.md,
   "Vendored modules"); genix: 179,131 writes and one interrupt. Every ROM word MAME read was
   read. Past that point the comparison is per frame (`mame_sys_trace.py`).
3. **Measured CPI on game code** against MAME's 16 MHz (`mame/mark_time.lua`), split between
   execution and SDRAM stall, with video fetch traffic running. — Partly: through the line cache
   and a bank stand-in (ack, 4-11 clocks, 4 beats), 9,754,341 68000 clocks in 29,263,026 system
   clocks over pirates' first 2M accesses, nominal 16 MHz to one clock (genix: 8,707,374 in
   26,122,123): every phase withheld for 5,098 line fills was repaid. Zero-latency ROM gives the
   same clock count to one. With `jtframe_sdram64` and `sim/models/np_sdram_model.v` in place of
   the stand-in (`-GSDRAM=1`): the same 9,754,341 clocks, the same trace, no SDRAM timing error.
   The model is checked against Micron's on one controller's pins (`sim/sdram_xcheck_tb`: 89,939
   words, 0 mismatches, 0 missed). Video traffic is measured with the video, in Phase 1.
4. **Standalone Fmax and area at 48 MHz** for the CPU and SDRAM path, the constraint committed with
   the measurement. — Met: `rtl/synth_check/np_cpu` (np_main, the ROM slot and 16 KB cache,
   np_rom_loader, jtframe_sdram64; NixPirates.qsf's settings; `np_cpu_synth.sdc`, 20.833 ns),
   `python scripts/synth_check.py np_cpu` at `5d9dd7d`: setup slack +6.679 ns, hold +0.327 ns,
   Fmax 95.98 MHz (slow 1100 mV 100 C); 4,515 ALMs (11%), 4,449 registers, 135 of 553 M10K (24%),
   no DSP. Every RAM one copy (true dual port), after three fixes to `np_dpram` (its header).
5. **The loader's SDRAM image equals `decrypt_model.py`'s for all three sets**, plane interleave
   included, in simulation from the `.mra`'s byte stream. — Met: `sim/loader_tb/run_loader_tb.py`,
   whole images through a prog-port stand-in, 12 of 12 banks equal to `sdram_model.py`'s build from
   MAME's decryption loops; `sim/loader_sdram_tb/run_loader_sdram_tb.py`, through `jtframe_sdram64`
   and Micron's model, 2131-2133 sampled bytes a set (every address bit of each region), every
   expected lane right and no other lane written, 3 of 3 sets.

**Phase 1 — Video, against a software model.**

`scripts/render_model.py` reproducing `screen_update` (279-285) from `mame_capture.py` dumps,
pixel-exact against MAME's snapshots; then RTL in Verilator against the model, layer by layer, then
whole frames. Exit criteria: `pirates` and `genix` render frames pixel-identical to MAME's for a
captured set of scenes (attract and play), silent, in simulation. - Met: `scripts/render_model.py` equals MAME on 18 of 18
captured frames (5 attract and 4 play, each game; `scripts/vid_capture.py`); `rtl/np_video.sv` in
`sim/video_tb` (jtframe_sdram64 and the SDRAM model behind the slots) equals the model on the same
18, and on one frame at 20 scroll values.

**Phase 2 — Hardware bring-up and the first games.**

SDRAM with all clients, DDR3 fast loading through the decrypting path, `.mra` generation (CRCs,
`<mameversion>`, mod byte), inputs with the games' button names, EEPROM saved to SD, the ISSP probe
and the OSD debug page. The standard feature set: CRT Adjust (and V-Size), hiscore, HDMI scaling
and crop, HDMI rotation, audio mix, HDMI-only options hidden under direct video, CRT Adjust
parameters hidden until enabled, Pause suspending the 68000, and flip screen from the OSD through
one path (the board has no flip DIP or register in MAME, so a fake DIP), worked out per layer.
No peripherals: both games are joystick and three buttons. Exit criteria: `pirates` and `genix`
boot and play on a DE10-nano, silent.

**Phase 3 — Sound.**

jt6295 at 1.3333 MHz, pin 7 low, bank bit from `out_w` bit 6, on SDRAM bank 3 through a
`jtframe_rom_1slot` (`rtl/sound/PROVENANCE.md` has the read deadline it meets). Exit
criteria: register-write traces captured from MAME reproduce correct audio, by ear and by a
decoded capture against MAME's output. - The capture half met in simulation:
`sim/sound_tb/run_sound_tb.py`, 30 s of attract, each game, the writes replayed through the real
SDRAM path; per half second of sound, correlation with MAME median 0.932 (pirates) and 0.962
(genix), level within 8%, compared by MAME's sample index because MAME's M6295 runs 100 ppm
slow (`docs/MAME_KLUDGES.md`, Sound). By ear: not yet (needs the board).

**Phase 4 — The rest of the list, and accuracy.**

`piratesb`'s `.mra` in `releases/_alternatives/_Pirates/`, every `MAME_KLUDGES.md` and `HACKS.md`
entry current, the video timing checked over direct video into a scaler.

**Phase 5 — Protection beyond MAME's patches.** Only with board evidence; MAME's own partial model
hangs (312-330, TODO 13-17). Not planned.

**Phase 6 — Savestates, state dumps and cheats.** Optional. Not before Phase 4, but every RAM
above has a port reachable for state capture from Phase 1, and `docs/STATE.md` is kept as RAMs land.

## Verification strategy

- **MAME is a reference generator, driven from scripts**: boot traces, RAM and register dumps at
  known frames, write logs. WORKFLOW §9 applies.
- **The software model comes before the RTL**, checked against MAME first.
- **Every vendored module is verified against MAME before it is wired to anything.**
- **Layouts are verified before ROMs are involved**: `charlayout` and `spritelayout` (405-427) get
  the "every bit of a tile exactly once" check.
- **`.mra` files are generated**, re-read byte for byte against an image built from `ROM_START`.
- **Worst cases are measured in the RTL**: sprite-line overrun and CPU stall counters.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer**, `Template.*` renamed to `NixPirates.*` and split into
the `NixPirates_stp` and `NixPirates` revisions; the Quartus 13 project dropped. Quartus **17.0.2**.

## Open items

**The pixel clock and frame totals are an assumption.** Known: 32 and 24 MHz crystals, HSync
15.69 kHz, VSync 60 Hz (PCB notes, 85-88). Assumed: 6 MHz, 384 x 262. Closed by a PCB measurement
or footage with a known frame rate.

~~**SDRAM controller.**~~ `jtframe_sdram64`, approved.

~~**Tile RAM and palette live, or queued to vblank.**~~ Live, approved.

**Genix Family's buttons 1 and 2 are unnamed.** No manual or flyer was found. The cabinet test of
both games labels the buttons A, B, C. Pirates' were named by pressing each in MAME play (button 1
a hit flash at the crosshair, 2 a roll aside, 3 a bomb off the counter): Shoot, Slide, Bomb.
Genix's button 3 circles the player with cards ("Special"); 1 and 2 keep the cabinet test's
"Button A", "Button B". Closed by a manual, a flyer or a clearer play test.

**Bus wait states are MAME's: none.** No schematic. The core is zero-wait on every access
(`sim/boot_tb`: 200,000 of 200,000 bus cycles at 5 phases); fx68k reproduces whatever DTACK it is
given, so a measured wait state goes in by delaying DTACK for that region. Closed by AS-to-DTACK
on a PCB for ROM, RAM, video RAM and I/O.

**Unknown writes.** `pirates` writes 0x500800-0x500804 12 times from PC 0x01b22e; the sprite
colour word's bits 8-15 are written and unused by MAME; `out_w` bit 7 is unknown (299). All are
ignored, as MAME.

## Next steps

1. ~~Approval of this roadmap.~~
2. ~~`.mra` generator and files.~~
3. ~~Phase 0: vendor fx68k, `jtframe_68kdtack_cen`, `jtframe_sdram64`; the loader.~~
4. ~~Phase 0: the 68000 bus logic and memory map, boot trace against MAME (criterion 2).~~
5. ~~Phase 0: a Verilator SDRAM model so `jtframe_sdram64` runs under fx68k (criterion 3).~~
6. ~~Phase 0: the standalone Fmax project (criterion 4).~~
7. ~~Phase 1: video, against a software model.~~
8. Phase 2: the top level, the first build on the board. Build at 1238028: timing met, black
   screen on the board; `sim/top_tb` reproduced it (the 93C46's write busy, `docs/MAME_KLUDGES.md`)
   and shows both games' attract after the fix. On the board: Pirates and Genix boot to attract
   (`_stp` at a6e81cb's slew settings, 8 of 8 launches), after `SHIFTED=1` (520db7c) and SDRAM
   slew rate 0 (a6e81cb). Play, fast load, flip, CRT adjust and hiscore on the board: pending.
9. Phase 2 features: flip, CRT adjust, crop, rotation, audio mix, fast load, hiscore, ISSP. In
   simulation: flip (`sim/video_tb --flip`), hiscore restore (`sim/top_tb`). On the board: pending.
10. Phase 3: sound against MAME in simulation (above); by ear pending.
11. Phase 5: not planned (above).
