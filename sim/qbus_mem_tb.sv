//
// qbus_mem_tb - cosim of the synthesizable Q-bus slave against the vm1 core.
//
// Same clock / reset / cycle-count measurement methodology as the upstream
// bk10 timing testbench, but the behavioural memory model is replaced by the
// real synthesizable src/qbus_mem.sv. If this reproduces the golden
// "FETCH <addr> cycles=N" stream, the hardware memory path is cycle-faithful
// before we ever fit.
//
`timescale 1ns / 100ps

`define CLK_HALF_PERIOD 167          // ~3 MHz, matching bk10_tb
`define TEST_LO 16'o001000
`define TEST_HI 16'o002000

module qbus_mem_tb;

   // ---- clock + cycle counter ------------------------------------------
   reg     clk;
   integer nclk;
   initial clk = 0;
   always #(`CLK_HALF_PERIOD) clk = ~clk;
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

   // ---- synthesizable memory slave (DUT), clocked on inverted CPU clk --
   wire [15:0] dut_addr;
   wire        dut_fetch;
   qbus_mem #(.MEMFILE("../mem/bk10_prog.hex")) mem0 (
      .clk(~clk),  .reset(~dclo),
      .ad_n(ad),   .sync_n(sync), .din_n(din), .dout_n(dout),
      .wtbt_n(wtbt), .rply_n(rply),
      .bus_addr(dut_addr), .fetch_stb(dut_fetch)
   );

   // ---- independent address snoop for measurement (as in bk10_tb) ------
   reg [15:0] addr;
   reg        sel_ram;
   always @(negedge sync) begin
      addr    = ~ad;
      sel_ram = (addr < 16'o100000);
   end
   always @(posedge sync) sel_ram = 1'b0;

   // ---- cycle-count measurement ----------------------------------------
   integer    prev_nclk;
   reg [15:0] prev_addr;
   reg        have_baseline;
   always @(negedge din) begin
      if (~sync && sel_ram && addr >= `TEST_LO && addr < `TEST_HI) begin
         if (have_baseline)
            $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
         prev_nclk     = nclk;
         prev_addr     = addr;
         have_baseline = 1'b1;
      end
   end

   // ---- reset sequence + run limit (as in bk10_tb) ---------------------
   initial begin
      nclk = 0; prev_nclk = 0; have_baseline = 1'b0;
      pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111; virq = 1'b1;
      dclo = 1'b0; aclo = 1'b0;
      repeat (8) @(negedge clk); dclo = 1'b1;
      repeat (4) @(negedge clk); aclo = 1'b1;
      #5_000_000;
      $finish;
   end

endmodule
