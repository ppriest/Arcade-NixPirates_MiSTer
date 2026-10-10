# rtl/sound provenance

The board's one OKI M6295 (pirates.cpp 460). GPL-3.0-or-later, as this repository.

| Path | Source | Changes |
|---|---|---|
| `jt6295/hdl/jt6295*.v`, `jt6295/LICENSE` | jotego's JT6295, github.com/jotego/jt6295 `master` at `7d76b0be8cd8f85f3ae741178c9830b20e2071a1`, copied from `E:/Arcade-Vamphalf_MiSTer/rtl/sound/jt6295` at `ec45cfbf05aa8fd938149dabd8f2ad2c7360fde8` (vendored there from `E:/Arcade-Fuuki_MiSTer`; see its PROVENANCE). Without `jt12_comb.v`, `jt12_interpol.v` and the FIR tables: `INTERPOL = 0` leaves them unused | none |

jt6295 reads ADPCM bytes without a handshake: the byte must be on `rom_data` by the end of two
`cen_sr32` slots after the address changes. With `ss = 0` and the 1.3333 MHz enable every 36
clocks of 48 MHz, that is 2 x 5 x 36 = 360 clocks; `rtl/np_sound.sv` reads through a
`jtframe_rom_1slot` on SDRAM bank 3, without the bridge and sample cache Vamphalf needs for its
DDR3 path.
