// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// ROADMAP Phase 0, exit criterion 2: np_main's 68000 boots a set from its
// decrypted program ROM (SDRAM bank 0 as rtl/np_rom_loader.sv leaves it) and
// its bus trace is compared with MAME's (scripts/compare_boot_trace.py).
//
//   +bank0=<file>   bank 0 image, 16-bit little-endian words (scripts/sdram_model.py --out)
//   +replay=<file>  MAME's I/O reads in order (compare_boot_trace.py replay)
//   +trace=<file>   RTL trace out, "seq rw addr mask data"
//   +n=<count>      bus accesses to log
//   +genix          the genix protection variant
//   -GCACHE_SIZE=   program-ROM cache bytes, -GTAG_RAM= its tag storage (jtframe_romrq_lcache)
//
// The program ROM sits behind jtframe_rom_1slot's line cache and a stand-in for one
// jtframe_sdram64 bank (below). Every read that is neither ROM nor RAM (regions.json
// "trace") takes the next replayed value. IRQ1 is raised at MAME's vblank times counted
// in delivered 68000 clocks, so SDRAM stalls do not move it: every 800000/3 clocks from
// the start, at whole frames of 60 Hz (pirates.cpp 449). Measured in MAME 0.289: each
// level-1 vector fetch falls 40-54 clocks after k * 266666.7 (k = 17-20).

`timescale 1ns/1ps
`default_nettype none

module tb_boot #(parameter CACHE_SIZE = 16384, TAG_RAM = 1, IDEAL_ROM = 0, SDRAM = 0);

reg clk = 1'b0;
always #10.4167 clk = ~clk;

reg         rst = 1'b1, rst_sd = 1'b1, genix = 1'b0, vblank = 1'b0;
reg  [15:0] io_data = 16'hffff;

wire        rom_cs, rom_ok;
wire [18:0] rom_addr;
wire [15:0] rom_data;
wire [23:0] A;
wire        as_n, rw_n, dtack_n, cen;
wire  [1:0] ds_n;
wire  [2:0] fc;
wire [15:0] din, dout;

