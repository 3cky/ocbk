// ============================================================================
//  bk_turbosound_tb - the device contract on the 177714 seam
// ----------------------------------------------------------------------------
//  Drives qbus_mem's port_wr/port_data/port_word/port_be exactly as the real
//  capture produces them (BK-TRUE polarity, one strobe per bus write, the odd
//  lane leaving the low half STALE) and checks the whole BkEmu Ay8910
//  contract plus the mix fold.
//
//  THE OBSERVABILITY TRICK. Waiting for tones would make this leg slow and
//  its expectations fuzzy. Instead every check runs with R7 = 0x3F, i.e.
//  every tone and noise channel DISABLED - in which case the core's mixer
//  term degenerates to `~(1 & 1) = 0` and each channel emits its programmed
//  volume as a steady DC level. The register file then reads out directly on
//  CHANNEL_A/B/C within a cycle.
//
//  ONLY TWO VOLUME-TABLE ENTRIES ARE ASSUMED HERE: volume 15 -> 255 and
//  volume 0 -> 0, the endpoints. Everything else about the table is
//  ym2149_equiv_tb's job (it diffs all 64 entries against the vendored
//  reference), so this leg stays a contract test of THIS module and cannot
//  fail for a reason that belongs to the core.
//
//    volume 15 -> level {1111,1} = 31 -> volTable[31] = 8'hFF = 255
//    volume  0 -> level {0000,0} =  0 -> volTable[0]  = 8'h00 =   0
//
//  Fold expectations therefore come out in closed form, e.g. chip 0 with
//  A = 15 and B = C = 0, single-chip:  2*(2*255 + 0)*15 = 15300 on the left
//  and 0 on the right.
// ============================================================================
`timescale 1ns/1ps

module bk_turbosound_tb;

   // The EXPECTED PSG clock divisor. Deliberately NOT passed to the
   // instance below - the device is built with its own default so that a
   // mutation of that default actually changes the rate and this leg catches
   // it. A tb that echoes back whatever it was given pins nothing.
   localparam integer CE_DIV_EXPECT = 56;

   reg         sys_clk = 1'b0;
   reg         rst_n   = 1'b0;
   reg         init_n  = 1'b1;
   reg         port_wr = 1'b0;
   reg  [15:0] port_data = 16'h0000;
   reg         port_word = 1'b0;
   reg  [1:0]  port_be   = 2'b00;

   wire signed [15:0] ts_l, ts_r;
   wire               ts_act, dual_act;

   integer errors = 0;

   always #5 sys_clk = ~sys_clk;

   bk_turbosound #(.DUAL_ENABLE (1'b1)) dut (
      .sys_clk   (sys_clk),
      .rst_n     (rst_n),
      .init_n    (init_n),
      .port_wr   (port_wr),
      .port_data (port_data),
      .port_word (port_word),
      .port_be   (port_be),
      .ts_l      (ts_l),
      .ts_r      (ts_r),
      .ts_act    (ts_act),
      .dual_act  (dual_act)
   );

   // ---- headroom watchdog: runs for the WHOLE simulation ------------------
   integer peak_l = 0, peak_r = 0;
   always @(posedge sys_clk) if (rst_n) begin
      if (ts_l < 0 || ts_r < 0) begin
         $display("TS-ERROR t=%0t negative output l=%0d r=%0d", $time, ts_l, ts_r);
         errors = errors + 1;
      end
      if (ts_l > 22950 || ts_r > 22950) begin
         $display("TS-ERROR t=%0t headroom bound broken l=%0d r=%0d (max 22950)",
                  $time, ts_l, ts_r);
         errors = errors + 1;
      end
      if (ts_l > peak_l) peak_l = ts_l;
      if (ts_r > peak_r) peak_r = ts_r;
   end

   // ---- CE rate measurement ----------------------------------------------
   integer ce_gap = 0, ce_last = -1, ce_seen = 0, ce_bad = 0;
   always @(posedge sys_clk) if (rst_n) begin
      ce_gap = ce_gap + 1;
      if (dut.ce) begin
         if (ce_last >= 0 && ce_gap != CE_DIV_EXPECT) ce_bad = ce_bad + 1;
         ce_last = 1; ce_seen = ce_seen + 1; ce_gap = 0;
      end
   end

   // ---- bus-write tasks ---------------------------------------------------
   // The device inverts (v = ~port_data[7:0]), so these take the AY-LEVEL
   // value and present its BK-true complement, which is what a program
   // writing to 0177714 actually puts on the bus.
   task pulse_wr;
      begin
         @(negedge sys_clk); port_wr = 1'b1;
         @(negedge sys_clk); port_wr = 1'b0;
         repeat (4) @(negedge sys_clk);        // let the 2-stage pipe drain
      end
   endtask

   task ay_addr(input [7:0] r);                 // WORD write = address latch
      begin
         port_data = {8'h00, ~r};
         port_word = 1'b1;
         port_be   = 2'b11;
         pulse_wr;
      end
   endtask

   task ay_data(input [7:0] d);                 // EVEN byte write = data
      begin
         port_data = {8'h00, ~d};
         port_word = 1'b0;
         port_be   = 2'b01;
         pulse_wr;
      end
   endtask

   // ODD byte (0177715): qbus_mem updates only the HIGH half and leaves the
   // low half stale, and BkEmu turns that into a data write of 0xFF. The
   // stale low byte is set to something that would be a DIFFERENT value if
   // the device wrongly used it.
   task ay_data_odd(input [7:0] hi);
      begin
         port_data = {~hi, 8'h55};              // 8'h55 stale => v would be 0xAA
         port_word = 1'b0;
         port_be   = 2'b10;
         pulse_wr;
      end
   endtask

   task ay_wr(input [7:0] r, input [7:0] d);
      begin ay_addr(r); ay_data(d); end
   endtask

   // Silence everything and disable tone+noise, so channels read out volumes.
   task quiet_chip;
      begin
         ay_wr(8'd7,  8'h3F);                   // all tone + noise disabled
         ay_wr(8'd8,  8'h00);
         ay_wr(8'd9,  8'h00);
         ay_wr(8'd10, 8'h00);
      end
   endtask

   task settle; repeat (8) @(posedge sys_clk); endtask

   task chk(input [255:0] what, input integer got, input integer exp);
      begin
         if (got !== exp) begin
            $display("TS-ERROR %0s: got %0d expected %0d", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   task chk_b(input [255:0] what, input got, input exp);
      begin
         if (got !== exp) begin
            $display("TS-ERROR %0s: got %b expected %b", what, got, exp);
            errors = errors + 1;
         end
      end
   endtask

   initial begin
      repeat (4) @(negedge sys_clk);
      rst_n = 1'b1;
      settle;

      // ================= 1. reset state ===================================
      chk("reset ts_l",     ts_l,     0);
      chk("reset ts_r",     ts_r,     0);
      chk_b("reset dual_act", dual_act, 1'b0);
      chk_b("reset ts_act",   ts_act,   1'b0);

      // ================= 2. the basic protocol ============================
      // Word write selects a register, even-byte write supplies the data.
      quiet_chip;
      settle;
      chk("quiet chip ts_l", ts_l, 0);
      chk("quiet chip ts_r", ts_r, 0);
      chk_b("R7=3F => ts_act low", ts_act, 1'b0);

      // chip 0: A at full volume, B and C silent.
      //   lc0 = 2*255 + 0 = 510, rc0 = 0
      //   single chip => lsum = 1020, ts_l = 1020*15 = 15300, ts_r = 0
      ay_wr(8'd8, 8'h0F);
      settle;
      chk("A=15 single-chip ts_l", ts_l, 15300);
      chk("A=15 single-chip ts_r", ts_r, 0);

      // C at full volume too: rc0 = 510 => ts_r = 15300
      ay_wr(8'd10, 8'h0F);
      settle;
      chk("C=15 ts_r", ts_r, 15300);
      chk("C=15 leaves ts_l", ts_l, 15300);

      // B is the CENTRE channel: it must appear on BOTH sides.
      //   lc0 = rc0 = 2*255 + 255 = 765 => lsum = rsum = 1530 => 22950
      ay_wr(8'd9, 8'h0F);
      settle;
      chk("B=15 ts_l (ACB centre)", ts_l, 22950);
      chk("B=15 ts_r (ACB centre)", ts_r, 22950);
      chk("headroom peak_l", peak_l, 22950);
      chk("headroom peak_r", peak_r, 22950);

      // ================= 3. the odd-byte lane =============================
      // 0177715 must write 0xFF, NOT the stale low half (which would be 0xAA).
      // Register 8 takes the low 5 bits: 0xFF -> volume select bit 4 set =
      // envelope-driven; 0xAA -> bit 4 set too. Use register 9 read-back via
      // the channel instead: point at R9 and write odd. 0xFF sets R9[4] (env)
      // while 0xAA also would - so use a register where the two differ:
      // R7. 0xFF = everything disabled, 0xAA = tone B/noise A,C enabled.
      ay_wr(8'd8, 8'h00); ay_wr(8'd9, 8'h00); ay_wr(8'd10, 8'h00);
      ay_addr(8'd7);
      ay_data_odd(8'h00);                       // value irrelevant: must be 0xFF
      settle;
      chk_b("odd-byte wrote 0xFF to R7 (all disabled)", ts_act, 1'b0);
      // prove the leg has teeth: 0xAA into R7 WOULD light ts_act
      ay_wr(8'd7, 8'hAA);
      settle;
      chk_b("control: R7=0xAA lights ts_act", ts_act, 1'b1);
      ay_wr(8'd7, 8'h3F);
      settle;

      // ================= 3b. the 4-bit address mask =======================
      // BkEmu does `currentRegister = v & 0x0f`, so 0x59 selects register 9.
      // Silicon would latch all eight bits and then IGNORE the following data
      // write, because the core's own guard is `else if(!addr[7:4])`. This is
      // a real divergence and BkEmu wins; without the mask the write below
      // vanishes and ts stays at 0.
      ay_wr(8'd8, 8'h00); ay_wr(8'd9, 8'h00); ay_wr(8'd10, 8'h00);
      settle;
      chk("mask setup silent", ts_l, 0);
      ay_addr(8'h59);                           // masked => register 9
      ay_data(8'h0F);
      settle;
      // B is centre: lc0 = rc0 = 255 => lsum = rsum = 510 => 7650
      chk("0x59 masked to register 9, ts_l", ts_l, 7650);
      chk("0x59 masked to register 9, ts_r", ts_r, 7650);
      ay_wr(8'd9, 8'h00);
      settle;

      // ================= 4. chip select and Turbosound activation =========
      // Before any 0xFE the secondary is inert and dual_act is low.
      chk_b("no 0xFE yet => dual_act low", dual_act, 1'b0);

      // Set chip 0 to A=15 only: ts_l = 15300, ts_r = 0.
      ay_wr(8'd8, 8'h0F); ay_wr(8'd9, 8'h00); ay_wr(8'd10, 8'h00);
      settle;
      chk("chip0 A=15 before activation ts_l", ts_l, 15300);

      // Activate Turbosound. BkEmu averages the two chips from here on, so
      // chip 0 alone now reads HALF: lsum = lc0 = 510 => 7650.
      ay_addr(8'hFE);
      settle;
      chk_b("0xFE sets dual_act", dual_act, 1'b1);
      chk("activation halves chip0 ts_l (BkEmu averaging)", ts_l, 7650);

      // The secondary came out of its activation reset silent (R7 = 0xFF).
      chk("secondary silent at activation ts_r", ts_r, 0);

      // Program the SECONDARY: C at full volume => rc1 = 510 => ts_r = 7650.
      quiet_chip;                                // goes to chip 1 now
      ay_wr(8'd10, 8'h0F);
      settle;
      chk("secondary C=15 ts_r", ts_r, 7650);
      chk("secondary write left chip0 ts_l alone", ts_l, 7650);

      // ================= 5. 0xFF returns to the primary ===================
      ay_addr(8'hFF);
      settle;
      chk_b("0xFF keeps dual_act set", dual_act, 1'b1);
      // A data write now hits chip 0. Silence its A: ts_l -> 0, ts_r stays.
      ay_wr(8'd8, 8'h00);
      settle;
      chk("0xFF steered the write to chip0", ts_l, 0);
      chk("... and left chip1 alone",        ts_r, 7650);

      // ================= 6. the shared register pointer ===================
      // A word write broadcasts the address to BOTH chips, so after one
      // address write a byte write lands in the same register whichever chip
      // is selected. Put B=15 in both and check the centre channel sums.
      ay_addr(8'd9);
      ay_data(8'h0F);                            // -> chip 0 (selected)
      ay_addr(8'hFE);
      ay_addr(8'd9);
      ay_data(8'h0F);                            // -> chip 1
      settle;
      //   chip0: A=0 B=15 C=0 -> lc0 = rc0 = 255
      //   chip1: A=0 B=15 C=15 -> lc1 = 255, rc1 = 2*255+255 = 765
      //   lsum = 510  -> 7650 ; rsum = 1020 -> 15300
      chk("shared pointer, both B=15, ts_l", ts_l, 7650);
      chk("shared pointer, both B=15, ts_r", ts_r, 15300);

      // ================= 6b. a chip select CLOBBERS the pointer ===========
      // BkEmu runs `currentRegister = v & 0x0f` BEFORE it looks for the
      // Turbosound escapes, so 0xFF and 0xFE leave the pointer at 15 and 14
      // as a side effect. A program must re-select a register after switching
      // chips - which is also why the RTL's address broadcast cannot be
      // observed (see the D11 note in run.sh): every route back to the
      // primary goes through a 0xFF that rewrites the pointer anyway.
      ay_addr(8'hFF);
      quiet_chip;
      ay_addr(8'hFE);
      quiet_chip;
      ay_addr(8'hFF);
      quiet_chip;
      settle;
      chk("clobber setup silent", ts_l, 0);

      ay_addr(8'd8);                             // pointer := 8 (volume A)
      ay_addr(8'hFF);                            // ... clobbered to 15 (IOB)
      ay_data(8'h0F);
      settle;
      chk("a chip select clobbers the pointer, so no volume was written",
          ts_l, 0);

      ay_addr(8'd8);                             // control: pointer intact
      ay_data(8'h0F);
      settle;
      // Turbosound is engaged by now, so this is the AVERAGED scale:
      // lsum = lc0 + lc1 = 510 + 0 => 7650, not the single-chip 15300.
      chk("control: volume A written after a real address select", ts_l, 7650);
      ay_wr(8'd8, 8'h00);
      settle;

      // ================= 7. full-scale headroom, both chips ===============
      ay_addr(8'hFE);
      ay_wr(8'd8, 8'h0F); ay_wr(8'd9, 8'h0F); ay_wr(8'd10, 8'h0F);
      ay_addr(8'hFF);
      ay_wr(8'd8, 8'h0F); ay_wr(8'd9, 8'h0F); ay_wr(8'd10, 8'h0F);
      settle;
      chk("both chips full scale ts_l", ts_l, 22950);
      chk("both chips full scale ts_r", ts_r, 22950);

      // ================= 8. nINIT resets the device =======================
      @(negedge sys_clk); init_n = 1'b0;
      repeat (8) @(negedge sys_clk);
      init_n = 1'b1;
      settle;
      chk("nINIT clears ts_l",       ts_l,     0);
      chk("nINIT clears ts_r",       ts_r,     0);
      chk_b("nINIT clears dual_act", dual_act, 1'b0);
      chk_b("nINIT clears ts_act",   ts_act,   1'b0);

      // The chips were really RESET, not merely muted: they were at full
      // scale (22950/22950) going in and read 0 coming out, which can only
      // happen if the volume registers cleared. R7 reset to 0xFF = every
      // tone and noise channel disabled, which in this core means each
      // channel sits at DC on its programmed volume - so writing a volume
      // now must produce output again, on the PRIMARY (dual_act cleared too).
      ay_addr(8'd8);
      ay_data(8'h0F);
      settle;
      chk_b("post-nINIT R7=0xFF => ACTIVE low", ts_act, 1'b0);
      chk("post-nINIT write lands on the primary at single-chip scale",
          ts_l, 15300);

      // ================= 9. the CE rate ===================================
      // Everything above runs at DC, so the run is only ~500 clocks long -
      // far too short to measure a /56 enable. Give it a window.
      repeat (6000) @(posedge sys_clk);
      if (ce_seen < 100) begin
         $display("TS-ERROR CE never ran (%0d pulses)", ce_seen);
         errors = errors + 1;
      end
      if (ce_bad != 0) begin
         $display("TS-ERROR CE gap wrong on %0d of %0d pulses (expected /%0d)",
                  ce_bad, ce_seen, CE_DIV_EXPECT);
         errors = errors + 1;
      end

      $display("TSDEV: %0d CE pulses at /%0d, peak l/r = %0d/%0d",
               ce_seen, CE_DIV_EXPECT, peak_l, peak_r);

      if (errors == 0) $display("COSIM PASS");
      else             $display("COSIM FAIL (%0d errors)", errors);
      $finish;
   end

endmodule
