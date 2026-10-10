# Third-party components

**Project licence: GPL-3.0-or-later** (`LICENSE`). fx68k is GPLv3 and the jtframe modules are
GPL-3.0-or-later, so the core as a whole is GPL-3.0; the MiSTer framework in `sys/` is
GPL-2.0-or-later, which permits that.

## fx68k — `rtl/cpu/fx68k/`

- Upstream: https://github.com/ijor/fx68k, Jorge Cwik, GPLv3 (`rtl/cpu/fx68k/LICENSE`).
- Taken: the CPU (`fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem`).
- Modified upstream of here, in sibling cores: `$readmemb` paths, packed structs, `stop_out`
  (`rtl/cpu/fx68k/PROVENANCE.md`). Unmodified here.
- Obliges: source with any binary, the licence text, notices of modification (carried in the
  file headers and PROVENANCE).

## jtframe — `rtl/jtframe/`

- Upstream: https://github.com/jotego/jtcores `modules/jtframe/hdl/`, Jose Tejada Gomez,
  GPL-3.0-or-later (SPDX headers).
- Taken: `jtframe_68kdtack_cen`, `jtframe_freqinfo`, `jtframe_bcd_cnt`, `jtframe_sdram64` and its
  bank, init, latch and refresh files, and the ROM slot stack (`jtframe_rom_1slot`,
  `jtframe_rom_2slots`, `jtframe_romrq` with its three caches, `jtframe_ramslot_ctrl`,
  `jtframe_rpwp_ram`, `jtframe_dual_ram`); commits and SHA-1s in `rtl/jtframe/PROVENANCE.md`.
- Unmodified.
- Obliges: as fx68k.

## jteeprom — `rtl/jteeprom/`

- Upstream: jotego's jteeprom, GPL-3.0-or-later (`rtl/jteeprom/PROVENANCE.md`).
- Taken: `jt9346.v`, the 93C46. Unmodified.

## JT6295 — `rtl/sound/jt6295/`

- Upstream: https://github.com/jotego/jt6295, Jose Tejada Gomez, GPL-3.0-or-later
  (`rtl/sound/jt6295/LICENSE`); commit and route in `rtl/sound/PROVENANCE.md`.
- Taken: `hdl/jt6295*.v`. Unmodified.

## hiscore — `rtl/hiscore/`

- Upstream: Alan Steremberg and Jim Gregory's hiscore module
  (https://github.com/JimmyStones/Hiscores_MiSTer, version 14), GPL-3.0-or-later, as carried by
  Arcade-Psikyo_MiSTer (`rtl/hiscore/PROVENANCE.md`).
- Modified: three outputs given initial values (`rtl/hiscore/PROVENANCE.md`).

## CRT adjust and screen rotation — `rtl/video/`

- `crt_adjust.sv`: rmonic79 (Arcade-Raiden_MiSTer), GPL-3.0-or-later, with Arcade-Seta_MiSTer's
  one fix, named in its header.
- `screen_rotate_two.sv`: Sorgelig, GPL-2.0-or-later.
- `np_crt.sv`: Arcade-Vamphalf_MiSTer's wrapper, adapted. Sources in `rtl/video/PROVENANCE.md`.

## Simulation only (not in any bitstream)

- `sim/models/mt48lc16m16a2.v`: Micron's SDRAM model as adapted in jtcores
  (`sim/models/PROVENANCE.md`).
- `sim/upstream/run_jtframe_tests.sh` reads jtcores' test benches from a jtcores checkout; none
  are copied here.

## Reference material, not code

- MAME (https://github.com/mamedev/mame), `src/mame/nix/pirates.cpp` and the devices it uses,
  BSD-3-Clause: the specification for the memory map, video, decryption and protection kludges.
  No MAME source is copied; `scripts/decrypt_model.py` transcribes its bit permutations, and
  cites the lines.

## Release checklist

- [ ] Every vendored directory's PROVENANCE matches its files (SHA-1s).
- [ ] Change notices present in every modified vendored file.
- [ ] SPDX header on every file of ours.
- [ ] `sys/` unmodified against Template_MiSTer.
- [ ] `LICENSE` text is GPL-3.0.
