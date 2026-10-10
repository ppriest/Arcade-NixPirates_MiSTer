// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// Dual-port RAM, 16 bits, one clock: port A reads and writes with byte enables,
// port B only reads. Two np_tdp8, one a byte lane. Writers other than the CPU
// (hiscore, state restore) go through port A while the CPU is paused.
//
// Only this shape became one M10K copy in Quartus 17.0 (np_cpu_synth):
//   - byte enables in one RAM, written from both ports: left in registers
//     (Info 276009, "unsupported read-during-write behavior");
//   - the byte lanes as a generate loop over part-selects of one output reg:
//     each RAM built twice, as two simple dual-port copies;
//   - a depth below 1 << AW: left in registers.
// np_tdp8 alone infers BIDIR_DUAL_PORT.

`default_nettype none

module np_dpram #(
	parameter AW = 10
) (
	input  wire          clk,

	input  wire [AW-1:0] a_addr,
	input  wire    [1:0] a_we,      // [1] = [15:8]
	input  wire   [15:0] a_din,
	output wire   [15:0] a_dout,

	input  wire [AW-1:0] b_addr,
	output wire   [15:0] b_dout
);

np_tdp8 #(.AW(AW)) u_lo (
	.clk(clk), .we_a(a_we[0]), .a(a_addr), .d(a_din[7:0]), .qa(a_dout[7:0]),
	.b(b_addr), .qb(b_dout[7:0])
);

np_tdp8 #(.AW(AW)) u_hi (
	.clk(clk), .we_a(a_we[1]), .a(a_addr), .d(a_din[15:8]), .qa(a_dout[15:8]),
	.b(b_addr), .qb(b_dout[15:8])
);

endmodule

// Quartus' true-dual-port template with port B's write tied off, as
// Arcade-KonamiGX_MiSTer's rtl/video/gx_tdpram.sv: port A returns the written
// data on a write, port B the old data.
module np_tdp8 #(
	parameter AW = 10
) (
	input  wire          clk,
	input  wire          we_a,
	input  wire [AW-1:0] a,
	input  wire    [7:0] d,
	output reg     [7:0] qa,
	input  wire [AW-1:0] b,
	output reg     [7:0] qb
);

reg [7:0] mem [0:(1 << AW) - 1];

// zero in simulation, as MAME's RAM; on the board M10K comes up zero from
// configuration (and Quartus refuses an initial loop past 5000 iterations)
`ifdef SIMULATION
initial begin : clear
	integer i;
	for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 8'd0;
end
`endif

always @(posedge clk) begin
	if (we_a) begin
		mem[a] <= d;
		qa     <= d;
	end else
		qa <= mem[a];
end

always @(posedge clk) qb <= mem[b];

endmodule

`default_nettype wire
