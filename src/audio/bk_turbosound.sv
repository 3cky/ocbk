// ============================================================================
//  bk_turbosound - the BK TurboSound: 2x YM2149 on the 0177714 parallel port
// ----------------------------------------------------------------------------
//  Snoops qbus_mem's port_wr/port_data/port_word/port_be, never touches the bus,
//  and presents one stereo pair to bk_audio's mixer slots.
//
//  The port is physically inverted; word write -> address latch;
//  byte write -> data into the latched register of the selected chip.
//  0xFF / 0xFE in the address latch select the primary / secondary chip.
//  The first 0xFE ever seen activates 2-chip mode, and the secondary is
//  mixed in only from then on.
//
//  Clock: sys_clk/56 = 96.6477/56 = 1.72585 MHz.
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
                s_sel  <= chip_sel;        // a data write goes to the current chip

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