np_main dut (
	.clk(clk), .rst(rst), .genix(genix), .cpu_run(1'b1), .vblank(vblank),
	.rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
	.inputs_in(io_data), .system_in(io_data),
	.out_we(), .out_d(), .scroll(), .oki_we(), .oki_din(), .oki_dout(io_data[7:0]),
	.hs_access(1'b0), .hs_addr(16'd0), .hs_we(1'b0), .hs_din(8'd0), .hs_dout(),
	.wram_b_addr(15'd0), .wram_b_dout(),
	.pal_b_addr(13'd0), .pal_b_dout(), .vram_b_addr(14'd0), .vram_b_dout(),
	.spr_b_addr(10'd0), .spr_b_dout(), .spr_wr(), .spr_wr_addr(), .spr_wr_din(), .spr_wr_be(),
	.dbg_addr(A), .dbg_as_n(as_n), .dbg_rw_n(rw_n), .dbg_ds_n(ds_n), .dbg_fc(fc),
	.dbg_din(din), .dbg_dout(dout), .dbg_dtack_n(dtack_n), .dbg_cen(cen)
);

// --- program ROM: jtframe_rom_1slot's line cache and a one-bank stand-in -------------------
// The stand-in answers like a jtframe_sdram64 bank at BA0_LEN 64: ack a clock after rd, then
// after 4-11 clocks four words on consecutive clocks, dst with the first, rdy with the last.
wire        ba_rd;
wire [21:0] ba_addr;
reg         ba_ack = 1'b0, ba_dst = 1'b0, ba_rdy = 1'b0;
reg  [15:0] ba_dout = 16'd0;

// -GIDEAL_ROM=1: the program ROM answers in the same clock, for measuring the 68000 alone
wire [15:0] slot_data;
wire        slot_ok;
assign rom_data = IDEAL_ROM ? {bank0[2*rom_addr+1], bank0[2*rom_addr]} : slot_data;
assign rom_ok   = IDEAL_ROM ? rom_cs : slot_ok;

jtframe_rom_1slot #(
	.SDRAMW(22), .SLOT0_DW(16), .SLOT0_AW(19), .CACHE0_LARGE(1), .CACHE0_SIZE(CACHE_SIZE),
	.SLOT0_BURSTLEN(64), .TAG_RAM(TAG_RAM)
) u_slot (
	.rst(rst), .clk(clk),
	.slot0_addr(rom_addr), .slot0_dout(slot_data), .slot0_cs(rom_cs), .slot0_ok(slot_ok),
	.sdram_ack(s_ack), .sdram_rd(ba_rd), .sdram_addr(ba_addr),
	.data_dst(s_dst), .data_rdy(s_rdy), .data_read(s_dout)
);

// -GSDRAM=1: jtframe_sdram64 as the core sets it up, on sim/models/np_sdram_model.v loaded
// with the bank images (+sdram_bank0=...), refresh once a 64 us line, the 68000 held in reset
// until the controller has initialised
wire        s_ack, s_dst, s_rdy, sd_init;
wire [15:0] s_dout;
reg  [11:0] hcnt = 12'd0;
always @(posedge clk) hcnt <= hcnt == 12'd3071 ? 12'd0 : hcnt + 12'd1;

generate if (SDRAM) begin : g_sdram
	wire  [3:0] ack, dst, rdy;
	wire [15:0] sd_dout, dq, sd_din;
	wire [12:0] sa;
	wire  [1:0] sba, dqm;
	wire        nwe, ncas, nras, ncs, cke;
	jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1),
		.BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(16)) u_ctl (
		.rst(rst_sd), .clk(clk), .init(sd_init),
		.ba0_addr(ba_addr), .ba1_addr(22'd0), .ba2_addr(22'd0), .ba3_addr(22'd0),
		.rd({3'd0, ba_rd}), .wr(4'd0),
		.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
		.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
		.prog_en(1'b0), .prog_addr(22'd0), .prog_rd(1'b0), .prog_wr(1'b0), .prog_din(16'd0),
		.prog_dsn(2'b11), .prog_ba(2'd0), .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
		.rfsh(hcnt == 12'd0),
		.ack(ack), .dst(dst), .dok(), .rdy(rdy), .dout(sd_dout),
		.sdram_dq(dq), .sdram_din(sd_din), .sdram_a(sa), .sdram_dqml(dqm[0]), .sdram_dqmh(dqm[1]),
		.sdram_ba(sba), .sdram_nwe(nwe), .sdram_ncas(ncas), .sdram_nras(nras), .sdram_ncs(ncs),
		.sdram_cke(cke)
	);
	np_sdram_model #(.PERIOD_NS(20.8333)) u_sdram (
		.clk(clk), .cke(cke), .cs_n(ncs), .ras_n(nras), .cas_n(ncas), .we_n(nwe),
		.ba(sba), .a(sa), .dqm(dqm), .din(sd_din), .dq(dq), .dq_oe()
	);
	assign s_ack = ack[0], s_dst = dst[0], s_rdy = rdy[0], s_dout = sd_dout;
end else begin : g_standin
	assign s_ack = ba_ack, s_dst = ba_dst, s_rdy = ba_rdy, s_dout = ba_dout, sd_init = 1'b0;
end endgenerate

reg  [7:0] bank0 [0:2*(1<<19)-1];
integer    lat = 0, beat = 0, rom_reads = 0, rom_wait = 0;
reg [21:0] burst_a;
always @(posedge clk) begin
	ba_ack <= 1'b0; ba_dst <= 1'b0; ba_rdy <= 1'b0;
	if (beat > 0) begin
		ba_dout <= {bank0[2*(burst_a+beat)+1], bank0[2*(burst_a+beat)]};
		ba_rdy  <= beat == 3;
		beat = beat == 3 ? 0 : beat + 1;
	end else if (!SDRAM && ba_rd && !ba_ack && lat == 0) begin
		ba_ack  <= 1'b1;
		burst_a  = ba_addr;
		lat = 4 + ($urandom & 7);
	end else if (lat == 1) begin
		ba_dout <= {bank0[2*burst_a+1], bank0[2*burst_a]};
		ba_dst  <= 1'b1;
		beat = 1;
		lat  = 0;
	end else if (lat > 1)
		lat = lat - 1;
	if (rom_cs && !rom_ok) rom_wait = rom_wait + 1;
	if (ba_rd && s_ack) rom_reads = rom_reads + 1;
end

// --- MAME's vblank, in delivered 68000 clocks -----------------------------------------------
longint cycles = 0, sysclk = 0;
longint next3  = 64'd800000;        // thirds of a clock: one frame, 800000 / 3
always @(posedge clk) begin
	if (!rst) sysclk = sysclk + 1;
	if (cen) begin
		cycles = cycles + 1;
		if (cycles * 3 >= next3) begin
			vblank <= 1'b1;
			next3 = next3 + 64'd800000;
		end else if (vblank && cycles * 3 >= next3 - 64'd800000 + 64'd3000)
			vblank <= 1'b0;
	end
end

// --- bus cycle lengths in 68000 phases, AS low to AS high: 5 is no wait state -------------
integer as_ph = 0, hist [0:15], whist [0:15];
reg as_q = 1'b1, rw_q = 1'b1;
always @(posedge clk) begin
	as_q <= as_n;
	if (!as_n) rw_q <= rw_n;
	if (!as_n && (cen || dut.cenb)) as_ph = as_ph + 1;
	if (as_n && !as_q) begin
		if (!rst) hist[as_ph > 15 ? 15 : as_ph] = hist[as_ph > 15 ? 15 : as_ph] + 1;
		if (!rst && !rw_q) whist[as_ph > 15 ? 15 : as_ph] = whist[as_ph > 15 ? 15 : as_ph] + 1;
		as_ph = 0;
	end
end
final begin : show
	integer k;
	for (k = 0; k < 16; k = k + 1) if (hist[k] != 0) $display("ASLEN: %0d phases: %0d cycles, %0d of them writes", k, hist[k], whist[k]);
end

// --- replay and trace -----------------------------------------------------------------------
function automatic bit is_rom(input [23:0] a); is_rom = a <= 24'h0fffff; endfunction
function automatic bit is_ram(input [23:0] a);
	is_ram = (a >= 24'h100000 && a <= 24'h10ffff) || (a >= 24'h500000 && a <= 24'h5007ff) ||
	         (a >= 24'h700000 && a <= 24'h700001) || (a >= 24'h800000 && a <= 24'h803fff) ||
	         (a >= 24'h900000 && a <= 24'h904187);
endfunction

string  bank_f, replay_f, trace_f;
integer fd_rp, fd_tr, n_max, n = 0, r, errors = 0, replayed = 0;
reg [23:0] rp_a;
reg [31:0] rp_m, rp_d;
reg        as_l = 1'b1, in_cycle = 1'b0, cyc_rw = 1'b1;
reg [23:0] cyc_a;
reg  [1:0] cyc_ds;
reg [15:0] cyc_d;

always @(posedge clk) begin
	as_l <= as_n;
	// a cycle starts: replay an I/O read
	if (!rst && as_l && !as_n && !(&fc)) begin
		in_cycle <= 1'b1;
		cyc_a    <= A;
		cyc_rw   <= rw_n;
		cyc_ds   <= 2'b11;
		if (rw_n && !is_rom(A) && !is_ram(A)) begin
			r = $fscanf(fd_rp, "%h %h %h\n", rp_a, rp_m, rp_d);
			if (r != 3) begin
				if (errors < 10) $display("ERROR: replay ran out at access %0d, %06x", n + 1, A);
				errors = errors + 1;
			end else begin
				if (rp_a != A && errors < 10) $display("NOTE: replay entry %06x for read of %06x", rp_a, A);
				io_data <= rp_d[15:0];
				replayed = replayed + 1;
			end
		end
	end
	if (in_cycle && !as_n) begin
		cyc_ds <= cyc_ds & ds_n;
		cyc_d  <= cyc_rw ? din : dout;
	end
	// a cycle ends: log it
	if (in_cycle && as_n) begin
		in_cycle <= 1'b0;
		n = n + 1;
		if (n % 100000 == 0)
			$display("ACC: access %0d, 68000 clock %0d", n, cycles);
		if (cyc_rw && cyc_a == 24'h000064)
			$display("VEC: level-1 vector fetch at access %0d, 68000 clock %0d", n, cycles);
		$fwrite(fd_tr, "%0d\t%s\t%06X\t%04X\t%04X\n", n, cyc_rw ? "r" : "w", cyc_a,
		        {{8{~cyc_ds[1]}}, {8{~cyc_ds[0]}}}, cyc_d);
		if (n >= n_max) begin
			$fclose(fd_tr);
			$display("DONE: %0d accesses, %0d replayed, %0d line fills, %0d clocks with ROM not ready, %0d 68000 clocks in %0d clocks, %0d errors",
			         n, replayed, rom_reads, rom_wait, cycles, sysclk, errors);
			$finish;
		end
	end
end

initial begin : setup
	integer fd, k;
	for (k = 0; k < 16; k = k + 1) begin hist[k] = 0; whist[k] = 0; end
	if (!$value$plusargs("bank0=%s", bank_f) || !$value$plusargs("replay=%s", replay_f) ||
	    !$value$plusargs("trace=%s", trace_f) || !$value$plusargs("n=%d", n_max)) begin
		$display("ERROR: +bank0= +replay= +trace= +n= are required"); $finish;
	end
	genix = $test$plusargs("genix");
	fd = $fopen(bank_f, "rb");
	k  = $fread(bank0, fd);
	$fclose(fd);
	if (k != 2*(1<<19)) $display("NOTE: bank 0 file gave %0d bytes", k);
	fd_rp = $fopen(replay_f, "r");
	fd_tr = $fopen(trace_f, "w");
	$fwrite(fd_tr, "# np_main bus accesses from reset (sim/boot_tb)\n# seq\trw\taddr\tmask\tdata\n");
	repeat (16) @(posedge clk);
	rst_sd = 1'b0;
	repeat (4) @(posedge clk);
	while (sd_init) @(posedge clk);
	rst = 1'b0;
end

endmodule

`default_nettype wire
