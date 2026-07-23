// raminit_tb - unit oracle for src/ram_init.sv (the authentic DRAM power-on
// pattern filler). Drives ram_init with a served-mask-honoring grant model and
// checks, per fill pass:
//   * the SEGMENT SEQUENCE: a pass covers every needed segment, machine RAM
//     (seg 0) first, then the SMK512's 256 Kwords (seg 1) - and skips either
//     when its own trigger says it is not needed;
//   * the address walk covers exactly each segment's range, contiguously
//     (bk10 0x0000..0x3FFF = 16384 words; bk11 0x20000..0x2FFFF = 65536 words;
//     SMK 0x40000..0x7FFFF = 262144 words);
//   * every written word matches the expected data: for seg 0 the bkemu-QT
//     power-on pattern - this oracle is an INDEPENDENT, literal transcription
//     of the C loops CMotherBoard[_11M]::InitMemoryValues (devemu/Board.cpp /
//     Board_11M.cpp), an exp_val bit plus the flag/n counters stepped per
//     granted word exactly as the emulator, NOT a copy of the RTL's closed
//     form, so a derivation bug in the RTL is caught here - and for seg 1
//     exactly 0x0000 (the SMK512 has no reference pattern; see the RTL header);
//   * the served-mask contract: w_req drops for >=1 cycle after each grant;
//   * the trigger, against an INDEPENDENT shadow model of ram_valid /
//     model_seen / smk_valid kept here in the tb: main fill at power-on and on
//     a model change only; SMK fill at power-on and on a DIP-8 0->1 only, both
//     flags sticky across "warm resets" (a same-configuration reset must never
//     re-fill, and DIP 8 off->on again must not re-zero);
//   * blank_pulse: silent on the first (power-on) fill AND on an SMK-only fill
//     (SMK RAM is never displayed), one pulse per main-RAM re-fill.
// Breaking the RTL pattern compare, range, segment sequence or trigger makes a
// check fire and the run drops the final COSIM PASS.
`timescale 1ns/1ps
module raminit_tb;

    localparam int AB = 24;

    localparam logic [AB-1:0] SMK_BASE = 24'h040000;
    localparam logic [AB-1:0] SMK_LAST = 24'h07FFFF;
    localparam int            SMK_CNT  = 262144;

    logic          clk = 0;
    logic          rst_n;
    logic          model_bk11;
    logic          smk_en;
    logic          enable;
    logic          w_req, w_gnt;
    logic [AB-1:0] w_addr;
    logic [15:0]   w_wdata;
    logic          fill_active, fill_busy, blank_pulse;

    always #5 clk = ~clk;   // 100 MHz

    ram_init #(.ADDR_BITS(AB)) dut (
        .clk(clk), .rst_n(rst_n), .model_bk11(model_bk11), .smk_en(smk_en),
        .enable(enable),
        .w_req(w_req), .w_addr(w_addr), .w_wdata(w_wdata), .w_gnt(w_gnt),
        .fill_active(fill_active), .fill_busy(fill_busy), .blank_pulse(blank_pulse)
    );

    // ---- grant model: at most one grant per 3 cycles, only while w_req -------
    // (models the arbiter's re-arb + SDRAM write latency; forces ram_init to
    // honor the served-mask gap between words).
    logic [1:0] cd;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_gnt <= 1'b0;
            cd    <= 2'd0;
        end else begin
            w_gnt <= 1'b0;
            if (cd != 0)          cd <= cd - 1'b1;
            else if (w_req)     begin w_gnt <= 1'b1; cd <= 2'd2; end
        end
    end

    // ---- checker ------------------------------------------------------------
    logic          fa_d, gnt_d;
    logic [AB-1:0] exp_addr;
    logic [31:0]   word_cnt;
    logic          cur_model;
    logic [31:0]   total_fills, main_fills, smk_fills;
    logic          err;
    logic [15:0]   expw;
    logic [AB-1:0] seg_last;
    logic [31:0]   exp_cnt;

    // Independent shadow of the RTL's own trigger state.
    logic sh_ram_valid, sh_smk_valid, sh_model_seen;
    logic need_main_x, need_smk_x;   // expectations captured at fill start
    logic chk_seg;                   // segment currently being checked
    logic pend_smk;                  // seg 1 still owed in this pass

    // Independent pattern model = a literal transcription of the bkemu-QT
    // InitMemoryValues loops (Board.cpp / Board_11M.cpp), stepped per word.
    logic          exp_val;       // current word value bit (0 or 1 -> {16{}})
    logic [7:0]    exp_flag8;     // bk10 uint8_t flag
    logic [3:0]    exp_n;         // bk11 n (8..1)
    logic [3:0]    exp_flag11;    // bk11 flag (8..0)
    logic          ev;            // bk10: flag==192 event (temp)
    logic [3:0]    nd, fd;        // bk11: decremented n / flag (temp)

    task automatic shadow_reset;   // model a power cycle (rst_n pulse)
        begin
            sh_ram_valid = 1'b0;
            sh_smk_valid = 1'b0;
            sh_model_seen = 1'b0;
        end
    endtask

    initial begin
        err = 0; total_fills = 0; main_fills = 0; smk_fills = 0;
        fa_d = 0; gnt_d = 0;
        exp_addr = 0; word_cnt = 0; cur_model = 0;
        exp_val = 0; exp_flag8 = 0; exp_n = 8; exp_flag11 = 8;
        chk_seg = 0; pend_smk = 0; need_main_x = 0; need_smk_x = 0;
        shadow_reset;
    end

    always @(posedge clk) begin
        fa_d  <= fill_active;
        gnt_d <= w_gnt;

        // served-mask: the cycle after a grant, w_req must be low
        if (gnt_d && w_req) begin
            $display("RAMINIT-ERROR: w_req not dropped for a cycle after grant");
            err <= 1'b1;
        end

        // fill start (rising edge of fill_active)
        if (fill_active && !fa_d) begin
            need_main_x = !sh_ram_valid || (model_bk11 != sh_model_seen);
            need_smk_x  = smk_en && !sh_smk_valid;
            cur_model  <= model_bk11;
            chk_seg    <= !need_main_x;
            pend_smk   <= need_main_x && need_smk_x;
            exp_addr   <= need_main_x ? (model_bk11 ? 24'h020000 : 24'h000000)
                                      : SMK_BASE;
            word_cnt   <= 0;
            // reset the InitMemoryValues loop state to its i=0 initial values
            exp_val    <= 1'b0;
            exp_flag8  <= 8'd0;
            exp_n      <= 4'd8;
            exp_flag11 <= 4'd8;
            if (!need_main_x && !need_smk_x) begin
                $display("RAMINIT-ERROR: fill started with nothing needed");
                err <= 1'b1;
            end
            // blank_pulse: only a MAIN-RAM re-fill blacks the display out
            if (blank_pulse !== (need_main_x && sh_ram_valid)) begin
                $display("RAMINIT-ERROR: blank_pulse=%b, expected %b (need_main=%b ram_valid=%b)",
                         blank_pulse, need_main_x && sh_ram_valid,
                         need_main_x, sh_ram_valid);
                err <= 1'b1;
            end
        end

        // capture each granted word
        if (w_gnt && fill_active) begin
            seg_last = chk_seg ? SMK_LAST : (cur_model ? 24'h02FFFF : 24'h003FFF);
            exp_cnt  = chk_seg ? SMK_CNT  : (cur_model ? 32'd65536  : 32'd16384);
            if (w_addr !== exp_addr) begin
                $display("RAMINIT-ERROR: seg%0d addr %06h != expected %06h",
                         chk_seg, w_addr, exp_addr);
                err <= 1'b1;
            end
            expw = chk_seg ? 16'h0000 : {16{exp_val}};
            if (w_wdata !== expw) begin
                $display("RAMINIT-ERROR: wdata %04h != expected %04h @ %06h",
                         w_wdata, expw, w_addr);
                err <= 1'b1;
            end

            if (w_addr === seg_last) begin      // last word of this segment
                if (word_cnt + 1 !== exp_cnt) begin
                    $display("RAMINIT-ERROR: seg%0d fill count %0d != expected %0d",
                             chk_seg, word_cnt + 1, exp_cnt);
                    err <= 1'b1;
                end
                word_cnt <= 0;
                if (!chk_seg) begin
                    sh_ram_valid  <= 1'b1;
                    sh_model_seen <= cur_model;
                    main_fills    <= main_fills + 1'b1;
                    $display("RAMINIT: seg0 (machine RAM) fill done model=%b words=%0d",
                             cur_model, word_cnt + 1);
                    if (pend_smk) begin         // hand over to seg 1
                        chk_seg  <= 1'b1;
                        pend_smk <= 1'b0;
                        exp_addr <= SMK_BASE;
                    end
                end else begin
                    sh_smk_valid <= 1'b1;
                    smk_fills    <= smk_fills + 1'b1;
                    $display("RAMINIT: seg1 (SMK RAM) fill done words=%0d", word_cnt + 1);
                end
            end else begin
                exp_addr <= exp_addr + 1'b1;
                word_cnt <= word_cnt + 1'b1;
            end

            // advance the InitMemoryValues loop state for the next word
            if (!cur_model) begin
                // bk10 (Board.cpp): val=~val, then flag==192 -> extra invert +
                // reset; the for-update decrements the uint8_t flag.
                ev = (exp_flag8 == 8'd192);
                exp_val   <= ev ? exp_val : ~exp_val;
                exp_flag8 <= (ev ? 8'd0 : exp_flag8) - 8'd1;
            end else begin
                // bk11 (Board_11M.cpp): every 8 words decrement flag; invert
                // val while the decremented flag stays >0, else reset flag=8.
                nd = exp_n - 4'd1;
                if (nd == 4'd0) begin
                    exp_n <= 4'd8;
                    fd = exp_flag11 - 4'd1;
                    if (fd != 4'd0) begin
                        exp_val    <= ~exp_val;
                        exp_flag11 <= fd;
                    end else begin
                        exp_flag11 <= 4'd8;
                    end
                end else begin
                    exp_n <= nd;
                end
            end
        end

        // fill end (falling edge of fill_active)
        if (!fill_active && fa_d) begin
            if (pend_smk) begin
                $display("RAMINIT-ERROR: pass ended with the SMK segment skipped");
                err <= 1'b1;
            end
            if (word_cnt !== 0) begin
                $display("RAMINIT-ERROR: pass ended mid-segment (%0d words in)", word_cnt);
                err <= 1'b1;
            end
            total_fills <= total_fills + 1'b1;
            $display("RAMINIT: pass #%0d done", total_fills);
        end
    end

    // ---- stimulus -----------------------------------------------------------
    task automatic wait_fill;   // wait for one fill pass to start and finish
        begin
            wait (fill_busy);
            @(negedge fill_busy);
            repeat (4) @(posedge clk);   // let the end-detect + count settle
        end
    endtask

    task automatic expect_idle(input string what);
        begin
            repeat (400) @(posedge clk);
            if (fill_busy || fill_active) begin
                $display("RAMINIT-ERROR: unexpected fill (%0s)", what);
                err = 1;
            end
        end
    endtask

    task automatic expect_counts(input [31:0] m, input [31:0] s, input string what);
        begin
            if (main_fills !== m || smk_fills !== s) begin
                $display("RAMINIT-ERROR: %0s: main_fills=%0d smk_fills=%0d, expected %0d/%0d",
                         what, main_fills, smk_fills, m, s);
                err = 1;
            end
        end
    endtask

    initial begin
        rst_n = 0; model_bk11 = 0; smk_en = 0; enable = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // (1) power-on fill, bk10, no SMK -> main only, no blank
        enable = 1;
        wait_fill;
        expect_counts(1, 0, "power-on bk10 fill");

        // (2) same-config "warm reset": nothing changed -> NO new fill
        expect_idle("same-config reset");
        expect_counts(1, 0, "after same-config reset");

        // (3) DIP 8 turned ON at a warm reset -> SMK-ONLY fill, no blank
        smk_en = 1;
        wait_fill;
        expect_counts(1, 1, "DIP-8 enable fill");

        // (4) another same-config reset -> still nothing
        expect_idle("same-config reset with SMK on");

        // (5) DIP 8 off, then on again -> the content survived, NO re-fill
        smk_en = 0;
        expect_idle("DIP-8 disable");
        smk_en = 1;
        expect_idle("DIP-8 re-enable (smk_valid is sticky)");
        expect_counts(1, 1, "after the DIP-8 round trip");

        // (6) model change with SMK on -> MAIN re-fill only (blank), seg 1 kept
        model_bk11 = 1;
        wait_fill;
        expect_counts(2, 1, "bk11 re-fill");

        // (7) model change back -> main re-fill again
        model_bk11 = 0;
        wait_fill;
        expect_counts(3, 1, "bk10 re-fill");

        // (8) power cycle with both DIPs set -> ONE pass, seg 0 then seg 1
        enable = 0;
        rst_n  = 0;
        shadow_reset;
        repeat (8) @(posedge clk);
        rst_n      = 1;
        model_bk11 = 1;
        smk_en     = 1;
        repeat (4) @(posedge clk);
        enable = 1;
        wait_fill;
        expect_counts(4, 2, "power-cycle two-segment pass");
        if (total_fills !== 5) begin
            $display("RAMINIT-ERROR: %0d passes, expected 5 (the last must cover BOTH segments)",
                     total_fills);
            err = 1;
        end

        repeat (20) @(posedge clk);
        if (err) $display("COSIM FAIL");
        else     $display("COSIM PASS");
        $finish;
    end

    // safety timeout (two 262144-word SMK fills + the main fills, ~3 cyc/word)
    initial begin
        #60_000_000;
        $display("RAMINIT-ERROR: timeout");
        $display("COSIM FAIL");
        $finish;
    end

endmodule
