// ============================================================================
//  ym2149 - YM2149 / AY-3-8910 PSG core (VENDORED)
// ----------------------------------------------------------------------------
//  Upstream: ~/projects/other/fpga/BK0011M_MiSTer/rtl/ym2149.sv
//            (c) MikeJ 2005, (c) Sorgelig 2016-2019. Licence header below,
//            unmodified. Re-sync from upstream is fine, but re-apply the
//            marked local hooks and re-run sim/ts/run.sh afterwards.
//
//  Instantiated twice by bk_turbosound.sv (the BK Turbosound = 2x YM2149 on
//  port 0177714). Per-channel unsigned 8-bit output, which is why this core
//  was chosen over esemsx3's psg_wave.vhd - that one time-multiplexes A/B/C
//  into one summed mono value, and the BK mix needs them apart to pan ACB.
//
//  THE MODULE NAME IS LOWERCASE `ym2149` ON PURPOSE. sim/ts/ym2149_ref.sv
//  carries the upstream's uppercase `YM2149`, so both can be elaborated into
//  ONE testbench and diffed cycle-for-cycle. That equivalence leg is what
//  makes the local hooks below safe; do not rename either module.
//
//  LOCAL HOOKS - all mechanical, no logic change. Groups A/B/C are shared
//  with ym2149_ref.sv and enumerated in ITS header (Icarus-blocking SV-2009
//  forms, declaration-before-use, and the `= 0` power-up initialisers that
//  the un-reset state needs or the core simulates as X forever). Group D is
//  additionally required by Quartus II 11.0 and is marked inline:
//
//    D1  block-local `reg` inside an always block -> module level
//    D2  `wire [11:0] tone_gen_freq[1:3]`         -> three plain wires
//    D3  the `for (i = 1; i <= 3; ...)` tone loop -> unrolled x3
//    D4  `wire [7:0] volTable[64] = '{...}`       -> a function + case
//
//  CONFIGURATION AS USED HERE: SEL = 0 (the /8 prescale) and MODE = 0 (the
//  YM2149 volume law), both tied at the instance in bk_turbosound.sv - the
//  MiSTer BK settings. Both are kept as real inputs and the AY8910 half of
//  the table is kept intact so leg 1 can exercise them; they constant-fold
//  away in the build, taking the upper 32 table entries with them.
//
//  DO / IOA / IOB are unused on the BK: there is no 177714 read merge (see
//  the seam comment in qbus_mem.sv) and the port pins go nowhere, so those
//  cones are pruned by synthesis.
// ============================================================================
//
// Copyright (c) MikeJ - Jan 2005
// Copyright (c) 2016-2019 Sorgelig
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// Redistributions in synthesized form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of the author nor the names of other contributors may
// be used to endorse or promote products derived from this software without
// specific prior written permission.
//
// THIS CODE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//


// BDIR  BC  MODE
//   0   0   inactive
//   0   1   read value
//   1   0   write value
//   1   1   set address
//

module ym2149
(
	input        CLK,       // Global clock
	input        CE,        // PSG Clock enable
	input        RESET,     // Chip RESET (set all Registers to '0', active hi)
	input        BDIR,      // Bus Direction (0 - read , 1 - write)
	input        BC,        // Bus control
	input  [7:0] DI,        // Data In
	output [7:0] DO,        // Data Out
	output [7:0] CHANNEL_A, // PSG Output channel A
	output [7:0] CHANNEL_B, // PSG Output channel B
	output [7:0] CHANNEL_C, // PSG Output channel C

	input        SEL,
	input        MODE,
	
	output [5:0] ACTIVE,

	input  [7:0] IOA_in,
	output [7:0] IOA_out,

	input  [7:0] IOB_in,
	output [7:0] IOB_out
);


reg [7:0] addr;
reg [7:0] ymreg[0:15];
integer ri;

assign ACTIVE  = ~ymreg[7][5:0];
assign IOA_out = ymreg[14];
assign IOB_out = ymreg[15];

// Write to PSG
reg env_reset = 0;
always @(posedge CLK) begin
	if(RESET) begin
		for(ri = 0; ri < 16; ri = ri + 1) ymreg[ri] <= 8'h00;
		ymreg[7]  <= 8'hFF;
		addr      <= 8'h00;
		env_reset <= 0;
	end else begin
		env_reset <= 0;
		if(BDIR) begin
			if(BC) addr <= DI;
			else if(!addr[7:4]) begin
				ymreg[addr[3:0]] <= DI;
				env_reset <= (addr == 13);
			end
		end
	end
