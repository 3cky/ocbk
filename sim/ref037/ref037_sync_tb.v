//
// Phase 3 equivalence testbench: vm1 CPU + retimed va_037_sync + behavioural DRAM.
//
// Identical program, memory model and measurement to ref037_tb.v, but the 037 is
// the retimed sys_clk-domain core (src/va_037_sync.sv) driven by ÷16 enables, and
// the CPU runs at sys_clk/32 = CLKIN/2 (same phase as the reference). If the
// retime is correct this reproduces sim/ref037/golden_037.txt bit-for-bit.
//
// mem_ready is tied 1 (done-gate is a no-op here), so any difference is a pure
// retiming error, not an interlock effect.
//
`timescale 1ns / 100ps

`define SYSCLK_HALF 5          // 100 MHz-ish sys_clk (absolute rate irrelevant)
`define N_ROM       2

`define TEST_LO 16'o001000
`define TEST_HI 16'o002000
// +romprog: the same program words placed in ROM at 101000 (see ref037_tb.v).
`define ROM_TEST_LO 16'o101000
`define ROM_TEST_HI 16'o102000

module ref037_sync_tb;

//______________________________________________________________________________
// sys_clk + ÷16 enables (en_pos / en_neg 8 apart) + CPU clk (÷32 = CLKIN/2)
//
reg       sys_clk;
reg [4:0] divc;
integer   nclk;

initial sys_clk = 1'b0;
always #(`SYSCLK_HALF) sys_clk = ~sys_clk;

initial divc = 5'd0;
always @(posedge sys_clk) divc <= divc + 1'b1;

