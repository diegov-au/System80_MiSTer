module system80_core
(
	input         clk_sys,
	input         reset,

	input         sim_fast,

	output        ce_pix,
	output  [7:0] video_r,
	output  [7:0] video_g,
	output  [7:0] video_b,
	output        video_hs,
	output        video_vs,
	output        video_hb,
	output        video_vb,
	input         video_50hz,

	input   [1:0] phosphor,

	input         snow_en,

	input  [63:0] kbd_matrix,

	output        cas_motor,
	output  [1:0] cas_out,
	output        cas_deck,
	input         cas_in,

	input         tape_wr,
	input         tape_rewind,
	output        tape_playing,
	output [16:0] tape_pos,
	output [16:0] tape_len,
	output        tape_pulse_o,

	output signed [15:0] audio,

	input   [1:0] disk_present,
	input   [1:0] disk_wp,
	input   [1:0] img_mounted,
	input  [31:0] img_size,
	output        disk_busy,

	output        disk_prepare,

	output [31:0] sd_lba,
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,

	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_data,

	output [15:0] debug_pc,
	output  [7:0] debug_opcode,
	output        debug_fetch,
	output [15:0] debug_addr,
	output  [7:0] debug_din,
	output  [7:0] debug_dout,
	output        debug_mreq,
	output        debug_iorq,
	output        debug_rd,
	output        debug_wr
);

wire [4:0] div_max = sim_fast ? 5'd5 : 5'd23;

reg [4:0] clkdiv = 0;
always @(posedge clk_sys) clkdiv <= (clkdiv == div_max) ? 5'd0 : clkdiv + 5'd1;

