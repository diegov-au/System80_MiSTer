// Vendored from MiSTer-devel/Specialist_MiSTer/rtl/wd1793.sv (GPL-2), reworked
// for the FD1771 in the System 80's X-4010 expansion unit.
//
// The 1771 and the 179x are the same family and the register model is
// identical - four registers at A1:A0, the same command top-nibbles, the same
// Type I status bits. What differs, and what changed here:
//
//   FM ONLY.       The 1771 has no MFM. Nothing in this file ever selected a
//                  density, so this costs nothing but is why S5's DMK support
//                  will only ever see single-density tracks.
//   NO SIDE.       Drawing 4.19's floppy bus carries DS1-DS4, MOTOR ON, STEP,
//                  DIRECTION, WRITE GATE, WRITE DATA, READ DATA, WRITE PROTECT,
//                  INDEX and TRACK ZERO - and no side select. The caller ties
//                  `side` low; `layout` is 1 (linear).
//   JV1 GEOMETRY.  size_code 5, added here: 10 sectors x 256 bytes per track,
//                  single sided, and SECTOR IDS BASED AT 0. Every other format
//                  this file knows numbers sectors from 1. The System 80 boot
//                  ROM proves the base: $06B6 does XOR A / LD ($37EE),A and
//                  then reads, so sector 0 is a real sector.
//   RECORD TYPE.   On a 179x, Type II status bit 5 is Write Fault. On the 1771
//                  it doubles as Record Type on a READ - set when the sector
//                  carried a deleted data address mark. TRSDOS and NEWDOS mark
//                  the directory track that way, and JV1 stores no marks at
//                  all, so it is synthesised from the directory track number.
//                  See `dir_track` and its port comment.
//
//   DMK.           S5. The vendored file's .dsk/EDSK scanner has been replaced
//                  by a DMK one, keeping the sector TABLE and everything
//                  downstream of it - `edsk[]`, STATE_SEARCH_1, READ ADDRESS,
//                  `buff_a = edsk_offset` - because none of that was ever
//                  CPC-specific: it matches on (track, side, sector) and takes
//                  an absolute byte offset, which is exactly what a DMK lookup
//                  produces. Only the PARSER is new. The `edsk_*` names survive
//                  as the name of the generic variable-geometry sector table;
//                  renaming them would have buried the real change in noise.
//                  The two CPC signature branches are gone - no CPC disc will
//                  ever be mounted on this machine and keeping them was a live
//                  misdetection risk.
//
// The other local change, inherited: fd1771_dpram reimplemented as inferred RAM
// so Verilator can simulate it - see the note at the bottom of this file.
`default_nettype none

// ====================================================================
//
//  WD1793, WD1772, WD1773 replica (with write capability)
//
//  Copyright (C) 2007,2008 Viacheslav Slavinsky
//  Copyright (C) 2016 Sorgelig
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

module fd1771 #(parameter RWMODE=0, DMK=1)
(
	input        clk_sys,
	input        ce,
	input        reset,
	input        io_en,
	input        rd,
	input        wr,
	input  [1:0] addr,
	input  [7:0] din,
	output [7:0] dout,
	output       drq,
	output       intrq,
	output       busy,

	input        wp,

	input  [2:0] size_code,
	input        layout,
	input        side,
	input        ready,

	input  [7:0] dir_track,

	input        drive,

	input  [1:0] img_mounted,
	input [31:0] img_size,
	output       prepare,
	output       sd_drive,
	output[31:0] sd_lba,
	output reg   sd_rd,
	output reg   sd_wr,
	input        sd_ack,
	input  [8:0] sd_buff_addr,
	input  [7:0] sd_buff_dout,
	output [7:0] sd_buff_din,
	input        sd_buff_wr,

	input        input_active,
	input [19:0] input_addr,
	input  [7:0] input_data,
	input        input_wr,
	output[19:0] buff_addr,
	output       buff_read,
	input  [7:0] buff_din
);

assign dout      = q;
assign drq       = s_drq;
assign busy      = s_busy;
assign intrq     = s_intrq;
assign sd_lba    = scan_active ? scan_addr[19:9] : buff_a[19:9] + sd_block;
assign prepare   = DMK ? scan_active : |img_mounted;
assign sd_drive  = scan_active ? scan_drive : drive;
assign buff_addr = {buff_a[19:9], 9'd0} + byte_addr;
assign buff_read = ((addr == A_DATA) && buff_rd);

reg   [7:0] sectors_per_track, edsk_spt = 0;
reg         buff_wr;
reg   [7:0] spt_addr;
wire [10:0] sector_size = 11'd128 << wd_size_code;
reg  [10:0] byte_addr /* verilator public_flat_rd */;
reg  [19:0] buff_a;
reg   [1:0] wd_size_code;

wire  [7:0] buff_dout;
reg   [1:0] sd_block = 0;
reg         format;
generate
	if(RWMODE) begin
		fd1771_dpram sbuf
		(
			.clock(clk_sys),

			.address_a({sd_block, sd_buff_addr}),
			.data_a(sd_buff_dout),
			.wren_a(sd_buff_wr & sd_ack),
			.q_a(sd_buff_din),

			.address_b(scan_active ? {2'b00, scan_addr[8:0]} : byte_addr),
			.data_b(format ? 8'd0 : din),
			.wren_b(wre & buff_wr & (addr == A_DATA) & ~scan_active),
			.q_b(buff_dout)
		);
	end else begin
		assign buff_dout   = 0;
		assign sd_buff_din = 0;
	end
endgenerate

reg  [1:0]  var_size_d  = 0;
reg  [19:0] disk_size_d [0:1];
reg  [1:0]  layout_r_d  = 0;
reg         scan_drive  = 0;

initial begin
	disk_size_d[0] = 0; disk_size_d[1] = 0;
end

wire        var_size /* verilator public_flat_rd */ = var_size_d[drive];
wire [19:0] disk_size  = disk_size_d[drive];
wire        layout_r   = layout_r_d[drive];
wire [19:0] hs  = (layout_r & side) ? disk_size >> 1 : 20'd0;
wire  [7:0] dts = {disk_track[6:0], side} >> layout_r;

wire        ds80    = ~var_size & (disk_size == 20'd819200);

wire        jv1     = ~var_size & (size_code == 3'd5);
wire  [7:0] secbase = jv1                            ? 8'd0  :
                      (ds80 & (disk_track >= 8'd2))  ? 8'd21 : 8'd1;
wire  [7:0] sectop  = secbase + sectors_per_track - 8'd1;
always @* begin
	case({var_size,size_code})
				0: buff_a = hs + {{1'b0, dts, 4'b0000} + {dts, 3'b000} + {dts, 1'b0} + wdreg_sector - 1'd1,  7'd0};
				1: buff_a = hs + {{dts, 4'b0000}                                     + wdreg_sector - 1'd1,  8'd0};
				2: buff_a = hs + {{dts, 3'b000}  + dts                               + wdreg_sector - 1'd1,  9'd0};
				3: buff_a = hs + {{dts, 2'b00}   + dts                               + wdreg_sector - 1'd1, 10'd0};
				4: buff_a = hs + {{dts, 3'b000}  +{dts, 1'b0}                        + wdreg_sector - secbase,  9'd0};
				5: buff_a = {{1'b0, dts, 3'b000} + {3'b000, dts, 1'b0} + {4'd0, wdreg_sector}, 8'd0};
		default: buff_a = edsk_offset;
	endcase
	case({var_size,size_code})
				0: sectors_per_track = 26;
				1: sectors_per_track = 16;
				2: sectors_per_track = 9;
				3: sectors_per_track = 5;
				4: sectors_per_track = 10;
				5: sectors_per_track = 10;
		default: sectors_per_track = edsk_spt;
	endcase
	case({var_size,size_code})
				0: wd_size_code = 0;
				1: wd_size_code = 1;
				2: wd_size_code = 2;
				3: wd_size_code = 3;
				4: wd_size_code = 2;
				5: wd_size_code = 1;
		default: wd_size_code = edsk_sizecode;
	endcase
end

wire [12:0] rw_span  = {2'b0, sector_size} * {11'b0, rd_step};
wire [13:0] blk_span = {5'b0, buff_a[8:0]} + {1'b0, rw_span} - 14'd1;
wire  [1:0] blk_size = blk_span[10:9];

localparam A_COMMAND         = 0;
localparam A_STATUS          = 0;
localparam A_TRACK           = 1;
localparam A_SECTOR          = 2;
localparam A_DATA            = 3;

typedef enum
{
	STATE_IDLE,

	STATE_SEARCH,
	STATE_SEARCH_1,

	STATE_WAIT_READ,
	STATE_WAIT_READ_1,
	STATE_WAIT_READ_2,

	STATE_READ,
	STATE_READ_1,
	STATE_READ_2,
	STATE_READ_3,

	STATE_WAIT_WRITE,
	STATE_WAIT_WRITE_1,
	STATE_WAIT_WRITE_2,

	STATE_WRITE,
	STATE_WRITE_1,
	STATE_WRITE_2,

	STATE_ABORT,
	STATE_WAIT,
	STATE_WAIT_2,
	STATE_ENDCOMMAND
} io_state_t;

wire        s_readonly = (wp | !RWMODE | var_size);
reg			s_crcerr;
reg			s_headloaded, s_seekerr, s_index;
reg			s_lostdata, s_wrfault;

reg  [1:0]  s_rectype;
localparam [1:0] DIR_DAM = 2'b01;

reg         s_wrcmd;

reg 			cmd_mode;

reg	[1:0]	s_drq_busy;
wire			s_drq  = s_drq_busy[1];
wire			s_busy = s_drq_busy[0];
reg         s_intrq;

reg   [7:0] wdreg_track;
reg   [7:0] wdreg_sector;
reg   [7:0] wdreg_data;
wire  [7:0] wdreg_status = cmd_mode == 0 ?
	{~ready, s_readonly, s_headloaded, s_seekerr | ~ready, s_crcerr, !disk_track, s_index, s_busy}:
	{~ready, (s_readonly & s_wrcmd) | s_rectype[1], s_wrfault | s_rectype[0], s_seekerr | ~ready, s_crcerr, s_lostdata,  s_drq,   s_busy};

reg   [7:0] read_addr[6];
reg   [7:0] q;
always @* begin
	case (addr)
		A_STATUS: q = wdreg_status;
		A_TRACK:  q = wdreg_track;
		A_SECTOR: q = wdreg_sector;
		A_DATA:   q = (state == STATE_IDLE) ? wdreg_data : buff_rd ? (RWMODE ? buff_dout : buff_din) : read_addr[byte_addr[2:0]];
	endcase
end

reg         buff_rd;
reg         step_direction;

reg   [7:0] disk_track;
reg  [10:0]	data_length;
io_state_t  state = STATE_IDLE;

wire  [7:0] next_track  = (din[6] ? din[5] : step_direction) ? disk_track - 1'd1 : disk_track + 1'd1;
wire [10:0]	next_length = data_length - 1'b1;

reg         watchdog_set;
wire        watchdog_bark = (wd_timer == 0);
reg  [15:0] wd_timer;
always @(posedge clk_sys) begin
	if(ce) begin
		if(watchdog_set) wd_timer <= 4096;
			else if(wd_timer != 0) wd_timer <= wd_timer - 1'b1;
	end
end

always @(posedge clk_sys) begin
	integer cnt;
	if(ce) begin
		if(ready) begin
			if(cnt) cnt <= cnt - 1;
				else cnt <= 35000;
		end else cnt <= 0;
		s_index <= (cnt < 100);
	end
end

wire        rde = rd & io_en;
wire        wre = wr & io_en;
always @(posedge clk_sys) begin
	reg old_wr, old_rd;

	reg [2:0] cur_addr;
	reg       read_data;
	reg       write_data;
	reg       rw_type;
	integer   wait_time;
	reg [3:0] read_timer;
	reg [9:0] seektimer;
	reg [7:0] ra_sector;
	reg [7:0] ra_now;
	reg       multisector;
	reg       write;
	reg [5:0] ack;
	reg       sd_busy;
	reg [1:0] old_mounted;
	reg [3:0] scan_state;
	reg [1:0] scan_cnt;
	reg [1:0] blk_max;

	if(RWMODE) begin
		old_mounted <= img_mounted;
		if(|(old_mounted & ~img_mounted)) begin
			if(DMK) begin
				scan_q[old_mounted[1]] <= 1'b1;
			end
			disk_size_d[old_mounted[1]] <= img_size[19:0];
			layout_r_d [old_mounted[1]] <= layout;
		end
	end else begin
		scan_active <= input_active;
		scan_addr   <= input_addr;
		scan_wr     <= input_wr;
		if(scan_active & ~input_active) begin
			scan_drive        <= 1'b0;
			disk_size_d[1'b0] <= input_addr + 1'd1;
			layout_r_d [1'b0] <= layout;
		end
	end

	if(reset & ~scan_active & ~|scan_q) begin
		read_data <= 0;
		write_data <= 0;
		multisector <= 0;
		step_direction <= 0;
		disk_track <= 0;
		wdreg_track <= 0;
		wdreg_sector <= 0;
		wdreg_data <= 0;
		data_length <= 0;
		byte_addr <=0;
		buff_rd <= 0;
		if(RWMODE) buff_wr <= 0;
		state <= STATE_IDLE;
		cmd_mode <= 0;
		{s_headloaded, s_seekerr, s_crcerr, s_intrq} <= 0;
		{s_wrfault, s_lostdata, s_rectype, s_wrcmd} <= 0;
		s_drq_busy <= 0;
		watchdog_set <= 0;
		seektimer <= 'h3FF;
		{ack, sd_wr, sd_rd, sd_busy} <= 0;
		ra_sector <= 1;
	end else if(ce) begin

		ack <= {ack[4:0], sd_ack};
		if(ack[5:4] == 'b01) {sd_rd,sd_wr} <= 0;
		if(ack[5:4] == 'b10) sd_busy <= 0;

		if(DMK & RWMODE & |scan_q & ~scan_active & (state == STATE_IDLE)) begin
			scan_drive   <= ~scan_q[0];
			scan_q[~scan_q[0]] <= 1'b0;
			scan_active  <= 1;
			scan_addr    <= 0;
			scan_state   <= 0;
			scan_wr      <= 0;
			sd_block     <= 0;
		end

		if(RWMODE & scan_active) begin
			if(scan_addr >= disk_size_d[scan_drive]) scan_active <= 0;
			else if(scan_jump_req != scan_jump_ack) begin
				scan_jump_ack <= scan_jump_req;
				scan_addr     <= scan_jump_to;
				scan_state    <= 0;
				scan_wr       <= 0;
			end
			else begin
				case(scan_state)
					0:	begin
							sd_rd   <= 1;
							sd_busy <= 1;
							scan_wr <= 0;
							scan_state <= 1;
						end
					1: if(!sd_busy) begin
							scan_wr    <= 1;
							scan_cnt   <= 1;
							scan_state <= 2;
						end
					2: begin
							scan_cnt <= scan_cnt + 1'd1;
							if(!scan_cnt) begin
								scan_wr <= ~scan_wr;
								if(scan_wr) begin
									scan_addr <= scan_addr + 1'b1;
									if(&scan_addr[8:0]) begin
										scan_active <= var_size_d[scan_drive];
										scan_state  <= 0;
									end
								end
							end
						end
				endcase
			end
		end

		old_wr <=wre;
		old_rd <=rde;

		if((!old_rd && rde) || (!old_wr && wre)) cur_addr <= addr;

		if(old_rd && !rde && (cur_addr == A_STATUS)) s_intrq <= 0;

		if(old_rd && !rde && (cur_addr == A_DATA)) read_data <=1;

		if(old_wr && !wre && (cur_addr == A_DATA)) write_data <=1;

		case (state)
			/* Idle state or buffer to host transfer */
			STATE_IDLE:;

			STATE_SEARCH:
				begin
					if(!ready) begin
						s_seekerr <= 1;
						state <= STATE_ENDCOMMAND;
					end else begin
						seektimer <= seektimer - 1'b1;
						if(!seektimer) begin
							byte_addr <= 0;
							if(var_size) begin
								if(~format) edsk_addr <= edsk_start;
								spt_addr  <= (side ? spt_size>>1 : 8'd0) + disk_track;
								state     <= STATE_SEARCH_1;
							end else begin
								if(rw_type && ((wdreg_sector < secbase) || (wdreg_sector > sectop))) begin
									if(~format) s_seekerr <= 1;
									state <= STATE_ENDCOMMAND;
								end else begin
									state <= rw_type ? STATE_WAIT_READ : STATE_READ;
								end
							end
						end
					end
				end
			STATE_SEARCH_1:
				begin
					if(rw_type & (edsk_track == disk_track) &
									 (edsk_side == side) &
									 (format | (edsk_sector == wdreg_sector))) begin
						if(~write) s_rectype <= edsk_dam;
						state <= STATE_WAIT_READ;
					end
					else
					if(~rw_type & (edsk_track == disk_track) &
									  (edsk_side == side)) begin
						read_addr[0] <= edsk_trackf;
						read_addr[1] <= edsk_sidef;
						read_addr[2] <= edsk_sector;
						read_addr[3] <= edsk_sizecode;
						state        <= STATE_READ;
					end
					else
					if(edsk_next == edsk_start) begin
						if(~format) s_seekerr <= 1;
						state <= STATE_ENDCOMMAND;
					end
					else
					begin
						edsk_addr <= edsk_next;
					end
				end
			STATE_WAIT_READ:
				begin
					data_length <= sector_size;
					byte_addr   <= buff_a[8:0];
					blk_max     <= blk_size;
					sd_block    <= 0;
					state       <= RWMODE ? STATE_WAIT_READ_1 : write ? STATE_WRITE : STATE_READ;
				end
			STATE_WAIT_READ_1:
				begin
					sd_busy <= 1;
					sd_rd   <= 1;
					state   <= STATE_WAIT_READ_2;
				end
			STATE_WAIT_READ_2:
				begin
					if(!sd_busy) begin
						sd_block <= sd_block + 1'd1;
						state <= write ? STATE_WRITE : STATE_READ;
						if(sd_block < blk_max) state <= STATE_WAIT_READ_1;
					end
				end

			STATE_READ:
				begin
					watchdog_set <= 1;
					read_timer <= 15;
					state <= STATE_READ_1;
				end
			STATE_READ_1:
				begin
					read_timer <= read_timer - 1'b1;
					if(!read_timer) begin
						read_data <= 0;
						watchdog_set <= 0;
						s_lostdata <= 0;
						s_drq_busy <= 2'b11;
						state <= STATE_READ_2;
					end
				end
			STATE_READ_2:
				begin
					if(watchdog_bark | (read_data & s_drq)) begin
						s_drq_busy <= 2'b01;
						s_lostdata <= watchdog_bark;

						if(next_length == 0) begin
							if(multisector) begin
								wdreg_sector <= wdreg_sector + 1'b1;
								state <= STATE_SEARCH;
							end else begin
								state <= STATE_ENDCOMMAND;
							end
						end else begin
							byte_addr <= byte_addr + {9'd0, rd_step};
							data_length <= next_length;
							state <= STATE_READ;
						end
					end
				end

			STATE_WAIT_WRITE:
				begin
					if(!ready) begin
						s_wrfault <= 1;
						state <= STATE_ENDCOMMAND;
					end else begin
						sd_block <= 0;
						state <= STATE_WAIT_WRITE_1;
					end
				end
			STATE_WAIT_WRITE_1:
				begin
					sd_busy <= 1;
					sd_wr   <= 1;
					state   <= STATE_WAIT_WRITE_2;
				end
			STATE_WAIT_WRITE_2:
				begin
					if(!sd_busy) begin
						sd_block <= sd_block + 1'd1;
						if(sd_block < blk_max) state <= STATE_WAIT_WRITE_1;
						else begin
							if(format && var_size && !edsk_next) begin
								state <= STATE_ENDCOMMAND;
							end else if(multisector) begin
								edsk_addr <= edsk_next;
								wdreg_sector <= wdreg_sector + 1'b1;
								state <= STATE_SEARCH;
							end else begin
								state <= STATE_ENDCOMMAND;
							end
						end
					end
				end
			STATE_WRITE:
				begin
					watchdog_set <= 1;
					read_timer <= 15;
					state <= STATE_WRITE_1;
				end
			STATE_WRITE_1:
				begin
					read_timer <= read_timer - 1'b1;
					if(!read_timer) begin
						write_data <= 0;
						watchdog_set <= 0;
						s_lostdata <= 0;
						s_drq_busy <= 2'b11;
						state <= STATE_WRITE_2;
					end
				end
			STATE_WRITE_2:
				begin
					if(watchdog_bark | (write_data & s_drq)) begin
						s_drq_busy <= 2'b01;
						s_lostdata <= watchdog_bark;

						if(!next_length) state <= STATE_WAIT_WRITE;
						else begin
							byte_addr <= byte_addr + {9'd0, rd_step};
							data_length <= next_length;
							state <= STATE_WRITE;
						end
					end
				end

			STATE_ABORT:
				begin
					data_length <= 0;
					{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;
					state <= STATE_ENDCOMMAND;
				end

			STATE_WAIT:
				begin
					wait_time <= 4000;
					state <= STATE_WAIT_2;
				end
			STATE_WAIT_2:
				begin
					if(wait_time) wait_time <= wait_time - 1;
						else state <= STATE_ENDCOMMAND;
				end

			STATE_ENDCOMMAND:
				begin
					format  <= 0;
					buff_rd <= 0;
					if(RWMODE) buff_wr <=0;
					state <= STATE_IDLE;
					s_drq_busy <= 2'b00;
					seektimer <= 'h3FF;
					s_intrq <= 1;
				end
		endcase

		/* Register write operations */
		if (!old_wr & wre) begin
			case (addr)
				A_COMMAND:
					begin
						s_intrq <= 0;
						if((state == STATE_IDLE) | (din[7:4] == 'hD)) begin
							cmd_mode <= din[7];
							{s_rectype, s_wrcmd} <= 0;

							if(!din[7]) {s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

							case (din[7:4])
							'h0:
								begin
									s_headloaded <= din[3];
									wdreg_track <= 0;
									disk_track <= 0;

									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h1:
								begin
									disk_track <= wdreg_data;
									wdreg_track  <= wdreg_data;
									s_headloaded <= din[3];

									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h2,
							'h3,
							'h4,
							'h5,
							'h6,
							'h7:
								begin
									if (din[6] == 1) step_direction <= din[5];

									disk_track <= next_track;

									if (din[4]) wdreg_track <= next_track;

									s_headloaded <= din[3];

									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h8, 'h9,
							'hA, 'hB,
							'hF:
								begin

									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= din[5] ? 2'b10 : 2'b01;
									if(RWMODE) buff_wr <= din[5];

									s_rectype <= (jv1 & ~din[5] & (disk_track == dir_track)) ? DIR_DAM : 2'b00;
									s_wrcmd   <= din[5];

									if(din[6]) wdreg_sector <= 1;

									format      <= din[6];
									multisector <= din[4];
									rw_type     <= 1;
									write_data  <= 0;
									read_data   <= 0;
									edsk_start  <= 0;
									edsk_addr   <= 0;
									state       <= STATE_SEARCH;

									if(s_readonly & din[5]) begin
										s_wrfault <= 1;
										state <= STATE_WAIT;
									end
								end
							'hC:
								begin
									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= 0;
									if(RWMODE) buff_wr <=0;

									format      <= 0;
									multisector <= 0;
									rw_type     <= 0;
									read_data   <= 0;
									edsk_start  <= edsk_next;
									data_length <= 6;

									ra_now = (ra_sector < secbase || ra_sector > sectop)
									         ? secbase : ra_sector;

									read_addr[0] <= disk_track;
									read_addr[1] <= {7'b0, side};
									read_addr[2] <= ra_now;
									read_addr[3] <= wd_size_code;
									read_addr[4] <= 0;
									read_addr[5] <= 0;

									if(ra_now >= sectop) ra_sector <= secbase;
										else ra_sector <= ra_now + 1'd1;
									state <= STATE_SEARCH;
								end
							'hD:
								begin
									if(din[3:0] != 0)             cmd_mode <= 0;
									else if(state == STATE_IDLE)  cmd_mode <= 0;
									else                          cmd_mode <= cmd_mode;
									if(state != STATE_IDLE) state <= STATE_ABORT;
										else {s_wrfault,s_seekerr,s_crcerr,s_lostdata, s_drq_busy} <= 0;
								end
							'hE:
								begin
									{s_wrfault,s_crcerr,s_lostdata} <= 0;
									s_seekerr  <= 1;
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							endcase
						end
					end

				A_TRACK:  if (!s_busy) wdreg_track <= din;
				A_SECTOR: if (!s_busy) begin
								wdreg_sector <= din;
								if (din >= secbase && din <= sectop) ra_sector <= din;
							end
				A_DATA:   wdreg_data <= din;
			endcase
		end

	end
end

reg        scan_active /* verilator public_flat_rd */ = 0;
reg  [1:0] scan_q = 0;
reg [19:0] scan_addr /* verilator public_flat_rd */;
reg        scan_wr;

reg        scan_jump_req = 0;
reg        scan_jump_ack = 0;
reg [19:0] scan_jump_to;

reg  [1:0] edsk_sizecode = 0;
reg        edsk_side = 0;
reg  [6:0] edsk_track = 0;
reg  [7:0] edsk_sector = 0;
reg [19:0] edsk_offset /* verilator public_flat_rd */ = 0;
reg  [7:0] edsk_trackf = 0, edsk_sidef = 0;

reg  [1:0] edsk_dam = 0;

reg  [1:0] step_d [0:1];
initial begin
	step_d[0] = 2'd1; step_d[1] = 2'd1;
end
wire [1:0] rd_step /* verilator public_flat_rd */ = var_size ? step_d[drive] : 2'd1;

reg [10:0] edsk_addr /* verilator public_flat_rd */, edsk_start;

reg [10:0] edsk_size_d [0:1];
reg  [7:0] spt_size_d  [0:1];
initial begin
	edsk_size_d[0] = 0; edsk_size_d[1] = 0;
	spt_size_d [0] = 0; spt_size_d [1] = 0;
end

wire[10:0] edsk_size /* verilator public_flat_rd */ = edsk_size_d[drive];
wire[10:0] edsk_next = ((edsk_addr + 1'd1) >= edsk_size) ? 11'd0 : edsk_addr + 1'd1;

wire [7:0] spt_size /* verilator public_flat_rd */ = spt_size_d[drive];
reg [19:0] dbg_bytes /* verilator public_flat_rd */ = 0;
reg [15:0] dbg_tsize /* verilator public_flat_rd */ = 0;
reg  [9:0] dbg_hdrs  /* verilator public_flat_rd */ = 0;
reg [31:0] dbg_sum   /* verilator public_flat_rd */ = 0;
reg [19:0] dbg_off0  /* verilator public_flat_rd */ = 0;
reg [15:0] dbg_id0   /* verilator public_flat_rd */ = 0;

generate
	if(DMK) begin
		wire [7:0] scan_data = RWMODE ? buff_dout : input_data;
		reg [55:0] edsk[2*2048];
		reg  [7:0] spt[2*256];

		integer zi;
		initial begin
			for(zi = 0; zi < 2*2048; zi = zi + 1) edsk[zi] = 0;
			for(zi = 0; zi < 2*256;  zi = zi + 1) spt[zi]  = 0;
			for(zi = 0; zi < 64;     zi = zi + 1) idam[zi] = 0;
		end

		always @(posedge clk_sys) begin
			{edsk_track,edsk_side,edsk_trackf,edsk_sidef,edsk_sector,edsk_sizecode,edsk_dam,edsk_offset} <= edsk[{drive, edsk_addr}];
			edsk_spt <= spt[{drive, spt_addr}];
		end

		wire       var_size_s = var_size_d[scan_drive];
		wire [7:0] spt_size_s = spt_size_d[scan_drive];
		wire[10:0] edsk_size_s = edsk_size_d[scan_drive];

		localparam DS_WAIT = 2'd0;
		localparam DS_ID   = 2'd1;
		localparam DS_DAM  = 2'd2;

		reg  [7:0] dmk_ntrk;
		reg [15:0] dmk_tlen;
		reg        dmk_2side;
		reg  [1:0] dmk_step;
		reg        dmk_hdr_ok;

		reg [15:0] dmk_tpos;
		reg  [7:0] dmk_tidx;
		reg [19:0] dmk_tbase;

		reg [15:0] idam[0:63];
		reg [15:0] dmk_ent;
		reg [15:0] dmk_entn;
		reg  [7:0] dmk_lo;
		reg  [6:0] dmk_nidam;
		reg  [6:0] dmk_idx;
		reg        dmk_tabend;

		always @(posedge clk_sys) begin
			dmk_ent  <= idam[dmk_idx[5:0]];
			dmk_entn <= idam[dmk_idx[5:0] + 6'd1];
		end

		wire [13:0] dmk_target = dmk_ent[13:0];
		wire        dmk_mfm    = dmk_ent[15];
		wire        dmk_more   = (dmk_idx < dmk_nidam);

		wire        dmk_more_n  = ((dmk_idx + 7'd1) < dmk_nidam);
		wire [19:0] dmk_next_tr = dmk_tbase +
		                          (dmk_2side ? {3'd0, dmk_tlen, 1'b0} : {4'd0, dmk_tlen});
		wire [19:0] dmk_jump_at = dmk_more_n ? (dmk_tbase + {6'd0, dmk_entn[13:0]})
		                                     : dmk_next_tr;

		reg  [1:0] dmk_state;
		reg        dmk_half;
		reg  [3:0] dmk_k;
		reg  [5:0] dmk_gap;
		reg  [7:0] dmk_trackf, dmk_sidef, dmk_sector;
		reg  [1:0] dmk_sizec;

		wire [6:0] dmk_ptrk = dmk_2side ? dmk_tidx[7:1] : dmk_tidx[6:0];
		wire       dmk_pside= dmk_2side ? dmk_tidx[0]   : 1'b0;

		wire [23:0] dmk_trkbytes = dmk_ntrk * dmk_tlen;
		wire [24:0] dmk_expect   = dmk_2side ? {dmk_trkbytes, 1'b0} : {1'b0, dmk_trkbytes};
		wire        dmk_size_ok  = ((dmk_expect + 25'd16) == {5'd0, disk_size_d[scan_drive]})
		                         & (dmk_ntrk  != 8'd0)
		                         & (dmk_tlen  >  16'd128)
		                         & (dmk_tlen  <= 16'h2940);

		always @(posedge clk_sys) begin
			reg old_active, old_wr;
			reg jumped;

			old_active <= scan_active;
			if(scan_active & ~old_active) begin
				edsk_size_d[scan_drive] <= 0;
				spt_size_d [scan_drive] <= 0;
				var_size_d [scan_drive] <= 1;
				step_d     [scan_drive] <= 2'd1;
				dmk_hdr_ok <= 1;
				dmk_ntrk   <= 0;
				dmk_tlen   <= 0;
				dmk_2side  <= 0;
				dmk_step   <= 2'd2;
				dmk_tpos   <= 0;
				dmk_tbase  <= 20'd16;
				dmk_tidx   <= 0;
				dmk_nidam  <= 0;
				dmk_idx    <= 0;
				dmk_tabend <= 0;
				dmk_state  <= DS_WAIT;
				dmk_half   <= 0;
				dbg_bytes  <= 0;
				dbg_sum    <= 0;
				dbg_hdrs   <= 0;
				dbg_tsize  <= 0;
			end

			old_wr <= scan_wr;
			if(scan_wr & ~old_wr & scan_active) begin
				dbg_bytes <= dbg_bytes + 1'd1;
				dbg_sum   <= dbg_sum + scan_data;
				jumped     = 1'b0;

				if(scan_addr < 20'd16) begin
					case(scan_addr[3:0])
						 1: dmk_ntrk      <= scan_data;
						 2: dmk_tlen[7:0] <= scan_data;
						 3: begin
								dmk_tlen[15:8] <= scan_data;
								dbg_tsize      <= {scan_data, dmk_tlen[7:0]};
							end
						 4: begin
								dmk_2side <= ~scan_data[4];
								dmk_step  <= (scan_data[6] | scan_data[7]) ? 2'd1 : 2'd2;
							end
						5,6,7,8,9,10,11,12,13,14,15:
							if(scan_data) dmk_hdr_ok <= 0;
						default: ;
					endcase
				end
				else begin
					if(scan_addr == 20'd16) begin
						var_size_d[scan_drive] <= dmk_hdr_ok & dmk_size_ok;
						step_d    [scan_drive] <= dmk_step;
						spt_size_d[scan_drive] <= dmk_2side ? {dmk_ntrk[6:0], 1'b0} : dmk_ntrk;
					end

					if(var_size_s) begin
						if(dmk_tpos < 16'd128) begin
							if(!dmk_tpos[0]) dmk_lo <= scan_data;
							else if(!dmk_tabend) begin
								if(!{scan_data, dmk_lo}) dmk_tabend <= 1;
								else begin
									idam[dmk_nidam[5:0]] <= {scan_data, dmk_lo};
									dmk_nidam <= dmk_nidam + 1'd1;
								end
							end
						end
						else begin
							if(dmk_tpos == 16'd128) begin
								spt[{scan_drive, (dmk_pside ? {1'b0, spt_size_s[7:1]} : 8'd0) + {1'b0, dmk_ptrk}}] <= {1'b0, dmk_nidam};
								dbg_hdrs <= dbg_hdrs + 1'd1;
							end

							case(dmk_state)
							DS_WAIT:
								if(dmk_more && (dmk_tpos[13:0] == dmk_target)) begin
									if(dmk_mfm || (scan_data != 8'hFE)) dmk_idx <= dmk_idx + 1'd1;
									else begin
										dmk_half  <= (dmk_step == 2'd2);
										dmk_k     <= 4'd1;
										dmk_state <= DS_ID;
									end
								end

							DS_ID:
								if(dmk_half) dmk_half <= 0;
								else begin
									dmk_half <= (dmk_step == 2'd2);
									dmk_k    <= dmk_k + 1'd1;
									case(dmk_k)
										1: dmk_trackf <= scan_data;
										2: dmk_sidef  <= scan_data;
										3: dmk_sector <= scan_data;
										4: dmk_sizec  <= scan_data[1:0];
										5: ;
										6: begin
												dmk_gap   <= 0;
												dmk_state <= DS_DAM;
											end
										default: ;
									endcase
								end

							DS_DAM:
								if(dmk_half) dmk_half <= 0;
								else begin
									dmk_half <= (dmk_step == 2'd2);
									if(scan_data[7:2] == 6'b111110) begin
										if(!edsk_size_s) begin
											dbg_off0 <= scan_addr + {18'd0, dmk_step};
											dbg_id0  <= {dmk_trackf, dmk_sector};
										end
										if(!((dmk_step == 2'd2) && (dmk_sizec == 2'd3))) begin
											edsk[{scan_drive, edsk_size_s}] <=
												{dmk_ptrk, dmk_pside,
												 dmk_trackf, dmk_sidef, dmk_sector,
												 dmk_sizec,
												 (scan_data == 8'hFB) ? 2'b00 : DIR_DAM,
												 scan_addr + {18'd0, dmk_step}};
											edsk_size_d[scan_drive] <= edsk_size_s + 1'd1;
										end
										jumped = 1'b1;
									end
									else begin
										dmk_gap <= dmk_gap + 1'd1;
										if(dmk_gap == 6'd40) jumped = 1'b1;
									end
								end

							default: dmk_state <= DS_WAIT;
							endcase
						end

						if((dmk_tpos == 16'd128) && !dmk_nidam) jumped = 1'b1;

						if(jumped) begin
							scan_jump_to  <= dmk_jump_at;
							scan_jump_req <= ~scan_jump_req;
							dmk_state     <= DS_WAIT;
							dmk_half      <= 0;

							if(dmk_more_n) begin
								dmk_tpos <= {2'd0, dmk_entn[13:0]};
								dmk_idx  <= dmk_idx + 1'd1;
							end
							else begin
								dmk_tpos   <= 0;
								dmk_tidx   <= dmk_tidx + (dmk_2side ? 8'd2 : 8'd1);
								dmk_tbase  <= dmk_next_tr;
								dmk_nidam  <= 0;
								dmk_idx    <= 0;
								dmk_tabend <= 0;
							end
						end
						else if(dmk_tpos == (dmk_tlen - 16'd1)) begin
							dmk_tpos   <= 0;
							dmk_tidx   <= dmk_tidx + (dmk_2side ? 8'd2 : 8'd1);
							dmk_tbase  <= dmk_next_tr;
							dmk_nidam  <= 0;
							dmk_idx    <= 0;
							dmk_tabend <= 0;
							dmk_state  <= DS_WAIT;
							dmk_half   <= 0;
						end
						else dmk_tpos <= dmk_tpos + 1'd1;
					end
				end
			end
		end
	end
endgenerate

endmodule

module fd1771_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=11)
(
	input                  clock,

	input  [ADDRWIDTH-1:0] address_a,
	input  [DATAWIDTH-1:0] data_a,
	input                  wren_a,
	output [DATAWIDTH-1:0] q_a,

	input  [ADDRWIDTH-1:0] address_b,
	input  [DATAWIDTH-1:0] data_b,
	input                  wren_b,
	output [DATAWIDTH-1:0] q_b
);

reg [DATAWIDTH-1:0] mem [0:(2**ADDRWIDTH)-1];
reg [DATAWIDTH-1:0] q_a_r, q_b_r;

always @(posedge clock) begin
	if (wren_a) begin
		mem[address_a] <= data_a;
		q_a_r          <= data_a;
	end
	else q_a_r <= mem[address_a];
end

always @(posedge clock) begin
	if (wren_b) begin
		mem[address_b] <= data_b;
		q_b_r          <= data_b;
	end
	else q_b_r <= mem[address_b];
end

assign q_a = q_a_r;
assign q_b = q_b_r;

endmodule
