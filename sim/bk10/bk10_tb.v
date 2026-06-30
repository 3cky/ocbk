//
// BK-0010 CPU timing testbench
//
// Measures instruction execution time in CPU clock cycles using
// address-decoded RPLY latency:
//   RAM (000000-077777): N_RAM CPU cycles after nDIN/nDOUT
//   ROM (100000-137777): N_ROM CPU cycles after nDIN
//
// Output: "FETCH <addr_octal> <cycles>" per read in RAM test area
// [001000, 002000).  Each line gives the cycle count for the previous
// instruction (from its fetch SYNC to this one's fetch SYNC).
//
//______________________________________________________________________________
//
`timescale 1ns / 100ps

`define CLK_HALF_PERIOD 167   // ~3 MHz

`define N_RAM   4             // RAM RPLY: CPU cycles after DIN/DOUT
`define N_ROM   2             // ROM RPLY: CPU cycles after DIN

`define TEST_LO 16'o001000
`define TEST_HI 16'o002000

module bk10_tb;

//______________________________________________________________________________
//
// Clock and cycle counter
//
reg      clk;
integer  nclk;

initial  clk = 0;
always #(`CLK_HALF_PERIOD) clk = ~clk;
always @(posedge clk) nclk = nclk + 1;

//______________________________________________________________________________
//
// Q-Bus
//
wire [15:0] ad_mux;
tri1 [15:0] ad;
reg  [15:0] ad_reg;
reg         ad_oe;

assign ad = ad_oe ? ~ad_mux : 16'hZZZZ;

tri1        sync, din, dout, wtbt, rply;
reg         rply_reg;
assign      rply = rply_reg ? 1'bZ : 1'b0;

reg         dclo, aclo;
reg  [3:1]  irq;
reg         virq, dmgi, sp;
reg  [1:0]  pa;
wire        dmgo;
tri1        init, dmr, sack, iako;
wire [2:1]  sel;
wire        bsy;

//______________________________________________________________________________
//
// Address decode (latched at negedge sync)
//
reg [15:0] addr;
reg        sel_ram, sel_rom, sel_io;
reg        wflg;

