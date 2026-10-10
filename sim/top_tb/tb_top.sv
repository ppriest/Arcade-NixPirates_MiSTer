// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// The whole core, emu itself, from power-on: the framework around it is sim/top_tb/stubs.sv,
// the SDRAM sim/models/np_sdram_model.v, and DDR3 a model serving the ROM image for the fast
// load. The downloads are the .mra's, paced by ioctl_wait as the HPS does, then a reset, as
// Main_MiSTer gives after loading.
//
//   +image=     the index-0 image (scripts/build_mra.py --image SET FILE)
//   +mod=       the mod byte (hex), +dsw= the DIP byte (hex)
//   +fast       index 0 as the fast load: no bytes, the image in DDR3
//   +sdram_bank0= ... +sdram_bank3=   the banks preloaded into the model instead, as
//               rtl/np_rom_loader.sv leaves them (scripts/sdram_model.py --out); one byte is sent
//               past DL_END so the top still sees an index-0 download
//   +hs_cfg=    hiscore config as index 3 (hex bytes, as the .mra's <rom index="3">)
//   +nvm=       the .nvm as index 2 (93C46, then the hiscore table)
//   +frames=    frames to run; +every= write every Nth frame's pixels, +out= their prefix
//
// Per frame it prints the 68000's bus cycles and the load flags: where the board shows black,
// this says whether the game is running. +cpudbg adds the CPU's state, +trace=N the first N bus
// cycles. Run it also with +verilator+rand+reset+2 +verilator+seed+N: registers with no reset or
// initial value then start random, as Power-Up Don't Care lets them on the board (without it
// they start at zero).

`timescale 1ns/1ps
`default_nettype none

module tb_top;

reg clk = 1'b0;
always #10.4167 clk = ~clk;

reg  [127:0] status = 128'd0;
reg   [31:0] joy0 = 32'd0;
reg          dl_download = 1'b0, dl_wr = 1'b0;
reg   [15:0] dl_index = 16'd0;
reg   [26:0] dl_addr = 27'd0;
reg    [7:0] dl_dout = 8'd0;
reg          rst = 1'b0;

wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire  [1:0] sdram_ba;
wire        sdram_dqml, sdram_dqmh, sdram_ncs, sdram_ncas, sdram_nras, sdram_nwe, sdram_cke;
wire        ce_pixel, vga_hs, vga_vs, vga_de;
wire  [7:0] vga_r, vga_g, vga_b;
wire  [7:0] ddr_burstcnt, ddr_be;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire        ddr_rd, ddr_we;
reg  [63:0] ddr_dout = 64'd0;
reg         ddr_ready = 1'b0;
wire [15:0] audio_l;

emu dut (
	.CLK_50M(clk), .RESET(rst), .HPS_BUS(),
	.CLK_VIDEO(), .CE_PIXEL(ce_pixel), .VIDEO_ARX(), .VIDEO_ARY(),
	.VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
	.VGA_F1(), .VGA_SL(), .VGA_SCALER(), .VGA_DISABLE(),
	.HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080), .HDMI_FREEZE(), .HDMI_BLACKOUT(), .HDMI_BOB_DEINT(),
	.FB_EN(), .FB_FORMAT(), .FB_WIDTH(), .FB_HEIGHT(), .FB_BASE(), .FB_STRIDE(), .FB_VBL(1'b0), .FB_LL(1'b0),
	.FB_FORCE_BLANK(),
	.LED_USER(), .LED_POWER(), .LED_DISK(), .BUTTONS(),
	.CLK_AUDIO(1'b0), .AUDIO_L(audio_l), .AUDIO_R(), .AUDIO_S(), .AUDIO_MIX(),
	.ADC_BUS(), .SD_SCK(), .SD_MOSI(), .SD_MISO(1'b0), .SD_CS(), .SD_CD(1'b0),
	.DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(ddr_burstcnt), .DDRAM_ADDR(ddr_addr),
	.DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_ready), .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din),
	.DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
	.SDRAM_CLK(), .SDRAM_CKE(sdram_cke), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba), .SDRAM_DQ(sdram_dq),
	.SDRAM_DQML(sdram_dqml), .SDRAM_DQMH(sdram_dqmh), .SDRAM_nCS(sdram_ncs), .SDRAM_nCAS(sdram_ncas),
	.SDRAM_nRAS(sdram_nras), .SDRAM_nWE(sdram_nwe),
	.UART_CTS(1'b0), .UART_RTS(), .UART_RXD(1'b0), .UART_TXD(), .UART_DTR(), .UART_DSR(1'b0),
	.USER_IN(7'h7f), .USER_OUT(), .OSD_STATUS(1'b0)
);

