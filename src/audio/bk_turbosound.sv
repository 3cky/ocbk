// ============================================================================
//  bk_turbosound - the BK TurboSound: 2x YM2149 on the 0177714 parallel port
// ----------------------------------------------------------------------------
//  The first device to hang off the Phase-10 177714 capture seam. It snoops
//  qbus_mem's port_wr/port_data/port_word/port_be, never touches the bus, and
//  presents ONE STEREO PAIR to bk_audio's mixer slots.
//
//  BkEmu's Ay8910.java IS THE CONTRACT (it is the only one of the two
//  references that implements TurboSound at all; MiSTer's BK core has a
//  single PSG). Everything below transcribes it:
//
//    * v = ~port_data[7:0]. The port is physically inverted; qbus_mem hands
//      us the BK-TRUE value the program wrote, and BkEmu's device models each
//      do their own `v = ~value`, so the inversion belongs HERE.
//
//    * WORD write  -> ADDRESS latch, broadcast to BOTH chips. BkEmu keeps ONE
//      shared `currentRegister` field across the two chips, so broadcasting is
//      what reproduces it; only the DATA write is steered by the selection.
//      The latch value is masked to v[3:0], exactly like BkEmu, which is also
//      what keeps the core's own `addr[7:4]` write guard permanently
//      satisfied.
//
//    * BYTE write  -> DATA into the latched register of the SELECTED chip.
//      An EVEN-byte (0177714) write carries the value; an ODD-byte (0177715)
//      write is a data write of 0xFF, because BkEmu's Computer.writeMemory
//      passes `value << 8` for the odd lane, whose low byte is 0, and the
//      model then computes ~0 = 0xFF. Junk either way - but it is BkEmu's
//      junk, and sim/ts pins it.
//
//    * 0xFF / 0xFE in the address latch select the primary / secondary chip.
//      The first 0xFE ever seen ACTIVATES 2-chip mode, and the secondary is
//      mixed in only from then on.
//
//      TWO PIECES OF BkEmu ARE DELIBERATELY NOT REPRODUCED, and they are the
//      SAME piece of behaviour: its 3-second dead-man timeout (no 0xFE for
//      3 s => fall back to one chip) and its reset of the secondary at
//      activation. Both exist because a BkEmu chip OBJECT outlives the
//      program that programmed it, so the emulator needs a way to notice
//      that TurboSound is no longer in use and to scrub stale state on the
//      way back in. In hardware nINIT already does that job, and dropping
//      the timeout makes the reset unreachable: dual_act is cleared ONLY by
//      the reset that also clears both chips, so a "first 0xFE" can never
//      find a dirty secondary. Implementing it anyway would be dead logic
//      that no oracle could kill. The two go together - if the timeout is
//      ever added back, the activation reset has to come with it.
//
//  DELIBERATE DIVERGENCE FROM MiSTer: it wires BC = bus_wtbt[1], so an
//  odd-byte write is an ADDRESS latch there and a DATA write here. BkEmu wins
//  (this repo's standing rule for BK register semantics), and the odd-byte
//  case is a named leg of sim/ts/bk_turbosound_tb.
//
//  RESET is `~init_n` ORed with the power-on reset - the standard BK
//  peripheral rule, which qbus_mem's own seam comment names for exactly this
//  device class ("AY registers ... keys to init_n inside the DEVICE"). So a
//  RESET instruction silences the PSGs, as it would on a real board, and
//  clears the TurboSound latch. nINIT crosses from the CPU domain, so it gets
//  a 2-FF sync; the CE divider is deliberately NOT reset by it (a real chip's
//  clock keeps running through nINIT).
//
//  CLOCK. sys_clk/56 = 96.6477/56 = 1.72585 MHz against a real BK AY's
//  12 MHz/7 = 1.714286 - +0.674 %, the SAME offset the whole design carries,
//  and CPU:PSG = 56:24 = 7:3 EXACTLY as on real hardware. So the PSG does not
//  drift against CPU-timed code, which is the property that matters for
//  players that count instructions between register writes. The divider is
//  PRIVATE, not a port: taking the tick from cpu_clkgen would force every
//  audio testbench to replicate a divider, which is the replica-drift trap
//  this repo records for cpu_clkgen (and audio_out's prescaler follows the
//  same rule).
//
//  THE MIX FOLD, and why it is done here rather than in the mixer. audio_mixer
//  takes one slot per channel with a COMPILE-TIME pan and explicitly forbids a
//  runtime pan; its header says the device's own logic decides what to put in
//  each slot. Six PSG channels as six slots would also push the mixer past the
//  ~6-slot depth its header warns about. So the ACB pan (A left, C right, B
//  centre - what BOTH references do) and the 2-chip combine happen here, and
//  the device presents two slots:
//
//      lc = 2*A + B   per chip                                   0 .. 765
//      l  = dual_act ? (lc0 + lc1) : 2*lc0                       0 .. 1530
//      ts_l = 15 * l  == (l << 4) - l                            0 .. 22950
//
//  The `dual_act ? sum : 2*chip0` form is BkEmu's "average the two chips when
//  TurboSound is engaged" (Ay8910.writeSample does l = (l0 + l1)/2) expressed
//  without a divider: the FULL-SCALE BOUND is 1530 in both modes, which is
//  what makes the headroom proof below hold whatever the program does. Note
//  the consequence, which is BkEmu's and is reproduced deliberately: engaging
//  TurboSound drops each individual chip by 6 dB, so a primary-only tune gets
//  quieter the moment a program first selects chip 1.
//
//  ts_snd IS THE COVOX ARBITRATION HOOK (Phase 12). bk_covox decodes the same
//  0177714 address, so with both present each renders the other's traffic as
//  garbage; the PSGs win and the Covox mutes on this signal. It is deliberately
//  NOT ts_act and deliberately taken before the x15 stage - see the note at the
//  assignment, which is where that argument lives.
//
//  THE OUTPUT IS UNIPOLAR (0 at silence) ON PURPOSE. A real PSG channel is a
//  gated DC level, so its natural rest value is zero, and subtracting a
//  mid-scale offset to "centre" it would put a permanent DC on the ladder and
//  destroy audio_ns6's exact-zero fixed point - the property that makes
//  silence produce literally no pin activity, measured on hardware
//  (-85.8 dBFS floor, no idle tones). The DC that a PLAYING PSG carries is
//  real and harmless: audio_ns6 has DC gain exactly 1 and the analog stage
//  measured flat from 100 Hz.
//
//  THE GAIN BUDGET CLOSES BY CONSTRUCTION, which is the whole reason for the
//  22950 bound. bk_audio drives the speaker at +/-8192, so the worst a mixer
//  channel can ever see is 22950 + 8192 = 31142 <= FS_SAT = 31744. The mixer
//  cannot saturate and the shapers cannot clip - a proof, not a reliance on
//  the saturator. If either bound moves, redo this arithmetic; pLed[1]/[2]
//  going on means it was got wrong.
// ============================================================================
module bk_turbosound #(
    // sys_clk / CE_DIV = the PSG clock. 56 is the authentic 7:3 against the
    // BK-0011M CPU rate; see the header.
    parameter int CE_DIV = 56,
    // Drop the second chip. A documented escape hatch for the fitter, NOT the
    // shipped configuration: it costs ~half this module's logic and makes
    // dual_act permanently 0, so 0xFE-selected writes go nowhere.
    parameter bit DUAL_ENABLE = 1'b1
) (
    input  logic               sys_clk,
    input  logic               rst_n,       // power-on reset (active low)
    input  logic               init_n,      // Q-bus nINIT (CPU domain, async)

    // ---- the 177714 seam (qbus_mem, sclk = sys_clk: no CDC) ---------------
    input  logic               port_wr,
    input  logic [15:0]        port_data,
    input  logic               port_word,
    input  logic [1:0]         port_be,

    // ---- to bk_audio's mixer slots ----------------------------------------
    output logic signed [15:0] ts_l,        // 0 .. 22950, unipolar
    output logic signed [15:0] ts_r,

    // ---- indicators --------------------------------------------------------
    output logic               ts_act,      // a tone/noise channel is enabled
    output logic               dual_act,    // TurboSound 2-chip mode engaged

    // ---- arbitration -------------------------------------------------------
    // "the PSGs are emitting a non-zero sample" - bk_covox's mute input. See
    // the note above the assignment for why this is NOT ts_act and why it is
    // taken before the x15 stage.
    output logic               ts_snd
);

    // ---- reset -------------------------------------------------------------
    // nINIT comes from the CPU domain (vm1 drives it open-collector), so 2 FF.
    logic init_meta, init_sync;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            init_meta <= 1'b1;
            init_sync <= 1'b1;
        end else begin
            init_meta <= init_n;
            init_sync <= init_meta;
        end
    end

    wire reset = ~rst_n | ~init_sync;       // active high, as the cores want

    // ---- PSG clock enable --------------------------------------------------
    // Power-on reset only: nINIT must not restart the chip clock.
    logic [5:0] ce_cnt;
    logic       ce;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ce_cnt <= 6'd0;
            ce     <= 1'b0;
        end else begin
            ce_cnt <= (ce_cnt == CE_DIV[5:0] - 6'd1) ? 6'd0 : ce_cnt + 6'd1;
            ce     <= (ce_cnt == CE_DIV[5:0] - 6'd1);
        end
    end

    // ---- bus decode --------------------------------------------------------
    wire [7:0] v     = ~port_data[7:0];
    // port_be[0] = the low lane carried this write. Clear only for a
    // 0177715-odd-byte write, which BkEmu turns into a data write of 0xFF.
    wire [7:0] wdata = port_be[0] ? v : 8'hFF;

    // One pipeline stage: capture the decoded write, drive the cores next
    // cycle. port_wr is one sclk and the cores' register write is NOT
    // CE-gated, so one BDIR cycle is exactly one write - which is why the
    // seam guarantees ONE STROBE PER BUS WRITE (`port_seen` in qbus_mem):
    // unlike the idempotent speaker latch, a PSG register select and a data
    // write are different events and a repeated strobe would corrupt them.
    logic       s_wr, s_word, s_sel;
    logic [7:0] s_di;
    logic       chip_sel;

    always_ff @(posedge sys_clk) begin
        if (reset) begin
            chip_sel <= 1'b0;
            dual_act <= 1'b0;
            s_wr     <= 1'b0;
        end else begin
            s_wr <= port_wr;

            if (port_wr) begin
                s_word <= port_word;
                // The latch value is MASKED to 4 bits, per BkEmu's
                // `currentRegister = v & 0x0f`. This is a real divergence
                // from silicon, where the latch is 8 bits wide and a value
                // with a non-zero high nibble makes the chip ignore the
                // following data write. BkEmu wins (the standing rule for BK
                // register semantics) and sim/ts pins it with a 0x59 write.
                s_di   <= port_word ? {4'b0000, v[3:0]} : wdata;
                s_sel  <= chip_sel;        // a data write goes to the CURRENT

                if (port_word) begin
                    if (v == 8'hFF) begin
                        chip_sel <= 1'b0;
                    end else if (v == 8'hFE && DUAL_ENABLE) begin
                        chip_sel <= 1'b1;
                        dual_act <= 1'b1;   // sticky; only a reset clears it
                    end
                end
            end
        end
    end

    // A word write reaches both chips; a byte write only the selected one.
    wire bdir0 = s_wr & (s_word | ~s_sel);
    wire bdir1 = s_wr & (s_word |  s_sel);
    wire bc    = s_word;

    // ---- the two PSGs ------------------------------------------------------
    wire [7:0] a0, b0, c0, a1, b1, c1;
    wire [5:0] act0, act1;

    ym2149 u_psg0 (
        .CLK       (sys_clk),
        .CE        (ce),
        .RESET     (reset),
        .BDIR      (bdir0),
        .BC        (bc),
        .DI        (s_di),
        .DO        (),
        .CHANNEL_A (a0), .CHANNEL_B (b0), .CHANNEL_C (c0),
        .SEL       (1'b0),          // the /8 prescale
        .MODE      (1'b0),          // the YM2149 volume law
        .ACTIVE    (act0),
        .IOA_in    (8'hFF), .IOA_out (),
        .IOB_in    (8'hFF), .IOB_out ()
    );

    generate
        if (DUAL_ENABLE) begin : g_psg1
            ym2149 u_psg1 (
                .CLK       (sys_clk),
                .CE        (ce),
                .RESET     (reset),
                .BDIR      (bdir1),
                .BC        (bc),
                .DI        (s_di),
                .DO        (),
                .CHANNEL_A (a1), .CHANNEL_B (b1), .CHANNEL_C (c1),
                .SEL       (1'b0),
                .MODE      (1'b0),
                .ACTIVE    (act1),
                .IOA_in    (8'hFF), .IOA_out (),
                .IOB_in    (8'hFF), .IOB_out ()
            );
        end else begin : g_no_psg1
            assign a1 = 8'h00; assign b1 = 8'h00; assign c1 = 8'h00;
            assign act1 = 6'b000000;
        end
    endgenerate

    assign ts_act = (|act0) | (dual_act & (|act1));

    // ---- the fold: stage A, the per-chip ACB pan --------------------------
    logic [9:0] lc0, rc0, lc1, rc1;
    always_ff @(posedge sys_clk) begin
        if (reset) begin
            lc0 <= 10'd0; rc0 <= 10'd0;
            lc1 <= 10'd0; rc1 <= 10'd0;
        end else begin
            lc0 <= {1'b0, a0, 1'b0} + {2'b00, b0};      // 2*A + B
            rc0 <= {1'b0, c0, 1'b0} + {2'b00, b0};      // 2*C + B
            // No dual_act gate here: lsum/rsum below already drop lc1/rc1
            // when TurboSound is not engaged, so gating twice would be logic
            // no mutation could kill.
            lc1 <= {1'b0, a1, 1'b0} + {2'b00, b1};
            rc1 <= {1'b0, c1, 1'b0} + {2'b00, b1};
        end
    end

    // ---- the fold: stage B, combine the chips and scale -------------------
    wire [10:0] lsum = dual_act ? ({1'b0, lc0} + {1'b0, lc1}) : {lc0, 1'b0};
    wire [10:0] rsum = dual_act ? ({1'b0, rc0} + {1'b0, rc1}) : {rc0, 1'b0};

    // x15 == (x << 4) - x. No multiplier on this device, and 15 is the
    // largest integer scale that keeps 1530 inside the headroom the speaker
    // leaves (1530 * 15 = 22950; * 16 would be 24480 and would saturate).
    wire [14:0] lscl = {lsum, 4'b0000} - {4'b0000, lsum};
    wire [14:0] rscl = {rsum, 4'b0000} - {4'b0000, rsum};

    // "the PSGs are emitting a non-zero sample", for bk_covox's mute. Covox and
    // TurboSound decode the same address, so each renders the other's traffic
    // as garbage and one of them has to stand down; the PSGs win.
    //
    // IT MUST LEAD ts_l/ts_r BY EXACTLY ONE CYCLE, so the mute is already
    // asserted on the cycle the PSG output first becomes non-zero and the two
    // sources can never both reach audio_mixer's stage 0. One cycle of overlap
    // would be enough to saturate (22950 + 20480 + 8192 = 51622) and light
    // pLed[1], which the gain budget says can never happen.
    //
    // AND NOT ts_act, which is ~R7[5:0] - the channel-ENABLE bits. That is
    // both insufficient and harmful here: a channel with tone AND noise
    // disabled passes its volume register through as DC (see the mixer terms
    // in ym2149.sv), which is how AY "digi" playback works, so ts_act = 0 does
    // not imply silence; and a player that exits leaving channels enabled at
    // volume 0 would mute the Covox until the next reset. ts_act keeps its own
    // job on pLed[4].
    //
    // IT IS A FLOP, AND IT IS TAKEN FROM THE CHANNELS RATHER THAN FROM
    // lsum/rsum. Two reasons that happen to coincide:
    //
    //   TIMING - the reason it has to be a flop. It lands in the ENABLE cone
    //   of bk_covox's 26-bit mute-hold counter, in another module, across the
    //   chip. Driving that from a combinational `(|lsum)|(|rsum)` - and lsum
    //   is itself an 11-bit ADDER output - measured sys_clk -0.639 ns,
    //   TNS -12.003 on the first Covox build: the exact "keep translate
    //   outputs out of a register's enable cone" failure this tree has hit
    //   twice before (rdata_oe, then wdata_o). A flop output into the enable
    //   is the structural cure, in the established idiom - never an SDC
    //   exception, never a SEED change.
    //
    //   EQUIVALENCE - the reason it can be. The fold is non-negative and every
    //   term is monotone, so `(|lsum)|(|rsum)` is zero exactly when every
    //   CONTRIBUTING CHANNEL is zero. Taking that predicate one stage earlier
    //   and registering it lands on the SAME cycle as the combinational
    //   version did: lc0/rc0 register a0..c0 on the same edge this flop
    //   registers the predicate. The lead is preserved exactly, and
    //   bk_turbosound_tb checks it against ts_l/ts_r every cycle.
    //
    // dual_act is sampled one stage earlier here too, which cannot matter: it
    // is sticky, and on the edge it rises the secondary is still silent (it
    // can only be programmed after the 0xFE that sets it).
    wire snd_now = (|a0) | (|b0) | (|c0) | (dual_act & ((|a1)|(|b1)|(|c1)));

    always_ff @(posedge sys_clk) begin
        if (reset) ts_snd <= 1'b0;
        else       ts_snd <= snd_now;
    end

    always_ff @(posedge sys_clk) begin
        if (reset) begin
            ts_l <= 16'sd0;
            ts_r <= 16'sd0;
        end else begin
            ts_l <= $signed({1'b0, lscl});
            ts_r <= $signed({1'b0, rscl});
        end
    end

endmodule
