// ============================================================================
//  bk_audio - BK 1-bit speaker -> board R-2R sound DAC, plus the CMT jack
// ----------------------------------------------------------------------------
//  The BK-0010 built-in speaker is a single output bit (bit 6 of register
//  177716; captured in qbus_mem as spk_bit). Software toggles it at audio
//  rates and the board's analog stage (RC low-pass + amp) turns the square wave
//  into a tone - so no oversampling/PWM is needed for the 1-bit source: we drive
//  the speaker level straight onto the R-2R ladder.
//
//  spk_bit is produced in the CPU-clock (FSM) domain and is quasi-static
//  relative to sys_clk (it changes at most every few CPU cycles), so a plain
//  2-FF synchronizer is sufficient - same pattern as key_scrmode -> screen_mode.
//
//  DAC drive for AUDIO: PUSH-PULL, all 6 bits, mono (same sample on both
//  channels), centred on mid-scale - the board-proven scheme from
//  ocb-test/audio_test.sv (which produces an audible 1 kHz tone on this exact
//  board). The speaker level maps to a full-swing code (0 <-> 63) and
//  idle/reset holds mid-scale (32) so there is no DC step/click. NOTE: an
//  earlier version used the esemsx3 tri-stated {lvl,4'bZ,lvl} pattern for
//  audio - that is for esemsx3's 21 MHz sigma-delta bitstream and produced NO
//  sound here; drive all six taps push-pull for audio.
//
//  CMT (cassette) mode - the ONE intentional tri-state use of the ladder,
//  esemsx3's board-proven Cassette Magnetic Tape trick (emsx_top.vhd, the
//  CmtScro block): while cmt_mode is on (the PS/2 Scroll Lock toggle in the
//  top - the same key esemsx3 uses; gating on the 177716 motor bit was tried
//  first but real BK software writes bit 7 = 0 outside tape ops and wrongly
//  killed the right audio channel), the right-channel ladder becomes a
//  comparator at the jack:
//    dac_r[5] = Z            <- CMT INPUT pad, sampled below
//    dac_r[4] = Z
//    dac_r[3] = tape_lvl     \  positive feedback through the R-2R resistors
//    dac_r[2] = ~tape_lvl    /  = a Schmitt trigger biased at the threshold
//    dac_r[1] = 0
//    dac_r[0] = spk level    <- CMT OUTPUT (BK tape-out IS bit 6; lets the BK
//                               record to a PC through the same jack)
//  The registered sample (tape_lvl) both closes the feedback loop and goes to
//  the CPU as 177716 read bit 5 (2-FF resynced onto cpu_clk in the top).
//  esemsx3 samples with one FF at 21 MHz; two FFs here add ~20 ns loop lag -
//  negligible against the ~1 kHz tape half-periods. The left channel stays
//  audio in both modes.
//
//  FORWARD SEAM (Covox / higher fidelity, deferred): to add the 8-bit Covox DAC
//  feed a real 6-bit sample in place of the 1-bit level, or a sigma-delta stream
//  (see esemsx3 src/sound/dac/esepwm.vhd). Left mono here. Tape-out fidelity:
//  a real BK mixes write bits 6 AND 5 resistively into a 3-level record
//  waveform (d6.mac KBIT01/KBIT11); bit 6 alone is the dominant component.
// ============================================================================
module bk_audio (
    input  logic       sys_clk,   // 96.65 MHz fabric clock
    input  logic       rst_n,     // power-on reset (active low)
    input  logic       spk_bit,   // BK speaker level (cpu_clk domain)
    input  logic       cmt_mode,  // 1 = motor running: right channel is the CMT jack
    input  logic       cmt_in_pad,// raw pDac_SR[5] pad value (async)
    output logic       tape_lvl,  // registered CMT comparator level (sys_clk)
    output logic [5:0]  dac_l,     // pDac_SL  (Sound-L)
    output logic [5:0]  dac_r_o,   // pDac_SR data (right channel / CMT network)
    output logic [5:0]  dac_r_oe,  // pDac_SR per-bit output enables
    output logic        active     // 1 = speaker toggled recently (LED tap)
);
    // 2-FF resync of the CPU-domain speaker bit into sys_clk.
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

    // 2-FF sample of the CMT input pad; tape_lvl closes the Schmitt feedback
    // and feeds the 177716 bit-5 read path. Forced 0 while CMT mode is off
    // (esemsx3 does the same: "CMT data input is always '0'" when disabled) -
    // otherwise the audio push-pull drive on the same pad would echo the
    // speaker level into the tape-in bit.
    logic cmt_meta;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            cmt_meta <= 1'b0;
            tape_lvl <= 1'b0;
        end else begin
            cmt_meta <= cmt_in_pad;
            tape_lvl <= cmt_mode ? cmt_meta : 1'b0;
        end
    end

    // Push-pull full-swing DAC code; mid-scale (32) while idle/reset.
    wire [5:0] sample = spk_sync ? 6'd63 : 6'd0;
    assign dac_l = rst_n ? sample : 6'd32;

    // Right channel: audio mono copy, or the CMT comparator network.
    always_comb begin
        if (rst_n && cmt_mode) begin
            dac_r_o  = {2'b00, tape_lvl, ~tape_lvl, 1'b0, spk_sync};
            dac_r_oe = 6'b001111;
        end else begin
            dac_r_o  = rst_n ? sample : 6'd32;
            dac_r_oe = 6'b111111;
        end
    end

    // Speaker-activity indicator: any spk edge reloads a ~11 ms one-shot, so the
    // LED sits solid on while a tone plays and dark when the speaker is idle.
    // (Observability for the audio-path bring-up - proves the 177716-bit-6
    // capture is toggling independent of the analog stage.)
    logic [19:0] act_cnt;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)                     act_cnt <= 20'd0;
        else if (spk_sync ^ spk_sync_d) act_cnt <= 20'hFFFFF;   // edge: reload
        else if (act_cnt != 0)          act_cnt <= act_cnt - 1'b1;
    end
    assign active = (act_cnt != 0);

endmodule