// en_pos/en_neg are phased so the gated always_ff fires ON the CPU clock edges
// (CPU = CLKIN/2, edges coincident) - matching the reference's simultaneity of the
// 037 CLKIN update and the CPU clock edge. (divc[3:0]==15 -> update at divc->0/16.)
wire en_pos = (divc[3:0] == 4'd15);   // "posedge CLKIN", lands on CPU edges (divc 0/16)
wire en_neg = (divc[3:0] == 4'd7);    // "negedge CLKIN", lands between (divc 8/24)
wire clk    = divc[4];          // CPU clock, sys_clk/32
always @(posedge clk) nclk = nclk + 1;

//______________________________________________________________________________
// Q-Bus (inverted, active low, open-collector)
//
tri1 [15:0] ad;
reg  [15:0] ram_data, rom_data, io_data;
reg         ram_oe, rom_oe, io_oe;
assign ad = ram_oe ? ~ram_data : 16'hZZZZ;
assign ad = rom_oe ? ~rom_data : 16'hZZZZ;
assign ad = io_oe  ? ~io_data  : 16'hZZZZ;

tri1        sync, din, dout, wtbt, rply;

reg         rply_ext_n;
assign rply = rply_ext_n ? 1'bZ : 1'b0;

wire        rply037_n;
assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

reg         dclo, aclo;
reg  [3:1]  irq;
reg         virq, dmgi, sp;
reg  [1:0]  pa;
wire        dmgo;
tri1        init, dmr, sack, iako;
wire [2:1]  sel;
wire        bsy;

//______________________________________________________________________________
// Address decode (latched at negedge sync)
//
reg [15:0] addr;
reg        sel_ram, sel_rom, sel_io;

always @(negedge sync) begin
   addr    = ~ad;
   sel_ram = (addr < 16'o100000);
   sel_rom = (addr >= 16'o100000) && (addr < 16'o140000);
   sel_io  = (addr >= 16'o177600);
end
always @(posedge sync) begin
   sel_ram = 1'b0; sel_rom = 1'b0; sel_io = 1'b0;
end

//______________________________________________________________________________
// Memory
//
reg [15:0] ram [0:16383];
reg [15:0] rom [0:8191];

always @(*) begin
   ram_data = ram[addr[14:1]];
   ram_oe   = (~din) && sel_ram;
end

reg wr_committed;
always @(negedge rply) begin
   if (~dout && sel_ram && !wr_committed) begin
      if (~wtbt) begin
         if (addr[0]) ram[addr[14:1]][15:8] = ~ad[15:8];
         else         ram[addr[14:1]][7:0]  = ~ad[7:0];
      end else
         ram[addr[14:1]] = ~ad;
      wr_committed = 1'b1;
   end
end
always @(posedge dout) wr_committed = 1'b0;

always @(negedge din) begin
   if (~sync) begin
      if (sel_rom) begin
         rom_data = rom[addr[13:1]];
         repeat (`N_ROM) @(negedge clk);
         rom_oe = 1'b1; rply_ext_n = 1'b0;
      end else if (sel_io) begin
         io_data = (addr == 16'o177716) ? 16'o100000 : 16'o000000;
         repeat (`N_ROM) @(negedge clk);
         io_oe = 1'b1; rply_ext_n = 1'b0;
      end
   end
end

always @(posedge din or posedge dout) begin
   @(negedge clk);
   rply_ext_n = 1'b1;
   @(posedge clk);
   rom_oe = 1'b0; io_oe = 1'b0;
end

//______________________________________________________________________________
// Timing measurement
//
integer    prev_nclk;
reg [15:0] prev_addr;
reg        have_baseline;
reg        romprog;            // +romprog: program (and window) in the ROM region

always @(negedge din) begin
   if (~sync && (romprog ? (sel_rom && addr >= `ROM_TEST_LO && addr < `ROM_TEST_HI)
                         : (sel_ram && addr >= `TEST_LO     && addr < `TEST_HI))) begin
      if (have_baseline)
         $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
      prev_nclk     = nclk;
      prev_addr     = addr;
      have_baseline = 1'b1;
   end
end

//______________________________________________________________________________
// CPU
//
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

//______________________________________________________________________________
// Retimed 037
//
wire [6:0] va_a;  wire [1:0] va_cas;
wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
wire [13:1] va_video;

va_037_sync pr037_sync (
   .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(1'b1),
   .PIN_R(~dclo), .PIN_C(1'b0),
   .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
   .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
   .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
   .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
   .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(va_video),
   .vid_fetch(), .vid_line_en(), .hgate(), .vgate()
);

//______________________________________________________________________________
// Program + memory init (identical to ref037_tb.v)
//
// One word table, copied to RAM at 001000 (default) or ROM at 101000
// (+romprog) - see ref037_tb.v for the rationale.
reg [15:0] prog [0:16'h2F];
integer ii;
initial begin
   for (ii = 0; ii < 16384; ii = ii + 1) ram[ii] = 16'o000000;
   for (ii = 0; ii < 8192;  ii = ii + 1) rom[ii] = 16'o000000;
   prog['h00] = 16'o012700; prog['h01] = 16'o002000;
   prog['h02] = 16'o012701; prog['h03] = 16'o002000;
   prog['h04] = 16'o012710; prog['h05] = 16'o012345;
   prog['h06] = 16'o010002;
   prog['h07] = 16'o011002;
   prog['h08] = 16'o012002;
   prog['h09] = 16'o012700; prog['h0A] = 16'o002000;
   prog['h0B] = 16'o014002;
   prog['h0C] = 16'o012700; prog['h0D] = 16'o002000;
   prog['h0E] = 16'o016002; prog['h0F] = 16'o000000;
   prog['h10] = 16'o010011;
   prog['h11] = 16'o012711; prog['h12] = 16'o012345;
   prog['h13] = 16'o010021;
   prog['h14] = 16'o012701; prog['h15] = 16'o002000;
   prog['h16] = 16'o010041;
   prog['h17] = 16'o012701; prog['h18] = 16'o002000;
   prog['h19] = 16'o010061; prog['h1A] = 16'o000000;
   // RMW (DATIO/DATIOB) coverage - see ref037_tb.v; FAIL park 001124/101124.
   prog['h1B] = 16'o012700; prog['h1C] = 16'o002000;
   prog['h1D] = 16'o005010;
   prog['h1E] = 16'o005210;
   prog['h1F] = 16'o062710; prog['h20] = 16'o000005;
   prog['h21] = 16'o052710; prog['h22] = 16'o000120;
   prog['h23] = 16'o042710; prog['h24] = 16'o000100;
   prog['h25] = 16'o105210;
   prog['h26] = 16'o011002;
   prog['h27] = 16'o020227; prog['h28] = 16'o000027;
   prog['h29] = 16'o001401;
   prog['h2A] = 16'o000777;                              // RMW FAIL park
   prog['h2B] = 16'o005002;
   prog['h2C] = 16'o000400;
   prog['h2D] = 16'o012702; prog['h2E] = 16'o001234;
   prog['h2F] = 16'o000777;                              // self-loop
   if ($test$plusargs("romprog")) begin
      rom[0] = 16'o000137; rom[1] = 16'o101000;
      for (ii = 0; ii < 16'h30; ii = ii + 1) rom[16'h100 + ii] = prog[ii];
   end else begin
      rom[0] = 16'o000137; rom[1] = 16'o001000;
      for (ii = 0; ii < 16'h30; ii = ii + 1) ram[16'h100 + ii] = prog[ii];
   end
   ram[16'h200] = 16'o012345;
end

//______________________________________________________________________________
// Reset + 037 register init + sim limit
//
initial begin
   nclk = 0; prev_nclk = 0; have_baseline = 1'b0;
   romprog = $test$plusargs("romprog");
   ram_oe = 0; rom_oe = 0; io_oe = 0;
   rply_ext_n = 1'b1; wr_committed = 1'b0;
   ram_data = 0; rom_data = 0; io_data = 0;
   pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111; virq = 1'b1;
   dclo = 1'b0; aclo = 1'b0;


   repeat (8) @(negedge clk); dclo = 1'b1;
   repeat (4) @(negedge clk); aclo = 1'b1;

   #2_000_000;
   $finish;
end

endmodule
