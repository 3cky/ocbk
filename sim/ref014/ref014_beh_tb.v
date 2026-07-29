//
// Phase 6 contract equivalence: the behavioral src/peripheral/bk_kbd014.sv driven
// through the SAME shared scenario (ref014_scenario.v) as the vp_014 gate
// netlist; the output must diff-match the same committed golden_014.txt.
//
// The bus here is the 16-bit inverted tri-state Q-bus of the SoC; nCS is
// generated like the 037's PIN_nBS (window compare on the presented
// address), the key events go in through the translator-side strobe
// interface (make strobe + code/ar2 + key_down level) instead of the
// keyboard matrix. Presses use the same code map as the netlist matrix
// positions - a wrong table entry breaks the golden diff.
//
`timescale 1ns / 10ps

`define  BEH014_TIME_LIMIT  4000000   // global watchdog, ns

module ref014_beh_tb();

reg         clk;        // pin_clk_p equivalent, ~3 MHz
wire        clk_n = ~clk;

tri1 [15:0] ad_n;
reg  [15:0] ad_out;
reg         ad_oe;
reg         sync_n;
reg         din_n;
reg         dout_n;
reg         cs_n;
reg         iako_n;
reg         init_n;
tri1        rply_n;
tri1        virq_n;

reg         key_stb;
reg  [6:0]  key_code;
reg         key_ar2;
reg         key_down;
reg         ec2_level;

assign ad_n = ad_oe ? ~ad_out : 16'hZZZZ;

initial
begin
   clk = 1'b0;
   forever #165 clk = ~clk;
end

initial
begin
   #`BEH014_TIME_LIMIT
   $display("FATAL: ref014_beh_tb time limit");
   $finish;
end

//______________________________________________________________________________
//
// Scenario key map: id -> final KOI-7 code (must equal what the netlist
// generates for the matrix positions in ref014_tb.v)
//
function [6:0] kcode (input integer id);
begin
   case (id)
      1: kcode = 7'o141;
      2: kcode = 7'o142;
      3: kcode = 7'o143;
      4: kcode = 7'o144;
      5: kcode = 7'o145;
      6: kcode = 7'o146;   // pressed with АР2 (EC2) held in the scenario
      7: kcode = 7'o013;   // autoar2 key -> vector 0274 on its own
      8: kcode = 7'o147;
      default:
      begin
         $display("FATAL: unknown key id %0d", id);
         $finish;
      end
   endcase
end
endfunction