assign ce_pix = sim_fast ? 1'b1 : (clkdiv[1:0] == 2'd0);
wire   ce_cpu = (clkdiv == 5'd0);

wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
wire  [7:0] cpu_din;
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;

wire        fdc_prepare;
reg         ever_run = 1'b0;
wire        cpu_reset = reset | (fdc_prepare & ~ever_run);
always @(posedge clk_sys) if (~cpu_reset) ever_run <= 1'b1;

wire        exp_int;
wire        fdc_intrq;
wire  [7:0] fdc_dout;
wire        fdc_drq;
wire        fdc_sd_drive;
wire  [7:0] fdc_buff_din;
wire        fdc_rd, fdc_wr;

tv80s_ce cpu
(
	.reset_n (~cpu_reset),
	.clk     (clk_sys),
	.cen     (ce_cpu & ~fdc_prepare),
	.wait_n  (1'b1),
	.int_n   (~exp_int),
	.nmi_n   (1'b1),
	.busrq_n (1'b1),
	.m1_n    (m1_n),
	.mreq_n  (mreq_n),
	.iorq_n  (iorq_n),
	.rd_n    (rd_n),
	.wr_n    (wr_n),
	.rfsh_n  (rfsh_n),
	.halt_n  (),
	.busak_n (),
	.A       (cpu_addr),
	.di      (cpu_din),
	.dout    (cpu_dout)
);

wire mem_rd   = ~mreq_n & ~rd_n & rfsh_n;
wire mem_wr   = ~mreq_n & ~wr_n & rfsh_n;
wire m1_fetch = ~m1_n   & ~mreq_n & ~rd_n & rfsh_n;
wire io_rd    = ~iorq_n & ~rd_n & m1_n;
wire io_wr    = ~iorq_n & ~wr_n & m1_n;

reg io_wr_d;
always @(posedge clk_sys) if (ce_cpu) io_wr_d <= io_wr;
wire io_wr_stb = ce_cpu & io_wr & ~io_wr_d;

wire [7:0] mem_din;
wire [9:0] vid_addr;
wire [7:0] vid_data;
wire       vid_contend;
wire [10:0] chr_addr;
wire [7:0] chr_data;

system80_mem mem
(
	.clk_sys        (clk_sys),
	.cpu_addr       (cpu_addr),
	.cpu_dout       (cpu_dout),
	.cpu_din        (mem_din),
	.mem_rd         (mem_rd),
	.mem_wr         (mem_wr),
	.kbd_matrix     (kbd_matrix),
	.vid_addr       (vid_addr),
	.vid_data       (vid_data),
	.vid_contend    (vid_contend),
	.chr_addr       (chr_addr),
	.chr_data       (chr_data),
	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_data     (ioctl_data)
);

wire port_f8 = (cpu_addr[7:0] == 8'hF8);
wire port_f9 = (cpu_addr[7:0] == 8'hF9);
wire port_fd = (cpu_addr[7:0] == 8'hFD);
wire port_fe = (cpu_addr[7:0] == 8'hFE);
wire port_ff = (cpu_addr[7:0] == 8'hFF);

reg [7:0] latch_ff;
reg [7:0] latch_fe;

always @(posedge clk_sys) begin
	if (reset) begin
		latch_ff <= 8'h00;
		latch_fe <= 8'h00;
	end
	else if (io_wr_stb) begin
		if (port_ff) latch_ff <= cpu_dout;
		if (port_fe) latch_fe <= cpu_dout;
	end
end

assign cas_motor = latch_ff[2];
assign cas_out   = latch_ff[1:0];

wire tape_pulse;
assign tape_pulse_o = tape_pulse;

system80_tape tape (
	.clk_sys        (clk_sys),
	.reset          (reset),
	.ce_cpu         (ce_cpu),
	.tape_wr        (tape_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_data     (ioctl_data),
	.rewind         (tape_rewind),
	.motor          (cas_motor),
	.pulse          (tape_pulse),
	.playing        (tape_playing),
	.pos            (tape_pos),
	.len            (tape_len)
);
assign cas_deck  = latch_fe[4];

localparam signed [15:0] SPK_LEVEL = 16'sd6000;

reg signed [15:0] audio_r;
always @(posedge clk_sys) begin
	if (reset || latch_ff[2])
		audio_r <= 16'sd0;
	else case (latch_ff[1:0])
		2'b01:   audio_r <=  SPK_LEVEL;
		2'b10:   audio_r <= -SPK_LEVEL;
		default: audio_r <= 16'sd0;
	endcase
end

assign audio = audio_r;

reg cas_latch;
always @(posedge clk_sys) begin
	if (reset)                     cas_latch <= 1'b0;
	else if (tape_pulse | cas_in)  cas_latch <= 1'b1;
	else if (io_wr_stb & port_ff)  cas_latch <= 1'b0;
end

wire cas_bit = cas_latch;

wire sel_exp = (cpu_addr[15:5] == 11'b0011_0111_111);
wire exp_drv = sel_exp & ~cpu_addr[3] & ~cpu_addr[2];
wire exp_fdc = sel_exp &  cpu_addr[3] &  cpu_addr[2];

wire exp_present = |disk_present;

reg [3:0] drv_sel;
always @(posedge clk_sys) begin
	if (reset)                drv_sel <= 4'd0;
	else if (mem_wr & exp_drv) drv_sel <= cpu_dout[3:0];
end

wire       fdc_drive    = ~drv_sel[0] & drv_sel[1];
wire       fdc_selected = drv_sel[0] | drv_sel[1];

assign disk_prepare = fdc_prepare;
wire       fdc_ready    = fdc_selected & disk_present[fdc_drive] & ~fdc_prepare;

localparam HB_DIV = 16'd44352;

reg [15:0] hb_cnt     = 16'd0;
reg        hb_pending = 1'b0;

reg  mem_rd_d;
always @(posedge clk_sys) if (ce_cpu) mem_rd_d <= mem_rd;
wire mem_rd_stb = ce_cpu & mem_rd & ~mem_rd_d;

always @(posedge clk_sys) begin
	if (reset) begin
		hb_cnt     <= 16'd0;
		hb_pending <= 1'b0;
	end
	else begin
		if (mem_rd_stb & exp_drv) hb_pending <= 1'b0;

		if (ce_cpu) begin
			if (hb_cnt == HB_DIV - 16'd1) begin
				hb_cnt     <= 16'd0;
				hb_pending <= 1'b1;
			end
			else hb_cnt <= hb_cnt + 16'd1;
		end
	end
end

wire [7:0] exp_irq = {hb_pending, fdc_intrq, 6'b000000};

assign exp_int = exp_present & hb_pending;

assign sd_rd       = {fdc_rd &  fdc_sd_drive, fdc_rd & ~fdc_sd_drive};
assign sd_wr       = {fdc_wr &  fdc_sd_drive, fdc_wr & ~fdc_sd_drive};
assign sd_buff_din = fdc_buff_din;

fd1771 #(.RWMODE(1), .DMK(1)) fdc
(
	.clk_sys      (clk_sys),
	.ce           (ce_cpu),
	.reset        (reset),

	.io_en        (exp_fdc & exp_present),
	.rd           (mem_rd),
	.wr           (mem_wr),
	.addr         (cpu_addr[1:0]),
	.din          (cpu_dout),
	.dout         (fdc_dout),
	.drq          (fdc_drq),
	.intrq        (fdc_intrq),
	.busy         (disk_busy),

	.wp           (disk_wp[fdc_drive]),

	.size_code    (3'd5),
	.layout       (1'b1),
	.side         (1'b0),
	.drive        (fdc_drive),
	.ready        (fdc_ready),
	.dir_track    (8'd17) ,

	.img_mounted  (img_mounted),
	.img_size     (img_size),
	.prepare      (fdc_prepare),
	.sd_drive     (fdc_sd_drive),
	.sd_lba       (sd_lba),
	.sd_rd        (fdc_rd),
	.sd_wr        (fdc_wr),
	.sd_ack       (|sd_ack),
	.sd_buff_addr (sd_buff_addr),
	.sd_buff_dout (sd_buff_dout),
	.sd_buff_din  (fdc_buff_din),
	.sd_buff_wr   (sd_buff_wr),

	.input_active (1'b0),
	.input_addr   (20'd0),
	.input_data   (8'd0),
	.input_wr     (1'b0),
	.buff_addr    (),
	.buff_read    (),
	.buff_din     (8'd0)
);

wire _unused_fdc = &{1'b0, fdc_drq, fdc_intrq, 1'b0};

reg [7:0] io_din;
always @* begin
	if      (port_ff) io_din = {cas_bit, 7'h00};
	else if (port_fe) io_din = 8'hFF;
	else if (port_fd) io_din = 8'h30;
	else if (port_f9) io_din = 8'h00;
	else if (port_f8) io_din = 8'h00;
	else              io_din = 8'hFF;
end

wire [7:0] exp_din = exp_fdc ? fdc_dout : exp_irq;

assign cpu_din = io_rd                   ? io_din  :
                 (sel_exp & exp_present) ? exp_din :
                                           mem_din;

system80_video video
(
	.clk_sys    (clk_sys),
	.ce_pix     (ce_pix),
	.reset      (reset),
	.video_50hz (video_50hz),
	.phosphor   (phosphor),
	.snow_en    (snow_en),
	.vid_contend(vid_contend),
	.vid_addr   (vid_addr),
	.vid_data   (vid_data),
	.chr_addr   (chr_addr),
	.chr_data   (chr_data),
	.video_r    (video_r),
	.video_g    (video_g),
	.video_b    (video_b),
	.video_hs   (video_hs),
	.video_vs   (video_vs),
	.video_hb   (video_hb),
	.video_vb   (video_vb)
);

assign debug_pc     = cpu_addr;
assign debug_opcode = cpu_din;
assign debug_fetch  = ce_cpu & m1_fetch;
assign debug_addr   = cpu_addr;
assign debug_din    = cpu_din;
assign debug_dout   = cpu_dout;
assign debug_mreq   = ~mreq_n;
assign debug_iorq   = ~iorq_n;
assign debug_rd     = ~rd_n;
assign debug_wr     = ~wr_n;

endmodule
