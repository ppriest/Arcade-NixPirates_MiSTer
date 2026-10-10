// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fast ROM load. An .mra whose <rom index="0"> carries address="0x30000000" makes the HPS write
// the ROM image straight into DDR3; the core sees ioctl_download rise and fall with no ioctl_wr.
// This replays that image, byte by byte, into rtl/np_rom_loader.sv's download port -- ioctl_wr
// pulses with ioctl_addr, paced by its ioctl_wait -- so the decryption and the SDRAM write path
// are the ones the byte-streamed download uses (sim/loader_sdram_tb).
//
// Arcade-JalecoMS32_MiSTer rtl/memory/ms32_rom_loader.sv at 42a6340f, without f1superb's map:
// the whole image, 0 to DL_END (rtl/np_rom_map.svh), is copied. Granules come from ddram_phy
// (8 bytes, byte i at rdata[8*i +: 8]).

module np_ddr_loader #(
	parameter logic [27:0] LENGTH = 28'h058_0000
) (
	input  logic         clk,
	input  logic         reset,

	input  logic         start,       // pulse
	output logic         active,      // copying: hold the core, feed the download port

	output logic         ddr_req,     // ddram_phy: pulse while !busy
	output logic [27:0]  ddr_addr,
	input  logic         ddr_busy,
	input  logic         ddr_valid,
	input  logic [63:0]  ddr_rdata,

	output logic         l_wr,        // one clock per byte
	output logic [26:0]  l_addr,
	output logic [7:0]   l_dout,
	input  logic         l_wait       // np_rom_loader's ioctl_wait
);

	typedef enum logic [2:0] {L_IDLE, L_RD, L_RDWAIT, L_BYTE, L_HOLD, L_WAIT} lst_t;
	lst_t st;
	logic [27:0] base;
	logic [63:0] gran;
	logic [2:0]  k;

	assign active   = (st != L_IDLE);
	assign ddr_req  = (st == L_RD) && !ddr_busy;
	assign ddr_addr = base;

	always_ff @(posedge clk) begin
		l_wr <= 1'b0;
		if (reset) begin
			st <= L_IDLE;
		end else case (st)
			L_IDLE: if (start) begin base <= 28'd0; st <= L_RD; end
			L_RD:     if (!ddr_busy) st <= L_RDWAIT;
			L_RDWAIT: if (ddr_valid) begin gran <= ddr_rdata; k <= 3'd0; st <= L_BYTE; end
			L_BYTE: begin
				l_addr <= base[26:0] + {24'd0, k};
				l_dout <= gran[{k, 3'b000} +: 8];
				l_wr   <= 1'b1;
				st     <= L_HOLD;
			end
			L_HOLD: st <= L_WAIT;                 // ioctl_wait follows the pulse a clock later
			L_WAIT: if (!l_wait) begin
				if (k != 3'd7) begin
					k  <= k + 3'd1;
					st <= L_BYTE;
				end else if (base + 28'd8 >= LENGTH) begin
					st <= L_IDLE;
				end else begin
					base <= base + 28'd8;
					st   <= L_RD;
				end
			end
			default: st <= L_IDLE;
		endcase
	end

endmodule
