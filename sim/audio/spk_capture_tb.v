// ============================================================================
//  spk_capture_tb - directed oracle for the 177716-bit-6 speaker capture in
//  qbus_mem. Drives real Q-bus write cycles (SYNC latches the address,
//  DOUT presents the data) to 177716 and checks spk_bit follows bit 6 - the
//  key point being that the capture must NOT depend on the ROM/IO wait FSM's
//  reply (the vm1 self-replies for 177700-177717, so the FSM never sees the
//  write). Also checks a write to a different I/O address leaves spk_bit alone.
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
    logic reset  = 1'b1;   // = ~dclo_n; held at power-on to init the wait FSM
    wire        spk_bit;
    wire [15:0] bus_addr;
    wire        s_dq_dummy;   // unused SDRAM data bus stays floating

    integer errors = 0;

    qbus_mem dut (
        .cpu_clk   (cclk),
        .reset     (reset),
        .init_n    (1'b1),
        .kbd_down  (1'b0),
        .sclk      (sclk),
        .srst_n    (1'b1),
        .init_done (),
        .ad_n      (ad_n),
        .sync_n    (sync_n),
        .din_n     (din_n),
        .dout_n    (dout_n),
        .wtbt_n    (wtbt_n),
        .rply_n    (),
        .mem_ready (),
        .boot_active(1'b0),
        .bw_req    (1'b0), .bw_addr('0), .bw_wdata('0), .bw_gnt(),
        .v1_req(1'b0), .v1_addr('0), .v1_gnt(), .v1_rvalid(),
        .v2_req(1'b0), .v2_addr('0), .v2_gnt(), .v2_rvalid(),
        .v3_req(1'b0), .v3_addr('0), .v3_wdata('0), .v3_gnt(), .v_rdata(),
        .s_cke(), .s_cs_n(), .s_ras_n(), .s_cas_n(), .s_we_n(),
        .s_ba(), .s_addr(), .s_dqm(), .s_dq(),
        .bus_addr(bus_addr), .fetch_stb(),
        .spk_bit(spk_bit)
    );

    // One DATO (write) bus cycle: SYNC latches `a`, DOUT presents `d`.
    task bus_write(input [15:0] a, input [15:0] d);
        begin
            ad_oe = 1'b1; ad_drive = ~a;       // address onto the (inverted) bus
            #6  sync_n = 1'b0;                  // negedge SYNC latches addr = a
            #6  ad_drive = ~d;                  // switch bus to write data
            #4  wtbt_n = 1'b0;                  // WTBT = write at SYNC, byte at DOUT (unused here)
                dout_n = 1'b1; #1 dout_n = 1'b0;// assert DOUT (data-out phase)
            repeat (4) @(posedge sclk);         // let the sys_clk capture sample
            dout_n = 1'b1; #6 sync_n = 1'b1; wtbt_n = 1'b1; ad_oe = 1'b0;
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
        bus_write(16'o177716, 16'o177677); expect_spk(1'b0, "clear via word w/ bit6=0");
        bus_write(16'o177716, 16'o000100); expect_spk(1'b1, "set again");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
