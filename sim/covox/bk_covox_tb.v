// ============================================================================
//  bk_covox_tb - the Covox device contract on the 177714 seam
// ----------------------------------------------------------------------------
//  Drives port_wr/port_data exactly as qbus_mem's capture produces them -
//  BK-TRUE polarity, one strobe per bus write, and above all THE LANE THAT WAS
//  NOT WRITTEN LEFT AT ITS PREVIOUS VALUE, which is the one place this device
//  deliberately departs from BkEmu (see bk_covox.sv's header). The tasks below
//  model that latch behaviour rather than the device's expectation of it, so
//  the lane-hold section has real teeth.
//
//  TWO INSTANCES, and the split matters:
//
//    dut      - the one every functional section drives, built with SMALL
//               one-shot parameters (2^6 and 2^8 sys_clk) so the mute and idle
//               BEHAVIOUR - expiry, retrigger, hold - can actually be
//               simulated. The measured periods are checked against those
//               overrides, so a mutation of the counter logic is caught here.
//
//    dut_def  - inputs tied off, never driven. It exists so the SHIPPED
//               parameter defaults can be asserted: 2^22 = 43 ms and 2^26 =
//               694 ms at 96.65 MHz are not simulable, so the RATE is pinned
//               as a parameter value while the BEHAVIOUR is pinned on `dut`.
//               Between them a mutation of either the default or the logic
//               dies. Saying this out loud rather than quietly dropping the
//               rate check is the sim/ts precedent.
//
//  THE SHARPEST SECTION IS THE FIRST ONE. qbus_mem's 177714 latch has NO reset
//  (a real Covox is a passive DAC on the port latch with no reset pin), so at
//  power-on it reads 0 - which INVERTS to b = 255 = +32767, full positive
//  scale, on both channels. Section 1 asserts both halves of that: the sample
//  really is at full scale, AND cx_en is low so the mixer contributes exactly
//  zero. Without the idle one-shot the board would sit on a full-scale DC on
//  both ladders from power-on.
//
//  SECTION 10 IS THE OTHER ONE, and it is a HARDWARE-FOUND REGRESSION. Arming
//  on any write is not enough: MONITOR's system-init routine ends with a lone
//  CLR @#177714 (d1.mac:270), which is a single write of the one value that
//  inverts to FULL POSITIVE SCALE on both lanes, and it runs at boot and again
//  on every return from a user program. The board clicked several times per
//  boot. So `live` now takes a write that CHANGES the code, inside a one-shot
//  that is already running - "the port is being modulated", not "the port was
//  written" - and section 10 walks the exact MONITOR sequence. The tasks below
//  therefore split into wr_* (one bus write) and arm_word (a two-write burst
//  that leaves the DAC on a chosen code and the slot live).
//
//  The device carries no scaling: it emits BkEmu's own +/-32767 map and the
//  headroom is one SLOT_GAIN nibble in bk_audio, where bk_audio_tb pins it.
//  So there is no gain arithmetic to check here - only the map itself.
// ============================================================================
`timescale 1ns/1ps

module bk_covox_tb;

   // The SHIPPED defaults, asserted against dut_def below. Deliberately not
   // passed to any instance - a tb that echoes back what it was given pins
   // nothing (the CE_DIV_EXPECT idiom from bk_turbosound_tb).
   localparam integer IDLE_BITS_SHIPPED = 22;    // ~43 ms  at 96.65 MHz
   localparam integer PSG_BITS_SHIPPED  = 26;    // ~694 ms at 96.65 MHz

   // The simulable overrides used by `dut`. NOTE the deliberate inversion of
   // the shipped ordering: here the IDLE one-shot is made LONGER than the PSG
   // hold, so one write keeps the device `live` right through a hold
   // measurement and the two counters can be measured independently. On the
   // board the ordering is the other way round; nothing in the logic cares.
   localparam integer IDLE_BITS_TB = 10;         // live for 1023 cycles
   localparam integer PSG_BITS_TB  = 8;          // mute held for  255 cycles
   localparam integer IDLE_LEN     = (1 << IDLE_BITS_TB) - 1;
   localparam integer PSG_LEN      = (1 << PSG_BITS_TB)  - 1;

   reg         sys_clk   = 1'b0;
   reg         rst_n     = 1'b0;
   reg         init_n    = 1'b1;
   reg         port_wr   = 1'b0;
   reg  [15:0] port_data = 16'h0000;             // the true power-on latch value
   reg         mono      = 1'b0;
   reg         psg_act   = 1'b0;

   wire signed [15:0] cx_l, cx_r;
   wire               cx_en;

   integer errors = 0;

   always #5 sys_clk = ~sys_clk;

   bk_covox #(
      .IDLE_BITS (IDLE_BITS_TB),
      .PSG_BITS  (PSG_BITS_TB)
   ) dut (
      .sys_clk   (sys_clk),
      .rst_n     (rst_n),
      .init_n    (init_n),
      .port_wr   (port_wr),
      .port_data (port_data),
      .mono      (mono),
      .psg_act   (psg_act),
      .cx_l      (cx_l),
      .cx_r      (cx_r),
      .cx_en     (cx_en)
   );

   // Defaults only - never driven, never checked functionally.
   wire signed [15:0] def_l, def_r;
   wire               def_en;
   bk_covox dut_def (
      .sys_clk   (sys_clk),
      .rst_n     (1'b1),
      .init_n    (1'b1),
      .port_wr   (1'b0),
      .port_data (16'h0000),
      .mono      (1'b0),
      .psg_act   (1'b0),
      .cx_l      (def_l),
      .cx_r      (def_r),
      .cx_en     (def_en)
   );

   // ---- watchdogs: run for the WHOLE simulation ---------------------------
   integer peak_l = -100000, peak_r = -100000;
   integer min_l  =  100000, min_r  =  100000;
   integer distinct_l = 0, stereo_seen = 0;
   integer mutes = 0, unmutes = 0;
   reg     seen_val [0:65535];
   reg     en_d = 1'b0;
   integer i;

   always @(posedge sys_clk) if (rst_n) begin
      if (cx_l > peak_l) peak_l = cx_l;
      if (cx_r > peak_r) peak_r = cx_r;
      if (cx_l < min_l)  min_l  = cx_l;
      if (cx_r < min_r)  min_r  = cx_r;
      if (!seen_val[cx_l[15:0]]) begin
         seen_val[cx_l[15:0]] = 1'b1;
         distinct_l = distinct_l + 1;
      end
      if (cx_l !== cx_r) stereo_seen = stereo_seen + 1;
      en_d <= cx_en;
      if ( en_d && !cx_en) mutes   = mutes   + 1;
      if (!en_d &&  cx_en) unmutes = unmutes + 1;
   end

   // ---- bus-write tasks ----------------------------------------------------
   // The port inverts, so these take the value the DAC should SEE and present
   // its complement, which is what a program writing 0177714 puts on the bus.
   // Note each task touches only the lane its bus cycle touches - that is the
   // real latch, and section 3 depends on it.
   task pulse_wr;
      begin
         @(negedge sys_clk); port_wr = 1'b1;
         @(negedge sys_clk); port_wr = 1'b0;
         repeat (2) @(negedge sys_clk);          // let the output register load
      end
   endtask

   task wr_word(input [7:0] l, input [7:0] r);   // MOV  -> both lanes
      begin port_data = {~r, ~l}; pulse_wr; end
   endtask

   task wr_even(input [7:0] l);                  // MOVB 0177714 -> low lane
      begin port_data[7:0] = ~l; pulse_wr; end
   endtask

   task wr_odd(input [7:0] r);                   // MOVB 0177715 -> high lane
      begin port_data[15:8] = ~r; pulse_wr; end
   endtask

   // Arm the slot and land on {l,r}. Two writes: the first opens the one-shot,
   // the second CHANGES the code inside it, which is what `live` now takes.
   // Written as l ^ 1 rather than a fixed priming value so the caller's
   // chosen code is what the DAC ends up on.
   task arm_word(input [7:0] l, input [7:0] r);
      begin
         wr_word(l ^ 8'h01, r);
         wr_word(l, r);
      end
   endtask

   task settle; repeat (4) @(posedge sys_clk); endtask

   task chk(input [255:0] what, input integer got, input integer exp);
      begin
         if (got !== exp) begin
            $display("CX-ERROR %0s: got %0d expected %0d", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   task chk_b(input [255:0] what, input got, input exp);
      begin
         if (got !== exp) begin
            $display("CX-ERROR %0s: got %b expected %b", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   // BkEmu's toPcmSampleValue, as an integer: ((b-128)<<8)|b == 257*b - 32768.
   function integer pcm(input integer b);
      pcm = 257*b - 32768;
   endfunction

   integer t0, span;

   initial begin
      for (i = 0; i < 65536; i = i + 1) seen_val[i] = 1'b0;

      // ================= 0. the shipped parameter defaults =================
      chk("shipped IDLE_BITS default", dut_def.IDLE_BITS, IDLE_BITS_SHIPPED);
      chk("shipped PSG_BITS default",  dut_def.PSG_BITS,  PSG_BITS_SHIPPED);

      // ================= 1. reset and the power-on latch ===================
      // The sample and counter registers take a SYNCHRONOUS reset (Cyclone
      // FFs power up to 0 anyway), so clock a few edges with rst_n low before
      // reading the reset state.
      repeat (4) @(negedge sys_clk);
      chk("reset cx_l",   cx_l,  0);
      chk("reset cx_r",   cx_r,  0);
      chk_b("reset cx_en", cx_en, 1'b0);

      rst_n = 1'b1;
      settle;

      // qbus_mem's latch has no reset, so port_data = 0 => b = 255 on BOTH
      // lanes => full positive scale. This is not a hypothetical: it is the
      // board's rest state, and it is exactly what the idle one-shot exists
      // to keep off the ladders.
      chk("power-on latch presents full scale on L", cx_l, pcm(255));
      chk("power-on latch presents full scale on R", cx_r, pcm(255));

      // ... and with no write ever seen, the slot must stay disabled, for
      // longer than the one-shot could possibly run.
      repeat (3*IDLE_LEN) @(posedge sys_clk);
      chk_b("no write yet => muted", cx_en, 1'b0);

      // ================= 2. the inversion and the byte map =================
      // Word writes with DIFFERENT lanes: this section pins the map on both
      // channels and supplies the stereo anti-vacuity evidence at once.
      wr_word(8'd0,   8'd255); settle;
      chk("b=0   left  (pins the inversion)", cx_l, pcm(0));
      chk("b=255 right",                      cx_r, pcm(255));
      wr_word(8'd255, 8'd0);   settle;
      chk("b=255 left",                       cx_l, pcm(255));
      chk("b=0   right",                      cx_r, pcm(0));
      wr_word(8'd128, 8'd127); settle;
      chk("b=128 left  (pins the -32768 offset)", cx_l, pcm(128));
      chk("b=127 right",                          cx_r, pcm(127));
      wr_word(8'd1,   8'd254); settle;
      chk("b=1   left",  cx_l, pcm(1));
      chk("b=254 right", cx_r, pcm(254));
      wr_word(8'd64,  8'd192); settle;
      chk("b=64  left",  cx_l, pcm(64));
      chk("b=192 right", cx_r, pcm(192));
      wr_word(8'd129, 8'd63);  settle;
      chk("b=129 left",  cx_l, pcm(129));
      chk("b=63  right", cx_r, pcm(63));

      // ================= 3. per-lane hold, not BkEmu's zero-fill ===========
      wr_word(8'h10, 8'hE0); settle;
      chk("word write sets left",  cx_l, pcm(8'h10));
      chk("word write sets right", cx_r, pcm(8'hE0));

      // An EVEN byte write moves the left lane only. BkEmu would pass the
      // high lane as 0, which inverts to 255 - so a build reproducing that
      // artifact reads +32767 here instead of holding 0xE0.
      wr_even(8'h40); settle;
      chk("even byte moves left",              cx_l, pcm(8'h40));
      chk("even byte HOLDS right (not 0xFF)",  cx_r, pcm(8'hE0));

      // The mirror: an ODD byte (0177715) moves the right lane only.
      wr_odd(8'h33); settle;
      chk("odd byte moves right",              cx_r, pcm(8'h33));
      chk("odd byte HOLDS left (not 0xFF)",    cx_l, pcm(8'h40));

      // ================= 4. the mono fold ==================================
      mono = 1'b1;
      wr_word(8'h20, 8'hC0); settle;
      chk("mono: right takes the LEFT lane", cx_r, pcm(8'h20));
      chk("mono: left unaffected",           cx_l, pcm(8'h20));
      // An odd-byte write must be inaudible in mono: the high lane is ignored.
      wr_odd(8'h07); settle;
      chk("mono: odd byte does not reach the right channel", cx_r, pcm(8'h20));
      wr_word(8'd0, 8'd255); settle;
      chk("mono at the negative rail, left",  cx_l, pcm(0));
      chk("mono at the negative rail, right", cx_r, pcm(0));

      // ================= 5. DIP 5 is LIVE ==================================
      // No write, no reset: flipping the switch must take effect on its own.
      // (port_data still holds l = 0, r = 255 from the write above.)
      mono = 1'b0;
      settle;
      chk("DIP 5 off: right returns to its own lane", cx_r, pcm(255));
      chk("DIP 5 off: left unchanged",                cx_l, pcm(0));
      mono = 1'b1;
      settle;
      chk("DIP 5 on again: right folds back", cx_r, pcm(0));
      mono = 1'b0;
      settle;

      // ================= 6. the PSG mute ===================================
      // 6a. a live Covox is muted by the PSGs.
      arm_word(8'h90, 8'h30); settle;
      chk_b("a modulated port => live", cx_en, 1'b1);
      @(negedge sys_clk); psg_act = 1'b1;
      @(negedge sys_clk); psg_act = 1'b0;
      settle;
      chk_b("psg_act mutes", cx_en, 1'b0);

      // 6b. the mute is HELD, and for the right length. The write above keeps
      // the device live for IDLE_LEN >> PSG_LEN cycles, so the only thing that
      // can bring cx_en back is the hold expiring.
      t0 = 0;
      while (cx_en === 1'b0 && t0 < 4*PSG_LEN) begin
         @(posedge sys_clk);
         t0 = t0 + 1;
      end
      chk_b("the mute hold releases", cx_en, 1'b1);
      if (t0 < PSG_LEN/2 || t0 > 2*PSG_LEN) begin
         $display("CX-ERROR mute hold %0d cycles, expected about %0d", t0, PSG_LEN);
         errors = errors + 1;
      end

      // 6c. a PSG square wave is zero for half of every period, so psg_act
      // arrives as a train of pulses. The hold must swallow the gaps: this is
      // the section a hold-less build (mute follows psg_act) dies in.
      // NOTE the writes below are IDENTICAL and still keep the device live -
      // arming takes a change, HOLDING must not, or a sample run that repeats
      // a value would drop out mid-note.
      for (i = 0; i < 8; i = i + 1) begin
         @(negedge sys_clk); psg_act = 1'b1;
         @(negedge sys_clk); psg_act = 1'b0;
         wr_word(8'h90, 8'h30);
         repeat (PSG_LEN/4) @(posedge sys_clk);
         chk_b("mute survives the gap between psg_act pulses", cx_en, 1'b0);
      end
      // and it comes back once the PSGs really stop
      wr_word(8'h90, 8'h30);
      repeat (2*PSG_LEN) @(posedge sys_clk);
      chk_b("mute releases once the PSGs stop", cx_en, 1'b1);

      // ================= 7. the idle one-shot ==============================
      // Measure it: arm, then count until the slot goes quiet.
      arm_word(8'hA0, 8'h50);
      t0 = 0;
      while (cx_en === 1'b1 && t0 < 4*IDLE_LEN) begin
         @(posedge sys_clk);
         t0 = t0 + 1;
      end
      chk_b("the idle one-shot expires", cx_en, 1'b0);
      span = t0;
      if (span < IDLE_LEN-4 || span > IDLE_LEN+4) begin
         $display("CX-ERROR idle one-shot %0d cycles, expected %0d", span, IDLE_LEN);
         errors = errors + 1;
      end

      // RETRIGGERABLE: arm, wait most of the period, write again. The slot
      // must then stay live for another full period from the SECOND write - a
      // build that reloads only from the idle state falls silent early.
      // The retrigger write repeats the code the DAC is already on, which is
      // the point: the one-shot reload is VALUE-BLIND even though arming is
      // not, so a repeated sample can never cut a live stream short.
      arm_word(8'hA0, 8'h50);
      repeat (IDLE_LEN - IDLE_LEN/4) @(posedge sys_clk);
      chk_b("still live just before the retrigger", cx_en, 1'b1);
      wr_word(8'hA0, 8'h50);
      t0 = 0;
      while (cx_en === 1'b1 && t0 < 4*IDLE_LEN) begin
         @(posedge sys_clk);
         t0 = t0 + 1;
      end
      if (t0 < IDLE_LEN-8) begin
         $display("CX-ERROR one-shot not retriggerable: %0d cycles after the second write, expected %0d",
                  t0, IDLE_LEN);
         errors = errors + 1;
      end

      // ================= 8. nINIT resets the device ========================
      // Go in LIVE and MUTED-pending so both counters have something to clear.
      arm_word(8'h11, 8'h22);
      @(negedge sys_clk); psg_act = 1'b1;
      @(negedge sys_clk); psg_act = 1'b0;
      settle;
      chk_b("pre-nINIT: muted by the PSGs", cx_en, 1'b0);

      @(negedge sys_clk); init_n = 1'b0;
      repeat (8) @(negedge sys_clk);
      chk("nINIT clears cx_l",  cx_l,  0);
      chk("nINIT clears cx_r",  cx_r,  0);
      chk_b("nINIT clears cx_en", cx_en, 1'b0);

      init_n = 1'b1;
      settle;
      // The 177714 LATCH is deliberately not reset (a real Covox is a passive
      // DAC with no reset pin, and qbus_mem keeps it in the spk/mot class), so
      // the sample reappears the moment reset lifts - but the slot must stay
      // MUTED, because nINIT cleared the idle one-shot and no write has
      // happened since.
      chk("post-nINIT the latch is still there", cx_l, pcm(8'h11));
      chk_b("post-nINIT the slot stays muted",   cx_en, 1'b0);
      repeat (2*PSG_LEN) @(posedge sys_clk);
      chk_b("nINIT cleared the PSG hold too - still muted only by idle",
            cx_en, 1'b0);

      // A fresh BURST brings the device straight back, which is what proves
      // the hold was cleared rather than merely still running - and it takes
      // a burst, not a write: nINIT left both counters at zero, so the first
      // write only opens the window even though it does change the code.
      wr_word(8'h11, 8'h22);
      settle;
      chk_b("post-nINIT one write does not arm", cx_en, 1'b0);
      wr_word(8'h11, 8'h23);          // ...the second one, changing, arms it
      settle;
      chk_b("post-nINIT a change re-arms", cx_en, 1'b1);
      chk("post-nINIT the sample is right again",  cx_l, pcm(8'h11));
      chk("the compare sees the right lane",
          cx_r, pcm(8'h23));

      // ================= 10. the MONITOR CLR regression ====================
      // The hardware bug this rule exists for. MONITOR's system-init routine
      // MIDMBK ends with
      //
      //     CLR  @#APORT          ; APORT = 177714  (d1.mac:135,270)
      //
      // - ONE isolated write, of the one value that inverts to b = 255 on
      // BOTH lanes, i.e. full positive scale. MIDMBK runs at boot and again
      // on every return from a user program, so a build that arms on any
      // write clicks several times per boot: two -3.8 dBFS DC edges 43 ms
      // apart on both ladders, each time.

      // Start from where a finished program leaves the machine: a stream that
      // was live, then stopped.
      arm_word(8'h60, 8'hA5);
      settle;
      chk_b("10: a modulated port is live", cx_en, 1'b1);
      repeat (IDLE_LEN + 8) @(posedge sys_clk);
      chk_b("10: the stream stopped => muted", cx_en, 1'b0);

      // 10a. THE CLR itself. Both halves are checked, so the section cannot
      // pass vacuously: the sample really IS at the positive rail, and the
      // slot really IS still muted.
      wr_word(8'd255, 8'd255);              // bus value 0 = CLR @#177714
      settle;
      chk("10a: the CLR is at +full scale L", cx_l, pcm(255));
      chk("10a: the CLR is at +full scale R", cx_r, pcm(255));
      chk_b("10a: a lone CLR does not unmute", cx_en, 1'b0);
      repeat (IDLE_LEN + 8) @(posedge sys_clk);
      chk_b("10a: still muted a one-shot later", cx_en, 1'b0);

      // 10b. MIDMBK runs more than once, so a second CLR can land well inside
      // the first one's window. Two writes - but the same value, so it is
      // still not modulation.
      wr_word(8'd255, 8'd255);
      repeat (IDLE_LEN/4) @(posedge sys_clk);
      chk_b("10b: muted between the two CLRs", cx_en, 1'b0);
      wr_word(8'd255, 8'd255);
      settle;
      chk_b("10b: two CLRs do not unmute", cx_en, 1'b0);
      repeat (IDLE_LEN + 8) @(posedge sys_clk);

      // 10c. Nor does a HOLD-style burst of one repeated code, arriving on a
      // quiet port: that is a DC, and a real Covox drives an AC-COUPLED
      // amplifier that does not reproduce one. The first write changes the
      // code but only OPENS the window; the other 31 change nothing.
      for (i = 0; i < 32; i = i + 1) wr_word(8'h60, 8'h60);
      chk_b("10c: a constant-code burst is a DC", cx_en, 1'b0);

      // 10d. ...and the anti-vacuity half: one changing write inside that
      // same window, which is what a sample stream does, unmutes at once.
      wr_word(8'h61, 8'h60);
      settle;
      chk_b("10d: a changing write unmutes", cx_en, 1'b1);
      chk("10d: on the code it wrote", cx_l, pcm(8'h61));

      // ================= 9. anti-vacuity ===================================
      if (distinct_l < 12) begin
         $display("CX-ERROR only %0d distinct cx_l values seen", distinct_l);
         errors = errors + 1;
      end
      if (stereo_seen < 4) begin
         $display("CX-ERROR the channels never differed (%0d cycles)", stereo_seen);
         errors = errors + 1;
      end
      if (mutes < 2 || unmutes < 2) begin
         $display("CX-ERROR too few mute/unmute events (%0d/%0d)", mutes, unmutes);
         errors = errors + 1;
      end
      chk("both rails reached, min", min_l, -32768);
      chk("both rails reached, max", peak_l, 32767);

      $display("CXDEV: %0d distinct samples, %0d mute/%0d unmute, range %0d..%0d, idle %0d cyc",
               distinct_l, mutes, unmutes, min_l, peak_l, span);

      if (errors == 0) $display("COSIM PASS");
      else             $display("COSIM FAIL (%0d errors)", errors);
      $finish;
   end

endmodule
