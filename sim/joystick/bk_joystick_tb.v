// ============================================================================
//  bk_joystick_tb - the MSX-pad -> BK-0177714 translation contract
// ----------------------------------------------------------------------------
//  bk_joystick has no bus, no state the CPU can see and no reset. Everything it
//  can get wrong is therefore in three places, and this tb is built around them:
//
//    1. THE INVERSION. MSX pads are active low (a switch to GND against the
//       pads' weak pull-ups); BkEmu's PeripheralPort is active high.
//
//    2. THE REMAP, which is the real error surface. The two direction nibbles
//       are different permutations - MSX is U,D,L,R and the BK is U,R,D,L - so
//       a plain pass-through is wrong in a way that still "works" for UP. Every
//       one of the twelve inputs is therefore walked individually and checked
//       for WHICH bit it lands on, with the other byte held at 0 throughout.
//
//    3. THE POWER-ON WORD. The module has no reset by design, so the only thing
//       that makes 0177714 read 0 before the first clock edge is the sync
//       chain's declaration-time initial values. Section 1 checks that BEFORE
//       any edge - and it is what guarantees the ten qbus_mem testbenches
//       that tie joy_word off never see an X propagate into rdata.
//
//  Section 8 pins the synchroniser DEPTH (exactly two clocks, no more, no
//  fewer). That is not a performance check: a one-flop chain is a metastability
//  hazard on an asynchronous pad, and a combinational path would put a raw pad
//  into qbus_mem's rdata cone.
//
//  WHAT THIS LEG DOES NOT OWN. The bus side - that a read of 0177714 returns
//  this word, and that a DATIO read half sees it while the write half still
//  reaches the Covox/AY seam - belongs to sim/audio's spk_capture_tb, which
//  drives the REAL qbus_mem (section 10 there, mutations Q6-Q9 in
//  sim/run_audio.sh). The !sel2_n GATE that keeps the word out of the SMK
//  I/O-page overlay merge needs a real SDRAM behind that overlay, so sim/smk
//  owns it (its section 2). Same division of labour as sim/covox and sim/ts:
//  device here, seam there.
// ============================================================================
`timescale 1ns/1ps

module bk_joystick_tb;

   // MSX DE-9 index, active low on the pads.
   localparam integer P_UP    = 0;
   localparam integer P_DOWN  = 1;
   localparam integer P_LEFT  = 2;
   localparam integer P_RIGHT = 3;
   localparam integer P_TRGA  = 4;
   localparam integer P_TRGB  = 5;

   // BkEmu JoystickManager masks, active high in the BK word.
   localparam [7:0] B_UP     = 8'o001;
   localparam [7:0] B_RIGHT  = 8'o002;
   localparam [7:0] B_DOWN   = 8'o004;
   localparam [7:0] B_LEFT   = 8'o010;
   localparam [7:0] B_START  = 8'o020;   // no DE-9 source: must stay 0
   localparam [7:0] B_A      = 8'o040;
   localparam [7:0] B_B      = 8'o100;
   localparam [7:0] B_SELECT = 8'o200;   // no DE-9 source: must stay 0

   localparam [7:0] B_ALL    = B_UP | B_RIGHT | B_DOWN | B_LEFT | B_A | B_B;

   reg         clk     = 1'b0;
   reg  [5:0]  pad_a_n = 6'b111111;      // released
   reg  [5:0]  pad_b_n = 6'b111111;
   wire [15:0] joy_word;

   integer errors = 0;
   integer i;

   always #5 clk = ~clk;                 // first posedge at t = 5 ns

   bk_joystick dut (
      .clk      (clk),
      .pad_a_n  (pad_a_n),
      .pad_b_n  (pad_b_n),
      .joy_word (joy_word)
   );

   // ---- anti-vacuity watchdog: how many distinct words the run produced ----
   reg     seen [0:65535];
   integer distinct = 0;
   always @(posedge clk) begin
      if (^joy_word === 1'bx) begin
         $display("JOY-ERROR joy_word went X at t=%0t", $time);
         errors = errors + 1;
      end else if (!seen[joy_word]) begin
         seen[joy_word] = 1'b1;
         distinct = distinct + 1;
      end
   end

   // ---- helpers ------------------------------------------------------------
   task settle; begin repeat (4) @(posedge clk); #1; end endtask

   // press_*(mask) takes an MSX pad mask (bit set = that control is HELD) and
   // presents its complement, which is what the DE-9 switches do to the pins.
   task press_a(input [5:0] m); begin pad_a_n = ~m; settle; end endtask
   task press_b(input [5:0] m); begin pad_b_n = ~m; settle; end endtask

   task chk(input [255:0] what, input [15:0] got, input [15:0] exp);
      begin
         if (got !== exp) begin
            $display("JOY-ERROR %0s: got %06o expected %06o", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   task chk_walk(input [63:0] port, input [63:0] name,
                 input [15:0] got, input [15:0] exp);
      begin
         if (got !== exp) begin
            $display("JOY-ERROR walk port %0s %0s: got %06o expected %06o",
                     port, name, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   // ---- the walk table: one MSX pad -> one BK bit --------------------------
   // Written as data rather than as an expression so the tb states the contract
   // instead of re-deriving it the way the RTL does.
   reg [5:0]  walk_pad  [0:5];
   reg [7:0]  walk_bit  [0:5];
   reg [63:0] walk_name [0:5];

   initial begin
      walk_pad[0] = 6'b1 << P_UP;    walk_bit[0] = B_UP;    walk_name[0] = "UP";
      walk_pad[1] = 6'b1 << P_DOWN;  walk_bit[1] = B_DOWN;  walk_name[1] = "DOWN";
      walk_pad[2] = 6'b1 << P_LEFT;  walk_bit[2] = B_LEFT;  walk_name[2] = "LEFT";
      walk_pad[3] = 6'b1 << P_RIGHT; walk_bit[3] = B_RIGHT; walk_name[3] = "RIGHT";
      walk_pad[4] = 6'b1 << P_TRGA;  walk_bit[4] = B_A;     walk_name[4] = "TRG_A";
      walk_pad[5] = 6'b1 << P_TRGB;  walk_bit[5] = B_B;     walk_name[5] = "TRG_B";
   end

   initial begin
      for (i = 0; i < 65536; i = i + 1) seen[i] = 1'b0;

      // ================= 1. the power-on word, BEFORE any clock edge ========
      // No reset exists, so this is purely the sync chain's initial values -
      // and it is the assertion the joy_word tie-offs in the SoC testbenches
      // rest on. Checked at t=1, four ns before the first posedge.
      #1;
      chk("1: power-on word is 0 before the first edge", joy_word, 16'o000000);

      // ================= 2. idle: nothing plugged in / nothing held =========
      settle;
      chk("2: both ports released", joy_word, 16'o000000);

      // ================= 3. per-control walk, PORT A -> the LOW byte ========
      for (i = 0; i < 6; i = i + 1) begin
         press_a(walk_pad[i]);
         chk_walk("A", walk_name[i], joy_word, {8'h00, walk_bit[i]});
         press_a(6'b000000);
         chk_walk("A released", walk_name[i], joy_word, 16'o000000);
      end

      // ================= 4. per-control walk, PORT B -> the HIGH byte =======
      for (i = 0; i < 6; i = i + 1) begin
         press_b(walk_pad[i]);
         chk_walk("B", walk_name[i], joy_word, {walk_bit[i], 8'h00});
         press_b(6'b000000);
         chk_walk("B released", walk_name[i], joy_word, 16'o000000);
      end

      // ================= 5. both ports at once, distinct patterns ===========
      // The case a byte swap or a collapse of the two ports cannot survive:
      // A = UP + TRG_A, B = LEFT + TRG_B, which share no bit position.
      press_a((6'b1 << P_UP)   | (6'b1 << P_TRGA));
      press_b((6'b1 << P_LEFT) | (6'b1 << P_TRGB));
      chk("5: A=UP+TRG_A, B=LEFT+TRG_B", joy_word,
          {(B_LEFT | B_B), (B_UP | B_A)});

      // ...and the mirror image, so neither port can be a copy of the other.
      press_a((6'b1 << P_LEFT) | (6'b1 << P_TRGB));
      press_b((6'b1 << P_UP)   | (6'b1 << P_TRGA));
      chk("5: A=LEFT+TRG_B, B=UP+TRG_A", joy_word,
          {(B_UP | B_A), (B_LEFT | B_B)});

      press_a(6'b000000);
      press_b(6'b000000);

      // ================= 6. diagonals =======================================
      press_a((6'b1 << P_UP) | (6'b1 << P_RIGHT));
      chk("6: A up-right", joy_word, {8'h00, (B_UP | B_RIGHT)});
      press_a((6'b1 << P_DOWN) | (6'b1 << P_LEFT));
      chk("6: A down-left", joy_word, {8'h00, (B_DOWN | B_LEFT)});
      press_b((6'b1 << P_DOWN) | (6'b1 << P_RIGHT));
      chk("6: B down-right over A down-left", joy_word,
          {(B_DOWN | B_RIGHT), (B_DOWN | B_LEFT)});
      press_a(6'b000000);
      press_b(6'b000000);

      // ================= 7. START and SELECT have no source =================
      // Every pad held on both ports: the word must be exactly the six mapped
      // bits per byte (0o157), i.e. bits 4 and 7 of each byte stay clear. An
      // MSX pad cannot produce START or SELECT and the RTL must not invent them.
      press_a(6'b111111);
      press_b(6'b111111);
      chk("7: everything held", joy_word, {B_ALL, B_ALL});
      if (|(joy_word & {(B_START | B_SELECT), (B_START | B_SELECT)})) begin
         $display("JOY-ERROR 7: START/SELECT asserted (%06o)", joy_word);
         errors = errors + 1;
      end
      press_a(6'b000000);
      press_b(6'b000000);
      chk("7: everything released again", joy_word, 16'o000000);

      // ================= 8. the synchroniser is exactly two deep ============
      // Change a pad on a negedge, then count posedges. One flop would show the
      // change after the first; a combinational path would show it immediately.
      @(negedge clk);
      pad_a_n = ~(6'b1 << P_RIGHT);
      #1;
      chk("8: no combinational bypass (no edge yet)", joy_word, 16'o000000);
      @(posedge clk); #1;
      chk("8: still stale after ONE clock", joy_word, 16'o000000);
      @(posedge clk); #1;
      chk("8: present after TWO clocks", joy_word, {8'h00, B_RIGHT});

      // ...and the same on the release edge, so the depth is not direction-
      // dependent.
      @(negedge clk);
      pad_a_n = 6'b111111;
      @(posedge clk); #1;
      chk("8: release still stale after ONE clock", joy_word, {8'h00, B_RIGHT});
      @(posedge clk); #1;
      chk("8: release present after TWO clocks", joy_word, 16'o000000);

      // ================= 9. anti-vacuity ====================================
      settle;
      if (distinct < 16) begin
         $display("JOY-ERROR only %0d distinct words seen", distinct);
         errors = errors + 1;
      end

      $display("JOYDEV: %0d distinct words, all-held = %06o",
               distinct, {B_ALL, B_ALL});

      if (errors == 0) $display("COSIM PASS");
      else             $display("COSIM FAIL (%0d errors)", errors);
      $finish;
   end

endmodule
