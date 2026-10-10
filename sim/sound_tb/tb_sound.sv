// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// np_sound against MAME (ROADMAP Phase 3): the M6295 command writes and out_w bank bit of a
// MAME run (scripts/mame/okitrace.lua) are replayed on the clock they were made, the samples
// come from jtframe_sdram64 and sim/models/np_sdram_model.v (bank 3 as rtl/np_rom_loader.sv
// leaves it, scripts/sdram_model.py --out), and the chip's output is written at its sample
// rate for sim/sound_tb/run_sound_tb.py to compare with MAME's -wavwrite.
//
//   +writes=        lines "<clock> <o|b> <hex>", clocks of 48 MHz from power-on, in order
//   +sdram_bank3=   bank image (np_sdram_model)
//   +cycles=        clocks to run
//   +out=           16-bit little-endian samples, one per 5940 clocks (pin 7 low: /165)

`timescale 1ns/1ps
`default_nettype none

module tb_sound;

reg clk = 1'b0;
always #10.4167 clk = ~clk;
reg rst = 1'b1, rst_sd = 1'b1;

reg        oki_we = 1'b0, bank = 1'b0;
reg  [7:0] oki_din = 8'd0;
wire       ba3_rd;
wire [21:0] ba3_addr;
wire  [3:0] ack, dst, rdy;
wire [15:0] sd_dout;
wire signed [13:0] sound;

np_sound dut (
	.clk(clk), .rst(rst),
	.oki_we(oki_we), .oki_din(oki_din), .oki_dout(), .bank(bank),
	.ba3_rd(ba3_rd), .ba3_addr(ba3_addr), .ba3_ack(ack[3]), .ba3_dst(dst[3]), .ba3_rdy(rdy[3]),
	.sdram_dout(sd_dout), .sound(sound)
);

wire [15:0] dq, sd_din;
wire [12:0] sa;
wire  [1:0] sba, dqm;
wire        nwe, ncas, nras, ncs, cke, init;
reg  [8:0]  hcnt = 9'd0;    // a refresh request a 384-pixel line, as the core's hsync
always @(posedge clk) hcnt <= hcnt == 9'd383 ? 9'd0 : hcnt + 9'd1;
jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1),
	.BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(32)) u_ctl (
	.rst(rst_sd), .clk(clk), .init(init),
	.ba0_addr(22'd0), .ba1_addr(22'd0), .ba2_addr(22'd0), .ba3_addr(ba3_addr),
	.rd({ba3_rd, 3'b000}), .wr(4'd0),
	.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
	.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
	.prog_en(1'b0), .prog_addr(22'd0), .prog_rd(1'b0), .prog_wr(1'b0), .prog_din(16'd0),
	.prog_dsn(2'b11), .prog_ba(2'd0), .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
	.rfsh(hcnt == 9'd0),
	.ack(ack), .dst(dst), .dok(), .rdy(rdy), .dout(sd_dout),
	.sdram_dq(dq), .sdram_din(sd_din), .sdram_a(sa), .sdram_dqml(dqm[0]), .sdram_dqmh(dqm[1]),
	.sdram_ba(sba), .sdram_nwe(nwe), .sdram_ncas(ncas), .sdram_nras(nras), .sdram_ncs(ncs),
	.sdram_cke(cke)
);
np_sdram_model #(.PERIOD_NS(20.8333)) u_sdram (
	.clk(clk), .cke(cke), .cs_n(ncs), .ras_n(nras), .cas_n(ncas), .we_n(nwe),
	.ba(sba), .a(sa), .dqm(dqm), .din(sd_din), .dq(dq), .dq_oe()
);

// --- replay and capture ----------------------------------------------------------------------
string     f_wr, f_out;
integer    fw, fo, cycles = 0, n = 0, late = 0, nw = 0;
longint    clk_n = 0, next_clk = -1;
reg  [7:0] next_kind, next_val;

task automatic fetch;
	integer r;
	r = $fscanf(fw, "%d %c %h\n", next_clk, next_kind, next_val);
	if (r != 3) next_clk = -1;
endtask

always @(posedge clk) begin
	clk_n  <= clk_n + 1;
	oki_we <= 1'b0;
	if (!rst && next_clk >= 0 && clk_n >= next_clk) begin
		if (clk_n > next_clk) late = late + 1;
		if (next_kind == "o") begin oki_we <= 1'b1; oki_din <= next_val; nw = nw + 1; end
		else bank <= next_val[0];
		fetch();
	end
	if (dut.u_oki.cen_sr) begin
		$fwrite(fo, "%c%c", sound[7:0], {{2{sound[13]}}, sound[13:8]});
		n = n + 1;
	end
	if (clk_n == cycles) begin
		$fclose(fo);
		$display("DONE: %0d samples, %0d writes (%0d late), %0d SDRAM model errors", n, nw, late, u_sdram.errors);
		$finish;
	end
end

initial begin
	if (!$value$plusargs("writes=%s", f_wr) || !$value$plusargs("out=%s", f_out) ||
	    !$value$plusargs("cycles=%d", cycles)) begin
		$display("ERROR: +writes= +out= +cycles= are required"); $finish;
	end
	fw = $fopen(f_wr, "r");
	fo = $fopen(f_out, "wb");
	fetch();
	repeat (16) @(posedge clk);
	rst_sd = 1'b0;
	repeat (4) @(posedge clk);
	while (init) @(posedge clk);
	rst = 1'b0;
end

endmodule

`default_nettype wire
