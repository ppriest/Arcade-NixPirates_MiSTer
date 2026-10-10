// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// np_video against captured state (scripts/vid_capture.py): the tile RAM, palette, sprite
// list and scroll a MAME frame was drawn from are loaded into the RAMs np_main would hold,
// the graphics come from jtframe_sdram64 and sim/models/np_sdram_model.v (banks 1 and 2 as
// rtl/np_rom_loader.sv leaves them, scripts/sdram_model.py --out), and the visible pixels of
// the second frame are written out, RGB, for sim/video_tb/run_video_tb.py to compare with
// scripts/render_model.py and MAME's snapshot.
//
//   +vram= +pal= +spr= +scroll=   capture files (big-endian words)
//   +sdram_bank1= +sdram_bank2=   bank images (np_sdram_model)
//   +out=                         288 x 224 x 5 bytes: R, G, B, palette index (big-endian)

`timescale 1ns/1ps
`default_nettype none

module tb_video #(parameter LEAD_TILE = 8, LEAD_SPR = 1, FLIP = 0);

reg clk = 1'b0;
always #10.4167 clk = ~clk;
reg rst = 1'b1, rst_sd = 1'b1;

reg [15:0] vram [0:16383];
reg [15:0] pal  [0:8191];
reg [15:0] spr  [0:1023];
reg [15:0] scr  [0:0];
reg [15:0] vram_q, pal_q, spr_q;

wire [13:0] vram_addr;
wire [12:0] pal_addr;
wire  [9:0] spr_addr;
always @(posedge clk) begin
	vram_q <= vram[vram_addr];
	pal_q  <= pal[pal_addr];
	spr_q  <= spr[spr_addr];
end

wire        ba1_rd, ba2_rd, ce_pix, hblank, vblank, hsync, vsync, irq;
wire [21:0] ba1_addr, ba2_addr;
wire  [3:0] ack, dst, rdy;
wire [15:0] sd_dout;
wire  [7:0] r, g, b;
wire [12:0] pen;

np_video #(.LEAD_TILE(LEAD_TILE), .LEAD_SPR(LEAD_SPR)) dut (
	.clk(clk), .rst(rst), .flip(FLIP != 0), .scroll_in(scr[0]),
	.spr_wr(1'b0), .spr_wr_addr(10'd0), .spr_wr_din(16'd0), .spr_wr_be(2'b00),
	.vram_addr(vram_addr), .vram_dout(vram_q), .pal_addr(pal_addr), .pal_dout(pal_q),
	.spr_addr(spr_addr), .spr_dout(spr_q),
	.ba1_rd(ba1_rd), .ba1_addr(ba1_addr), .ba1_ack(ack[1]), .ba1_dst(dst[1]), .ba1_rdy(rdy[1]),
	.ba2_rd(ba2_rd), .ba2_addr(ba2_addr), .ba2_ack(ack[2]), .ba2_dst(dst[2]), .ba2_rdy(rdy[2]),
	.sdram_dout(sd_dout),
	.ce_pix(ce_pix), .r(r), .g(g), .b(b), .hblank(hblank), .vblank(vblank),
	.hsync(hsync), .vsync(vsync), .vblank_irq(irq), .dbg_pen(pen)
);

wire [15:0] dq, sd_din;
wire [12:0] sa;
wire  [1:0] sba, dqm;
wire        nwe, ncas, nras, ncs, cke, init;
jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1),
	.BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(16)) u_ctl (
	.rst(rst_sd), .clk(clk), .init(init),
	.ba0_addr(22'd0), .ba1_addr(ba1_addr), .ba2_addr(ba2_addr), .ba3_addr(22'd0),
	.rd({1'b0, ba2_rd, ba1_rd, 1'b0}), .wr(4'd0),
	.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
	.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
	.prog_en(1'b0), .prog_addr(22'd0), .prog_rd(1'b0), .prog_wr(1'b0), .prog_din(16'd0),
	.prog_dsn(2'b11), .prog_ba(2'd0), .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
	.rfsh(hsync),
	.ack(ack), .dst(dst), .dok(), .rdy(rdy), .dout(sd_dout),
	.sdram_dq(dq), .sdram_din(sd_din), .sdram_a(sa), .sdram_dqml(dqm[0]), .sdram_dqmh(dqm[1]),
	.sdram_ba(sba), .sdram_nwe(nwe), .sdram_ncas(ncas), .sdram_nras(nras), .sdram_ncs(ncs),
	.sdram_cke(cke)
);
np_sdram_model #(.PERIOD_NS(20.8333)) u_sdram (
	.clk(clk), .cke(cke), .cs_n(ncs), .ras_n(nras), .cas_n(ncas), .we_n(nwe),
	.ba(sba), .a(sa), .dqm(dqm), .din(sd_din), .dq(dq), .dq_oe()
);

// --- capture the second frame's visible pixels ----------------------------------------------
string  f_vram, f_pal, f_spr, f_scr, f_out;
integer fd, frame = 0, n = 0, line_px = 0, lines = 0;
reg     vb_l = 1'b1, hb_l = 1'b1;
always @(posedge clk) if (ce_pix && !rst) begin
	vb_l <= vblank;
	hb_l <= hblank;
	if (vblank && !vb_l) begin
		frame = frame + 1;
		if (frame == 3) begin
			$fclose(fd);
			$display("DONE: %0d pixels, %0d lines, %0d SDRAM model errors", n, lines, u_sdram.errors);
			$finish;
		end
	end
	if (frame == 2 && !vblank && !hblank) begin
		$fwrite(fd, "%c%c%c%c%c", r, g, b, pen[12:8], pen[7:0]);
		n = n + 1;
	end
	if (frame == 2 && !vblank && hblank && !hb_l) lines = lines + 1;
end

initial begin : setup
	integer f, k;
	for (k = 0; k < 16384; k = k + 1) vram[k] = 16'd0;
	if (!$value$plusargs("vram=%s", f_vram) || !$value$plusargs("pal=%s", f_pal) ||
	    !$value$plusargs("spr=%s", f_spr) || !$value$plusargs("scroll=%s", f_scr) ||
	    !$value$plusargs("out=%s", f_out)) begin
		$display("ERROR: +vram= +pal= +spr= +scroll= +out= are required"); $finish;
	end
	f = $fopen(f_vram, "rb"); k = $fread(vram, f, 0, 8388); $fclose(f);
	f = $fopen(f_pal, "rb");  k = $fread(pal, f);  $fclose(f);
	f = $fopen(f_spr, "rb");  k = $fread(spr, f);  $fclose(f);
	f = $fopen(f_scr, "rb");  k = $fread(scr, f);  $fclose(f);
	fd = $fopen(f_out, "wb");
	repeat (16) @(posedge clk);
	rst_sd = 1'b0;
	repeat (4) @(posedge clk);
	while (init) @(posedge clk);
	rst = 1'b0;
end

endmodule

`default_nettype wire
