// ============================================================================
//  bk_audio_tb - unit oracle for the BK 1-bit speaker -> R-2R sound DAC path.
//
//  Drives spk_bit toggles on sys_clk and checks the board-proven push-pull DAC
//  drive: full-swing code (spk=1 -> 63, spk=0 -> 0), mono (dac_l == dac_r),
//  mid-scale (32) held while rst_n is asserted, and the `active` one-shot going
//  high on speaker toggling and decaying to 0 when the speaker goes idle.
// ============================================================================
`timescale 1ns/1ps
module bk_audio_tb;

    logic       sys_clk = 1'b0;
    logic       rst_n   = 1'b0;
    logic       spk_bit = 1'b0;
    logic [5:0] dac_l, dac_r;
    logic       active;

    integer errors = 0;

    bk_audio dut (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .spk_bit (spk_bit),
        .dac_l   (dac_l),
        .dac_r   (dac_r),
        .active  (active)
    );

    always #5 sys_clk = ~sys_clk;

    // Check the DAC drive for an expected 1-bit level (after resync settled).
    task check_level(input lvl);
        reg [5:0] exp;
        begin
            exp = lvl ? 6'd63 : 6'd0;
            if (dac_l !== exp)
                begin $display("AUDIO-ERROR dac_l: lvl=%b exp=%0d got=%0d",
                               lvl, exp, dac_l); errors = errors + 1; end
            if (dac_r !== dac_l)
                begin $display("AUDIO-ERROR channels not mono: l=%0d r=%0d", dac_l, dac_r);
                      errors = errors + 1; end
        end
    endtask

    // Apply a speaker level, wait out the 2-FF resync, then verify.
    task apply(input lvl);
        begin
            spk_bit = lvl;
            repeat (4) @(posedge sys_clk);
            #1 check_level(lvl);
        end
    endtask

    integer k;
    initial begin
        // --- reset held: DACs must hold mid-scale (no DC step) --------------
        repeat (3) @(posedge sys_clk);
        #1;
        if (dac_l !== 6'd32 || dac_r !== 6'd32)
            begin $display("AUDIO-ERROR DAC not mid-scale under reset: l=%0d r=%0d",
                           dac_l, dac_r); errors = errors + 1; end

        // --- release reset and exercise a toggle sequence -------------------
        @(posedge sys_clk); rst_n = 1'b1;

        apply(1'b0);   // idle low
        apply(1'b1);   // speaker high
        apply(1'b0);   // back low
        apply(1'b1);
        apply(1'b1);   // stays high (no spurious change)
        apply(1'b0);

        // --- activity indicator: toggling -> active high -------------------
        for (k = 0; k < 8; k = k + 1) apply(k[0]);
        #1 if (active !== 1'b1)
            begin $display("AUDIO-ERROR active low while toggling"); errors = errors + 1; end

        // --- go idle: activity one-shot must eventually decay to 0 ----------
        spk_bit = 1'b0;
        repeat (20'hFFFFF + 100) @(posedge sys_clk);
        #1 if (active !== 1'b0)
            begin $display("AUDIO-ERROR active stuck high when idle"); errors = errors + 1; end

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
