// ============================================================================
//  bk_audio - the BK audio subsystem: sources -> mixer -> noise-shaped DAC
// ----------------------------------------------------------------------------
//  This module is the ASSEMBLY. It owns the BK-machine-specific part (the 1-bit
//  speaker: its CDC, its level-to-sample map and the activity LED one-shot) and
//  the SLOT MAP, then wires the generic infrastructure together:
//
//      spk_bit ---> slot 0 -+
//      audio_tone -> 1, 2 --+--> audio_mixer --> audio_out --> pDac_SL/SR
//                                (stereo, sat)     (2x audio_ns6, CMT jack)
//
//  Naming convention for src/audio/: audio_* is generic infrastructure,
//  bk_* is BK-machine-specific (the bk_kbd014 / bk_evnt / bk_rply precedent).
//  Future 177714 sound devices (bk_covox, bk_ay wrapping the vendored
//  MiSTer ym2149.sv, bk_menestrel) belong in src/peripheral/ - they are bus
//  peripherals that snoop and emit samples - and arrive here as extra packed
//  slot inputs, not as logic inside this file.
//
//  THE SPEAKER. The BK-0010 built-in speaker is a single output bit (bit 6 of
//  register 177716, captured in qbus_mem as spk_bit); software toggles it at
//  audio rates. It is produced in the CPU-clock domain and is quasi-static
//  relative to sys_clk, so a plain 2-FF synchronizer suffices - the same
//  pattern as key_scrmode -> screen_mode. It enters the mixer as a full-scale
//  square (+/-31744), which audio_ns6 turns into a STATIC code 63 or 1.
//
//  NOTE THE ONE-CODE TRIM: before the rework the speaker drove codes 63/0; it
//  now drives 63/1, because the mixer saturates at 31744 rather than 32767 to
//  keep audio_ns6 provably clip-free. That is 0.14 dB, it is deliberate, and it
//  is the ONLY change to how the speaker sounds - the code is still static, with
//  no shaping activity, so the one audio feature that is confirmed working on
//  hardware cannot be regressed by any of this. bk_audio_tb pins 63/1 and pins
//  that they are static.
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
    // The DIP-5 self-test source. Set to 0 to reclaim ~130 LE in a fit/STA
    // emergency; the audio path itself is unaffected (the tone slots then hold
    // a constant zero and fold away entirely).
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

    // ---- slot map -----------------------------------------------------------
    //   0 = BK speaker      BOTH
    //   1 = self-test A     BOTH   (440 Hz reference tone)
    //   2 = self-test B     RIGHT  (1567 Hz, the 6 dB staircase)
    // Growth path for the device increments (audio_mixer_tb proves NSRC=10):
    //   3 = AY chan A  L | 4 = AY chan B BOTH | 5 = AY chan C R
    //   6 = Covox L    L | 7 = Covox R    R
    //   8 = Menestrel L L | 9 = Menestrel R R
    localparam int NSRC = 3;
    localparam [NSRC*4-1:0] SLOT_GAIN = 12'h888;         // all at 8/8
    localparam [NSRC*2-1:0] SLOT_PAN  = 6'b01_11_11;     // BOTH, BOTH, R-only

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

    wire signed [15:0] spk_sample = spk_sync ? FS_SAT : -FS_SAT;

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

    wire [NSRC*16-1:0] slot_src = {voice_b, voice_a, spk_sample};

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
    // WHEN THE REAL DEVICES LAND they arrive here the same way (the AY tied
    // live, Covox and Menestrel driven by the PS/2 radial-toggle select) - and
    // they will need this same conversation: the speaker's 8/8 gain has to come
    // down (MiSTer's answer is 1/4) so a device and the speaker can sound
    // together. That is a per-device loudness decision, so it belongs in the
    // increment that adds the first device, not here.
    wire [NSRC-1:0]    slot_en  = {tone_live, tone_live, ~tone_live};

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
