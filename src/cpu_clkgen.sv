// cpu_clkgen - the fabric clock-divider chain off the 96.65 MHz VCO (Phase 7).
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
//    In /32 mode this is cycle-identical to the historical divc[4] counter
//    tap (first rising edge 16 sys_clk after reset release; edges coincide
//    with en_pos/en_neg fires, CPU = CLKIN/2) - pinned by sim/clkgen_tb.v
//    against a replica of that tap, so BK-0010 hardware timing cannot move.
//    In /24 mode the CPU:CLKIN phase walks a 48-sys_clk pattern instead
//    (offsets 0/4/8 sys_clk) - deterministic, and 0011M cycle-accuracy
//    against a reference is a later Phase-7 item (see ROADMAP).
//
// model_bk11 must only change while the CPU is held in reset (ocbk_top latches
// DIP 1 during the DCLO hold). A retarget is still glitch-free by construction:
// the >= wrap compare means a mid-count target change only stretches/shrinks
// the current half-period to 12..16 sys_clk - never a runt pulse.
module cpu_clkgen (
    input  logic sys_clk,     // 96.65 MHz VCO (altpll clk0)
    input  logic rst_n,       // PLL locked (async assert)
    input  logic model_bk11,  // 0 = BK-0010 (/32), 1 = BK-0011M (/24)

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
    wire  [3:0] cdiv_last = model_bk11 ? 4'd11 : 4'd15;
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
