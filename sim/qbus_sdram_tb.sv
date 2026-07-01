//
// qbus_sdram_tb - cosim of the Phase-2 RAM-in-SDRAM datapath against the vm1 core.
//
// Wires the real synthesizable src/qbus_sdram.sv (with its embedded sdram_ctrl)
// to a behavioural SDRAM model and runs the ROM-resident RAM-test program. Two
// independent clocks - the ~3 MHz CPU clock and a fast ~96.65 MHz SDRAM clock -
// deliberately stress the clock-domain-crossing handshake (on hardware they are
// related as sys_clk/32, but async here is the stronger test).
//
// Checks:
//   (a) datapath correctness  - the program self-verifies its word/byte writes
//       and parks in the SUCCESS self-loop (PC 100072), never the FAILURE loop
//       (PC 100100);
//   (b) deterministic timing  - every RAM access replies a fixed number of CPU
//       cycles after DIN/DOUT (the SDRAM latency is fully hidden behind RPLY).
//
`timescale 1ns / 100ps

`define CPU_HALF 167                  // ~3 MHz CPU clock, matching bk10_tb
`define SDR_HALF 5                    // ~100 MHz SDRAM clock (~96.65 MHz target)

`define PC_SUCCESS 16'o100072
`define PC_FAIL    16'o100100

module qbus_sdram_tb;

   import qbus_pkg::*;

   // ---- clocks + CPU-cycle counter -------------------------------------
   reg     clk, sclk;
   integer nclk;
   initial begin clk = 0; sclk = 0; end
   always #(`CPU_HALF) clk  = ~clk;
   always #(`SDR_HALF) sclk = ~sclk;
   always @(posedge clk) nclk = nclk + 1;

   // ---- Q-bus (inverted, active-low, pull-up = inactive) ---------------
   tri1 [15:0] ad;
   tri1        sync, din, dout, wtbt, rply;
   tri1        init, dmr, sack, iako;
   reg         dclo, aclo;
   reg  [3:1]  irq;
   reg         virq, dmgi, sp;
   reg  [1:0]  pa;
   wire        dmgo;
   wire [2:1]  sel;
   wire        bsy;

   // ---- SDRAM domain reset ---------------------------------------------
   reg srst_n;

   // ---- CPU ------------------------------------------------------------
   vm1 cpu0 (
      .pin_clk_p(clk),   .pin_clk_n(~clk),  .pin_ena(1'b1),
      .pin_pa_n(pa),     .pin_sp_n(sp),
      .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
      .pin_irq_n(irq),   .pin_virq_n(virq),
      .pin_ad_n(ad),     .pin_dout_n(dout), .pin_din_n(din),
      .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
      .pin_dmr_n(dmr),   .pin_sack_n(sack), .pin_dmgi_n(dmgi),
      .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel),
      .pin_bsy_n(bsy)
   );

   // ---- DUT: RAM-in-SDRAM slave + its SDRAM controller -----------------
   localparam int ROWB = 13, COLB = 9, BAB = 2, DQB = 16, CL = 2;
   wire [BAB-1:0]  s_ba;
   wire [ROWB-1:0] s_addr;
   wire [1:0]      s_dqm;
   wire            s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, init_done;
   wire [DQB-1:0]  s_dq;
   wire [15:0]     dut_addr;
   wire            dut_fetch;

   qbus_sdram #(
      .MEMFILE("../mem/ram_test.hex"),
      .CLK_FREQ_HZ(2_000_000),         // short init/refresh for sim (functional)
      .ROW_BITS(ROWB), .COL_BITS(COLB), .BA_BITS(BAB),
      .DQ_BITS(DQB), .CAS_LATENCY(CL)
   ) dut (
      .clk(~clk), .reset(~dclo),
      .sclk(sclk), .srst_n(srst_n), .init_done(init_done),
      .ad_n(ad), .sync_n(sync), .din_n(din), .dout_n(dout),
      .wtbt_n(wtbt), .rply_n(rply),
      .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
      .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
      .bus_addr(dut_addr), .fetch_stb(dut_fetch)
   );

   sdram_model #(
      .ROW_BITS(ROWB), .COL_BITS(COLB), .BA_BITS(BAB), .DQ_BITS(DQB), .CAS_LATENCY(CL)
   ) model (
      .clk(sclk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
      .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
   );

   // ---- address snoop (latched at negedge sync, as in bk10_tb) ----------
   reg [15:0] addr;
   reg        sel_ram;
   always @(negedge sync) begin
      addr    = ~ad;
      sel_ram = (addr < 16'o100000);
   end
   always @(posedge sync) sel_ram = 1'b0;

   // ---- success/failure park detection (count fetches of each loop PC) --
   integer succ_cnt, fail_cnt;
   always @(negedge din) begin
      if (~sync && addr == `PC_SUCCESS) succ_cnt = succ_cnt + 1;
      if (~sync && addr == `PC_FAIL)    fail_cnt = fail_cnt + 1;
   end

   // ---- RAM-access RPLY latency (CPU cycles from DIN/DOUT to RPLY) ------
   // Reads (timed from DIN) and writes (timed from DOUT) differ by a fixed bus
   // phase, so determinism is checked within each class: every RAM read must
   // take the same number of CPU cycles, and likewise every RAM write - that is
   // what "the SDRAM latency is hidden behind a fixed RPLY" means.
   reg        acc_active, acc_we;
   reg [15:0] acc_addr;
   integer    acc_start;
   integer    lat_rd_val, lat_rd_n, lat_wr_val, lat_wr_n;
   reg        lat_rd_ok, lat_wr_ok;
   always @(negedge din)  if (~sync && sel_ram && !acc_active)
                             begin acc_active=1; acc_we=0; acc_addr=addr; acc_start=nclk; end
   always @(negedge dout) if (~sync && sel_ram && !acc_active)
                             begin acc_active=1; acc_we=1; acc_addr=addr; acc_start=nclk; end
   always @(negedge rply) if (acc_active) begin
      integer lat;
      lat = nclk - acc_start;
      $display("RAMACC %06o %s lat=%0d", acc_addr, acc_we ? "WR" : "RD", lat);
      if (acc_we) begin
         if (lat_wr_n == 0)        lat_wr_val = lat;
         else if (lat !== lat_wr_val) lat_wr_ok = 1'b0;
         lat_wr_n = lat_wr_n + 1;
      end else begin
         if (lat_rd_n == 0)        lat_rd_val = lat;
         else if (lat !== lat_rd_val) lat_rd_ok = 1'b0;
         lat_rd_n = lat_rd_n + 1;
      end
      acc_active = 1'b0;
   end

   // ---- reset: bring SDRAM up first, then release the CPU (as in top) ---
   initial begin
      nclk = 0; succ_cnt = 0; fail_cnt = 0;
      acc_active = 0;
      lat_rd_n = 0; lat_rd_val = 0; lat_rd_ok = 1'b1;
      lat_wr_n = 0; lat_wr_val = 0; lat_wr_ok = 1'b1;
      pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111; virq = 1'b1;
      dclo = 1'b0; aclo = 1'b0; srst_n = 1'b0;
      repeat (4) @(negedge sclk); srst_n = 1'b1;   // release SDRAM controller
      wait (init_done);                            // wait for SDRAM init
      repeat (8) @(negedge clk); dclo = 1'b1;       // then the CPU reset sequence
      repeat (4) @(negedge clk); aclo = 1'b1;
   end

   // ---- run limit + verdict --------------------------------------------
   initial begin
      #800_000;
      if (succ_cnt > 10 && fail_cnt == 0 && lat_rd_ok && lat_wr_ok
          && lat_rd_n > 0 && lat_wr_n > 0)
         $display("COSIM PASS: RAM-in-SDRAM ok (success=%0d); deterministic RPLY - reads %0d cyc x%0d, writes %0d cyc x%0d",
                  succ_cnt, lat_rd_val, lat_rd_n, lat_wr_val, lat_wr_n);
      else
         $display("COSIM FAIL: success=%0d fail=%0d rd_ok=%0b wr_ok=%0b rd_n=%0d wr_n=%0d init_done=%0b",
                  succ_cnt, fail_cnt, lat_rd_ok, lat_wr_ok, lat_rd_n, lat_wr_n, init_done);
      $finish;
   end

endmodule
