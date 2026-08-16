// ============================================================================
//  bk_gamepad_tb - the USB-pad -> BK-0177714 translation contract
// ----------------------------------------------------------------------------
//  bk_gamepad has no bus and no state the CPU can see. What it can get wrong
//  lives in four places, and this tb is built around them:
//
//    1. THE REMAP, the real error surface. The host names its outputs
//       l/r/u/d/a/b/x/y/sel/sta; the BK word is U,R,D,L,START,A,B,SELECT. A
//       plain pass-through is wrong in a way that still "works" for UP, so all
//       ten inputs are walked individually and checked for WHICH bit they land
//       on, with everything else held released.
//
//    2. THE TYPE GATE. usb_hid_host reports ONE typ, so bk_mouse (typ 2) and
//       bk_gamepad (typ 3) must never both contribute to joy_word. Section 2
//       drives every game_* input high under typ 0, 1 and 2 and requires zero -
//       the mirror of sim/mouse's `gate` leg, which asserts the same exclusion
//       from the mouse's side.
//
//    3. THE ARMING FLOP. The host clears typ on disconnect but NOT the game_*
//       levels; they hold the last report's values forever. Sections 3 and 7
//       are the reason the flop exists: a pad that has enumerated but not yet
//       reported, and a RE-plugged pad whose stale levels are still high, must
//       both read 0 until reports actually arrive.
//
//    4. WHOLE, AGREED FRAMES ONLY - the board bug of 2026-08-16, sections 7b
//       and 7c. game_* are levels only BETWEEN reports; while one is arriving
//       the wrapper rewrites them byte by byte over ~43 us, so the payload must
//       be LATCHED at the report pulse rather than sampled (7b). And because
//       this host checks no CRC, a packet corrupted on the wire is decoded as a
//       real report where a PC would discard it - so a payload is presented
//       only after two consecutive reports agree on it (7c).
//
//    5. THE POWER-ON WORD. No reset by design, so the only thing making
//       0177714 read 0 before the first clock edge is the sync chain's
//       declaration-time initial values - the same guarantee bk_joystick gives
//       the ten SoC testbenches that tie joy_word off.
//
//  The synchroniser DEPTH is pinned CONTINUOUSLY rather than in a section: the
//  monitor below requires pad_word to equal pl_hold delayed exactly two clk
//  posedges on every edge of the run. That is not a performance check - one
//  flop is a metastability hazard on a signal from another clock domain, and a
//  combinational path would put usb_clk logic straight into qbus_mem's rdata
//  cone. Section 8 only guards against the monitor being vacuous.
//
//  WHAT THIS LEG DOES NOT OWN. The report DECODE - which report byte carries
//  which button - belongs to sim/usb, whose pad legs drive real USB traffic
//  through usb_hid_host and check the ten game_* outputs. Everything upstream
//  of this module's inputs is that oracle's job. The bus side - that a read of
//  0177714 returns joy_word at all, and the !sel2_n gate - belongs to
//  sim/audio's spk_capture_tb (section 10) and sim/smk (section 2), exactly as
//  for bk_joystick. Device here, decode there, seam elsewhere.
// ============================================================================
`timescale 1ns/1ps

module bk_gamepad_tb;

   // Host game_* index, active high, as driven into the DUT below.
   localparam integer G_UP    = 0;
   localparam integer G_DOWN  = 1;
   localparam integer G_LEFT  = 2;
   localparam integer G_RIGHT = 3;
   localparam integer G_A     = 4;
   localparam integer G_B     = 5;
   localparam integer G_X     = 6;
   localparam integer G_Y     = 7;
   localparam integer G_SEL   = 8;
   localparam integer G_STA   = 9;
   localparam integer G_TL    = 10;    // shoulder triggers (hook H9)
   localparam integer G_TR    = 11;

   // BkEmu JoystickManager masks, active high in the BK word.
   localparam [7:0] B_UP     = 8'o001;
   localparam [7:0] B_RIGHT  = 8'o002;
   localparam [7:0] B_DOWN   = 8'o004;
   localparam [7:0] B_LEFT   = 8'o010;
   localparam [7:0] B_START  = 8'o020;
   localparam [7:0] B_A      = 8'o040;
   localparam [7:0] B_B      = 8'o100;
   localparam [7:0] B_SELECT = 8'o200;

   // A USB pad, unlike a DE-9 pad, CAN source START and SELECT.
   localparam [7:0] B_ALL    = 8'o377;

   reg         usb_clk    = 1'b0;
   reg         clk        = 1'b0;
   reg         hid_report = 1'b0;
   reg  [1:0]  hid_typ    = 2'd0;
   // Held, not released, from t=0. The host never clears game_* - they carry
   // the last report's levels forever - so "every input high with nothing
   // enumerated" is the state a board actually powers up into after a pad has
   // been used and unplugged. Starting at 0 would make the arming flop's
   // power-up value unobservable, since a wrongly-armed flop would then leak a
   // zero payload and look correct.
   reg  [11:0] g          = 12'hfff;    // indexed by G_* above
   wire [15:0] pad_word;
   wire        pad_active;

   integer errors = 0;
   integer i;

   // usb_clk 12.08 MHz, clk = cpu_clk_n ~4 MHz: a 3:1 ratio, which is the real
   // BK-0011M relationship. Deliberately NOT an integer-aligned pair of edges -
   // the phases drift, so nothing here can rest on a fixed edge relationship.
   //
   // clk takes its FIRST edge before usb_clk does, which is the order that
   // matters: in ocbk_top the two come from different dividers with no defined
   // start relationship, so the BK side can sample this module before the USB
   // side has run at all. A design that emits X in that window would be a real
   // hazard, and the X watchdog below is what catches it.
   always #17 clk = ~clk;
   initial begin
      usb_clk = 1'b0;
      #23;                              // first usb_clk posedge at t=28, after
      forever #5 usb_clk = ~usb_clk;    // clk's first at t=17
   end

   bk_gamepad dut (
      .usb_clk    (usb_clk),
      .hid_report (hid_report),
      .hid_typ    (hid_typ),
      .g_u        (g[G_UP]),
      .g_d        (g[G_DOWN]),
      .g_l        (g[G_LEFT]),
      .g_r        (g[G_RIGHT]),
      .g_a        (g[G_A]),
      .g_b        (g[G_B]),
      .g_x        (g[G_X]),
      .g_y        (g[G_Y]),
      .g_tl       (g[G_TL]),
      .g_tr       (g[G_TR]),
      .g_sel      (g[G_SEL]),
      .g_sta      (g[G_STA]),
      .clk        (clk),
      .pad_word   (pad_word),
      .pad_active (pad_active)
   );

   // ---- standing checks: X, and the upper byte -----------------------------
   // The upper byte is checked on EVERY edge rather than per-section: there is
   // one USB port, so player 2 must be unreachable by any input combination,
   // not merely by the ones a section happens to drive.
   reg     seen [0:65535];
   integer distinct = 0;
   always @(posedge clk) begin
      if (^pad_word === 1'bx || pad_active === 1'bx) begin
         $display("PAD-ERROR X on the outputs at t=%0t (word=%b active=%b)",
                  $time, pad_word, pad_active);
         errors = errors + 1;
      end else begin
         if (pad_word[15:8] !== 8'h00) begin
            $display("PAD-ERROR upper byte non-zero (%06o) at t=%0t",
                     pad_word, $time);
            errors = errors + 1;
         end
         if (!seen[pad_word]) begin
            seen[pad_word] = 1'b1;
            distinct = distinct + 1;
         end
      end
   end

   // ---- continuous synchroniser-depth check --------------------------------
   // pad_word must equal pl_hold delayed by EXACTLY two clk posedges, at EVERY
   // edge of the whole run - not just in one section. Hand-counted edges were
   // tried first and were the wrong tool: once the agreement filter landed, an
   // input change and a payload change stopped being the same event, and the
   // count raced the report helper (frame() does not return until 5 ns after
   // pl_hold moves, and a clk posedge fits in that gap). This invariant needs
   // no alignment at all, and it holds the depth over every transition the run
   // produces rather than the two a section happens to drive.
   //
   // Both sides read PRE-update values inside the block, so the comparison is
   // exactly the DUT's own p_s0/p_s1 chain restated independently.
   reg [7:0] hold_d1 = 8'h00, hold_d2 = 8'h00;
   integer   depth_moves = 0;
   always @(posedge clk) begin
      if (pad_word[7:0] !== hold_d2) begin
         $display("PAD-ERROR sync depth: pad_word %03o, pl_hold two edges ago %03o (t=%0t)",
                  pad_word[7:0], hold_d2, $time);
         errors = errors + 1;
      end
      if (hold_d1 !== dut.pl_hold) depth_moves = depth_moves + 1;
      hold_d1 <= dut.pl_hold;
      hold_d2 <= hold_d1;
   end

   // ---- helpers ------------------------------------------------------------
   task settle; begin repeat (4) @(posedge clk); #1; end endtask

   // One usb_clk-wide report pulse, driven off the negedge so exactly one
   // posedge sees it - the shape usb_hid_host actually produces.
   task report_pulse;
      begin
         @(negedge usb_clk); hid_report = 1'b1;
         @(negedge usb_clk); hid_report = 1'b0;
      end
   endtask

   // Enumerate as `t` and deliver one report, i.e. arrive at a usable device.
   task plug(input [1:0] t);
      begin
         @(negedge usb_clk); hid_typ = t;
         report_pulse;
         settle;
      end
   endtask

   task unplug;
      begin
         @(negedge usb_clk); hid_typ = 2'd0;
         settle;
      end
   endtask

   // ONE report carrying mask `m`. The building block for the filter legs: a
   // lone frame must never reach pad_word by itself.
   task frame(input [11:0] m); begin g = m; report_pulse; end endtask

   // press(mask) holds exactly the listed controls and delivers the report that
   // latches them. The levels alone do nothing - the payload is latched at the
   // report pulse, never sampled off the inputs.
   task press(input [11:0] m); begin frame(m); settle; end endtask

   task chk(input [255:0] what, input [15:0] got, input [15:0] exp);
      begin
         if (got !== exp) begin
            $display("PAD-ERROR %0s: got %06o expected %06o", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   task chk_walk(input [63:0] name, input [15:0] got, input [15:0] exp);
      begin
         if (got !== exp) begin
            $display("PAD-ERROR walk %0s: got %06o expected %06o",
                     name, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   task chk_act(input [255:0] what, input got, input exp);
      begin
         if (got !== exp) begin
            $display("PAD-ERROR %0s: pad_active %b expected %b", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   // ---- the walk table: one host output -> one BK bit ----------------------
   // Stated as data, not re-derived as an expression: the tb asserts the
   // contract, the RTL states it once. X and Y share bits with A and B by
   // design (four face buttons onto two BK triggers) and section 5 owns that.
   reg [11:0] walk_g    [0:11];
   reg [7:0]  walk_bit  [0:11];
   reg [63:0] walk_name [0:11];

   initial begin
      walk_g[0] = 12'b1 << G_UP;    walk_bit[0] = B_UP;     walk_name[0] = "UP";
      walk_g[1] = 12'b1 << G_DOWN;  walk_bit[1] = B_DOWN;   walk_name[1] = "DOWN";
      walk_g[2] = 12'b1 << G_LEFT;  walk_bit[2] = B_LEFT;   walk_name[2] = "LEFT";
      walk_g[3] = 12'b1 << G_RIGHT; walk_bit[3] = B_RIGHT;  walk_name[3] = "RIGHT";
      walk_g[4] = 12'b1 << G_A;     walk_bit[4] = B_A;      walk_name[4] = "A";
      walk_g[5] = 12'b1 << G_B;     walk_bit[5] = B_B;      walk_name[5] = "B";
      walk_g[6] = 12'b1 << G_X;     walk_bit[6] = B_A;      walk_name[6] = "X";
      walk_g[7] = 12'b1 << G_Y;     walk_bit[7] = B_B;      walk_name[7] = "Y";
      walk_g[8] = 12'b1 << G_SEL;   walk_bit[8] = B_SELECT; walk_name[8] = "SELECT";
      walk_g[9] = 12'b1 << G_STA;   walk_bit[9] = B_START;  walk_name[9] = "START";
      // The shoulder triggers fold onto the same two BK fire bits as the face
      // buttons: R joins A, L joins B (hook H9).
      walk_g[10] = 12'b1 << G_TL;   walk_bit[10] = B_B;     walk_name[10] = "L-trig";
      walk_g[11] = 12'b1 << G_TR;   walk_bit[11] = B_A;     walk_name[11] = "R-trig";
   end

   initial begin
      for (i = 0; i < 65536; i = i + 1) seen[i] = 1'b0;

      // ================= 1. the power-on word, BEFORE any clock edge ========
      // No reset exists, so this is purely the declaration-time initial values
      // on the sync chain and the arming flop. Checked at t=1, before the first
      // edge of either clock.
      #1;
      chk("1: power-on word is 0 before the first edge", pad_word, 16'o000000);

      // ================= 2. the type gate ===================================
      // Every input held, reports flowing, but the device is NOT a gamepad.
      // typ 2 is the one that matters - that is a mouse, and bk_mouse is
      // driving joy_word at the same time.
      g = 12'hfff;
      plug(2'd0);
      chk("2: typ=0 (nothing enumerated), all inputs held", pad_word, 16'o000000);
      plug(2'd1);
      chk("2: typ=1 (keyboard), all inputs held", pad_word, 16'o000000);
      plug(2'd2);
      chk("2: typ=2 (MOUSE), all inputs held", pad_word, 16'o000000);
      chk_act("2: typ=2 must not arm", pad_active, 1'b0);

      // ================= 3. arming: enumerated but not yet reported =========
      // typ goes to 3 with every level already high - which is exactly what a
      // hot-plug looks like, since the host never clears game_* - and the word
      // must stay 0 until a report arrives.
      @(negedge usb_clk); hid_typ = 2'd3;
      settle;
      chk("3: typ=3 but no report yet", pad_word, 16'o000000);
      chk_act("3: not armed before the first report", pad_active, 1'b0);
      report_pulse;
      settle;
      chk("3: live after the first report", pad_word, {8'h00, B_ALL});
      chk_act("3: armed after the first report", pad_active, 1'b1);

      // ================= 4. per-control walk ================================
      press(12'd0);
      chk("4: all released", pad_word, 16'o000000);
      for (i = 0; i < 12; i = i + 1) begin
         press(walk_g[i]);
         chk_walk(walk_name[i], pad_word, {8'h00, walk_bit[i]});
         press(12'd0);
         chk_walk(walk_name[i], pad_word, 16'o000000);
      end

      // ================= 5. four face buttons onto two triggers =============
      // X joins A and Y joins B. Each alone was walked above; here they are
      // held together, which is the case a swap or a dropped OR cannot survive.
      press((12'b1 << G_A) | (12'b1 << G_X));
      chk("5: A+X together are still just A", pad_word, {8'h00, B_A});
      press((12'b1 << G_B) | (12'b1 << G_Y));
      chk("5: B+Y together are still just B", pad_word, {8'h00, B_B});
      press((12'b1 << G_A) | (12'b1 << G_TR));
      chk("5: A + R-trigger are still just A", pad_word, {8'h00, B_A});
      press((12'b1 << G_B) | (12'b1 << G_TL));
      chk("5: B + L-trigger are still just B", pad_word, {8'h00, B_B});
      press((12'b1 << G_TL) | (12'b1 << G_TR));
      chk("5: both triggers reach both fire bits",
          pad_word, {8'h00, (B_A | B_B)});
      press((12'b1 << G_X) | (12'b1 << G_Y));
      chk("5: X+Y reach both triggers", pad_word, {8'h00, (B_A | B_B)});
      press((12'b1 << G_A) | (12'b1 << G_Y));
      chk("5: A+Y reach both triggers", pad_word, {8'h00, (B_A | B_B)});

      // ================= 6. diagonals, and everything at once ===============
      press((12'b1 << G_UP) | (12'b1 << G_RIGHT));
      chk("6: up-right", pad_word, {8'h00, (B_UP | B_RIGHT)});
      press((12'b1 << G_DOWN) | (12'b1 << G_LEFT));
      chk("6: down-left", pad_word, {8'h00, (B_DOWN | B_LEFT)});
      press((12'b1 << G_UP) | (12'b1 << G_LEFT));
      chk("6: up-left", pad_word, {8'h00, (B_UP | B_LEFT)});
      press((12'b1 << G_DOWN) | (12'b1 << G_RIGHT));
      chk("6: down-right", pad_word, {8'h00, (B_DOWN | B_RIGHT)});
      press((12'b1 << G_DOWN) | (12'b1 << G_LEFT) | (12'b1 << G_STA));
      chk("6: down-left + START", pad_word, {8'h00, (B_DOWN | B_LEFT | B_START)});

      // A USB pad reaches all eight bits, which is the whole gain over DE-9:
      // bk_joystick can only ever produce 0o157.
      press(12'hfff);
      chk("6: everything held reaches all eight bits", pad_word, {8'h00, B_ALL});
      if ((pad_word[7:0] & (B_START | B_SELECT)) !== (B_START | B_SELECT)) begin
         $display("PAD-ERROR 6: START/SELECT not reachable (%06o)", pad_word);
         errors = errors + 1;
      end

      // ================= 7. unplug, and the stale re-plug ===================
      // The host clears typ on disconnect and leaves game_* alone, so `g` stays
      // all-high across this whole section on purpose.
      unplug;
      chk("7: unplug clears the word", pad_word, 16'o000000);
      chk_act("7: unplug disarms", pad_active, 1'b0);

      @(negedge usb_clk); hid_typ = 2'd3;
      settle;
      chk("7: re-plug does NOT resurrect the stale levels", pad_word, 16'o000000);
      chk_act("7: re-plug is unarmed until a report", pad_active, 1'b0);
      report_pulse;
      settle;
      chk("7: live again after a report", pad_word, {8'h00, B_ALL});

      // A mouse plugged in after a pad must also disarm, not inherit it.
      plug(2'd2);
      chk("7: pad -> mouse hands the word over cleanly", pad_word, 16'o000000);
      plug(2'd3);
      chk("7: mouse -> pad comes back", pad_word, {8'h00, B_ALL});

      // ================= 7b. levels alone do nothing ========================
      // The payload is LATCHED AT THE REPORT PULSE. game_* are levels only
      // BETWEEN reports; while one is arriving the wrapper rewrites them byte
      // by byte over ~43 us, so a module that sampled them freely would show
      // the BK half-decoded frames. Moving every input with no report must
      // therefore change nothing at all.
      press(12'd0);
      chk("7b: settled at zero", pad_word, 16'o000000);
      g = 12'hfff;
      settle; settle;
      chk("7b: inputs moved with NO report - word unchanged",
          pad_word, 16'o000000);
      g = (12'b1 << G_UP) | (12'b1 << G_B);
      settle; settle;
      chk("7b: inputs moved AGAIN with no report - still unchanged",
          pad_word, 16'o000000);
      press(12'd0);

      // ================= 7c. corruption is NOT this module's job ============
      // A two-frame agreement filter lived here after the first board run. It
      // was the wrong layer: the fault proved DATA-DEPENDENT, so consecutive
      // frames agreed on the same wrong value and it only thinned the symptom.
      // Corrupt packets are now rejected at the source by hook H7's CRC16 check
      // in usb_hid_host.v, and sim/usb's `crc` leg owns that contract - it
      // asserts that a damaged frame produces NO report pulse and that the
      // consumer view never sees it. What is left here is section 7b: because
      // H7 gates the pulse and not the decode, latching at the pulse is what
      // makes a corrupt frame invisible, so 7b is load-bearing, not tidiness.

      // ================= 8. the synchroniser depth ==========================
      // Owned by the continuous monitor above, which asserts pad_word ==
      // pl_hold delayed two clk posedges on EVERY edge of the run. Nothing to
      // do here but require that the monitor was not vacuous - that the run
      // actually moved the payload enough times to have caught a wrong depth.
      // One flop, or a combinational bypass, breaks it on the first move.
      if (depth_moves < 12) begin
         $display("PAD-ERROR depth monitor vacuous: only %0d payload moves",
                  depth_moves);
         errors = errors + 1;
      end

      // ================= 9. anti-vacuity ====================================
      settle;
      if (distinct < 16) begin
         $display("PAD-ERROR only %0d distinct words seen", distinct);
         errors = errors + 1;
      end

      $display("PADDEV: %0d distinct words, all-held = %06o",
               distinct, {8'h00, B_ALL});

      if (errors == 0) $display("COSIM PASS");
      else             $display("COSIM FAIL (%0d errors)", errors);
      $finish;
   end

endmodule