always @(negedge sync)
begin
   addr    = ~ad;
   wflg    = ~wtbt;
   sel_ram = (addr < 16'o100000);
   sel_rom = (addr >= 16'o100000) && (addr < 16'o177600);
   sel_io  = (addr >= 16'o177600);
end

always @(posedge sync)
begin
   sel_ram = 1'b0;
   sel_rom = 1'b0;
   sel_io  = 1'b0;
end

//______________________________________________________________________________
//
// Memory
//
reg [15:0] ram [0:16383];   // 000000-077777
reg [15:0] rom [0:8191];    // 100000-137777

assign ad_mux = sel_ram ? ram[addr[14:1]]
              : sel_rom ? rom[addr[13:1]]
              : ad_reg;

//______________________________________________________________________________
//
// Read handler
//
always @(negedge din)
begin
   if (~sync)
   begin
      if (sel_ram)
      begin
         repeat (`N_RAM) @(negedge clk);
         rply_reg = 1'b0;
         ad_oe    = 1'b1;
      end
      else if (sel_rom)
      begin
         repeat (`N_ROM) @(negedge clk);
         rply_reg = 1'b0;
         ad_oe    = 1'b1;
      end
      else if (sel_io)
      begin
         ad_reg   = (addr == 16'o177716) ? 16'o100000 : 16'o000000;
         repeat (`N_ROM) @(negedge clk);
         rply_reg = 1'b0;
         ad_oe    = 1'b1;
      end
   end
end

//______________________________________________________________________________
//
// Write handler
//
always @(negedge dout)
begin
   if (~sync && sel_ram)
   begin
      repeat (`N_RAM) @(negedge clk);
      if (wflg)
      begin
         if (addr[0]) ram[addr[14:1]][15:8] = ~ad[15:8];
         else         ram[addr[14:1]][7:0]  = ~ad[7:0];
      end
      else
         ram[addr[14:1]] = ~ad;
      rply_reg = 1'b0;
   end
end

//______________________________________________________________________________
//
// Bus cycle end: deassert RPLY and data bus
//
always @(posedge din or posedge dout)
begin
   @(negedge clk);
   rply_reg = 1'b1;
   @(posedge clk);
   ad_oe    = 1'b0;
end

//______________________________________________________________________________
//
// Timing measurement
//
integer    prev_nclk;
reg [15:0] prev_addr;
reg        have_baseline;

always @(negedge din)
begin
   if (~sync && sel_ram
         && addr >= `TEST_LO && addr < `TEST_HI)
   begin
      if (have_baseline)
         $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
      prev_nclk     = nclk;
      prev_addr     = addr;
      have_baseline = 1'b1;
   end
end

//______________________________________________________________________________
//
// CPU
//
vm1 cpu0 (
   .pin_clk_p(clk),   .pin_clk_n(~clk),  .pin_ena(1'b1),
   .pin_pa_n(pa),     .pin_sp_n(sp),
   .pin_init_n(init), .pin_dclo_n(dclo),  .pin_aclo_n(aclo),
   .pin_irq_n(irq),   .pin_virq_n(virq),
   .pin_ad_n(ad),     .pin_dout_n(dout),  .pin_din_n(din),
   .pin_wtbt_n(wtbt), .pin_sync_n(sync),  .pin_rply_n(rply),
   .pin_dmr_n(dmr),   .pin_sack_n(sack),  .pin_dmgi_n(dmgi),
   .pin_dmgo_n(dmgo), .pin_iako_n(iako),  .pin_sel_n(sel),
   .pin_bsy_n(bsy)
);

//______________________________________________________________________________
//
// Memory initialisation
//
// ROM bootstrap at 100000 (rom indices 0-1):
//   000137  JMP @#001000
//   001000  target
//
// RAM test program at 001000 (byte addr 001000 octal = 512 dec = word 256 = 0x100):
//
//   Addr    Idx   Word     Instruction / note
//   001000  0x100 012700   MOV #002000,R0  } setup
//   001002  0x101 002000                   }
//   001004  0x102 012701   MOV #002000,R1  }
//   001006  0x103 002000                   }
//   001010  0x104 012710   MOV #012345,@R0 }
//   001012  0x105 012345                   }
//
//   001014  0x106 010002   T01 MOV R0,R2          (mode 0 src, mode 0 dst)
//   001016  0x107 011002   T02 MOV @R0,R2          (mode 1 src)
//   001020  0x108 012002   T03 MOV (R0)+,R2        (mode 2 src)  R0->002002
//   001022  0x109 012700       MOV #002000,R0  restore
//   001024  0x10A 002000
//   001026  0x10B 014002   T04 MOV -(R0),R2        (mode 4 src)  R0->001776
//   001030  0x10C 012700       MOV #002000,R0  restore
//   001032  0x10D 002000
//   001034  0x10E 016002   T05 MOV 0(R0),R2        (mode 6 src, 2 words)
//   001036  0x10F 000000       offset = 0
//   001040  0x110 010011   T06 MOV R0,@R1           (mode 1 dst)
//   001042  0x111 012711       MOV #012345,@R1  restore mem[002000]
//   001044  0x112 012345
//   001046  0x113 010021   T07 MOV R0,(R1)+         (mode 2 dst)  R1->002002
//   001050  0x114 012701       MOV #002000,R1  restore
//   001052  0x115 002000
//   001054  0x116 010041   T08 MOV R0,-(R1)         (mode 4 dst)  R1->001776
//   001056  0x117 012701       MOV #002000,R1  restore
//   001060  0x118 002000
//   001062  0x119 010061   T09 MOV R0,0(R1)         (mode 6 dst, 2 words)
//   001064  0x11A 000000       offset = 0
//   001066  0x11B 005002   T10 CLR R2               (single-op, mode 0)
//   001070  0x11C 000400   T11 BR  .+2              (branch taken, offset=0)
//   001072  0x11D 012702   T12 MOV #001234,R2       (immediate src, 2 words)
//   001074  0x11E 001234
//   001076  0x11F 000777   end BR . (self-loop, stops output)
//
// Data area at 002000 (byte 1024 dec = word 512 = 0x200):
//   002000  0x200 012345   initial data value
//
integer ii;
initial
begin
   for (ii = 0; ii < 16384; ii = ii + 1) ram[ii] = 16'o000000;
   for (ii = 0; ii < 8192;  ii = ii + 1) rom[ii] = 16'o000000;

   // ROM bootstrap
   rom[0] = 16'o000137;   rom[1] = 16'o001000;

   // setup
   ram[16'h100] = 16'o012700; ram[16'h101] = 16'o002000;
   ram[16'h102] = 16'o012701; ram[16'h103] = 16'o002000;
   ram[16'h104] = 16'o012710; ram[16'h105] = 16'o012345;

   // T01 - T02
   ram[16'h106] = 16'o010002;
   ram[16'h107] = 16'o011002;

   // T03 + restore R0
   ram[16'h108] = 16'o012002;
   ram[16'h109] = 16'o012700; ram[16'h10A] = 16'o002000;

   // T04 + restore R0
   ram[16'h10B] = 16'o014002;
   ram[16'h10C] = 16'o012700; ram[16'h10D] = 16'o002000;

   // T05 (2 words)
   ram[16'h10E] = 16'o016002; ram[16'h10F] = 16'o000000;

   // T06 + restore mem[002000]
   ram[16'h110] = 16'o010011;
   ram[16'h111] = 16'o012711; ram[16'h112] = 16'o012345;

   // T07 + restore R1
   ram[16'h113] = 16'o010021;
   ram[16'h114] = 16'o012701; ram[16'h115] = 16'o002000;

   // T08 + restore R1
   ram[16'h116] = 16'o010041;
   ram[16'h117] = 16'o012701; ram[16'h118] = 16'o002000;

   // T09 (2 words)
   ram[16'h119] = 16'o010061; ram[16'h11A] = 16'o000000;

   // T10 - T12 + self-loop
   ram[16'h11B] = 16'o005002;
   ram[16'h11C] = 16'o000400;
   ram[16'h11D] = 16'o012702; ram[16'h11E] = 16'o001234;
   ram[16'h11F] = 16'o000777;

   // data area
   ram[16'h200] = 16'o012345;
end

//______________________________________________________________________________
//
// Reset sequence and simulation limit
//
initial
begin
   nclk          = 0;
   prev_nclk     = 0;
   have_baseline = 1'b0;
   ad_oe         = 1'b0;
   rply_reg      = 1'b1;
   ad_reg        = 16'o000000;
   pa            = 2'b11;
   sp            = 1'b1;
   dmgi          = 1'b1;
   irq           = 3'b111;
   virq          = 1'b1;
   dclo          = 1'b0;
   aclo          = 1'b0;

   repeat (8) @(negedge clk);
   dclo = 1'b1;
   repeat (4) @(negedge clk);
   aclo = 1'b1;

   // run long enough for all test instructions to complete
   #10_000_000;
   $finish;
end

endmodule
