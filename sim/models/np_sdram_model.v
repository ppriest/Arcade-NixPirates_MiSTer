// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// Cycle-based model of the MiSTer SDRAM's MT48LC16M16 (4 banks x 8K rows x 512
// columns x 16 bits) for Verilator benches, where Micron's model, with its
// delays and inout bus, does not run. It decodes the commands on each rising
// edge and checks the timing a controller must respect, in clocks of
// PERIOD_NS, with the limits of jtcores' copy of Micron's model
// (sim/models/mt48lc16m16a2.v: tRCD 15, tRP 15, tRAS 37, tRC 60, tRRD 14,
// tRFC 66, tWR 14 ns, tMRD 2 clocks). sim/sdram_xcheck_tb runs it beside
// Micron's model on the same pins and compares every word read.
//
// Supported: LOAD MODE (CAS latency 2 or 3, burst 1/2/4/8, sequential, burst
// or single-location writes), ACTIVE, READ and WRITE with auto-precharge,
// PRECHARGE one or all, AUTO REFRESH, BURST TERMINATE; a READ or WRITE ends
// the read burst in flight, a PRECHARGE or BURST TERMINATE ends it CL-1 clocks
// on; DQM masks writes at once and reads two clocks on (a masked byte floats,
// which Verilator's two states make 0).
// Each violation is printed (the first ERRMAX) and counted in `errors`. Commands before
// the first PRECHARGE, which opens every power-up sequence, are ignored: they are the
// controller's outputs while it is held in reset.
//
// Data: dq is what the controller samples on the edge after the model drives
// it; dq_oe is high in those clocks. With CLK_LAG the model runs on the falling edge, as a chip
// whose clock trails the controller's, so a read returns a clock sooner: the pair for
// jtframe_sdram64's SHIFTED=1. Bank contents load from little-endian
// 16-bit word files: +sdram_bank0=<file> ... +sdram_bank3=<file>; +sdram_be reads them
// big-endian, as Micron's model's $fread does.

