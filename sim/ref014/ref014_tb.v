//
// Phase 6 contract oracle: the VENDORED 1801VP1-014 gate netlist driven
// through the shared scenario (ref014_scenario.v). This run's output is the
// committed golden_014.txt; the behavioral src/peripheral/bk_kbd014.sv must reproduce
// it line-for-line (ref014_beh_tb.v).
//
// Bus tasks mimic the vm1 master shapes that matter for the contract:
//  - nCS (the 037 nBS in the SoC) is presented with the address and released
//    after the transaction; the chip latches it at SYNC fall (probed).
//  - The IAK cycle is DIN + nIAKI with NO SYNC (vm1_qbus.v:539,623).
//  - DATIO RMW runs DIN then DOUT under one SYNC.
// All waits are RPLY-handshake or debounce-pin (RP1/RP2) driven -- the
// netlist is asynchronous, so no timestamps ever reach the log.
//
// Matrix, RC-debounce model and clock are adapted from the vendored tb_014.v.
//
`timescale 1ns / 10ps

`define  REF014_CLOCK_HPERIOD    125      // 4 MHz debounce-model clock
`define  REF014_TIME_LIMIT       4000000  // global watchdog, ns

//______________________________________________________________________________
//
// External RC debounce model (from the vendored tb_014.v)
//
module ref014_rp
(
   input  reset,
   input  clock,
   output rp
);
reg [3:0] count;

assign rp = (count >= 8) & reset;

initial count = 0;

always @(negedge reset or posedge clock)
begin
   if (!reset)
      count <= 0;
   else
      if (count < 8)
         count <= count + 1;
end
endmodule

//______________________________________________________________________________
//
module ref014_tb();

tri1 [7:0] nAD;
reg  [7:0] AD_in;
reg        AD_oe;

reg        nCS;
reg        nDIN;
reg        nDOUT;
reg        nSYNC;
reg        nINIT;
reg        nIAKI;
tri1       nRPLY;
tri1       nIRQ;
wire       nIAKO;

wire [7:1] Y_in;
tri1 [7:1] Y_out;
wire [9:0] X_in;

reg        CTRL;
reg        SHIFT;
reg        EC1;
reg        EC2;
reg        CLK;

reg [79:0] kb;

assign nAD = AD_oe ? AD_in : 8'hZZ;

//______________________________________________________________________________
//
// Keyboard matrix (vendored model): kb[r*10+c], r=0 is the ground column Y0
//
generate
genvar i;
   for (i = 0; i < 7; i = i + 1)
   begin: Y
      assign Y_in[i+1] = Y_out[i+1] &
                  ( kb[10*i+19] | kb[10*i+18] | kb[10*i+17] | kb[10*i+16]
                  | kb[10*i+15] | kb[10*i+14] | kb[10*i+13] | kb[10*i+12]
                  | kb[10*i+11] | kb[10*i+10]);
   end

   for (i = 0; i < 10; i = i + 1)
   begin: X
      assign X_in[i] = ( !kb[0+i])
                  & (!kb[10+i] | Y_out[1])
                  & (!kb[20+i] | Y_out[2])
                  & (!kb[30+i] | Y_out[3])
                  & (!kb[40+i] | Y_out[4])
                  & (!kb[50+i] | Y_out[5])
                  & (!kb[60+i] | Y_out[6])
                  & (!kb[70+i] | Y_out[7]);
   end
endgenerate

tri1 RP1_net;
tri1 RP2_net;
wire RP1_in;
wire RP2_in;

ref014_rp rp1 (.reset(RP1_net), .clock(CLK), .rp(RP1_in));
ref014_rp rp2 (.reset(RP2_net), .clock(CLK), .rp(RP2_in));

initial
begin
   CLK = 1'b0;
   forever #`REF014_CLOCK_HPERIOD CLK = ~CLK;
end

initial
begin
   #`REF014_TIME_LIMIT
   $display("FATAL: ref014_tb time limit");
   $finish;
end

