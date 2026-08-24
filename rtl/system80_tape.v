module system80_tape (
	input         clk_sys,
	input         reset,

	input         ce_cpu,

	input         tape_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_data,

	input         motor,

	input         rewind,

	output reg    pulse,

	output        playing,
	output [16:0] pos,
	output [16:0] len
);

localparam CAS_BYTES = 65536;

reg [7:0] cas [0:CAS_BYTES-1] /* verilator public_flat_rw */;
reg [16:0] cas_len;

wire load_wr = tape_wr & (ioctl_addr < CAS_BYTES);

reg [15:0] rd_addr;
reg [7:0]  rd_data;

always @(posedge clk_sys) begin
	if (load_wr) begin
		cas[ioctl_addr[15:0]] <= ioctl_data;
		cas_len <= ioctl_addr[16:0] + 17'd1;
	end
	rd_data <= cas[rd_addr];
end

localparam HALF_MS = 1774;

reg [11:0] tick;
reg        half;
reg [16:0] byte_idx;
reg [2:0]  bit_idx;
reg [7:0]  shifter;
reg        running;

wire       loaded = (cas_len != 0);

reg        sync_done;
reg        pausing;

assign playing = running;
assign pos     = byte_idx;
assign len     = cas_len;

wire at_end = (byte_idx >= cas_len);

reg rewind_d;
always @(posedge clk_sys) rewind_d <= rewind;
wire rewind_stb = rewind & ~rewind_d;

always @* rd_addr = running ? (byte_idx[15:0] + 16'd1) : byte_idx[15:0];

always @(posedge clk_sys) begin
	pulse <= 1'b0;

	if (reset) begin
		running <= 1'b0; byte_idx <= 0; bit_idx <= 3'd7;
		tick <= 0; half <= 1'b0;
		sync_done <= 1'b0; pausing <= 1'b0;
	end
	else if (load_wr || rewind_stb) begin
		running <= 1'b0; byte_idx <= 0; bit_idx <= 3'd7;
		tick <= 0; half <= 1'b0;
		sync_done <= 1'b0; pausing <= 1'b0;
	end
	else if (!motor || at_end) begin
		running <= 1'b0;
	end
	else if (loaded) begin
		if (!running) begin
			running <= 1'b1;
			shifter <= rd_data;
			tick    <= 0;
			half    <= 1'b0;
			pulse   <= 1'b1;
		end
		else if (ce_cpu) begin
			if (tick == HALF_MS[11:0] - 12'd1) begin
				tick <= 0;
				if (pausing) begin
					pausing <= 1'b0;
					half    <= 1'b0;
					pulse   <= 1'b1;
				end
				else if (!half) begin
					half  <= 1'b1;
					pulse <= shifter[bit_idx];
				end
				else begin
					if (bit_idx == 3'd0) begin
						bit_idx  <= 3'd7;
						byte_idx <= byte_idx + 17'd1;
						shifter  <= rd_data;
						if (!sync_done && shifter == 8'hA5) begin
							sync_done <= 1'b1;
							pausing   <= 1'b1;
							pulse     <= 1'b0;
						end
						else begin
							half  <= 1'b0;
							pulse <= 1'b1;
						end
					end
					else begin
						bit_idx <= bit_idx - 3'd1;
						half    <= 1'b0;
						pulse   <= 1'b1;
					end
				end
			end
			else begin
				tick <= tick + 12'd1;
			end
		end
	end
end

endmodule
