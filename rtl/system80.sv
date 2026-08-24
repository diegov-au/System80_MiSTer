//============================================================================
//
//  Dick Smith System 80 (Blue Label) core for MiSTer — top level.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
//
//  Ported from verilator/sim.v, which is the same machine wired to the
//  simulation harness and is the reference for anything ambiguous here. The two
//  must stay in step: the harness is what proves the core, so a signal that
//  exists only on this side is a signal nothing tests.
//
//  CONF_STR IS THE ONE SURFACE NO SIMULATION COVERS. The harness never parses
//  it. Anything that lives only here - the ROM slot, the option list - has to be
//  checked on hardware deliberately. It cost the MicroBee core two hardware
//  rounds (archived BUG-011, BUG-014).
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_MIX = 0;
assign AUDIO_S   = 1;
assign AUDIO_L   = audio;
assign AUDIO_R   = audio;

assign LED_USER  = ioctl_download;
wire disk_busy;
wire disk_prepare;
assign LED_DISK  = {1'b0, disk_busy | disk_prepare};
assign LED_POWER = 0;
assign BUTTONS   = 0;

`include "build_id.v"
localparam CONF_STR = {
	"System80;;",
	"-;",
	"S0,DSKJV1DMK,Mount Drive 0:;",
	"S1,DSKJV1DMK,Mount Drive 1:;",
	"-;",
	"F1,CAS,Load Tape;",
	"T[16],Rewind Tape;",
	"-;",
	"O[11:10],Phosphor,Green,Amber,White;",
	"O[9],Snow,On,Off;",
	"O[15],Keyboard,Symbolic,Positional;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[3:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"P1O[14:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"-;",
	"R[0],Reset;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire   [1:0] buttons;
wire  [10:0] ps2_key;
wire         forced_scandoubler;
wire  [21:0] gamma_bus;

wire         ioctl_download;
wire         ioctl_wr;
wire  [24:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire  [15:0] ioctl_index;

wire  [31:0] sd_lba[2];
wire   [1:0] sd_rd;
wire   [1:0] sd_wr;
wire   [1:0] sd_ack;
wire   [8:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[2];
wire         sd_buff_wr;
wire   [1:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;

wire  [31:0] fdc_lba;
wire   [7:0] fdc_buff_din;
assign sd_lba[0]      = fdc_lba;
assign sd_lba[1]      = fdc_lba;
assign sd_buff_din[0] = fdc_buff_din;
assign sd_buff_din[1] = fdc_buff_din;

reg [1:0] disk_present = 2'b00;
reg [1:0] disk_wp      = 2'b00;
always @(posedge clk_sys) begin
	if (img_mounted[0]) begin disk_present[0] <= |img_size; disk_wp[0] <= img_readonly; end
	if (img_mounted[1]) begin disk_present[1] <= |img_size; disk_wp[1] <= img_readonly; end
end

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(1'b0),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.ps2_key(ps2_key)
);

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire rom_slot0 = (ioctl_index == 16'd0);

wire reset = RESET | status[0] | buttons[1] | (ioctl_download & rom_slot0);

wire rom_wr    = ioctl_wr & rom_slot0;

wire tape_slot = (ioctl_index[5:0] == 6'd1);
wire tape_wr   = ioctl_wr & tape_slot;

reg tape_rewind = 1'b0;
reg tape_rew_r  = 1'b0;
always @(posedge clk_sys) begin
	tape_rew_r  <= status[16];
	tape_rewind <= (status[16] != tape_rew_r);
end

wire [63:0] kbd_matrix;

system80_kbd kbd
(
	.clk_sys (clk_sys),
	.reset   (reset),
	.symbolic (~status[15]),
	.ps2_key (ps2_key),
	.matrix  (kbd_matrix)
);

wire       ce_pix;
wire [15:0] audio;
wire [7:0] vid_r, vid_g, vid_b;
wire       hs, vs, hb, vb;

system80_core core
(
	.clk_sys        (clk_sys),
	.reset          (reset),
	.sim_fast       (1'b0),

	.ce_pix         (ce_pix),
	.video_r        (vid_r),
	.video_g        (vid_g),
	.video_b        (vid_b),
	.video_hs       (hs),
	.video_vs       (vs),
	.video_hb       (hb),
	.video_vb       (vb),
	.video_50hz     (1'b1),
	.phosphor       (status[11:10]),
	.snow_en        (~status[9]),

	.kbd_matrix     (kbd_matrix),

	.cas_motor      (),
	.cas_out        (),
	.audio          (audio),
	.cas_deck       (),
	.cas_in         (1'b0),

	.tape_wr        (tape_wr),
	.tape_rewind    (tape_rewind),
	.tape_playing   (),
	.tape_pos       (),
	.tape_len       (),

	.disk_present   (disk_present),
	.disk_wp        (disk_wp),
	.img_mounted    (img_mounted),
	.img_size       (img_size[31:0]),
	.disk_busy      (disk_busy),
	.disk_prepare   (disk_prepare),

	.sd_lba         (fdc_lba),
	.sd_rd          (sd_rd),
	.sd_wr          (sd_wr),
	.sd_ack         (sd_ack),
	.sd_buff_addr   (sd_buff_addr),
	.sd_buff_dout   (sd_buff_dout),
	.sd_buff_din    (fdc_buff_din),
	.sd_buff_wr     (sd_buff_wr),

	.ioctl_download (ioctl_download),
	.ioctl_wr       (rom_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_data     (ioctl_dout),

	.debug_pc       (),
	.debug_opcode   (),
	.debug_fetch    (),
	.debug_addr     (),
	.debug_din      (),
	.debug_dout     (),
	.debug_mreq     (),
	.debug_iorq     (),
	.debug_rd       (),
	.debug_wr       ()
);

assign CLK_VIDEO = clk_sys;

wire [2:0] fx = {1'b0, status[3:2]};
assign VGA_SL = fx[1:0];

wire vga_de;

video_mixer #(.LINE_LENGTH(800), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),

	.scandoubler(forced_scandoubler || |status[3:2]),
	.hq2x(status[3:2] == 2'b01),

	.gamma_bus(gamma_bus),

	.R(vid_r),
	.G(vid_g),
	.B(vid_b),

	.HSync(hs),
	.VSync(vs),
	.HBlank(hb),
	.VBlank(vb),

	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de)
);

wire [1:0] ar = status[122:121];

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

	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(0),
	.SCALE(status[14:12])
);

endmodule
