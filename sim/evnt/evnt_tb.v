//
// Phase-9 EVNT/IRQ2 oracle: src/bk_evnt.sv against the 037.
//
// bk_evnt is a gate-faithful replica of the real BK-0011M's external frame-
// interrupt detector (D28 K555IE5 /2 + D3:B K555TM2, off the 037's WTI and
// SYNCO pins - see src/bk_evnt.sv for the schematic trace). The 037 itself is
// the timing authority, so the transcript this tb prints is diffed against a
// golden GENERATED FROM THE REFERENCE NETLIST RUN ONLY (`-DREF037`, the
// vendored sim/ref037/va_037.v). The retimed src/va_037_sync.sv must then
// reproduce the same transcript line-for-line - the sim/ref014 contract shape.
//
// Build flags:
//   -DREF037    drive bk_evnt from the reference netlist (golden source)
//   (default)   drive it from the retimed va_037_sync
//   -DMUT=n     inject mutation n (see run.sh) - each must break the diff
//
// Transcript format: every line is an event with the raster position expressed
// against the 037's OWN vgate edges, so the numbers are independent of how the
// tb counts lines:
//
//   EVNT <leg> ASSERT|DEASSERT vg<+/-><clkin>
//
// Legs:
//   1  full screen (177664 bit 9 set)  - the normal 0011M configuration
//   2  1/4 screen  (bit 9 clear)       - WTI stops after 64 displayed lines,
//                                        so the request fires during ACTIVE
//                                        video; the old vgate model could not
//                                        express this at all
//   3  mask semantics                  - masking clears the request at once;
//                                        UNMASKING mid-blanking must NOT
//                                        retro-fire, it waits for the next
//                                        SYNCO edge
//
`timescale 1ns / 100ps

`define CLKIN_HALF 83           // ~6.02 MHz 037 CLKIN, as sim/ref037

module evnt_tb;

// ---------------------------------------------------------------------------
// Clocks. The reference netlist takes CLKIN directly; va_037_sync takes
// sys_clk plus the /16 en_pos/en_neg strobes, so build both from one counter
// exactly as cpu_clkgen does (sys_clk = 16 x CLKIN).
// ---------------------------------------------------------------------------
reg sys_clk = 1'b0;
always #(`CLKIN_HALF/8.0) sys_clk = ~sys_clk;

