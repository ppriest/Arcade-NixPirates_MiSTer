// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Priest
//
// np_rom_loader against a whole download image (scripts/build_mra.py --image):
// every byte streamed the way hps_io sends it (one ioctl_wr, then nothing until
// ioctl_wait is low), into a stand-in for jtframe_sdram64's prog port that
// completes each write 2-9 clocks after prog_wr and pulses prog_rdy. The four
// banks are dumped as 4M little-endian 16-bit words each for
// sim/loader_tb/run_loader_tb.py to compare with scripts/sdram_model.py.
//
//   +image=<file>  download image        +out=<prefix>  writes <prefix>bank{0..3}.bin

`timescale 1ns/1ps
`default_nettype none

module tb_loader;

localparam NBYTES = 24'h580000;      // DL_END, rtl/np_rom_map.svh
localparam WORDS  = 1 << 22;

reg clk = 1'b0;
always #10.4167 clk = ~clk;          // 48 MHz

reg         sdram_init = 1'b1;
reg         ioctl_download = 1'b0, ioctl_wr = 1'b0;
reg  [26:0] ioctl_addr = 27'd0;
reg   [7:0] ioctl_dout = 8'd0;
wire        ioctl_wait, prog_en, prog_wr;
wire [21:0] prog_addr;
wire  [1:0] prog_ba, prog_dsn;
wire [15:0] prog_din;
reg         prog_rdy = 1'b0;

np_rom_loader dut (
	.clk(clk), .sdram_init(sdram_init),
	.ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.prog_en(prog_en), .prog_addr(prog_addr), .prog_ba(prog_ba), .prog_wr(prog_wr),
	.prog_din(prog_din), .prog_dsn(prog_dsn), .prog_rdy(prog_rdy)
);

reg [15:0] bank0 [0:WORDS-1];
reg [15:0] bank1 [0:WORDS-1];
reg [15:0] bank2 [0:WORDS-1];
reg [15:0] bank3 [0:WORDS-1];
reg  [7:0] img   [0:NBYTES-1];

integer errors = 0, writes = 0, lat = 0;

task automatic put(input [1:0] ba, input [21:0] w, input [15:0] d, input [1:0] dsn);
	reg [15:0] old;
	case (ba)
		2'd0: old = bank0[w];
		2'd1: old = bank1[w];
		2'd2: old = bank2[w];
		default: old = bank3[w];
	endcase
	if (!dsn[0]) old[7:0]  = d[7:0];
	if (!dsn[1]) old[15:8] = d[15:8];
	case (ba)
		2'd0: bank0[w] = old;
		2'd1: bank1[w] = old;
		2'd2: bank2[w] = old;
		default: bank3[w] = old;
	endcase
endtask

// prog port stand-in
always @(posedge clk) begin
	prog_rdy <= 1'b0;
	if (prog_wr && !prog_rdy) begin
		if (!prog_en) begin
			if (errors < 10) $display("ERROR: prog_wr without prog_en at bank %0d word %06x", prog_ba, prog_addr);
			errors = errors + 1;
		end
		if (sdram_init) begin
			if (errors < 10) $display("ERROR: prog_wr during SDRAM init");
			errors = errors + 1;
		end
		if (prog_dsn != 2'b01 && prog_dsn != 2'b10) begin
			if (errors < 10) $display("ERROR: prog_dsn %b is not one lane", prog_dsn);
			errors = errors + 1;
		end
		if (lat == 0)
			lat = 2 + ($urandom & 7);
		else if (lat == 1) begin
			put(prog_ba, prog_addr, prog_din, prog_dsn);
			writes = writes + 1;
			prog_rdy <= 1'b1;
			lat = 0;
		end else
			lat = lat - 1;
	end
end

string image, out;
integer fd, n, i, b, w;

initial begin
	for (w = 0; w < WORDS; w = w + 1) begin
		bank0[w] = 16'd0; bank1[w] = 16'd0; bank2[w] = 16'd0; bank3[w] = 16'd0;
	end
	if (!$value$plusargs("image=%s", image)) begin $display("ERROR: +image= missing"); $finish; end
	if (!$value$plusargs("out=%s", out)) out = "";
	fd = $fopen(image, "rb");
	if (fd == 0) begin $display("ERROR: cannot open %s", image); $finish; end
	n = $fread(img, fd);
	$fclose(fd);
	if (n != NBYTES) begin $display("ERROR: image is %0d bytes, expected %0d", n, NBYTES); $finish; end

	// download starts while the SDRAM still initialises: the loader must hold the HPS
	repeat (10) @(posedge clk);
	ioctl_download = 1'b1;
	repeat (200) @(posedge clk);
	if (!ioctl_wait) begin $display("ERROR: ioctl_wait low during SDRAM init"); errors = errors + 1; end
	sdram_init = 1'b0;

	for (i = 0; i < n; i = i + 1) begin
		while (ioctl_wait) @(posedge clk);
		ioctl_addr <= i[26:0];
		ioctl_dout <= img[i];
		ioctl_wr   <= 1'b1;
		@(posedge clk);
		ioctl_wr   <= 1'b0;
		repeat (1 + ($urandom & 3)) @(posedge clk);
	end
	while (ioctl_wait) @(posedge clk);
	ioctl_download = 1'b0;
	repeat (4) @(posedge clk);
	if (prog_en) begin $display("ERROR: prog_en high after the download"); errors = errors + 1; end
	if (writes != n) begin $display("ERROR: %0d writes for %0d bytes", writes, n); errors = errors + 1; end

	if (out != "") begin
		for (b = 0; b < 4; b = b + 1) begin
			fd = $fopen($sformatf("%sbank%0d.bin", out, b), "wb");
			for (w = 0; w < WORDS; w = w + 1)
				case (b)
					0: $fwrite(fd, "%c%c", bank0[w][7:0], bank0[w][15:8]);
					1: $fwrite(fd, "%c%c", bank1[w][7:0], bank1[w][15:8]);
					2: $fwrite(fd, "%c%c", bank2[w][7:0], bank2[w][15:8]);
					default: $fwrite(fd, "%c%c", bank3[w][7:0], bank3[w][15:8]);
				endcase
			$fclose(fd);
		end
	end
	$display("%s: %0d bytes, %0d writes, %0d errors", errors == 0 ? "DONE" : "FAIL", n, writes, errors);
	$finish;
end

endmodule

`default_nettype wire
