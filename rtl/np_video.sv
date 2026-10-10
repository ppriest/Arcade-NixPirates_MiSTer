// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// The video of src/mame/nix/pirates.cpp (186-285, 405-456), per scanline.
//
//   timing   384 x 262 at 6 MHz (ce_pix every 8th clock of 48 MHz): an assumption, the
//            driver gives no pixel clock (docs/ROADMAP.md, Clocks). Visible 288 x 224, MAME's
//            lines 16-239; IRQ1 at line 240.
//   tiles    bg, fg, tx: jtframe_scroll each, 8x8 4bpp, column-major maps of code and colour
//            words in one tile RAM at MAME's bases (352-356). fg and bg take the X scroll; bg
//            is opaque, fg and tx drop pen 0. One VRAM port serves the three layers in a
//            six-clock round of code and colour reads, inside the 64 clocks jtframe_tilemap
//            allows between address and use. ROM from SDRAM bank 1, three 32-bit slots.
//   sprites  the list copied at line 13 into a shadow (rtl/np_video.sv, "snapshot"; ROADMAP,
//            Design decisions), scanned at each hsync for the line after next and drawn by
//            jtframe_objdraw into its double line buffer, entries in list order so later
//            ones land on top (draw_sprites, transpen). ROM from SDRAM bank 2.
//   mixer    bg, fg, sprites, tx (281-284); pen to palette address
//            {layer, colour[6:0], pen}; xRGB_555 out through pal5bit.
//   flip     not on the board: the picture turned 180 degrees, drawn a line early through a
//            line buffer of palette addresses (OSD and the .mra's fake DIP).
//
// Pipeline offsets (LEAD_*, SPR_XOFS) put every layer's pixel for screen x at the same ce_pix;
// sim/video_tb found them against scripts/render_model.py (per layer, by palette index).