end

// Read from PSG
reg [7:0] dout;
assign DO = dout;
always_comb begin
	dout = 8'hFF;
	if(~BDIR & BC & !addr[7:4]) begin
		case(addr[3:0])
			 0: dout = ymreg[0];
			 1: dout = ymreg[1][3:0];
			 2: dout = ymreg[2];
			 3: dout = ymreg[3][3:0];
			 4: dout = ymreg[4];
			 5: dout = ymreg[5][3:0];
			 6: dout = ymreg[6][4:0];
			 7: dout = ymreg[7];
			 8: dout = ymreg[8][4:0];
			 9: dout = ymreg[9][4:0];
			10: dout = ymreg[10][4:0];
			11: dout = ymreg[11];
			12: dout = ymreg[12];
			13: dout = ymreg[13][3:0];
			14: dout = ymreg[7][6] ? ymreg[14] & IOA_in : IOA_in;
			15: dout = ymreg[7][7] ? ymreg[15] & IOA_in : IOB_in;
		endcase
	end
end

reg ena_div = 0;
reg ena_div_noise = 0;

// D1: hoisted out of the always blocks (Quartus 11.0 has no automatic-variable
// support in a procedural block). Static in SystemVerilog either way, so this
// is a text move; the `= 0` initialisers are group C from the reference header.
reg [3:0]  cnt_div = 0;
reg        noise_div = 0;
reg [16:0] poly17 = 0;
reg [4:0]  noise_gen_cnt = 0;
reg [11:0] tone_gen_cnt1 = 0, tone_gen_cnt2 = 0, tone_gen_cnt3 = 0;
reg [15:0] env_gen_cnt = 0;
reg        env_hold = 0;
reg        env_inc = 0;