// jtframe_sdram64 under Verilator reads sdram_dq and writes through sdram_din
np_sdram_model #(.PERIOD_NS(20.8333), .CLK_LAG(1)) u_sdram (   // NixPirates.sv: SHIFTED=1
	.clk(clk), .cke(sdram_cke), .cs_n(sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas),
	.we_n(sdram_nwe), .ba(sdram_ba), .a(sdram_a), .dqm({sdram_dqmh, sdram_dqml}),
	.din(dut.u_sdram.sdram_din), .dq(sdram_dq), .dq_oe()
);

// --- the ROM image, and DDR3 for the fast load -------------------------------------------------
reg  [7:0] img [0:32'h57ffff];
integer    img_len = 0;
integer    ddr_wait = 0;
reg [24:0] ddr_q;
always @(posedge clk) begin
	ddr_ready <= 1'b0;
	if (ddr_rd) begin
		ddr_q    <= ddr_addr[24:0];
		ddr_wait <= 12;
	end else if (ddr_wait > 0) begin
		ddr_wait <= ddr_wait - 1;
		if (ddr_wait == 1) begin : serve
			integer i;
			for (i = 0; i < 8; i = i + 1)
				ddr_dout[8 * i +: 8] <= ({ddr_q, 3'b000} + i < img_len) ? img[{ddr_q, 3'b000} + i] : 8'hff;
			ddr_ready <= 1'b1;
		end
	end
end

// --- downloads, as the HPS gives them --------------------------------------------------------
task automatic send(input [15:0] index, input [26:0] addr, input [7:0] d);
	while (dut.ioctl_wait) @(posedge clk);
	dl_index <= index;
	dl_addr  <= addr;
	dl_dout  <= d;
	dl_wr    <= 1'b1;
	@(posedge clk);
	dl_wr    <= 1'b0;
	repeat (7) @(posedge clk);
endtask

string  f_img, f_out, f_cfg = "", f_nvm = "";
integer nvm_len = 0;
integer frames = 600, every = 0, mod = 0, dsw = 0;
reg     fast = 1'b0, preload = 1'b0;

initial begin : load
	integer f, i;
	if (!$value$plusargs("image=%s", f_img)) begin $display("ERROR: +image= is required"); $finish; end
	void'($value$plusargs("frames=%d", frames));
	void'($value$plusargs("every=%d", every));
	void'($value$plusargs("mod=%h", mod));
	void'($value$plusargs("dsw=%h", dsw));
	if (!$value$plusargs("out=%s", f_out)) f_out = "obj_verilator/top_tb_run/f";
	fast = $test$plusargs("fast");
	void'($value$plusargs("hs_cfg=%s", f_cfg));
	void'($value$plusargs("nvm=%s", f_nvm));
	preload = $test$plusargs("sdram_bank0");    // banks already in np_sdram_model (sdram_model.py --out)
	f = $fopen(f_img, "rb");
	img_len = $fread(img, f);
	$fclose(f);
	$display("image: %0d bytes, %s load, mod %02x, dsw %02x", img_len, fast ? "fast" : "byte", mod, dsw);
	repeat (32) @(posedge clk);
	dl_download <= 1'b1;
	dl_index    <= 16'd0;
	repeat (16) @(posedge clk);         // the HPS's first byte comes well after the download starts
	if (fast) repeat (64) @(posedge clk);
	else if (preload) send(16'd0, 27'h7ff_ffff, 8'h00);   // one byte past DL_END: dropped, but a byte
	else for (i = 0; i < img_len; i = i + 1) send(16'd0, i[26:0], img[i]);
	@(posedge clk);
	dl_download <= 1'b0;
	repeat (16) @(posedge clk);
	dl_index <= 16'd1; @(posedge clk);   // the HPS sets the index before the download starts
	dl_download <= 1'b1;
	send(16'd1, 27'd0, mod[7:0]);
	dl_download <= 1'b0;
	repeat (16) @(posedge clk);
	dl_index <= 16'd254; @(posedge clk);
	dl_download <= 1'b1;
	send(16'd254, 27'd0, dsw[7:0]);
	dl_download <= 1'b0;
	if (f_cfg != "") begin : cfg
		integer fc, b, k;
		fc = $fopen(f_cfg, "r");
		repeat (16) @(posedge clk);
		dl_index <= 16'd3; @(posedge clk);
		dl_download <= 1'b1;
		repeat (16) @(posedge clk);
		k = 0;
		while ($fscanf(fc, "%h", b) == 1) begin send(16'd3, k[26:0], b[7:0]); k = k + 1; end
		$fclose(fc);
		dl_download <= 1'b0;
	end
	if (f_nvm != "") begin : nvm
		integer fn, k;
		reg [7:0] nv [0:1023];
		fn = $fopen(f_nvm, "rb"); nvm_len = $fread(nv, fn); $fclose(fn);
		repeat (16) @(posedge clk);
		dl_index <= 16'd2; @(posedge clk);
		dl_download <= 1'b1;
		repeat (16) @(posedge clk);
		for (k = 0; k < nvm_len; k = k + 1) send(16'd2, k[26:0], nv[k]);
		dl_download <= 1'b0;
	end
	repeat (16) @(posedge clk);
	if (!$test$plusargs("noreset")) begin   // +noreset: no reset after the downloads
		rst <= 1'b1;
		repeat (64) @(posedge clk);
		rst <= 1'b0;
	end
	$display("downloads done at %0t ns: dl0_seen %0d dl_seen_wr %0d ldr_done %0d ldr_pending %0d ldr_active %0d",
	         $time, dut.dl0_seen, dut.dl_seen_wr, dut.ldr_done, dut.ldr_pending, dut.ldr_active);
	$fflush();
end

// --- the 93C46's pins as the game drives them (out_w bits 0 CS, 1 CLK, 2 DI) and its DO ------
integer ee_log = 0, ee_max = 4000;
always @(posedge clk) if (dut.out_we && ee_log < ee_max && (dut.out_d[2:0] != dut.out_q[2:0])) begin
	$display("out_w %0t: cs %0d clk %0d di %0d  (do %0d, jt9346 st %0h)", $time, dut.out_d[0], dut.out_d[1],
	         dut.out_d[2], dut.ee_do, dut.u_eeprom.st);
	ee_log = ee_log + 1;
end

// --- per frame -------------------------------------------------------------------------------
integer frame = 0, bus = 0, fo = 0, px = 0, nz = 0;
integer cens = 0;
integer trace_n = 0, ntr = 0;
reg     as_q = 1'b1;
initial void'($value$plusargs("trace=%d", trace_n));
always @(posedge clk) begin
	as_q <= dut.u_main.as_n;
	if (trace_n != 0 && !as_q && dut.u_main.as_n && ntr < trace_n) begin   // end of a bus cycle
		$display("BUS %0d %06x %s %04x", ntr, {dut.u_main.eab, 1'b0}, dut.u_main.rw_n ? "R" : "W",
		         dut.u_main.rw_n ? dut.u_main.cpu_din : dut.u_main.cpu_dout);
		ntr = ntr + 1;
	end
end
always @(posedge clk) if (dut.u_main.cen) cens = cens + 1;
reg     vs_l = 1'b0, as_l = 1'b1;
integer palw = 0, vramw = 0, okiw = 0;
always @(posedge clk) begin
	as_l <= dut.dbg_as_n;
	if (as_l && !dut.dbg_as_n) bus = bus + 1;
	if (dut.u_main.wr && dut.u_main.sel_pal ) palw  = palw + 1;
	if (dut.u_main.wr && dut.u_main.sel_vram) vramw = vramw + 1;
	if (dut.oki_we) okiw = okiw + 1;
	if (ce_pixel) begin
		vs_l <= vga_vs;
		if (vga_vs && !vs_l) begin
			if (fo != 0) begin $fclose(fo); fo = 0; end
			$display("frame %0d: bus cycles %0d, last address %06x, rom_loaded %0d, core_reset %0d, ldr_active %0d, non-black px %0d, palette writes %0d, VRAM writes %0d, M6295 writes %0d",
			         frame, bus, dut.dbg_addr, dut.rom_loaded, dut.core_reset, dut.ldr_active, nz, palw, vramw, okiw);
			if ($test$plusargs("cpudbg"))
				$display("  cpu: cens %0d as_n %0d ds %b dtack %0d rom_cs %0d rom_ok %0d tState %0d halted %0d",
				         cens, dut.u_main.as_n, {dut.u_main.uds_n, dut.u_main.lds_n}, dut.u_main.dtack_n,
				         dut.rom_cs, dut.rom_ok, dut.u_main.u_cpu.tState, dut.u_main.u_cpu.oHALTEDn);
				$display("  pause: pause_cpu %0d pause_toggle %0d hs_pause %0d hs_configured %0d status82 %0d", dut.pause_cpu, dut.pause_toggle, dut.hs_pause, dut.hs_configured, dut.status[82]);
			$fflush();
			frame = frame + 1;
			px = 0; nz = 0; palw = 0; vramw = 0;
			if (frame == frames) $finish;
			if (every != 0 && frame % every == 0) fo = $fopen($sformatf("%s%0d.rgb", f_out, frame), "wb");
		end
		if (vga_de) begin
			if (fo != 0) $fwrite(fo, "%c%c%c", vga_r, vga_g, vga_b);
			if ({vga_r, vga_g, vga_b} != 24'd0) nz = nz + 1;
			px = px + 1;
		end
	end
end

endmodule

`default_nettype wire
