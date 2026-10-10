// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// NIX's Pirates / Genix Family board (MAME src/mame/nix/pirates.cpp): sets in
// scripts/build_mra.py SETS.
//
// Framework glue: hps_io, PLL, resets, the decrypting ROM download, the mod byte, inputs, the
// 93C46 and its .nvm, the SDRAM, and the video output. The board is rtl/np_main.sv (68000,
// memory map, RAMs) and rtl/np_video.sv.
//
// Clocks (rtl/pll): clk_sys 48 MHz for everything, SDRAM included; SDRAM_CLK the same lagging
// 5555 ps (rtl/pll/pll_0002.v). 68000 16 MHz and the 6 MHz pixel by clock enables.

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "rtl/np_rom_map.svh"
`include "build_id.v"

wire [1:0] ar = status[122:121];

// Orientation: Auto follows the set, and every set is horizontal (pirates.cpp GAME lines, ROT0)
wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = rot_sel == 2'd2 || rot_sel == 2'd3;
wire       rotate_ccw = rot_sel == 2'd3;
wire [11:0] base_arx  = rotate_en ? 12'd3 : 12'd4;   // 4:3, 3:4 rotated (docs/ROADMAP.md)
wire [11:0] base_ary  = rotate_en ? 12'd4 : 12'd3;

`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif

localparam CONF_STR = {
	"NixPirates;;",
	"-;",
	"H5O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H5O[64:63],Orientation,Auto,Off,CW,CCW;",
	"O[65],Flip Screen,Off,On;",
	"H5O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"H5O[69],Crop,Off,216 lines;",
	"H5O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H5O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[124:123],Audio mix,Mono,None,25%,50%;",
	"H2O[78],Autosave Hiscores,Off,On;",
	"-;",
	"O[94],CRT adjust,Off,On;",
	"H3O[99:95],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[106:100],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[112:107],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// entry i is joystick bit 4 + i, matching the .mra <buttons> (scripts/build_mra.py)
	"J1,Button 1,Button 2,Button 3,-,-,-,Start,Coin,Pause,Service;",
	"jn,A,B,X,-,-,-,Start,Select,L,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler, direct_video;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire  [7:0] ioctl_din;
wire        ioctl_upload;
reg         nvram_save = 1'b0;
wire        hs_configured, hs_upload_req, hs_pause;   // rtl/hiscore/hiscore.v, below

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.buttons(buttons),
	.status(status),
	// H5 HDMI-only options under direct video, H3 CRT adjust's parameters, H2 hiscore (when the
	// .mra has a table), H1 Debug
	.status_menumask({10'd0, direct_video, 1'b0, ~status[94], ~hs_configured, DEBUG_MENU_HIDE, 1'b0}),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	// the .mra's <nvram index="2">: the 93C46, then the hiscore table (below)
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save | hs_upload_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),
	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram_shifted, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.locked(pll_locked)
);
assign SDRAM_CLK = clk_sdram_shifted;

///////////////////////   RESET   ////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// The game is held until a ROM is in SDRAM; the memory path is not (LESSONS_LEARNED, "Never hold
// the memory path in the core reset").
//
// Fast load (rtl/np_ddr_loader.sv): with address="0x30000000" on the .mra's index-0 ROM the HPS
// writes the image into DDR3 and no byte arrives; the copy then runs once, when the downloads
// have ended. Any download arms it, as Arcade-JalecoMS32_MiSTer's MS32.sv (whose reset includes
// ioctl_download), so it does not depend on the reset Main_MiSTer gives after loading. An .mra
// without the attribute streams bytes as before; which one ran is told by whether a byte arrived.
wire        ldr_active, l_wr;
wire [26:0] l_addr;
wire  [7:0] l_dout;
wire        dl0 = ioctl_download && ioctl_index == 16'd0;
reg  dl0_d = 1'b0, dl0_seen = 1'b0, dl_seen_wr = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0;
reg  ldr_done = 1'b0, rom_loaded = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_start    <= 1'b0;
	dl0_d        <= dl0;
	ldr_active_d <= ldr_active;
	if (dl0) dl0_seen <= 1'b1;
	if (dl0 && !dl0_d)                 begin dl_seen_wr <= 1'b0; ldr_done <= 1'b0; rom_loaded <= 1'b0; end
	else if (dl0 && ioctl_wr)          dl_seen_wr <= 1'b1;
	if (dl0_d && !dl0 && dl_seen_wr)   rom_loaded <= 1'b1;   // the byte path wrote SDRAM
	if (ldr_active_d && !ldr_active)   rom_loaded <= 1'b1;   // the copy finished
	if (reset || ioctl_download) ldr_pending <= 1'b1;
	else if (ldr_pending && !ldr_active) begin
		ldr_pending <= 1'b0;
		if (!dl_seen_wr && !ldr_done && dl0_seen) begin ldr_start <= 1'b1; ldr_done <= 1'b1; end
	end
end
wire core_reset = reset | ioctl_download | ldr_active | ~rom_loaded;

// the download port the ROM loader sees: the HPS's bytes, or the copy's
wire        ld_dl    = ioctl_download | ldr_active;
wire [15:0] ld_index = ldr_active ? 16'd0  : ioctl_index;
wire        ld_wr    = ldr_active ? l_wr   : ioctl_wr;
wire [26:0] ld_addr  = ldr_active ? l_addr : ioctl_addr;
wire  [7:0] ld_dout  = ldr_active ? l_dout : ioctl_dout;

///////////////////   .mra: mod byte   ///////////////////////////

// <rom index="1">, rtl/np_rom_map.svh: [0] the genix protection variant
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd1 && ioctl_addr == 27'd0) mod_byte <= ioctl_dout;
wire genix = mod_byte[MOD_GENIX_BIT];

// <switches>, index 254: the board has no DIPs; bit 0 is the core's flip (scripts/build_mra.py)
reg [7:0] dsw = 8'd0;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd254 && ioctl_addr == 27'd0) dsw <= ioctl_dout;
wire flip = status[65] ^ dsw[0];

