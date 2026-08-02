// ============================================================================
//  bk_audio - the BK audio subsystem: sources -> mixer -> noise-shaped DAC
// ----------------------------------------------------------------------------
//  This module is the assembly. It owns the BK-machine-specific part (the 1-bit
//  speaker: its CDC, its level-to-sample map and the activity LED one-shot) and
//  the slot map, then wires the generic infrastructure together:
//
//      spk_bit -------> slot 0 -+
//      audio_tone ----> 1, 2 ---+
//      bk_turbosound -> 3, 4 ---+--> audio_mixer --> audio_out --> pDac_SL/SR
//      bk_covox ------> 5, 6 ---+     (stereo, sat)   (2x audio_ns6, CMT jack)
//
//  The BK-0010 built-in speaker is a single output bit (bit 6 of register 177716,
//  captured in qbus_mem as spk_bit); software toggles it at audio rates.
//
//  Reset is power-on only (ocbk_top passes vid_rst_n): sound survives a warm
//  reset, like the display. Both ladders hold mid-scale (code 32) while reset is
//  asserted so there is no DC step or click.
// ============================================================================
module bk_audio #(
    parameter int RATE_DIV    = 16,      // sys_clk/RATE_DIV = the DAC update rate
    // Self-test source enable.
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

    // The speaker rail.
    localparam signed [15:0] SPK_LVL = 16'sd8192;

    // ---- slot map -----------------------------------------------------------
    //   0 = BK speaker      BOTH   (+/-8192)
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

    // The self-test owns the output when DIP 5 is on: it mutes the
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
