// ============================================================================
//  smk_ide_tb - unit oracle for src/smk_ide.sv (Phase-8 IDE increment (a)).
//
//  Transcribes BkEmu IdeControllerTest.testIdeController plus the
//  SmkIdeController bus packing onto real Q-bus-shaped transactions at the
//  module pins (the spk_capture_tb driving style), against the behavioral
//  ide_disk_model loaded with mem/gen_ide_image.py's AltPro image
//  (C/H/S = 10/4/16 = 640 sectors, per-sector pattern data).
//
//  All register expectations are CORE-side values (what IdeControllerTest
//  asserts): the read task returns ~ide_rdata, and one dedicated leg pins
//  the raw ~ inversion itself so a dropped inversion cannot cancel out.
//  DATA-port convention (the SMK contract): the CPU stores word D by
//  writing ~D on the bus, and reads it back as ~(bus word) = D.
//
//  Legs (in order):
//    0  attach + reset snapshot (STATUS 0x40, ERROR 0x01, CYL 0/0, COUNT 1,
//       SNUM 1, DHR 0xA0, DAR 0x32) + the raw-inversion pin
//    1  absent slave: DHR DRV=1 -> all reads 0xFFFF (bus) / 0x0000 (core),
//       command write ignored; master re-select restores
//    2  SRST via byte 177743: assert -> BSY 0x80, release -> full snapshot;
//       word write at 177742 = DHR (NOT control); DAR head bits follow
//    3  lane rules: garbage command at exact 740 -> ABRT 0x41/0x04;
//       byte write to 741 ignored; SRST-release recovers
//    4  IDENTIFY: per-word STATUS 0x58 before / 0x50 after the last, full
//       word map vs an independent hand transcription of identify()
//    5  single-sector READ of EVERY sector via CHS auto-advance (one CHS
//       seed, then per-sector COUNT=1 + CMD 0x20), data vs the model array,
//       CHS register spot-checks at the S and H wrap boundaries
//    6  multi-sector READ: SNUM=2, COUNT=0 (=> 256 sectors), data vs model
//    6b prefetch overlap: COUNT=4 chain, per-sector data-exact; a mid-drain
//       SNUM read pins the visible CHS at drain-start (never at prefetch-
//       done); disk pass: no BSY window at the boundary; ack_cnt == 4
//    6c drain-finishes-first (disk pass only): a slow backend (lat_extra)
//       so the drain outruns the prefetch -> a real BSY window, then DRQ
//    6d mid-drain hazards (E_FLUSH interlock): d1 fresh COMMAND, d2 SRST,
//       d3 WRITE - each dispatched while a prefetch is in flight, recovers
//    7  single-sector WRITEs (pattern) -> model array compare + a READ
//       round-trip; multi-sector WRITE (COUNT=8) -> compare
//    8  ABRT: unsupported opcode (0xC4) and the LBA bit (documented
//       deviation) - status 0x41, error 0x04, recovery
//    9  data-hold: ide_rdata stable across the whole DIN window
//   10  geometry fallback: DCLO replay with a broken sector-7 checksum and
//       total=2016 -> raw defaults C/H/S 2/16/63 in IDENTIFY; then a replay
//       with total=640 -> C=total/1008=0 -> attach FAILS, drive absent
//       (BkEmu throws out of setupDefaultGeometry)
//
//  Prints IDE-ERROR lines and a final `COSIM PASS` (run.sh greps).
// ============================================================================
`timescale 1ns/1ps
module smk_ide_tb;

    // geometry of the generated image (mirrors gen_ide_image.py)
    localparam CYLS = 10, HEADS = 4, SECS = 16;
    localparam TOTAL = CYLS * HEADS * SECS;         // 640

    // -DSD_STACK (run.sh second pass): u_disk becomes sd_harness = the REAL
    // sd_backend + sd_model SPI stack; attach then rides a full card init +
    // SPI sector-7 read, so the attach waits and the watchdog scale up.
`ifdef SD_STACK
    `define DISK u_disk.u_card.card
    localparam AWAIT0 = 60000, AWAIT = 60000;
    localparam WDOG_NS = 500_000_000;
    localparam POLL_MAX = 6000;         // the hazard flush adds up to two
                                        // SPI sector times at the boundary
`else
    `define DISK u_disk.disk
    localparam AWAIT0 = 3000, AWAIT = 8000;
    localparam WDOG_NS = 60_000_000;
    localparam POLL_MAX = 2000;
`endif

    logic sclk = 0; always #5 sclk = ~sclk;         // ~100 MHz sys_clk stand-in

    // Q-bus (inverted); the tb is the only bus master
    logic [15:0] ad_drive = 16'hFFFF;
    logic        ad_oe    = 1'b0;
    wire  [15:0] ad_n = ad_oe ? ad_drive : 16'hzzzz;
    logic sync_n = 1'b1, din_n = 1'b1, dout_n = 1'b1, wtbt_n = 1'b1;

    logic reset  = 1'b1;
    logic media  = 1'b0;
    logic [27:0] total_in = TOTAL;

    wire [15:0] ide_rdata;
    wire        bk_req, bk_wr, bk_bank, bk_ack, bk_done, bk_error;
    wire        bk_media_ok;
    wire [27:0] bk_sector, bk_total;
    wire [7:0]  bk_baddr;
    wire [15:0] bk_wdata, bk_rdata;
    wire        bk_we;

    smk_ide dut (
        .sclk(sclk), .reset(reset), .enable(1'b1),
        .ad_n(ad_n), .sync_n(sync_n), .din_n(din_n), .dout_n(dout_n),
        .wtbt_n(wtbt_n),
        .ide_rdata(ide_rdata), .ide_act(),
        .bk_req(bk_req), .bk_wr(bk_wr), .bk_sector(bk_sector),
        .bk_bank(bk_bank), .bk_ack(bk_ack), .bk_done(bk_done),
        .bk_error(bk_error), .bk_media_ok(bk_media_ok), .bk_total(bk_total),
        .bk_baddr(bk_baddr), .bk_wdata(bk_wdata), .bk_we(bk_we),
        .bk_rdata(bk_rdata)
    );

`ifdef SD_STACK
    sd_harness     #(.MAX_SECTORS(TOTAL), .LATENCY(24)) u_disk (
`else
    ide_disk_model #(.MAX_SECTORS(TOTAL), .LATENCY(24)) u_disk (
`endif
        .sclk(sclk), .rst(reset),
        .media_in(media), .total_in(total_in),
        .bk_req(bk_req), .bk_wr(bk_wr), .bk_sector(bk_sector),
        .bk_bank(bk_bank), .bk_ack(bk_ack), .bk_done(bk_done),
        .bk_error(bk_error), .bk_media_ok(bk_media_ok), .bk_total(bk_total),
        .bk_baddr(bk_baddr), .bk_wdata(bk_wdata), .bk_we(bk_we),
        .bk_rdata(bk_rdata)
    );

    // register addresses (octal)
    localparam A_COMP0 = 16'o177740, A_COMP1 = 16'o177742,
               A_CYLHI = 16'o177744, A_CYLLO = 16'o177746,
               A_SNUM  = 16'o177750, A_COUNT = 16'o177752,
               A_ERR   = 16'o177754, A_DATA  = 16'o177756;

    integer errors = 0;

    // ---- prefetch spies ---------------------------------------------------
    // overlap_seen: a prefetch req riding high while the CPU still has DRQ up
    // (the tier-1 overlap moment). ack_cnt: one increment per accepted
    // backend op - snapshot ack_base before a chain to count its ops.
    reg     overlap_seen = 1'b0;
    integer ack_cnt = 0, ack_base = 0;
    always @(posedge sclk) begin
        if (bk_req && dut.drq) overlap_seen <= 1'b1;
        if (bk_ack)            ack_cnt <= ack_cnt + 1;
    end

    task chk(input [31:0] got, input [31:0] exp, input [255:0] what);
        if (got !== exp) begin
            errors = errors + 1;
            $display("IDE-ERROR %0s: got %04x expected %04x @%0t",
                     what, got, exp, $time);
        end
    endtask

    // ---- Q-bus cycle tasks (spk_capture_tb style) --------------------------
    // ALL write tasks take CORE-side values (what BkEmu's writeTaskRegister
    // receives): the device computes invValue = ~bus_true = ad_n, so the
    // core value goes onto ad_n DIRECTLY (the address phase still drives
    // the ordinary inverted address). The CPU-eye view - that software must
    // put ~X on the bus to deliver X - is pinned separately by the raw-
    // inversion leg; using core values everywhere else means a dropped
    // inversion in the DUT flips every check instead of cancelling out.

    // word write: WTBT at SYNC = write, RELEASED at DOUT = word op
    task w_word(input [15:0] a, input [15:0] x);
        begin
            ad_oe = 1'b1; ad_drive = ~a; wtbt_n = 1'b0;
            #6 sync_n = 1'b0;
            #6 ad_drive = x;                    // ad_n = x = invValue
            #4 wtbt_n = 1'b1; dout_n = 1'b0;
            repeat (4) @(posedge sclk);
            #2 dout_n = 1'b1;
            repeat (3) @(posedge sclk);         // release-edge action lands
            #4 sync_n = 1'b1; ad_oe = 1'b0; wtbt_n = 1'b1;
            repeat (2) @(posedge sclk);
        end
    endtask

    // byte write: WTBT stays asserted through DOUT; core byte on its lane,
    // the other lane deasserted (bus true 0 -> core 0xFF, matching the
    // BkEmu odd-byte value<<8 shape where only the addressed lane matters)
    task w_byte(input [15:0] a, input [7:0] x);
        begin
            ad_oe = 1'b1; ad_drive = ~a; wtbt_n = 1'b0;
            #6 sync_n = 1'b0;
            #6 ad_drive = a[0] ? {x, 8'hFF} : {8'hFF, x};
            #4 dout_n = 1'b0;
            repeat (4) @(posedge sclk);
            #2 dout_n = 1'b1;
            repeat (3) @(posedge sclk);
            #4 sync_n = 1'b1; ad_oe = 1'b0; wtbt_n = 1'b1;
            repeat (2) @(posedge sclk);
        end
    endtask

    // word read; returns the CORE-side value (~bus). For DATA-register
    // reads the word must stay stable across the whole DIN window (leg 9:
    // the drain pointer moves only at DIN RELEASE - the vm1 hold rule's
    // unit-level face). Status/task registers are exempt: device state may
    // legitimately change while a poll read is in flight (e.g. DRQ rising
    // when a chained fetch completes) - at SoC level qbus_mem's reply-point
    // rdata latch is what gives the CPU a coherent word.
    logic [15:0] rd_smp;
    task r_word(input [15:0] a, output [15:0] d);
        begin
            ad_oe = 1'b1; ad_drive = ~a;
            #6 sync_n = 1'b0;
            #6 ad_oe = 1'b0; din_n = 1'b0;
            repeat (3) @(posedge sclk);
            rd_smp = ide_rdata;                 // mid-window sample
            repeat (3) @(posedge sclk);
            if (a == A_DATA && ide_rdata !== rd_smp) begin
                errors = errors + 1;
                $display("IDE-ERROR data not held across DIN window @%0t",
                         $time);
            end
            d = ~ide_rdata;
            #2 din_n = 1'b1;
            #6 sync_n = 1'b1;
            repeat (3) @(posedge sclk);         // pointer-advance settles
        end
    endtask

    // poll STATUS (COMP_0 low byte) until DRQ, bounded
    task poll_drq;
        integer n;
        logic [15:0] v;
        begin
            n = 0;
            v = 0;
            while (!v[3] && n < POLL_MAX) begin
                r_word(A_COMP0, v);
                n = n + 1;
            end
            if (!v[3]) begin
                errors = errors + 1;
                $display("IDE-ERROR DRQ poll timeout @%0t", $time);
            end
        end
    endtask

    // poll STATUS until NOT DRQ/BSY (command end)
    task poll_idle;
        integer n;
        logic [15:0] v;
        begin
            n = 0;
            v = 16'h0008;
            while ((v[3] || v[7]) && n < POLL_MAX) begin
                r_word(A_COMP0, v);
                n = n + 1;
            end
        end
    endtask

    // expected IDENTIFY word - an INDEPENDENT hand transcription of BkEmu
    // identify() (do not derive from the RTL function)
    function [15:0] exp_ident(input integer i, input integer c,
                              input integer h, input integer s,
                              input integer total);
        integer cap;
        begin
            cap = c * h * s;
            case (i)
                0:  exp_ident = 16'h0040;
                1:  exp_ident = c[15:0];
                3:  exp_ident = h[15:0];
                4:  exp_ident = (512 * s) & 16'hFFFF;
                5:  exp_ident = 512;
                6:  exp_ident = s[15:0];
                10: exp_ident = {"S", "/"};
                11: exp_ident = {"N", ":"};
                12: exp_ident = {"0", "0"};
                13: exp_ident = {"2", " "};
                20: exp_ident = 3;
                21: exp_ident = 512;
                22: exp_ident = 4;
                23: exp_ident = {"v", "0"};
                24: exp_ident = {".", "0"};
                25: exp_ident = {"1", " "};
                27: exp_ident = {"B", "K"};
                28: exp_ident = {"E", "M"};
                29: exp_ident = {"U", " "};
                30: exp_ident = {"H", "D"};
                31: exp_ident = {"D", " "};
                47: exp_ident = 16'h8010;
                48: exp_ident = 1;
                49: exp_ident = 16'h0200;
                51: exp_ident = 16'h0200;
                53: exp_ident = 1;
                54: exp_ident = c[15:0];
                55: exp_ident = h[15:0];
                56: exp_ident = s[15:0];
                57: exp_ident = cap[15:0];
                58: exp_ident = cap[31:16];
                60: exp_ident = total[15:0];
                61: exp_ident = total[31:16];
                default:
                    // string padding fields are "  "; the rest 0
                    if ((i >= 14 && i <= 19) || i == 26
                        || (i >= 32 && i <= 46))
                        exp_ident = {" ", " "};
                    else
                        exp_ident = 16'h0000;
            endcase
        end
    endfunction

    // run IDENTIFY and check the whole block (per-word status contract)
    task run_identify(input integer c, input integer h, input integer s,
                      input integer total);
        integer i;
        logic [15:0] v, w;
        begin
            w_word(A_COMP0, 16'h00EC);
            poll_drq;
            for (i = 0; i < 256; i = i + 1) begin
                r_word(A_COMP0, v);
                chk(v[7:0], 8'h58, "IDENTIFY status during");
                r_word(A_DATA, w);
                chk(w, exp_ident(i, c, h, s, total), "IDENTIFY word");
            end
            r_word(A_COMP0, v);
            chk(v[7:0], 8'h50, "IDENTIFY status after");
        end
    endtask

    // read one 256-word block (assumes DRQ), compare vs the model sector;
    // one mid-block status check pins DRQ held across the whole block
    task drain_sector(input integer sec);
        integer w;
        logic [15:0] dv, sv;
        begin
            for (w = 0; w < 256; w = w + 1) begin
                if (w == 128) begin
                    r_word(A_COMP0, sv);
                    chk(sv[7:0], 8'h58, "mid-block status");
                end
                r_word(A_DATA, dv);
                if (dv !== `DISK[sec * 256 + w]) begin
                    errors = errors + 1;
                    $display("IDE-ERROR sector %0d word %0d: %04x != %04x",
                             sec, w, dv, `DISK[sec * 256 + w]);
                end
            end
        end
    endtask

    function [15:0] wpat(input integer s, input integer w);
        wpat = (s * 7 + w * 3 + 16'h9999) & 16'hFFFF;
    endfunction

    // fill one 256-word block via the DATA port (assumes DRQ); the stored
    // word IS the core-side value the task delivers
    task fill_sector(input integer sec);
        integer w;
        begin
            for (w = 0; w < 256; w = w + 1)
                w_word(A_DATA, wpat(sec, w));
        end
    endtask

    integer i, s, n;
    logic [15:0] v, v2, dv;
    integer fails_at;

    initial begin
        $readmemh("ide_image.hex", `DISK);

        // ---- leg 0: attach + reset snapshot -----------------------------
        media = 1'b1;
        repeat (10) @(posedge sclk);
        reset = 1'b0;
        // geometry parse: fetch + ~800 cycles; wait generously
        repeat (AWAIT0) @(posedge sclk);

        r_word(A_COMP0, v);
        chk(v[7:0], 8'h40, "reset STATUS");
        chk(v[15:8], 8'h32, "reset DRIVE-ADDR");     // 0x30|DS1, head 0
        r_word(A_COMP1, v);
        chk(v[7:0], 8'hA0, "reset DHR");
        chk(v[15:8], 8'h40, "reset ALT-STATUS");
        r_word(A_ERR, v);   chk(v, 16'h0001, "reset ERROR");
        r_word(A_CYLLO, v); chk(v, 16'h0000, "reset CYL_LO");
        r_word(A_CYLHI, v); chk(v, 16'h0000, "reset CYL_HI");
        r_word(A_SNUM, v);  chk(v, 16'h0001, "reset SNUM");
        r_word(A_COUNT, v); chk(v, 16'h0001, "reset COUNT");

        // the raw inversion pin: bus value must be ~core value
        ad_oe = 1'b1; ad_drive = ~A_COMP0;
        #6 sync_n = 1'b0; #6 ad_oe = 1'b0; din_n = 1'b0;
        repeat (4) @(posedge sclk);
        chk(ide_rdata, 16'hCDBF, "raw bus inversion");   // = ~16'h3240
        #2 din_n = 1'b1; #6 sync_n = 1'b1;
        repeat (2) @(posedge sclk);

        // ---- leg 1: absent slave ----------------------------------------
        w_word(A_COMP1, 16'h0010);              // DHR DRV=1 -> slave
        r_word(A_COMP0, v); chk(v, 16'h0000, "slave STATUS (absent)");
        r_word(A_COMP1, v); chk(v, 16'h0000, "slave DHR (absent)");
        r_word(A_SNUM, v);  chk(v, 16'h0000, "slave SNUM (absent)");
        w_word(A_COMP0, 16'h00EC);              // IDENTIFY: must be ignored
        repeat (50) @(posedge sclk);
        r_word(A_COMP0, v); chk(v, 16'h0000, "slave cmd ignored");
        w_word(A_COMP1, 16'h0000);              // back to master
        r_word(A_COMP0, v); chk(v[7:0], 8'h40, "master restored");

        // ---- leg 2: SRST + the 742/743 lane split -----------------------
        w_byte(16'o177743, 8'h04);              // control: SRST assert
        r_word(A_COMP0, v); chk(v[7:0], 8'h80, "SRST asserted -> BSY");
        w_byte(16'o177743, 8'h00);              // release -> full re-init
        r_word(A_COMP0, v); chk(v[7:0], 8'h40, "SRST released -> DRDY");
        r_word(A_ERR, v);   chk(v, 16'h0001, "SRST ERROR re-seeded");
        r_word(A_COMP1, v); chk(v[7:0], 8'hA0, "SRST DHR re-seeded");
        // word write at exact 742 must hit DHR (head nibble), NOT control
        w_word(A_COMP1, 16'h0005);              // head=5
        r_word(A_COMP1, v); chk(v[7:0], 8'hA5, "DHR via word 742");
        r_word(A_COMP0, v);
        chk(v[15:8], 8'h32 | (8'h05 << 2), "DAR head bits");
        w_word(A_COMP1, 16'h0000);              // head back to 0

        // ---- leg 3: command lane rules ----------------------------------
        w_word(A_COMP0, 16'h0077);              // garbage opcode, exact 740
        r_word(A_COMP0, v); chk(v[7:0], 8'h41, "ABRT status");
        r_word(A_ERR, v);   chk(v, 16'h0004, "ABRT error");
        w_byte(16'o177743, 8'h04); w_byte(16'o177743, 8'h00);   // recover
        r_word(A_COMP0, v); chk(v[7:0], 8'h40, "recovered");
        w_byte(16'o177741, 8'hEC);              // byte 741: IGNORED
        repeat (50) @(posedge sclk);
        r_word(A_COMP0, v); chk(v[7:0], 8'h40, "741 write ignored");

        // ---- leg 4: IDENTIFY --------------------------------------------
        run_identify(CYLS, HEADS, SECS, TOTAL);

        // ---- leg 5: single-sector read of EVERY sector ------------------
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 1);
        for (s = 0; s < TOTAL; s = s + 1) begin
            w_word(A_COUNT, 1);
            w_word(A_COMP0, 16'h0020);          // READ
            poll_drq;
            drain_sector(s);
            // CHS auto-advance spot checks at the wrap boundaries
            if (s == 0) begin
                r_word(A_SNUM, v); chk(v, 16'h0002, "CHS +1: snum");
            end
            if (s == SECS - 1) begin            // S-wrap: head 0 -> 1
                r_word(A_SNUM, v);  chk(v, 16'h0001, "S-wrap snum");
                r_word(A_COMP1, v); chk(v[7:0], 8'hA1, "S-wrap head");
            end
            if (s == SECS * HEADS - 1) begin    // H-wrap: cyl 0 -> 1
                r_word(A_COMP1, v); chk(v[7:0], 8'hA0, "H-wrap head");
                r_word(A_CYLLO, v); chk(v, 16'h0001, "H-wrap cyl");
            end
        end
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "read-all end status");

        // ---- leg 6: multi-sector read (COUNT=0 => 256) ------------------
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 2);  // start at index 1
        w_word(A_COUNT, 0);
        w_word(A_COMP0, 16'h0021);              // READ (no-retry flavour)
        for (s = 1; s <= 256; s = s + 1) begin
            poll_drq;
            drain_sector(s);
        end
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "multi-read end status");
        r_word(A_ERR, v);   chk(v, 16'h0000, "multi-read error clear");

        // ---- leg 6b: prefetch overlap (COUNT=4 chain) -------------------
        // sector 0 drains from bank 0 while sector 1 prefetches into bank 1;
        // the visible CHS must show sector 1 throughout (advanced at
        // drain-start, NEVER at the prefetch's own bk_done), and (disk pass)
        // there is no BSY window at the sector boundary since the fast disk
        // model always beats the drain. Exactly ONE backend op per sector.
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 1);      // start sector 0 (index 0)
        ack_base = ack_cnt;
        w_word(A_COUNT, 4);
        w_word(A_COMP0, 16'h0020);                  // READ
        poll_drq;
        // drain sector 0, checking SNUM mid-block: it must still read sector
        // 1's value (2) even after the sector-1 prefetch has completed in
        // the background - the "visible advance at prefetch-done" catch
        for (n = 0; n < 256; n = n + 1) begin
            if (n == 200) begin
                r_word(A_SNUM, v);
                chk(v, 16'h0002, "6b SNUM held at sector-1 value mid-drain");
            end
            r_word(A_DATA, dv);
            if (dv !== `DISK[0 * 256 + n]) begin
                errors = errors + 1;
                $display("IDE-ERROR 6b sector 0 word %0d: %04x != %04x",
                         n, dv, `DISK[0 * 256 + n]);
            end
        end
`ifndef SD_STACK
        r_word(A_COMP0, v);                         // prefetch beat the drain:
        chk(v[7:0], 8'h58, "6b no-BSY at boundary");// DRQ already up, no BSY
`endif
        poll_drq; drain_sector(1);
        poll_drq; drain_sector(2);
        poll_drq; drain_sector(3);
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "6b end status");
        chk(ack_cnt - ack_base, 4, "6b backend op count (one per sector)");

`ifndef SD_STACK
        // ---- leg 6c: drain-finishes-first (slow backend) ----------------
        // a slow disk model so the CPU drain outruns the prefetch: a genuine
        // BSY window opens at the boundary, then the swap raises DRQ.
        u_disk.lat_extra = 5000;
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 1);
        w_word(A_COUNT, 3);
        w_word(A_COMP0, 16'h0020);
        poll_drq;
        drain_sector(0);
        r_word(A_COMP0, v);
        chk(v[7:0], 8'h80, "6c BSY while the slow prefetch is in flight");
        poll_drq; drain_sector(1);
        poll_drq; drain_sector(2);
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "6c end status");
        u_disk.lat_extra = 0;
`endif

        // ---- leg 6d: mid-drain hazards ----------------------------------
        // after poll_drq the next sector's prefetch is reliably in flight;
        // each hazard must route through E_FLUSH and recover cleanly.

        // d1: a fresh COMMAND mid-chain (abandon the stale prefetch)
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 2);      // sector 1 (index 1)
        w_word(A_COUNT, 2);
        w_word(A_COMP0, 16'h0020);
        poll_drq;                                   // sector-2 prefetch in flight
        w_word(A_SNUM, 4); w_word(A_COUNT, 1);      // new READ: sector 3
        w_word(A_COMP0, 16'h0020);
        poll_drq;
        drain_sector(3);
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "6d d1 fresh-command end");

        // d2: SRST mid-chain, then the snapshot contract, then a clean READ
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 1);
        w_word(A_COUNT, 4);
        w_word(A_COMP0, 16'h0020);
        poll_drq;                                   // sector-1 prefetch in flight
        w_byte(16'o177743, 8'h04);                  // SRST assert
        w_byte(16'o177743, 8'h00);                  // release -> full re-init
        r_word(A_COMP0, v); chk(v[7:0], 8'h40, "6d d2 SRST snapshot STATUS");
        r_word(A_ERR, v);   chk(v, 16'h0001, "6d d2 SRST ERROR");
        r_word(A_SNUM, v);  chk(v, 16'h0001, "6d d2 SRST SNUM");
        w_word(A_SNUM, 1); w_word(A_COUNT, 1);
        w_word(A_COMP0, 16'h0020);                  // clean READ (flushes op)
        poll_drq;
        drain_sector(0);
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "6d d2 post-SRST read end");

        // d3: a WRITE dispatched mid-READ-chain (fill must not land in a
        // backend-owned write port); backing store proves the fill landed
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 1);
        w_word(A_COUNT, 4);
        w_word(A_COMP0, 16'h0020);                  // READ chain
        poll_drq;                                   // sector-1 prefetch in flight
        w_word(A_SNUM, 11); w_word(A_COUNT, 1);     // WRITE sector 10 (index 10)
        w_word(A_COMP0, 16'h0030);
        poll_drq;                                   // DRQ up after the flush
        fill_sector(10);
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "6d d3 WRITE end status");
        for (i = 0; i < 256; i = i + 1)
            if (`DISK[10 * 256 + i] !== wpat(10, i)) begin
                errors = errors + 1;
                $display("IDE-ERROR 6d d3 wr sector 10 word %0d: %04x != %04x",
                         i, `DISK[10 * 256 + i], wpat(10, i));
            end

        // ---- leg 7: writes ----------------------------------------------
        for (s = 0; s < 8; s = s + 1) begin     // single-sector writes
            w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
            w_word(A_COMP1, 0); w_word(A_SNUM, s + 1);
            w_word(A_COUNT, 1);
            w_word(A_COMP0, 16'h0030);          // WRITE
            poll_drq;
            fill_sector(s);
            poll_idle;
            r_word(A_COMP0, v); chk(v[7:0], 8'h50, "write end status");
            for (i = 0; i < 256; i = i + 1)
                if (`DISK[s * 256 + i] !== wpat(s, i)) begin
                    errors = errors + 1;
                    $display("IDE-ERROR wr sector %0d word %0d: %04x != %04x",
                             s, i, `DISK[s * 256 + i], wpat(s, i));
                end
        end
        // read-back round trip (bus-inversion pair closes)
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 0); w_word(A_SNUM, 3);
        w_word(A_COUNT, 1);
        w_word(A_COMP0, 16'h0020);
        poll_drq;
        drain_sector(2);
        // multi-sector write: sectors 16..23 (cyl 0, head 1)
        w_word(A_CYLLO, 0); w_word(A_CYLHI, 0);
        w_word(A_COMP1, 1);                     // head=1 -> index 16
        w_word(A_SNUM, 1);
        w_word(A_COUNT, 8);
        w_word(A_COMP0, 16'h0031);              // WRITE (no-retry flavour)
        for (s = 16; s < 24; s = s + 1) begin
            poll_drq;
            fill_sector(s);
        end
        poll_idle;
        r_word(A_COMP0, v); chk(v[7:0], 8'h50, "multi-write end status");
        for (s = 16; s < 24; s = s + 1)
            for (i = 0; i < 256; i = i + 1)
                if (`DISK[s * 256 + i] !== wpat(s, i)) begin
                    errors = errors + 1;
                    $display("IDE-ERROR mwr sector %0d word %0d", s, i);
                end
        w_word(A_COMP1, 0);                     // head back to 0

        // ---- leg 8: ABRT ------------------------------------------------
        w_word(A_COMP0, 16'h00C4);              // READ MULTIPLE: unsupported
        r_word(A_COMP0, v); chk(v[7:0], 8'h41, "ABRT 0xC4");
        r_word(A_ERR, v);   chk(v, 16'h0004, "ABRT 0xC4 error");
        w_word(A_COMP1, 16'h0040);              // LBA bit
        w_word(A_COUNT, 1); w_word(A_SNUM, 1);
        w_word(A_COMP0, 16'h0020);
        r_word(A_COMP0, v); chk(v[7:0], 8'h41, "ABRT LBA bit");
        w_word(A_COMP1, 16'h0000);
        w_byte(16'o177743, 8'h04); w_byte(16'o177743, 8'h00);

        // ---- leg 10: geometry fallback (DCLO replays) -------------------
        // (leg 9, data-hold, rides inside every r_word)
        reset = 1'b1; media = 1'b0;
        repeat (10) @(posedge sclk);
        $readmemh("ide_image.hex", `DISK);              // pristine image
        $readmemh("ide_sector7_bad.hex", `DISK, 7 * 256, 7 * 256 + 255);
        total_in = 2016;                        // default C = 2016/1008 = 2
        media = 1'b1;
        reset = 1'b0;
        repeat (AWAIT) @(posedge sclk);         // parse + C-divide loop
        r_word(A_COMP0, v);
        chk(v[7:0], 8'h40, "fallback attach STATUS");
        run_identify(2, 16, 63, 2016);

        // replay with total too small for even one default cylinder:
        // attach fails (BkEmu throws) -> drive stays absent
        reset = 1'b1; media = 1'b0;
        repeat (10) @(posedge sclk);
        total_in = 640;
        media = 1'b1;
        reset = 1'b0;
        repeat (AWAIT) @(posedge sclk);
        r_word(A_COMP0, v); chk(v, 16'h0000, "zero-C attach fails: absent");
        w_word(A_COMP0, 16'h00EC);
        repeat (50) @(posedge sclk);
        r_word(A_COMP0, v); chk(v, 16'h0000, "zero-C cmd ignored");

        // ---- verdict ----------------------------------------------------
        if (!overlap_seen) begin
            errors = errors + 1;
            $display("IDE-ERROR prefetch overlap never observed @%0t", $time);
        end
        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #WDOG_NS;                               // clean runs: ~27 ms disk-model,
                                                // SPI-real in the SD pass
        $display("IDE-ERROR watchdog timeout");
        $display("COSIM FAIL");
        $finish;
    end

endmodule
