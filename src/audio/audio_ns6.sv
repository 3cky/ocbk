// ============================================================================
//  audio_ns6 - first-order noise-shaped 16-bit -> 6-bit quantizer (ONE channel)
// ----------------------------------------------------------------------------
//  Turns a signed 16-bit audio sample into the 6-bit code the board's R-2R
//  sound ladder wants, WITHOUT throwing away the low 10 bits: the truncation
//  error is fed back into the next sample, so the code stream's short-term
//  AVERAGE carries the full 16-bit value. At the shipped 6.04 MHz update rate
//  (sys_clk/16, see audio_out) that is an oversampling ratio of ~151 against a
//  20 kHz audio band, which puts the shaped in-band noise ~60 dB below the raw
//  6-bit truncation floor - far past what the discrete ladder's own resistor
//  matching can deliver. See sim/audio/README.md for the honest three-line
//  resolution claim; the short version is that a signal one TENTH of a ladder
//  step is reproduced rather than lost, while absolute full-scale linearity is
//  unchanged (ladder-INL-limited) and there are still six bits at the pins.
//
//  THE FORMULATION MATTERS. This one costs one 17-bit adder and one 10-bit
//  register, and its properties are provable rather than hoped for:
//
//      accr = s_in + errp        (errp = the previous residue, UNSIGNED and
//                                 always in [0,1023], so there is no sign
//                                 handling and no second adder anywhere)
//      q    = accr >>> 10        (arithmetic, free - a bit select)
//      errn = accr[9:0]          (the new residue, free)
//      code = 32 + q             (offset binary; 32+q[5:0] mod 64 == 32+q
//                                 exactly, because q in [-32,31] here)
//
//  The identity accr == (q<<10) + errn holds BIT-EXACTLY by construction, so
//  the loop's DC gain is exactly 1: summing it over M ticks telescopes to
//      1024*sum(code) - M*(32*1024 + s) == errp_0 - errp_M,
//  i.e. the mean code tracks the input to within 1023/M of one 1/1024 step.
//  That is the oracle assertion (audio_ns6_tb L1), and it is an identity, not
//  a tolerance.
//
//  THREE FIXED POINTS - the reason FS_SAT is 31744 (= 31*1024) and not 32767.
//  The mixer saturates there, which costs 0.14 dB (one code of swing) and buys:
//
//      s_in = 0       -> accr =    512 -> q =   0, errn = 512 -> code = 32 static
//      s_in = +31744  -> accr =  32256 -> q = +31, errn = 512 -> code = 63 static
//      s_in = -31744  -> accr = -31232 -> q = -31, errn = 512 -> code =  1 static
//
//  So (a) SILENCE PRODUCES ZERO PIN ACTIVITY - which matters on this board,
//  where pDac_SR[5] doubles as the CMT input pad, and which makes "silent at
//  silence" a sharp binary check instead of a statistical one; and (b) the BK
//  1-bit speaker, whose level maps to the two rails, comes out as a STATIC
//  63/1 with no shaping activity at all, so the one audio feature that already
//  works on hardware cannot be regressed by this module. And since
//  |s_in| <= 31744 gives accr in [-31744, 32767] -> q in [-31,+31],
//  CLIPPING IS STRUCTURALLY UNREACHABLE in the shipped configuration.
//
//  FIRST order, deliberately. Second order buys nothing usable here (we are
//  ladder-limited two orders of magnitude before the shaper's limit) and costs
//  real hazards: it doubles the out-of-band noise slope (20 -> 40 dB/decade)
//  into an analog stage whose corner is unmeasured, it can push the quantizer
//  out of range on transients - reintroducing exactly the windup mode the
//  clip guard below exists to bound - and it needs a stability clamp.
//
//  NO DITHER, deliberately. For a DC input whose fractional part is p/q in
//  lowest terms the limit cycle sits at Fs/q with amplitude O(1/q) codes; the
//  audio band needs q > 300, so any IN-band idle tone is below ~-85 dBFS,
//  while the loud short cycles (Fs/2 = 3.02 MHz, Fs/3) are all >= 1 MHz. The
//  exact-zero fixed point above is worth more than decorrelation. Insertion
//  point if this is ever revisited: accr = s_in + errp + dither, RPDF from an
//  LFSR - it invalidates exactly one oracle leg (L3, silence), which would
//  have to become a bounded-variance check.
//
//  WHY NOT esemsx3's DAC scheme: esemsx3 drives a 1-bit sigma-delta bitstream
//  (src/sound/dac/esepwm.vhd, ~21 MHz) onto ladder taps 5 and 0 only, and on
//  its own firmware that works and sounds fine - it is NOT a broken scheme and
//  NOT silent on this board. We use the whole ladder for a positive reason:
//  the OneChipBook schematic gives us a real 6-bit WEIGHTED R-2R network, so a
//  6-bit quantizer starts ~30 dB ahead of a 1-bit one at equal oversampling
//  and needs 16x less of it. (ocbk's own earlier attempt at esemsx3's two-tap
//  pin pattern WAS silent, but because it fed those taps an audio-rate 1-bit
//  level instead of a modulated bitstream - two taps have nothing to average.
//  That was a bug in the reproduction, not a property of the hardware.)
// ============================================================================
module audio_ns6 (
    input  logic               sys_clk,
    input  logic               rst_n,     // async, active low (power-on only)
    input  logic               tick,      // 1 sys_clk per DAC update (audio_out)
    input  logic signed [15:0] s_in,      // signed sample; |s_in| <= FS_SAT
    output logic         [5:0] code,      // ladder code, mid-scale 32
    output logic               dbg_clip   // sticky: the quantizer clipped once
);
    // The residue register, UNSIGNED and always in [0,1023].
    //
    // Its reset value of 512 is the MID-residue, so the modulator starts
    // centred rather than on a quantization boundary. That is a cosmetic
    // choice about the first output or two and NOTHING MORE - do not let a
    // comment grow here claiming it is a rounding bias. It cannot be: errp is
    // the residue accr[9:0], not a constant added every tick, so it carries no
    // persistent offset. Checked both ways: resetting it to 0 gives the same
    // mean (the telescoping identity above holds for ANY errp_0), the same
    // three fixed points, and the same noise power - only the limit-cycle
    // phase moves. It is therefore pinned by the oracle as documented state
    // (L7), not as a correctness property, and there is deliberately no
    // mutation for it because none would fail.
    logic [9:0] errp;

    wire signed [16:0] accr = s_in + $signed({7'b0, errp});
    wire signed [6:0]  q    = accr[16:10];
    wire        [9:0]  errn = accr[9:0];

    // Clip guard. Structurally unreachable while the mixer honours
    // FS_SAT = 31744 (see the header), but it ships anyway because a future
    // source's gain bug is exactly how a 6-bit code gets asked for a 7-bit
    // value - and the CLAMP is genuinely load-bearing: without it the
    // "6'd32 + q[5:0]" offset-binary add WRAPS, turning an overload into a
    // full-scale sign inversion, i.e. the loudest artifact this path can
    // produce. Mutation N4 pins that.
    //
    // NO WINDUP IS POSSIBLE HERE, and not because of the errp <- 512 line
    // below: the residue is the bit-select accr[9:0], so it is bounded to
    // [0,1023] by CONSTRUCTION. The classic runaway - an error integrator
    // growing without bound through a clipped passage and holding the ladder
    // railed long afterwards - belongs to the other formulation, where the fed
    // back error is computed as accr - (code_clamped << 10) in a word wide
    // enough to hold it. Do not let a comment grow here claiming this line
    // prevents windup; it does not, because there is nothing to prevent.
    //
    // What errp <- 512 on clip actually buys: once the clamp has discarded
    // whole codes, accr[9:0] is no longer the loop's true error, so
    // propagating it would carry a meaningless value into the next sample.
    // Re-centring instead makes post-overload recovery exact and predictable
    // from the first tick. It costs one mux and no arithmetic. Pinned by L5's
    // exact post-clip code sequence (mutation N3).
    wire clip_hi = (q >  7'sd31);
    wire clip_lo = (q < -7'sd32);

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            errp     <= 10'd512;
            code     <= 6'd32;
            dbg_clip <= 1'b0;
        end else if (tick) begin
            code     <= clip_hi ? 6'd63 : clip_lo ? 6'd0 : (6'd32 + q[5:0]);
            errp     <= (clip_hi || clip_lo) ? 10'd512 : errn;
            dbg_clip <= dbg_clip || clip_hi || clip_lo;
        end
    end

endmodule
