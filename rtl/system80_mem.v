module system80_mem
(
	input         clk_sys,

	input  [15:0] cpu_addr,
	input   [7:0] cpu_dout,
	output  [7:0] cpu_din,
	input         mem_rd,
	input         mem_wr,

	input  [63:0] kbd_matrix,

	input   [9:0] vid_addr,
	output  [7:0] vid_data,

	output        vid_contend,

	input  [10:0] chr_addr,
	output  [7:0] chr_data,

	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_data
);

localparam ROM_BYTES = 14336;
localparam CHR_BYTES = 2048;

wire sel_rom = (cpu_addr <  16'h3800);
wire sel_kbd = (cpu_addr >= 16'h3800) && (cpu_addr < 16'h3C00);
wire sel_vid = (cpu_addr >= 16'h3C00) && (cpu_addr < 16'h4000);
wire sel_ram = (cpu_addr >= 16'h4000);

reg [7:0] rom[0:ROM_BYTES-1] /* verilator public_flat_rw */;
reg [7:0] rom_q;

// THE ROM IS BAKED INTO THE BITSTREAM, and the downloader still overrides it.
//
// `$readmemh` in an initial block is how an inferred RAM gets an initial value:
// Quartus turns it into the M10K's init contents and Verilator simply executes
// it, so ONE mechanism covers both toolchains. That matters here more than
// usual - a rule with a separate copy per toolchain is the one that gets fixed
// in the tested half only.
//
// It does not replace the download path, it underlies it. `reset` in
// system80.sv takes `ioctl_download` as a LEVEL, so with no boot0.rom present
// reset simply never asserts and these contents stand; with one on the SD card
// the framework loads it straight over the top exactly as before. So a user can
// still substitute a different ROM by dropping a file in, and a card with no
// ROM at all now boots.
//
// THE .hex FILES ARE GENERATED AND GITIGNORED. They are a copyrighted ROM in
// another encoding, so they live where `release/` does - outside the repo -
// and `make bundle` builds them. That puts a generation step ahead of every
// Quartus build, and a MISSING FILE IS ONLY A WARNING in Quartus: it would
// silently produce a blank ROM and a machine that does not boot. See CLAUDE.md.
//
// The path differs because the two toolchains run from different directories -
// Quartus from the project root, Verilator from verilator/. SIMULATION is
// already defined by the Verilator Makefile, so this reuses a macro that is
// tested rather than inventing one that is not.
initial begin
`ifdef SIMULATION
	$readmemh("../rtl/boot0_rom.hex", rom);
`else
	$readmemh("rtl/boot0_rom.hex", rom);
`endif
end

wire rom_load = ioctl_download & ioctl_wr & (ioctl_addr < ROM_BYTES);

always @(posedge clk_sys) begin
	if (rom_load)  rom[ioctl_addr[13:0]] <= ioctl_data;
	if (sel_rom)   rom_q <= rom[cpu_addr[13:0]];
end

reg [7:0] chr[0:CHR_BYTES-1] /* verilator public_flat_rw */;
reg [7:0] chr_q;

initial begin
`ifdef SIMULATION
	$readmemh("../rtl/boot0_chr.hex", chr);
`else
	$readmemh("rtl/boot0_chr.hex", chr);
`endif
end

wire chr_load = ioctl_download & ioctl_wr &
                (ioctl_addr >= ROM_BYTES) && (ioctl_addr < ROM_BYTES + CHR_BYTES);
wire [10:0] chr_load_addr = ioctl_addr[10:0] - ROM_BYTES[10:0];

always @(posedge clk_sys) begin
	if (chr_load) chr[chr_load_addr] <= ioctl_data;
	chr_q <= chr[chr_addr];
end

assign chr_data = chr_q;

assign vid_contend = sel_vid;

reg [7:0] vram[0:1023] /* verilator public_flat_rw */;
reg [7:0] vram_q;
reg [7:0] vid_q;

always @(posedge clk_sys) begin
	if (mem_wr & sel_vid) vram[cpu_addr[9:0]] <= cpu_dout;
	vram_q <= vram[cpu_addr[9:0]];
	vid_q  <= vram[vid_addr];
end

assign vid_data = vid_q;

reg [7:0] ram[0:49151] /* verilator public_flat_rw */;
reg [7:0] ram_q;

wire [15:0] ram_addr = cpu_addr - 16'h4000;

always @(posedge clk_sys) begin
	if (mem_wr & sel_ram) ram[ram_addr] <= cpu_dout;
	if (sel_ram)          ram_q <= ram[ram_addr];
end

reg [7:0] kbd_q;
integer r;
always @* begin
	kbd_q = 8'h00;
	for (r = 0; r < 8; r = r + 1)
		if (cpu_addr[r]) kbd_q = kbd_q | kbd_matrix[r*8 +: 8];
end

assign cpu_din = sel_rom ? rom_q  :
                 sel_kbd ? kbd_q  :
                 sel_vid ? vram_q :
                           ram_q;

wire _unused = &{1'b0, cpu_addr[15:14], 1'b0};

endmodule
