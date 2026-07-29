// ============================================================================
//  sd_backend_tb - unit oracle for src/peripheral/sd_backend.sv against sd_model.v
//  (Phase-8 IDE increment (b)). The tb plays the smk_ide engine role on
//  the bk_* backend sector port; the card model is loaded with the SAME
//  gen_ide_image.py AltPro image the ide oracles use (sectors past the
//  image, SDHC only, hold a known filler so high-sector addressing is
//  checkable). The engine-side sector buffer is emulated with the same
//  registered-read RAM smk_ide has, so the commit settle contract is
//  exercised for real.
//
//  Legs (default run = SDHC personality; +sdsc = v1 byte-addressed card):
//    0 init transcript : media_ok rises; >=74 CS-high dummy clocks;
//        CMD0/CMD8/ACMD41/CMD58/CMD9 each seen; CMD16 seen iff SDSC
//        (and never on the SDHC card); bk_total exact from the CSD
//        (SDHC 1024 = CSDv2, SDSC 640 = CSDv1) - both card types walk
//        both CSD capacity formulas.
//    1 reads data-exact: sector 7 (the attach-critical AltPro table
//        sector) + a spread incl. sector 639 (image end) and, SDHC, a
//        past-image sector against the filler (addressing beyond the
//        image); a x512 addressing slip fails BOTH personalities (data
//        lands from the wrong sector / the model flags misalignment).
//    2 oob            : sector == bk_total completes done+error with
//        ZERO SPI traffic (cmd_total unchanged) - the disk-model
//        contract smk_ide relies on.
//    3 write+readback : buffer word -> CMD24 -> model backing store
//        checked word-exact -> CMD17 round trip; then a re-read of
//        sector 0 (the backend serves normally after every leg).
//    4 warm-reset recovery : rst_n is pulsed WITHOUT resetting the card
//        (exactly what DCLO does on the board - the card keeps its state),
//        landing MID-single-block-read so the card is left holding ~half a
//        block that the preamble must flush before CMD0 (the model
//        deliberately does not drop that residue on the idle CMD12). The
//        sector opens with a long 0xFF run - what a BK disk really looks
//        like on the card, since the IDE layer inverts - which is the case
//        a flush that stops when the bus merely LOOKS idle gets wrong.
//        The leg also asserts dbg_retried == 0: ONE recovery pass must be
//        enough, so the automatic retry cannot hide a weak recovery.
//  Error-injection runs (each a separate vvp invocation):
//    +noinit : ACMD41 never ready -> bk_media_ok stays 0, no bk_done.
//    +rderr  : read answers an error token -> bk_done+bk_error, no
//              buffer writes; media_ok stays up.
//    +wrrej  : write data-response reject -> bk_done+bk_error, backing
//              store untouched.
//    +cmd0busy : the card answers no CMD0 for the first 25 ms (a still-busy
//              card). Init must still complete - only by re-running the WHOLE
//              recovery between attempts, which is the automatic equivalent
//              of the second reset press; dbg_retried must record it.
//    +cmd8junk : an SDHC card whose FIRST CMD8 answers illegal-command (what
//              one stray residue byte does). A host that only retries CMD0
//              mistypes it v1, sends ACMD41 without HCS and stalls forever;
//              the whole-ladder retry must recover AND re-type it SDHC.
//
//  Pass: "COSIM PASS" with zero tb errors AND zero model protocol
//  errors (the model checks CRCs, CMD ordering, alignment - see
//  sd_model.v).
// ============================================================================
`timescale 1ns/1ps
module sd_backend_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;               // ~100 MHz sys_clk stand-in
    reg rst_n = 1'b0;

    integer errors = 0;
    reg sdsc, noinit, rderr, wrrej, cmd0busy, cmd8junk;

    // ---- DUT + card ---------------------------------------------------------
    wire sd_ck, sd_cs, sd_mosi, sd_miso;

    reg         bk_req = 0, bk_wr = 0;
    reg  [27:0] bk_sector = 0;
    wire        bk_ack, bk_done, bk_error, bk_media_ok;
    wire [27:0] bk_total;
    wire [7:0]  bk_baddr;
    wire [15:0] bk_wdata;
    wire        bk_we;
    reg  [15:0] bk_rdata;

    sd_backend #(
        .SETTLE_CLKS (64),              // shrunk budgets; dividers stay REAL
        .INIT_TRIES  (4),
        .ACMD41_TRIES(64),
        .TOK_POLLS   (64),
        .BUSY_POLLS  (64),
        // PRE_FLUSH stays big enough to swallow a WHOLE residual block
        // (token + 512 + CRC) - that is the property the recovery leg tests
        .PRE_BUSY_BYTES(64),
        .PRE_FLUSH     (700),
        .PRE_IDLE      (64)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (1'b1),
        .sd_ck      (sd_ck),
        .sd_cs      (sd_cs),
        .sd_mosi    (sd_mosi),
        .sd_miso    (sd_miso),
        .bk_req     (bk_req),
        .bk_wr      (bk_wr),
        .bk_sector  (bk_sector),
        .bk_bank    (1'b0),
        .bk_ack     (bk_ack),
        .bk_done    (bk_done),
        .bk_error   (bk_error),
        .bk_media_ok(bk_media_ok),
        .bk_total   (bk_total),
        .bk_baddr   (bk_baddr),
        .bk_wdata   (bk_wdata),
        .bk_we      (bk_we),
        .bk_rdata   (bk_rdata)
    );

    sd_model u_card (
        .rst  (1'b0),
        .ck   (sd_ck),
        .cs   (sd_cs),
        .mosi (sd_mosi),
        .miso (sd_miso)
    );

    // ---- engine-side buffer emulation ----------------------------------------
    // fetch side: capture the backend's bank writes
    reg [15:0] rbuf [0:255];
    integer    we_count;
    always @(posedge clk)
        if (bk_we) begin
            rbuf[bk_baddr] <= bk_wdata;
            we_count = we_count + 1;
        end
    // commit side: the registered-read RAM exactly like smk_ide's sbuf
    reg [15:0] wbuf [0:255];
    always @(posedge clk)
        bk_rdata <= wbuf[bk_baddr];

    // ---- reference data -------------------------------------------------------
    reg [15:0] ref_img [0:640*256-1];

    function [15:0] filler(input integer idx);
        filler = 16'hBEEF + idx;        // past-image SDHC sectors
    endfunction

    function [15:0] wpat(input integer sec, input integer w);
        wpat = (sec*7 + w*3 + 16'h1234) & 16'hFFFF;   // leg-5 write pattern
    endfunction

    // ---- helpers ---------------------------------------------------------------
    task check(input cond, input [8*80-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("SD-ERROR: tb: %0s (time %0t)", msg, $time);
        end
    endtask

    integer cnt;
    reg     done_seen, err_seen;
    reg     saw_done = 1'b0;            // any bk_done ever (for +noinit)
    always @(posedge clk) if (bk_done) saw_done = 1'b1;

    task bk_op(input wr, input [27:0] sec, input exp_err);
        begin
            we_count = 0;
            @(posedge clk);
            bk_wr     <= wr;
            bk_sector <= sec;
            bk_req    <= 1'b1;
            cnt = 0;
            while (!bk_ack && cnt < 1000000) begin
                @(posedge clk); cnt = cnt + 1;
            end
            check(bk_ack, "no bk_ack");
            bk_req <= 1'b0;
            done_seen = 0; err_seen = 0; cnt = 0;
            while (!done_seen && cnt < 2000000) begin
                @(posedge clk);
                if (bk_done) begin
                    done_seen = 1;
                    err_seen  = bk_error;
                end
                cnt = cnt + 1;
            end
            check(done_seen, "no bk_done");
            check(err_seen == exp_err, "bk_error mismatch");
        end
    endtask

    // start an op and return as soon as it is accepted (the recovery leg resets the
    // host in the middle of the transfer, so it must not wait for bk_done)
    task bk_start(input wr, input [27:0] sec);
        begin
            we_count = 0;
            @(posedge clk);
            bk_wr     <= wr;
            bk_sector <= sec;
            bk_req    <= 1'b1;
            cnt = 0;
            while (!bk_ack && cnt < 1000000) begin
                @(posedge clk); cnt = cnt + 1;
            end
            check(bk_ack, "no bk_ack");
            bk_req <= 1'b0;
        end
    endtask

    // a DCLO pulse: resets the HOST only - the card keeps its state, which
    // is the whole point of the recovery preamble
    task warm_reset;
        begin
            rst_n = 1'b0;
            repeat (20) @(posedge clk);
            rst_n = 1'b1;
            cnt = 0;
            while (!bk_media_ok && cnt < 8000000) begin
                @(posedge clk); cnt = cnt + 1;
            end
            check(bk_media_ok, "no re-init after a warm reset");
            // The field symptom this whole preamble exists for was "one reset
            // is not enough, a second one works". A retry would paper over
            // exactly that, so pin the stronger property: ONE recovery pass
            // brings the card back. (The retry path itself is covered by the
            // +cmd0busy run.)
            check(u_dut.dbg_retried === 1'b0,
                  "re-init needed a CMD0 retry: one recovery pass was not enough");
        end
    endtask

    integer w;
    task cmp_ref(input [27:0] sec);     // rbuf vs the image
        begin
            check(we_count == 256, "read did not deliver 256 words");
            for (w = 0; w < 256; w = w + 1)
                if (rbuf[w] !== ref_img[sec*256 + w]) begin
                    errors = errors + 1;
                    $display("SD-ERROR: tb: sector %0d word %0d: %04x != %04x",
                             sec, w, rbuf[w], ref_img[sec*256 + w]);
                    w = 256;
                end
        end
    endtask

    task finish_report;
        begin
            if (errors == 0 && u_card.prot_errors == 0)
                $display("COSIM PASS");
            else
                $display("COSIM FAIL: %0d tb + %0d protocol errors",
                         errors, u_card.prot_errors);
            $finish;
        end
    endtask

    // ---- watchdog ---------------------------------------------------------------
    initial begin
        #500_000_000;                   // 500 ms sim time
        $display("SD-ERROR: tb: global watchdog");
        $display("COSIM FAIL");
        $finish;
    end

    // ---- main -------------------------------------------------------------------
    integer i, ct;
    integer s;
    reg [15:0] save;
    initial begin
        sdsc   = $test$plusargs("sdsc");
        noinit = $test$plusargs("noinit");
        rderr  = $test$plusargs("rderr");
        wrrej  = $test$plusargs("wrrej");
        cmd0busy = $test$plusargs("cmd0busy");
        cmd8junk = $test$plusargs("cmd8junk");

        $readmemh("ide_image.hex", ref_img);
        for (i = 0; i < 1024*256; i = i + 1)
            u_card.card[i] = filler(i);
        $readmemh("ide_image.hex", u_card.card);

        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        if (noinit) begin
            // a full failed init ladder fits well inside this window
            repeat (4000000) @(posedge clk);
            check(!bk_media_ok, "media_ok rose under +noinit");
            check(!saw_done,    "spurious bk_done under +noinit");
            finish_report;
        end

        // ---- leg 0: init transcript ----
        cnt = 0;
        while (!bk_media_ok && cnt < 20000000) begin
            @(posedge clk); cnt = cnt + 1;
        end
        check(bk_media_ok, "init did not complete");
        check(u_card.dummy_clocks >= 74, "fewer than 74 dummy clocks");
        check(u_card.cmd0_cnt   >= 1, "CMD0 not seen");
        // +cmd8junk deliberately forces a second whole-ladder attempt, so
        // CMD8 is legitimately sent twice there; everywhere else exactly once
        check(u_card.cmd8_cnt   == (cmd8junk ? 2 : 1), "CMD8 count wrong");
        check(u_card.acmd41_cnt >= 1, "ACMD41 not seen");
        check(u_card.cmd58_cnt  == 1, "CMD58 count wrong");
        check(u_card.cmd9_cnt   == 1, "CMD9 count wrong");
        check(u_card.cmd16_cnt  == (sdsc ? 1 : 0), "CMD16 iff SDSC violated");
        check(u_card.cmd16_sdhc == 0, "CMD16 sent to the SDHC card");
        check(bk_total == (sdsc ? 28'd640 : 28'd1024), "bk_total wrong");

        if (cmd8junk) begin
            // the card was mistyped v1 on the first attempt and stalled in
            // ACMD41; only a whole-ladder retry recovers, and it must re-type
            // the card correctly (SDHC capacity, not the v1 reading)
            check(u_dut.dbg_retried === 1'b1, "+cmd8junk: no retry was recorded");
            check(u_dut.dbg_fail   === 4'd5,
                  "+cmd8junk: expected fail code 5 (ACMD41 stalled, typed v1)");
            check(u_card.cmd8_cnt >= 2, "+cmd8junk: CMD8 was not re-sent");
            check(bk_total == 28'd1024, "+cmd8junk: card not re-typed as SDHC");
            bk_op(0, 7, 0); cmp_ref(7);
            finish_report;
        end

        if (cmd0busy) begin
            // the card swallowed the first CMD0; init must still complete,
            // via the automatic recovery retry, and then serve normally
            check(u_dut.dbg_retried === 1'b1, "+cmd0busy: no retry was recorded");
            check(u_card.cmd0_cnt >= 2, "+cmd0busy: CMD0 was not re-sent");
            bk_op(0, 7, 0); cmp_ref(7);
            finish_report;
        end

        if (rderr) begin
            bk_op(0, 7, 1);             // error token -> done+error
            check(we_count == 0, "buffer written despite the read error");
            bk_op(0, 3, 1);             // still serving (and still erroring)
            finish_report;
        end

        if (wrrej) begin
            for (w = 0; w < 256; w = w + 1)
                wbuf[w] = 16'h55AA ^ w;
            save = u_card.card[3*256 + 5];
            bk_op(1, 3, 1);             // reject -> done+error
            check(u_card.card[3*256 + 5] === save,
                  "backing store changed despite the write reject");
            finish_report;
        end

        // ---- leg 1: reads data-exact ----
        bk_op(0, 7, 0);   cmp_ref(7);   // the AltPro geometry sector
        bk_op(0, 0, 0);   cmp_ref(0);
        bk_op(0, 1, 0);   cmp_ref(1);
        bk_op(0, 100, 0); cmp_ref(100);
        bk_op(0, 639, 0); cmp_ref(639); // image end
        if (!sdsc) begin                // past-image sector: filler content
            bk_op(0, 700, 0);
            check(we_count == 256, "read did not deliver 256 words");
            for (w = 0; w < 256; w = w + 1)
                if (rbuf[w] !== filler(700*256 + w)) begin
                    errors = errors + 1;
                    $display("SD-ERROR: tb: filler sector word %0d: %04x != %04x",
                             w, rbuf[w], filler(700*256 + w));
                    w = 256;
                end
        end

        // ---- leg 2: oob completes with no SPI traffic ----
        ct = u_card.cmd_total;
        bk_op(0, bk_total, 1);
        check(u_card.cmd_total == ct, "oob request reached the card");
        check(we_count == 0, "oob request moved data");

        // ---- leg 3: write + backing-store check + readback round trip ----
        for (w = 0; w < 256; w = w + 1)
            wbuf[w] = (5*w + 16'hA5A5) & 16'hFFFF;
        bk_op(1, 5, 0);
        for (w = 0; w < 256; w = w + 1)
            if (u_card.card[5*256 + w] !== wbuf[w]) begin
                errors = errors + 1;
                $display("SD-ERROR: tb: store word %0d: %04x != %04x",
                         w, u_card.card[5*256 + w], wbuf[w]);
                w = 256;
            end
        bk_op(0, 5, 0);
        check(we_count == 256, "readback did not deliver 256 words");
        for (w = 0; w < 256; w = w + 1)
            if (rbuf[w] !== wbuf[w]) begin
                errors = errors + 1;
                $display("SD-ERROR: tb: readback word %0d: %04x != %04x",
                         w, rbuf[w], wbuf[w]);
                w = 256;
            end
        bk_op(0, 0, 0); cmp_ref(0);     // still serving normally

        // ---- leg 4: warm-reset recovery, mid-block ----
        // The reset lands MID-block of a single-sector read, so the card
        // is left holding the rest of that block - the preamble's flush is
        // what keeps those bytes out of CMD0's R1 poll.
        // The sector deliberately OPENS WITH A LONG 0xFF RUN: that is what a
        // BK disk actually looks like on the card (the IDE layer inverts, so
        // BK zero-filled regions are stored as 0xFF), and it is the case a
        // flush that stops as soon as the bus "looks idle" gets wrong - it
        // quits inside the residue and leaves the rest for CMD0.
        for (w = 0; w < 256; w = w + 1)
            u_card.card[200*256 + w] = (w < 64) ? 16'hFFFF : wpat(200, w);
        bk_start(0, 200);
        repeat (5000) @(posedge clk);   // ~70 bytes in: inside the 0xFF run
        check(u_card.oq_rd < u_card.oq_wr, "leg4: no in-flight block to flush");
        warm_reset;
        bk_op(0, 200, 0);
        check(we_count == 256, "leg4: readback did not deliver 256 words");
        for (w = 0; w < 256; w = w + 1)
            if (rbuf[w] !== ((w < 64) ? 16'hFFFF : wpat(200, w))) begin
                errors = errors + 1;
                $display("SD-ERROR: tb: leg4 readback word %0d: %04x", w, rbuf[w]);
                w = 256;
            end

        finish_report;
    end

endmodule
