# NIX Pirates hardware core for MiSTer

A MiSTer FPGA core for NIX's Pirates hardware (MAME's `nix/pirates.cpp`), built with Quartus
Prime 17.0.2 Lite for the DE10-nano.

**Status: in development.** `releases/Arcade-NixPirates_20261010.rbf` (commit `5852eb1`, default
fitter seed) boots Pirates and Genix Family to their attract modes on a DE10-nano. Play, sound by
ear, flip, CRT adjust and hiscore saving have not been checked on hardware. Timing met (worst
`clk_sys` setup slack 4.155 ns); 34,051 of 41,910 ALMs.

## Games

| Set | Game | Year | `.mra` | On hardware |
|-|-|-|-|-|
| `pirates` | Pirates (set 1) | 1994 | `releases/` | attract |
| `genix` | Genix Family | 1994 | `releases/` | attract |
| `piratesb` | Pirates (set 2) | 1995 | `releases/_alternatives/_Pirates/` | not run |

ROM sets as MAME 0.289.

## Installation

Needs an SDRAM module.

* Copy `releases/Arcade-NixPirates_20261010.rbf` to `_Arcade/cores/`, renamed
  `NixPirates_20261010.rbf`.
* Copy the `.mra` files and the `_alternatives` folder from `releases/` to `_Arcade/`.
* Put the MAME ROM sets (`pirates.zip`, `genix.zip`) in `games/mame/`.

## Controls

Three buttons, Start and Coin per player: Shoot, Slide, Bomb in Pirates; Button A, Button B,
Special in Genix Family. Pause and Service can be mapped to joystick buttons.

## Hardware

| Chip | Implementation |
|-|-|
| MC68000, 16 MHz | fx68k |
| OKI M6295, 1.333 MHz | jt6295 |
| 93C46 EEPROM | jt9346 |
| Tilemaps, sprites, palette | written for this core (`rtl/np_video.sv`) |
| ROMs | SDRAM through `jtframe_sdram64` |

## Building

`python scripts/build_staged.py --rev NixPirates`, then `python scripts/deploy.py` with a
`mister.env`. `docs/ROADMAP.md` is the plan and its progress.

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

## Acknowledgements

- David Haywood, Nicola Salmoria and Paul Priest, and the MAMEdev team, for `pirates.cpp`.
- Jorge Cwik for fx68k; Jose Tejada Gomez for jtframe, JT6295 and jteeprom; Alan Steremberg and
  Jim Gregory for the hiscore module; rmonic79 for CRT adjust; Sorgelig and the MiSTer-devel team
  for Template_MiSTer.

## License

GPL-3.0-or-later (`LICENSE`). Third-party components and their licences: `THIRD-PARTY.md`.
