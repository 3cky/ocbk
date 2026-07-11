// clkgen_tb - unit oracle for cpu_clkgen (Phase 7 model-selected CPU clock).
//
// No SoC testbench instantiates ocbk_top (they all replicate the divider
// locally), so this tb is the ONLY sim coverage of the real divider chain.
// Three legs:
//
//   A. BK-0010 identity: a cpu_clkgen held at model_bk11=0 must be
//      BIT-IDENTICAL every sys_clk - cpu_clk, cpu_clk_n, dot_ena, en_pos,
//      en_neg - to a replica of the historical divc[4:0] counter-tap chain
//      (the pre-Phase-7 ocbk_top code, kept verbatim below). This is the
//      regression anchor: BK-0010 hardware timing cannot move.
//
//   B. BK-0011M rate: model_bk11=1 in steady state must give half-periods of
//      exactly 12 sys_clk (period 24 = 96.65/24 = 4.03 MHz, 50% duty), with
//      the /16 enables still identical to the replica (model-independent).
//
//   C. Retarget (the warm-reset DCLO-hold shape): flipping model_bk11
//      mid-count, both directions, at every count phase, must never produce
//      a half-period outside 12..16 sys_clk (no runt, no stall), and must
//      settle to the exact new rate within two toggles.
//
// Self-checking; prints COSIM PASS / CLKGEN-ERROR lines (run_clkgen.sh greps).
`timescale 1ns/1ps

module clkgen_tb;

    reg  sys_clk = 1'b0;
    reg  rst_n   = 1'b0;
    always #5.173 sys_clk = ~sys_clk;      // ~96.65 MHz

    integer errors = 0;

    // ---- DUT 0: pinned BK-0010 mode (leg A) ------------------------------
    wire c0_cpu, c0_cpun, c0_dot, c0_pos, c0_neg;
    cpu_clkgen dut0 (
        .sys_clk(sys_clk), .rst_n(rst_n), .model_bk11(1'b0),
        .cpu_clk(c0_cpu), .cpu_clk_n(c0_cpun),
        .dot_ena(c0_dot), .en_pos(c0_pos), .en_neg(c0_neg)
    );

    // ---- DUT X: tb-driven model (legs B, C) ------------------------------
    reg  model = 1'b0;
    wire cx_cpu, cx_cpun, cx_dot, cx_pos, cx_neg;
    cpu_clkgen dutx (
        .sys_clk(sys_clk), .rst_n(rst_n), .model_bk11(model),
        .cpu_clk(cx_cpu), .cpu_clk_n(cx_cpun),
        .dot_ena(cx_dot), .en_pos(cx_pos), .en_neg(cx_neg)
    );

    // ---- replica of the pre-Phase-7 ocbk_top divider (verbatim) ----------
    reg [4:0] divc;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) divc <= 5'd0;
        else        divc <= divc + 1'b1;
    end
    wire r_dot  = (divc[2:0] == 3'b000);
    wire r_cpu  =  divc[4];
    wire r_cpun = ~divc[4];
    wire r_pos  = (divc[3:0] == 4'd15);
    wire r_neg  = (divc[3:0] == 4'd7);

    // ---- leg A: continuous bit-identity, checked on the falling edge -----
    always @(negedge sys_clk) if (rst_n) begin
        if (c0_cpu !== r_cpu || c0_cpun !== r_cpun) begin
            errors = errors + 1;
            $display("CLKGEN-ERROR @%0t: BK-0010 cpu_clk %b/%b != replica %b/%b",
                     $time, c0_cpu, c0_cpun, r_cpu, r_cpun);
        end
        if (c0_dot !== r_dot || c0_pos !== r_pos || c0_neg !== r_neg) begin
            errors = errors + 1;
            $display("CLKGEN-ERROR @%0t: BK-0010 enables %b%b%b != replica %b%b%b",
                     $time, c0_dot, c0_pos, c0_neg, r_dot, r_pos, r_neg);
        end
        // enables are model-independent: dutx must match too, whatever model is
        if (cx_dot !== r_dot || cx_pos !== r_pos || cx_neg !== r_neg) begin
            errors = errors + 1;
            $display("CLKGEN-ERROR @%0t: dutx enables %b%b%b != replica %b%b%b",
                     $time, cx_dot, cx_pos, cx_neg, r_dot, r_pos, r_neg);
        end
    end

    // ---- dutx half-period monitor -----------------------------------------
    // width = sys_clk ticks between cpu_clk toggle DETECTIONS (detection lags
    // the toggle by one constant cycle, which cancels between two detections
    // - so the first width after reset, referenced to reset release instead
    // of a detection, is not checked: have_ref). Bounds: always 12..16; when
    // the model has been stable for >= 2 toggles, exactly the model's
    // half-period.
    integer width = 0;
    integer toggles_since_flip = 2;     // arm exact-checking from reset
    reg     cx_prev = 1'b0;
    reg     have_ref = 1'b0;
    always @(posedge sys_clk) if (rst_n) begin
        width <= width + 1;
        if (cx_cpu !== cx_prev) begin
            cx_prev <= cx_cpu;
            if (have_ref && (width + 1 < 12 || width + 1 > 16)) begin
                errors = errors + 1;
                $display("CLKGEN-ERROR @%0t: half-period %0d outside 12..16",
                         $time, width + 1);
            end
            if (have_ref && toggles_since_flip >= 2 &&
                (width + 1) !== (model ? 12 : 16)) begin
                errors = errors + 1;
                $display("CLKGEN-ERROR @%0t: settled half-period %0d != %0d (model=%b)",
                         $time, width + 1, model ? 12 : 16, model);
            end
            if (toggles_since_flip < 2)
                toggles_since_flip = toggles_since_flip + 1;
            have_ref = 1'b1;
            width <= 0;
        end
    end

    task flip_model;
        begin
            @(negedge sys_clk);
            model = ~model;
            toggles_since_flip = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (5) @(negedge sys_clk);
        rst_n = 1'b1;

        // Leg A+B warm-up: dutx still BK-0010, prove /32 exactness too.
        repeat (2000) @(negedge sys_clk);

        // Leg B: switch to BK-0011M, let it settle, hold for many periods.
        flip_model;                         // -> /24
        repeat (5000) @(negedge sys_clk);

        // Leg C: flip at every count phase, both directions (24+32 = one
        // full period of each mode swept in steps of 1 sys_clk via the +1
        // stride against the 24/32 periods).
        for (i = 0; i < 200; i = i + 1) begin
            repeat (30 + i) @(negedge sys_clk);
            flip_model;
        end
        repeat (5000) @(negedge sys_clk);

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

endmodule
