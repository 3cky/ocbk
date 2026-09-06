// Host-ROM deselect oracle for qbus_slot: rom_dsl_vec against the four МПИ
// deselect wires, in both models.
//
// This is a unit bench, not an SoC leg. The property it pins is a PER-MODEL
// PHYSICAL FACT that no BK-0010 program can reach:
//
//   * BAS / BAS2 / MON10 are wired only on a BK-0010, M11 / P4O only on a
//     BK-0011M, while the adapter routes all four in both cases. The model
//     gate is what emulates which wires EXIST. A module drives them with no
//     idea which host it is in.
//   * MON10 and M11 are AFTER-MARKET wires the SMK512 installation adds, on no
//     stock schematic. M11 takes the BK-0011M BOS at 140000-157777 (segs 4,5)
//     so the module can put RAM there - it is NOT the 160000 window.
//   * 160000-177577 on a BK-0011M is NOT motherboard ROM - МСТД is itself an
//     МПИ card, so it is mutually exclusive with any other module. When the
//     slot is live on a BK-0011M the connector owns segments 6,7 whatever the
//     wires do, and our mstd11m blob image must stand down. This is the path
//     the SMK512 start vector needs: PC = 0166400 is in segment 6.
//   * On a BK-0010 the same addresses ARE on the motherboard (BASIC bank 3),
//     so there they go away only when the module asserts BAS2.
//   * DIP 8 (the internal SMK512) kills the whole vector in both models, and
//     so does an ABSENT ADAPTER - slot pin 44 is tied to GND by the adapter,
//     and with it missing the МПИ pins are a bare MSX edge. That term is what
//     keeps a BK-0011M with no adapter on its own mstd11m image instead of
//     conceding a window to a module that is not there.
`timescale 1ns/1ps

module dsl_tb;

    reg cpu_clk = 1'b0;
    always #10 cpu_clk = ~cpu_clk;

    reg rst_n = 1'b0, dclo_n = 1'b1;
    reg model_bk11 = 1'b0, smk_en = 1'b0;
    reg mon10_n = 1'b1, bas10_n = 1'b1, bas2_n = 1'b1, mon11_n = 1'b1;
    reg present_n = 1'b0;       // low = the МПИ adapter is fitted

    wire [7:0]  rom_dsl_vec;
    wire [15:0] mpi_word;
    wire        rom4_force;
    wire [15:0] pSltAd;
    tri1        pSltRom4_n;
    wire [15:0] ad_n;
    wire        rply_n;
    integer     fails = 0;

    qbus_slot u_slot (
        .cpu_clk(cpu_clk), .rst_n(rst_n), .dclo_n(dclo_n),
        .ad_n(ad_n), .sync_n(1'b1), .din_n(1'b1), .dout_n(1'b1),
        .wtbt_n(1'b1), .sel1_n(1'b1), .init_n(1'b1), .e_037_n(1'b1),
        .rply_n(rply_n),
        .model_bk11(model_bk11), .smk_en(smk_en), .rom3(1'b0), .rom4(1'b0),
        .rom_dsl_vec(rom_dsl_vec), .mpi_word(mpi_word), .rom4_force(rom4_force),
        .pSltAd(pSltAd),
        .pSltSync_n(), .pSltDin_n(), .pSltDout_n(), .pSltWtbt_n(),
        .pSltRply_n(1'b1), .pSltInit_n(), .pSltRom3_n(),
        .pSltRom4_n(pSltRom4_n), .pSltE_n(),
        .pSltMon10_n(mon10_n), .pSltBas10_n(bas10_n),
        .pSltBas2_n(bas2_n),   .pSltMon11_n(mon11_n),
        .pSltPresent_n(present_n)
    );

    // The four wires are active low at the pad (the adapter's BSS138 inverts
    // the МПИ's active-high assertion). Settle time covers the 3-FF sync plus
    // the bus-idle load of rom_dsl_vec.
    task check (input m11mode, input [3:0] drive, input [7:0] want,
                input [255:0] what);
        begin
            model_bk11 = m11mode;
            {mon11_n, bas2_n, bas10_n, mon10_n} = ~drive;
            repeat (12) @(posedge cpu_clk);
            #1;
            if (rom_dsl_vec !== want) begin
                $display("DSL-ERROR: %0s: bk11=%0b drive=%b -> %b, want %b",
                         what, m11mode, drive, rom_dsl_vec, want);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge cpu_clk);
        rst_n = 1'b1;
        repeat (4) @(posedge cpu_clk);

        // ---- BK-0010: the three bk10 wires work, M11 does nothing ---------
        check(1'b0, 4'b0000, 8'b0000_0000, "bk10 idle");
        check(1'b0, 4'b0001, 8'b0000_0011, "bk10 MON10 -> segs 0,1");
        check(1'b0, 4'b0010, 8'b0011_1100, "bk10 BAS  -> segs 2-5");
        check(1'b0, 4'b0100, 8'b1100_0000, "bk10 BAS2 -> segs 6,7");
        check(1'b0, 4'b1000, 8'b0000_0000, "bk10 M11 alone moves nothing");
        check(1'b0, 4'b0111, 8'b1111_1111, "bk10 all three = the SMK reset state");

        // ---- BK-0011M: the bk10 wires do nothing; segs 6,7 are conceded ----
        // This is the new one. The host has no ROM at 160000-177577 with a
        // module in the slot, so the concede must not depend on any wire.
        check(1'b1, 4'b0000, 8'b1100_0000, "bk11 idle -> МСТД card absent");
        check(1'b1, 4'b0111, 8'b1100_0000, "bk11 ignores MON10/BAS/BAS2");
        check(1'b1, 4'b1000, 8'b1111_0000, "bk11 M11 -> BOS segs 4,5 as well");
        check(1'b1, 4'b1111, 8'b1111_0000, "bk11 M11 with the bk10 wires too");

        // ---- DIP 8: the internal SMK512, so the slot stands down ----------
        smk_en = 1'b1;
        check(1'b0, 4'b0111, 8'b0000_0000, "bk10 DIP 8 kills the vector");
        check(1'b1, 4'b1111, 8'b0000_0000, "bk11 DIP 8 kills the concede");
        smk_en = 1'b0;

        // ---- no adapter: the same stand-down, for the other reason --------
        // A bk11 here MUST keep its mstd11m image: there is no module to
        // concede 160000-177577 to, and the deselect pins are floating.
        present_n = 1'b1;
        check(1'b0, 4'b0111, 8'b0000_0000, "bk10 no adapter -> nothing moves");
        check(1'b1, 4'b1111, 8'b0000_0000, "bk11 no adapter -> BOS + МСТД stay");
        present_n = 1'b0;
        check(1'b1, 4'b0000, 8'b1100_0000, "adapter back -> bk11 concedes again");

        if (fails == 0) $display("COSIM PASS");
        else            $display("COSIM FAIL");
        $finish;
    end

endmodule
