// cpu_clkgen - the fabric clock-divider chain off the 96.65 MHz VCO.
//
// Two independent dividers, one reset (the PLL lock), free-running from the
// same edge so their phase relation is deterministic:
//
//  - the fixed /16 chain: dot_ena (96.65/8 = 12.08 MHz strobe, spare) and the
//    037 CLKIN enables en_pos/en_neg (96.65/16 = 6.04 MHz; see va_037_sync).
//    Model-independent - the 037 is BK-0010 video either way.
//
//  - the CPU clock: a toggle divider, 50% duty, model-selected rate:
//      model_bk11 = 0  toggle every 16 sys_clk  -> /32 = 3.02 MHz (BK-0010)
//      model_bk11 = 1  toggle every 12 sys_clk  -> /24 = 4.03 MHz (BK-0011M)
//      turbo (either model)  every  8 sys_clk  -> /16 = 6.04 MHz
//    Turbo OVERRIDES the model rate and is explicitly non-authentic: at /16 the
//    CPU clock equals CLKIN (ratio 1:1 instead of the real 1:2 / 1:1.5), which
//    is only sane because turbo also switches the 037 out of the RAM path
//    (va_037_sync's no_steal - see qbus_pkg's N_TURBO). Unlike model_bk11 it is
//    a LIVE control (PS/2 F12), not a DCLO-hold latch; ocbk_top qualifies it on
//    a bus-idle edge, so a retarget never lands mid-transaction.
//    /32 mode: first rising edge 16 sys_clk after reset release, edges
//    coinciding with the en_pos/en_neg fires (CPU = CLKIN/2). sim/clkgen_tb.v
//    pins this waveform exactly, so BK-0010 hardware timing cannot move.
//    /24 mode: the CPU:CLKIN phase walks a 48-sys_clk pattern instead
//    (offsets 0/4/8 sys_clk) - deterministic, and MEASURED not to cost
//    0011M cycle accuracy (12 phase/duty combinations, all flat; the real
//    divergence is the 037 grant rule - see va_037_sync's GRANT_SETUP).
//
// model_bk11 must only change while the CPU is held in reset (ocbk_top latches
// DIP 1 during the DCLO hold); turbo may change at any bus-idle instant. A
// retarget is glitch-free by construction either way: the >= wrap compare means
// a mid-count target change only stretches/shrinks the current half-period to
// 8..16 sys_clk - never a runt pulse.
module cpu_clkgen (
    input  logic sys_clk,     // 96.65 MHz VCO (altpll clk0)
    input  logic rst_n,       // PLL locked (async assert)
    input  logic model_bk11,  // 0 = BK-0010 (/32), 1 = BK-0011M (/24)
    input  logic turbo,       // 1 = /16 turbo (6.04 MHz), overrides model_bk11

    output logic cpu_clk,     // 50% duty CPU clock  -> vm1 pin_clk_p
    output logic cpu_clk_n,   // anti-phase pair     -> vm1 pin_clk_n
    output logic dot_ena,     // 12.08 MHz 1-in-8 enable strobe (spare)
    output logic en_pos,      // 037 "posedge CLKIN" enable (/16)
    output logic en_neg       // 037 "negedge CLKIN" enable (/16)
);

    // --- fixed /16 chain: dot strobe + 037 CLKIN enables ------------------
    logic [3:0] divc;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) divc <= '0;
        else        divc <= divc + 1'b1;
    end

    assign dot_ena = (divc[2:0] == 3'b000);
    assign en_pos  = (divc == 4'd15);   // "posedge CLKIN" (divc -> 0)
    assign en_neg  = (divc == 4'd7);    // "negedge CLKIN" (divc -> 8)

    // --- programmable CPU-clock toggle divider ----------------------------
    logic [3:0] cdiv;
    logic       cpu_clk_r;              // the SDC generated-clock anchor
    // turbo re-registered locally - the model_bk11_q idiom (CLAUDE.md: "a
    // quasi-static signal with big fanout still costs real setup time"). It
    // comes from a top-level flop and fans out to the 037 and qbus_mem as well,
    // so the fitter routes it far; one flop here ends that route next to the
    // comparator. The 1-cycle lag is invisible - ocbk_top only moves the level
    // on a bus-idle edge, and a retarget is glitch-free at any count phase.
    logic turbo_q;
    always_ff @(posedge sys_clk or negedge rst_n)
        if (!rst_n) turbo_q <= 1'b0;
        else        turbo_q <= turbo;

    wire  [3:0] cdiv_last = turbo_q ? 4'd7 : (model_bk11 ? 4'd11 : 4'd15);
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            cdiv      <= '0;
            cpu_clk_r <= 1'b0;
        end else if (cdiv >= cdiv_last) begin
            cdiv      <= '0;
            cpu_clk_r <= ~cpu_clk_r;
        end else begin
            cdiv      <= cdiv + 1'b1;
        end
    end

    assign cpu_clk   =  cpu_clk_r;
    assign cpu_clk_n = ~cpu_clk_r;

endmodule