`default_nettype none

module np_video #(
	parameter LEAD_TILE = 8,        // jtframe_tilemap's pixel lags its hdump by this
	parameter LEAD_SPR  = 1,        // jtframe_obj_buffer's readout lags its hdump by this
	parameter SPR_XOFS  = 2         // and its pixel for buffer address a lands at screen a - 2
) (
	input  wire        clk,
	input  wire        rst,
	input  wire        flip,        // the whole picture turned 180 degrees, taken at line 0

	input  wire [15:0] scroll_in,   // np_main, 0x700000

	// CPU writes to sprite RAM, for write-through while the snapshot runs
	input  wire        spr_wr,
	input  wire  [9:0] spr_wr_addr,
	input  wire [15:0] spr_wr_din,
	input  wire  [1:0] spr_wr_be,

	// np_main's second RAM ports: address out, data a clock later
	output reg  [13:0] vram_addr,
	input  wire [15:0] vram_dout,
	output reg  [12:0] pal_addr,
	input  wire [15:0] pal_dout,
	output reg   [9:0] spr_addr,
	input  wire [15:0] spr_dout,

	// SDRAM: bank 1 tiles, bank 2 sprites (jtframe_sdram64 bank ports)
	output wire        ba1_rd,
	output wire [21:0] ba1_addr,
	input  wire        ba1_ack, ba1_dst, ba1_rdy,
	output wire        ba2_rd,
	output wire [21:0] ba2_addr,
	input  wire        ba2_ack, ba2_dst, ba2_rdy,
	input  wire [15:0] sdram_dout,

	output reg         ce_pix = 1'b0,
	output reg   [7:0] r = 8'd0, g = 8'd0, b = 8'd0,
	output reg         hblank = 1'b1, vblank = 1'b1, hsync = 1'b0, vsync = 1'b0,
	output wire        vblank_irq,
	output reg  [12:0] dbg_pen = 13'd0     // the palette index behind r, g, b
);

// --- timing ----------------------------------------------------------------------------------
localparam [8:0] HTOTAL = 9'd384, HVIS = 9'd288, HS_START = 9'd298, HS_END = 9'd326;
localparam [8:0] VTOTAL = 9'd262, V_TOP = 9'd16, V_BOT = 9'd239, VS_START = 9'd244, VS_END = 9'd247;

reg [2:0] cen_cnt = 3'd0;
reg [8:0] hcnt = 9'd0, vcnt = 9'd0;
always @(posedge clk) begin
	cen_cnt <= cen_cnt + 3'd1;
	ce_pix  <= cen_cnt == 3'd7;
	if (ce_pix) begin
		hcnt <= hcnt == HTOTAL - 9'd1 ? 9'd0 : hcnt + 9'd1;
		if (hcnt == HTOTAL - 9'd1) vcnt <= vcnt == VTOTAL - 9'd1 ? 9'd0 : vcnt + 9'd1;
	end
end

wire hs = hcnt >= HS_START && hcnt < HS_END;
assign vblank_irq = vcnt >= 9'd240;         // MAME's vblank start (wtiming: line 240)

// the layers run ahead of the display by their pipeline; in hblank they work on the next line
function automatic [8:0] wrap(input [9:0] v);
	wrap = v >= {1'b0, HTOTAL} ? v[8:0] - HTOTAL : v[8:0];
endfunction
// The tile layers' hdump runs on modulo 512 through the last 32 clocks of blanking into the
// first visible tile: jtframe_tilemap fetches when bit 3 of its map x changes, and a jump of
// 384 at the line's start moves the map by 128 without changing it, so the first tile was not
// fetched for some scroll values (sim/video_tb, genix frame 1500: six columns of fg at scroll
// 0x0a). The jump is now in mid-blanking, where nothing is shown.
localparam [8:0] PREROLL = 9'd32;
wire [9:0] hsum    = {1'b0, hcnt} + LEAD_TILE;
wire [8:0] hdump_t = hcnt >= HTOTAL - PREROLL ? hsum[8:0] + 9'd128 : hsum[8:0];
wire [8:0] hdump_s = wrap({1'b0, hcnt} + LEAD_SPR);

// Flip: the board has none (MAME), so it is the finished picture turned round. Each line is
// drawn a line early, of the mirrored line (V_TOP + V_BOT - 1 - line), into a line buffer of
// palette addresses that the next line reads right to left. Unflipped, nothing changes.
reg flip_f = 1'b0;
always @(posedge clk) if (ce_pix && hcnt == 9'd0 && vcnt == 9'd0) flip_f <= flip;
localparam [8:0] V_MIRROR = V_TOP + V_BOT - 9'd1;
wire [8:0] vnext   = hcnt >= HVIS ? vcnt + 9'd1 : vcnt;
wire [8:0] vdump_t = flip_f ? V_MIRROR - vnext : vnext;
wire       vis_t   = vdump_t >= V_TOP && vdump_t <= V_BOT;

// scroll and the sprite list are taken at the same point, line 13, before line 16 is drawn
reg  [15:0] scroll = 16'd0;
wire        snap_go = ce_pix && hcnt == 9'd0 && vcnt == 9'd13;
always @(posedge clk) if (snap_go) scroll <= scroll_in;

// --- tile layers -------------------------------------------------------------------------------
localparam [13:0] TX_BASE = 14'h00c0, FG_BASE = 14'h09c0, BG_BASE = 14'h1540;  // words (353-356)

wire [10:0] va [0:2];               // {row[4:0], col[5:0]} from jtframe_tilemap
reg  [15:0] code [0:2];
reg   [6:0] colr [0:2];
wire [18:0] t_ra [0:2];
wire [31:0] t_rd [0:2];
wire  [2:0] t_cs, t_ok;
wire [10:0] t_pxl [0:2];            // {colour, pen}

genvar l;
generate for (l = 0; l < 3; l = l + 1) begin : layer
	jtframe_scroll #(
		.SIZE(8), .VA(11), .CW(16), .PW(11), .MAP_HW(9), .MAP_VW(8), .HJUMP(1)
	) u_scroll (
		.rst(rst), .clk(clk), .pxl_cen(ce_pix), .hs(hs),
		.vdump(vdump_t), .hdump(hdump_t), .blankn(vis_t), .flip(1'b0),
		.scrx(l == 2 ? 9'd0 : scroll[8:0]), .scry(8'd0),
		.vram_addr(va[l]), .code(code[l]), .pal(colr[l]), .hflip(1'b0), .vflip(1'b0),
		.rom_addr(t_ra[l]), .rom_data(t_rd[l]), .rom_cs(t_cs[l]), .rom_ok(t_ok[l]),
		.pxl(t_pxl[l])
	);
end endgenerate
// layer 0 bg, 1 fg, 2 tx

// VRAM: code then colour word of each layer in turn, one read a clock
reg  [2:0] slot = 3'd0, slot_q = 3'd0;
wire [1:0] sl = slot[2:1];
always @* begin
	case (sl)
		2'd0: vram_addr = BG_BASE + {2'b00, va[0][5:0], va[0][10:6], slot[0]};
		2'd1: vram_addr = FG_BASE + {2'b00, va[1][5:0], va[1][10:6], slot[0]};
		default: vram_addr = TX_BASE + {2'b00, va[2][5:0], va[2][10:6], slot[0]};
	endcase
end
always @(posedge clk) begin
	slot   <= slot == 3'd5 ? 3'd0 : slot + 3'd1;
	slot_q <= slot;
	if (slot_q[0]) colr[slot_q[2:1]] <= vram_dout[6:0];
	else           code[slot_q[2:1]] <= vram_dout;
end

// tile ROM, bank 1: word address {code, row, j}; the slot's 32 bits are {j=1, j=0}
jtframe_rom_3slots #(
	.SDRAMW(22),
	.SLOT0_DW(32), .SLOT1_DW(32), .SLOT2_DW(32),
	.SLOT0_AW(20), .SLOT1_AW(20), .SLOT2_AW(20)
) u_tiles (
	.rst(rst), .clk(clk),
	.slot0_addr({t_ra[0], 1'b0}), .slot1_addr({t_ra[1], 1'b0}), .slot2_addr({t_ra[2], 1'b0}),
	.slot0_dout(t_rd[0]), .slot1_dout(t_rd[1]), .slot2_dout(t_rd[2]),
	.slot0_cs(t_cs[0]), .slot1_cs(t_cs[1]), .slot2_cs(t_cs[2]),
	.slot0_ok(t_ok[0]), .slot1_ok(t_ok[1]), .slot2_ok(t_ok[2]),
	.sdram_ack(ba1_ack), .sdram_rd(ba1_rd), .sdram_addr(ba1_addr),
	.data_dst(ba1_dst), .data_rdy(ba1_rdy), .data_read(sdram_dout)
);

// --- sprites: snapshot --------------------------------------------------------------------------
reg  [15:0] shadow [0:1023];
reg   [9:0] cp_cnt = 10'd0, cp_wa = 10'd0;
reg         copying = 1'b0, cp_we = 1'b0;
reg   [9:0] sh_raddr = 10'd0;
reg  [15:0] sh_dout = 16'd0;

always @* spr_addr = cp_cnt;

always @(posedge clk) begin
	cp_we <= 1'b0;
	if (rst) copying <= 1'b0;
	else if (snap_go) begin
		copying <= 1'b1;
		cp_cnt  <= 10'd0;
	end else if (copying) begin
		// a CPU write behind the cursor goes into the shadow this clock; the copy waits a clock
		if (spr_wr && spr_wr_addr < cp_cnt) begin
			if (spr_wr_be[0]) shadow[spr_wr_addr][7:0]  <= spr_wr_din[7:0];
			if (spr_wr_be[1]) shadow[spr_wr_addr][15:8] <= spr_wr_din[15:8];
		end else begin
			cp_we  <= 1'b1;
			cp_wa  <= cp_cnt;
			cp_cnt <= cp_cnt + 10'd1;
			if (cp_cnt == 10'd1023) copying <= 1'b0;
		end
	end
	if (cp_we) shadow[cp_wa] <= spr_dout;
	sh_dout <= shadow[sh_raddr];
end

// --- sprites: scan and draw ---------------------------------------------------------------------
// At each hsync the line buffer swaps; the half now free is drawn for the line after next.
// Entry k (1-254): colour 4k, x 4k+1, code 4k+2, y 4k-1; the list ends at a y with bit 15.
localparam S_IDLE = 3'd0, S_Y = 3'd1, S_YW = 3'd2, S_X = 3'd3, S_C = 3'd4, S_COL = 3'd5, S_DRAW = 3'd6;
reg   [2:0] st = S_IDLE;
reg   [7:0] k = 8'd0;
reg   [8:0] target = 9'd0;
reg         hs_l = 1'b0;
reg  [15:0] w_x, w_code;
reg   [3:0] ysub;
reg         draw = 1'b0;
wire        busy;
wire [16:0] dy = {8'd0, target} + {1'b0, sh_dout} - 17'd242;   // target - (0xf2 - y), y on sh_dout in S_Y
wire [16:0] sx = {1'b0, w_x} - 17'd32;
wire        x_in = $signed(sx) > -17'sd16 && $signed(sx) < 17'sd288;

always @(posedge clk) begin
	hs_l <= hs;
	draw <= 1'b0;
	if (rst) st <= S_IDLE;
	else case (st)
		S_IDLE: if (hs && !hs_l) begin
			// read out two lines on; flipped, that line's pixels are shown on the line after
			target <= flip_f ? V_MIRROR - 9'd2 - vcnt : vcnt + 9'd2;
			k <= 8'd1;
			sh_raddr <= 10'd3;          // y of entry 1
			st <= S_YW;
		end
		S_YW: st <= S_Y;                // shadow read latency
		S_Y: begin
			if (sh_dout[15] || k == 8'd255) st <= S_IDLE;
			else if (dy < 17'd16) begin
				ysub <= dy[3:0];
				sh_raddr <= {k, 2'd1};  // x
				st <= S_X;
			end else begin
				k <= k + 8'd1;
				sh_raddr <= {k + 8'd1, 2'd0} - 10'd1;
				st <= S_YW;
			end
		end
		S_X: begin sh_raddr <= {k, 2'd2}; st <= S_C; end      // x arrives next clock
		S_C: begin w_x <= sh_dout; sh_raddr <= {k, 2'd0}; st <= S_COL; end
		S_COL: begin w_code <= sh_dout; st <= S_DRAW; end
		S_DRAW: if (!busy) begin
			// sh_dout now holds the colour word
			if (x_in) draw <= 1'b1;
			k <= k + 8'd1;
			sh_raddr <= {k + 8'd1, 2'd0} - 10'd1;
			st <= S_YW;
		end
		default: st <= S_IDLE;
	endcase
end

reg  [13:0] d_code;
reg   [8:0] d_x;
reg   [3:0] d_ysub;
reg         d_hf, d_vf;
reg   [6:0] d_pal;
always @(posedge clk) if (st == S_DRAW && !busy) begin
	d_code <= w_code[15:2]; d_hf <= w_code[1]; d_vf <= w_code[0];
	d_x <= sx[8:0] + SPR_XOFS[8:0]; d_ysub <= ysub; d_pal <= sh_dout[6:0];
end

wire [20:2] s_ra;                   // {code, H, Y}
wire        s_cs, s_ok;
wire [31:0] s_rd;
wire [10:0] s_pxl;

// HFIX off: it assumes an hdump that runs on to 511 through blanking, and this one wraps at
// 384, so its readout counter was still past 384 at the next line and caught up near x=128
// (sim/video_tb: no sprite left of it)
jtframe_objdraw #(
	.AW(9), .CW(14), .PW(11), .LATCH(1), .HFIX(0)
) u_obj (
	.rst(rst), .clk(clk), .pxl_cen(ce_pix), .hs(hs), .flip(1'b0), .hdump(hdump_s),
	.draw(draw), .busy(busy), .code(d_code), .xpos(d_x), .ysub(d_ysub),
	.hzoom(6'd0), .hz_keep(1'b0), .hflip(d_hf), .vflip(d_vf), .pal(d_pal),
	.rom_addr(s_ra), .rom_cs(s_cs), .rom_ok(s_ok), .rom_data(s_rd), .pxl(s_pxl)
);

// sprite ROM, bank 2: word address {code, row, half, j}; jtframe_draw asks for {code, half, row}
jtframe_rom_1slot #(
	.SDRAMW(22), .SLOT0_DW(32), .SLOT0_AW(20)
) u_sprites (
	.rst(rst), .clk(clk),
	.slot0_addr({s_ra[20:7], s_ra[5:2], s_ra[6], 1'b0}), .slot0_dout(s_rd), .slot0_cs(s_cs),
	.slot0_ok(s_ok),
	.sdram_ack(ba2_ack), .sdram_rd(ba2_rd), .sdram_addr(ba2_addr),
	.data_dst(ba2_dst), .data_rdy(ba2_rdy), .data_read(sdram_dout)
);

// --- mixer and palette ---------------------------------------------------------------------------
// screen order bg, fg, sprites, tx; pen 0 of fg, sprites and tx is transparent
reg  [3:0] blank_sh = 4'hf, vb_sh = 4'hf, hs_sh = 4'h0, vs_sh = 4'h0;
wire       hb_now = hcnt >= HVIS, vb_now = vcnt < V_TOP || vcnt > V_BOT;
wire       vs_now = vcnt >= VS_START && vcnt < VS_END;

function automatic [7:0] pal5(input [4:0] v); pal5 = {v, v[4:2]}; endfunction

reg [12:0] mix;
always @* begin
	if (t_pxl[2][3:0] != 4'd0)      mix = {2'b00, t_pxl[2]};
	else if (s_pxl[3:0] != 4'd0)    mix = {2'b11, s_pxl};
	else if (t_pxl[1][3:0] != 4'd0) mix = {2'b01, t_pxl[1]};
	else                            mix = {2'b10, t_pxl[0]};
end

// flip line buffer: the pixel mixed at hcnt h is shown at screen x = h - 1, so it is written
// at h on this line and read at 289 - h on the next; the read address is steady for the 8
// clocks before each ce_pix (sim/video_tb --flip)
reg  [12:0] flip_lb [0:1023];
reg  [12:0] flip_q;
wire  [8:0] flip_rx = HVIS + 9'd1 - hcnt;
always @(posedge clk) begin
	if (ce_pix) flip_lb[{vcnt[0], hcnt}] <= mix;
	flip_q <= flip_lb[{~vcnt[0], flip_rx}];
end

always @(posedge clk) if (ce_pix) begin
	pal_addr <= flip_f ? flip_q : mix;
	// palette data arrives a clock after pal_addr; it is taken at the next ce_pix
	dbg_pen <= pal_addr;
	r <= pal5(pal_dout[14:10]);
	g <= pal5(pal_dout[9:5]);
	b <= pal5(pal_dout[4:0]);
	blank_sh <= {blank_sh[2:0], hb_now};
	vb_sh    <= {vb_sh[2:0], vb_now};
	hs_sh    <= {hs_sh[2:0], hs};
	vs_sh    <= {vs_sh[2:0], vs_now};
	hblank <= blank_sh[1];
	vblank <= vb_sh[1];
	hsync  <= hs_sh[1];
	vsync  <= vs_sh[1];
end

endmodule

`default_nettype wire
