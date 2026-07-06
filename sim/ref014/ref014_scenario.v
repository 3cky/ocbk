//
// Shared contract scenario for the 1801VP1-014 keyboard controller oracle.
//
// Included (`include) by BOTH ref014_tb.v (the vendored gate netlist -- the
// ground truth that generates golden_014.txt) and ref014_beh_tb.v (the
// synthesizable src/bk_kbd014.sv). Each testbench implements the t_* tasks
// with IDENTICAL $display formats; the two outputs must diff-match the same
// committed golden. The log is transaction-granular on purpose: the netlist
// is asynchronous (RC debounce, no clock), so only the bus-visible contract
// is comparable -- never timestamps. t_irq doubles as the settle point after
// events with an asynchronous latency (the queued-press re-delivery).
//
// Key map (from the vendored tb_014.v matrix scan, all modifier pins
// inactive): K1..K6,K8 = matrix col 6 rows 1..7 = codes 0141..0147 (K6 is
// pressed with the АР2/EC2 pin held -> vector 0274), K7 = matrix (row 3,
// col 1) = code 0013, an "autoar2" key (vector 0274 regardless of EC2).
//
// The netlist-pinned contract this scenario freezes (probe evidence in the
// phase comments):
//  - the code register re-latches on EVERY press debounce, ready or not;
//  - a press finding ready CLEAR delivers: ready=1 + request trigger=1
//    (the trigger sets even when masked -- IEN gates only the pin);
//  - a press finding ready SET is queued: when a 662 read clears ready and
//    that key is STILL HELD, the chip re-delivers (ready + trigger again,
//    same code); releasing the key first cancels the queued delivery;
//  - reading 662 returns {v274, code} and clears ready AND a pending
//    (un-IAK'd) request trigger;
//  - the IAK cycle clears the trigger only, ready survives;
//  - INIT clears ready/trigger and re-sets the mask, the code register is
//    NOT cleared (stale code readable after INIT).
//
task scenario;
begin
   // ---- cold state -------------------------------------------------------
   t_init;              // release the cold INIT
   t_irq;               // no request pending
   t_rd(8'o260);        // cold CSR: VIRQ mask bit set
   t_rd_nocs(8'o260);   // nCS high at SYNC fall -> chip must not reply
   t_wr(8'o260, 8'o000);// unmask VIRQ
   t_rd(8'o260);

   // ---- phase 1: basic press -> VIRQ -> IAK vector -> read clears --------
   t_press(1);          // expect IRQ=1
   t_rd(8'o260);        // ready set
   t_iak;               // vector 060
   t_irq;               // request cleared by the IAK cycle
   t_rd(8'o260);        // ready survives the IAK
   t_rd(8'o262);        // code K1; the read clears ready
   t_irq;               // settle: K1 is held but was delivered -> no re-fire
   t_rd(8'o260);
   t_release(1);

   // ---- phase 2: press while ready still set -> queued, re-delivers ------
   t_press(2);
   t_iak;               // vector 060; ready stays set (662 never read)
   t_release(2);
   t_press(3);          // ready set from K2: code re-latches, no request
   t_irq;
   t_rd(8'o262);        // K3's code; clears ready, then K3 (still held)
   t_irq;               //   re-delivers: request fires again
   t_rd(8'o260);        // ready re-set by the re-delivery
   t_release(3);
   t_iak;               // collect the re-delivered request
   t_rd(8'o262);        // same code again, clears ready for good
   t_rd(8'o260);
   t_irq;

   // ---- phase 2b: queued press RELEASED before the read -> cancelled -----
   t_press(2);
   t_iak;
   t_release(2);
   t_press(3);          // queued (ready still set)
   t_release(3);        // released before any read
   t_rd(8'o262);        // K3's code (register re-latched anyway)
   t_irq;               // no re-delivery: the key is up
   t_rd(8'o260);
   t_iak;               // nothing pending -> TIMEOUT

   // ---- phase 2c: queue behind an un-IAK'd request ------------------------
   t_press(2);          // delivers (ready+trigger)
   t_release(2);
   t_press(3);          // queued; trigger still pending from K2
   t_irq;
   t_rd(8'o262);        // K3's code (K2's overwritten); clears ready+trigger,
   t_irq;               //   then held K3 re-delivers
   t_rd(8'o260);
   t_iak;               // K3's re-delivered request
   t_release(3);
   t_rd(8'o262);        // drain
   t_rd(8'o260);
   t_irq;

   // ---- phase 3: masked press, then unmask (retro-fire) ------------------
   t_wr(8'o260, 8'o100);// mask VIRQ
   t_press(4);          // IRQ=0: the pin is gated...
   t_rd(8'o260);        // ...but ready sets
   t_wr(8'o260, 8'o000);// unmask with the trigger already latched
   t_irq;               // retro-fire: the pin asserts now
   t_iak;               // vector 060
   t_rd(8'o262);        // code K4, clears ready
   t_irq;               // delivered press: no re-fire while held
   t_release(4);
   t_iak;               // drain: TIMEOUT
   t_rd(8'o260);
   t_irq;

   // ---- phase 3b: IAK while the trigger is set but masked -----------------
   t_wr(8'o260, 8'o100);
   t_press(5);          // trigger sets, pin quiet
   t_iak;               // does the IAK responder see a masked trigger?
   t_rd(8'o262);        // drain the code, clears ready+trigger
   t_release(5);
   t_wr(8'o260, 8'o000);
   t_irq;
   t_iak;               // drain: TIMEOUT unless the masked IAK left state

   // ---- phase 4: read 662 BEFORE the IAK (pending-request clear) ---------
   t_press(5);
   t_rd(8'o262);        // code K5; clears ready AND the pending trigger
   t_irq;
   t_iak;               // TIMEOUT: nothing pending anymore
   t_rd(8'o260);
   t_release(5);

   // ---- phase 5: АР2 modifier (EC2 pin) -> vector 0274 -------------------
   t_ec2(1);
   t_press(6);
   t_iak;               // vector 274
   t_rd(8'o262);        // bit7 (АР2 flag) in the data register?
   t_rd(8'o260);
   t_release(6);
   t_ec2(0);

   // ---- phase 5b: АР2 press, 662 read BEFORE the IAK ----------------------
   t_ec2(1);
   t_press(6);
   t_rd(8'o262);        // is bit7 (АР2) ever visible in the data register?
   t_irq;
   t_iak;               // trigger already cleared by the read -> TIMEOUT
   t_release(6);
   t_ec2(0);

   // ---- phase 6: autoar2 key -> vector 0274 without EC2 ------------------
   t_press(7);
   t_iak;               // vector 274
   t_rd(8'o262);        // bit7 for an autoar2 code?
   t_release(7);

   // ---- phase 6b: autoar2 key, 662 read BEFORE the IAK --------------------
   t_press(7);
   t_rd(8'o262);
   t_irq;
   t_iak;               // TIMEOUT
   t_release(7);

   // ---- phase 7: DATIO read-modify-write on the CSR (BIS/BIC shape) ------
   t_rmw(8'o260, 8'o100);  // one SYNC: DIN then DOUT (mask set)
   t_rd(8'o260);
   t_rmw(8'o260, 8'o000);  // unmask back the same way
   t_rd(8'o260);

   // ---- phase 8: write to the data register ------------------------------
   t_wr(8'o262, 8'o125);   // the 014 does NOT reply: bus timeout
   t_rd(8'o262);           // stale code, unchanged

   // ---- phase 9: nCS is latched at SYNC fall ------------------------------
   t_rd_cslatch(8'o260);   // nCS released right after SYNC fall: must reply

   // ---- phase 10: INIT with a request pending -----------------------------
   t_press(8);
   t_release(8);        // key released, request still pending (no IAK/read)
   t_irq;
   t_init;
   t_irq;               // cleared by INIT
   t_rd(8'o260);        // mask back to the cold value
   t_rd(8'o262);        // the code register is NOT cleared by INIT
   t_iak;               // nothing pending -> TIMEOUT
   t_rd(8'o260);
end
endtask
