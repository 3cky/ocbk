// ============================================================================
//  bk_covox - the BK Covox: an 8-bit DAC on the 0177714 parallel port
// ============================================================================
module bk_covox #(
    // Idle one-shot: 2^IDLE_BITS sys_clk = 43.4 ms at 96.65 MHz. Long enough
    // that no sample-playback loop can fall through it, short enough that a
    // finished program's leftover DC is gone before anyone notices it.
    parameter int IDLE_BITS = 22,
    // PSG mute hold: 2^PSG_BITS sys_clk = 694 ms. Must comfortably exceed the
    // longest rest a tune can contain; see the header.
    parameter int PSG_BITS  = 26
) (
    input  logic               sys_clk,
    input  logic               rst_n,       // power-on reset (active low)
    input  logic               init_n,      // Q-bus nINIT (CPU domain, async)

    // ---- the 177714 seam (qbus_mem, sclk = sys_clk: no CDC) ---------------
    input  logic               port_wr,     // 1 sclk per 177714/15 bus write
    input  logic [15:0]        port_data,   // the latch, BK-true, lanes held

    // ---- configuration and arbitration ------------------------------------
    input  logic               mono,        // DIP 5 (live), 1 = right := left
    input  logic               psg_act,     // bk_turbosound ts_snd

    // ---- to bk_audio's mixer slots ----------------------------------------
    output logic signed [15:0] cx_l,        // -32768 .. +32767, BkEmu scale
    output logic signed [15:0] cx_r,
    output logic               cx_en        // 0 = muted (the slot is zeroed)
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

    wire reset = ~rst_n | ~init_sync;

    // ---- the byte lanes ----------------------------------------------------
    wire [7:0] lb = ~port_data[7:0];
    wire [7:0] rb = mono ? lb : ~port_data[15:8];

    // 257*b - 32768. 257*b is {b,b}, so the -32768 is one inverted bit and the
    // whole levels map costs no logic at all. Written inline rather than as a
    // function due to Quartus 11.0's SystemVerilog support limitation.
    wire signed [15:0] samp_l = $signed({~lb[7], lb[6:0], lb});
    wire signed [15:0] samp_r = $signed({~rb[7], rb[6:0], rb});

    always_ff @(posedge sys_clk) begin
        if (reset) begin
            cx_l <= 16'sd0;
            cx_r <= 16'sd0;
        end else begin
            cx_l <= samp_l;
            cx_r <= samp_r;
        end
    end

    // ---- the idle one-shot -------------------------------------------------
    logic [IDLE_BITS-1:0] idle_cnt;
    always_ff @(posedge sys_clk) begin
        if (reset)              idle_cnt <= {IDLE_BITS{1'b0}};
        else if (port_wr)       idle_cnt <= {IDLE_BITS{1'b1}};
        else if (idle_cnt != 0) idle_cnt <= idle_cnt - 1'b1;
    end

    // ---- the modulation detector -------------------------------------------
    logic [15:0] last_data;
    always_ff @(posedge sys_clk) begin
        if (reset)        last_data <= 16'h0000;
        else if (port_wr) last_data <= port_data;
    end

    wire wr_change = port_wr & (port_data != last_data);

    // ---- the liveness detector -------------------------------------------
    logic live;
    always_ff @(posedge sys_clk) begin
        if (reset)              live <= 1'b0;
        else if (idle_cnt == 0) live <= 1'b0;
        else if (wr_change)     live <= 1'b1;
    end

    // ---- the PSG mute hold -------------------------------------------------
    logic [PSG_BITS-1:0] psg_cnt;
    always_ff @(posedge sys_clk) begin
        if (reset)             psg_cnt <= {PSG_BITS{1'b0}};
        else if (psg_act)      psg_cnt <= {PSG_BITS{1'b1}};
        else if (psg_cnt != 0) psg_cnt <= psg_cnt - 1'b1;
    end

    // psg_zero is (psg_cnt == 0) PRECOMPUTED into a flop, and it is a timing
    // fix, not a style choice. `cx_en` is audio_mixer's src_en[6] - a REGISTER
    // ENABLE in another module - so the plain compare put a 13-bit reduction
    // between this counter and that enable cone, across the routing between the
    // two blocks. That is the enable-cone rule (doc/dev/gotchas.md) and it went
    // to a real VIOLATION, -0.169 ns / TNS -2.134, when the МПИ slot's pins
    // re-placed the fitter - in a module the slot edit never touched. Same cure
    // as sdram_ctrl's wait_zero and ref_zero: the compare moves onto the
    // counter's own load path, where it is plain flop-to-flop with a whole
    // clock period, and the enable becomes a single flop output.
    //
    // Cycle-exact by construction: the counter only reloads to all-ones or
    // decrements, so it reaches 0 exactly one cycle after it held 1.
    logic psg_zero;
    always_ff @(posedge sys_clk) begin
        if (reset)             psg_zero <= 1'b1;
        else if (psg_act)      psg_zero <= 1'b0;
        else if (psg_cnt != 0) psg_zero <= (psg_cnt == {{(PSG_BITS-1){1'b0}}, 1'b1});
    end

    assign cx_en = live & psg_zero;

endmodule
