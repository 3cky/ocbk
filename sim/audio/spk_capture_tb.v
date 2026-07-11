// ============================================================================
//  spk_capture_tb - directed oracle for the 177716 register bits in qbus_mem.
//  Drives real Q-bus write cycles (SYNC latches the address, DOUT presents
//  the data) to 177716 and checks spk_bit (bit 6) and mot_bit (bit 7, tape
//  motor; 1 = stopped) follow the written data - the key point being that the
//  capture must NOT depend on the ROM/IO wait FSM's reply (the vm1
//  self-replies for 177700-177717, so the FSM never sees the write). Also
//  checks a write to a different I/O address leaves the latches alone, that
//  nINIT does NOT clear them (software-owned; it does clear the bit-2
//  write-flag), and - via real DATI cycles - that the 177716 read word
//  carries the start vector, the write-flag, the kbd bit and the Phase-6
//  tape-in level on bit 5.
// ============================================================================
`timescale 1ns/1ps
module spk_capture_tb;

    // clocks
    logic sclk = 0;  always #5  sclk = ~sclk;   // ~100 MHz stand-in for sys_clk
    logic cclk = 0;  always #160 cclk = ~cclk;  // ~3 MHz stand-in for cpu_clk

    // Q-bus (inverted / active-low)
    logic [15:0] ad_drive = 16'hFFFF;
    logic        ad_oe    = 1'b0;
    wire  [15:0] ad_n;
    assign ad_n = ad_oe ? ad_drive : 16'hzzzz;   // tb == the "CPU" driver

    logic sync_n = 1'b1, din_n = 1'b1, dout_n = 1'b1, wtbt_n = 1'b1;
    // CPU register-select pins (push-pull from the vm1.v hook): the tb models
    // the core's behaviour - decoded from the address during the address
    // phase, stable before SYNC falls, held for the whole cycle.
    logic sel1_n = 1'b1, sel2_n = 1'b1;
    logic reset  = 1'b1;   // = ~dclo_n; held at power-on to init the wait FSM
    logic init_n  = 1'b1;  // Q-bus nINIT (pulsed by the RESET-instruction test)
    logic model_bk11 = 1'b0;  // flipped by the Phase-7 banking-gate cases
    logic tape_in = 1'b0;  // CMT comparator level -> 177716 read bit 5
    wire        spk_bit;
    wire        mot_bit;
    wire        rply_n;
    wire [15:0] bus_addr;
    wire        s_dq_dummy;   // unused SDRAM data bus stays floating

    integer errors = 0;

    qbus_mem dut (
        .cpu_clk   (cclk),
        .reset     (reset),
        .init_n    (init_n),
        .kbd_down  (1'b0),
        .tape_in   (tape_in),
        .sel1_n    (sel1_n),
        .sel2_n    (sel2_n),
        .model_bk11(model_bk11),
        .sclk      (sclk),
        .srst_n    (1'b1),
        .init_done (),
        .ad_n      (ad_n),
        .sync_n    (sync_n),
        .din_n     (din_n),
        .dout_n    (dout_n),
        .wtbt_n    (wtbt_n),
        .rply_n    (rply_n),
        .mem_ready (),
        .boot_active(1'b0),
        .bw_req    (1'b0), .bw_addr('0), .bw_wdata('0), .bw_gnt(),
        .v1_req(1'b0), .v1_addr('0), .v1_gnt(), .v1_rvalid(),
        .v2_req(1'b0), .v2_addr('0), .v2_gnt(), .v2_rvalid(),
        .v3_req(1'b0), .v3_addr('0), .v3_wdata('0), .v3_gnt(), .v_rdata(),
        .s_cke(), .s_cs_n(), .s_ras_n(), .s_cas_n(), .s_we_n(),
        .s_ba(), .s_addr(), .s_dqm(), .s_dq(),
        .bus_addr(bus_addr), .fetch_stb(),
        .spk_bit(spk_bit),
        .mot_bit(mot_bit)
    );

    // One DATO (write) bus cycle: SYNC latches `a`, DOUT presents `d`.
    // NOTE: keeps WTBT asserted through the DOUT window - a BYTE-op signature
    // (dual-purpose WTBT: write at SYNC time, byte at DOUT time). The original
    // Phase-6 cases below all use it, which pins that the spk/mot capture
    // ignores the byte/word distinction in BK-0010 mode.
    task bus_write(input [15:0] a, input [15:0] d);
        begin
            ad_oe = 1'b1; ad_drive = ~a;       // address onto the (inverted) bus
            sel1_n = !(a[15:1] == (16'o177716 >> 1));   // CPU decodes its SEL
            sel2_n = !(a[15:1] == (16'o177714 >> 1));   //   pins at address phase
            #6  sync_n = 1'b0;                  // negedge SYNC latches addr = a
            #6  ad_drive = ~d;                  // switch bus to write data
            #4  wtbt_n = 1'b0;                  // WTBT = write at SYNC, byte at DOUT (unused here)
                dout_n = 1'b1; #1 dout_n = 1'b0;// assert DOUT (data-out phase)
            repeat (4) @(posedge sclk);         // let the sys_clk capture sample
            dout_n = 1'b1; #6 sync_n = 1'b1; wtbt_n = 1'b1; ad_oe = 1'b0;
            sel1_n = 1'b1; sel2_n = 1'b1;
            repeat (2) @(posedge sclk);
        end
    endtask

    // Phase-7 byte/word-explicit DATO cycles: the mem_mapper banking decode
    // keys on WTBT at DOUT time (word write = WTBT RELEASED in the DOUT
    // window; byte write = asserted), exactly what these two model.
    // Unlike the legacy task these hold the DOUT window across two cpu_clk
    // edges (so the ROM/IO wait FSM deterministically observes the write and
    // sets the bit-2 write-flag - the legacy short window only sometimes
    // lands on a cclk edge) and drain the FSM back to idle before returning.
    task bus_write_word(input [15:0] a, input [15:0] d);
        begin
            ad_oe = 1'b1; ad_drive = ~a;
            sel1_n = !(a[15:1] == (16'o177716 >> 1));
            sel2_n = !(a[15:1] == (16'o177714 >> 1));
            wtbt_n = 1'b0;                      // write flag at SYNC time
            #6  sync_n = 1'b0;
            #6  ad_drive = ~d;
            #4  wtbt_n = 1'b1;                  // released at DOUT = WORD op
                dout_n = 1'b1; #1 dout_n = 1'b0;
            repeat (2) @(posedge cclk);         // FSM detection + sclk capture
            #2 dout_n = 1'b1; #6 sync_n = 1'b1; ad_oe = 1'b0;
            sel1_n = 1'b1; sel2_n = 1'b1;
            repeat (2) @(posedge cclk);         // let the FSM drain to idle
        end
    endtask

    task bus_write_byte(input [15:0] a, input [15:0] d);
        begin
            ad_oe = 1'b1; ad_drive = ~a;
            sel1_n = !(a[15:1] == (16'o177716 >> 1));
            sel2_n = !(a[15:1] == (16'o177714 >> 1));
            wtbt_n = 1'b0;                      // write flag at SYNC time...
            #6  sync_n = 1'b0;
            #6  ad_drive = ~d;
            #4  dout_n = 1'b1; #1 dout_n = 1'b0; // ...and still asserted = BYTE op
            repeat (2) @(posedge cclk);
            #2 dout_n = 1'b1; #6 sync_n = 1'b1; wtbt_n = 1'b1; ad_oe = 1'b0;
            sel1_n = 1'b1; sel2_n = 1'b1;
            repeat (2) @(posedge cclk);
        end
    endtask

    // One DATI (read) bus cycle: SYNC latches `a`, DIN strobes, the DUT's wait
    // FSM replies (N_ROM edges on cclk) and drives the read word; compare it.
    task bus_read(input [15:0] a, input [15:0] e, input [127:0] tag);
        begin
            ad_oe = 1'b1; ad_drive = ~a;
            sel1_n = !(a[15:1] == (16'o177716 >> 1));
            sel2_n = !(a[15:1] == (16'o177714 >> 1));
            #6  sync_n = 1'b0;                  // negedge SYNC latches addr = a
            #6  ad_oe = 1'b0;                   // release the bus for read data
            #4  din_n = 1'b0;                   // data-in phase
            wait (rply_n === 1'b0);             // FSM reply point
            #2;
            if (~ad_n !== e) begin
                $display("AUDIO-ERROR %0s: read %o exp=%o got=%o",
                         tag, a, e, ~ad_n);
                errors = errors + 1;
            end
            #6  din_n = 1'b1;
            #6  sync_n = 1'b1; sel1_n = 1'b1; sel2_n = 1'b1;
            wait (rply_n !== 1'b0);
            repeat (2) @(posedge sclk);
        end
    endtask

    task expect_spk(input e, input [127:0] tag);
        begin
            if (spk_bit !== e) begin
                $display("AUDIO-ERROR %0s: spk_bit exp=%b got=%b", tag, e, spk_bit);
                errors = errors + 1;
            end
        end
    endtask

    task expect_mot(input e, input [127:0] tag);
        begin
            if (mot_bit !== e) begin
                $display("AUDIO-ERROR %0s: mot_bit exp=%b got=%b", tag, e, mot_bit);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Power-on: hold reset over a few CPU clocks to init the wait FSM
        // (drive_data etc.), then release - as DCLO does on the real board.
        repeat (3) @(posedge cclk);
        @(negedge cclk) reset = 1'b0;
        repeat (4) @(posedge sclk);

        bus_write(16'o177716, 16'o000100); expect_spk(1'b1, "set bit6");
        bus_write(16'o177716, 16'o000000); expect_spk(1'b0, "clear bit6");
        bus_write(16'o177716, 16'o000144); expect_spk(1'b1, "set bit6 (other bits hi)");
        // a write to a different I/O register must not disturb spk_bit
        bus_write(16'o177560, 16'o000000); expect_spk(1'b1, "unrelated write ignored");
        // a 177717 HIGH-BYTE write asserts nSEL1 but must not touch bit 6
        // (it lives in the low byte) - pins the addr[0] gate in the capture
        bus_write(16'o177717, 16'o000000); expect_spk(1'b1, "177717 high-byte write ignored");
        bus_write(16'o177716, 16'o177677); expect_spk(1'b0, "clear via word w/ bit6=0");
        bus_write(16'o177716, 16'o000100); expect_spk(1'b1, "set again");

        // ---- tape motor (bit 7; 1 = stopped) - MONITOR d6.mac constants ----
        expect_mot(1'b0, "motor running after bit7=0 write");
        bus_write(16'o177716, 16'o000220); expect_mot(1'b1, "KSTOP stops");
                                           expect_spk(1'b0, "KSTOP clears spk");
        bus_write(16'o177716, 16'o000320); expect_mot(1'b1, "keyclick keeps stopped");
                                           expect_spk(1'b1, "keyclick sets spk");
        bus_write(16'o177716, 16'o000020); expect_mot(1'b0, "KPUSK starts");
        bus_write(16'o177560, 16'o000200); expect_mot(1'b0, "unrelated write ignored");
        bus_write(16'o177717, 16'o000200); expect_mot(1'b0, "177717 high-byte write ignored");
        bus_write(16'o177716, 16'o000220); expect_mot(1'b1, "KSTOP again");

        // ---- 177716 reads: start vector | write-flag | kbd | tape bit 5 ----
        // kbd_down=0 => bit 6 reads 1 (active low); the KSTOP write above set
        // the write-flag; the first read returns it and clears it.
        bus_read(16'o177716, 16'o100104, "read: wflag set, tape=0");
        bus_read(16'o177716, 16'o100100, "read: wflag cleared");
        tape_in = 1'b1;
        bus_read(16'o177716, 16'o100140, "read: tape=1");
        bus_read(16'o177717, 16'o100140, "read 177717: full word (nSEL1 both bytes)");
        tape_in = 1'b0;
        bus_read(16'o177716, 16'o100100, "read: tape=0 again");

        // ---- nINIT (RESET instruction): clears the write-flag, but NOT the
        //      software-owned spk/mot latches -------------------------------
        bus_write(16'o177716, 16'o000320);  // spk=1, mot=1, wflag set
        @(negedge cclk) init_n = 1'b0;
        repeat (3) @(posedge cclk);
        @(negedge cclk) init_n = 1'b1;
        repeat (2) @(posedge cclk);
        expect_spk(1'b1, "nINIT keeps spk");
        expect_mot(1'b1, "nINIT keeps mot");
        bus_read(16'o177716, 16'o100100, "read: nINIT cleared wflag");

        // ==== Phase-7: BK-0011M banking vs the speaker/motor capture =======
        // bk10 regression pin FIRST: on a BK-0010 bit 11 means nothing - a
        // word write with bit 11 set is still a peripheral write and captures
        // (state here: spk=1, mot=1; data bit7=0 flips mot).
        bus_write_word(16'o177716, 16'o004100);
        expect_spk(1'b1, "bk10 word w/ bit11: captures spk");
        expect_mot(1'b0, "bk10 word w/ bit11: captures mot");

        model_bk11 = 1'b1;
        // word writes with bit 11 SET are BANKING: spk/mot must not move
        // (data bits 6/7 = 0/0 then 1/1 - either capture polarity would show)
        bus_write_word(16'o177716, 16'o004000);
        expect_spk(1'b1, "bk11 banking (bits 0/0) leaves spk");
        expect_mot(1'b0, "bk11 banking (bits 0/0) leaves mot");
        bus_write_word(16'o177716, 16'o004300);
        expect_spk(1'b1, "bk11 banking (bits 1/1) leaves spk");
        expect_mot(1'b0, "bk11 banking (bits 1/1) leaves mot");
        // a word write with bit 11 CLEAR is a peripheral write, captures
        bus_write_word(16'o177716, 16'o000200);
        expect_spk(1'b0, "bk11 word w/o bit11 captures spk");
        expect_mot(1'b1, "bk11 word w/o bit11 captures mot");
        // byte writes can never carry bit 11 -> ALWAYS peripheral
        bus_write_byte(16'o177716, 16'o000100);
        expect_spk(1'b1, "bk11 byte write captures spk");
        expect_mot(1'b0, "bk11 byte write captures mot");
        bus_write_byte(16'o177716, 16'o004000);   // data bit 11 set, but BYTE
        expect_spk(1'b0, "bk11 byte w/ bit-11 data still captures spk");
        expect_mot(1'b0, "bk11 byte w/ bit-11 data still captures mot");
        // the 177717 odd byte is neither banking nor a low-byte capture
        bus_write_byte(16'o177717, 16'o000300);
        expect_spk(1'b0, "bk11 177717 byte: no spk effect");
        expect_mot(1'b0, "bk11 177717 byte: no mot effect");
        // write-only register + banking-sets-wflag pin: a DATI read after a
        // banking write returns SYS_START | wflag | kbd - never the map bits
        bus_read(16'o177716, 16'o100104, "bk11: clear pending wflag");
        bus_read(16'o177716, 16'o100100, "bk11: wflag now clear");
        bus_write_word(16'o177716, 16'o004000);   // banking write...
        bus_read(16'o177716, 16'o100104, "bk11: banking sets wflag, map not readable");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