///////////////////////   INPUTS   ///////////////////////////////

// MiSTer joystick: 0 R, 1 L, 2 D, 3 U, buttons 1-3 at 4-6 (7-9 unused), Start 10, Coin 11,
// Pause 12, Service 13. MAME's INPUTS (pirates.cpp 365-381), a byte per player, active low:
// up, down, left, right, buttons 1-3, start.
wire [31:0] key0, key1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(3), .START(10), .COIN(11), .PAUSE(12), .SERVICE(13)) u_keys (
	.clk(clk_sys), .ps2_key(ps2_key), .key0(key0), .key1(key1), .svc_coin(svc_coin)
);
wire [31:0] joy0 = joystick_0 | key0;
wire [31:0] joy1 = joystick_1 | key1;

function automatic [7:0] np_port(input [31:0] j);
	np_port = ~{j[10], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};
endfunction
wire [15:0] inputs_in = {np_port(joy1), np_port(joy0)};

// SYSTEM (383-400): 0 COIN1, 1 COIN2, 2 SERVICE1, 3 service mode (momentary, as MAME's
// PORT_SERVICE_NO_TOGGLE), active low; 4 the EEPROM's DO; 5, 6 unknown, read 0; 7 the
// protection bit, which MAME's prot_r reads as 1; 8-15 unknown, read 0.
wire ee_do, ee_ready;
wire [15:0] system_in = {8'h00, 1'b1, 2'b00, ee_do & ee_ready,
                         ~(joy0[13] | joy1[13]), ~svc_coin[0], ~joy1[11], ~joy0[11]};

// Pause: joystick bit 12 (or P) toggles; the Debug page's Pause CPU is ORed in
wire pause_btn = joy0[12] | joy1[12];
reg  pause_btn_d = 1'b0, pause_toggle = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_toggle <= ~pause_toggle;
end
// hiscore.v's pause_cpu has no reset or initial value: unconfigured it never pauses, so it
// is only heard once configured (sim/top_tb with +verilator+rand+reset+2 found it powered up 1)
wire pause_cpu = pause_toggle | status[82] | (hs_pause & hs_configured);

