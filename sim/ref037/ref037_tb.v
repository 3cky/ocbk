//
// Phase 3 reference oracle: vm1 CPU + real va_037 (1801VP1-037) + behavioural DRAM.
//
// This is the ground-truth timing model for Phase 3. It runs the SAME test
// program as sim/bk10/bk10_tb.v, but the RAM (000000-077777) RPLY now comes from
// the actual va_037 arbiter with its video machinery free-running - so the
// per-instruction cycle counts include the CPU/video cycle-stealing ("the screen
// slows the CPU"). Diffing this against the bk10 golden (fixed N_RAM=4, no video)
// gives the with-/without-display timing delta that va_037_sync must reproduce.
//
// Memory ownership on the shared, inverted, open-collector Q-bus:
//   RAM 000000-077777 (A[15]=0): DATA from the tb array; RPLY from va_037 (stolen).
//   ROM 100000-137777          : tb model, fixed N_ROM reply (037 does not see it).
//   I/O 177716                 : tb model returns 100000 (boot vector), N_ROM reply.
// va_037 additionally drives AD for its own registers (177664/177716) with Z-default
// tri-state, so it never fights the tb array on RAM reads.
//
// Clocking: CLKIN = 037 pixel/2 (~6 MHz); the CPU runs at CLKIN/2 (~3 MHz),
// phase-locked, exactly as on real BK hardware.
//
`timescale 1ns / 100ps

`define CLKIN_HALF 83          // ~6.02 MHz 037 clock (CPU = /2 = ~3.01 MHz)
`define N_ROM      2           // ROM/IO RPLY: CPU cycles after DIN (037-independent)

`define TEST_LO 16'o001000
`define TEST_HI 16'o002000

module ref037_tb;

//______________________________________________________________________________
// Clocks: CLKIN (037) is the base; CPU clk = CLKIN/2, phase-locked.
//
reg     clkin;
reg     clk;                   // CPU clock
integer nclk;                  // CPU cycle counter

initial clkin = 1'b0;
always #(`CLKIN_HALF) clkin = ~clkin;

initial clk = 1'b0;
always @(posedge clkin) clk <= ~clk;
always @(posedge clk)   nclk = nclk + 1;

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

// External (ROM/IO) reply, open-collector.
reg         rply_ext_n;        // 0 = reply, 1 = release
assign rply = rply_ext_n ? 1'bZ : 1'b0;

// va_037 reply, converted from its hard-driven PIN_nRPLY to open-collector.
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