//______________________________________________________________________________
//
// Scenario key map: id -> kb bit (see ref014_scenario.v header)
//
function integer kbit (input integer id);
begin
   case (id)
      1: kbit = 16;  // row 1 col 6, code 0141
      2: kbit = 26;  // row 2 col 6, code 0142
      3: kbit = 36;  // row 3 col 6, code 0143
      4: kbit = 46;  // row 4 col 6, code 0144
      5: kbit = 56;  // row 5 col 6, code 0145
      6: kbit = 66;  // row 6 col 6, code 0146 (pressed with АР2/EC2)
      7: kbit = 31;  // row 3 col 1, code 0013 (autoar2 -> vector 0274)
      8: kbit = 76;  // row 7 col 6, code 0147
      default:
      begin
         $display("FATAL: unknown key id %0d", id);
         $finish;
      end
   endcase
end
endfunction

//______________________________________________________________________________
//
// RPLY handshake with a timeout (20 us poll cap)
//
task wait_rply_fall (output ok);
integer n;
begin
   ok = 0;
   for (n = 0; n < 400 && !ok; n = n + 1)
      if (nRPLY === 1'b0) ok = 1; else #50;
end
endtask

task wait_rply_rise;
integer n;
reg ok;
begin
   ok = 0;
   for (n = 0; n < 400 && !ok; n = n + 1)
      if (nRPLY !== 1'b0) ok = 1; else #50;
end
endtask

//______________________________________________________________________________
//
// Bus primitives
//
task bus_read
(
   input  [7:0] addr,
   input        cs_early_release, // deassert nCS right after SYNC fall
   input        no_cs,            // keep nCS high for the whole cycle
   output       ok,
   output [7:0] data
);
begin
   nCS   = no_cs ? 1'b1 : 1'b0;
   AD_in = ~addr;
   AD_oe = 1;
   #250 nSYNC = 0;
   #250 AD_oe = 0;
   if (cs_early_release)
      nCS = 1;
   nDIN = 0;
   wait_rply_fall(ok);
   #125;
   if (ok)
      data = ~nAD;
   nDIN = 1;
   if (ok)
      wait_rply_rise;
   #125 nSYNC = 1;
   #250 nCS = 1;
end
endtask

task bus_write
(
   input  [7:0] addr,
   input  [7:0] data,
   output       ok
);
begin
   nCS   = 0;
   AD_in = ~addr;
   AD_oe = 1;
   #250 nSYNC = 0;
   #250 AD_in = ~data;
   #250 nDOUT = 0;
   wait_rply_fall(ok);
   #125 nDOUT = 1;
   if (ok)
      wait_rply_rise;
   #125 nSYNC = 1;
   AD_oe = 0;
   #250 nCS = 1;
end
endtask

//______________________________________________________________________________
//
// Scenario tasks (the $display formats are the contract -- ref014_beh_tb.v
// must produce identical lines)
//
task t_init;
begin
   nINIT = 0;
   #2000 nINIT = 1;
   #1000;
   $display("INIT");
end
endtask

task t_irq;
begin
   #2000;
   $display("IRQ=%b", (nIRQ === 1'b0));
end
endtask

task t_rd (input [7:0] addr);
reg ok;
reg [7:0] d;
begin
   bus_read(addr, 1'b0, 1'b0, ok, d);
   if (ok) $display("RD %03o = %03o", addr, d);
   else    $display("RD %03o = TIMEOUT", addr);
end
endtask

task t_rd_cslatch (input [7:0] addr);
reg ok;
reg [7:0] d;
begin
   bus_read(addr, 1'b1, 1'b0, ok, d);
   if (ok) $display("RDCSL %03o = %03o", addr, d);
   else    $display("RDCSL %03o = TIMEOUT", addr);
end
endtask

task t_rd_nocs (input [7:0] addr);
reg ok;
reg [7:0] d;
begin
   bus_read(addr, 1'b0, 1'b1, ok, d);
   if (ok) $display("RDNOCS %03o = %03o", addr, d);
   else    $display("RDNOCS %03o = TIMEOUT", addr);
end
endtask

task t_wr (input [7:0] addr, input [7:0] data);
reg ok;
begin
   bus_write(addr, data, ok);
   if (ok) $display("WR %03o <- %03o", addr, data);
   else    $display("WR %03o <- %03o TIMEOUT", addr, data);
end
endtask

// DATIO read-modify-write: DIN then DOUT under ONE SYNC
task t_rmw (input [7:0] addr, input [7:0] wdata);
reg ok1, ok2;
reg [7:0] d;
begin
   nCS   = 0;
   AD_in = ~addr;
   AD_oe = 1;
   #250 nSYNC = 0;
   #250 AD_oe = 0;
   nDIN = 0;
   wait_rply_fall(ok1);
   #125;
   if (ok1)
      d = ~nAD;
   nDIN = 1;
   if (ok1)
      wait_rply_rise;
   #250 AD_oe = 1;
   AD_in = ~wdata;
   #250 nDOUT = 0;
   wait_rply_fall(ok2);
   #125 nDOUT = 1;
   if (ok2)
      wait_rply_rise;
   #125 nSYNC = 1;
   AD_oe = 0;
   #250 nCS = 1;
   if (ok1 && ok2) $display("RMW %03o rd=%03o wr=%03o", addr, d, wdata);
   else            $display("RMW %03o TIMEOUT", addr);
end
endtask

// Interrupt acknowledge: DIN + nIAKI, NO SYNC (the vm1 shape)
task t_iak;
reg ok;
reg [7:0] v;
begin
   nCS   = 1;
   AD_oe = 0;
   #250 nDIN = 0;
   #250 nIAKI = 0;
   wait_rply_fall(ok);
   #125;
   if (ok)
      v = ~nAD;
   nDIN  = 1;
   nIAKI = 1;
   if (ok)
      wait_rply_rise;
   #250;
   if (ok) $display("IAK = %03o", v);
   else    $display("IAK = TIMEOUT");
end
endtask

task t_press (input integer id);
begin
   kb[kbit(id)] = 1;
   @ (posedge RP1_in);   // press-debounce complete (WSTB point)
   #2000;
   $display("PRESS K%0d IRQ=%b", id, (nIRQ === 1'b0));
end
endtask

task t_release (input integer id);
begin
   kb[kbit(id)] = 0;
   @ (posedge RP2_in);   // release-debounce complete
   #2000;
   $display("RELEASE K%0d", id);
end
endtask

// АР2 modifier: logical 1 = held = EC2 pin low
task t_ec2 (input v);
begin
   EC2 = ~v;
   #500;
   $display("EC2=%b", v);
end
endtask

`include "ref014_scenario.v"

//______________________________________________________________________________
//
initial
begin
   kb    = 0;
   CTRL  = 1;
   SHIFT = 1;
   EC1   = 1;
   EC2   = 1;
   AD_in = 0;
   AD_oe = 0;
   nCS   = 1;
   nDIN  = 1;
   nDOUT = 1;
   nSYNC = 1;
   nIAKI = 1;
   nINIT = 0;
   #5000;
   scenario;
   $finish;
end

//______________________________________________________________________________
//
vp_014 vp_014
(
   .PIN_nAD(nAD),
   .PIN_nSYNC(nSYNC),
   .PIN_nDIN(nDIN),
   .PIN_nDOUT(nDOUT),
   .PIN_nINIT(nINIT),
   .PIN_nCS(nCS),
   .PIN_nIAKI(nIAKI),
   .PIN_nIAKO(nIAKO),
   .PIN_nRPLY(nRPLY),
   .PIN_nIRQ(nIRQ),
   .PIN_Y(Y_in),
   .PIN_Y_OC(Y_out),
   .PIN_X(X_in),
   .PIN_RP1_OC(RP1_net),
   .PIN_RP2_OC(RP2_net),
   .PIN_RP1(RP1_in),
   .PIN_RP2(RP2_in),
   .PIN_nCTRL(CTRL),
   .PIN_nSHIFT(SHIFT),
   .PIN_nEC1(EC1),
   .PIN_EC2(EC2)
);

endmodule
