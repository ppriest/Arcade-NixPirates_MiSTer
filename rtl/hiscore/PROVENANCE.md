# rtl/hiscore provenance

| File | Source | Licence | Changes |
|---|---|---|---|
| `hiscore.v` | Alan Steremberg and Jim Gregory's hiscore module (github.com/JimmyStones/Hiscores_MiSTer, version 14), as carried by `E:/Arcade-Psikyo_MiSTer/rtl/hiscore.v` at `7500d5191c3b8fca33391a4b1a9fb92194ed78fa` | GPL-3.0-or-later | `ioctl_upload_req`, `ram_write` and `pause_cpu` given initial values: they had none, and powered up 1 in `sim/top_tb` with `+verilator+rand+reset+2` (as Power-Up Don't Care allows on the board), which handed work RAM to hiscore and let it write while the 68000 ran. Otherwise as Psikyo's; Psikyo's own patches (marked `// Psikyo:`) take one more clock of RAM read latency, which `rtl/np_main.sv`'s registered `hs_dout` needs, and require CHECK_HOLD of 2 or more |
