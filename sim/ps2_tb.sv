// Phase-6 PS/2 front-end unit cosim: ps2_rx + kbd_ps2bk against a
// hand-written expected event list (run_ps2.sh, part of make sim).
//
// A synthetic ~12 kHz PS/2 device sends scan-code frames (including a
// parity-corrupted one and an abandoned half-frame) and the checker
// verifies every translator event: the BkEmu case algebra over the
// ЛАТ/РУС × ЗАГЛ/СТР × НР matrix, СУ masking, АР2 + autoar2 flags, the
// РУС/ЛАТ shadow updates, CapsLock toggling, typematic suppression,
// multi-key key_down, and СТОП (Delete) strobes. Prints PS2-ERROR lines
// and a final verdict; run_ps2.sh greps for COSIM PASS.
`timescale 1ns / 1ps

module ps2_tb;

    // cpu_clk ~3.02 MHz
    logic clk = 0;
    always #165 clk = ~clk;

    // PS/2 device model
    logic ps2c = 1'b1;
    logic ps2d = 1'b1;

    logic [7:0] rx_byte;
    logic       rx_stb;
    logic       key_stb, key_ar2, key_down, key_stop;
    logic [6:0] key_code;

    ps2_rx u_rx (
        .clk(clk), .ps2_clk_i(ps2c), .ps2_dat_i(ps2d),
        .byte_o(rx_byte), .stb_o(rx_stb)
    );

    kbd_ps2bk u_tr (
        .clk(clk), .ps2_byte(rx_byte), .ps2_stb(rx_stb),
        .key_stb(key_stb), .key_code(key_code), .key_ar2(key_ar2),
        .key_down(key_down), .key_stop(key_stop)
    );

    // ---- device-side frame sender (~16 kHz clock, data before fall) --------
    localparam int PS2_HALF = 25_000;   // 25 us half period

    task send_bit (input b);
    begin
        ps2d = b;
        #(PS2_HALF/2);
        ps2c = 0;                        // receiver samples here
        #(PS2_HALF);
        ps2c = 1;
        #(PS2_HALF/2);
    end
    endtask

    task send_frame (input [7:0] b, input good_parity);
    begin
        send_bit(1'b0);                  // start
        for (int i = 0; i < 8; i++)
            send_bit(b[i]);
        send_bit(good_parity ? ~(^b) : (^b));  // odd parity (or corrupted)
        send_bit(1'b1);                  // stop
        #(2*PS2_HALF);
    end
    endtask

    task send_byte  (input [7:0] b); send_frame(b, 1'b1); endtask

    task mk  (input [7:0] b);  send_byte(b);                                endtask
    task mke (input [7:0] b);  send_byte(8'hE0); send_byte(b);              endtask
    task brk (input [7:0] b);  send_byte(8'hF0); send_byte(b);              endtask
    task brke(input [7:0] b);  send_byte(8'hE0); send_byte(8'hF0); send_byte(b); endtask

    // ---- scoreboard ----------------------------------------------------------
    integer errors = 0;
    integer nev = 0, nstop = 0;
    logic [7:0] exp_q [$];               // {ar2, code}
    string      exp_what [$];
    logic [7:0] cur_e;
    string      cur_w;

    always @(posedge clk) begin
        if (key_stb) begin
            nev = nev + 1;
            if (exp_q.size() == 0) begin
                errors = errors + 1;
                $display("PS2-ERROR: unexpected event code=%03o ar2=%b",
                         key_code, key_ar2);
            end else begin
                cur_e = exp_q.pop_front();
                cur_w = exp_what.pop_front();
                if ({key_ar2, key_code} !== cur_e) begin
                    errors = errors + 1;
                    $display("PS2-ERROR: %s: got code=%03o ar2=%b, want code=%03o ar2=%b",
                             cur_w, key_code, key_ar2, cur_e[6:0], cur_e[7]);
                end
            end
        end
        if (key_stop) nstop = nstop + 1;
    end

    task expect_ev (input [6:0] code, input ar2, input string what);
    begin
        exp_q.push_back({ar2, code});
        exp_what.push_back(what);
    end
    endtask

    task check_down (input v, input string what);
    begin
        if (key_down !== v) begin
            errors = errors + 1;
            $display("PS2-ERROR: key_down=%b, want %b (%s)", key_down, v, what);
        end
    end
    endtask

    // ---- the scenario ---------------------------------------------------------
    initial begin
        #10_000;

        // 1: plain letter, power-on ЛАТ+ЗАГЛ -> uppercase Latin
        expect_ev(7'o101, 0, "a: LAT+ZAGL");
        mk(8'h1C);  check_down(1, "a held");  brk(8'h1C);  check_down(0, "a up");

        // 2: typematic suppression - repeated make while held = ONE event
        expect_ev(7'o101, 0, "a first make");
        mk(8'h1C);  mk(8'h1C);  mk(8'h1C);  brk(8'h1C);

        // 3: НР with ЗАГЛ absorbs shift on letters
        expect_ev(7'o101, 0, "shift+a under ZAGL");
        mk(8'h12);  mk(8'h1C);  brk(8'h1C);  brk(8'h12);

        // 4: CapsLock -> СТР: letters drop to the low register; НР flips back
        mk(8'h58);  brk(8'h58);                      // ЗАГЛ -> СТР
        expect_ev(7'o141, 0, "a: LAT+STR");
        mk(8'h1C);  brk(8'h1C);
        expect_ev(7'o101, 0, "shift+a: LAT+STR+NR");
        mk(8'h12);  mk(8'h1C);  brk(8'h1C);  brk(8'h12);
        mk(8'h58);  brk(8'h58);                      // back to ЗАГЛ

        // 5: РУС (LCtrl) emits 016 and flips the shadow: letters -> 0141+
        expect_ev(7'o016, 0, "RUS key");
        mk(8'h14);  brk(8'h14);
        expect_ev(7'o141, 0, "a: RUS+ZAGL");
        mk(8'h1C);  brk(8'h1C);

        // 6: ЛАТ (Home) emits 017 and flips back
        expect_ev(7'o017, 0, "LAT key");
        mke(8'h6C);  brke(8'h6C);
        expect_ev(7'o101, 0, "a: LAT again");
        mk(8'h1C);  brk(8'h1C);

        // 7: СУ (Insert held) masks 01xx codes to control codes; the result
        //    001 is in the silicon auto-274 group -> ar2 set
        mke(8'h70);
        expect_ev(7'o001, 1, "SU+a");
        mk(8'h1C);  brk(8'h1C);
        brke(8'h70);

        // 8: АР2 (Alt held) tags the event
        mk(8'h11);
        expect_ev(7'o101, 1, "AR2+a");
        mk(8'h1C);  brk(8'h1C);
        brk(8'h11);

        // 9: arrows are NOT auto-274 (silicon-measured); Tab (code 011) IS
        expect_ev(7'o032, 0, "Up arrow");
        mke(8'h75);  brke(8'h75);
        expect_ev(7'o011, 1, "Tab (silicon auto-274 group)");
        mk(8'h0D);  brk(8'h0D);
        expect_ev(7'o001, 1, "F1 = ПОВТ");
        mk(8'h05);  brk(8'h05);

        // 10: digits/symbols through the shift table
        expect_ev(7'o061, 0, "1");
        mk(8'h16);  brk(8'h16);
        expect_ev(7'o041, 0, "shift+1 = !");
        mk(8'h12);  mk(8'h16);  brk(8'h16);  brk(8'h12);
        expect_ev(7'o012, 0, "Enter");
        mk(8'h5A);  brk(8'h5A);

        // 11: multi-key key_down
        expect_ev(7'o101, 0, "a of pair");
        expect_ev(7'o102, 0, "b of pair");
        mk(8'h1C);  mk(8'h32);  check_down(1, "a+b held");
        brk(8'h1C); check_down(1, "b still held");
        brk(8'h32); check_down(0, "all up");

        // 12: СТОП (Delete): strobe on make only, typematic suppressed
        if (nstop != 0) begin
            errors = errors + 1;
            $display("PS2-ERROR: premature key_stop");
        end
        mke(8'h71);  mke(8'h71);          // make + typematic repeat
        brke(8'h71);
        #10_000;
        if (nstop != 1) begin
            errors = errors + 1;
            $display("PS2-ERROR: key_stop count=%0d, want 1", nstop);
        end

        // 13: parity-corrupted frame is dropped (no event)
        send_frame(8'h1C, 1'b0);          // bad 'a' make
        send_byte(8'hF0); send_frame(8'h1C, 1'b0);
        #10_000;

        // 14: abandoned half-frame, then the dead-men recover everything:
        //     the ps2_rx frame watchdog (~340 us) AND the translator prefix
        //     timeout (~10.8 ms - step 13 left a stale F0 that would swallow
        //     the next make)
        ps2d = 0; #(PS2_HALF/2); ps2c = 0; #(PS2_HALF); ps2c = 1; #(PS2_HALF/2);
        ps2d = 1; #(PS2_HALF/2); ps2c = 0; #(PS2_HALF); ps2c = 1; #(PS2_HALF/2);
        #12_000_000;                      // > both watchdogs
        expect_ev(7'o101, 0, "a after recovery");
        mk(8'h1C);  brk(8'h1C);

        #50_000;
        if (exp_q.size() != 0) begin
            errors = errors + 1;
            $display("PS2-ERROR: %0d expected events never arrived", exp_q.size());
            for (int i = 0; i < exp_q.size(); i++)
                $display("PS2-ERROR:   missing: %s", exp_what[i]);
        end
        if (errors == 0) begin
            $display("events checked: %0d", nev);
            $display("COSIM PASS");
        end else
            $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("PS2-ERROR: timeout");
        $display("COSIM FAIL");
        $finish;
    end

endmodule
