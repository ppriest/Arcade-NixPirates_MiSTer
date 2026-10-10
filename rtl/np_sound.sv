// SPDX-License-Identifier: GPL-3.0-or-later
//
// The OKI M6295 (pirates.cpp 460): 24 MHz / 18 = 1.3333 MHz, pin 7 low, samples on SDRAM bank 3.
// out_w bit 6 is the chip's address bit 18 (set_rom_bank, 297). rtl/sound/PROVENANCE.md has the
// read deadline the slot meets.

module np_sound (
	input  wire        clk,             // 48 MHz
	input  wire        rst,
	input  wire        oki_we,          // 0xa00001 write, one clock
	input  wire  [7:0] oki_din,
	output wire  [7:0] oki_dout,
	input  wire        bank,

	// SDRAM bank 3: bytes, even byte in [7:0] (rtl/np_sdram_map.svh)
	output wire        ba3_rd,
	output wire [21:0] ba3_addr,
	input  wire        ba3_ack,
	input  wire        ba3_dst,
	input  wire        ba3_rdy,
	input  wire [15:0] sdram_dout,

	output wire signed [13:0] sound
);

reg [5:0] cen_cnt = 6'd0;
reg       cen = 1'b0;
always @(posedge clk) begin
	cen     <= cen_cnt == 6'd0;
	cen_cnt <= cen_cnt == 6'd35 ? 6'd0 : cen_cnt + 6'd1;
end

wire [17:0] rom_addr;
wire  [7:0] rom_data;
wire        rom_ok;

jt6295 #(.INTERPOL(0)) u_oki (
	.rst(rst), .clk(clk), .cen(cen), .ss(1'b0),
	.wrn(~oki_we), .din(oki_din), .dout(oki_dout),
	.rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
	.sound(sound), .sample()
);

jtframe_rom_1slot #(.SDRAMW(22), .SLOT0_DW(8), .SLOT0_AW(19)) u_slot (
	.rst(rst), .clk(clk),
	.slot0_addr({bank, rom_addr}), .slot0_dout(rom_data), .slot0_cs(1'b1), .slot0_ok(rom_ok),
	.sdram_ack(ba3_ack), .sdram_rd(ba3_rd), .sdram_addr(ba3_addr),
	.data_dst(ba3_dst), .data_rdy(ba3_rdy), .data_read(sdram_dout)
);

endmodule
