// ============================================================================
//  bk_audio - the BK audio subsystem: sources -> mixer -> noise-shaped DAC
// ----------------------------------------------------------------------------
//  This module is the ASSEMBLY. It owns the BK-machine-specific part (the 1-bit
//  speaker: its CDC, its level-to-sample map and the activity LED one-shot) and
//  the SLOT MAP, then wires the generic infrastructure together:
//
//      spk_bit -------> slot 0 -+
//      audio_tone ----> 1, 2 ---+
//      bk_turbosound -> 3, 4 ---+--> audio_mixer --> audio_out --> pDac_SL/SR
//      bk_covox ------> 5, 6 ---+     (stereo, sat)   (2x audio_ns6, CMT jack)
//
//  Naming convention for src/audio/: audio_* is generic infrastructure,
//  bk_* is BK-machine-specific (the bk_kbd014 / bk_evnt / bk_rply precedent).
//  SOUND DEVICES LIVE IN src/audio/ TOO (bk_turbosound.sv and the ym2149.sv it
//  vendors, bk_covox.sv; bk_menestrel when it lands) - src/peripheral/ is for
//  NON-audio bus peripherals. They are instantiated as ocbk_top siblings that
//  snoop the 177714 seam, and arrive HERE as extra packed slot inputs, never as
//  logic inside this file.
//
//  THE SPEAKER. The BK-0010 built-in speaker is a single output bit (bit 6 of
//  register 177716, captured in qbus_mem as spk_bit); software toggles it at
//  audio rates. It is produced in the CPU-clock domain and is quasi-static
//  relative to sys_clk, so a plain 2-FF synchronizer suffices - the same
//  pattern as key_scrmode -> screen_mode. It enters the mixer as a square at
//  +/-SPK_LVL, which audio_ns6 turns into a STATIC code (see the next note).
//
//  THE SPEAKER IS DUCKED, and this is the one user-audible change the
//  TurboSound increment makes to an otherwise untouched feature. It used to
//  run at full scale (+/-31744, codes 63/1); it now runs at SPK_LVL =
//  +/-8192, codes 40/24, i.e. ~11.8 dB quieter. The reason is the gain
//  budget: a full-scale speaker uses the ENTIRE headroom by itself, so
//  anything sounding alongside it saturates. MiSTer hits the same wall and
//  answers the same way (BK0011M.sv: spk_out<<7 alone, but spk_out<<5 with
//  the PSG live). We duck unconditionally rather than gating on "a PSG
//  channel is enabled", so the speaker's loudness never jumps mid-program.
//
//  8192 IS NOT AN ARBITRARY QUARTER. It is 8*1024 EXACTLY, which is what
//  keeps the speaker on a STATIC audio_ns6 code with no shaping activity -
//  the structural property that makes the one hardware-confirmed audio
//  feature immune to everything else in this path. Work it through
//  audio_ns6: errp resets to 512, accr = 8192 + 512, q = 8, code = 40, and
//  errn = 512 again, so it is a fixed point. A literal quarter of 31744
//  would be 7936 = 7.75*1024, which is NOT a fixed point and would make the
//  shaper rattle between codes on a signal that used to be silent between
//  edges. bk_audio_tb pins 40/24 and pins that they are static.
//
//  Bit 6 only is the BkEmu Speaker contract for a BK-0010 (MiSTer's extra
//  spk_out bits are its tape-monitor mixing, not register semantics) - that
//  decision lives in qbus_mem, not here.
//
//  WHY THE 6-BIT LADDER IS DRIVEN IN FULL rather than as a 1-bit stream on two
//  taps, since this comment has been wrong before: esemsx3 drives a 1-bit
//  sigma-delta bitstream (src/sound/dac/esepwm.vhd, ~21 MHz) onto pDac taps 5
//  and 0 only, Hi-Z'ing 4:1, and ON ITS OWN FIRMWARE THAT WORKS AND SOUNDS
//  FINE. It is not a broken scheme and it is NOT silent on this board. What was
//  silent was ocbk's earlier attempt at the same pin pattern, because it fed
//  those two taps an audio-rate 1-bit LEVEL instead of a modulated bitstream -
//  two taps have nothing to average. That was a bug in the reproduction, not a
//  property of the hardware. We use the whole ladder for a positive reason: the
//  OneChipBook schematic gives us a real 6-bit WEIGHTED R-2R network (see
//  ocb-test), so a 6-bit quantizer starts ~30 dB ahead of a 1-bit one at equal
//  oversampling and needs 16x less of it.
//
//  RESET is power-on only (ocbk_top passes vid_rst_n): sound survives a warm
//  reset, like the display. Both ladders hold mid-scale (code 32) while reset is
//  asserted so there is no DC step or click.
// ============================================================================
module bk_audio #(
    parameter int RATE_DIV    = 16,      // sys_clk/RATE_DIV = the DAC update rate
    // The DIP-5 self-test source. MEASURED: setting this to 0 reclaims
    // 355 LE (7,357 -> 7,002 on 2026-07-31) - the two DDS voices and the
    // staircase shifter, plus mixer slots 1-2 and their adder trees folding
    // away with them. An earlier note here guessed ~130; it was wrong.
    // The audio path itself is unaffected (the tone slots hold constant zero).
    // The SHIPPED build sets this to 0: the self-test was a diagnostic, it
    // did its job (the resolution claim is measured and confirmed), and a
    // debug feature does not ship. Set it back to 1 for a diagnostic
    // firmware - that one token is the whole difference.
    parameter bit TONE_ENABLE = 1'b1,
    // Staircase dwell for the self-test, 2^N sys_clk. Only the testbench should
    // ever shorten this.
    parameter int TONE_STEP_BITS = 26
) (
    input  logic       sys_clk,     // 96.65 MHz fabric clock
    input  logic       rst_n,       // power-on reset (active low)
    input  logic       spk_bit,     // BK speaker level (cpu_clk domain)
    input  logic       cmt_mode,    // 1 = CMT mode (DIP 4): right channel is the jack
    input  logic       cmt_in_pad,  // raw pDac_SR[5] pad value (async)
    input  logic       tone_en,     // 1 = audio self-test tone (DIP 5, live)
    input  logic signed [15:0] ts_l,   // bk_turbosound, already ACB-folded
    input  logic signed [15:0] ts_r,   //   (unipolar 0..22950)
    input  logic signed [15:0] cx_l,   // bk_covox, BkEmu scale (+/-32767)
    input  logic signed [15:0] cx_r,   //   scaled to fit by SLOT_GAIN, below
    input  logic               cx_en,  // bk_covox's mute: 0 = slot is zeroed
    output logic       tape_lvl,    // registered CMT comparator level (sys_clk)
    output logic [5:0] dac_l,       // pDac_SL  (Sound-L)
    output logic [5:0] dac_r_o,     // pDac_SR data (right channel / CMT network)
    output logic [5:0] dac_r_oe,    // pDac_SR per-bit output enables
    output logic       active,      // 1 = speaker toggled recently (pLed[0])
    output logic       dbg_sat,     // sticky: the mixer saturated  (pLed[1])
    output logic       dbg_clip,    // sticky: a shaper clipped     (pLed[2])
    output logic       dbg_tone     // 1 = the self-test tone is live (pLed[3])
);
    // Full scale = the mixer's saturation bound = audio_ns6's clip-free limit.
    localparam signed [15:0] FS_SAT = 16'sd31744;

    // The ducked speaker rail. 8*1024 exactly - see the header for why that
    // matters and why a literal FS_SAT/4 would not do.
    localparam signed [15:0] SPK_LVL = 16'sd8192;

    // ---- slot map -----------------------------------------------------------
    //   0 = BK speaker      BOTH   (+/-8192, ducked)
    //   1 = self-test A     BOTH   (440 Hz reference tone)
    //   2 = self-test B     RIGHT  (1567 Hz, the 6 dB staircase)
    //   3 = TurboSound L    LEFT   (bk_turbosound, 2x YM2149, ACB-folded)
    //   4 = TurboSound R    RIGHT
    //   5 = Covox L         LEFT   (bk_covox, BkEmu scale, gain 5/8)
    //   6 = Covox R         RIGHT
    // Growth path for the remaining device (audio_mixer_tb proves NSRC=10):
    //   7 = Menestrel L L | 8 = Menestrel R R
    //
    // At the shipped TONE_ENABLE = 0 slots 1 and 2 are constant zero with a
    // constant-zero enable, so they and their adder terms fold away entirely
    // - they cost nothing and keep a diagnostic firmware buildable. That
    // leaves FIVE live slots, so the mixer's stage-1 sum stays at tree depth
    // 3, inside the "fine to ~6 slots at 96.65 MHz" note in its header - and
    // because the pans are compile-time constants, each SIDE only sums three
    // terms.
    localparam int NSRC = 7;
    // THE COVOX SCALE LIVES HERE, not in bk_covox. The device emits BkEmu's
    // own +/-32767 map verbatim (audio_mixer's sample domain exists precisely
    // so it can), and 5/8 is what fits it under the speaker - see the gain
    // budget below for why 5 is provably the largest legal value.
    //                                   6  5  4  3  2  1  0
    localparam [NSRC*4-1:0] SLOT_GAIN = 28'h5_5_8_8_8_8_8;
    localparam [NSRC*2-1:0] SLOT_PAN  = 14'b01_10_01_10_01_11_11;

    // ---- speaker: 2-FF resync (+1 delay for the activity edge detect) -------
    logic spk_meta, spk_sync, spk_sync_d;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            spk_meta   <= 1'b0;
            spk_sync   <= 1'b0;
            spk_sync_d <= 1'b0;
        end else begin
            spk_meta   <= spk_bit;
            spk_sync   <= spk_meta;
            spk_sync_d <= spk_sync;
        end
    end

    wire signed [15:0] spk_sample = spk_sync ? SPK_LVL : -SPK_LVL;

    // ---- speaker-activity indicator -----------------------------------------
    // Any spk edge reloads a ~11 ms one-shot, so pLed[0] sits solid while a tone
    // plays and dark when the speaker is idle. Observability for audio bring-up:
    // it proves the 177716-bit-6 capture is toggling independently of the mixer,
    // the shaper and the analog stage.
    logic [19:0] act_cnt;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)                     act_cnt <= 20'd0;
        else if (spk_sync ^ spk_sync_d) act_cnt <= 20'hFFFFF;   // edge: reload
        else if (act_cnt != 0)          act_cnt <= act_cnt - 1'b1;
    end
    assign active = (act_cnt != 0);

    // ---- the self-test source ----------------------------------------------
    logic signed [15:0] voice_a, voice_b;
    generate
        if (TONE_ENABLE) begin : g_tone
            audio_tone #(.STEP_BITS (TONE_STEP_BITS)) u_tone (
                .sys_clk (sys_clk),
                .rst_n   (rst_n),
                .en      (tone_en),
                .voice_a (voice_a),
                .voice_b (voice_b),
                .step    ()
            );
            assign dbg_tone = tone_en;
        end else begin : g_no_tone
            assign voice_a  = 16'sd0;
            assign voice_b  = 16'sd0;
            assign dbg_tone = 1'b0;
        end
    endgenerate

    // ---- mix ----------------------------------------------------------------
    wire tone_live = tone_en & TONE_ENABLE;

    wire [NSRC*16-1:0] slot_src = {cx_r, cx_l, ts_r, ts_l,
                                   voice_b, voice_a, spk_sample};

    // THE GAIN BUDGET, and why the self-test MUTES the speaker.
    //
    // The speaker is a 1-bit source at FULL SCALE (+/-31744): by itself it uses
    // the entire headroom, so ANY second source live at the same time saturates
    // the mixer. That is not a tb artifact - it is what the arithmetic says, and
    // MiSTer hits it too, which is why it scales the BK speaker down when its
    // PSG is active (BK0011M.sv: spk_out<<7 alone, but spk_out<<5 with the PSG).
    //
    // For the self-test the right answer is that the diagnostic OWNS the output
    // while it runs: DIP 5 mutes the speaker slot. Two reasons beyond the
    // arithmetic - a saturating mix clips audibly and would put clipping
    // products into the very FFT the tone exists to enable, and a tone
    // uncontaminated by a BK square wave is what makes the recorded measurement
    // readable. pLed[3] says the mode is on, so a DIP 5 left on by accident is
    // diagnosable rather than mysterious.
    //
    // With the speaker muted the budget closes by construction: voice A is
    // +/-8192 (BOTH) and voice B at most +/-16384 (RIGHT), so the worst channel
    // sum is 24576 < 31744 and neither the mixer nor the shapers can clip.
    // bk_audio_tb asserts dbg_sat and dbg_clip stay clear with the tone running.
    //
    // THE TURBOSOUND INCREMENT SETTLED THAT CONVERSATION for the speaker: it
    // is ducked to SPK_LVL unconditionally (see the header), which is what
    // buys the headroom for a device to sound alongside it. The budget closes
    // BY CONSTRUCTION rather than by trusting the saturator.
    //
    // THE COVOX INCREMENT RE-OPENED IT, as this comment used to say it would,
    // and closed it again for FREE - because Covox and the PSGs are MUTUALLY
    // EXCLUSIVE. They decode the same 0177714 address, so each renders the
    // other's traffic as garbage; bk_covox mutes itself whenever the PSGs are
    // emitting a non-zero sample (bk_turbosound's ts_snd), which arrives here
    // as cx_en. So the worst case is not a sum of the two:
    //
    //     speaker           +/- 8192
    //     TurboSound           0 .. 22950            (bk_turbosound's bound)
    //     Covox           -20480 .. +20479           (+/-32768 at gain 5/8)
    //     worst channel   max(22950, 20480) + 8192 = 31142  <=  FS_SAT = 31744
    //
    // - the SAME 31142 the TurboSound increment computed. Neither the mixer
    // nor the shapers can clip.
    //
    // WHY THE COVOX GAIN IS 5/8 AND NOT MORE: at 6/8 the bound would be 24576
    // and 24576 + 8192 = 32768 > FS_SAT, so 5 is the largest legal value.
    // 32768*5/8 = 20480 = 20*1024 exactly, so a Covox parked at a DC still
    // lands on a STATIC audio_ns6 code - the same property that makes SPK_LVL
    // a multiple of 1024, generalised. If either bound moves, redo this
    // arithmetic; pLed[1]/[2] lighting means it was got wrong. Menestrel will
    // have to re-open it once more, and it cannot rely on the same mutual
    // exclusion unless it mutes on ts_snd too.
    //
    // The self-test still OWNS the output when DIP 5 is on: it mutes the
    // speaker, the PSGs AND the Covox, so the acceptance FFT stays free of a
    // BK square wave and of whatever anything else was doing. (In a
    // TONE_ENABLE = 1 diagnostic build DIP 5 drives both the tone and the
    // Covox mono fold - harmless, precisely because the tone mutes the Covox.)
    wire [NSRC-1:0]    slot_en  = {cx_en & ~tone_live, cx_en & ~tone_live,
                                   ~tone_live, ~tone_live,
                                   tone_live, tone_live, ~tone_live};

    logic signed [15:0] mix_l, mix_r;

    audio_mixer #(
        .NSRC   (NSRC),
        .SW     (16),
        .FS_SAT (FS_SAT),
        .GAIN8  (SLOT_GAIN),
        .PAN    (SLOT_PAN)
    ) u_mixer (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .src     (slot_src),
        .src_en  (slot_en),
        .mix_l   (mix_l),
        .mix_r   (mix_r),
        .dbg_sat (dbg_sat)
    );

    // ---- shape and drive the pads ------------------------------------------
    audio_out #(.RATE_DIV (RATE_DIV)) u_out (
        .sys_clk    (sys_clk),
        .rst_n      (rst_n),
        .mix_l      (mix_l),
        .mix_r      (mix_r),
        .cmt_mode   (cmt_mode),
        .cmt_in_pad (cmt_in_pad),
        .spk_raw    (spk_sync),        // CMT tape-out: the RAW bit, never audio
        .tape_lvl   (tape_lvl),
        .dac_l      (dac_l),
        .dac_r_o    (dac_r_o),
        .dac_r_oe   (dac_r_oe),
        .dbg_clip   (dbg_clip)
    );

endmodule
