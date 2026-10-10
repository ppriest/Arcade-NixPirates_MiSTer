// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// np_rom_loader through the production transport: jtframe_sdram64 (as the core
// will configure it: AW 22, HF 0 at 48 MHz, MISTER DQM on A12/A11) and Micron's
// command-level model. A sample of download bytes (sim/loader_sdram_tb/
// run_loader_sdram_tb.py: every address bit of each region, and random offsets)
// is sent the way hps_io sends it, starting while the SDRAM still initialises.
// Then each expected (bank, word, lane, value) is read back from the model's
// arrays, and every bank is scanned for lanes written that should not be.
//
//   +bytes=<file>   lines "aaaaaa dd"            (download address, byte)
//   +expect=<file>  lines "b wwwwww l vv"        (bank, word, lane 1 = [15:8], value)

`timescale 1ns/1ps
`default_nettype none

module tb_loader_sdram;

localparam real PERIOD = 20.8333;   // 48 MHz
localparam WORDS = 1 << 22;

reg clk = 1'b0, rst = 1'b1;
always #(PERIOD / 2) clk = ~clk;

// refresh request once a 64 us line, as the video timing will
reg [11:0] hcnt = 12'd0;
always @(posedge clk) hcnt <= hcnt == 12'd3071 ? 12'd0 : hcnt + 12'd1;
wire rfsh = hcnt == 12'd0;

reg         ioctl_download = 1'b0, ioctl_wr = 1'b0;
reg  [26:0] ioctl_addr = 27'd0;
reg   [7:0] ioctl_dout = 8'd0;
wire        ioctl_wait, prog_en, prog_wr, prog_rdy, sdram_init;
wire [21:0] prog_addr;
wire  [1:0] prog_ba, prog_dsn;
wire [15:0] prog_din;

np_rom_loader u_loader (
	.clk(clk), .sdram_init(sdram_init),
	.ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.prog_en(prog_en), .prog_addr(prog_addr), .prog_ba(prog_ba), .prog_wr(prog_wr),
	.prog_din(prog_din), .prog_dsn(prog_dsn), .prog_rdy(prog_rdy)
);

wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire  [1:0] sdram_ba, sdram_dqm;
wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;

jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1)) u_sdram (
	.rst(rst), .clk(clk), .init(sdram_init),
	.ba0_addr(22'd0), .ba1_addr(22'd0), .ba2_addr(22'd0), .ba3_addr(22'd0),
	.rd(4'd0), .wr(4'd0),
	.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
	.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
	.prog_en(prog_en), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr),
	.prog_din(prog_din), .prog_dsn(prog_dsn), .prog_ba(prog_ba),
	.prog_dst(), .prog_dok(), .prog_rdy(prog_rdy), .prog_ack(),
	.rfsh(rfsh),
	.ack(), .dst(), .dok(), .rdy(), .dout(),
	.sdram_dq(sdram_dq), .sdram_a(sdram_a), .sdram_dqml(sdram_dqm[0]), .sdram_dqmh(sdram_dqm[1]),
	.sdram_ba(sdram_ba), .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
	.sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
);

mt48lc16m16a2 sdram (
	.Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
	.Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe), .Dqm(sdram_dqm),
	.downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
);

function automatic [15:0] word_of(input [1:0] b, input [21:0] w);
	case (b)
		2'd0: word_of = sdram.Bank0[w];
		2'd1: word_of = sdram.Bank1[w];
		2'd2: word_of = sdram.Bank2[w];
		default: word_of = sdram.Bank3[w];
	endcase
endfunction

reg [8*256-1:0] bytes_f, expect_f;
integer fd, r, n, errors, lanes_exp, lanes_got, writes, b, w, l;
reg [23:0] ad;
reg  [7:0] by, vv;
reg [15:0] x;

always @(posedge clk) if (prog_wr && prog_rdy) writes = writes + 1;

initial begin
	errors = 0; writes = 0; n = 0; lanes_exp = 0; lanes_got = 0;
	if (!$value$plusargs("bytes=%s", bytes_f) || !$value$plusargs("expect=%s", expect_f)) begin
		$display("ERROR: +bytes= and +expect= are required"); $finish;
	end
	repeat (8) @(posedge clk);
	rst = 1'b0;
	ioctl_download = 1'b1;           // before init ends: the loader must hold the HPS
	fd = $fopen(bytes_f, "r");
	while (!$feof(fd)) begin
		r = $fscanf(fd, "%h %h\n", ad, by);
		if (r == 2) begin
			while (ioctl_wait) @(posedge clk);
			ioctl_addr <= {3'd0, ad};
			ioctl_dout <= by;
			ioctl_wr   <= 1'b1;
			@(posedge clk);
			ioctl_wr   <= 1'b0;
			repeat (3) @(posedge clk);
			n = n + 1;
		end
	end
	$fclose(fd);
	while (ioctl_wait) @(posedge clk);
	ioctl_download = 1'b0;
	repeat (20) @(posedge clk);
	if (writes != n) begin $display("ERROR: %0d writes completed for %0d bytes", writes, n); errors = errors + 1; end

	fd = $fopen(expect_f, "r");
	while (!$feof(fd)) begin
		r = $fscanf(fd, "%d %h %d %h\n", b, w, l, vv);
		if (r == 4) begin
			x = word_of(b[1:0], w[21:0]);
			lanes_exp = lanes_exp + 1;
			if ((l ? x[15:8] : x[7:0]) !== vv) begin
				if (errors < 10) $display("ERROR: bank %0d word %06x lane %0d: %h, expected %02x", b, w, l, x, vv);
				errors = errors + 1;
			end
		end
	end
	$fclose(fd);
	// every lane not in the expect list must still be unwritten (x)
	for (b = 0; b < 4; b = b + 1)
		for (w = 0; w < WORDS; w = w + 1) begin
			x = word_of(b[1:0], w[21:0]);
			if (x[7:0] !== 8'hxx) lanes_got = lanes_got + 1;
			if (x[15:8] !== 8'hxx) lanes_got = lanes_got + 1;
		end
	if (lanes_got != lanes_exp) begin
		$display("ERROR: %0d lanes written, %0d expected", lanes_got, lanes_exp); errors = errors + 1;
	end
	$display("%s: %0d bytes, %0d writes, %0d lanes, %0d errors", errors ? "FAIL" : "PASS", n, writes, lanes_got, errors);
	$finish;
end

endmodule

`default_nettype wire
