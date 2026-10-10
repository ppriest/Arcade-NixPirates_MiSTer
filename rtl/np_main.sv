// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// The 68000 and its memory map, from MAME src/mame/nix/pirates.cpp prg_map()
// (340-359). fx68k at 16 MHz from 48 MHz through jtframe_68kdtack_cen (1/3:
// two phases every three clocks), which also holds DTACK while the program ROM
// is not ready and repays the phases withheld. Every RAM is here, each with a
// second port for the video, hiscore and state capture. Unmapped reads return
// 0 and unmapped writes are dropped, as MAME's. The second ports only read
// (np_dpram); other writers go through the CPU's port while it is paused.
//
// I/O read data comes from the parent (inputs, SYSTEM with the EEPROM's DO and
// the protection bit, the M6295's status), so a bench can replay MAME's.
//
// MAME's protection kludges, by the mod byte (rtl/np_rom_map.svh):
//   pirates/piratesb  program word 0x62c0 reads 0x6006 (init_pirates, 618)
//   genix             reads of 0x109e98/0x109e9a return 0x0004/0x0000; writes
//                     still reach work RAM (init_genix, 621, 632)

`default_nettype none

module np_main (
	input  wire        clk,
	input  wire        rst,
	input  wire        genix,
	input  wire        cpu_run,         // low freezes the 68000 (Pause): its clock enables are held

	input  wire        vblank,          // rising edge raises IRQ1; held to the acknowledge

	// program ROM, SDRAM bank 0 (np_sdram_rd)
	output wire        rom_cs,
	output wire [18:0] rom_addr,        // word address
	input  wire [15:0] rom_data,
	input  wire        rom_ok,

	// I/O
	input  wire [15:0] inputs_in,       // 0x300000
	input  wire [15:0] system_in,       // 0x400000
	output reg         out_we = 1'b0,   // 0x600001 out_w: EEPROM, OKI bank
	output reg   [7:0] out_d  = 8'd0,
	output reg  [15:0] scroll = 16'd0,  // 0x700000
	output reg         oki_we = 1'b0,   // 0xa00001
	output reg   [7:0] oki_din = 8'd0,
	input  wire  [7:0] oki_dout,

	// hiscore: work RAM port A, taken only while the 68000 is paused (hiscore.v pauses first);
	// a byte address in the 64 KB, the byte back a clock after the RAM's (registered here)
	input  wire        hs_access,
	input  wire [15:0] hs_addr,
	input  wire        hs_we,
	input  wire  [7:0] hs_din,
	output reg   [7:0] hs_dout = 8'd0,

	// second ports of the RAMs
	input  wire [14:0] wram_b_addr,
	output wire [15:0] wram_b_dout,
	input  wire [12:0] pal_b_addr,
	output wire [15:0] pal_b_dout,
	input  wire [13:0] vram_b_addr,
	output wire [15:0] vram_b_dout,
	input  wire  [9:0] spr_b_addr,
	output wire [15:0] spr_b_dout,
	output wire        spr_wr,          // CPU writes to sprite RAM, for np_video's snapshot
	output wire  [9:0] spr_wr_addr,
	output wire [15:0] spr_wr_din,
	output wire  [1:0] spr_wr_be,

	// bus, for benches and the debug probe
	output wire [23:0] dbg_addr,
	output wire        dbg_as_n,
	output wire        dbg_rw_n,
	output wire  [1:0] dbg_ds_n,        // {UDS, LDS}
	output wire  [2:0] dbg_fc,
	output wire [15:0] dbg_din,
	output wire [15:0] dbg_dout,
	output wire        dbg_dtack_n,
	output wire        dbg_cen
);

// --- CPU ---------------------------------------------------------------------------------

wire [23:1] eab;
wire [15:0] cpu_dout;
reg  [15:0] cpu_din = 16'd0;
wire        as_n, rw_n, uds_n, lds_n, dtack_n, cen, cenb;
wire  [2:0] fc;
reg         irq1_n = 1'b1;

wire [23:0] A    = {eab, 1'b0};
wire        iack = &fc && !as_n;
wire        bus  = !as_n && !(uds_n && lds_n) && !iack;   // a data transfer is under way

fx68k u_cpu (
	.clk(clk), .HALTn(1'b1), .extReset(rst), .pwrUp(rst),
	.enPhi1(cen & cpu_run), .enPhi2(cenb & cpu_run),
	.eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
	.E(), .VMAn(),
	.FC0(fc[0]), .FC1(fc[1]), .FC2(fc[2]),
	.BGn(), .oRESETn(), .oHALTEDn(),
	.DTACKn(dtack_n), .VPAn(~iack), .BERRn(1'b1),
	.BRn(1'b1), .BGACKn(1'b1),
	.IPL0n(irq1_n), .IPL1n(1'b1), .IPL2n(1'b1),
	.iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab),
	.stop_out()
);

// bus_cs is every access, not only the ROM's: a write's strobes come out at S4, and DTACK,
// registered from them, would miss that phase's sample and cost a wait state the board does
// not have (sim/boot_tb: 22% of cycles at 7 phases, +4% clocks against MAME). Flagged, the
// sampling phase is held until DTACK is low and repaid.
reg rom_ok_dly = 1'b0;
always @(posedge clk) rom_ok_dly <= rom_cs & rom_ok;

jtframe_68kdtack_cen #(.MFREQ(48000)) u_dtack (
	.rst(rst), .clk(clk), .cpu_cen(cen), .cpu_cenb(cenb),
	.bus_cs(bus), .bus_busy(rom_cs & ~rom_ok_dly), .bus_legit(1'b0), .bus_ack(1'b0),
	.ASn(as_n), .DSn({uds_n, lds_n}),
	.num(4'd1), .den(5'd3),
	.wait2(1'b0), .wait3(1'b0),
	.DTACKn(dtack_n), .fave(), .fworst()
);

// IRQ1: vblank's rising edge asserts, the acknowledge clears and wins a tie
// (irq1_line_hold, 442; LESSONS_LEARNED, "Give a held interrupt line's acknowledge priority")
reg vblank_l = 1'b0;
always @(posedge clk) begin
	vblank_l <= vblank;
	if (rst)                     irq1_n <= 1'b1;
	else if (iack)               irq1_n <= 1'b1;
	else if (vblank && !vblank_l) irq1_n <= 1'b0;
end

// --- decode (prg_map) --------------------------------------------------------------------

wire sel_rom = A[23:20] == 4'h0;                          // 0x000000-0x0fffff
wire sel_wram= A[23:16] == 8'h10;                         // 0x100000-0x10ffff
wire sel_in  = A[23:1]  == 23'h180000;                    // 0x300000
wire sel_sys = A[23:1]  == 23'h200000;                    // 0x400000
wire sel_spr = A[23:11] == 13'h0a00;                      // 0x500000-0x5007ff, write only
wire sel_out = A[23:1]  == 23'h300000;                    // 0x600000, out_w on the low byte
wire sel_scr = A[23:1]  == 23'h380000;                    // 0x700000, write only
wire sel_pal = A[23:14] == 10'h200;                       // 0x800000-0x803fff
wire sel_vram= A[23:16] == 8'h90 && A[15:0] < 16'h4188;   // 0x900000-0x904187
wire sel_oki = A[23:1]  == 23'h500000;                    // 0xa00000, M6295 on the low byte
wire genix_prot = genix && A[23:2] == 22'h0427a6;         // 0x109e98-0x109e9b

assign rom_cs   = bus && rw_n && sel_rom;
assign rom_addr = A[19:1];

// one write strobe per bus cycle, once the data strobes are out
reg  wr_done = 1'b0;
wire wr      = bus && !rw_n && !wr_done;
always @(posedge clk) wr_done <= as_n ? 1'b0 : (wr_done | wr);
wire [1:0] be = {~uds_n, ~lds_n};

wire [15:0] wram_dout, pal_dout, vram_dout;

// 68000 big-endian: an even byte is the high lane
wire  [1:0] hs_be = hs_addr[0] ? 2'b01 : 2'b10;
np_dpram #(.AW(15)) u_wram (
	.clk(clk),
	.a_addr(hs_access ? hs_addr[15:1] : A[15:1]),
	.a_we(hs_access ? {2{hs_we}} & hs_be : {2{wr && sel_wram}} & be),
	.a_din(hs_access ? {hs_din, hs_din} : cpu_dout), .a_dout(wram_dout),
	.b_addr(wram_b_addr), .b_dout(wram_b_dout)
);
always @(posedge clk) hs_dout <= hs_addr[0] ? wram_dout[7:0] : wram_dout[15:8];

np_dpram #(.AW(13)) u_pal (
	.clk(clk),
	.a_addr(A[13:1]), .a_we({2{wr && sel_pal}} & be), .a_din(cpu_dout), .a_dout(pal_dout),
	.b_addr(pal_b_addr), .b_dout(pal_b_dout)
);

// 0x4188 bytes, 8388 words, decoded; the RAM is the full 16K words, because Quartus left an
// 8388-deep one in registers (np_cpu_synth: 134,240 of them). MAME's split into the three
// layers is the video's business (352-356).
np_dpram #(.AW(14)) u_vram (
	.clk(clk),
	.a_addr(A[14:1]), .a_we({2{wr && sel_vram}} & be), .a_din(cpu_dout), .a_dout(vram_dout),
	.b_addr(vram_b_addr), .b_dout(vram_b_dout)
);

np_dpram #(.AW(10)) u_spr (
	.clk(clk),
	.a_addr(A[10:1]), .a_we({2{wr && sel_spr}} & be), .a_din(cpu_dout), .a_dout(),
	.b_addr(spr_b_addr), .b_dout(spr_b_dout)
);

always @(posedge clk) begin
	out_we <= 1'b0;
	oki_we <= 1'b0;
	if (wr && sel_out && be[0]) begin out_we <= 1'b1; out_d <= cpu_dout[7:0]; end
	if (wr && sel_oki && be[0]) begin oki_we <= 1'b1; oki_din <= cpu_dout[7:0]; end
	if (wr && sel_scr) begin
		if (be[1]) scroll[15:8] <= cpu_dout[15:8];
		if (be[0]) scroll[7:0]  <= cpu_dout[7:0];
	end
end

// read data, a clock behind the address; the 68000 samples it phases later
always @(posedge clk) begin
	cpu_din <= 16'd0;
	if (sel_rom)       cpu_din <= (!genix && A[19:1] == 19'h03160) ? 16'h6006 : rom_data;
	else if (sel_wram) cpu_din <= genix_prot ? (A[1] ? 16'h0000 : 16'h0004) : wram_dout;
	else if (sel_in)   cpu_din <= inputs_in;
	else if (sel_sys)  cpu_din <= system_in;
	else if (sel_pal)  cpu_din <= pal_dout;
	else if (sel_vram) cpu_din <= vram_dout;
	else if (sel_oki)  cpu_din <= {8'h00, oki_dout};
end

assign spr_wr      = wr && sel_spr;
assign spr_wr_addr = A[10:1];
assign spr_wr_din  = cpu_dout;
assign spr_wr_be   = be;

assign dbg_addr    = A;
assign dbg_as_n    = as_n;
assign dbg_rw_n    = rw_n;
assign dbg_ds_n    = {uds_n, lds_n};
assign dbg_fc      = fc;
assign dbg_din     = cpu_din;
assign dbg_dout    = cpu_dout;
assign dbg_dtack_n = dtack_n;
assign dbg_cen     = cen & cpu_run;

endmodule

`default_nettype wire
