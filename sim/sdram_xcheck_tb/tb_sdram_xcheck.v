// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// sim/models/np_sdram_model.v against Micron's model (sim/models/mt48lc16m16a2.v),
// both on the pins of one jtframe_sdram64 at 48 MHz (AW 22, HF 0, MISTER DQM on
// A12/A11, banks at 64/32/32/16 bits) under random reads and writes on all four
// banks, refresh once a 64 us line. On every clock where np_sdram_model drives
// read data, the bus must carry the same word from Micron's model; every read
// burst must come back whole; and the controller's own requesters check each
// word against a shadow of their writes. iverilog only (Micron's model).
//
//   +ms=<n> simulated milliseconds (default 4); +load=<%> chance a free requester starts a
//   request each clock (default 35); bank files sdram_bank{0..3}.bin
//   in the working directory, big-endian words, for both models (+sdram_be).

`timescale 1ns/1ps

module tb_sdram_xcheck;

localparam real PERIOD = 20.8333;
reg clk = 1'b0, rst = 1'b1;
always #(PERIOD / 2) clk = ~clk;

reg [11:0] hcnt = 12'd0;
always @(posedge clk) hcnt <= hcnt == 12'd3071 ? 12'd0 : hcnt + 12'd1;

wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire  [1:0] sdram_ba, sdram_dqm;
wire        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, init;
wire  [3:0] ack, dst, dok, rdy;
wire [15:0] dout;
reg   [3:0] rd = 4'd0, wr = 4'd0;
reg  [21:0] addr [0:3];
reg  [15:0] wdat [0:3];
reg   [1:0] wdsn [0:3];

jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1),
	.BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(16),
	.BA1_WEN(1), .BA2_WEN(1), .BA3_WEN(1)) u_ctl (
	.rst(rst), .clk(clk), .init(init),
	.ba0_addr(addr[0]), .ba1_addr(addr[1]), .ba2_addr(addr[2]), .ba3_addr(addr[3]),
	.rd(rd), .wr(wr),
	.ba0_din(wdat[0]), .ba0_dsn(wdsn[0]), .ba1_din(wdat[1]), .ba1_dsn(wdsn[1]),
	.ba2_din(wdat[2]), .ba2_dsn(wdsn[2]), .ba3_din(wdat[3]), .ba3_dsn(wdsn[3]),
	.prog_en(1'b0), .prog_addr(22'd0), .prog_rd(1'b0), .prog_wr(1'b0), .prog_din(16'd0),
	.prog_dsn(2'b11), .prog_ba(2'd0), .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
	.rfsh(hcnt == 12'd0),
	.ack(ack), .dst(dst), .dok(dok), .rdy(rdy), .dout(dout),
	.sdram_dq(sdram_dq), .sdram_a(sdram_a), .sdram_dqml(sdram_dqm[0]), .sdram_dqmh(sdram_dqm[1]),
	.sdram_ba(sdram_ba), .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
	.sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
);

mt48lc16m16a2 u_micron (
	.Clk(clk), .Cke(sdram_cke), .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba),
	.Cs_n(sdram_ncs), .Ras_n(sdram_nras), .Cas_n(sdram_ncas), .We_n(sdram_nwe), .Dqm(sdram_dqm),
	.downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
);

np_sdram_model #(.PERIOD_NS(PERIOD)) u_model (
	.clk(clk), .cke(sdram_cke), .cs_n(sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas),
	.we_n(sdram_nwe), .ba(sdram_ba), .a(sdram_a), .dqm(sdram_dqm), .din(sdram_dq),
	.dq(), .dq_oe()
);

// --- the two models agree on every word read ------------------------------------------------
// The mode register's burst is the longest bank's (4 words), so a shorter bank's read leaves
// burst words the controller does not take; both models drive them, and they are compared too.
// A clock where Micron's model drives the bus and the controller does not, with np_sdram_model
// silent, is a missed word.
integer compared = 0, mismatches = 0, missed = 0;
always @(posedge clk) if (!u_model.dq_oe && sdram_dq !== 16'hzzzz && u_ctl.dq_pad === 16'hzzzz) begin
	if (missed < 10) $display("MISSED at %t: Micron drives %h, np_sdram_model silent", $time, sdram_dq);
	missed = missed + 1;
end
always @(posedge clk) if (u_model.dq_oe) begin
	compared = compared + 1;
	if (sdram_dq !== u_model.dq) begin
		if (mismatches < 10) $display("MISMATCH at %t: Micron %h, np_sdram_model %h", $time, sdram_dq, u_model.dq);
		mismatches = mismatches + 1;
	end
end

// --- random requesters, one a bank ----------------------------------------------------------
localparam integer LEN0 = 4, LEN1 = 2, LEN2 = 2, LEN3 = 1;
function integer blen(input integer b);
	blen = b == 0 ? LEN0 : b == 1 ? LEN1 : b == 2 ? LEN2 : LEN3;
endfunction

reg  [15:0] shadow [0:3][0:255];     // 256 words a bank, so reads hit earlier writes
reg  [ 3:0] known  [0:3];
reg         busy   [0:3];
reg         isrd   [0:3];
integer     beat   [0:3];
integer     nrd = 0, nwr = 0, words = 0, data_err = 0, b, j, load = 35;
reg  [21:0] base   [0:3];

initial begin
	for (b = 0; b < 4; b = b + 1) begin
		busy[b] = 0; isrd[b] = 0; beat[b] = 0; addr[b] = 0; wdat[b] = 0; wdsn[b] = 2'b11;
		base[b] = $urandom & 22'h3ffe00;
	end
end

task start(input integer bb);
	reg [7:0] w;
	begin
		w = $urandom;
		if (($urandom % 100) < 30) begin
			isrd[bb] = 0;
			addr[bb] = base[bb] | w;
			wdat[bb] = $urandom;
			wdsn[bb] = ($urandom % 3) == 0 ? 2'b01 : ($urandom % 2) ? 2'b10 : 2'b00;
			wr[bb] = 1'b1;
		end else begin
			isrd[bb] = 1;
			addr[bb] = base[bb] | (w & ~(blen(bb) - 1));
			rd[bb] = 1'b1;
		end
		busy[bb] = 1; beat[bb] = 0;
	end
endtask

// a word of a read burst: compare with the shadow where the shadow knows the word
// (both models start from the same random contents, so unknown words are not checked)
reg [255:0] written [0:3];
always @(posedge clk) if (!rst && !init) begin
	for (b = 0; b < 4; b = b + 1) begin
		if (ack[b]) begin rd[b] <= 1'b0; wr[b] <= 1'b0; end
		if (busy[b] && isrd[b] && dok[b]) begin
			j = (addr[b][7:0] + beat[b]) & 255;
			if (written[b][j] && dout !== shadow[b][j]) begin
				if (data_err < 10) $display("DATA ERROR bank %0d word %h: read %h, wrote %h", b, base[b] | j, dout, shadow[b][j]);
				data_err = data_err + 1;
			end
			beat[b] = beat[b] + 1;
			words = words + 1;
		end
		if (busy[b] && rdy[b]) begin
			if (isrd[b]) begin
				if (beat[b] != blen(b)) begin
					$display("SHORT BURST bank %0d: %0d of %0d words", b, beat[b], blen(b));
					data_err = data_err + 1;
				end
				nrd = nrd + 1;
			end else begin
				j = addr[b][7:0];
				if (!wdsn[b][0]) shadow[b][j][7:0]  = wdat[b][7:0];
				if (!wdsn[b][1]) shadow[b][j][15:8] = wdat[b][15:8];
				// a half-written word is known only if the other half was known
				if (wdsn[b] == 2'b00) written[b][j] = 1'b1;
				nwr = nwr + 1;
			end
			busy[b] = 0;
		end
		// no new requests in the first 8 us of each line, as blanking: jtframe_sdram64 refreshes
		// only when no bank requests (or its debt forces it, after eight lines)
		if (!busy[b] && hcnt >= 12'd384 && (($urandom % 100) < load)) start(b);
	end
end

integer ms;
initial begin
	if (!$value$plusargs("load=%d", load)) load = 35;
	for (b = 0; b < 4; b = b + 1) written[b] = 256'd0;
	if (!$value$plusargs("ms=%d", ms)) ms = 4;
	repeat (10) @(posedge clk);
	rst = 1'b0;
	#(ms * 1000000.0);
	$display("%s: %0d reads (%0d words taken, %0d driven and compared), %0d writes, %0d refreshes, %0d mismatches, %0d missed, %0d data errors, %0d np_sdram_model timing errors",
	         (mismatches == 0 && missed == 0 && data_err == 0 && u_model.errors == 0 && compared >= words && words > 0) ? "PASS" : "FAIL",
	         nrd, words, compared, nwr, u_model.refreshes, mismatches, missed, data_err, u_model.errors);
	$finish;
end

endmodule
