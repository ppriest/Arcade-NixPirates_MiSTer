// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// SDRAM contents: one region per bank of the 32 MB module, 16-bit words, word
// addresses within the bank (jtframe_sdram64 AW = 22). jtframe_sdram64 serves
// bank 0 first and bank 3 last (BAPRIO=1), so the banks are in the order of
// what a stall costs (docs/ROADMAP.md, Memory plan).
//
// Formats, all decrypted (pirates.cpp decrypt_*). scripts/decrypt_model.py
// sdram_from_regions() builds these from MAME's decrypted regions; keep the two
// in step. "Plane p" is pen bit p: RGN_FRAC(p,4), pirates.cpp 405-427.
//
//   bank 0, program: word w = 68000 word at byte address 2w, high byte = even byte.
//   bank 1, tiles:   tile t, row y (0-7): words {t, y, j}, 16 + 3 + 1 bits;
//                    j=0 {plane1, plane0}, j=1 {plane3, plane2}, [15:8] the higher
//                    plane. Pixel 0 in bit 7 of each plane byte: the order
//                    jtframe_tilemap shifts out ("plane3,plane2,plane1,plane0").
//   bank 2, sprites: sprite s, row y (0-15), half h (pixels 0-7, 8-15): words
//                    {s, y, h, j}, 14 + 4 + 1 + 1 bits, j as tiles. Pixel 0 in bit 0, as MAME's
//                    layout and jtframe_draw ("leftmost pixel in LSB").
//   bank 3, samples: byte b at word b >> 1, [7:0] for even b. Bank bit 18 is
//                    out_w bit 6 (pirates.cpp 297).

localparam [1:0] BA_PRG     = 2'd0;
localparam [1:0] BA_TILES   = 2'd1;
localparam [1:0] BA_SPRITES = 2'd2;
localparam [1:0] BA_OKI     = 2'd3;
