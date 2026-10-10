// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// Bench stand-ins for the framework around emu (sim/top_tb): the PLL, hps_io's download side,
// and the video framework as a pass-through. Only what NixPirates.sv uses.

`default_nettype none

module pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output reg  locked = 1'b0
);
	assign outclk_0 = refclk;
	assign outclk_1 = refclk;
	integer n = 0;
	always @(posedge refclk) begin
		n <= n + 1;
		if (n == 16) locked <= 1'b1;
	end
endmodule

// hps_io: status and inputs zero; the downloads come from tb_top's dl_* drivers, paced by
// ioctl_wait as the HPS does
module hps_io #(parameter CONF_STR = "", parameter CONF_STR_BRAM = 0, parameter PS2DIV = 0,
                parameter WIDE = 0, parameter VDNUM = 1, parameter BLKSZ = 2, parameter PS2WE = 0) (
	input  wire         clk_sys,
	inout  wire  [45:0] HPS_BUS,
	inout  wire  [35:0] EXT_BUS,
	output wire  [21:0] gamma_bus,
	output wire         forced_scandoubler,
	output wire         direct_video,
	output wire   [1:0] buttons,
	output wire [127:0] status,
	input  wire  [15:0] status_menumask,
	output wire  [31:0] joystick_0,
	output wire  [31:0] joystick_1,
	output wire         ioctl_download,
	output wire  [15:0] ioctl_index,
	output wire         ioctl_wr,
	output wire  [26:0] ioctl_addr,
	output wire   [7:0] ioctl_dout,
	input  wire         ioctl_wait,
	output wire         ioctl_upload,
	input  wire         ioctl_upload_req,
	input  wire   [7:0] ioctl_upload_index,
	input  wire   [7:0] ioctl_din,
	output wire         ioctl_rd,
	output wire  [10:0] ps2_key
);
	assign gamma_bus = 22'd0;
	assign forced_scandoubler = 1'b0;
	assign direct_video = 1'b0;
	assign buttons = 2'b00;
	assign status = tb_top.status;
	assign joystick_0 = tb_top.joy0;
	assign joystick_1 = 32'd0;
	assign ioctl_download = tb_top.dl_download;
	assign ioctl_index = tb_top.dl_index;
	assign ioctl_wr = tb_top.dl_wr;
	assign ioctl_addr = tb_top.dl_addr;
	assign ioctl_dout = tb_top.dl_dout;
	assign ioctl_upload = 1'b0;
	assign ioctl_rd = 1'b0;
	assign ps2_key = 11'd0;
endmodule

module arcade_video #(parameter WIDTH = 320, DW = 8, GAMMA = 1) (
	input  wire          clk_video,
	input  wire          ce_pix,
	input  wire [DW-1:0] RGB_in,
	input  wire          HBlank,
	input  wire          VBlank,
	input  wire          HSync,
	input  wire          VSync,
	output wire          CLK_VIDEO,
	output wire          CE_PIXEL,
	output wire    [7:0] VGA_R,
	output wire    [7:0] VGA_G,
	output wire    [7:0] VGA_B,
	output wire          VGA_HS,
	output wire          VGA_VS,
	output wire          VGA_DE,
	output wire    [1:0] VGA_SL,
	input  wire    [2:0] fx,
	input  wire          forced_scandoubler,
	inout  wire   [21:0] gamma_bus
);
	assign CLK_VIDEO = clk_video;
	assign CE_PIXEL = ce_pix;
	assign {VGA_R, VGA_G, VGA_B} = RGB_in;
	assign VGA_HS = HSync;
	assign VGA_VS = VSync;
	assign VGA_DE = ~(HBlank | VBlank);
	assign VGA_SL = 2'd0;
endmodule

module video_freak (
	input  wire        CLK_VIDEO,
	input  wire        CE_PIXEL,
	input  wire        VGA_VS,
	input  wire [11:0] HDMI_WIDTH,
	input  wire [11:0] HDMI_HEIGHT,
	output wire        VGA_DE,
	output wire [12:0] VIDEO_ARX,
	output wire [12:0] VIDEO_ARY,
	input  wire        VGA_DE_IN,
	input  wire [11:0] ARX,
	input  wire [11:0] ARY,
	input  wire [11:0] CROP_SIZE,
	input  wire  [4:0] CROP_OFF,
	input  wire  [2:0] SCALE
);
	assign VGA_DE = VGA_DE_IN;
	assign VIDEO_ARX = {1'b0, ARX};
	assign VIDEO_ARY = {1'b0, ARY};
endmodule

module screen_rotate_two (
	input  wire        CLK_VIDEO,
	input  wire        CE_PIXEL,
	input  wire  [7:0] VGA_R, VGA_G, VGA_B,
	input  wire        VGA_HS, VGA_VS, VGA_DE,
	input  wire        rotate_ccw, no_rotate, flip, two_screen,
	output wire        video_rotated,
	output wire        FB_EN,
	output wire  [4:0] FB_FORMAT,
	output wire [11:0] FB_WIDTH, FB_HEIGHT,
	output wire [31:0] FB_BASE,
	output wire [13:0] FB_STRIDE,
	input  wire        FB_VBL, FB_LL,
	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire        DDRAM_RD
);
	assign video_rotated = 1'b0;
	assign {FB_EN, FB_FORMAT, FB_WIDTH, FB_HEIGHT, FB_BASE, FB_STRIDE} = '0;
	assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_WE, DDRAM_RD} = '0;
endmodule

`default_nettype wire
