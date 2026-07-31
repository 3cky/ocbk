// ============================================================================
//  audio_mixer - N-slot stereo audio mixer feeding the noise-shaped DAC
// ----------------------------------------------------------------------------
//  Sums up to NSRC signed audio sources into a stereo pair, with a per-slot
//  compile-time gain and pan and a per-slot RUNTIME enable, saturating at the
//  bound audio_ns6 needs to stay provably clip-free.
//
//  SLOT MAP (bk_audio ships NSRC = 5; the rest is the documented growth path,
//  proven functional at NSRC = 10 by audio_mixer_tb but deliberately NOT
//  synthesized until the devices exist - no dead logic):
//
//      0 = BK speaker (BOTH)    3 = Turbosound L (L)  5 = Covox L (L)
//      1 = self-test tone A     4 = Turbosound R (R)  6 = Covox R (R)
//          (BOTH)                                     7 = Menestrel L (L)
//      2 = self-test tone B (R)                       8 = Menestrel R (R)
//
//  Note the two PSGs of the Turbosound take TWO slots between them, not six:
//  bk_turbosound does its own ACB pan and chip combine and hands over a
//  finished stereo pair. That is this module's design law in action - see
//  "RUNTIME STEREO IS NOT A RUNTIME PAN" below - and it is also what keeps the
//  stage-1 tree shallow enough to meet timing.
//
//  SAMPLE SCALE: signed, full scale +/-32767, i.e. exactly BkEmu's short
//  domain (AudioOutput.MAX_OUTPUT = Short.MAX_VALUE). That is deliberate - it
//  lets the AY volume table, the Covox byte map and the Menestrel counter
//  levels transcribe 1:1 out of BkEmu with no rescaling to get wrong.
//
//  GAIN AND PAN ARE COMPILE-TIME; ENABLE IS RUNTIME. There is no volume UI in
//  this design and never will be, so the gains are fixed relative-loudness
//  design constants: as parameters they constant-fold to shifted adds and cost
//  nothing, whereas a runtime gain would need a shift-and-add bank per slot on
//  a device with NO multipliers. The enable must be runtime because Covox and
//  Menestrel are to be cycled by a PS/2 radial-toggle key while the AY stays
//  always live.
//
//  RUNTIME STEREO IS NOT A RUNTIME PAN. Covox decides mono-vs-stereo from a
//  write's high byte; the Turbosound has six channels across two chips, and
//  whether the second one is mixed in at all depends on a runtime latch.
//  All of them present as ONE SLOT PER CHANNEL OF THEIR OWN OUTPUT with a
//  static pan, and the device's own logic decides what to put in each slot -
//  bk_turbosound is the worked example: it folds A/B/C of both chips into one
//  L and one R sample itself and takes two slots. That is the seam decision
//  that keeps this module trivial - do not add a runtime pan.
//
//  SATURATING, NEVER WRAPPING. A wrap is a full-scale sign inversion, i.e. the
//  loudest artifact this path can emit. BkEmu saturates too
//  (AudioMixer.clipSample). We saturate at FS_SAT = 31744 rather than 32767
//  because that is exactly audio_ns6's structurally-clip-free window - putting
//  the bound HERE is what makes the shaper's "can never clip" proof hold. The
//  cost is 0.14 dB of swing. dbg_sat is sticky: saturation should be rare, and
//  the mixing STRATEGY is the gain budget (the gains of slots that can be live
//  together should sum to <= 8/8 at nominal amplitude), not the saturator - it
//  is a guard, and the LED says when it fired.
//
//  TWO SIMPLIFICATIONS AGAINST THE ORIGINAL PLAN, both deliberate:
//
//  1. NO explicit BOTH/L-only/R-only group partition. The plan called for one
//     to halve the adder count. It is unnecessary: a slot's pan mask is a
//     COMPILE-TIME constant, so an R-only slot's left-hand term is a literal
//     zero and the synthesizer folds it out of the left tree entirely. The
//     fitter performs the partition; expressing it in RTL would only add
//     elaboration-time group counting, which is exactly where Quartus 11.0
//     SystemVerilog bites.
//     MEASURED, not assumed (quartus_map, EP1C12, NSRC=10, both configs chosen
//     so L and R differ and no tree sharing is possible): the planned pan map
//     (6 left + 7 right terms) costs 392 LE against 527 LE for a near-all-BOTH
//     map (10 + 9 terms) - 135 LE saved, ~22 LE per folded 21-bit term. NB an
//     ALL-BOTH map is NOT the control to compare against: there mix_l and mix_r
//     are the same expression and Quartus shares one tree between them, which
//     makes it look smaller than the partitioned case for an unrelated reason.
//  2. NO AW port. The accumulator width is a localparam SW+5, which carries 16
//     slots at full scale without overflow (16*31744 < 2^20) and leaves the
//     headroom that makes the final saturation meaningful. Exposing it only
//     created a way to set it too small and wrap silently.
//
//  PIPELINE: two registered stages, both one 21-bit carry chain deep at
//  NSRC = 3 (stage 0 = enable/gain/pan, stage 1 = sum + saturate). Latency 2
//  sys_clk = ~21 ns, an eighth of one DAC tick - architecturally invisible,
//  which is why this runs continuously on sys_clk rather than on the tick.
//  GROWTH NOTE: the stage-1 sum is written as an associative reduction, so
//  Quartus balances it into a tree of depth ceil(log2(NSRC)) - fine to ~6
//  slots at 96.65 MHz. Beyond that it wants one more registered stage. Sim
//  cannot see this; STA will, when the slots actually land.
//
//  Quartus II 11.0 hygiene, all load-bearing: flat PACKED vector ports with
//  [i*W +: W] slicing (never unpacked arrays in ports), every parameter passed
//  explicitly at the instance, and no package import anywhere in this file (so
//  none of the wildcard-imported-parameter gotchas can apply).
// ============================================================================
module audio_mixer #(
    parameter int NSRC   = 3,       // number of slots (<= 16)
    parameter int SW     = 16,      // per-slot signed sample width
    // Saturation bound = audio_ns6's clip-free limit. Declared SIZED and signed
    // rather than as a `parameter int`: an int makes the literal 32 bits, which
    // then truncates into the AW-wide SAT_P/SAT_N below and costs two Quartus
    // (10230) warnings for nothing.
    parameter signed [15:0] FS_SAT = 16'sd31744,
    // Per-slot, slot 0 in the LOW bits. Gain is g/8 with g in 1..8.
    parameter [NSRC*4-1:0] GAIN8 = {NSRC{4'd8}},
    // Per-slot {to_L, to_R}: 2'b11 = both, 2'b10 = left only, 2'b01 = right only.
    parameter [NSRC*2-1:0] PAN   = {NSRC{2'b11}}
) (
    input  logic                 sys_clk,
    input  logic                 rst_n,    // async, active low (power-on only)
    input  logic [NSRC*SW-1:0]   src,      // packed signed samples
    input  logic [NSRC-1:0]      src_en,   // 1 = slot contributes, 0 = exactly zero
    output logic signed [SW-1:0] mix_l,
    output logic signed [SW-1:0] mix_r,
    output logic                 dbg_sat   // sticky: the sum saturated at least once
);
    // Accumulator width: SW + 5 carries 16 slots at full scale (16*31744 =
    // 507904 < 2^19 = 524288, so 21 bits signed is comfortable) and leaves the
    // headroom that lets the saturation below actually saturate.
    localparam int AW = SW + 5;

    // ---- stage 0: enable mask, gain, pan --------------------------------------
    logic signed [AW-1:0] s0_l [0:NSRC-1];
    logic signed [AW-1:0] s0_r [0:NSRC-1];

    genvar gi;
    generate
        for (gi = 0; gi < NSRC; gi = gi + 1) begin : g_slot
            // The slot sample, sign-extended into the accumulator width.
            wire signed [AW-1:0] raw = $signed(src[gi*SW +: SW]);

            // Gain g/8. g is a compile-time constant so this multiply folds to
            // at most two shifted adds (5=4+1, 6=4+2, 7=8-1, 1/2/4/8 pure
            // shifts) - and to a plain wire at the shipped g=8. The $signed on
            // the constant matters: a mixed signed/unsigned multiply in Verilog
            // is UNSIGNED, which would mangle every negative sample.
            localparam [3:0] G = GAIN8[gi*4 +: 4];
            wire signed [AW+4:0] scaled = raw * $signed({1'b0, G});
            wire signed [AW-1:0] gained = scaled[AW+2:3];   // (raw*G) >>> 3

            wire signed [AW-1:0] enab = src_en[gi] ? gained : {AW{1'b0}};

            // Pan masks are compile-time, so a slot not panned to a side
            // contributes a literal zero there and folds out of that tree.
            localparam PAN_L = PAN[gi*2+1];
            localparam PAN_R = PAN[gi*2+0];

            always_ff @(posedge sys_clk or negedge rst_n) begin
                if (!rst_n) begin
                    s0_l[gi] <= {AW{1'b0}};
                    s0_r[gi] <= {AW{1'b0}};
                end else begin
                    s0_l[gi] <= PAN_L ? enab : {AW{1'b0}};
                    s0_r[gi] <= PAN_R ? enab : {AW{1'b0}};
                end
            end
        end
    endgenerate

    // ---- stage 1: sum + saturate ---------------------------------------------
    logic signed [AW-1:0] sum_l, sum_r;
    integer i;
    always_comb begin
        sum_l = {AW{1'b0}};
        sum_r = {AW{1'b0}};
        for (i = 0; i < NSRC; i = i + 1) begin
            sum_l = sum_l + s0_l[i];
            sum_r = sum_r + s0_r[i];
        end
    end

    localparam signed [AW-1:0] SAT_P =  FS_SAT;
    localparam signed [AW-1:0] SAT_N = -FS_SAT;

    wire hit_l = (sum_l > SAT_P) || (sum_l < SAT_N);
    wire hit_r = (sum_r > SAT_P) || (sum_r < SAT_N);

    wire signed [AW-1:0] cl_l = (sum_l > SAT_P) ? SAT_P : (sum_l < SAT_N) ? SAT_N : sum_l;
    wire signed [AW-1:0] cl_r = (sum_r > SAT_P) ? SAT_P : (sum_r < SAT_N) ? SAT_N : sum_r;

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_l   <= {SW{1'b0}};
            mix_r   <= {SW{1'b0}};
            dbg_sat <= 1'b0;
        end else begin
            // |cl_*| <= FS_SAT < 2^15, so the narrowing to SW bits is exact.
            mix_l   <= cl_l[SW-1:0];
            mix_r   <= cl_r[SW-1:0];
            dbg_sat <= dbg_sat || hit_l || hit_r;
        end
    end

endmodule