`timescale 1ns/1ps

module np_sdram_model #(
	parameter real PERIOD_NS = 20.8333,
	parameter      ERRMAX    = 20,
	parameter      CLK_LAG   = 0    // 1: the chip's clock lags the controller's (MiSTer's 5555 ps):
	                                // commands and data are taken and driven on the falling edge
) (
	input  wire        clk,
	input  wire        cke,
	input  wire        cs_n,
	input  wire        ras_n,
	input  wire        cas_n,
	input  wire        we_n,
	input  wire  [1:0] ba,
	input  wire [12:0] a,
	input  wire  [1:0] dqm,       // {DQMH, DQML}
	input  wire [15:0] din,
	output reg  [15:0] dq = 16'd0,
	output reg         dq_oe = 1'b0
);

localparam WORDS = 1 << 22;
reg [15:0] mem0 [0:WORDS-1];
reg [15:0] mem1 [0:WORDS-1];
reg [15:0] mem2 [0:WORDS-1];
reg [15:0] mem3 [0:WORDS-1];

integer errors = 0, reads = 0, writes = 0, refreshes = 0, acts = 0;
integer t = 0;                      // clock count
integer c_rcd, c_rp, c_ras, c_rc, c_rrd, c_rfc, c_wr, c_mrd;

// per bank
reg        open [0:3];
reg [12:0] row  [0:3];
integer    t_act [0:3], t_pre [0:3], t_wr [0:3];
reg        ap_pending [0:3];        // auto-precharge after the burst or write
integer    ap_at [0:3];
integer    t_any_act = -1000, t_ref = -1000, t_mode = -1000;
reg        mode_set = 1'b0;
reg        powered  = 1'b0;   // commands before the first PRECHARGE are a controller's reset state
integer    cl = 2, bl = 1;
reg        wsingle = 1'b1;

// read pipeline: slot k is driven at the edge k+1 from now, for the controller to sample
// the edge after. A READ sampled at edge T is sampled back at T+CL: slot CL-2.
localparam PD = 16;
reg        pv [0:PD-1];
reg  [1:0] pb [0:PD-1];
reg [21:0] pa [0:PD-1];
reg  [1:0] dqm_h1 = 2'b00;

integer i, k;
reg [8:0] col;

function integer clocks(input real ns);
	clocks = $rtoi($ceil(ns / PERIOD_NS - 0.001));
endfunction

task err(input [8*96-1:0] msg);
	begin
		if (errors < ERRMAX) $display("SDRAM ERROR at clock %0d: %0s", t, msg);
		errors = errors + 1;
	end
endtask

function [15:0] rd(input [1:0] b, input [21:0] w);
	case (b)
		2'd0: rd = mem0[w];
		2'd1: rd = mem1[w];
		2'd2: rd = mem2[w];
		default: rd = mem3[w];
	endcase
endfunction

task wr(input [1:0] b, input [21:0] w, input [15:0] d, input [1:0] m);
	reg [15:0] v;
	begin
		v = rd(b, w);
		if (!m[0]) v[7:0]  = d[7:0];
		if (!m[1]) v[15:8] = d[15:8];
		case (b)
			2'd0: mem0[w] = v;
			2'd1: mem1[w] = v;
			2'd2: mem2[w] = v;
			default: mem3[w] = v;
		endcase
	end
endtask

task load(input integer b, input [8*256-1:0] f, input be);
	integer fd, n, j;
	reg [7:0] lo, hi;
	begin
		fd = $fopen(f, "rb");
		if (fd == 0) begin $display("SDRAM model: cannot open %0s", f); end
		else begin
			for (j = 0; j < WORDS; j = j + 1) begin
				if (be) begin hi = $fgetc(fd); lo = $fgetc(fd); end
				else    begin lo = $fgetc(fd); hi = $fgetc(fd); end
				case (b)
					0: mem0[j] = {hi, lo};
					1: mem1[j] = {hi, lo};
					2: mem2[j] = {hi, lo};
					default: mem3[j] = {hi, lo};
				endcase
			end
			$fclose(fd);
		end
	end
endtask

reg [8*256-1:0] fname;
initial begin
	c_rcd = clocks(15.0); c_rp = clocks(15.0); c_ras = clocks(37.0); c_rc = clocks(60.0);
	c_rrd = clocks(14.0); c_rfc = clocks(66.0); c_wr = clocks(14.0); c_mrd = 2;
	for (i = 0; i < 4; i = i + 1) begin
		open[i] = 1'b0; row[i] = 13'd0; t_act[i] = -1000; t_pre[i] = -1000; t_wr[i] = -1000;
		ap_pending[i] = 1'b0; ap_at[i] = 0;
	end
	for (i = 0; i < PD; i = i + 1) begin pv[i] = 1'b0; pb[i] = 2'd0; pa[i] = 22'd0; end
	for (i = 0; i < WORDS; i = i + 1) begin mem0[i] = 16'd0; mem1[i] = 16'd0; mem2[i] = 16'd0; mem3[i] = 16'd0; end
	if ($value$plusargs("sdram_bank0=%s", fname)) load(0, fname, $test$plusargs("sdram_be"));
	if ($value$plusargs("sdram_bank1=%s", fname)) load(1, fname, $test$plusargs("sdram_be"));
	if ($value$plusargs("sdram_bank2=%s", fname)) load(2, fname, $test$plusargs("sdram_be"));
	if ($value$plusargs("sdram_bank3=%s", fname)) load(3, fname, $test$plusargs("sdram_be"));
end

wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
localparam LMR = 4'b0000, REF = 4'b0001, PRE = 4'b0010, ACT = 4'b0011,
           WRT = 4'b0100, RDC = 4'b0101, BST = 4'b0110;

wire sclk = CLK_LAG ? ~clk : clk;
always @(posedge sclk) if (cke) begin
	t = t + 1;
	// drive this clock's read slot, masked by the DQM sampled an edge before: two edges
	// ahead of the controller's sample, as Micron's Dqm_reg0. A masked byte floats.
	dq_oe <= pv[0];
	if (pv[0]) begin
		dq <= rd(pb[0], pa[0]);
		if (dqm_h1[0]) dq[7:0]  <= 8'hzz;
		if (dqm_h1[1]) dq[15:8] <= 8'hzz;
	end
	for (k = 0; k < PD - 1; k = k + 1) begin
		pv[k] = pv[k+1]; pb[k] = pb[k+1]; pa[k] = pa[k+1];
	end
	pv[PD-1] = 1'b0;
	dqm_h1 = dqm;

	// auto-precharges that come due
	for (i = 0; i < 4; i = i + 1)
		if (ap_pending[i] && t >= ap_at[i]) begin
			ap_pending[i] = 1'b0; open[i] = 1'b0; t_pre[i] = t;
		end

	if (cmd == PRE) powered = 1'b1;
	if (powered) case (cmd)
		LMR: begin
			for (i = 0; i < 4; i = i + 1) begin
				if (open[i]) err("LOAD MODE with a bank open");
				if (t - t_pre[i] < c_rp) err("tRP before LOAD MODE");
			end
			cl = a[6:4];
			bl = a[2:0] == 3'd0 ? 1 : a[2:0] == 3'd1 ? 2 : a[2:0] == 3'd2 ? 4 : a[2:0] == 3'd3 ? 8 : 0;
			wsingle = a[9];
			if (cl != 2 && cl != 3) err("CAS latency not 2 or 3");
			if (bl == 0) err("unsupported burst length");
			if (a[3]) err("interleaved bursts not modelled");
			mode_set = 1'b1; t_mode = t;
		end
		REF: begin
			for (i = 0; i < 4; i = i + 1) begin
				if (open[i]) err("AUTO REFRESH with a bank open");
				if (t - t_pre[i] < c_rp) err("tRP before AUTO REFRESH");
			end
			if (t - t_ref < c_rfc) err("tRFC between AUTO REFRESHes");
			t_ref = t; refreshes = refreshes + 1;
		end
		PRE: begin
			for (i = 0; i < 4; i = i + 1)
				if (a[10] || ba == i[1:0]) begin
					if (open[i] && t - t_act[i] < c_ras) err("tRAS before PRECHARGE");
					if (open[i] && t - t_wr[i] < c_wr) err("tWR before PRECHARGE");
					if (open[i]) t_pre[i] = t;
					open[i] = 1'b0; ap_pending[i] = 1'b0;
					// a PRECHARGE ends the bank's read burst CL-1 clocks on
					for (k = cl - 2; k < PD; k = k + 1) if (pv[k] && pb[k] == i[1:0]) pv[k] = 1'b0;
				end
		end
		ACT: begin
			if (!mode_set) err("ACTIVE before LOAD MODE");
			if (open[ba]) err("ACTIVE on an open bank");
			if (t - t_pre[ba] < c_rp) err("tRP before ACTIVE");
			if (t - t_act[ba] < c_rc) err("tRC before ACTIVE");
			if (t - t_any_act < c_rrd) err("tRRD before ACTIVE");
			if (t - t_ref < c_rfc) err("tRFC before ACTIVE");
			if (t - t_mode < c_mrd) err("tMRD before ACTIVE");
			open[ba] = 1'b1; row[ba] = a; t_act[ba] = t; t_any_act = t; acts = acts + 1;
		end
		RDC, WRT: begin
			if (!open[ba]) err(cmd == RDC ? "READ on a closed bank" : "WRITE on a closed bank");
			if (t - t_act[ba] < c_rcd) err("tRCD before READ or WRITE");
			// a READ or WRITE ends the read burst in flight
			if (cmd == WRT && dq_oe) err("WRITE while read data is on the bus");
			for (k = (cmd == RDC ? cl - 2 : 0); k < PD; k = k + 1) pv[k] = 1'b0;
			if (cmd == WRT) begin
				if (!wsingle && bl != 1) err("burst writes not modelled");
				wr(ba, {row[ba], a[8:0]}, din, dqm);
				t_wr[ba] = t; writes = writes + 1;
				if (a[10]) begin ap_pending[ba] = 1'b1; ap_at[ba] = t + c_wr + 1; end
			end else begin
				for (k = 0; k < bl; k = k + 1) begin
					pv[cl - 2 + k] = 1'b1;
					pb[cl - 2 + k] = ba;
					// sequential burst, wrapping within the burst's aligned block
					col = (a[8:0] & ~(bl - 1)) | ((a[8:0] + k) & (bl - 1));
					pa[cl - 2 + k] = {row[ba], col};
				end
				reads = reads + 1;
				if (a[10]) begin ap_pending[ba] = 1'b1; ap_at[ba] = t + bl; end
			end
		end
		BST: for (k = cl - 2; k < PD; k = k + 1) pv[k] = 1'b0;
		default: ;
	endcase
end

endmodule