reg [3:0] divc = 4'd0;
always @(posedge sys_clk) divc <= divc + 1'b1;
wire en_pos = (divc == 4'd15);
wire en_neg = (divc == 4'd7);

// CLKIN reconstructed for the reference netlist (and for the event timebase)
reg clkin = 1'b0;
always @(posedge sys_clk) begin
   if (en_pos) clkin <= 1'b1;
   if (en_neg) clkin <= 1'b0;
end

integer nclkin = 0;
always @(posedge clkin) nclkin = nclkin + 1;

// ---------------------------------------------------------------------------
// Idle Q-bus (the tb only ever writes 177664 to set the screen mode)
// ---------------------------------------------------------------------------
tri1 [15:0] ad;
reg  [15:0] drv_data;
reg         drv_oe = 1'b0;
assign ad = drv_oe ? ~drv_data : 16'hZZZZ;

reg sync_n = 1'b1, din_n = 1'b1, dout_n = 1'b1, wtbt_n = 1'b1;
reg reset  = 1'b1;

wire wti, synco, vgate;

`ifdef REF037
va_037 dut (
   .PIN_CLK   (clkin),
   .PIN_R     (reset),
   .PIN_C     (1'b0),
   .PIN_nAD   (ad),
   .PIN_nSYNC (sync_n),
   .PIN_nDIN  (din_n),
   .PIN_nDOUT (dout_n),
   .PIN_nWTBT (wtbt_n),
   .PIN_nRPLY (),
   .PIN_A     (), .PIN_nCAS (), .PIN_nRAS (), .PIN_nWE (),
   .PIN_nE    (), .PIN_nBS  (),
   .PIN_WTI   (wti),
   .PIN_WTD   (),
   .PIN_nVSYNC(synco)
);
assign vgate = dut.VGATE;
`else
va_037_sync dut (
    .no_steal(1'b0),   // turbo off: authentic 037 arbitration
   .clk       (sys_clk),
   .en_pos    (en_pos),
   .en_neg    (en_neg),
   .mem_ready (1'b1),
   .ext_ram   (1'b0),
   .PIN_R     (reset),
   .PIN_C     (1'b0),
   .PIN_nAD   (ad),
   .PIN_nSYNC (sync_n),
   .PIN_nDIN  (din_n),
   .PIN_nDOUT (dout_n),
   .PIN_nWTBT (wtbt_n),
   .PIN_nRPLY (),
   .PIN_A     (), .PIN_nCAS (), .PIN_nRAS (), .PIN_nWE (),
   .PIN_nE    (), .PIN_nBS  (),
   .PIN_WTI   (wti),
   .PIN_WTD   (),
   .PIN_nVSYNC(synco),
   .cpu_grant (), .video_va (), .vid_fetch (), .vid_line_en (),
   .hgate     (),
   .vgate     (vgate)
);
`endif

// ---------------------------------------------------------------------------
// DUT: the detector. run.sh compiles this against either the real
// src/bk_evnt.sv or a sed-mutated copy of it (see the run.sh header) - there
// is deliberately NO inline replica here that could drift from the RTL.
// ---------------------------------------------------------------------------
reg irq_en = 1'b1;
wire evnt;

bk_evnt u_evnt (
   .sys_clk (sys_clk),
   .rst_n   (~reset),
   .wti     (wti),
   .synco   (synco),
   .irq_en  (irq_en),
   .evnt    (evnt)
);

// ---------------------------------------------------------------------------
// 177664 write (screen mode + scroll base)
// ---------------------------------------------------------------------------
task wr664(input [15:0] val);
begin
   @(negedge clkin);
   drv_data = 16'o177664; drv_oe = 1'b1; wtbt_n = 1'b0;
   #40 sync_n = 1'b0;
   #60 drv_oe = 1'b0; wtbt_n = 1'b1;
   #40 drv_data = val; drv_oe = 1'b1;
   #40 dout_n = 1'b0;
   repeat (6) @(negedge clkin);
   dout_n = 1'b1;
   #40 drv_oe = 1'b0;
   #40 sync_n = 1'b1;
   @(negedge clkin);
end
endtask

// ---------------------------------------------------------------------------
// Event transcript, timed against the 037's own VGATE edges.
// ---------------------------------------------------------------------------
integer vg_rise = 0, vg_fall = 0;
reg     vg_d = 1'b1, evnt_d = 1'b0;
reg [8*8-1:0] leg = "init";

always @(posedge clkin) begin
   if (!reset) begin
      if (!vg_d &&  vgate) vg_rise = nclkin;
      if ( vg_d && !vgate) vg_fall = nclkin;

      if (!evnt_d && evnt)
         $display("EVNT %0s ASSERT   vg+%0d", leg, nclkin - vg_rise);
      if (evnt_d && !evnt)
         $display("EVNT %0s DEASSERT vg+%0d", leg, nclkin - vg_fall);

      vg_d   = vgate;
      evnt_d = evnt;
   end
end

// frame counter (for sequencing only - never printed)
integer frameno = 0;
reg     vgf_d = 1'b1;
always @(posedge clkin) if (!reset) begin
   if (vgf_d && !vgate) frameno = frameno + 1;
   vgf_d = vgate;
end

// ---------------------------------------------------------------------------
initial begin
   repeat (4) @(negedge clkin);
   reset = 1'b0;
   @(negedge clkin);

   // ---- leg 1: full screen ------------------------------------------------
   wr664(16'o001330);                  // bit 9 = full screen, scroll 0330
   wait (frameno == 2);                // settle past the power-on frame
   leg = "L1";
   wait (frameno == 5);

   // ---- leg 2: 1/4 screen -------------------------------------------------
   leg = "----";
   wr664(16'o000330);
   wait (frameno == 7);
   leg = "L2";
   wait (frameno == 10);

   // ---- leg 3: mask semantics ---------------------------------------------
   leg = "----";
   wr664(16'o001330);
   wait (frameno == 12);
   leg = "L3";
   // land inside blanking with the request already asserted, then mask
   wait (vgate == 1'b1);
   repeat (4*384) @(posedge clkin);
   irq_en = 1'b0;                      // must clear immediately
   repeat (2*384) @(posedge clkin);
   irq_en = 1'b1;                      // must NOT retro-fire: next SYNCO edge
   repeat (3*384) @(posedge clkin);
   wait (frameno == 14);

   $display("EVNT done");
   $finish;
end

endmodule