always @(negedge sync)
begin
   addr    = ~ad;
   sel_ram = (addr < 16'o100000);
   sel_rom = (addr >= 16'o100000) && (addr < 16'o140000);
   sel_io  = (addr >= 16'o177600);
end
always @(posedge sync)
begin
   sel_ram = 1'b0; sel_rom = 1'b0; sel_io = 1'b0;
end

//______________________________________________________________________________
// Memory arrays
//
reg [15:0] ram [0:16383];      // 000000-077777
reg [15:0] rom [0:8191];       // 100000-137777

//______________________________________________________________________________
// RAM DATA path (va_037 owns RAM RPLY). Drive the read word for the whole read
// data phase so it is valid whenever va_037 asserts RPLY; capture writes at the
// 037 reply edge.
//
always @(*) begin
   ram_data = ram[addr[14:1]];
   ram_oe   = (~din) && sel_ram;      // CPU RAM read in progress
end

// Byte flag is WTBT sampled at DOUT time (dual-purpose WTBT); commit at 037 reply.
reg  wr_committed;
always @(negedge rply) begin
   if (~dout && sel_ram && !wr_committed) begin
      if (~wtbt) begin                 // byte write
         if (addr[0]) ram[addr[14:1]][15:8] = ~ad[15:8];
         else         ram[addr[14:1]][7:0]  = ~ad[7:0];
      end else
         ram[addr[14:1]] = ~ad;        // word write
      wr_committed = 1'b1;
   end
end
always @(posedge dout) wr_committed = 1'b0;

//______________________________________________________________________________
// ROM / I/O reply (fixed N_ROM, 037-independent). Read handler.
//
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

// Bus cycle end: release external reply + data.
always @(posedge din or posedge dout) begin
   @(negedge clk);
   rply_ext_n = 1'b1;
   @(posedge clk);
   rom_oe = 1'b0; io_oe = 1'b0;
end

//______________________________________________________________________________
// Timing measurement (identical methodology to bk10_tb)
//
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
// 1801VP1-037 (video/arbiter). RAM RPLY + video cycle-stealing come from here.
//
wire [6:0] va_a;
wire [1:0] va_cas;
wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync;

va_037 pr_037 (
   .PIN_CLK   (clkin),
   .PIN_R     (~dclo),         // 037 reset active-high while CPU held in reset
   .PIN_C     (1'b0),
   .PIN_nAD   (ad),
   .PIN_nSYNC (sync),
   .PIN_nDIN  (din),
   .PIN_nDOUT (dout),
   .PIN_nWTBT (wtbt),
   .PIN_nRPLY (rply037_n),
   .PIN_A     (va_a),
   .PIN_nCAS  (va_cas),
   .PIN_nRAS  (va_ras),
   .PIN_nWE   (va_we),
   .PIN_nE    (va_ne),
   .PIN_nBS   (va_nbs),
   .PIN_WTI   (va_wti),
   .PIN_WTD   (va_wtd),
   .PIN_nVSYNC(va_vsync)
);

//______________________________________________________________________________
// Program + memory init (same program as bk10_tb: ROM bootstrap -> RAM test).
//
integer ii;
initial begin
   for (ii = 0; ii < 16384; ii = ii + 1) ram[ii] = 16'o000000;
   for (ii = 0; ii < 8192;  ii = ii + 1) rom[ii] = 16'o000000;

   rom[0] = 16'o000137; rom[1] = 16'o001000;   // JMP @#001000

   ram[16'h100] = 16'o012700; ram[16'h101] = 16'o002000;
   ram[16'h102] = 16'o012701; ram[16'h103] = 16'o002000;
   ram[16'h104] = 16'o012710; ram[16'h105] = 16'o012345;
   ram[16'h106] = 16'o010002;
   ram[16'h107] = 16'o011002;
   ram[16'h108] = 16'o012002;
   ram[16'h109] = 16'o012700; ram[16'h10A] = 16'o002000;
   ram[16'h10B] = 16'o014002;
   ram[16'h10C] = 16'o012700; ram[16'h10D] = 16'o002000;
   ram[16'h10E] = 16'o016002; ram[16'h10F] = 16'o000000;
   ram[16'h110] = 16'o010011;
   ram[16'h111] = 16'o012711; ram[16'h112] = 16'o012345;
   ram[16'h113] = 16'o010021;
   ram[16'h114] = 16'o012701; ram[16'h115] = 16'o002000;
   ram[16'h116] = 16'o010041;
   ram[16'h117] = 16'o012701; ram[16'h118] = 16'o002000;
   ram[16'h119] = 16'o010061; ram[16'h11A] = 16'o000000;
   ram[16'h11B] = 16'o005002;
   ram[16'h11C] = 16'o000400;
   ram[16'h11D] = 16'o012702; ram[16'h11E] = 16'o001234;
   ram[16'h11F] = 16'o000777;
   ram[16'h200] = 16'o012345;
end

//______________________________________________________________________________
// Reset + 037 register init + sim limit
//
initial begin
   nclk = 0; prev_nclk = 0; have_baseline = 1'b0;
   ram_oe = 0; rom_oe = 0; io_oe = 0;
   rply_ext_n = 1'b1; wr_committed = 1'b0;
   ram_data = 0; rom_data = 0; io_data = 0;
   pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111; virq = 1'b1;
   dclo = 1'b0; aclo = 1'b0;

   // Initialise the 037 video base register (RA/M256 have no async reset).
   pr_037.RA   = 8'o000;
   pr_037.M256 = 1'b0;

   repeat (8) @(negedge clk); dclo = 1'b1;
   repeat (4) @(negedge clk); aclo = 1'b1;

   #2_000_000;                    // program + several self-loop iterations
   $finish;
end

endmodule
