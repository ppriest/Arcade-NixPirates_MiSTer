# NixPirates: hardware notes

What the board is, from MAME and any other source, each fact with where it came from.

Source: MAME `src/mame/nix/pirates.cpp`, last changed by `774a180df2b` (a screen-device refactor,
the only change to the file since `mame0289`), in the checkout at `E:/mame` (`mame0289-661`).
`mame -listxml` and every capture below are from MAME **0.289** (`C:/Emulation/Emulators/MAME`).
Line numbers are `pirates.cpp`'s. Everything here is MAME's model unless marked otherwise. The
driver is one file; its devices are `cpu/m68000`, `machine/eepromser` (93C46) and
`sound/okim6295`. None of those changed between `mame0289` and the source checkout in a way
that touches a 68000 board (`git log mame0289..HEAD` on each: two 68030/68040 CACR fixes and a
rotate-helper refactor).

## Sets

| Set | Game | Init | Program | Tiles | Sprites | OKI | MAME status |
|---|---|---|---|---|---|---|---|
| `pirates` | Pirates (set 1), 1994 | `init_pirates` | 2 x 512 KB | 4 x 512 KB | 4 x 512 KB | 512 KB | good, `MACHINE_SUPPORTS_SAVE` |
| `piratesb` | Pirates (set 2), 1995, clone | `init_pirates` | 2 x 512 KB (own) | = `pirates` | = `pirates` except `u71` | = `pirates` | good |
| `genix` | Genix Family, 1994 | `init_genix` | 2 x 512 KB | 4 x 256 KB in 512 KB slots | 4 x 256 KB in 512 KB slots | 512 KB | good |

From `-listxml` (`debug/listxml.xml`): every set is `status="good"`, `emulation="good"`, no
imperfect flags. `piratesb` shares 9 of 11 parts with `pirates` by CRC; its `u71` (`0bb7c816`)
differs from `pirates`' `s4_fdcc.bin` (`8916ddb5`) by one bit (driver comment, line 501). Each set
loads 5.5 MB: 1 MB program, 2 MB tiles, 2 MB sprites, 512 KB samples.

