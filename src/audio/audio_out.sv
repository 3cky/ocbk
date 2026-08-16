// ============================================================================
//  audio_out - the pad-facing audio output stage: DAC update rate, the two
//              noise shapers, true stereo / CMT mono fold, and the CMT jack
// ----------------------------------------------------------------------------
//  Everything that touches the two sound pads lives here, so there is exactly
//  one place to reason about the ladder drive and the cassette jack.
//
//  TRUE STEREO, folding to MONO ON THE LEFT LADDER IN CMT MODE:
//
//    cmt_mode = 0 (the normal case)
//        dac_l    = shape(mix_l)                 <- independent channels
//        dac_r_o  = shape(mix_r)
//        dac_r_oe = 6'b111111
//
//    cmt_mode = 1 (DIP 4: the right jack IS the cassette port)
//        dac_l    = shape((mix_l + mix_r) >>> 1) <- both channels, mono
//        dac_r_o  = {2'b00, tape_lvl, ~tape_lvl, 1'b0, spk_raw}
//        dac_r_oe = 6'b001111
//
//    !rst_n (either mode - RESET WINS, preserving the pre-rework ordering)
//        dac_l = dac_r_o = 6'd32,  dac_r_oe = 6'b111111
//
//  The fold is an AVERAGE, not a sum: a BOTH-panned source is then equally loud
//  in mono and in stereo, and hard-panned content folds 6 dB down, which is
//  standard correct mono behaviour. It also needs no extra saturator - each
//  input is bounded to +/-31744, so the average is too, still inside
//  audio_ns6's clip-free window. And because the BK speaker is panned BOTH,
//  mix_l == mix_r for it and the CMT-mode left ladder still sits at code 63/1:
//  turning CMT on cannot change how the speaker sounds.
//
//  Only the LEFT shaper's INPUT is muxed, not two parallel shaper pairs. So
//  flipping DIP 4 steps that input once - a click, on a deliberate human
//  action, exactly as before the rework. The residue carries across the flip
//  harmlessly (it is bounded to [0,1023] by construction).
//
//  TAPE-OUT IS A DATA SIGNAL, NOT AUDIO - HARD RULE. dac_r_o[0] is spk_raw,
//  the synchronized RAW speaker bit, and nothing else. Never a mixed sample and
//  never a shaped code. Three reasons, written down because this is the mistake
//  a future increment will make:
//    1. bit 0 IS the ladder's LSB tap, and a shaped code's bit 0 can rattle at
//       up to 3 MHz - that would destroy the duration-coded waveform MONITOR
//       writes to tape.
//    2. it would mix OTHER sources (an AY!) into a tape recording.
//    3. it matches the real machine: BK tape-out is the speaker register bit.
//  (A real BK resistively mixes write bits 6 AND 5 into a 3-level record
//  waveform; bit 6 alone is shipped, and that is a qbus_mem/Speaker-contract
//  question, not this module's - do not "improve" it here.)
//
//  THE ANTI-ECHO RULE IS NOW MORE LOAD-BEARING THAN IT WAS. tape_lvl is forced
//  to 0 whenever CMT mode is off, because pDac_SR[5] is then DRIVEN by us - and
//  since the rework what it carries is a shaped code bit that can toggle at
//  3 MHz, where before it was a quasi-static mono speaker level. Without the
//  force, that rattle would be sampled straight into 177716 read bit 5.
//
//  RATE: sys_clk / RATE_DIV, default 16 = 6.0405 MHz. See audio_ns6's header
//  for why not the full 96.65 MHz (pad/ladder settling, and a 17-bit carry
//  chain on the every-cycle path against +0.3 ns of sys_clk slack) and why not
//  a 1-bit stream on two taps. The prescaler is PRIVATE rather than a port on
//  purpose: taking the tick from cpu_clkgen would force every audio testbench
//  to replicate a divider, which is exactly the replica-drift trap CLAUDE.md
//  records for cpu_clkgen. Four flops buys a subsystem that is independent of
//  the CPU clock tree and whose tbs exercise the REAL rate logic. Both channels
//  share the one prescaler so L and R step on the same edge - otherwise their
//  shaped noise would beat against each other in the common analog ground.
//  Fallbacks if the board dislikes 3 MHz shaped noise or cannot settle in
//  165 ns: RATE_DIV = 8 or 32, a one-parameter change.
//
//  PADS ARE DRIVEN FROM FLOPS. audio_ns6's `code` is already a register, so
//  dac_l is a register output directly and dac_r_o/dac_r_oe are a two-way mux
//  of registered values selected by a registered mode bit. Deliberately NOT
//  re-registered again here: that would add a cycle of skew between the two
//  ladders' update instants for no benefit, and it would put the reset value
//  in two places instead of one (audio_ns6 already resets code to mid-scale,
//  so the reset path and the explicit mux agree by construction).
// ============================================================================
module audio_out #(
    parameter int RATE_DIV = 16      // sys_clk / RATE_DIV = the DAC update rate
) (
    input  logic               sys_clk,
    input  logic               rst_n,       // async, active low (power-on only)
    input  logic signed [15:0] mix_l,       // mixer output, |.| <= 31744
    input  logic signed [15:0] mix_r,
    input  logic               cmt_mode,    // DIP 4 (already 2-FF synced above)
    input  logic               cmt_in_pad,  // raw pDac_SR[5] value (async)
    input  logic               spk_raw,     // synced raw speaker bit (CMT out)
    output logic               tape_lvl,    // CMT comparator level -> 177716 bit 5
    output logic         [5:0] dac_l,       // pDac_SL  (Sound-L)
    output logic         [5:0] dac_r_o,     // pDac_SR data
    output logic         [5:0] dac_r_oe,    // pDac_SR per-bit output enables
    output logic               dbg_clip     // sticky: either shaper clipped
);
    // ---- DAC update rate ----------------------------------------------------
    // 5 bits carries RATE_DIV up to 32. A fixed width rather than $clog2 keeps
    // this free of any elaboration-time arithmetic.
    logic [4:0] ph;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) ph <= 5'd0;
        else        ph <= (ph == RATE_DIV[4:0] - 5'd1) ? 5'd0 : ph + 5'd1;
    end
    wire tick = (ph == 5'd0);

    // ---- cmt_mode re-registered locally -------------------------------------
    // The model_bk11_q / smk_en_q idiom. cmt_mode is quasi-static and already
    // 2-FF synced in ocbk_top, but since the rework it feeds a 16-bit datapath
    // mux AND the pad-OE decode, and a long route into either is precisely how
    // this design has repeatedly lost sys_clk slack. One flop turns that into a
    // local flop-to-flop path. Safe because a DIP flip is a human event: no
    // oracle compares this cone combinationally across a change.
    logic cmt_mode_q;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) cmt_mode_q <= 1'b0;
        else        cmt_mode_q <= cmt_mode;
    end

    // ---- CMT input: 2-FF sample of the pad, closing the Schmitt loop --------
    // Forced to 0 while CMT is off - see the ANTI-ECHO note in the header.
    // (esemsx3 does the same: "CMT data input is always '0'" when disabled.)
    logic cmt_meta;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            cmt_meta <= 1'b0;
            tape_lvl <= 1'b0;
        end else begin
            cmt_meta <= cmt_in_pad;
            tape_lvl <= cmt_mode_q ? cmt_meta : 1'b0;
        end
    end

    // ---- the mono fold ------------------------------------------------------
    // Widen BEFORE adding: mix_l + mix_r at 16 bits would wrap (Verilog sizes
    // the expression to its widest operand, not to the sum's range).
    wire signed [16:0] msum = $signed({mix_l[15], mix_l})
                            + $signed({mix_r[15], mix_r});
    wire signed [15:0] mono = msum[16:1];          // arithmetic >>> 1

    wire signed [15:0] s_left = cmt_mode_q ? mono : mix_l;

    // ---- shaper input pipeline (STA, 2026-08-16) ----------------------------
    // One register between the mixer and the shapers. Without it the combinational
    // chain from the mixer's output register is
    //
    //     mix_l -> the 17-bit mono add -> the CMT mux -> the shaper's 17-bit add
    //           -> the clip compare -> errp
    //
    // i.e. TWO 17-bit adds and a compare in one sys_clk. That cone went to
    // -0.072 ns / TNS -0.586 when an unrelated +22 LE elsewhere re-placed the
    // fitter, and it is the natural place to break: the mono add is only live in
    // CMT mode, but STA has to assume it and an SDC exception is forbidden here.
    //
    // A SOURCE-LEVEL REWRITE WAS TRIED FIRST AND IS A DEAD END - do not retry it.
    // Splitting the shaper's 17-bit add into its 10-bit and 7-bit halves (which
    // is exact, since errp is only 10 bits) produced a BIT-IDENTICAL fit: same
    // 9,170 LE, same -0.072, same cone. Quartus re-associates that arithmetic
    // itself, so only a real register boundary moves this path.
    //
    // The cost is one sys_clk (10.3 ns) of latency on both channels equally -
    // a pure delay, not a resampling: the shapers still consume one value per
    // tick, tick is unchanged, and both channels shift together so the stereo
    // image cannot skew. audio_ns6's DC gain is exactly 1 and a delay does not
    // touch that, which is why sim/audio's identity leg still holds.
    logic signed [15:0] s_left_q, s_right_q;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            s_left_q  <= 16'sd0;
            s_right_q <= 16'sd0;
        end else begin
            s_left_q  <= s_left;
            s_right_q <= mix_r;
        end
    end

    // ---- the two shapers ----------------------------------------------------
    logic [5:0] code_l, code_r;
    logic       clip_l, clip_r;

    audio_ns6 u_ns6_l (
        .sys_clk (sys_clk), .rst_n (rst_n), .tick (tick),
        .s_in    (s_left_q), .code (code_l), .dbg_clip (clip_l)
    );

    audio_ns6 u_ns6_r (
        .sys_clk (sys_clk), .rst_n (rst_n), .tick (tick),
        .s_in    (s_right_q),  .code (code_r), .dbg_clip (clip_r)
    );

    assign dbg_clip = clip_l | clip_r;

    // ---- pad drive ----------------------------------------------------------
    // The (rst_n && cmt_mode_q) form preserves the pre-rework ordering exactly:
    // reset wins over CMT mode, so both ladders hold mid-scale with all six taps
    // driven while reset is asserted, whatever DIP 4 says.
    wire cmt_live = rst_n && cmt_mode_q;

    assign dac_l    = code_l;                       // a register output
    assign dac_r_o  = cmt_live ? {2'b00, tape_lvl, ~tape_lvl, 1'b0, spk_raw}
                               : code_r;
    assign dac_r_oe = cmt_live ? 6'b001111 : 6'b111111;

endmodule
