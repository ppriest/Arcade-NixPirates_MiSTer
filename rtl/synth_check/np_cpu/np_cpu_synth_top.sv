// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// Standalone synthesis of the CPU and SDRAM path on the DE10-nano's Cyclone V
// (5CSEBA6U23I7), for ROADMAP Phase 0 criterion 4: does it close at 48 MHz, and
// how much does it take. Not part of the core. np_main (fx68k, the bus logic, the
// RAMs), the program-ROM slot and cache, np_rom_loader and jtframe_sdram64, wired
// as the core will wire them.
//
// After Arcade-KonamiGX_MiSTer's rtl/synth_check: every input comes from a
// register loaded by a serial shift chain and every output is XOR-reduced into a
// register, so paths start and end on flops, the pin count stays small and nothing
// is optimised away. Those pins are VIRTUAL; the SDRAM's are real and unconstrained
// (the I/O timing is sys/'s business, in the full build).

module np_cpu_synth_top (
	input  logic        clk,
	input  logic        rst,
	input  logic        sdi,
	input  logic        ld,
	output logic  [7:0] sig,

	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS,
	output logic        SDRAM_CKE
);

localparam int N = 1 + 1 + 16 + 16 + 8 + 15 + 13 + 14 + 10 + 1 + 1 + 27 + 8 + 16 + 3 + 3 * 22;
logic [N-1:0] sh, r;
always_ff @(posedge clk) begin
	sh <= {sh[N-2:0], sdi};
	if (ld) r <= sh;
end

logic        genix, vblank, ioctl_download, ioctl_wr;
logic [15:0] inputs_in, system_in, ioctl_index;
logic  [7:0] oki_dout, ioctl_dout;
logic [14:0] wram_b_addr;
logic [12:0] pal_b_addr;
logic [13:0] vram_b_addr;
logic  [9:0] spr_b_addr;
logic [26:0] ioctl_addr;
logic  [2:0] vid_rd;
logic [21:0] vid_addr [1:3];

assign {genix, vblank, inputs_in, system_in, oki_dout, wram_b_addr,
        pal_b_addr, vram_b_addr, spr_b_addr, ioctl_download, ioctl_wr, ioctl_addr, ioctl_dout,
        ioctl_index, vid_rd, vid_addr[1], vid_addr[2], vid_addr[3]} = r;

// --- CPU and bus ---------------------------------------------------------------------------
logic        rom_cs, rom_ok, out_we, oki_we, as_n, rw_n, dtack_n, cen;
logic [18:0] rom_addr;
logic [15:0] rom_data, scroll, wram_b_dout, pal_b_dout, vram_b_dout, spr_b_dout, dbg_din, dbg_dout;
logic  [7:0] out_d, oki_din;
logic [23:0] dbg_addr;
logic  [1:0] ds_n;
logic  [2:0] fc;

np_main u_main (
	.clk, .rst, .genix, .cpu_run(1'b1), .vblank,
	.rom_cs, .rom_addr, .rom_data, .rom_ok,
	.inputs_in, .system_in, .out_we, .out_d, .scroll, .oki_we, .oki_din, .oki_dout,
	.hs_access(1'b0), .hs_addr(16'd0), .hs_we(1'b0), .hs_din(8'd0), .hs_dout(),
	.wram_b_addr, .wram_b_dout,
	.pal_b_addr, .pal_b_dout, .vram_b_addr, .vram_b_dout, .spr_b_addr, .spr_b_dout,
	.spr_wr(), .spr_wr_addr(), .spr_wr_din(), .spr_wr_be(),
	.dbg_addr, .dbg_as_n(as_n), .dbg_rw_n(rw_n), .dbg_ds_n(ds_n), .dbg_fc(fc),
	.dbg_din, .dbg_dout, .dbg_dtack_n(dtack_n), .dbg_cen(cen)
);

// --- program ROM: slot and line cache on bank 0 -----------------------------------------------
logic        ba0_rd;
logic [21:0] ba0_addr;
logic  [3:0] ack, dst, dok, rdy;
logic [15:0] sd_dout;

jtframe_rom_1slot #(
	.SDRAMW(22), .SLOT0_DW(16), .SLOT0_AW(19), .CACHE0_LARGE(1), .CACHE0_SIZE(16384),
	.SLOT0_BURSTLEN(64), .TAG_RAM(1)
) u_slot (
	.rst, .clk,
	.slot0_addr(rom_addr), .slot0_dout(rom_data), .slot0_cs(rom_cs), .slot0_ok(rom_ok),
	.sdram_ack(ack[0]), .sdram_rd(ba0_rd), .sdram_addr(ba0_addr),
	.data_dst(dst[0]), .data_rdy(rdy[0]), .data_read(sd_dout)
);

// --- loader and SDRAM ----------------------------------------------------------------------
logic        ioctl_wait, prog_en, prog_wr, prog_rdy, sdram_init;
logic [21:0] prog_addr;
logic  [1:0] prog_ba, prog_dsn;
logic [15:0] prog_din;

np_rom_loader u_loader (
	.clk, .sdram_init,
	.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
	.prog_en, .prog_addr, .prog_ba, .prog_wr, .prog_din, .prog_dsn, .prog_rdy
);

logic [11:0] hcnt;
always_ff @(posedge clk) hcnt <= hcnt == 12'd3071 ? 12'd0 : hcnt + 12'd1;

jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1),
	.BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(16)) u_sdram (
	.rst, .clk, .init(sdram_init),
	.ba0_addr, .ba1_addr(vid_addr[1]), .ba2_addr(vid_addr[2]), .ba3_addr(vid_addr[3]),
	.rd({vid_rd, ba0_rd}), .wr(4'd0),
	.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
	.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
	.prog_en, .prog_addr, .prog_rd(1'b0), .prog_wr, .prog_din, .prog_dsn, .prog_ba,
	.prog_dst(), .prog_dok(), .prog_rdy, .prog_ack(),
	.rfsh(hcnt == 12'd0),
	.ack, .dst, .dok, .rdy, .dout(sd_dout),
	.sdram_dq(SDRAM_DQ), .sdram_a(SDRAM_A), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
	.sdram_ba(SDRAM_BA), .sdram_nwe(SDRAM_nWE), .sdram_ncas(SDRAM_nCAS), .sdram_nras(SDRAM_nRAS),
	.sdram_ncs(SDRAM_nCS), .sdram_cke(SDRAM_CKE)
);

// --- every output into one register ----------------------------------------------------------
always_ff @(posedge clk)
	sig <= {^{out_we, out_d, oki_we, oki_din}, ^scroll, ^wram_b_dout, ^pal_b_dout,
	        ^vram_b_dout, ^{spr_b_dout, dok, sd_dout}, ^{dbg_addr, as_n, rw_n, ds_n, fc, dtack_n, cen},
	        ^{dbg_din, dbg_dout, ioctl_wait, ack[3:1], dst[3:1], rdy[3:1]}};

endmodule