Every ROM is scrambled, address and data (`decrypt_68k` 532, `decrypt_p` 552, `decrypt_s` 571,
`decrypt_oki` 591). `scripts/decrypt_model.py` transcribes all four and checks them against the
regions MAME holds after init (`scripts/mame/dumpregions.lua`): **byte-identical for every region
of all three sets**. It also checks the load-time form: encrypted byte *i* written, data
bit-permuted, to a bit permutation of *i* gives the same image, so the loader decrypts with wiring
only (the program ROM's permutation is inverted per byte lane; `--tables` prints the tables). The
one difference from MAME's region is the protection patch below.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| `maincpu` | MC68000 | 32 MHz / 2 = 16 MHz, "verified on PCB" (440) | everything | fx68k, in Seta, KonamiGX, BallySente |
| `oki` | OKI M6295, pin 7 low (/165) | 24 MHz / 18 = 1.3333 MHz, "verified on PCB" (460) | all sound, mono | jt6295, in Fuuki and Vamphalf |
| `eeprom` | 93C46, 16-bit | serial, bit-banged | settings | jotego `jt5911` (`E:/jtcores/modules/jteeprom`) |
| video | 4 x Altera EPM7064 (PCB layout, lines 59-89) | unknown | 3 tilemaps + sprites | none; the CPLDs are undocumented |

The PCB layout also shows a PAL and an 18-pin DIP with its surface scratched off (line 89).

## Clocks

| Clock | Value | Source |
|---|---|---|
| CPU crystal | 32 MHz | PCB layout, line 80 |
| Video / sound crystal | 24 MHz, between the video CPLDs | PCB layout, line 70 |
| 68000 | 16.000 MHz | line 85, line 440 |
| M6295 | 1.33333 MHz, sample rate clock / 165 = 8.08 kHz | line 86, line 460; `okim6295.cpp:120` |
| HSync | 15.69 kHz | line 88, PCB measurement (Guru) |
| VSync | 60 Hz | line 87; MAME `set_refresh_hz(60)` (449) |
| Pixel clock | **not given** | the driver uses `set_refresh_hz`/`set_size` (449-452), no `set_raw` |

**The pixel clock is unknown.** MAME draws a 288 x 256 frame at 60 Hz (a 15.36 kHz line, not the
PCB's 15.69 kHz). Candidates from the crystals, each with the line total that comes nearest the
measured 15.69 kHz and a 262-line frame:

| Pixel clock | Line total | Line rate | Frame | Visible share | Divides 48 MHz |
|---|---|---|---|---|---|
| 24 / 4 = 6 MHz | 384 | 15.625 kHz | 59.64 Hz | 75% | yes, /8 |
| 24 / 4 = 6 MHz | 382 | 15.707 kHz | 59.95 Hz | 75% | yes, /8 |
| 32 / 5 = 6.4 MHz | 408 | 15.686 kHz | 59.87 Hz | 71% | no |
| 24 / 3 = 8 MHz | 510 | 15.686 kHz | 59.87 Hz | 56% | yes, /6 |

6 MHz from the 24 MHz crystal beside the video CPLDs is the likeliest; it is an assumption until a
PCB measurement or timed footage settles it. The roadmap's Clocks section carries the choice.

## Video

From `-listxml`: 288 x 224 visible, 60.000 Hz, rotate 0. Screen 36 x 8 by 32 x 8, visible lines
16-239 (451-452); vblank IRQ at line 240, measured as the vblank start in every sweep run.

**Palette**: 0x2000 entries, xRGB_555 (456), at 0x800000-0x803fff, CPU read/write. Pen bases:
tx 0x000, fg 0x800, bg 0x1000 (one 384-colour gfx element, colour words offset +0x80 and +0x100;
188-208, 430), sprites 0x1800 (431).

**Tilemaps**, all 8x8 4bpp, `TILEMAP_SCAN_COLS` (column-major: index = column x 32 + row), two
words per tile, code then colour (186-210, 213-222):

| Layer | Size | RAM (MAME's split) | Scroll | Transparent | Order |
|---|---|---|---|---|---|
| bg | 64 x 32 | 0x902a80-0x904187, 1474 tiles | `scroll[0]` X, no Y | no | bottom |
| fg | 64 x 32 | 0x901380-0x902a7f, 1472 tiles | `scroll[0]` X, no Y | pen 0 | 2 |
| tx | 36 x 32 | 0x900180-0x90137f, 1152 tiles | none | pen 0 | top |

fg and bg share one X scroll (279-280). MAME's tilemaps are 64 columns but the RAM it assigns
holds 46: MAME reads past the share for columns 46-63, where the game would only reach by
scrolling that far. The split of one RAM at 0x900000-0x904187 into these bases is MAME's
("more of tilemaps ?", 352-357), and the bases (0x180, 0x1380, 0x2a80) are not aligned to any
power of two.

**Sprites**: 16x16 4bpp, 128 colours, list at 0x500000-0x5007ff (writeonly in MAME, 347),
four words an entry, entry *k* from word 4*k* (`draw_sprites`, 247-275):

| Word | Use |
|---|---|
| 4k | colour, `& 0xff`, then `% 128` by `drawgfx` (`drawgfx.cpp:361`) |
| 4k+1 | X; screen x = word - 32, no wrap |
| 4k+2 | code = word >> 2 (14 bits); bit 1 flip X, bit 0 flip Y |
| 4k-1 | Y (the *previous* entry's last word); bit 15 ends the list; screen y = 0xf2 - word |

The walk starts at entry 1 and stops at entry 255 or the end marker; later entries draw over
earlier ones (`transpen`, pen 0 transparent). Order: bg, fg, sprites, tx (281-284).

**What the games write** (`scripts/attr_census.py`, attract 3600 frames and play 6000, both sets):

| Word | Bits seen | Consequence |
|---|---|---|
| tile colour, all layers | `0x007f` | MAME's `% 384` wrap is never reached; 7 bits suffice |
| tile code | bg `0x7fff`, fg `0x5fff`, tx `0x07ff` | 16-bit codes kept |
| sprite colour | `0xffff` (pirates), `0x80ff` (genix) | bits 8-15 written, ignored by MAME |
| sprite X | `0x81ff` | bit 15 set moves a sprite off screen by MAME's arithmetic |
| sprite Y | `0x80ff` | bit 15 is the end marker; Y is 8 bits |

**Sprites per line** (`scripts/sprite_load.py`): most on one visible line 52 (`pirates` attract,
frame 2588 line 173), 49 in play; `genix` 21 attract, 7 in play. Longest list 252 entries
(`genix` attract).

**Flip**: no flip register or DIP in MAME. MAME emulates no priority bits, no Y scroll, no
line scroll.

### Flip screen

The board has no flip: no register, DIP or `flip_screen_set` in pirates.cpp. The core's flip is
the finished picture turned 180 degrees, from the OSD's Flip Screen or the `.mra`'s fake DIP
(`<switches>` bit 0, every set), XORed (`NixPirates.sv`, `flip`). `rtl/np_video.sv` draws each
line one line early, of the mirrored line (254 - line, for MAME's visible 16-239), into a line
buffer of palette addresses that the next line reads right to left; the sprite scanner's target
line is mirrored the same way. No layer needs its own offset. Checked in `sim/video_tb --flip`:
9 of 9 frames equal to the unflipped model turned 180 degrees (there is no MAME reference for a
flip the board does not have).

## When the game writes video state (sweep)

`docs/write_timing_mame.txt`, attract and play, all three sets:

- **Sprite RAM**: written in the vblank handler. 98.7-100% of writes fall in MAME's 16 lines of
  vblank (lines 240-255), the rest within lines 0-47 and 216-239 (`pirates` attract only, under
  1%). Play: 100% in vblank for all three sets.
- **Scroll**: once a frame, 93-100% in the first two lines after vblank start.
- **Tile VRAM and palette**: across the whole frame in attract (palette 41 a frame in `pirates`,
  80 in `genix`); in play, palette and tx writes mid-frame (lines ~72-136 in `pirates`).
- **`out_w`** (EEPROM, OKI bank): about once every five frames, anywhere in the frame.

MAME draws the whole frame at vblank start (line 240) from the state then, with no partial
updates, and looks up the palette after drawing.

## Memory map

`prg_map`, 340-359. Everything not listed is unmapped: MAME ignores writes and reads 0.

| Address | Size | R/W | What | MAME line |
|---|---|---|---|---|
| 0x000000-0x0fffff | 1 MB | R | program ROM | 342 |
| 0x100000-0x10ffff | 64 KB | RW | work RAM | 343 |
| 0x300000 | word | R | INPUTS: P1 bits 0-7, P2 bits 8-15 (up, down, left, right, b1, b2, b3, start), active low | 344, 365 |
| 0x400000 | word | R | SYSTEM: coin1, coin2, service1, test (active low), EEPROM DO (bit 4), protection (bit 7, reads 1), rest 0 | 345, 383 |
| 0x500000-0x5007ff | 2 KB | W | sprite list | 347 |
| 0x600001 | byte | W | `out_w`: bit 0 EEPROM CS, 1 CLK, 2 DI; bit 6 OKI bank (256 KB); bit 7 unknown | 349, 289 |
| 0x700000 | word | W | scroll X (fg and bg) | 350 |
| 0x800000-0x803fff | 16 KB | RW | palette | 351 |
| 0x900000-0x904187 | 16.4 KB | RW | tile RAM: 0x180 bytes unused by MAME, then tx, fg, bg | 352-356 |
| 0xa00001 | byte | RW | M6295 | 358 |

Interrupts: level 1 autovector at vblank, `irq1_line_hold` (442): held until the CPU's
acknowledge. Vectors from the decrypted ROM (`scripts/mem_scan.py`): level 1 at `0x00bf84`
(pirates, piratesb) and `0x00ddf6` (genix); levels 2-7, bus error, address error and illegal
each have their own handler; reset PC `0x000400`, SSP `0x10effe` / `0x10dffe`. Only level 1 is
ever raised.

Accesses outside the map (`scripts/mem_scan.py`, 3600 frames attract and 4800 play, from
power-on; exact addresses with the first PC):

| Set | Access | Count | First PC | MAME |
|---|---|---|---|---|
| pirates, piratesb | write 0x500800, 0x500802, 0x500804 | 12 each, from frame 4 | 0x01b22e | unmapped (the `nopw` at 348 is commented out) |
| pirates, piratesb | write 0x600002 | 1 at power-on | 0x00042c | unmapped |
| all | read 0x880000, 0x880002 | 1 each | 0x005fd2 / 0x00654c | unmapped, reads 0 |
| genix | write then read 0x500f00-0x500f0e | 1-2 each at frame 2 | 0x0136b6 | unmapped, reads 0 |
| genix | read-modify-write 0xc02000 | 5-6 | 0x015e6a | unmapped |
| pirates | read 0x700000 (scroll, writeonly) | 154 in 3600 frames | | reads 0 |

No write lands past 0x904187; the power-on test walks only the regions in the map.

## Protection

- **pirates, piratesb**: `prot_r` (SYSTEM bit 7) always reads 1; a real sequence is sketched in a
  disabled block (312-330). MAME patches the program ROM instead: word 0x62c0, `0x6706` (beq) to
  `0x6006` (bra) (618), the decrypted value confirmed by `scripts/decrypt_model.py`.
- **genix**: reads of 0x109e98 return `0x0004` and of 0x109e9a `0x0000`, writes still reach work
  RAM (621, 632).

The driver says the protection hangs the game periodically when emulated, and that the prototype
board hangs the same way (TODO, lines 10-17, and 53-57).

## EEPROM

93C46, 16-bit organisation, on `out_w` bits 0-2 and SYSTEM bit 4. The driver's TODO says the
EEPROM "doesn't work" and that the program's use of it is not understood (10-12). MAME has no
default image for any set: the part starts erased.

## Sound

One M6295, mono, 1.3333 MHz with pin 7 low; 512 KB sample ROM in two 256 KB banks selected by
`out_w` bit 6 (297). No sound CPU: the 68000 writes the chip directly.

## Feasibility

Not needed: a 16 MHz 68000, one ADPCM chip, 5.5 MB of ROM against a 32 MB module, and a little
over 100 KB of RAM.