///////////////////////   OUT_W, EEPROM   ////////////////////////

// out_w (pirates.cpp 289-301): 0 EEPROM CS, 1 CLK, 2 DI, 6 OKI bank, 7 unknown
wire       out_we;
wire [7:0] out_d;
reg  [7:0] out_q = 8'd0;
always @(posedge clk_sys) if (core_reset) out_q <= 8'd0; else if (out_we) out_q <= out_d;

// The .nvm (index 2) is the 93C46 in bytes 0-127, big-endian words, then the hiscore dump: the
// .mra has one <nvram>. The 93C46 loads while the core is held; a save is asked for a second
// after the game's last write, or by hiscore.v when the table has changed.
wire        nvm_ee = ioctl_addr[26:7] == 20'd0;
wire        ee_flag;
reg         ee_clr = 1'b0;
reg   [7:0] ee_hi = 8'd0;
wire        ee_load = ioctl_download && ioctl_wr && ioctl_index == 16'd2 && nvm_ee;
wire [15:0] ee_dout;
wire  [7:0] hs_to_hps;
assign ioctl_din = !nvm_ee ? hs_to_hps : ioctl_addr[0] ? ee_dout[7:0] : ee_dout[15:8];
always @(posedge clk_sys) if (ee_load && !ioctl_addr[0]) ee_hi <= ioctl_dout;

jt9346 #(.AW(6), .DW(16)) u_eeprom (
	.rst(core_reset), .clk(clk_sys),
	.sclk(out_q[1]), .sdi(out_q[2]), .sdo(ee_do), .scs(out_q[0]),
	.dump_clk(clk_sys), .dump_addr(ioctl_addr[6:1]), .dump_we(ee_load && ioctl_addr[0]),
	.dump_din({ee_hi, ioctl_dout}), .dump_dout(ee_dout),
	.dump_clr(ee_clr), .dump_flag(ee_flag)
);

// After a write the 93C46 is busy, DO low, for MAME's write time (eeprom.cpp 42, 1750 us).
// jt9346 shows ready at once; the game waits to see busy and then ready, and without the busy
// it waits for ever on the first write to a blank EEPROM (sim/top_tb; docs/MAME_KLUDGES.md).
reg [16:0] ee_busy = 17'd0;
always @(posedge clk_sys)
	if (core_reset)          ee_busy <= 17'd0;
	else if (ee_flag)        ee_busy <= 17'd84000;
	else if (ee_busy != 0)   ee_busy <= ee_busy - 17'd1;
assign ee_ready = ee_busy == 17'd0;

