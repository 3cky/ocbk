// ============================================================================
//  bk_audio_tb - unit oracle for the BK 1-bit speaker -> R-2R sound DAC path
//  and the Phase-6 CMT (cassette) jack mode.
//
//  Audio mode: drives spk_bit toggles on sys_clk and checks the board-proven
//  push-pull DAC drive: full-swing code (spk=1 -> 63, spk=0 -> 0), mono
//  (dac_l == dac_r, all bits enabled), mid-scale (32) held while rst_n is
//  asserted, and the `active` one-shot going high on speaker toggling and
//  decaying to 0 when the speaker goes idle.
//
//  CMT mode (cmt_mode=1, the tape motor running): the right channel must
//  become the esemsx3 comparator network - [5:4] tri-stated (oe=001111),
//  [3]=tape_lvl, [2]=~tape_lvl, [1]=0, [0]=the speaker level (CmtOut) - and
//  tape_lvl must follow the cmt_in_pad sample through the 2-FF sync (the
//  Schmitt feedback loop). The left channel stays audio throughout.
// ============================================================================
`timescale 1ns/1ps
module bk_audio_tb;

    logic       sys_clk = 1'b0;
    logic       rst_n   = 1'b0;
    logic       spk_bit = 1'b0;
    logic       cmt_mode = 1'b0;
    logic       ext_lvl  = 1'b0;   // "tape recorder" level at the jack
    logic [5:0] dac_l, dac_r_o, dac_r_oe;
    logic       tape_lvl, active;

    // Pad model: in CMT mode bit 5 is released and the external tape signal
    // wins; when driven, the DUT's own output loops back (never happens for
    // bit 5 in CMT mode - that's the point of the oe split).
    wire pad_sr5 = dac_r_oe[5] ? dac_r_o[5] : ext_lvl;

    integer errors = 0;

    bk_audio dut (
        .sys_clk    (sys_clk),
        .rst_n      (rst_n),
        .spk_bit    (spk_bit),
        .cmt_mode   (cmt_mode),
        .cmt_in_pad (pad_sr5),
        .tape_lvl   (tape_lvl),
        .dac_l      (dac_l),
        .dac_r_o    (dac_r_o),
        .dac_r_oe   (dac_r_oe),
        .active     (active)
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
            if (dac_r_o !== dac_l || dac_r_oe !== 6'b111111)
                begin $display("AUDIO-ERROR channels not mono: l=%0d r=%0d oe=%b",
                               dac_l, dac_r_o, dac_r_oe); errors = errors + 1; end
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

    // Check the CMT-mode right-channel network for the current tape/spk levels.
    task check_cmt(input tlvl, input slvl);
        begin
            if (dac_r_oe !== 6'b001111)
                begin $display("AUDIO-ERROR cmt oe exp=001111 got=%b", dac_r_oe);
                      errors = errors + 1; end
            if (tape_lvl !== tlvl)
                begin $display("AUDIO-ERROR tape_lvl exp=%b got=%b", tlvl, tape_lvl);
                      errors = errors + 1; end
            if (dac_r_o[3:0] !== {tlvl, ~tlvl, 1'b0, slvl})
                begin $display("AUDIO-ERROR cmt net exp=%b got=%b",
                               {tlvl, ~tlvl, 1'b0, slvl}, dac_r_o[3:0]);
                      errors = errors + 1; end
        end
    endtask

    integer k;
    initial begin
        // --- reset held: DACs must hold mid-scale (no DC step) --------------
        repeat (3) @(posedge sys_clk);
        #1;
        if (dac_l !== 6'd32 || dac_r_o !== 6'd32 || dac_r_oe !== 6'b111111)
            begin $display("AUDIO-ERROR DAC not mid-scale under reset: l=%0d r=%0d oe=%b",
                           dac_l, dac_r_o, dac_r_oe); errors = errors + 1; end

        // --- release reset and exercise a toggle sequence -------------------
        @(posedge sys_clk); rst_n = 1'b1;

        apply(1'b0);   // idle low
        apply(1'b1);   // speaker high
        apply(1'b0);   // back low
        apply(1'b1);
        apply(1'b1);   // stays high (no spurious change)
        apply(1'b0);

        // --- CMT mode: right channel becomes the comparator network ---------
        ext_lvl  = 1'b0;
        cmt_mode = 1'b1;
        repeat (4) @(posedge sys_clk);
        #1 check_cmt(1'b0, 1'b0);
        // tape signal rises: tape_lvl follows through the 2-FF sync and the
        // feedback bits [3:2] flip with it
        ext_lvl = 1'b1;
        repeat (4) @(posedge sys_clk);
        #1 check_cmt(1'b1, 1'b0);
        // CmtOut carries the speaker level (BK tape-out IS bit 6)
        spk_bit = 1'b1;
        repeat (4) @(posedge sys_clk);
        #1 check_cmt(1'b1, 1'b1);
        ext_lvl = 1'b0;
        repeat (4) @(posedge sys_clk);
        #1 check_cmt(1'b0, 1'b1);
        // left channel stayed audio all along
        if (dac_l !== 6'd63)
            begin $display("AUDIO-ERROR dac_l lost audio in CMT mode: %0d", dac_l);
                  errors = errors + 1; end

        // --- back to audio mode: mono push-pull returns, tape_lvl forced 0
        //     (the audio drive on the pad must not echo into the tape bit) ---
        cmt_mode = 1'b0;
        spk_bit  = 1'b0;
        repeat (4) @(posedge sys_clk);
        #1 check_level(1'b0);
        spk_bit = 1'b1;
        repeat (4) @(posedge sys_clk);
        #1 if (tape_lvl !== 1'b0)
            begin $display("AUDIO-ERROR tape_lvl echoes audio when CMT off");
                  errors = errors + 1; end
        spk_bit = 1'b0;
        repeat (4) @(posedge sys_clk);

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
