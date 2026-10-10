# jteeprom provenance

From jotego's jteeprom (https://github.com/jotego/jteeprom), GPL-3.0-or-later (file header), as
the jtcores submodule `modules/jteeprom` at `9c68ce841f4ec560ca6f228c8af6301129fd95fa` in `E:/jtcores`.
**Verbatim.**

| file | SHA-1 | used for |
|---|---|---|
| `jt9346.v` | `f5d3e76391d1a05d7333757abfd71cd820a86c6a` | the 93C46, 64 x 16 (MAME `EEPROM_93C46_16BIT`, pirates.cpp 444); its RAM powers up erased, all ones, as MAME's part |

Used by jotego's CPS1 (`jtcps1_sdram.v`) and Pang (`jtpang_main.v`) cores. Not jt5911: that is the
ER5911, and its own header calls its 16-bit mode untested.