reg [25:0] ee_quiet = 26'd0;
always @(posedge clk_sys) begin
	nvram_save <= 1'b0;
	ee_clr     <= 1'b0;
	if (ee_flag) begin
		ee_clr   <= 1'b1;
		ee_quiet <= 26'd1;
	end else if (ee_quiet != 26'd0) begin
		ee_quiet <= ee_quiet + 26'd1;
		if (ee_quiet == 26'd48_000_000) begin
			ee_quiet   <= 26'd0;
			nvram_save <= 1'b1;
		end
	end
end

///////////////////////   HISCORE   //////////////////////////////

// MAME's hiscore.dat (rtl/hiscore/PROVENANCE.md): the table goes back into work RAM once the game
// has set it up, and comes out to be saved. Config is <rom index="3">; the dump is index 2 from
// byte 128 on, so hiscore.v sees it as its own index 4 at offset 0.
wire        hs_write, hs_read;
wire [15:0] hs_address;
wire  [7:0] hs_to_ram, hs_from_ram;
wire        hs_dump  = ioctl_index == 16'd2 && !nvm_ee;
wire  [7:0] hs_index = hs_dump ? 8'd4 : ioctl_index == 16'd3 ? 8'd3 : 8'hff;
wire [24:0] hs_ioaddr = hs_dump ? ioctl_addr[24:0] - 25'd128 : ioctl_addr[24:0];

hiscore #(.HS_ADDRESSWIDTH(16), .HS_SCOREWIDTH(8), .CFG_ADDRESSWIDTH(2), .CFG_LENGTHWIDTH(1)) u_hiscore (
	.clk(clk_sys),
	.reset(reset),
	.paused(pause_cpu),
	.autosave(status[78]),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(hs_upload_req),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(hs_ioaddr),
	.ioctl_index(hs_index),
	.OSD_STATUS(OSD_STATUS),
	.data_from_hps(ioctl_dout),
	.data_from_ram(hs_from_ram),
	.ram_address(hs_address),
	.data_to_hps(hs_to_hps),
	.data_to_ram(hs_to_ram),
	.ram_write(hs_write),
	.ram_intent_read(hs_read),
	.ram_intent_write(),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

///////////////////////   THE BOARD   ////////////////////////////

wire        rom_cs, rom_ok, vblank_irq;
wire [18:0] rom_addr;
wire [15:0] rom_data, scroll;
wire        spr_wr;
wire  [9:0] spr_wr_addr;
wire [15:0] spr_wr_din;
wire  [1:0] spr_wr_be;
wire [13:0] vram_addr;
wire [12:0] pal_addr;
wire  [9:0] spr_addr;
wire [15:0] vram_dout, pal_dout, spr_dout;
wire        oki_we;
wire  [7:0] oki_din, oki_dout;
wire [23:0] dbg_addr;
wire        dbg_as_n, dbg_rw_n;
wire [15:0] dbg_din;

np_main u_main (
	.clk(clk_sys), .rst(core_reset), .genix(genix), .cpu_run(~pause_cpu), .vblank(vblank_irq),
	.rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
	.inputs_in(inputs_in), .system_in(system_in),
	.hs_access(hs_read | hs_write), .hs_addr(hs_address), .hs_we(hs_write), .hs_din(hs_to_ram),
	.hs_dout(hs_from_ram),
	.out_we(out_we), .out_d(out_d), .scroll(scroll),
	.oki_we(oki_we), .oki_din(oki_din), .oki_dout(oki_dout),
	.wram_b_addr(15'd0), .wram_b_dout(),
	.pal_b_addr(pal_addr), .pal_b_dout(pal_dout), .vram_b_addr(vram_addr), .vram_b_dout(vram_dout),
	.spr_b_addr(spr_addr), .spr_b_dout(spr_dout),
	.spr_wr(spr_wr), .spr_wr_addr(spr_wr_addr), .spr_wr_din(spr_wr_din), .spr_wr_be(spr_wr_be),
	.dbg_addr(dbg_addr), .dbg_as_n(dbg_as_n), .dbg_rw_n(dbg_rw_n), .dbg_ds_n(), .dbg_fc(), .dbg_din(dbg_din), .dbg_dout(),
	.dbg_dtack_n(), .dbg_cen()
);

wire        ce_pix, core_hb, core_vb, core_hs, core_vs;
wire  [7:0] core_r, core_g, core_b;
wire        ba1_rd, ba2_rd;
wire [21:0] ba1_addr, ba2_addr;
wire  [3:0] ack, dst, rdy;
wire [15:0] sd_dout;

np_video u_video (
	.clk(clk_sys), .rst(core_reset), .flip(flip), .scroll_in(scroll),
	.spr_wr(spr_wr), .spr_wr_addr(spr_wr_addr), .spr_wr_din(spr_wr_din), .spr_wr_be(spr_wr_be),
	.vram_addr(vram_addr), .vram_dout(vram_dout), .pal_addr(pal_addr), .pal_dout(pal_dout),
	.spr_addr(spr_addr), .spr_dout(spr_dout),
	.ba1_rd(ba1_rd), .ba1_addr(ba1_addr), .ba1_ack(ack[1]), .ba1_dst(dst[1]), .ba1_rdy(rdy[1]),
	.ba2_rd(ba2_rd), .ba2_addr(ba2_addr), .ba2_ack(ack[2]), .ba2_dst(dst[2]), .ba2_rdy(rdy[2]),
	.sdram_dout(sd_dout),
	.ce_pix(ce_pix), .r(core_r), .g(core_g), .b(core_b),
	.hblank(core_hb), .vblank(core_vb), .hsync(core_hs), .vsync(core_vs),
	.vblank_irq(vblank_irq), .dbg_pen()
);

///////////////////////   SOUND   ////////////////////////////////

wire               ba3_rd;
wire        [21:0] ba3_addr;
wire signed [13:0] oki_snd;

np_sound u_sound (
	.clk(clk_sys), .rst(core_reset),
	.oki_we(oki_we), .oki_din(oki_din), .oki_dout(oki_dout), .bank(out_q[6]),
	.ba3_rd(ba3_rd), .ba3_addr(ba3_addr), .ba3_ack(ack[3]), .ba3_dst(dst[3]), .ba3_rdy(rdy[3]),
	.sdram_dout(sd_dout),
	.sound(oki_snd)
);

// mono (pirates.cpp 460), the same on both channels; the menu reads Mono, None, 25%, 50%
assign AUDIO_S   = 1;
assign AUDIO_MIX = status[124:123] == 2'd0 ? 2'd3 : status[124:123] - 2'd1;
assign AUDIO_L   = {oki_snd, 2'b00};
assign AUDIO_R   = {oki_snd, 2'b00};

///////////////////////   SDRAM   ////////////////////////////////

// bank 0 program (68000 through the line cache), 1 tiles, 2 sprites, 3 samples; the prog port
// is the decrypting loader (rtl/np_sdram_map.svh)
wire        ba0_rd;
wire [21:0] ba0_addr;
wire        prog_en, prog_wr, prog_rdy, sdram_init;
wire [21:0] prog_addr;
wire  [1:0] prog_ba, prog_dsn;
wire [15:0] prog_din;

jtframe_rom_1slot #(
	.SDRAMW(22), .SLOT0_DW(16), .SLOT0_AW(19), .CACHE0_LARGE(1), .CACHE0_SIZE(16384),
	.SLOT0_BURSTLEN(64), .TAG_RAM(1)
) u_prg (
	.rst(core_reset), .clk(clk_sys),
	.slot0_addr(rom_addr), .slot0_dout(rom_data), .slot0_cs(rom_cs), .slot0_ok(rom_ok),
	.sdram_ack(ack[0]), .sdram_rd(ba0_rd), .sdram_addr(ba0_addr),
	.data_dst(dst[0]), .data_rdy(rdy[0]), .data_read(sd_dout)
);

np_rom_loader u_loader (
	.clk(clk_sys), .sdram_init(sdram_init),
	.ioctl_download(ld_dl), .ioctl_index(ld_index), .ioctl_wr(ld_wr),
	.ioctl_addr(ld_addr), .ioctl_dout(ld_dout), .ioctl_wait(ioctl_wait),
	.prog_en(prog_en), .prog_addr(prog_addr), .prog_ba(prog_ba), .prog_wr(prog_wr),
	.prog_din(prog_din), .prog_dsn(prog_dsn), .prog_rdy(prog_rdy)
);

// SHIFTED: SDRAM_CLK lags clk_sys by 5555 ps, so the chip takes a command in the cycle it is
// driven and read data comes a clock earlier than at zero phase. jtframe's MiSTer target sets it
// (JTFRAME_SHIFT, target/mister/target.def). Without it the board read each word one address
// late in a burst (ISSP instance D: 0x400 read 0010, the word at 0x402).
jtframe_sdram64 #(.AW(22), .HF(0), .MISTER(1), .SHIFTED(1),
	.BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(32), .BA3_LEN(32)) u_sdram (
	.rst(~pll_locked), .clk(clk_sys), .init(sdram_init),
	.ba0_addr(ba0_addr), .ba1_addr(ba1_addr), .ba2_addr(ba2_addr), .ba3_addr(ba3_addr),
	.rd({ba3_rd, ba2_rd, ba1_rd, ba0_rd}), .wr(4'd0),
	.ba0_din(16'd0), .ba0_dsn(2'b11), .ba1_din(16'd0), .ba1_dsn(2'b11),
	.ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
	.prog_en(prog_en), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr), .prog_din(prog_din),
	.prog_dsn(prog_dsn), .prog_ba(prog_ba), .prog_dst(), .prog_dok(), .prog_rdy(prog_rdy), .prog_ack(),
	.rfsh(core_hs),
	.ack(ack), .dst(dst), .dok(), .rdy(rdy), .dout(sd_dout),
	.sdram_dq(SDRAM_DQ), .sdram_a(SDRAM_A), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
	.sdram_ba(SDRAM_BA), .sdram_nwe(SDRAM_nWE), .sdram_ncas(SDRAM_nCAS), .sdram_nras(SDRAM_nRAS),
	.sdram_ncs(SDRAM_nCS), .sdram_cke(SDRAM_CKE)
);

wire       crt_on, crt_ce, crt_hs, crt_vs, crt_hb, crt_vb;
wire vga_de_raw;

///////////////////////   DEBUG   ////////////////////////////////

// Probes: NixPirates_stp revision only (DEBUG_ISSP); scripts/read_issp.py reads them.
`ifdef DEBUG_ISSP
reg  [31:0] dbg_bus = 32'd0, dbg_dl = 32'd0;
reg  [15:0] dbg_oki = 16'd0;
reg   [7:0] dbg_frames = 8'd0;
reg         dbg_as_l = 1'b1, dbg_vb_l = 1'b0;
always @(posedge clk_sys) begin
	dbg_as_l <= dbg_as_n;
	dbg_vb_l <= vblank_irq;
	if (ld_dl && ld_wr && ld_index == 16'd0) dbg_dl <= dbg_dl + 32'd1;
	if (core_reset) begin
		dbg_bus <= 32'd0; dbg_oki <= 16'd0; dbg_frames <= 8'd0;
	end else begin
		if (dbg_as_l && !dbg_as_n)    dbg_bus    <= dbg_bus + 32'd1;
		if (oki_we)                   dbg_oki    <= dbg_oki + 16'd1;
		if (vblank_irq && !dbg_vb_l)  dbg_frames <= dbg_frames + 8'd1;
	end
end
// Instance F: [31:0] ROM bytes into the loader (index 0, either path), [63:32] 68000 bus cycles,
// [87:64] its last address, [103:88] M6295 writes, [111:104] frames, [112] rom_loaded,
// [113] core_reset, [114] ioctl_download, [115] dl_seen_wr, [116] ldr_active, [117] ldr_done,
// [118] flip, [119] pll_locked, [120] reset, [121] RESET, [122] status[0], [123] buttons[1],
// [124] dl0_seen, [125] ldr_pending, [126] pause_cpu, [127] hs_pause
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp_f (
	.clk(clk_sys),
	.probe({hs_pause, pause_cpu, ldr_pending, dl0_seen, buttons[1], status[0], RESET, reset,
	        pll_locked, flip, ldr_done, ldr_active, dl_seen_wr, ioctl_download, core_reset, rom_loaded,
	        dbg_frames, dbg_oki, dbg_addr, dbg_bus, dbg_dl}),
	.source()
);
// Instances D, E: counts over the last whole frame, latched at vblank_irq's rise. "vis" is a
// core pixel outside blanking; "nz" a non-zero value.
// D: [15:0] vis core RGB nz, [31:16] arcade_video RGB nz under its DE, [47:32] vis pal_dout nz,
//    [63:48] vis pal_addr nz, [79:64] CPU palette writes, [95:80] CPU VRAM writes,
//    [111:96] bank 1 (tiles) rdy, [127:112] bank 2 (sprites) rdy
// E: [15:0] bank 1 rdy with data nz, [31:16] bank 2 rdy with data nz, [47:32] vis pixels,
//    [63:48] arcade_video DE pixels, [76:64] last vis pal_addr nz, [92:77] last vis pal_dout nz,
//    [93] crt_on, [94] FB_EN, [95] forced_scandoubler, [96] direct_video, [99:97] status[46:44]
wire        dbg_vbr = vblank_irq && !dbg_vb_l;
wire        dbg_vis = ce_pix && !core_hb && !core_vb;
wire        dbg_wcyc = !dbg_as_n && !dbg_rw_n;
reg         dbg_wcyc_l = 1'b0;
reg  [15:0] dc_core = 16'd0, dc_vga = 16'd0, dc_pal = 16'd0, dc_pen = 16'd0;
reg  [15:0] dc_palw = 16'd0, dc_vramw = 16'd0, dc_rd1 = 16'd0, dc_rd2 = 16'd0;
reg  [15:0] dc_nz1 = 16'd0, dc_nz2 = 16'd0, dc_vis = 16'd0, dc_de = 16'd0;
reg  [12:0] dbg_lpen = 13'd0;
reg  [15:0] dbg_lpal = 16'd0;
reg [127:0] dbg_vd = 128'd0, dbg_ve = 128'd0;
function automatic [15:0] inc16(input [15:0] v); inc16 = &v ? v : v + 16'd1; endfunction
always @(posedge clk_sys) begin
	dbg_wcyc_l <= dbg_wcyc;
	if (dbg_vbr) begin
		dbg_vd <= {dc_rd2, dc_rd1, dc_vramw, dc_palw, dc_pen, dc_pal, dc_vga, dc_core};
		dbg_ve <= {28'd0, status[46:44], direct_video, forced_scandoubler, FB_EN, crt_on,
		           dbg_lpal, dbg_lpen, dc_de, dc_vis, dc_nz2, dc_nz1};
		{dc_core, dc_vga, dc_pal, dc_pen, dc_palw, dc_vramw} <= 96'd0;
		{dc_rd1, dc_rd2, dc_nz1, dc_nz2, dc_vis, dc_de} <= 96'd0;
	end else begin
		if (dbg_vis) dc_vis <= inc16(dc_vis);
		if (dbg_vis && {core_r, core_g, core_b} != 24'd0) dc_core <= inc16(dc_core);
		if (dbg_vis && pal_dout != 16'd0) begin dc_pal <= inc16(dc_pal); dbg_lpal <= pal_dout; end
		if (dbg_vis && pal_addr != 13'd0) begin dc_pen <= inc16(dc_pen); dbg_lpen <= pal_addr; end
		if (CE_PIXEL && vga_de_raw) dc_de <= inc16(dc_de);
		if (CE_PIXEL && vga_de_raw && {VGA_R, VGA_G, VGA_B} != 24'd0) dc_vga <= inc16(dc_vga);
		if (dbg_wcyc && !dbg_wcyc_l && dbg_addr[23:14] == 10'h200) dc_palw <= inc16(dc_palw);
		if (dbg_wcyc && !dbg_wcyc_l && dbg_addr[23:16] == 8'h90) dc_vramw <= inc16(dc_vramw);
		if (rdy[1]) dc_rd1 <= inc16(dc_rd1);
		if (rdy[2]) dc_rd2 <= inc16(dc_rd2);
		if (rdy[1] && sd_dout != 16'd0) dc_nz1 <= inc16(dc_nz1);
		if (rdy[2] && sd_dout != 16'd0) dc_nz2 <= inc16(dc_nz2);
	end
end
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(128), .SOURCE_W(8)) u_issp_d (
	.clk(clk_sys), .probe(dbg_vd), .source()
);
issp_probe #(.INSTANCE_ID("E"), .PROBE_W(128), .SOURCE_W(8)) u_issp_e (
	.clk(clk_sys), .probe(dbg_ve), .source()
);
// Instances G, H: the six bus cycles up to the first read of 0x00002c (vector 11, Line 1111)
// after reset, frozen there; each {rw_n, address[23:1], data in}, the vector read in G[39:0],
// earlier cycles above it, then H. [127:120] of G and H: the vector-11 reads counted (to 65535).
reg  [39:0] dbg_hist [0:5];
reg         dbg_frozen = 1'b0;
reg  [15:0] dbg_nvec = 16'd0;
integer     dbg_i;
initial for (dbg_i = 0; dbg_i < 6; dbg_i = dbg_i + 1) dbg_hist[dbg_i] = 40'd0;
always @(posedge clk_sys) begin
	if (core_reset) begin
		dbg_frozen <= 1'b0; dbg_nvec <= 16'd0;
	end else if (!dbg_as_l && dbg_as_n) begin                 // a bus cycle ends
		if (!dbg_frozen) begin
			for (dbg_i = 5; dbg_i > 0; dbg_i = dbg_i - 1) dbg_hist[dbg_i] <= dbg_hist[dbg_i - 1];
			dbg_hist[0] <= {dbg_rw_n, dbg_addr[23:1], dbg_din};
		end
		if (dbg_rw_n && dbg_addr == 24'h00002c) begin
			dbg_frozen <= 1'b1;
			if (dbg_nvec != 16'hffff) dbg_nvec <= dbg_nvec + 16'd1;
		end
	end
end
issp_probe #(.INSTANCE_ID("G"), .PROBE_W(128), .SOURCE_W(8)) u_issp_g (
	.clk(clk_sys), .probe({dbg_nvec[7:0], dbg_hist[2], dbg_hist[1], dbg_hist[0]}), .source()
);
issp_probe #(.INSTANCE_ID("H"), .PROBE_W(128), .SOURCE_W(8)) u_issp_h (
	.clk(clk_sys), .probe({dbg_nvec[15:8], dbg_hist[5], dbg_hist[4], dbg_hist[3]}), .source()
);
`endif

///////////////////////   VIDEO   ////////////////////////////////

// CRT adjust: analog only, off under the scandoubler (rtl/video/np_crt.sv)
wire [7:0] crt_r, crt_g, crt_b;
np_crt u_crt (
	.clk(clk_sys), .ce(ce_pix), .adjust(status[94] & ~forced_scandoubler),
	.hsize_idx(status[99:95]), .hpos_idx(status[106:100]), .vshift_idx(status[112:107]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.active(crt_on), .ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(288), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_ce : ce_pix),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : {core_r, core_g, core_b}),
	.HBlank(crt_on ? crt_hb : core_hb),
	.VBlank(crt_on ? crt_vb : core_vb),
	.HSync(crt_on ? crt_hs : core_hs),
	.VSync(crt_on ? crt_vs : core_vs),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),
	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// 4:3, the monitor's aspect, whatever the pixel count (docs/ROADMAP.md)
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_raw),
	.ARX((!ar) ? base_arx : (ar - 1'd1)),
	.ARY((!ar) ? base_ary : 12'd0),
	.CROP_SIZE(status[69] ? 12'd216 : 12'd0),     // 216 lines: 5x on 1080
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// DDR3: the fast load's copy while it runs, the rotator otherwise. The rotator sees DDR3 busy for
// the whole copy: it has no reset and counts a write as taken whenever BUSY is low
// (docs: the skill's video_audio_options.md; Arcade-Seta_MiSTer, Seta.sv).
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
wire  [7:0] ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire [63:0] ldr_DDRAM_DIN;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(~ldr_active),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT), .DDRAM_ADDR(ldr_DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);
np_ddr_loader #(.LENGTH({4'd0, DL_END})) u_ddr_loader (
	.clk(clk_sys), .reset(~pll_locked),
	.start(ldr_start), .active(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.l_wr(l_wr), .l_addr(l_addr), .l_dout(l_dout), .l_wait(ioctl_wait)
);

wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire  [7:0] rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;

// HDMI rotation: screen_rotate_two writes the output into DDR3 for the HPS framebuffer; analog
// keeps the native raster. Its flip is not used: Flip Screen is np_video's.
screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(1'b0),
	.two_screen(1'b0),
	.video_rotated(),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

endmodule
