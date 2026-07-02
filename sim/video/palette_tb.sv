// palette_apply unit test - pins down the exact slot/bit conventions that the
// FB writer, readout and gen_expected.py all mirror (see palette_apply.sv).
`timescale 1ns/1ps
module palette_tb;

    logic        screen_mode, line_en;
    logic [15:0] word;
    wire  [63:0] slots;
    integer      errors = 0;

    palette_apply dut (.*);

    task check(input [63:0] exp, input [127:0] name);
        #1;
        if (slots !== exp) begin
            $display("FAIL %0s: got %016h exp %016h", name, slots, exp);
            errors = errors + 1;
        end else
            $display("ok   %0s: %016h", name, slots);
    endtask

    initial begin
        line_en = 1;

        // mono: bit s -> slot s, LSB-first, 0/15
        screen_mode = 1;
        word = 16'h0001; check(64'h0000_0000_0000_000F, "mono lsb");
        word = 16'h8000; check(64'hF000_0000_0000_0000, "mono msb");
        word = 16'h8001; check(64'hF000_0000_0000_000F, "mono both ends");
        word = 16'hFFFF; check(64'hFFFF_FFFF_FFFF_FFFF, "mono all");

        // colour: pixel k = bits[2k+1:2k] -> slots 2k,2k+1 duplicated, index 0..3
        screen_mode = 0;
        word = 16'h00E4; check(64'h0000_0000_3322_1100, "colour 0,1,2,3");
        word = 16'hC000; check(64'h3300_0000_0000_0000, "colour msb pixel");
        word = 16'hFFFF; check(64'h3333_3333_3333_3333, "colour all red");
        word = 16'h0002; check(64'h0000_0000_0000_0022, "colour lsb pixel=2");

        // line_en=0 blanks everything in both modes
        line_en = 0;
        word = 16'hFFFF;
        screen_mode = 1; check(64'h0, "mono blanked");
        screen_mode = 0; check(64'h0, "colour blanked");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

endmodule
