// ============================================================================
//  bk_audio - BK 1-bit speaker -> board R-2R sound DAC
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
//  DAC drive: PUSH-PULL, all 6 bits, mono (same sample on both channels),
//  centred on mid-scale - the board-proven scheme from ocb-test/audio_test.sv
//  (which produces an audible 1 kHz tone on this exact board). The speaker level
//  maps to a full-swing code (0 <-> 63) and idle/reset holds mid-scale (32) so
//  there is no DC step/click. NOTE: an earlier version used the esemsx3
//  tri-stated {lvl,4'bZ,lvl} pattern - that is for esemsx3's 21 MHz sigma-delta
//  bitstream and produced NO sound here; drive all six taps push-pull instead.
//
//  FORWARD SEAM (Covox / higher fidelity, deferred): to add the 8-bit Covox DAC
//  feed a real 6-bit sample in place of the 1-bit level, or a sigma-delta stream
//  (see esemsx3 src/sound/dac/esepwm.vhd). Left mono here.
// ============================================================================
module bk_audio (
    input  logic       sys_clk,   // 96.65 MHz fabric clock
    input  logic       rst_n,     // power-on reset (active low)
    input  logic       spk_bit,   // BK speaker level (cpu_clk domain)
    output logic [5:0]  dac_l,     // pDac_SL  (Sound-L)
    output logic [5:0]  dac_r,     // pDac_SR  (Sound-R, mono copy)
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

    // Push-pull full-swing DAC code; mid-scale (32) while idle/reset.
    wire [5:0] sample = spk_sync ? 6'd63 : 6'd0;
    assign dac_l = rst_n ? sample : 6'd32;
    assign dac_r = rst_n ? sample : 6'd32;

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
