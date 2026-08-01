// ============================================================================
//  bk_audio_tb - SUBSYSTEM oracle for the BK audio path: speaker + self-test
//                tone -> mixer -> noise-shaped 6-bit DAC -> the two R-2R
//                ladders, plus the CMT (cassette) jack mode.
// ----------------------------------------------------------------------------
//  audio_ns6_tb and audio_mixer_tb pin the two infrastructure blocks in
//  isolation. This tb pins how bk_audio ASSEMBLES them, and above all it is the
//  regression guard for the two behaviours that are confirmed working on real
//  hardware and must not be broken by the rework:
//
//    THE SPEAKER  - spk_bit=1 must reach a STATIC ladder code 40 and spk_bit=0 a
//                   STATIC code 24, with no shaping activity in between.
//                   The CODES have moved twice and the STATICNESS never has,
//                   which is the point: 63/0 before the Phase-10 rework, then
//                   63/1 when the mixer's saturation bound became 31744, and
//                   now 40/24 because the Turbosound increment ducks the
//                   speaker to SPK_LVL = 8192 to make room for the PSGs.
//                   8192 = 8*1024 exactly, so it is still an audio_ns6 fixed
//                   point - that is the property under test here, not the
//                   particular number. A duck to a non-multiple of 1024 would
//                   leave the codes rattling and this leg would catch it.
//    THE CMT JACK - the oe split, the comparator network, tape_lvl following the
//                   pad through the 2-FF sync, the anti-echo force, and
//                   tape-out staying the RAW speaker bit.
//
//  New behaviour it also pins: true stereo (the two ladders must be able to
//  differ), the CMT mono fold on the left ladder, the tone_en routing, exact
//  silence at the pads, and DAC-tick discipline. The Turbosound slots are
//  driven directly here (ts_l/ts_r are plain inputs to bk_audio) to prove they
//  reach the mixer with the right pan - bk_turbosound itself is sim/ts's job.
//
//  The tone's staircase dwell is shortened via TONE_STEP_BITS so the 8-step
//  6 dB ladder can actually be walked in simulation (the shipped value is
//  2^26 sys_clk ~ 0.7 s per step).
// ============================================================================
`timescale 1ns/1ps
module bk_audio_tb;

    localparam integer RATE_DIV  = 16;    // the SHIPPED divider
    // tb-only staircase dwell (the shipped value is 26 = ~0.7 s). It cannot be
    // made arbitrarily small: voice B is 1567 Hz and the DAC tick rate is
    // sys_clk/16 = 6.04 MHz, so ONE VOICE-B PERIOD IS ~3854 TICKS = ~61.7k
    // sys_clk. A dwell shorter than that means a step ends before a full
    // waveform cycle has been emitted and its amplitude cannot be measured at
    // all. 16 gives 65536 sys_clk = 4096 ticks = 1.06 periods per step, which is
    // the smallest value that works.
    localparam integer STEP_BITS = 16;

    logic       sys_clk = 1'b0;
    logic       rst_n   = 1'b0;
    logic       spk_bit = 1'b0;
    logic       cmt_mode = 1'b0;
    logic       tone_en  = 1'b0;
    logic       ext_lvl  = 1'b0;   // "tape recorder" level at the jack
    logic signed [15:0] ts_l = 16'sd0, ts_r = 16'sd0;
    logic signed [15:0] cx_l = 16'sd0, cx_r = 16'sd0;
    logic               cx_en = 1'b0;
    logic [5:0] dac_l, dac_r_o, dac_r_oe;
    logic       tape_lvl, active, dbg_sat, dbg_clip, dbg_tone;

    // Pad model: in CMT mode bit 5 is released and the external tape signal
    // wins; when driven, the DUT's own output loops back (which never happens
    // for bit 5 in CMT mode - that is the point of the oe split).
    wire pad_sr5 = dac_r_oe[5] ? dac_r_o[5] : ext_lvl;

    integer errors = 0;

    bk_audio #(
        .RATE_DIV        (RATE_DIV),
        .TONE_ENABLE     (1'b1),
        .TONE_STEP_BITS  (STEP_BITS)
    ) dut (
        .sys_clk    (sys_clk),
        .rst_n      (rst_n),
        .spk_bit    (spk_bit),
        .cmt_mode   (cmt_mode),
        .cmt_in_pad (pad_sr5),
        .tone_en    (tone_en),
        .ts_l       (ts_l),
        .ts_r       (ts_r),
        .cx_l       (cx_l),
        .cx_r       (cx_r),
        .cx_en      (cx_en),
        .tape_lvl   (tape_lvl),
        .dac_l      (dac_l),
        .dac_r_o    (dac_r_o),
        .dac_r_oe   (dac_r_oe),
        .active     (active),
        .dbg_sat    (dbg_sat),
        .dbg_clip   (dbg_clip),
        .dbg_tone   (dbg_tone)
    );

    always #5 sys_clk = ~sys_clk;

    // ---- tick observation (the REAL prescaler, read hierarchically) ---------
    wire tick = dut.u_out.tick;
    reg  tick_p = 1'b0;
    always @(posedge sys_clk) tick_p <= tick;

    // ---- DAC-tick discipline: dac_l may only move on a tick ----------------
    // Same one-cycle-of-history care as audio_ns6_tb L6: the comparison at this
    // edge judges the transition at the PREVIOUS edge, so it gates on tick_p.
    reg        tickchk = 1'b0;
    reg  [5:0] dl_q;
    always @(posedge sys_clk) begin
        if (tickchk && !tick_p && rst_n && dac_l !== dl_q) begin
            $display("AUDIO-ERROR dac_l changed off-tick: %0d -> %0d", dl_q, dac_l);
            errors = errors + 1;
        end
        dl_q <= dac_l;
    end

    // ---- continuous anti-echo watch ----------------------------------------
    // With CMT off we DRIVE pDac_SR[5], and since the rework what it carries is
    // a shaped code bit that can rattle at 3 MHz - so tape_lvl must be held 0 on
    // EVERY cycle, not merely sampled once.
    reg echochk = 1'b0;
    always @(posedge sys_clk) begin
        if (echochk && rst_n && tape_lvl !== 1'b0) begin
            $display("AUDIO-ERROR tape_lvl echoes audio while CMT is off");
            errors = errors + 1;
        end
    end

    // ---- helpers ------------------------------------------------------------
    task wait_ticks(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge sys_clk);
                while (!tick_p) @(posedge sys_clk);
            end
        end
    endtask

    // Apply a speaker level and check the ladder settles STATICALLY to the
    // expected rail code. "Statically" is the fixed-point property that keeps
    // the speaker path bit-for-bit as quiet as it was before the rework.
    task apply_spk(input lvl);
        reg [5:0] exp, seen;
        integer   i;
        begin
            spk_bit = lvl;
            wait_ticks(6);                       // CDC + mixer latency + a tick
            exp  = lvl ? 6'd40 : 6'd24;
            #1 seen = dac_l;
            if (seen !== exp) begin
                $display("AUDIO-ERROR speaker level %b -> dac_l %0d (expected %0d)",
                         lvl, seen, exp);
                errors = errors + 1;
            end
            // and it must not move for the next 32 ticks
            for (i = 0; i < 32; i = i + 1) begin
                wait_ticks(1);
                #1 if (dac_l !== exp) begin
                    $display("AUDIO-ERROR speaker code not static: %0d != %0d",
                             dac_l, exp);
                    errors = errors + 1;
                    i = 32;
                end
            end
            if (dac_r_o !== exp || dac_r_oe !== 6'b111111) begin
                $display("AUDIO-ERROR speaker not mono in audio mode: l=%0d r=%0d oe=%b",
                         dac_l, dac_r_o, dac_r_oe);
                errors = errors + 1;
            end
        end
    endtask

    // Check the CMT-mode right-channel network for the current tape/spk levels.
    task check_cmt(input tlvl, input slvl);
        begin
            if (dac_r_oe !== 6'b001111)
                begin $display("AUDIO-ERROR cmt oe exp=001111 got=%b", dac_r_oe);
                      errors = errors + 1; end
            if (tape_lvl !== tlvl)
                begin $display("AUDIO-ERROR tape_lvl exp=%b got=%b", tlvl, tape_lvl);
                      errors = errors + 1; end
            if (dac_r_o[3:0] !== {tlvl, ~tlvl, 1'b0, slvl})
                begin $display("AUDIO-ERROR cmt net exp=%b got=%b",
                               {tlvl, ~tlvl, 1'b0, slvl}, dac_r_o[3:0]);
                      errors = errors + 1; end
        end
    endtask

    // Measure voice B's isolated swing (R - L) across one full waveform period,
    // starting at the boundary of the requested staircase step. Reading the
    // step counter hierarchically is what keeps the window aligned - the dwell
    // is barely longer than one period, so a window that starts mid-step would
    // spill into the next one and measure the wrong amplitude.
    integer km;
    task meas_swing(input [2:0] want, output integer pk);
        begin
            // RE-ARM first. audio_tone holds its dwell counter and step in reset
            // while disabled, so toggling tone_en restarts the staircase at
            // step 0 on a known boundary; waiting for `want` from there lands
            // exactly at that step's start. Merely waiting for step == want
            // would match a step already in progress, and since the dwell is
            // only 1.06 waveform periods the window would spill into the next
            // (6 dB quieter) step and report a blend of the two.
            tone_en = 1'b0;
            repeat (4) @(posedge sys_clk);
            tone_en = 1'b1;
            while (dut.g_tone.u_tone.step !== want) @(posedge sys_clk);
            pk = 0;
            for (km = 0; km < 3800; km = km + 1) begin
                wait_ticks(1);
                #1 if (dac_r_o > dac_l && (dac_r_o - dac_l) > pk)
                    pk = dac_r_o - dac_l;
            end
        end
    endtask

    integer k, nticks, moved_l, moved_r, differed;
    reg [5:0] prev_l, prev_r;
    reg [5:0] amp_seen_hi, amp_seen_lo;
    initial begin
        // =================================================================
        //  reset held: both ladders mid-scale, all taps driven
        // =================================================================
        repeat (3) @(posedge sys_clk);
        #1;
        if (dac_l !== 6'd32 || dac_r_o !== 6'd32 || dac_r_oe !== 6'b111111) begin
            $display("AUDIO-ERROR DAC not mid-scale under reset: l=%0d r=%0d oe=%b",
                     dac_l, dac_r_o, dac_r_oe);
            errors = errors + 1;
        end
        // reset must win over CMT mode (the pre-rework ordering)
        cmt_mode = 1'b1;
        repeat (3) @(posedge sys_clk);
        #1;
        if (dac_l !== 6'd32 || dac_r_o !== 6'd32 || dac_r_oe !== 6'b111111) begin
            $display("AUDIO-ERROR reset does not win over CMT: l=%0d r=%0d oe=%b",
                     dac_l, dac_r_o, dac_r_oe);
            errors = errors + 1;
        end
        cmt_mode = 1'b0;
        if (dbg_sat !== 1'b0 || dbg_clip !== 1'b0 || dbg_tone !== 1'b0) begin
            $display("AUDIO-ERROR debug flags set under reset: sat=%b clip=%b tone=%b",
                     dbg_sat, dbg_clip, dbg_tone);
            errors = errors + 1;
        end

        @(posedge sys_clk); #1 rst_n = 1'b1;

        // =================================================================
        //  exact silence: speaker idle low is a RAIL, so code 1 - but with
        //  nothing driving at all the mixer output is 0 and the pads must sit
        //  at exactly 32. Check that first, before the speaker moves.
        // =================================================================
        // (spk_bit = 0 maps to -FS, so "no source at all" needs the tone off and
        //  is observed through the reset state; here we verify the tone-off,
        //  speaker-low steady state is the -FS rail and is static.)
        echochk = 1'b1;                        // CMT is off for all of this
        tickchk = 1'b1;

        // =================================================================
        //  the speaker: static rails, mono, both ladders
        // =================================================================
        apply_spk(1'b0);
        apply_spk(1'b1);
        apply_spk(1'b0);
        apply_spk(1'b1);
        apply_spk(1'b1);      // stays high (no spurious change)
        apply_spk(1'b0);

        if (dbg_clip !== 1'b0) begin
            $display("AUDIO-ERROR shaper clipped on the speaker path (must be impossible)");
            errors = errors + 1;
        end
        if (dbg_sat !== 1'b0) begin
            $display("AUDIO-ERROR mixer saturated on the speaker path alone");
            errors = errors + 1;
        end

        // =================================================================
        //  tone_en routing + TRUE STEREO
        // =================================================================
        // Tone off, speaker idle: both ladders static at the speaker's LOW
        // rail (code 24 = mid-scale 32 minus SPK_LVL/1024 = 8).
        tone_en = 1'b0;
        wait_ticks(8);
        #1 if (dac_l !== 6'd24 || dac_r_o !== 6'd24) begin
            $display("AUDIO-ERROR tone off: ladders not at the idle rail: l=%0d r=%0d",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end
        if (dbg_tone !== 1'b0) begin
            $display("AUDIO-ERROR dbg_tone set with tone_en low"); errors = errors + 1;
        end

        // =================================================================
        //  THE TURBOSOUND PAN ORIENTATION
        // =================================================================
        // ts_l MUST reach the LEFT ladder only and ts_r the RIGHT ladder only.
        // This is the link in the pan chain that nothing else covers:
        // bk_turbosound_tb proves channel A lands in ts_l and C in ts_r, and
        // audio_mixer_tb proves slot 3 is L-only and slot 4 is R-only, but only
        // THIS check proves bk_audio packs ts_l into slot 3 rather than slot 4.
        // Swap them and every oracle still passes while the board plays the
        // stereo image MIRRORED - inaudible as a fault, just wrong.
        //
        // The arithmetic is exact and static. The speaker is low (-8192), so
        // both ladders sit at code 24; adding +16384 to one side gives
        // -8192 + 16384 = 8192 = 8*1024 -> code 40, still a fixed point, so
        // the check is a plain compare with no settling window.
        spk_bit = 1'b0;
        ts_l = 16'sd0; ts_r = 16'sd0;
        wait_ticks(6);
        #1 if (dac_l !== 6'd24 || dac_r_o !== 6'd24) begin
            $display("AUDIO-ERROR pan: baseline not at the low rail: l=%0d r=%0d",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        ts_l = 16'sd16384; ts_r = 16'sd0;
        wait_ticks(6);
        #1 if (dac_l !== 6'd40 || dac_r_o !== 6'd24) begin
            $display("AUDIO-ERROR pan: ts_l did not land LEFT-ONLY (l=%0d r=%0d, expected 40/24)",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        ts_l = 16'sd0; ts_r = 16'sd16384;
        wait_ticks(6);
        #1 if (dac_l !== 6'd24 || dac_r_o !== 6'd40) begin
            $display("AUDIO-ERROR pan: ts_r did not land RIGHT-ONLY (l=%0d r=%0d, expected 24/40)",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        // both together: the two sides move independently, not as a mono sum
        ts_l = 16'sd16384; ts_r = 16'sd16384;
        wait_ticks(6);
        #1 if (dac_l !== 6'd40 || dac_r_o !== 6'd40) begin
            $display("AUDIO-ERROR pan: both slots together gave l=%0d r=%0d, expected 40/40",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end
        ts_l = 16'sd0; ts_r = 16'sd0;
        wait_ticks(4);

        // =================================================================
        //  THE COVOX PAN ORIENTATION, ITS GAIN, AND ITS MUTE
        // =================================================================
        // Same argument as the TurboSound pan above: bk_covox_tb proves the
        // low byte lands in cx_l and the high byte in cx_r, audio_mixer_tb
        // proves slot 5 is L-only and slot 6 R-only, and only THIS check
        // proves bk_audio packs cx_l into slot 5 rather than slot 6.
        //
        // It pins the GAIN at the same time, which nothing else does. The
        // Covox slots run at 5/8 (the device emits BkEmu's raw +/-32767 map),
        // so +16384 contributes (16384*5)>>3 = 10240 = 10*1024 exactly.
        // Against the speaker's low rail: -8192 + 10240 = 2048 = 2*1024 ->
        // code 34, still an audio_ns6 fixed point, so this is a plain compare
        // with no settling window. At the wrong gain the code is not 34: 8/8
        // would give 40, 4/8 would give 32.
        cx_en = 1'b1;
        cx_l = 16'sd16384; cx_r = 16'sd0;
        wait_ticks(6);
        #1 if (dac_l !== 6'd34 || dac_r_o !== 6'd24) begin
            $display("AUDIO-ERROR covox: cx_l did not land LEFT-ONLY at 5/8 (l=%0d r=%0d, expected 34/24)",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        cx_l = 16'sd0; cx_r = 16'sd16384;
        wait_ticks(6);
        #1 if (dac_l !== 6'd24 || dac_r_o !== 6'd34) begin
            $display("AUDIO-ERROR covox: cx_r did not land RIGHT-ONLY at 5/8 (l=%0d r=%0d, expected 24/34)",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        cx_l = 16'sd16384; cx_r = 16'sd16384;
        wait_ticks(6);
        #1 if (dac_l !== 6'd34 || dac_r_o !== 6'd34) begin
            $display("AUDIO-ERROR covox: both slots gave l=%0d r=%0d, expected 34/34",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        // THE MUTE. cx_en is bk_covox's only mute mechanism - the device
        // keeps presenting its sample while muted (one gate, not two), so if
        // this enable is not wired into slot_en the Covox can never be
        // silenced and the PSG arbitration does nothing at all.
        cx_en = 1'b0;
        wait_ticks(6);
        #1 if (dac_l !== 6'd24 || dac_r_o !== 6'd24) begin
            $display("AUDIO-ERROR covox: cx_en=0 did not zero the slots (l=%0d r=%0d, expected 24/24)",
                     dac_l, dac_r_o);
            errors = errors + 1;
        end

        // THE RE-OPENED GAIN BUDGET. The Covox at its bound plus the speaker
        // at its high rail must not saturate or clip:
        //    32767*5/8 = 20479, + 8192 = 28671 <= FS_SAT = 31744.
        // Then the OTHER worst case, the TurboSound one, with the Covox muted
        // as bk_covox guarantees it will be: 22950 + 8192 = 31142 <= 31744.
        // The illegal third case - both devices at once - cannot occur,
        // because bk_covox mutes on bk_turbosound's ts_snd; that exclusion is
        // the device's job (sim/covox section 6), not the mixer's, and this
        // comment is here so nobody "fixes" the budget by trusting the
        // saturator instead.
        spk_bit = 1'b1;
        cx_en = 1'b1;
        cx_l = 16'sd32767; cx_r = 16'sd32767;
        wait_ticks(8);
        cx_en = 1'b0; cx_l = 16'sd0; cx_r = 16'sd0;
        ts_l = 16'sd22950; ts_r = 16'sd22950;
        wait_ticks(8);
        ts_l = 16'sd0; ts_r = 16'sd0;
        spk_bit = 1'b0;
        wait_ticks(4);
        if (dbg_sat !== 1'b0) begin
            $display("AUDIO-ERROR the re-opened gain budget saturated the mixer");
            errors = errors + 1;
        end
        if (dbg_clip !== 1'b0) begin
            $display("AUDIO-ERROR the re-opened gain budget clipped a shaper");
            errors = errors + 1;
        end

        // Tone on: the codes must MOVE, and the two ladders must DIFFER (voice A
        // is panned BOTH, voice B RIGHT-only - so a mono path cannot pass this).
        tone_en = 1'b1;
        tickchk = 1'b0;        // the tone changes the mixer input continuously
        wait_ticks(4);
        moved_l = 0; moved_r = 0; differed = 0;
        #1 prev_l = dac_l; prev_r = dac_r_o;
        for (k = 0; k < 4000; k = k + 1) begin
            wait_ticks(1);
            #1;
            if (dac_l   !== prev_l)  moved_l  = moved_l + 1;
            if (dac_r_o !== prev_r)  moved_r  = moved_r + 1;
            if (dac_l   !== dac_r_o) differed = differed + 1;
            prev_l = dac_l; prev_r = dac_r_o;
        end
        if (moved_l < 10 || moved_r < 10) begin
            $display("AUDIO-ERROR tone on but ladders barely move: l=%0d r=%0d changes",
                     moved_l, moved_r);
            errors = errors + 1;
        end
        if (differed < 100) begin
            $display("AUDIO-ERROR no true stereo: ladders differed on only %0d of 4000 ticks",
                     differed);
            errors = errors + 1;
        end
        if (dbg_tone !== 1'b1) begin
            $display("AUDIO-ERROR dbg_tone clear with tone_en high"); errors = errors + 1;
        end
        // the tone is inside the gain budget: it must never saturate or clip
        if (dbg_sat !== 1'b0 || dbg_clip !== 1'b0) begin
            $display("AUDIO-ERROR self-test tone overflows the path: sat=%b clip=%b",
                     dbg_sat, dbg_clip);
            errors = errors + 1;
        end

        // =================================================================
        //  the 6 dB staircase actually attenuates
        // =================================================================
        // Voice B is the ONLY right-panned source, so (dac_r_o - dac_l) isolates
        // it exactly - much sharper than an absolute peak, since voice A sits on
        // both ladders and does not attenuate. Measure the isolated swing at the
        // loudest step and at a late, sub-ladder-step one. This is the by-ear
        // demo made checkable, and the late steps are BELOW one ladder step,
        // which is what a plain 6-bit path could not render at all.
        meas_swing(3'd0, amp_seen_hi);   // 16384 = 16 ladder steps
        meas_swing(3'd5, amp_seen_lo);   //   512 = half a ladder step
        $display("staircase: R-L swing %0d codes at step 0, %0d codes at step 5",
                 amp_seen_hi, amp_seen_lo);
        if (amp_seen_hi < 8) begin
            $display("AUDIO-ERROR staircase step 0 too quiet: only %0d codes of R-L swing",
                     amp_seen_hi);
            errors = errors + 1;
        end
        // five 6 dB steps is a factor of 32; require at least 4x to leave room
        // for the shapers' +/-1 code of independent dither on the two ladders.
        if (!(amp_seen_lo * 4 < amp_seen_hi)) begin
            $display("AUDIO-ERROR staircase does not attenuate: R-L swing %0d then %0d",
                     amp_seen_hi, amp_seen_lo);
            errors = errors + 1;
        end

        tone_en = 1'b0;
        wait_ticks(8);

        // =================================================================
        //  CMT mode: the right channel becomes the comparator network
        // =================================================================
        echochk  = 1'b0;
        spk_bit  = 1'b0;
        ext_lvl  = 1'b0;
        cmt_mode = 1'b1;
        wait_ticks(4);
        #1 check_cmt(1'b0, 1'b0);
        // tape signal rises: tape_lvl follows through the 2-FF sync and the
        // feedback bits [3:2] flip with it
        ext_lvl = 1'b1;
        wait_ticks(4);
        #1 check_cmt(1'b1, 1'b0);
        // CmtOut carries the RAW speaker level (BK tape-out IS bit 6)
        spk_bit = 1'b1;
        wait_ticks(4);
        #1 check_cmt(1'b1, 1'b1);
        ext_lvl = 1'b0;
        wait_ticks(4);
        #1 check_cmt(1'b0, 1'b1);

        // the left ladder still carries audio in CMT mode - now the MONO FOLD.
        // The speaker is panned BOTH, so mix_l == mix_r and the fold is a no-op
        // for it: the left ladder must still sit at the speaker's rail.
        #1 if (dac_l !== 6'd40) begin
            $display("AUDIO-ERROR CMT-mode left ladder lost the speaker: %0d", dac_l);
            errors = errors + 1;
        end

        // TAPE-OUT IS A DATA SIGNAL: with the tone running (a non-trivial mixer
        // output) dac_r_o[0] must still be the raw speaker bit, not a shaped
        // sample bit. Without this the check could pass against a silent mixer.
        tone_en = 1'b1;
        wait_ticks(200);
        for (k = 0; k < 400; k = k + 1) begin
            wait_ticks(1);
            #1 if (dac_r_o[0] !== 1'b1) begin       // spk_bit is still 1
                $display("AUDIO-ERROR CMT tape-out is not the raw speaker bit (got %b)",
                         dac_r_o[0]);
                errors = errors + 1;
                k = 400;
            end
            if (dac_r_oe !== 6'b001111) begin
                $display("AUDIO-ERROR CMT oe disturbed by the tone: %b", dac_r_oe);
                errors = errors + 1;
                k = 400;
            end
        end
        spk_bit = 1'b0;
        wait_ticks(4);
        #1 if (dac_r_o[0] !== 1'b0) begin
            $display("AUDIO-ERROR CMT tape-out did not follow the speaker low");
            errors = errors + 1;
        end
        tone_en = 1'b0;

        // the CMT-mode left ladder is the MONO FOLD of both channels: with the
        // tone off and the speaker low it is the speaker's low rail again
        wait_ticks(8);
        #1 if (dac_l !== 6'd24) begin
            $display("AUDIO-ERROR CMT mono fold wrong at idle: %0d", dac_l);
            errors = errors + 1;
        end

        // =================================================================
        //  back to audio mode: mono returns, tape_lvl forced 0
        // =================================================================
        cmt_mode = 1'b0;
        wait_ticks(4);
        echochk = 1'b1;              // now watched on every cycle
        apply_spk(1'b0);
        apply_spk(1'b1);
        apply_spk(1'b0);

        // =================================================================
        //  activity indicator
        // =================================================================
        for (k = 0; k < 8; k = k + 1) begin
            spk_bit = k[0];
            repeat (8) @(posedge sys_clk);
        end
        #1 if (active !== 1'b1) begin
            $display("AUDIO-ERROR active low while toggling"); errors = errors + 1;
        end
        spk_bit = 1'b0;
        repeat (20'hFFFFF + 100) @(posedge sys_clk);
        #1 if (active !== 1'b0) begin
            $display("AUDIO-ERROR active stuck high when idle"); errors = errors + 1;
        end

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
