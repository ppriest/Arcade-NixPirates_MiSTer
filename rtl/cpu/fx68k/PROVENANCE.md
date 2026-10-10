# fx68k provenance

Cycle-accurate 68000, Copyright (c) 2018, 2021 Jorge Cwik. GPLv3 (`LICENSE`).
Upstream: https://github.com/ijor/fx68k.

The main CPU.

## Chain of custody

| Stage | What |
|-|-|
| Upstream | ijor/fx68k |
| Then | `Arcade-SegaXBoard_MiSTer-1.0.0/rtl/cpu/fx68k/` |
| Then | `Arcade-Seta_MiSTer/rtl/cpu/fx68k/`, `$readmemb` paths made project-relative |
| Then | `Arcade-KonamiGX_MiSTer/rtl/cpu/fx68k/` at `8e0fec757359e299e66bb8315b88a9cbc9876640`: packed structs for Verilator, `stop_out` port (both marked `[GX]`) |
| Here | copied from that KonamiGX tree, **unchanged** |

| file | SHA-1 |
|-|-|
| LICENSE | 1eba7caf09a39110ad2f542e3ed8700d1a69c6d3 |
| README.md | a454581293a92f84c16c19293d4ead9c8c787a73 |
| fx68k.sv | 729f47c7efcee52676c03b89da45323f6be695be |
| fx68kAlu.sv | 9ff96173e9a672c4cefd4a213f2609b613b0b4d7 |
| uaddrPla.sv | a48151e4cdb151feff01b1e16ce3f327204521ab |
| microrom.mem | 62036424b29dfd412e7091bd1e331b14e767caa0 |
| nanorom.mem | a1f291b6397c7907b64141429434aabda9a0d7dc |

The `.mem` SHA-1s are the ones Seta recorded for the SegaXBoard copy.

## Local changes

None here. Inherited, as KonamiGX's PROVENANCE describes them:

- the two `$readmemb` paths are relative to the project root (`rtl/cpu/fx68k/microrom.mem`,
  `nanorom.mem`), where Quartus (the `build/` worktree, `STAGE_COPIES` in
  `scripts/build_staged.py`) and the simulation scripts run;
- `s_clks`, `s_irdecod`, `s_nanod` declared `packed` (Verilator refuses an unpacked struct driven
  both by assigns and an `always_ff`); no other effect;
- `stop_out`: high while IRD holds STOP (`4E72`); no logic changes.

## Tests

Upstream ships no testbench. The regression is the boot trace against MAME (ROADMAP, Phase 0,
exit criterion 2).
