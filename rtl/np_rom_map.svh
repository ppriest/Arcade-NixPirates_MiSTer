// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// The ROM download image (ioctl index 0), in the order the .mra's parts are
// written. Every region arrives as dumped: encrypted, and for the program ROM
// as 68000 words, high byte first (ROM_LOAD16_BYTE pair, pirates.cpp 468-469).
// The loader decrypts each byte to its SDRAM address on the way in
// (scripts/decrypt_model.py, "scatter"). scripts/build_mra.py reads the DL_*
// values below; keep the localparam lines in this form.

localparam [23:0] DL_PRG     = 24'h000000;  // "maincpu", 1 MB
localparam [23:0] DL_TILES   = 24'h100000;  // "tiles", four 512 KB plane quarters
localparam [23:0] DL_SPRITES = 24'h300000;  // "sprites", four 512 KB plane quarters
localparam [23:0] DL_OKI     = 24'h500000;  // "oki", 512 KB, two 256 KB banks
localparam [23:0] DL_END     = 24'h580000;

// Mod byte (ioctl index 1). Zero is pirates/piratesb.
//   [0] protection variant: 0 = program word 0x62c0 reads 0x6006 (init_pirates),
//       1 = reads of 0x109e98/0x109e9a return 0x0004/0x0000 (init_genix)
localparam MOD_GENIX_BIT = 0;
