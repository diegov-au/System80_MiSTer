module system80_kbd
(
	input         clk_sys,
	input         reset,

	input         symbolic,

	input  [10:0] ps2_key,

	output [63:0] matrix
);

reg        ps2_prev;
wire       ps2_stb  = ps2_key[10] ^ ps2_prev;
wire       pressed  = ps2_key[9];
wire       extended = ps2_key[8];
wire [7:0] code     = ps2_key[7:0];

always @(posedge clk_sys) ps2_prev <= ps2_key[10];

reg [5:0] idx;
reg       idx_valid;

always @* begin
	idx_valid = 1'b1;
	idx       = 6'd0;
	if (extended) begin
		case (code)
			8'h75: idx = 6'd51;
			8'h72: idx = 6'd52;
			8'h6B: idx = 6'd53;
			8'h74: idx = 6'd54;
			8'h6C: idx = 6'd49;
			default: idx_valid = 1'b0;
		endcase
	end
	else begin
		case (code)
			8'h0E: idx = 6'd0;
			8'h1C: idx = 6'd1;
			8'h32: idx = 6'd2;
			8'h21: idx = 6'd3;
			8'h23: idx = 6'd4;
			8'h24: idx = 6'd5;
			8'h2B: idx = 6'd6;
			8'h34: idx = 6'd7;
			8'h33: idx = 6'd8;
			8'h43: idx = 6'd9;
			8'h3B: idx = 6'd10;
			8'h42: idx = 6'd11;
			8'h4B: idx = 6'd12;
			8'h3A: idx = 6'd13;
			8'h31: idx = 6'd14;
			8'h44: idx = 6'd15;
			8'h4D: idx = 6'd16;
			8'h15: idx = 6'd17;
			8'h2D: idx = 6'd18;
			8'h1B: idx = 6'd19;
			8'h2C: idx = 6'd20;
			8'h3C: idx = 6'd21;
			8'h2A: idx = 6'd22;
			8'h1D: idx = 6'd23;
			8'h22: idx = 6'd24;
			8'h35: idx = 6'd25;
			8'h1A: idx = 6'd26;
			8'h45: idx = 6'd32;
			8'h16: idx = 6'd33;
			8'h1E: idx = 6'd34;
			8'h26: idx = 6'd35;
			8'h25: idx = 6'd36;
			8'h2E: idx = 6'd37;
			8'h36: idx = 6'd38;
			8'h3D: idx = 6'd39;
			8'h3E: idx = 6'd40;
			8'h46: idx = 6'd41;
			8'h52: idx = 6'd42;
			8'h4C: idx = 6'd43;
			8'h41: idx = 6'd44;
			8'h4E: idx = 6'd45;
			8'h49: idx = 6'd46;
			8'h4A: idx = 6'd47;
			8'h5A: idx = 6'd48;
			8'h76: idx = 6'd50;
			8'h66: idx = 6'd53;
			8'h29: idx = 6'd55;
			default: idx_valid = 1'b0;
		endcase
	end
end

localparam SYM_NONE = 5'd31;

reg [4:0] sym_id;

always @* begin
	if (extended) sym_id = SYM_NONE;
	else case (code)
		8'h0E: sym_id = 5'd0;
		8'h16: sym_id = 5'd1;
		8'h1E: sym_id = 5'd2;
		8'h26: sym_id = 5'd3;
		8'h25: sym_id = 5'd4;
		8'h2E: sym_id = 5'd5;
		8'h36: sym_id = 5'd6;
		8'h3D: sym_id = 5'd7;
		8'h3E: sym_id = 5'd8;
		8'h46: sym_id = 5'd9;
		8'h45: sym_id = 5'd10;
		8'h4E: sym_id = 5'd11;
		8'h55: sym_id = 5'd12;
		8'h54: sym_id = 5'd13;
		8'h5B: sym_id = 5'd14;
		8'h5D: sym_id = 5'd15;
		8'h4C: sym_id = 5'd16;
		8'h52: sym_id = 5'd17;
		8'h41: sym_id = 5'd18;
		8'h49: sym_id = 5'd19;
		8'h4A: sym_id = 5'd20;
		default: sym_id = SYM_NONE;
	endcase
end

reg shift_l, shift_r;
wire shift_real = shift_l | shift_r;

