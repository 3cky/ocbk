// ============================================================================
//  audio_ns6_tb - THE RESOLUTION ORACLE for the noise-shaped 16->6-bit DAC
//                 output stage (src/audio/audio_ns6.sv).
// ----------------------------------------------------------------------------
//  This testbench is the whole justification for the claim that a 6-bit R-2R
//  ladder can carry substantially more than 6 bits of audio-band resolution.
//  It proves the DIGITAL half of that claim (the analog half - ladder INL, the
//  board's RC corner - is a jack recording + FFT, see sim/audio/README.md).
//
//  All integer arithmetic, no reals: exact and reproducible.
//
//  L1  DC accuracy - THE proof. For each DC input, accumulate M emitted codes
//      and require the IDENTITY
//          1024*sum(code) - M*(32*1024 + s)  ==  errp_0 - errp_M  in [-1023,1023]
//      to hold. This is not a tolerance: the loop telescopes to exactly that,
//      so the bound holds for EVERY M. Plain 6-bit truncation is off by up to
//      512 units PER SAMPLE (M*512 in total), so the discrimination is ~M-fold.
//      At the default M this pins the mean code to <1/4000 of a ladder step.
//  L2  Range: code in [1,63] on every in-range tick, and dbg_clip stays 0.
//  L3  Exact silence sits still: s=0 -> code == 32 on EVERY tick, and after a
//      loud passage it returns to 32 in ONE tick and stays. (Note errp does NOT
//      return to 512 - with s=0 the residue freezes at whatever it held. That
//      is correct and is asserted, so nobody "fixes" it later.)
//  L4  Reconstruction fidelity - the SHARPEST leg. The code stream and the
//      ideal value go through the SAME single-pole IIR and are compared. Leg
//      (b) uses a signal of amplitude 512 = HALF OF ONE LADDER STEP, which a
//      plain 6-bit truncating path renders as either silence or a 1-bit
//      square. Passing (b) IS the increment's premise.
//  L5  Clamp + post-clip recovery: over-range input must not WRAP (a wrap is a
//      full-scale sign inversion), dbg_clip must latch, and the exact code
//      sequence after returning in range pins the errp re-centring.
//  L6  Tick discipline: code and errp change ONLY on tick cycles.
//  L7  Reset: code == 32 and errp == 512 out of reset, mid-scale held during.
//
//  Errors print with the AUDIO-ERROR prefix (run_audio.sh greps for it) and the
//  run ends in the repo-standard COSIM PASS / COSIM FAIL line.
// ============================================================================
`timescale 1ns/1ps
module audio_ns6_tb;

    // The tb makes its own tick; the SHIPPED rate divider lives in audio_out
    // and is exercised by bk_audio_tb (audio_ns6 only ever sees an enable, so
    // this is not a replica of anything). 4 rather than 16 keeps L1 fast while
    // still leaving non-tick cycles for L6 to police.
    localparam integer TDIV = 4;

    integer m_ticks = 4096;         // L1 sweep length; +dcticks= raises it

    logic               sys_clk = 1'b0;
    logic               rst_n   = 1'b0;
    logic signed [15:0] s_in    = 16'sd0;
    logic        [5:0]  code;
    logic               dbg_clip;

    integer errors = 0;

    // ---- tick generator -----------------------------------------------------
    integer phase = 0;
    always @(posedge sys_clk) phase <= (phase == TDIV-1) ? 0 : phase + 1;
    wire tick = (phase == 0);

    audio_ns6 dut (
        .sys_clk  (sys_clk),
        .rst_n    (rst_n),
        .tick     (tick),
        .s_in     (s_in),
        .code     (code),
        .dbg_clip (dbg_clip)
    );

    always #5 sys_clk = ~sys_clk;

    // `code` is updated by the NBA at the tick edge, so it is stable from the
    // next edge onward: sample on the delayed tick.
    reg tick_d = 1'b0;
    always @(posedge sys_clk) tick_d <= tick;

    // ---- sampling / checking engine -----------------------------------------
    reg               acc_en   = 1'b0;   // accumulate for L1
    reg               chk_rng  = 1'b0;   // L2: code must be in [1,63]
    reg               chk_zero = 1'b0;   // L3: code must be exactly 32
    reg signed [63:0] acc_sum;
    integer           acc_cnt;

    reg  [5:0] code_q;                   // previous settled code, for L6
    reg  [9:0] errp_q;

    always @(posedge sys_clk) begin
        if (tick_d) begin
            if (acc_en) begin
                acc_sum = acc_sum + code;   // blocking: the count and the sum
                acc_cnt = acc_cnt + 1;      // must stay in step for the waiter
            end
            if (chk_rng && (code < 6'd1))
                begin $display("AUDIO-ERROR L2 code below rail: s=%0d code=%0d",
                               s_in, code); errors = errors + 1; end
            if (chk_zero && (code !== 6'd32))
                begin $display("AUDIO-ERROR L3 silence not still: code=%0d (expected 32)",
                               code); errors = errors + 1; end
        end
    end

    // ---- L6: nothing may move on a non-tick cycle ---------------------------
    // Timing care: at this edge, code_q holds the value established by edge
    // N-2 and code the value established by edge N-1, so the comparison here
    // judges the transition AT EDGE N-1 and must be gated on the tick that
    // governed that edge - hence tick_p, not tick. (Gating on the live tick
    // flags every legitimate update one cycle late.)
    reg l6_arm = 1'b0;
    reg tick_p = 1'b0;
    always @(posedge sys_clk) begin
        if (l6_arm && !tick_p && rst_n) begin
            if (code !== code_q)
                begin $display("AUDIO-ERROR L6 code changed off-tick: %0d -> %0d",
                               code_q, code); errors = errors + 1; end
            if (dut.errp !== errp_q)
                begin $display("AUDIO-ERROR L6 errp changed off-tick: %0d -> %0d",
                               errp_q, dut.errp); errors = errors + 1; end
        end
        code_q <= code;
        errp_q <= dut.errp;
        tick_p <= tick;
    end

    // ---- helpers ------------------------------------------------------------
    task do_reset;
        begin
            acc_en = 1'b0; chk_rng = 1'b0; chk_zero = 1'b0; l6_arm = 1'b0;
            rst_n  = 1'b0;
            repeat (2*TDIV) @(posedge sys_clk);
            #1 rst_n = 1'b1;
            @(posedge sys_clk);
        end
    endtask

    // Run n ticks with the current s_in, no accumulation.
    task run_ticks(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge sys_clk);
                while (!tick_d) @(posedge sys_clk);
            end
        end
    endtask

    // ---- L1 ------------------------------------------------------------------
    task dc_check(input signed [15:0] s);
        reg signed [63:0] lhs;
        begin
            do_reset();
            s_in    = s;
            acc_sum = 0;
            acc_cnt = 0;
            chk_rng = 1'b1;
            acc_en  = 1'b1;
            while (acc_cnt < m_ticks) @(posedge sys_clk);
            acc_en  = 1'b0;
            chk_rng = 1'b0;
            lhs = 64'sd1024 * acc_sum
                - $signed({{32{1'b0}}, m_ticks}) * (64'sd32768 + s);
            if (lhs > 64'sd1023 || lhs < -64'sd1023) begin
                $display("AUDIO-ERROR L1 DC s=%0d: 1024*sum-M*(32768+s)=%0d (|.|>1023, M=%0d)",
                         s, lhs, m_ticks);
                errors = errors + 1;
            end
            if (dbg_clip !== 1'b0) begin
                $display("AUDIO-ERROR L2 dbg_clip set for in-range s=%0d", s);
                errors = errors + 1;
            end
        end
    endtask

    // ---- L4: identical single-pole IIR over both streams --------------------
    // Both streams carry the SAME signal, so the signal content cancels in the
    // comparison and only the quantization noise differs - which is why the
    // waveform shape is free (a triangle is used). Units are 1/1024 of a code.
    localparam integer K    = 6;     // IIR shift: cutoff ~ Fs/402
    localparam integer TPER = 1024;  // triangle period in ticks (well below cutoff)

    task recon_check(input integer amp, input integer tol, input [127:0] name);
        integer i, t, worst, d;
        reg signed [31:0] y_code, y_ideal, x_code, x_ideal;
        reg signed [31:0] sig;
        begin
            do_reset();
            y_code  = 32*1024 << K;      // both filters pre-charged to mid-scale
            y_ideal = 32*1024 << K;      // (scaled accumulators)
            worst   = 0;
            chk_rng = 1'b1;
            for (i = 0; i < 8*TPER; i = i + 1) begin
                // symmetric triangle of amplitude `amp`, period TPER ticks
                t   = i % TPER;
                sig = (t < TPER/2) ? (-amp + (4*amp*t)/TPER)
                                   : (3*amp - (4*amp*t)/TPER);
                s_in = sig[15:0];
                run_ticks(1);
                x_code  = 1024 * code;
                x_ideal = 32*1024 + sig;
                y_code  = y_code  + (x_code  - (y_code  >>> K));
                y_ideal = y_ideal + (x_ideal - (y_ideal >>> K));
                // skip the filter settling transient
                if (i > 2*TPER) begin
                    d = (y_code >>> K) - (y_ideal >>> K);
                    if (d < 0) d = -d;
                    if (d > worst) worst = d;
                end
            end
            chk_rng = 1'b0;
            $display("L4 %0s: amp=%0d worst filtered error = %0d/1024 code (tol %0d)",
                     name, amp, worst, tol);
            if (worst > tol) begin
                $display("AUDIO-ERROR L4 %0s: filtered error %0d/1024 exceeds %0d",
                         name, worst, tol);
                errors = errors + 1;
            end
        end
    endtask

    // ---- main ---------------------------------------------------------------
    integer i;
    reg [5:0] seq [0:3];
    initial begin
        if ($value$plusargs("dcticks=%d", m_ticks))
            $display("L1 sweep length overridden: M=%0d", m_ticks);

        // ================= L7: reset state ==================================
        repeat (3) @(posedge sys_clk);
        #1;
        if (code !== 6'd32) begin
            $display("AUDIO-ERROR L7 code not mid-scale under reset: %0d", code);
            errors = errors + 1;
        end
        if (dut.errp !== 10'd512) begin
            $display("AUDIO-ERROR L7 errp not 512 under reset: %0d", dut.errp);
            errors = errors + 1;
        end
        if (dbg_clip !== 1'b0) begin
            $display("AUDIO-ERROR L7 dbg_clip set under reset"); errors = errors + 1;
        end

        // ================= L1 / L2: the DC identity =========================
        // Rails, near-rails, sub-step values, and both signs. The inter-step
        // values are the point: a truncating path cannot represent them at all.
        dc_check(16'sd0);
        dc_check(16'sd1);        dc_check(-16'sd1);
        dc_check(16'sd16);       dc_check(-16'sd16);
        dc_check(16'sd137);      dc_check(-16'sd137);
        dc_check(16'sd511);      dc_check(-16'sd511);
        dc_check(16'sd512);      dc_check(-16'sd512);
        dc_check(16'sd513);      dc_check(-16'sd513);
        dc_check(16'sd1023);     dc_check(-16'sd1023);
        dc_check(16'sd1024);     dc_check(-16'sd1024);
        dc_check(16'sd1161);     dc_check(-16'sd1161);   // 1024+137
        dc_check(16'sd16384);    dc_check(-16'sd16384);
        dc_check(16'sd16521);    dc_check(-16'sd16521);  // 16*1024+137
        dc_check(16'sd30000);    dc_check(-16'sd30000);
        dc_check(16'sd31743);    dc_check(-16'sd31743);
        dc_check(16'sd31744);    dc_check(-16'sd31744);  // the rails

        // the rails must be STATIC (the fixed-point property)
        do_reset(); s_in = 16'sd31744;  run_ticks(4); l6_arm = 1'b1;
        run_ticks(64);
        #1 if (code !== 6'd63)
            begin $display("AUDIO-ERROR L1 +FS rail not code 63: %0d", code);
                  errors = errors + 1; end
        l6_arm = 1'b0;
        do_reset(); s_in = -16'sd31744; run_ticks(4);
        run_ticks(64);
        #1 if (code !== 6'd1)
            begin $display("AUDIO-ERROR L1 -FS rail not code 1: %0d", code);
                  errors = errors + 1; end

        // ================= L3: exact silence ================================
        do_reset();
        s_in     = 16'sd0;
        chk_zero = 1'b1;
        run_ticks(100000);
        chk_zero = 1'b0;
        #1 if (dut.errp !== 10'd512)
            begin $display("AUDIO-ERROR L3 errp drifted at silence: %0d", dut.errp);
                  errors = errors + 1; end

        // a loud passage, then back to silence: ONE tick to settle, then still
        s_in = 16'sd20000; run_ticks(777);
        s_in = 16'sd0;
        run_ticks(1);
        #1 if (code !== 6'd32)
            begin $display("AUDIO-ERROR L3 not silent 1 tick after a loud passage: code=%0d",
                           code); errors = errors + 1; end
        errp_q   = dut.errp;      // the residue must now FREEZE, not re-centre
        chk_zero = 1'b1;
        run_ticks(2000);
        chk_zero = 1'b0;
        #1 if (dut.errp !== errp_q)
            begin $display("AUDIO-ERROR L3 errp moved while silent: %0d -> %0d",
                           errp_q, dut.errp); errors = errors + 1; end

        // ================= L4: reconstruction ===============================
        // Tolerances are 4x the measured values (9 and 10 units), chosen to be
        // DISCRIMINATING rather than comfortable: a plain truncating path
        // renders the amp=512 signal as a 31/32 square wave at the signal
        // frequency, i.e. an IN-BAND error of ~256+ units, so 40 separates the
        // two by ~6x while leaving room for benign retiming.
        recon_check(31744, 40, "full-scale");
        recon_check(  512, 40, "HALF ONE LADDER STEP");

        // ================= L5: clamp + post-clip recovery ===================
        do_reset();
        s_in = 16'sd32767;                 // beyond FS_SAT: must clamp, not wrap
        for (i = 0; i < 64; i = i + 1) begin
            run_ticks(1);
            if (code > 6'd63)
                begin $display("AUDIO-ERROR L5 code out of range: %0d", code);
                      errors = errors + 1; end
            if (code < 6'd60)
                begin $display("AUDIO-ERROR L5 over-range WRAPPED to %0d", code);
                      errors = errors + 1; end
        end
        #1 if (dbg_clip !== 1'b1)
            begin $display("AUDIO-ERROR L5 dbg_clip not latched on overload");
                  errors = errors + 1; end
        if (dut.errp !== 10'd512)
            begin $display("AUDIO-ERROR L5 errp not re-centred during clip: %0d",
                           dut.errp); errors = errors + 1; end

        // negative overload
        s_in = -16'sd32768;
        for (i = 0; i < 64; i = i + 1) begin
            run_ticks(1);
            if (code > 6'd3)
                begin $display("AUDIO-ERROR L5 negative overload WRAPPED to %0d", code);
                      errors = errors + 1; end
        end

        // Exact post-clip recovery, which pins the errp re-centring alongside
        // the during-clip errp check above. Coming out of a clamped state with
        // errp re-centred at 512 and s = +512 (exactly HALF a ladder step):
        //    accr = 512+512 = 1024 -> q=1 -> code 33, errn = 1024 & 1023 = 0
        //    accr = 512+  0 =  512 -> q=0 -> code 32, errn = 512
        //    accr = 512+512 = 1024 -> q=1 -> code 33, errn = 0   ... period 2
        // i.e. the textbook half-LSB limit cycle at Fs/2 - mean exactly 32.5,
        // and the alternation sits at 3 MHz where nothing can hear it. That is
        // the increment's premise in three ticks.
        s_in = 16'sd512;
        run_ticks(1); seq[0] = code;
        run_ticks(1); seq[1] = code;
        run_ticks(1); seq[2] = code;
        if (seq[0] !== 6'd33 || seq[1] !== 6'd32 || seq[2] !== 6'd33) begin
            $display("AUDIO-ERROR L5 post-clip recovery sequence %0d,%0d,%0d (expected 33,32,33)",
                     seq[0], seq[1], seq[2]);
            errors = errors + 1;
        end

        // ================= L6: tick discipline ==============================
        do_reset();
        s_in   = 16'sd12345;               // a value with a long limit cycle
        run_ticks(2);
        l6_arm = 1'b1;
        run_ticks(4096);
        l6_arm = 1'b0;

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
