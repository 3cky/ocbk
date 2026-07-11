// palette_apply unit test - pins down the exact slot/bit conventions that the
// FB writer, readout and gen_expected.py all mirror (see palette_apply.sv),
// and (Phase 7) the full 16-palette BK-0011M table against an INDEPENDENTLY
// transcribed expected list: EXPC below was decoded by hand from the MiSTer
// rtl/video.sv palettes[16] hex (c_p = colour nibble for pixel value p, i.e.
// the {p[0],p[1]} nibble swizzle already applied), so a swizzle mistake in
// the RTL cannot cancel out here.
`timescale 1ns/1ps
module palette_tb;

    logic        screen_mode, line_en;
    logic [3:0]  pal_idx;
    logic [15:0] word;
    wire  [63:0] slots;
    integer      errors = 0;

    palette_apply dut (.*);

    // Expected colours per palette, packed {c3, c2, c1, c0}: c0 = pixel 00,
    // c1 = pixel 01, c2 = pixel 10, c3 = pixel 11. Each nibble is the
    // physical colour {R1, B, G, R0}. Hand-decoded from MiSTer video.sv
    // (palette 0 = black/blue/green/red = the BK-0010 palette). Packed
    // vector, palette 0 at [15:0] (Icarus: no unpacked-array localparams).
    localparam [255:0] EXPC = {
        16'hF260, 16'hF2B0, 16'hFB60, 16'h6290,   // 15 14 13 12
        16'h9B60, 16'h8CA0, 16'h1530, 16'hD5C0,   // 11 10  9  8
        16'hB3A0, 16'h9180, 16'hFFF0, 16'hF6D0,   //  7  6  5  4
        16'hB620, 16'hD460, 16'h9DB0, 16'h9240    //  3  2  1  0
    };

    task check(input [63:0] exp, input [127:0] name);
        #1;
        if (slots !== exp) begin
            $display("FAIL %0s: got %016h exp %016h", name, slots, exp);
            errors = errors + 1;
        end else
            $display("ok   %0s: %016h", name, slots);
    endtask

    integer p;
    reg [3:0]   c0, c1, c2, c3;
    reg [63:0]  exp;
    reg [127:0] nm;

    initial begin
        line_en = 1;
        pal_idx = 0;

        // mono: bit s -> slot s, LSB-first, 0/15
        screen_mode = 1;
        word = 16'h0001; check(64'h0000_0000_0000_000F, "mono lsb");
        word = 16'h8000; check(64'hF000_0000_0000_0000, "mono msb");
        word = 16'h8001; check(64'hF000_0000_0000_000F, "mono both ends");
        word = 16'hFFFF; check(64'hFFFF_FFFF_FFFF_FFFF, "mono all");

        // mono ignores the palette select (real hardware: 1bpp bypasses it)
        pal_idx = 4'd7;
        word = 16'h8001; check(64'hF000_0000_0000_000F, "mono pal-independent");
        pal_idx = 0;

        // colour, palette 0 (= BK-0010): pixel k = bits[2k+1:2k] -> slots
        // 2k,2k+1 duplicated; physical nibbles black=0 blue=4 green=2 red=9
        screen_mode = 0;
        word = 16'h00E4; check(64'h0000_0000_9922_4400, "colour 0,1,2,3");
        word = 16'hC000; check(64'h9900_0000_0000_0000, "colour msb pixel");
        word = 16'hFFFF; check(64'h9999_9999_9999_9999, "colour all red");
        word = 16'h0002; check(64'h0000_0000_0000_0022, "colour lsb pixel=2");

        // colour: all 16 BK-0011M palettes, all 4 pixel values at once
        // (word 00E4 = pixels 0,1,2,3 then five 00 pixels)
        word = 16'h00E4;
        for (p = 0; p < 16; p = p + 1) begin
            pal_idx = p[3:0];
            {c3, c2, c1, c0} = EXPC[16*p +: 16];
            exp = {{8{c0}}, c3, c3, c2, c2, c1, c1, c0, c0};
            $sformat(nm, "palette %0d", p);
            check(exp, nm);
        end
        pal_idx = 0;

        // line_en=0 blanks everything in both modes (palette irrelevant)
        line_en = 0;
        word = 16'hFFFF;
        pal_idx = 4'd11;
        screen_mode = 1; check(64'h0, "mono blanked");
        screen_mode = 0; check(64'h0, "colour blanked");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

endmodule
