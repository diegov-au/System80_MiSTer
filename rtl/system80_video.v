module system80_video
(
	input         clk_sys,
	input         ce_pix,
	input         reset,
	input         video_50hz,

	input   [1:0] phosphor,

	input         snow_en,
	input         vid_contend,

	output [9:0]  vid_addr,
	input  [7:0]  vid_data,
	output [10:0] chr_addr,
	input  [7:0]  chr_data,

	output reg [7:0] video_r,
	output reg [7:0] video_g,
	output reg [7:0] video_b,
	output reg       video_hs,
	output reg       video_vs,
	output reg       video_hb,
	output reg       video_vb
);

localparam H_CHARS   = 112;
localparam H_DISP    = 64;
localparam DOTS      = 6;
localparam H_SYNC_ST = 72;
localparam H_SYNC_EN = 80;

localparam V_LINES   = 12;
localparam V_ROWS    = 16;
localparam V_DISP    = 192;
localparam V_TOT_50  = 312;
localparam V_TOT_60  = 264;
localparam V_SYNC_50 = 250;
localparam V_SYNC_60 = 226;
localparam V_SYNC_W  = 3;

localparam GLYPH_ROWS = 9;

localparam GLYPH_TOP = 0;

wire [8:0] v_total = video_50hz ? V_TOT_50[8:0]  : V_TOT_60[8:0];
wire [8:0] v_sync  = video_50hz ? V_SYNC_50[8:0] : V_SYNC_60[8:0];

reg [2:0] dot;
reg [6:0] hchar;
reg [3:0] line;
reg [3:0] row;
reg [8:0] vline;

wire last_dot   = (dot   == DOTS[2:0]    - 3'd1);
wire last_hchar = (hchar == H_CHARS[6:0] - 7'd1);
wire last_line  = (line  == V_LINES[3:0] - 4'd1);
wire last_vline = (vline == v_total      - 9'd1);

always @(posedge clk_sys) begin
	if (reset) begin
		dot <= 0; hchar <= 0; line <= 0; row <= 0; vline <= 0;
	end
	else if (ce_pix) begin
		dot <= last_dot ? 3'd0 : dot + 3'd1;
		if (last_dot) begin
			hchar <= last_hchar ? 7'd0 : hchar + 7'd1;
			if (last_hchar) begin
				if (last_vline) begin
					vline <= 9'd0;  line <= 4'd0;  row <= 4'd0;
				end
				else begin
					vline <= vline + 9'd1;
					line  <= last_line ? 4'd0 : line + 4'd1;
					if (last_line) row <= row + 4'd1;
				end
			end
		end
	end
end

wire        n_wrap  = last_hchar;
wire        n_frame = n_wrap && last_vline;
wire [6:0]  n_hchar = n_wrap ? 7'd0 : hchar + 7'd1;
wire [3:0]  n_line  = n_frame ? 4'd0
                    : n_wrap  ? (last_line ? 4'd0 : line + 4'd1) : line;
wire [3:0]  n_row   = n_frame ? 4'd0
                    : (n_wrap && last_line) ? row + 4'd1 : row;

assign vid_addr = {n_row, n_hchar[5:0]};

wire [3:0] n_glyph_row = n_line - GLYPH_TOP[3:0];
wire       n_glyph_on  = (n_line >= GLYPH_TOP[3:0]) &&
                         (n_line <  GLYPH_TOP[3:0] + GLYPH_ROWS[3:0]);

wire chr_a6 = vid_data[6] | ~vid_data[5];

assign chr_addr = {chr_a6, vid_data[5:0], n_glyph_row};

reg [7:0] vbyte;
reg [5:0] shifter;

always @(posedge clk_sys) begin
	if (ce_pix) begin
		if (last_dot) begin
			vbyte    <= vid_data;
			shifter <= (!vid_data[7] && n_glyph_on) ? {chr_data[7:3], 1'b0} : 6'd0;
		end
		else begin
			shifter <= {shifter[4:0], 1'b0};
		end
	end
end

wire char_pixel = shifter[5];

wire       left_half = (dot < 3'd3);
reg        gfx_pixel;
always @* begin
	case ({line[3:2], left_half})
		3'b00_1: gfx_pixel = vbyte[0];
		3'b00_0: gfx_pixel = vbyte[1];
		3'b01_1: gfx_pixel = vbyte[2];
		3'b01_0: gfx_pixel = vbyte[3];
		3'b10_1: gfx_pixel = vbyte[4];
		3'b10_0: gfx_pixel = vbyte[5];
		default: gfx_pixel = 1'b0;
	endcase
end

reg snow_hold;
always @(posedge clk_sys) begin
	if (reset)                     snow_hold <= 1'b0;
	else if (vid_contend)          snow_hold <= 1'b1;
	else if (ce_pix && last_dot)   snow_hold <= 1'b0;
end

wire snow_blank = snow_en & snow_hold;

wire hblank = (hchar >= H_DISP[6:0]);
wire vblank = (vline >= V_DISP[8:0]);
wire hsync  = (hchar >= H_SYNC_ST[6:0]) && (hchar < H_SYNC_EN[6:0]);
wire vsync  = (vline >= v_sync) && (vline < v_sync + V_SYNC_W[8:0]);

wire pixel = vbyte[7] ? gfx_pixel : char_pixel;
wire lit   = pixel & ~hblank & ~vblank & ~snow_blank;

localparam [23:0] PH_AMBER = 24'hF7AA00;
localparam [23:0] PH_GREEN = 24'h00FF00;
localparam [23:0] PH_WHITE = 24'hFFFFFF;

reg [23:0] fg;
always @* begin
	case (phosphor)
		2'd0:    fg = PH_GREEN;
		2'd1:    fg = PH_AMBER;
		default: fg = PH_WHITE;
	endcase
end

always @(posedge clk_sys) if (ce_pix) begin
	video_r  <= lit ? fg[23:16] : 8'h00;
	video_g  <= lit ? fg[15:8]  : 8'h00;
	video_b  <= lit ? fg[7:0]   : 8'h00;
	video_hb <= hblank;
	video_vb <= vblank;
	video_hs <= hsync;
	video_vs <= vsync;
end

wire _unused = &{1'b0, V_ROWS[4:0], 1'b0};

endmodule
