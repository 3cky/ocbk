//
// Phase 6 interrupt-latency reference oracle: vm1 CPU + reference va_037
// (authentic nBS + RAM cycle-stealing) + behavioural DRAM/ROM + the VENDORED
// vp_014 gate netlist (matrix + RC debounce). Runs the gen_kbd_test.py
// program; the reduced FETCH trace is committed as golden_kbd.txt, which the
// SoC integration run (ref014_irq_soc_tb.v: va_037_sync + qbus_mem +
// SDRAM model + behavioral bk_kbd014) must reproduce exactly - that diff is
// what calibrates N_KBD / N_IAK and the VIRQ pin-flop timing.
//
// Bus model mirrors sim/ref037/ref037_tb.v: RAM data from the tb array with
// RPLY from the 037 (video stealing active), ROM/IO fixed N_ROM reply. The
// keyboard block 177660-177663 is served by the vp_014 netlist behind the
// 037's authentic PIN_nBS - the tb I/O handler excludes it.
//
// The netlist's asynchronous nIRQ is retimed onto the CPU clock rising edge
// by an external flip-flop, exactly like the real BK board (bk0011m-sch
// sheet 1: D11, К555ТМ9 hex posedge D, re-times IRQ1-3/VIRQ + ACLO + DMR on
// the CLC net) - and exactly like bk_kbd014's final posedge virq flop, so
// the SoC run sees the same sampling grid.
//
// Key events are injected on writes to the ARM mailbox 000776 (phase id in
// the data): phases 1/2/3 drive the keyboard matrix (the RC debounce delay
// is absorbed by WAIT / the fixed-count delay loop, so the injection jitter
// never reaches the fetch trace); phase 4 pulses nIRQ1 for STOP_PULSE CPU
// clocks, launched on a clock edge (the СТОП one-shot shape in ocbk_top).
//
`timescale 1ns / 100ps

`define CLKIN_HALF 83          // ~6.02 MHz 037 clock (CPU = /2 = ~3.01 MHz)
`define N_ROM      2           // ROM/IO RPLY: CPU cycles after DIN/DOUT

`define TEST_LO 16'o001000
`define TEST_HI 16'o002000

//______________________________________________________________________________
//
// External RC debounce model (as the vendored tb_014.v)
//
module irq_rp
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
module ref014_irq_ref_tb;

//______________________________________________________________________________
// Clocks: CLKIN (037) base; CPU clk = CLKIN/2, phase-locked (as ref037_tb).
//
reg     clkin;
reg     clk;
integer nclk;

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

reg         rply_ext_n;
assign rply = rply_ext_n ? 1'bZ : 1'b0;

wire        rply037_n;
assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

reg         dclo, aclo;
reg  [3:1]  irq;
reg         dmgi, sp;
reg  [1:0]  pa;
wire        dmgo;
tri1        init, dmr, sack, iako;
wire [2:1]  sel;
wire        bsy;

//______________________________________________________________________________
// Address decode (latched at negedge sync)
//
reg [15:0] addr;
reg        sel_ram, sel_rom, sel_io, sel_kbd;

always @(negedge sync)
begin
   addr    = ~ad;
   sel_ram = (addr < 16'o100000);
   sel_rom = (addr >= 16'o100000) && (addr < 16'o177600);
   sel_kbd = (addr[15:2] == (16'o177660 >> 2));       // vp_014 serves these
   // 177674-177677 deliberately unserved (as on a real BK): the IRQ1/HALT
   // entry's 177676/177674 writes must time out -> trap 4 (СТОП = trap-to-4
   // with the BASIC ROM; the 160002 "vector" is never actually read).
   sel_io  = (addr >= 16'o177600) && !(addr[15:2] == (16'o177660 >> 2))
                                  && !(addr[15:2] == (16'o177674 >> 2));
end
always @(posedge sync)
begin
   sel_ram = 1'b0; sel_rom = 1'b0; sel_io = 1'b0; sel_kbd = 1'b0;
end

//______________________________________________________________________________
// Memory arrays (program from gen_kbd_test.py)
//
reg [15:0] ram [0:16383];      // 000000-077777
reg [15:0] rom [0:16319];      // 100000-177577 (HALT vector at 160002 inside)

//______________________________________________________________________________
// RAM DATA path (va_037 owns RAM RPLY), as ref037_tb.
//
always @(*) begin
   ram_data = ram[addr[14:1]];
   ram_oe   = (~din) && sel_ram;
end

reg  wr_committed;
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

//______________________________________________________________________________
// ROM / I/O reply (fixed N_ROM). Reads as ref037_tb; I/O writes (the HALT
// entry stores PSW/PC to 177676/177674 and updates 177716) reply-and-ignore.
//
// The still-in-cycle guards (!din / !dout) matter for 177716: the vm1
// self-replies for the whole 177700-177717 block, and its fast internal
// reply can complete the cycle before this delayed external reply lands -
// an unguarded late assert would hold RPLY forever (the HALT-mode entry
// writes 177716, the first-ever I/O write in these oracles).
always @(negedge din) begin
   if (~sync) begin
      if (sel_rom) begin
         rom_data = rom[addr[14:1]];
         repeat (`N_ROM) @(negedge clk);
         if (!din) begin
            rom_oe = 1'b1; rply_ext_n = 1'b0;
         end
      end else if (sel_io) begin
         io_data = (addr == 16'o177716) ? 16'o100000 : 16'o000000;
         repeat (`N_ROM) @(negedge clk);
         if (!din) begin
            io_oe = 1'b1; rply_ext_n = 1'b0;
         end
      end
   end
end

always @(negedge dout) begin
   if (~sync && (sel_io || sel_rom)) begin
      repeat (`N_ROM) @(negedge clk);
      if (!dout)
         rply_ext_n = 1'b0;
   end
end

always @(posedge din or posedge dout) begin
   @(negedge clk);
   rply_ext_n = 1'b1;
   @(posedge clk);
   rom_oe = 1'b0; io_oe = 1'b0;
end

//______________________________________________________________________________
// Timing measurement (identical methodology to ref037_tb)
//
integer    prev_nclk;
reg [15:0] prev_addr;
reg        have_baseline;

integer nloops;   // 001004 (sloop) visits: phase 4 landed, end the run

always @(negedge din) begin
   if (~sync && sel_ram && addr >= `TEST_LO && addr < `TEST_HI) begin
      if (have_baseline)
         $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
      prev_nclk     = nclk;
      prev_addr     = addr;
      have_baseline = 1'b1;
      if (addr == 16'o001004) begin
         nloops = nloops + 1;
         if (nloops == 6)
            $finish;
      end
   end
end

//______________________________________________________________________________
// CPU (nVIRQ comes retimed through the D11-style posedge flop below)
//
reg virq_r;
vm1 cpu0 (
   .pin_clk_p(clk),   .pin_clk_n(~clk),  .pin_ena(1'b1),
   .pin_pa_n(pa),     .pin_sp_n(sp),
   .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
   .pin_irq_n(irq),   .pin_virq_n(virq_r),
   .pin_ad_n(ad),     .pin_dout_n(dout), .pin_din_n(din),
   .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
   .pin_dmr_n(dmr),   .pin_sack_n(sack), .pin_dmgi_n(dmgi),
   .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel),
   .pin_bsy_n(bsy)
);

//______________________________________________________________________________
// 1801VP1-037 (RAM RPLY + cycle stealing + the authentic nBS decode)
//
wire [6:0] va_a;
wire [1:0] va_cas;
wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync;

va_037 pr_037 (
   .PIN_CLK   (clkin),
   .PIN_R     (~dclo),
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
// 1801VP1-014 keyboard controller (gate netlist) + matrix + RC debounce
//
reg [79:0] kb;
reg        CTRL, SHIFT, EC1, EC2;
wire [7:1] Y_in;
tri1 [7:1] Y_out;
wire [9:0] X_in;
tri1       RP1_net, RP2_net;
wire       RP1_in, RP2_in;
tri1       irq014_n;
wire       iako014_n;

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

irq_rp rp1 (.reset(RP1_net), .clock(clkin), .rp(RP1_in));
irq_rp rp2 (.reset(RP2_net), .clock(clkin), .rp(RP2_in));

vp_014 u_014 (
   .PIN_nAD   (ad[7:0]),
   .PIN_nSYNC (sync),
   .PIN_nDIN  (din),
   .PIN_nDOUT (dout),
   .PIN_nINIT (init),
   .PIN_nCS   (va_nbs),
   .PIN_nIAKI (iako),
   .PIN_nIAKO (iako014_n),
   .PIN_nRPLY (rply),
   .PIN_nIRQ  (irq014_n),
   .PIN_Y     (Y_in),
   .PIN_Y_OC  (Y_out),
   .PIN_X     (X_in),
   .PIN_RP1_OC(RP1_net),
   .PIN_RP2_OC(RP2_net),
   .PIN_RP1   (RP1_in),
   .PIN_RP2   (RP2_in),
   .PIN_nCTRL (CTRL),
   .PIN_nSHIFT(SHIFT),
   .PIN_nEC1  (EC1),
   .PIN_EC2   (EC2)
);

// D11-style retimer: the async netlist nIRQ onto the CPU clock rising edge
// (real-BK fidelity; also what makes the SoC run's posedge virq flop land
// on the same sampling grid).
always @(posedge clk) virq_r <= (irq014_n === 1'b0) ? 1'b0 : 1'b1;

// Bus-charge keeper (board-level physics the tri1 net does not model): the
// 014 releases its AD drivers combinationally with nDIN/nIAKI - unlike the
// synchronous slaves, which hold read data past the strobe (the upstream
// de0_tb1.v convention; bk_kbd014's S_REPLY does the same). The vm1's last
// data-strobe capture lands on the release edge and, on the real BK, reads
// the charge stored on the open-collector lines (they decay through pull-up
// resistors far slower than a CPU cycle). Hold the last 014-driven value on
// AD[7:0] for ~1.2 CPU cycles after the release; the bus is guaranteed idle
// for longer than that after any read (the keeper never fights a driver).
wire drv014 = (u_014.nOE === 1'b0);         // netlist AD output enable (peek)
reg  [7:0] keep_val;
reg        keep_en = 1'b0;
always @(*) if (drv014) keep_val = ~ad[7:0];
always @(negedge drv014) begin
   keep_en = 1'b1;
   #400 keep_en = 1'b0;
end
assign ad[7:0] = (keep_en && !drv014) ? ~keep_val : 8'hZZ;

//______________________________________________________________________________
// ARM mailbox watcher + key-event injection
//
// Phase key map (must match gen_kbd_test.py CODE1/2/3 and the SoC tb):
//   1: kb[16] = matrix (row 1, col 6) = code 0141
//   2: kb[66] = matrix (row 6, col 6) = code 0146, EC2 (АР2) held
//   3: kb[36] = matrix (row 3, col 6) = code 0143 (pressed while masked)
//
event      ev_arm, ev_rd662;

// The ARM anchor fires at the SYNC fall of the mailbox write - a vm1-launched
// edge that lands on the identical CPU cycle in the reference and SoC runs
// (an RPLY-edge anchor would differ by the reply sub-cycle phase and shift
// the phase-4 nIRQ1 pulse by a cycle between the two).
always @(negedge sync) begin
   if (~ad == 16'o000776)
      -> ev_arm;
end

always @(negedge rply) begin
   if (~din && sel_kbd && addr == 16'o177662)
      -> ev_rd662;
end

localparam STOP_PULSE = 64;    // must equal the ocbk_top СТОП one-shot width

initial begin
   kb = 0; CTRL = 1; SHIFT = 1; EC1 = 1; EC2 = 1;

   // Phases 1/2 must raise the VIRQ only after the CPU has entered the WAIT
   // (the mailbox SYNC anchor is ~15 CPU clocks before the WAIT arms; a too-
   // early VIRQ is taken at the pre-WAIT boundary, the pushed PC re-enters
   // the WAIT and the program sleeps forever). #6000 + the RC debounce puts
   // the request comfortably inside the WAIT.
   @(ev_arm);                          // phase 1: plain key -> 060
   #6000 kb[16] = 1;
   @(ev_rd662);                        // ISR60 consumed the code
   #2000 kb = 0;

   @(ev_arm);                          // phase 2: АР2 key -> 0274
   EC2 = 0;
   #6000 kb[66] = 1;
   @(ev_rd662);
   #2000 kb = 0;
   EC2 = 1;

   @(ev_arm);                          // phase 3: masked press (no WAIT: the
   #2000 kb[36] = 1;                   //   fixed-count loop absorbs jitter)
   @(ev_rd662);                        // the program's own 662 read
   #2000 kb = 0;

   @(ev_arm);                          // phase 4: СТОП -> nIRQ1 fixed pulse
   @(posedge clk);                     // launch on a CPU clock edge, as the
   irq[1] = 1'b0;                      // ocbk_top one-shot does
   repeat (STOP_PULSE) @(posedge clk);
   irq[1] = 1'b1;
end

//______________________________________________________________________________
// Program load + reset + sim limit
//
initial begin
   nclk = 0; prev_nclk = 0; have_baseline = 1'b0; nloops = 0;
   ram_oe = 0; rom_oe = 0; io_oe = 0;
   rply_ext_n = 1'b1; wr_committed = 1'b0;
   ram_data = 0; rom_data = 0; io_data = 0;
   pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111;
   virq_r = 1'b1;
   dclo = 1'b0; aclo = 1'b0;

   $readmemh("kbd_ram.hex", ram);
   $readmemh("kbd_rom.hex", rom);

   pr_037.RA   = 8'o000;
   pr_037.M256 = 1'b0;

   repeat (8) @(negedge clk); dclo = 1'b1;
   repeat (4) @(negedge clk); aclo = 1'b1;

   // hard watchdog: the FETCH- prefix breaks the golden diff loudly if the
   // run never reaches the park loop (the sloop counter ends a good run)
   #12_000_000;
   $display("FETCH-TIMEOUT: park loop never reached");
   $finish;
end

endmodule
