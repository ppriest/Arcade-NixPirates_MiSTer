// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// ROM download (ioctl index 0, rtl/np_rom_map.svh) into SDRAM through
// jtframe_sdram64's prog port, decrypted on the way: each byte is written to its
// decrypted bank, word and lane with its data permuted (np_decrypt.svh). The
// reference is scripts/sdram_model.py loader_map(); sim/loader_tb checks this
// module against it for whole images.
//
// One byte per SDRAM write, the byte on both lanes and the other lane masked.
// ioctl_wait holds the HPS from each byte until the write reports done
// (prog_rdy: upstream's prog_test pairs jtframe_dwnld's acknowledge with it),
// and while the SDRAM is still initialising.

`default_nettype none

module np_rom_loader (
	input  wire        clk,
	input  wire        sdram_init,      // jtframe_sdram64 init: no prog writes yet

	input  wire        ioctl_download,
	input  wire [15:0] ioctl_index,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire  [7:0] ioctl_dout,
	output wire        ioctl_wait,

	output wire        prog_en,
	output reg  [21:0] prog_addr = 22'd0,
	output reg   [1:0] prog_ba   = 2'd0,
	output reg         prog_wr   = 1'b0,
	output wire [15:0] prog_din,
	output reg   [1:0] prog_dsn  = 2'b11,
	input  wire        prog_rdy
);

`include "np_rom_map.svh"
`include "np_sdram_map.svh"
`include "np_decrypt.svh"

function automatic [7:0] rev8(input [7:0] d);
	rev8 = {d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]};
endfunction

reg  [7:0] data = 8'd0;
reg        busy = 1'b0;
wire       rom_dl = ioctl_download && ioctl_index == 16'd0;

assign prog_en    = rom_dl | busy;
assign prog_din   = {data, data};
assign ioctl_wait = busy | (rom_dl & sdram_init);

// Where one download byte goes. Region offsets by subtraction: the bases are not
// aligned to the region sizes (LESSONS_LEARNED, "[Seta] A region whose base is
// not aligned...").
wire [23:0] a   = ioctl_addr[23:0];
wire [23:0] o_t = a - DL_TILES;
wire [23:0] o_s = a - DL_SPRITES;
wire [23:0] o_k = a - DL_OKI;
wire [18:0] d_t = np_tile_addr(o_t[18:0]);
wire [18:0] d_s = np_spr_addr(o_s[18:0]);
wire [18:0] d_k = np_oki_addr(o_k[18:0]);
wire  [1:0] q_t = o_t[20:19];       // plane quarter = pen bit
wire  [1:0] q_s = o_s[20:19];

reg   [1:0] n_ba;
reg  [21:0] n_addr;
reg         n_lane;                 // 1 = [15:8]
reg   [7:0] n_data;
wire        n_keep = ioctl_addr[26:24] == 3'd0 && a < DL_END;

always @* begin
	if (a < DL_TILES) begin
		// 68000 words: even bytes (r ROM) are the high lane
		n_ba   = BA_PRG;
		n_lane = ~a[0];
		n_addr = {3'd0, a[0] ? np_prg_lo_addr(a[19:1]) : np_prg_hi_addr(a[19:1])};
		n_data = a[0] ? np_prg_lo_data(ioctl_dout) : np_prg_hi_data(ioctl_dout);
	end else if (a < DL_SPRITES) begin
		// word {tile, row, plane[1]}, lane plane[0]; pixel 0 to bit 7
		n_ba   = BA_TILES;
		n_lane = q_t[0];
		n_addr = {2'd0, d_t, q_t[1]};
		case (q_t)
			2'd0: n_data = rev8(np_tile_data0(ioctl_dout));
			2'd1: n_data = rev8(np_tile_data1(ioctl_dout));
			2'd2: n_data = rev8(np_tile_data2(ioctl_dout));
			default: n_data = rev8(np_tile_data3(ioctl_dout));
		endcase
	end else if (a < DL_OKI) begin
		// word {sprite, row, half, plane[1]}, lane plane[0]; pixel 0 stays in bit 0
		n_ba   = BA_SPRITES;
		n_lane = q_s[0];
		n_addr = {2'd0, d_s, q_s[1]};
		case (q_s)
			2'd0: n_data = np_spr_data0(ioctl_dout);
			2'd1: n_data = np_spr_data1(ioctl_dout);
			2'd2: n_data = np_spr_data2(ioctl_dout);
			default: n_data = np_spr_data3(ioctl_dout);
		endcase
	end else begin
		// bytes, even byte in [7:0]
		n_ba   = BA_OKI;
		n_lane = d_k[0];
		n_addr = {4'd0, d_k[18:1]};
		n_data = np_oki_data(ioctl_dout);
	end
end

always @(posedge clk) begin
	if (prog_wr && prog_rdy) begin
		prog_wr <= 1'b0;
		busy    <= 1'b0;
	end
	if (rom_dl && ioctl_wr && n_keep) begin
		prog_ba   <= n_ba;
		prog_addr <= n_addr;
		prog_dsn  <= n_lane ? 2'b01 : 2'b10;   // active low: write only this lane
		data      <= n_data;
		prog_wr   <= 1'b1;
		busy      <= 1'b1;
	end
end

endmodule

`default_nettype wire