// the 037's PIN_nBS window: 177660-177663
function nbs (input [15:0] addr);
begin
   nbs = ~(addr[15:2] == (16'o177660 >> 2));
end
endfunction

//______________________________________________________________________________
//
task wait_rply_fall (output ok);
integer n;
begin
   ok = 0;
   for (n = 0; n < 400 && !ok; n = n + 1)
      if (rply_n === 1'b0) ok = 1; else #50;
end
endtask

task wait_rply_rise;
integer n;
reg ok;
begin
   ok = 0;
   for (n = 0; n < 400 && !ok; n = n + 1)
      if (rply_n !== 1'b0) ok = 1; else #50;
end
endtask

// data checker: the 014 side must never drive the upper byte with ones
task check_upper (input [15:0] d, input [7:0] addr);
begin
   if (d[15:8] !== 8'h00)
      $display("BEH-UPPER-BYTE addr=%03o data=%06o", addr, d);
end
endtask

//______________________________________________________________________________
//
task bus_read
(
   input  [7:0]  addr,             // low byte; full address = {8'hFF, addr}
   input         cs_early_release,
   input         no_cs,
   output        ok,
   output [15:0] data
);
reg [15:0] a;
begin
   a      = {8'hFF, addr};
   cs_n   = no_cs ? 1'b1 : nbs(a);
   ad_out = a;
   ad_oe  = 1;
   #250 sync_n = 0;
   #250 ad_oe = 0;
   if (cs_early_release)
      cs_n = 1;
   din_n = 0;
   wait_rply_fall(ok);
   #125;
   if (ok)
      data = ~ad_n;
   din_n = 1;
   if (ok)
      wait_rply_rise;
   #125 sync_n = 1;
   #250 cs_n = 1;
end
endtask

task bus_write
(
   input  [7:0] addr,
   input  [7:0] data,
   output       ok
);
reg [15:0] a;
begin
   a      = {8'hFF, addr};
   cs_n   = nbs(a);
   ad_out = a;
   ad_oe  = 1;
   #250 sync_n = 0;
   #250 ad_out = {8'h00, data};
   #250 dout_n = 0;
   wait_rply_fall(ok);
   // bk_kbd014's write RPLY is combinational (wr_fast) but the register
   // load is clocked: hold DOUT across a CPU clock edge, as the vm1 does
   @(negedge clk);
   #50 dout_n = 1;
   if (ok)
      wait_rply_rise;
   #125 sync_n = 1;
   ad_oe = 0;
   #250 cs_n = 1;
end
endtask

//______________________________________________________________________________
//
// Scenario tasks - $display formats identical to ref014_tb.v
//
task t_init;
begin
   init_n = 0;
   #2000 init_n = 1;
   #1000;
   $display("INIT");
end
endtask

task t_irq;
begin
   #2000;
   $display("IRQ=%b", (virq_n === 1'b0));
end
endtask

task t_rd (input [7:0] addr);
reg ok;
reg [15:0] d;
begin
   bus_read(addr, 1'b0, 1'b0, ok, d);
   if (ok) begin
      check_upper(d, addr);
      $display("RD %03o = %03o", addr, d[7:0]);
   end else
      $display("RD %03o = TIMEOUT", addr);
end
endtask

task t_rd_cslatch (input [7:0] addr);
reg ok;
reg [15:0] d;
begin
   bus_read(addr, 1'b1, 1'b0, ok, d);
   if (ok) begin
      check_upper(d, addr);
      $display("RDCSL %03o = %03o", addr, d[7:0]);
   end else
      $display("RDCSL %03o = TIMEOUT", addr);
end
endtask

task t_rd_nocs (input [7:0] addr);
reg ok;
reg [15:0] d;
begin
   bus_read(addr, 1'b0, 1'b1, ok, d);
   if (ok) $display("RDNOCS %03o = %03o", addr, d[7:0]);
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
reg [15:0] a, d;
begin
   a      = {8'hFF, addr};
   cs_n   = nbs(a);
   ad_out = a;
   ad_oe  = 1;
   #250 sync_n = 0;
   #250 ad_oe = 0;
   din_n = 0;
   wait_rply_fall(ok1);
   #125;
   if (ok1)
      d = ~ad_n;
   din_n = 1;
   if (ok1)
      wait_rply_rise;
   #250 ad_oe = 1;
   ad_out = {8'h00, wdata};
   #250 dout_n = 0;
   wait_rply_fall(ok2);
   @(negedge clk);          // hold DOUT across a clock edge (see bus_write)
   #50 dout_n = 1;
   if (ok2)
      wait_rply_rise;
   #125 sync_n = 1;
   ad_oe = 0;
   #250 cs_n = 1;
   if (ok1 && ok2) begin
      check_upper(d, addr);
      $display("RMW %03o rd=%03o wr=%03o", addr, d[7:0], wdata);
   end else
      $display("RMW %03o TIMEOUT", addr);
end
endtask

// Interrupt acknowledge: DIN + IAKI, NO SYNC (the vm1 shape)
task t_iak;
reg ok;
reg [15:0] v;
begin
   cs_n  = 1;
   ad_oe = 0;
   #250 din_n = 0;
   #250 iako_n = 0;
   wait_rply_fall(ok);
   #125;
   if (ok)
      v = ~ad_n;
   din_n  = 1;
   iako_n = 1;
   if (ok)
      wait_rply_rise;
   #250;
   if (ok) begin
      check_upper(v, 8'o000);
      $display("IAK = %03o", v[7:0]);
   end else
      $display("IAK = TIMEOUT");
end
endtask

task t_press (input integer id);
begin
   key_code = kcode(id);
   key_ar2  = ec2_level | (id == 7);   // K7 is the autoar2 key
   key_down = 1;
   @ (posedge clk);
   key_stb = 1;
   @ (posedge clk);
   key_stb = 0;
   #2000;
   $display("PRESS K%0d IRQ=%b", id, (virq_n === 1'b0));
end
endtask

task t_release (input integer id);
begin
   key_down = 0;
   #2000;
   $display("RELEASE K%0d", id);
end
endtask

task t_ec2 (input v);
begin
   ec2_level = v;
   #500;
   $display("EC2=%b", v);
end
endtask

`include "ref014_scenario.v"

//______________________________________________________________________________
//
initial
begin
   ad_out    = 0;
   ad_oe     = 0;
   sync_n    = 1;
   din_n     = 1;
   dout_n    = 1;
   cs_n      = 1;
   iako_n    = 1;
   init_n    = 0;
   key_stb   = 0;
   key_code  = 0;
   key_ar2   = 0;
   key_down  = 0;
   ec2_level = 0;
   #5000;
   scenario;
   $finish;
end

//______________________________________________________________________________
//
bk_kbd014 dut
(
   .clk_fsm(clk_n),
   .clk_p(clk),
   .init_n(init_n),
   .ad_n(ad_n),
   .sync_n(sync_n),
   .din_n(din_n),
   .dout_n(dout_n),
   .cs_n(cs_n),
   .iako_n(iako_n),
   .rply_n(rply_n),
   .virq_n(virq_n),
   .key_stb(key_stb),
   .key_code(key_code),
   .key_ar2(key_ar2),
   .key_down(key_down)
);

endmodule
