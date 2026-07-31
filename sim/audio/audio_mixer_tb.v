// ============================================================================
//  audio_mixer_tb - unit oracle for the N-slot stereo mixer
//                   (src/audio/audio_mixer.sv)
// ----------------------------------------------------------------------------
//  Four instances, each pinning a different part of the contract:
//
//    dut3   NSRC=5, the SHIPPED config (spk BOTH, tone A BOTH, tone B R-only,
//           Turbosound L L-only, Turbosound R R-only)
//           -> enable, pan, saturation, dbg_sat, exact latency
//    dutg   NSRC=6, gains {8,4,6,3,1,7} all BOTH
//           -> the g/8 gain law against an INDEPENDENTLY WRITTEN reference
//    dut1   NSRC=1, gain 8, pan BOTH
//           -> the PASS-THROUGH INVARIANT: bit-identical to its input. This is
//              the differential-reference idiom this repo uses elsewhere
//              (smk_en=0, turbo=0) and it is what guarantees the speaker-only
//              shipped path cannot be perturbed by mixer arithmetic.
//    dut10  NSRC=10, the full planned slot map
//           -> proves the parameterization the device increments will inherit,
//              without shipping dead logic.
//
//  The gain reference is deliberately NOT a copy of the RTL expression: the RTL
//  uses an arithmetic shift (floor), so the reference does the floor explicitly
//  with integer division and a negative-side correction. A shift bug therefore
//  cannot cancel out against the checker (the palette-table precedent).
//
//  Errors print with the AUDIO-ERROR prefix; the run ends COSIM PASS / FAIL.
// ============================================================================
`timescale 1ns/1ps
module audio_mixer_tb;

    localparam integer FS = 31744;

    logic sys_clk = 1'b0;
    logic rst_n   = 1'b0;
    integer errors = 0;

    always #5 sys_clk = ~sys_clk;

    // ---- references ---------------------------------------------------------
    // Independent transcription of the g/8 law: floor(s*g/8) written as integer
    // division plus an explicit negative correction, never as a shift.
    function integer gain_ref(input integer s, input integer g);
        integer p;
        begin
            p = s * g;
            if (p >= 0) gain_ref =   p / 8;
            else        gain_ref = -(((-p) + 7) / 8);
        end
    endfunction

    function integer sat_ref(input integer v);
        begin
            if      (v >  FS) sat_ref =  FS;
            else if (v < -FS) sat_ref = -FS;
            else              sat_ref =  v;
        end
    endfunction

    task expect2(input integer got_l, input integer got_r,
                 input integer exp_l, input integer exp_r, input [511:0] what);
        begin
            if (got_l !== exp_l || got_r !== exp_r) begin
                $display("AUDIO-ERROR %0s: got l=%0d r=%0d expected l=%0d r=%0d",
                         what, got_l, got_r, exp_l, exp_r);
                errors = errors + 1;
            end
        end
    endtask

    // ========================================================================
    //  dut3 - the shipped config. MUST TRACK bk_audio.sv's SLOT_GAIN/SLOT_PAN:
    //  slot 0 speaker BOTH, 1 tone A BOTH, 2 tone B R-only, 3 Turbosound L
    //  L-only, 4 Turbosound R R-only.
    // ========================================================================
    logic [79:0] src3;
    logic [4:0]  en3;
    logic signed [15:0] l3, r3;
    logic sat3;

    audio_mixer #(
        .NSRC (5), .SW (16), .FS_SAT (FS),
        .GAIN8 (20'h88888),          // all slots at 8/8
        //      slot   4  3  2  1  0
        .PAN   (10'b01_10_01_11_11)
    ) dut3 (
        .sys_clk (sys_clk), .rst_n (rst_n),
        .src (src3), .src_en (en3),
        .mix_l (l3), .mix_r (r3), .dbg_sat (sat3)
    );

    // The 3-slot helper: drives the speaker and tone slots and holds the two
    // Turbosound slots at zero AND disabled, so every check written against
    // the pre-Turbosound slot map still means exactly what it did.
    task set3(input integer s0, input integer s1, input integer s2, input [2:0] en);
        begin
            src3[15:0]  = s0[15:0];
            src3[31:16] = s1[15:0];
            src3[47:32] = s2[15:0];
            src3[63:48] = 16'sd0;
            src3[79:64] = 16'sd0;
            en3 = {2'b00, en};
            repeat (4) @(posedge sys_clk);
            #1;
        end
    endtask

    // The full 5-slot helper, for the Turbosound pan checks.
    task set5(input integer s0, input integer s1, input integer s2,
              input integer s3, input integer s4, input [4:0] en);
        begin
            src3[15:0]  = s0[15:0];
            src3[31:16] = s1[15:0];
            src3[47:32] = s2[15:0];
            src3[63:48] = s3[15:0];
            src3[79:64] = s4[15:0];
            en3 = en;
            repeat (4) @(posedge sys_clk);
            #1;
        end
    endtask

    // ========================================================================
    //  dutg - the gain law
    // ========================================================================
    logic [95:0] srcg;
    logic [5:0]  eng;
    logic signed [15:0] lg, rg;
    logic satg;

    // slot: 0=8  1=4  2=6  3=3  4=1  5=7   (slot 0 in the LOW nibble)
    audio_mixer #(
        .NSRC (6), .SW (16), .FS_SAT (FS),
        .GAIN8 (24'h7_1_3_6_4_8),
        .PAN   (12'b11_11_11_11_11_11)
    ) dutg (
        .sys_clk (sys_clk), .rst_n (rst_n),
        .src (srcg), .src_en (eng),
        .mix_l (lg), .mix_r (rg), .dbg_sat (satg)
    );

    // ========================================================================
    //  dut1 - the pass-through invariant
    // ========================================================================
    logic [15:0] src1;
    logic        en1;
    logic signed [15:0] l1, r1;
    logic sat1;

    audio_mixer #(
        .NSRC (1), .SW (16), .FS_SAT (FS),
        .GAIN8 (4'd8), .PAN (2'b11)
    ) dut1 (
        .sys_clk (sys_clk), .rst_n (rst_n),
        .src (src1), .src_en (en1),
        .mix_l (l1), .mix_r (r1), .dbg_sat (sat1)
    );

    // ========================================================================
    //  dut10 - the planned endgame slot map
    // ========================================================================
    logic [159:0] src10;
    logic [9:0]   en10;
    logic signed [15:0] l10, r10;
    logic sat10;

    // 0 spk BOTH | 1 toneA BOTH | 2 toneB R | 3 AY-A L | 4 AY-B BOTH
    // 5 AY-C R   | 6 CovoxL L   | 7 CovoxR R| 8 MenL L | 9 MenR R
    audio_mixer #(
        .NSRC (10), .SW (16), .FS_SAT (FS),
        .GAIN8 (40'h8888888888),
        .PAN   (20'b01_10_01_10_01_11_10_01_11_11)
    ) dut10 (
        .sys_clk (sys_clk), .rst_n (rst_n),
        .src (src10), .src_en (en10),
        .mix_l (l10), .mix_r (r10), .dbg_sat (sat10)
    );

    // ========================================================================
    integer i, g, s, expl, expr, k;
    integer gtab [0:5];
    integer lat;
    initial begin
        gtab[0]=8; gtab[1]=4; gtab[2]=6; gtab[3]=3; gtab[4]=1; gtab[5]=7;

        src3 = 80'h0; en3 = 5'b11111;
        srcg = 96'h0; eng = 6'b111111;
        src1 = 16'h0; en1 = 1'b1;
        src10 = 160'h0; en10 = 10'h3FF;

        // ---- reset: everything must be zero, dbg_sat clear -----------------
        repeat (3) @(posedge sys_clk);
        #1;
        if (l3 !== 16'sd0 || r3 !== 16'sd0 || sat3 !== 1'b0) begin
            $display("AUDIO-ERROR reset: dut3 l=%0d r=%0d sat=%b", l3, r3, sat3);
            errors = errors + 1;
        end
        @(posedge sys_clk); #1 rst_n = 1'b1;

        // ================= pan ==============================================
        // slot 0 BOTH -> both sides; slot 2 R-only -> right only, and the left
        // must not see a trace of it.
        set3(1000, 0, 0, 3'b111);  expect2(l3, r3, 1000, 1000, "pan slot0 BOTH");
        set3(0, 0, 7000, 3'b111);  expect2(l3, r3,    0, 7000, "pan slot2 R-only");
        set3(0, 2000, 0, 3'b111);  expect2(l3, r3, 2000, 2000, "pan slot1 BOTH");
        set3(100, 200, 400, 3'b111);
        expect2(l3, r3, 300, 700, "pan mixed sum");

        // The Turbosound pair: slot 3 is L-only and slot 4 is R-only, so a
        // hard-panned PSG mix must NOT leak across. This is the shipped map's
        // only pair of oppositely-panned slots, and getting it backwards would
        // silently swap the stereo image on the board.
        set5(0, 0, 0, 9000, 0, 5'b01000);
        expect2(l3, r3, 9000, 0, "pan slot3 Turbosound-L is L-only");
        set5(0, 0, 0, 0, 9000, 5'b10000);
        expect2(l3, r3, 0, 9000, "pan slot4 Turbosound-R is R-only");
        set5(0, 0, 0, 4000, 6000, 5'b11000);
        expect2(l3, r3, 4000, 6000, "pan Turbosound pair, no crosstalk");

        // The shipped worst case, exactly as bk_audio's gain budget computes
        // it: the ducked speaker at +8192 on BOTH plus the Turbosound bound of
        // 22950 on one side = 31142, which must pass through UNSATURATED
        // (FS_SAT is 31744). If this ever saturates, the budget is wrong.
        set5(8192, 0, 0, 22950, 22950, 5'b11001);
        expect2(l3, r3, 31142, 31142, "shipped worst case is inside FS_SAT");
        if (sat3 !== 1'b0) begin
            $display("AUDIO-ERROR the shipped gain budget saturated the mixer");
            errors = errors + 1;
        end

        // ================= enable ===========================================
        // A disabled slot must contribute EXACTLY zero - not mid-scale, not
        // pass-through - even holding a large sample.
        set3(20000, 20000, 20000, 3'b000);
        expect2(l3, r3, 0, 0, "enable: all off with large samples");
        set3(20000, 20000, 20000, 3'b001);
        expect2(l3, r3, 20000, 20000, "enable: only slot0");
        set3(20000, -9000, 20000, 3'b010);
        expect2(l3, r3, -9000, -9000, "enable: only slot1");
        set3(20000, 20000, 12345, 3'b100);
        expect2(l3, r3, 0, 12345, "enable: only slot2 (R-only)");

        // ================= saturation =======================================
        // Two full-scale slots on the same side must clamp to +FS and, above
        // all, must NEVER come out negative (the wrap discriminator).
        set3(FS, FS, 0, 3'b011);
        expect2(l3, r3, FS, FS, "saturate +FS+FS");
        if (l3 < 0 || r3 < 0) begin
            $display("AUDIO-ERROR saturation WRAPPED negative: l=%0d r=%0d", l3, r3);
            errors = errors + 1;
        end
        if (sat3 !== 1'b1) begin
            $display("AUDIO-ERROR dbg_sat not set after saturation"); errors = errors + 1;
        end
        set3(-FS, -FS, 0, 3'b011);
        expect2(l3, r3, -FS, -FS, "saturate -FS-FS");
        if (l3 > 0 || r3 > 0) begin
            $display("AUDIO-ERROR negative saturation WRAPPED positive: l=%0d r=%0d", l3, r3);
            errors = errors + 1;
        end
        // and it is STICKY: a quiet sample afterwards must not clear it
        set3(10, 10, 0, 3'b011);
        if (sat3 !== 1'b1) begin
            $display("AUDIO-ERROR dbg_sat not sticky"); errors = errors + 1;
        end
        // right-side-only saturation is seen too (slot 2 is R-only)
        set3(FS, 0, FS, 3'b101);
        expect2(l3, r3, FS, FS, "saturate via the R-only slot");

        // ================= exact latency ====================================
        // Two registered stages: the new value must appear exactly 2 sys_clk
        // after the input changes, and hold thereafter.
        set3(0, 0, 0, 3'b001);
        @(posedge sys_clk);
        src3[15:0] = 16'sd4321;
        lat = -1;
        for (k = 1; k <= 6; k = k + 1) begin
            @(posedge sys_clk); #1;
            if (lat < 0 && l3 === 16'sd4321) lat = k;
        end
        if (lat !== 2) begin
            $display("AUDIO-ERROR latency: value appeared after %0d sys_clk (expected 2)", lat);
            errors = errors + 1;
        end
        repeat (4) @(posedge sys_clk); #1;
        if (l3 !== 16'sd4321) begin
            $display("AUDIO-ERROR value not held after latency: %0d", l3);
            errors = errors + 1;
        end

        // ================= the g/8 gain law =================================
        // One slot at a time, swept over values that exercise floor-vs-truncate
        // on the negative side (the reference does the floor explicitly).
        for (i = 0; i < 6; i = i + 1) begin
            for (k = 0; k < 14; k = k + 1) begin
                case (k)
                    0: s =      0;  1: s =      1;  2: s =     -1;
                    3: s =      7;  4: s =     -7;  5: s =      8;
                    6: s =     -8;  7: s =    137;  8: s =   -137;
                    9: s =   1023; 10: s =  -1023; 11: s =  20000;
                   12: s = -20000; default: s = FS;
                endcase
                srcg = 96'h0;
                srcg[i*16 +: 16] = s[15:0];
                eng  = 6'b111111;
                repeat (4) @(posedge sys_clk); #1;
                expl = sat_ref(gain_ref(s, gtab[i]));
                if (lg !== expl || rg !== expl) begin
                    $display("AUDIO-ERROR gain slot%0d g=%0d s=%0d: got l=%0d r=%0d expected %0d",
                             i, gtab[i], s, lg, rg, expl);
                    errors = errors + 1;
                end
            end
        end

        // ================= pass-through invariant ===========================
        // NSRC=1, g=8, BOTH: mix_l == mix_r == src, bit for bit, for every
        // value that can reach the mixer.
        for (k = 0; k < 18; k = k + 1) begin
            case (k)
                0: s =      0;  1: s =      1;  2: s =     -1;
                3: s =    512;  4: s =   -512;  5: s =   1024;
                6: s =  -1024;  7: s =    137;  8: s =   -137;
                9: s =  16384; 10: s = -16384; 11: s =  31743;
               12: s = -31743; 13: s =     FS; 14: s =    -FS;
               15: s =     63; 16: s =    -63; default: s = 12345;
            endcase
            src1 = s[15:0];
            en1  = 1'b1;
            repeat (4) @(posedge sys_clk); #1;
            if (l1 !== s[15:0] || r1 !== s[15:0]) begin
                $display("AUDIO-ERROR pass-through broken: src=%0d got l=%0d r=%0d",
                         s, l1, r1);
                errors = errors + 1;
            end
        end
        if (sat1 !== 1'b0) begin
            $display("AUDIO-ERROR pass-through instance saturated"); errors = errors + 1;
        end

        // ================= the NSRC=10 endgame shape ========================
        // Each slot alone, on the side(s) its pan says - this is what the device
        // increments inherit, so a pan typo in the map must show up here.
        for (i = 0; i < 10; i = i + 1) begin
            src10 = 160'h0;
            src10[i*16 +: 16] = 16'sd1000;
            en10  = 10'h3FF;
            repeat (4) @(posedge sys_clk); #1;
            case (i)
                0, 1, 4: begin expl = 1000; expr = 1000; end   // BOTH
                3, 6, 8: begin expl = 1000; expr =    0; end   // L only
                default: begin expl =    0; expr = 1000; end   // 2,5,7,9 R only
            endcase
            if (l10 !== expl || r10 !== expr) begin
                $display("AUDIO-ERROR NSRC=10 slot%0d: got l=%0d r=%0d expected l=%0d r=%0d",
                         i, l10, r10, expl, expr);
                errors = errors + 1;
            end
        end
        // all ten live at once: 3 BOTH + 3 L + 4 R
        for (i = 0; i < 10; i = i + 1) src10[i*16 +: 16] = 16'sd1000;
        repeat (4) @(posedge sys_clk); #1;
        expect2(l10, r10, 6000, 7000, "NSRC=10 all slots live");
        // and a disabled subset still contributes exactly zero
        en10 = 10'b00_00_01_00_11;   // slots 0,1,4 -> 3 BOTH only
        repeat (4) @(posedge sys_clk); #1;
        expect2(l10, r10, 3000, 3000, "NSRC=10 enable subset");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