always @(posedge clk_sys) begin
	if (reset) {shift_l, shift_r} <= 2'b00;
	else if (ps2_stb && !extended) begin
		if (code == 8'h12) shift_l <= pressed;
		if (code == 8'h59) shift_r <= pressed;
	end
end

reg [5:0] tgt_idx;
reg       tgt_shift;
reg       tgt_valid;

always @* begin
	tgt_idx   = 6'd0;
	tgt_shift = 1'b0;
	tgt_valid = 1'b1;

	case ({shift_real, sym_id})
		{1'b0, 5'd0 }: tgt_valid = 1'b0;
		{1'b0, 5'd1 }: tgt_idx = 6'd33;
		{1'b0, 5'd2 }: tgt_idx = 6'd34;
		{1'b0, 5'd3 }: tgt_idx = 6'd35;
		{1'b0, 5'd4 }: tgt_idx = 6'd36;
		{1'b0, 5'd5 }: tgt_idx = 6'd37;
		{1'b0, 5'd6 }: tgt_idx = 6'd38;
		{1'b0, 5'd7 }: tgt_idx = 6'd39;
		{1'b0, 5'd8 }: tgt_idx = 6'd40;
		{1'b0, 5'd9 }: tgt_idx = 6'd41;
		{1'b0, 5'd10}: tgt_idx = 6'd32;
		{1'b0, 5'd11}: tgt_idx = 6'd45;
		{1'b0, 5'd12}: begin tgt_idx = 6'd45; tgt_shift = 1'b1; end
		{1'b0, 5'd13}: tgt_valid = 1'b0;
		{1'b0, 5'd14}: tgt_valid = 1'b0;
		{1'b0, 5'd15}: tgt_valid = 1'b0;
		{1'b0, 5'd16}: tgt_idx = 6'd43;
		{1'b0, 5'd17}: begin tgt_idx = 6'd39; tgt_shift = 1'b1; end
		{1'b0, 5'd18}: tgt_idx = 6'd44;
		{1'b0, 5'd19}: tgt_idx = 6'd46;
		{1'b0, 5'd20}: tgt_idx = 6'd47;

		{1'b1, 5'd0 }: tgt_valid = 1'b0;
		{1'b1, 5'd1 }: begin tgt_idx = 6'd33; tgt_shift = 1'b1; end
		{1'b1, 5'd2 }: tgt_idx = 6'd0;
		{1'b1, 5'd3 }: begin tgt_idx = 6'd35; tgt_shift = 1'b1; end
		{1'b1, 5'd4 }: begin tgt_idx = 6'd36; tgt_shift = 1'b1; end
		{1'b1, 5'd5 }: begin tgt_idx = 6'd37; tgt_shift = 1'b1; end
		{1'b1, 5'd6 }: tgt_valid = 1'b0;
		{1'b1, 5'd7 }: begin tgt_idx = 6'd38; tgt_shift = 1'b1; end
		{1'b1, 5'd8 }: begin tgt_idx = 6'd42; tgt_shift = 1'b1; end
		{1'b1, 5'd9 }: begin tgt_idx = 6'd40; tgt_shift = 1'b1; end
		{1'b1, 5'd10}: begin tgt_idx = 6'd41; tgt_shift = 1'b1; end
		{1'b1, 5'd11}: tgt_valid = 1'b0;
		{1'b1, 5'd12}: begin tgt_idx = 6'd43; tgt_shift = 1'b1; end
		{1'b1, 5'd13}: tgt_valid = 1'b0;
		{1'b1, 5'd14}: tgt_valid = 1'b0;
		{1'b1, 5'd15}: tgt_valid = 1'b0;
		{1'b1, 5'd16}: tgt_idx = 6'd42;
		{1'b1, 5'd17}: begin tgt_idx = 6'd34; tgt_shift = 1'b1; end
		{1'b1, 5'd18}: begin tgt_idx = 6'd44; tgt_shift = 1'b1; end
		{1'b1, 5'd19}: begin tgt_idx = 6'd46; tgt_shift = 1'b1; end
		{1'b1, 5'd20}: begin tgt_idx = 6'd47; tgt_shift = 1'b1; end

		default: tgt_valid = 1'b0;
	endcase
end

wire remap = symbolic & (sym_id != SYM_NONE);

reg [63:0] keys;

reg [20:0] sym_down;
reg [20:0] sym_wants_shift;
reg  [5:0] sym_tgt [0:20];

integer i;

always @(posedge clk_sys) begin
	if (reset) begin
		keys            <= 64'd0;
		sym_down        <= 21'd0;
		sym_wants_shift <= 21'd0;
		for (i = 0; i < 21; i = i + 1) sym_tgt[i] <= 6'd0;
	end
	else if (ps2_stb) begin
		if (remap) begin
			if (pressed) begin
				if (tgt_valid) begin
					keys[tgt_idx]           <= 1'b1;
					sym_tgt[sym_id[4:0]]    <= tgt_idx;
					sym_wants_shift[sym_id] <= tgt_shift;
					sym_down[sym_id]        <= 1'b1;
				end
			end
			else if (sym_down[sym_id]) begin
				keys[sym_tgt[sym_id[4:0]]] <= 1'b0;
				sym_down[sym_id]           <= 1'b0;
			end
		end
		else if (idx_valid) keys[idx] <= pressed;
	end
end

wire sym_active = |sym_down;
wire sym_shift  = |(sym_down & sym_wants_shift);
wire shift_out  = (symbolic & sym_active) ? sym_shift : shift_real;

assign matrix = {keys[63:57], shift_out, keys[55:0]};

endmodule
