// ============================================================================
//  audio_tone - the DIP-5 audio self-test source (two DDS voices)
// ----------------------------------------------------------------------------
//  WHY THIS EXISTS. The audio rework's central claim is that the 6-bit ladder
//  now carries far more than 6 bits of audio-band resolution. But the only real
//  source in the machine is the BK's 1-bit speaker, which maps to the two rails
//  and therefore comes out of audio_ns6 as a STATIC code 63/1 with no shaping
//  activity at all. That is the best possible regression story - the board
//  sounds exactly as it did - and it also means the new capability would be
//  entirely unexercised on hardware, with no way to confirm the claim. This
//  module is the fix: a stimulus that a 6-bit path CANNOT produce, enterable
//  from a DIP switch with no BK software and no bus device involved.
//
//  It is a DIAGNOSTIC, not a user feature, which is why it is a DIP and not a
//  PS/2 key: it works before the machine boots.
//
//  WHAT YOU HEAR (DIP 5 on):
//    Voice A - 440 Hz, FIXED amplitude, panned BOTH. The reference pitch.
//    Voice B - 1567 Hz (a G above), panned RIGHT ONLY, its amplitude stepping
//              DOWN 6 dB every ~0.7 s through 8 steps and then wrapping.
//
//  The staircase is the actual experiment. Amplitudes are 16384, 8192, ... 128
//  in the mixer's units, where ONE LADDER STEP IS 1024. So the last three steps
//  (512, 256, 128) are a half, a quarter and an eighth of one step - on a plain
//  6-bit truncating path they are silence, or at best a 1-bit rattle. Hearing
//  all eight steps at an even 6 dB spacing is the by-ear demonstration; the
//  quantitative version is a jack recording + FFT (sim/audio/README.md).
//
//  Because voice A is BOTH and voice B is RIGHT-ONLY, a working stereo path
//  sounds obviously different in the two channels - which also makes this the
//  by-ear check for the true-stereo half of the rework, and for the CMT mono
//  fold: flip DIP 4 while it plays and both voices collapse onto the left
//  ladder while the right becomes the tape jack.
//
//  WAVEFORM: triangle, taken straight from the phase accumulator's top bits -
//  no table, no M4K, and exact at any amplitude (a shift). A 64-entry 6-bit
//  sine table like ocb-test's audio_test.sv is deliberately NOT used here: a
//  6-bit-QUANTIZED stimulus would demonstrate nothing about resolution, being
//  exactly what the old path could already do. (That table is still the right
//  choice later for a spectrally clean THD/FFT stimulus - 49 M4Ks are free.)
//
//  All amplitudes and both voices' "0 dB" reference are powers of two, so
//  every level is a shift: no multipliers (the EP1C12 has none anyway).
// ============================================================================
module audio_tone #(
    // Staircase dwell = 2^STEP_BITS sys_clk. 26 -> ~0.69 s at 96.65 MHz.
    // The testbench overrides this to something tiny; nothing else should.
    parameter int STEP_BITS = 26
) (
    input  logic               sys_clk,
    input  logic               rst_n,     // async, active low (power-on only)
    input  logic               en,        // DIP 5, live: 1 = generate
    output logic signed [15:0] voice_a,   // 440 Hz,  fixed level, panned BOTH
    output logic signed [15:0] voice_b,   // 1567 Hz, staircase,   panned RIGHT
    output logic         [2:0] step       // current attenuation step (0 = loudest)
);
    // Phase increments for a 32-bit accumulator clocked at sys_clk:
    //     STEP = round(f * 2^32 / 96_647_715)
    //   440 Hz -> round(1.88979e12 / 96647715) = 19554  -> 440.015 Hz
    //  1567 Hz -> round(6.73022e12 / 96647715) = 69637  -> 1567.010 Hz
    // (STEP_B read 69658 in the first build - a transposition, not the rounding
    // this comment describes; it put voice B at 1567.483 Hz, 0.52 cents sharp.
    // Inaudible, and it does not touch the staircase measurement, which is a
    // ratio at a single frequency - but the 2026-07-31 jack recording analysed
    // in sim/audio/README.md was made with the old value and its voice B reads
    // 1567.44 Hz. Do not treat that as a discrepancy against this constant.)
    // Spelled as literals rather than computed at elaboration: the arithmetic
    // needs 64-bit intermediates, and this avoids leaning on Quartus 11.0's
    // longint support for two constants that will never change.
    localparam [31:0] STEP_A = 32'd19554;
    localparam [31:0] STEP_B = 32'd69637;

    logic [31:0] ph_a, ph_b;
    logic [STEP_BITS-1:0] dwell;

    // Everything is held in reset while disabled, so each time DIP 5 is flipped
    // on the demo restarts from step 0 (the loudest) rather than resuming
    // mid-staircase - which is what you want when demonstrating it to someone.
    // NB the disabled case is a SEPARATE synchronous branch, not folded into the
    // reset condition as (!rst_n || !en): Quartus requires the if-condition of
    // an always_ff to match the edges in its event control exactly, and rejects
    // the mixed form outright (Icarus accepts it, so only a synthesis run
    // catches this).
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ph_a  <= 32'd0;
            ph_b  <= 32'd0;
            dwell <= {STEP_BITS{1'b0}};
            step  <= 3'd0;
        end else if (!en) begin
            ph_a  <= 32'd0;
            ph_b  <= 32'd0;
            dwell <= {STEP_BITS{1'b0}};
            step  <= 3'd0;
        end else begin
            ph_a  <= ph_a + STEP_A;
            ph_b  <= ph_b + STEP_B;
            dwell <= dwell + 1'b1;
            if (dwell == {STEP_BITS{1'b1}}) step <= step + 1'b1;   // wraps 7->0
        end
    end

    // Triangle: a 15-bit ramp from the accumulator, inverted on the second half
    // of the cycle, then centred. Range -16384 .. +16383 = +/-16 ladder steps
    // = -5.7 dBFS, which is this module's "0 dB" reference.
    // (Written out per voice rather than as a function: `tri` is a reserved
    // Verilog net type, and a function taking a 32-bit argument buys nothing
    // over four wires.)
    wire [14:0] ramp_a = ph_a[31] ? ~ph_a[30:16] : ph_a[30:16];
    wire [14:0] ramp_b = ph_b[31] ? ~ph_b[30:16] : ph_b[30:16];

    wire signed [15:0] tri_a = $signed({1'b0, ramp_a}) - 16'sd16384;
    wire signed [15:0] tri_b = $signed({1'b0, ramp_b}) - 16'sd16384;

    // Voice A sits 6 dB below the reference so that A and B together cannot
    // approach the mixer's saturation bound even at step 0 (16384/2 + 16384 =
    // 24576 < 31744). NB that budget holds because bk_audio MUTES THE SPEAKER
    // while the self-test runs - the speaker alone is full scale and would
    // saturate the sum on its own. See the gain-budget note in bk_audio.sv.
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_a <= 16'sd0;
            voice_b <= 16'sd0;
        end else if (!en) begin
            voice_a <= 16'sd0;      // exact silence, not a held sample
            voice_b <= 16'sd0;
        end else begin
            voice_a <= tri_a >>> 1;             // fixed -6 dB
            voice_b <= tri_b >>> step;          // 16384 >> step: 8 x 6 dB
        end
    end

endmodule