//  p_divider
always @(posedge CLK) begin

	if(CE) begin
		ena_div <= 0;
		ena_div_noise <= 0;
		if(!cnt_div) begin
			cnt_div <= {SEL, 3'b111};
			ena_div <= 1;
            
			noise_div <= (~noise_div);
			if (noise_div) ena_div_noise <= 1;
		end else begin
			cnt_div <= cnt_div - 1'b1;
		end
	end
end


reg [2:0] noise_gen_op = 0;

//  p_noise_gen
always @(posedge CLK) begin

	if(CE) begin
		if (ena_div_noise) begin
			if (!ymreg[6][4:0] || (noise_gen_cnt >= ymreg[6][4:0] - 1'd1)) begin
				noise_gen_cnt <= 0;
				poly17 <= {(poly17[0] ^ poly17[2] ^ !poly17), poly17[16:1]};
			end else begin
				noise_gen_cnt <= noise_gen_cnt + 1'd1;
			end
			noise_gen_op <= {3{poly17[0]}};
		end
	end
end

// D2: an unpacked array of wires is SystemVerilog-2009; three plain wires.
wire [11:0] tone_gen_freq1 = {ymreg[1][3:0], ymreg[0]};
wire [11:0] tone_gen_freq2 = {ymreg[3][3:0], ymreg[2]};
wire [11:0] tone_gen_freq3 = {ymreg[5][3:0], ymreg[4]};

reg [3:1] tone_gen_op = 0;

//p_tone_gens
always @(posedge CLK) begin

	if(CE) begin
		// looks like real chips count up - we need to get the Exact behaviour ..
		// D3: the upstream `for (i = 1; i <= 3; ...)` unrolled onto the three
		// hoisted counters. Each arm is the loop body verbatim.
		if(ena_div) begin
			if (!tone_gen_freq1 || (tone_gen_cnt1 >= (tone_gen_freq1 - 1'd1))) begin
				tone_gen_cnt1 <= 0;
				tone_gen_op[1] <= ~tone_gen_op[1];
			end else begin
				tone_gen_cnt1 <= tone_gen_cnt1 + 1'd1;
			end

			if (!tone_gen_freq2 || (tone_gen_cnt2 >= (tone_gen_freq2 - 1'd1))) begin
				tone_gen_cnt2 <= 0;
				tone_gen_op[2] <= ~tone_gen_op[2];
			end else begin
				tone_gen_cnt2 <= tone_gen_cnt2 + 1'd1;
			end

			if (!tone_gen_freq3 || (tone_gen_cnt3 >= (tone_gen_freq3 - 1'd1))) begin
				tone_gen_cnt3 <= 0;
				tone_gen_op[3] <= ~tone_gen_op[3];
			end else begin
				tone_gen_cnt3 <= tone_gen_cnt3 + 1'd1;
			end
		end
	end
end

reg env_ena = 0;
wire [15:0] env_gen_comp = {ymreg[12], ymreg[11]} ? {ymreg[12], ymreg[11]} - 1'd1 : 16'd0;

//p_envelope_freq
always @(posedge CLK) begin

	if(CE) begin
		env_ena <= 0;
		if(ena_div) begin
			if (env_gen_cnt >= env_gen_comp) begin
				env_gen_cnt <= 0;
				env_ena <= 1;
			end else begin
				env_gen_cnt <= (env_gen_cnt + 1'd1);
			end
		end
	end
end

reg [4:0] env_vol;

wire is_bot    = (env_vol == 5'b00000);
wire is_bot_p1 = (env_vol == 5'b00001);
wire is_top_m1 = (env_vol == 5'b11110);
wire is_top    = (env_vol == 5'b11111);

always @(posedge CLK) begin

	// envelope shapes
	// C AtAlH
	// 0 0 x x  \___
	//
	// 0 1 x x  /___
	//
	// 1 0 0 0  \\\\
	//
	// 1 0 0 1  \___
	//
	// 1 0 1 0  \/\/
	//           ___
	// 1 0 1 1  \
	//
	// 1 1 0 0  ////
	//           ___
	// 1 1 0 1  /
	//
	// 1 1 1 0  /\/\
	//
	// 1 1 1 1  /___

	if(env_reset | RESET) begin
		// load initial state
		if(!ymreg[13][2]) begin		// attack
			env_vol <= 5'b11111;
			env_inc <= 0;		// -1
		end else begin
			env_vol <= 5'b00000;
			env_inc <= 1;		// +1
		end
		env_hold <= 0;
	end
	else if(CE) begin
		if (env_ena) begin
			if (!env_hold) begin
				if (env_inc) env_vol <= (env_vol + 5'b00001);
					else env_vol <= (env_vol + 5'b11111);
			end

			// envelope shape control.
			if(!ymreg[13][3]) begin
				if(!env_inc) begin	// down
					if(is_bot_p1) env_hold <= 1;
				end else if (is_top) env_hold <= 1;
			end else if(ymreg[13][0]) begin		// hold = 1
				if(!env_inc) begin	// down
					if(ymreg[13][1]) begin		// alt
						if(is_bot) env_hold <= 1;
					end else if(is_bot_p1) env_hold <= 1;
				end else if(ymreg[13][1]) begin	// alt
					if(is_top) env_hold <= 1;
				end else if(is_top_m1) env_hold <= 1;
			end else if(ymreg[13][1]) begin		// alternate
				if(env_inc == 1'b0) begin		// down
					if(is_bot_p1) env_hold <= 1;
					if(is_bot) begin
						env_hold <= 0;
						env_inc  <= 1;
					end
				end else begin
					if(is_top_m1) env_hold <= 1;
					if(is_top) begin
						env_hold <= 0;
						env_inc  <= 0;
					end
				end
			end
		end
	end
end

reg [5:0] A = 0, B = 0, C = 0;
always @(posedge CLK) begin
	A <= {MODE, ~((ymreg[7][0] | tone_gen_op[1]) & (ymreg[7][3] | noise_gen_op[0])) ? 5'd0 : ymreg[8][4]  ? env_vol[4:0] : { ymreg[8][3:0],  ymreg[8][3]}};
	B <= {MODE, ~((ymreg[7][1] | tone_gen_op[2]) & (ymreg[7][4] | noise_gen_op[1])) ? 5'd0 : ymreg[9][4]  ? env_vol[4:0] : { ymreg[9][3:0],  ymreg[9][3]}};
	C <= {MODE, ~((ymreg[7][2] | tone_gen_op[3]) & (ymreg[7][5] | noise_gen_op[2])) ? 5'd0 : ymreg[10][4] ? env_vol[4:0] : {ymreg[10][3:0], ymreg[10][3]}};
end

// D4: an unpacked array of wires with an assignment pattern is
// SystemVerilog-2009. Same 64 entries, same order, as a function.
// Index = {MODE, level[4:0]}: 0-31 = YM2149, 32-63 = AY8910.
// THE TRANSCRIPTION RISK IN THIS FILE LIVES HERE - sim/ts leg 1 diffs
// every channel against ym2149_ref.sv, which keeps the array verbatim.
function [7:0] vol_lut(input [5:0] idx);
	case(idx)
		6'd0 : vol_lut = 8'h00;  // YM2149  0
		6'd1 : vol_lut = 8'h01;  // YM2149  1
		6'd2 : vol_lut = 8'h01;  // YM2149  2
		6'd3 : vol_lut = 8'h02;  // YM2149  3
		6'd4 : vol_lut = 8'h02;  // YM2149  4
		6'd5 : vol_lut = 8'h03;  // YM2149  5
		6'd6 : vol_lut = 8'h03;  // YM2149  6
		6'd7 : vol_lut = 8'h04;  // YM2149  7
		6'd8 : vol_lut = 8'h06;  // YM2149  8
		6'd9 : vol_lut = 8'h07;  // YM2149  9
		6'd10: vol_lut = 8'h09;  // YM2149 10
		6'd11: vol_lut = 8'h0a;  // YM2149 11
		6'd12: vol_lut = 8'h0c;  // YM2149 12
		6'd13: vol_lut = 8'h0e;  // YM2149 13
		6'd14: vol_lut = 8'h11;  // YM2149 14
		6'd15: vol_lut = 8'h13;  // YM2149 15
		6'd16: vol_lut = 8'h17;  // YM2149 16
		6'd17: vol_lut = 8'h1b;  // YM2149 17
		6'd18: vol_lut = 8'h20;  // YM2149 18
		6'd19: vol_lut = 8'h25;  // YM2149 19
		6'd20: vol_lut = 8'h2c;  // YM2149 20
		6'd21: vol_lut = 8'h35;  // YM2149 21
		6'd22: vol_lut = 8'h3e;  // YM2149 22
		6'd23: vol_lut = 8'h47;  // YM2149 23
		6'd24: vol_lut = 8'h54;  // YM2149 24
		6'd25: vol_lut = 8'h66;  // YM2149 25
		6'd26: vol_lut = 8'h77;  // YM2149 26
		6'd27: vol_lut = 8'h88;  // YM2149 27
		6'd28: vol_lut = 8'ha1;  // YM2149 28
		6'd29: vol_lut = 8'hc0;  // YM2149 29
		6'd30: vol_lut = 8'he0;  // YM2149 30
		6'd31: vol_lut = 8'hff;  // YM2149 31
		6'd32: vol_lut = 8'h00;  // AY8910  0
		6'd33: vol_lut = 8'h00;  // AY8910  1
		6'd34: vol_lut = 8'h03;  // AY8910  2
		6'd35: vol_lut = 8'h03;  // AY8910  3
		6'd36: vol_lut = 8'h04;  // AY8910  4
		6'd37: vol_lut = 8'h04;  // AY8910  5
		6'd38: vol_lut = 8'h06;  // AY8910  6
		6'd39: vol_lut = 8'h06;  // AY8910  7
		6'd40: vol_lut = 8'h0a;  // AY8910  8
		6'd41: vol_lut = 8'h0a;  // AY8910  9
		6'd42: vol_lut = 8'h0f;  // AY8910 10
		6'd43: vol_lut = 8'h0f;  // AY8910 11
		6'd44: vol_lut = 8'h15;  // AY8910 12
		6'd45: vol_lut = 8'h15;  // AY8910 13
		6'd46: vol_lut = 8'h22;  // AY8910 14
		6'd47: vol_lut = 8'h22;  // AY8910 15
		6'd48: vol_lut = 8'h28;  // AY8910 16
		6'd49: vol_lut = 8'h28;  // AY8910 17
		6'd50: vol_lut = 8'h41;  // AY8910 18
		6'd51: vol_lut = 8'h41;  // AY8910 19
		6'd52: vol_lut = 8'h5b;  // AY8910 20
		6'd53: vol_lut = 8'h5b;  // AY8910 21
		6'd54: vol_lut = 8'h72;  // AY8910 22
		6'd55: vol_lut = 8'h72;  // AY8910 23
		6'd56: vol_lut = 8'h90;  // AY8910 24
		6'd57: vol_lut = 8'h90;  // AY8910 25
		6'd58: vol_lut = 8'hb5;  // AY8910 26
		6'd59: vol_lut = 8'hb5;  // AY8910 27
		6'd60: vol_lut = 8'hd7;  // AY8910 28
		6'd61: vol_lut = 8'hd7;  // AY8910 29
		6'd62: vol_lut = 8'hff;  // AY8910 30
		6'd63: vol_lut = 8'hff;  // AY8910 31
		default: vol_lut = 8'h00;
	endcase
endfunction

assign CHANNEL_A = vol_lut(A);
assign CHANNEL_B = vol_lut(B);
assign CHANNEL_C = vol_lut(C);

endmodule
