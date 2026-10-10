# NixPirates state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| Work RAM 0x100000 | `np_main` `u_wram` | 16 x 32K | 64 KB | yes, read through port B |
| Palette 0x800000 | `np_main` `u_pal` | 16 x 8K | 16 KB | yes, port B |
| Tile RAM 0x900000 | `np_main` `u_vram` | 16 x 16K (8388 used) | 16.4 KB | yes, port B |
| Sprite list 0x500000 | `np_main` `u_spr` | 16 x 1K | 2 KB | yes, port B |
| Sprite snapshot | `np_video` `shadow` | 16 x 1K | 2 KB | no: recopied at line 13 of every frame |
| Sprite line buffers | `jtframe_obj_buffer` | 11 x 2 x 512 | | no: redrawn every line |
| Program-ROM cache | `jtframe_romrq_lcache` | 64 x 2048 | 16 KB | no: refilled from SDRAM; invalidate on restore |
| Flip line buffer | `np_video` `flip_lb` | 13 x 1024 | | no: rewritten every line |
| CRT adjust line buffer | `crt_adjust` | 24 x 1024 x 2 | | no: output only |
| Sample-ROM slot | `np_sound` `jtframe_rom_1slot` | 2 x 32 bits | | no: refilled from SDRAM |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| 68000 | fx68k | | yes (KonamiGX's `gx_ss_m68k` is the precedent) | m68000 |
| Scroll | `np_main` `scroll` | 16 | yes | `m_scroll` share |
| IRQ1 pending | `np_main` `irq1_n` | 1 | yes | HOLD_LINE state |
| `out_w` latch (EEPROM pins, OKI bank) | top level | 8 | yes | eeprom, okim6295 bank |
| Video counters | `np_video` `hcnt`, `vcnt` | 18 | yes, or restore at frame start | screen position |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| 93C46 | jt9346 | contents in RAM (its dump port); shift state in registers | | |
| M6295 | jt6295 | registers and channel state in flops | | the four voices' address and ADPCM state; MAME's okim6295 `save_item`s |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| SDRAM | ROM only, reloaded from the `.mra` |

## Frame alignment

Restore at a frame start before line 13, so the sprite snapshot and the scroll latch are taken
from the restored RAM.
