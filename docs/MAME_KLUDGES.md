# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/nix/pirates.cpp` unless named. MAME commit: `774a180df2b`
(the file's last change), checkout `mame0289-661`; captures from MAME 0.289.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

No set carries an imperfect flag; all three are `status="good"`.

## CPU and bus

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| No bus wait states | `prg_map` (340-359) declares none, so every access is zero-wait | copies: every data cycle is flagged to `jtframe_68kdtack_cen`, which holds the 68000's DTACK-sampling phase until DTACK is out and repays it (`rtl/np_main.sv`, `u_dtack`). `sim/boot_tb`: 200000 of 200000 bus cycles at 5 phases, 886443 68000 clocks to MAME's 886436 at access 200000 | AS-to-DTACK measured on a PCB for ROM, work RAM, video RAM and I/O |
| Unmapped accesses | read 0, writes dropped: `0x500800-0x500804` (pirates, the commented-out `nopw` at 348), `0x600002`, `0x880000`, `0x500f00-0x500f0e` and `0xc02000` (genix) (`scripts/mem_scan.py`) | copies, `rtl/np_main.sv` read mux | A PCB's decode |
| Write-only sprite RAM and scroll read 0 | `writeonly()` (347, 350); pirates reads `0x700000` 154 times in 3600 frames | copies | — |

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Whole frame drawn at vblank start | `screen_update` (279-285) draws every line at once from the state then, and looks the palette up after | differs: tile RAM and palette are read live, line by line (ROADMAP, Design decisions); a mid-frame write shows from its line on, not in the whole frame. The sprite list and scroll are taken at line 13, which is what MAME's frame uses for writes made in vblank | - |
| fg and bg tilemaps 64 columns wide over 46 columns of share | `video_start` (218-219, "Not sure how big they can be"): columns 46-63 read past the share | differs: the RTL reads on through the one tile RAM (into bg for fg, unwritten RAM past bg). `render_model.py` counts visible pixels from there: none in the 18 captured frames | A frame that scrolls fg or bg past column 46 on a PCB |
| Colour wrap | `tilemap.h:393`, `rawcolor % 384`; sprites `color % 128` (`drawgfx.cpp:361`) after `& 0xff` | colour words' low 7 bits; the same for every value the games write (`attr_census.py`: never above 0x7f in tiles) | - |
| Sprite colour word bits 8-15 | ignored (`draw_sprites`, 262) | copies (ignored); pirates sets them all | A PCB with a sprite whose upper colour bits differ |

## Sound

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| M6295 sample rate | `stream_alloc(0, 1, clock() / divisor)` (okim6295.cpp 121) divides the integer clock: 1333333 / 165 = 8080 Hz, 100 ppm under the chip's 8080.81 Hz | differs: the chip's rate, 48 MHz / 36 / 165. Against MAME a sound drifts 0.81 samples a second (`sim/sound_tb/run_sound_tb.py` compares by sample index for that reason) | - |
| Output level | a voice at full scale is 1.0 of the stream (2048 per sample) | 14 bits, four voices, shifted left by 2 into 16: a voice at full scale is a quarter of MAME's | - |

## Protection

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| "patch out protection check" (pirates, piratesb) | 618: program word 0x62c0 `beq` (0x6706) made `bra` (0x6006); `prot_r` reads 1 (304-335) | copies, on the CPU's read path, not in SDRAM (`rtl/np_main.sv`) | A board with the protection hardware working; the driver says its own fuller model hangs |
| genix counter write-protect | 621, 632: reads of 0x109e98/0x109e9a return 0x0004/0x0000, writes still reach RAM | copies (`rtl/np_main.sv`, `genix_prot`) | As above |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| jt9346, write busy | after a write the 93C46 is busy for `WRITE_TIME`, 1750 us (eeprom.cpp 42), DO low while CS is high | ready at once after a write. The game waits to see busy and then ready, so on a blank EEPROM it hung on the first write: a black screen on the board, and in `sim/top_tb` the 68000 looping at 0x54e8-0x59b0 past frame 55 | added outside the module: `NixPirates.sv` holds DO low for 84,000 clocks (1750 us) after each write (`ee_busy`); erase and the all-word commands get the same time, where MAME has 1000 us and 8000 us | the 93C46's datasheet tWP, or a PCB measurement |
| fx68k, interrupt recognition | MAME 0.289's 68000 takes level 1 one instruction sooner in some frames | `sim/boot_tb`, interrupts at MAME's times in 68000 clocks: pirates' third interrupt and genix's second are taken one instruction later than MAME's (vector fetches at accesses 1099856 and 970663, MAME 1099854 and 970662); the traces are identical before that, two and one interrupts included. Why, unverified | fx68k is built from the 68000's microcode; MAME's core is a model of it | A 68000 board with a logic analyser, IPL asserted at known points before an instruction ends |
