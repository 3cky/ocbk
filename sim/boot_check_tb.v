//
// Phase-5 MONITOR/BASIC boot smoke cosim (slow, manual - run_boot_check.sh,
// NOT part of make sim).
//
// The REAL BK-0010.01 ROM blob (mem/boot_blob_flash.hex) is preloaded directly
// into the SDRAM model ROM region (the EPCS loader path has its own gates:
// run_epcs_boot.sh + the ref037 +bootload golden run) and the full SoC - CPU,
// va_037_sync, qbus_mem, complete video pipeline on all 4 arbiter ports -
// cold-boots the actual MONITOR. Bounded checks, cheapest first:
//
//   1. no-X on the Q-bus data/reply at every read-reply point (backstops the
//      177700-177713 CPU-internal decode fix - a bus fight shows as X);
//   2. the CPU starts writing the video RAM (040000-077777) within the bound
//      and keeps going (the MONITOR screen clear) - >= VID_TARGET writes;
//   3. a bus-transaction trace of the first TRACE_N cycles is dumped to
//      boot_trace.txt for one-off manual diffing vs a BkEmu-side trace
//      (diagnostic aid, not a gate).
//
// +warmreset (Phase-5.5 soft reset): once the cold screen clear is underway,
// DCLO/ACLO are re-pulsed mid-run (the reset button; SDRAM contents stay, and
// the 037 + fb_video are NOT reset - power-on only, the display free-runs
// across the reset as on a real BK; the release is deliberately raster-
// unsynced here, the authentic arbitrary phase). The run must then see (a) the
// no-X checks stay clean, (b) a second 177716 start-vector read, and (c) a
// second full screen-clear burst - the real MONITOR warm-reboots. Roughly
// doubles the runtime.
//
// +bk11 (Phase 7): cold-boot the real BK-0011M BOS instead - model_bk11=1,
// the /24 (4.03 MHz) CPU clock, the bk11 ROM blob (boot_blob11_flash.hex)
// preloaded at SDRAM words 0x30000+ (window banks + top ROM), the 177662
// taps driving the fb_video base/palette mux and the EVNT/IRQ2 replica as in
// ocbk_top. Checks: the first 177716 read must reply the 140000 start vector
// (bits 15:14 = 11), then BOS activity = at least one replied 177662 write
// AND the >= VID_TARGET video-RAM writes (BOS clears its screen page through
// window 0, so the 040000-077777 bus-address window still catches it).
// VID_TARGET and the 60 ms bound are tunables - adjust if BOS's real startup
// profile (e.g. a RAM test before the clear) needs it. +warmreset is
// bk10-only for now (ignored under +bk11).
//
// +smk10 (Phase 8, bk10+SMK): the same real-SMK-BIOS cold boot on a BK-0010
// stack (BkEmu BK_0010_SMK512) - model_bk11=0, the /32 CPU rate, the bk10 ROM
// blob (the monitor ROM is what mon_en selects at segs 0,1) plus the bk11
// blob purely for the BIOS image at 0x3A000. Pass conditions as +smk MINUS
// the 177662 write: on a BK-0010 that write must NOT reply - it is the BIOS's
// own model detect (doc/smk64.mac START: trap 4 -> the MODE_STD10 commit).
//
// +smk (Phase 8): cold-boot the REAL SMK512 BIOS - +bk11 stack plus
// smk_en=1, the 43008-word blob incl. the BIOS image at SDRAM 0x3A000, a
// deepened SDRAM model (SMK RAM at 0x40000+, left zeroed - real hardware
// powers on garbage there), and - since the IDE increment - the LIVE
// smk_ide + ide_disk_model with the gen_ide_image.py AltPro image
// attached. Checks the boot end-to-end: the first 177716 read must carry
// the merged 166400 vector (rom7 register-space overlay | SEL1), then
// >= SMK_FETCH_TARGET DIN fetches from the rom6 window (the BIOS
// EXECUTING from ROM), then the BIOS's OWN banner (its 177662 write +
// the video-RAM burst - lands after its ~150 ms SOB startup delay, hence
// the longer +smk time bound), no X throughout with the sel_ide decode
// active. The BIOS's actual DRIVE probe is deliberately NOT required:
// smk64.mac routes every boot path through INIT -> EMT 0 = the full BOS
// re-init incl. the multi-second БК memory test BEFORE ZAGHDD/BOOT0
// touch the task file - out of reach for a sim oracle (>400 ms sim even
// with the +fastdelay ROM patch). The drive-engine contract is pinned by
// sim/ide (the same PARTRD/RWSEC sequences, transcribed from BkEmu); the
// real BIOS reading a real image is the increment-(b) HARDWARE milestone.
// Debug aids: +fastdelay NOPs the startup SOB (ROM-patching - never part
// of a check), +idetrace prints I/O-page accesses + a 1 ms PC sampler.
//
// Prints BOOTCHK-* lines; run_boot_check.sh greps for the final verdict.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module boot_check_tb;

    localparam int AB = 24;
    localparam int DW = 16;
    localparam integer VID_TARGET = 200;    // video-RAM writes to declare victory
    localparam integer TRACE_N    = 5000;   // bus transactions to dump
    // +smk: DIN fetches from the rom6 BIOS window required (with the banner
    // checks - see the header; the drive probe itself is out of sim reach)
    localparam integer SMK_FETCH_TARGET = 200;

    // ---- model select (+bk11 = BK-0011M BOS boot; +smk = BK-0011M + SMK512,
    //      boots the REAL SMK BIOS through the 177716 overlay; +smk10 = the
    //      same SMK BIOS boot on a BK-0010 stack - BkEmu BK_0010_SMK512, the
    //      bk10 ROM blob with the monitor at 100000 and the SMK covering the
    //      rest of the ROM window). NOTE $test$plusargs is a PREFIX match, so
    //      +smk10 satisfies $test$plusargs("smk") too - that is what makes
    //      `smk` true for both legs. -----------------------------------------
    reg model11, smk, smk10;
    initial begin
        smk10   = $test$plusargs("smk10");
        smk     = $test$plusargs("smk");
        model11 = ($test$plusargs("bk11") || smk) && !smk10;
    end

    // ---- clocks (as ref037_soc_video_tb / bk11_soc_tb) --------------------------
    // 037 CLKIN enables on the fixed /16 chain; CPU clock = cpu_clkgen replica
    // (/32 bk10 - identical to the old divc[4] tap - or /24 bk11).
    reg       sys_clk;
    reg [3:0] divc;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 4'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc == 4'd15);
    wire en_neg = (divc == 4'd7);

    reg [3:0] cdiv;
    reg       cpu_clk_r;
    initial begin cdiv = 4'd0; cpu_clk_r = 1'b0; end
    always @(posedge sys_clk) begin
        if (cdiv >= (model11 ? 4'd11 : 4'd15)) begin
            cdiv <= 4'd0; cpu_clk_r <= ~cpu_clk_r;
        end else
            cdiv <= cdiv + 1'b1;
    end
    wire clk = cpu_clk_r;

    reg pix_clk = 1'b0;
    always #7.5 pix_clk = ~pix_clk;

    // ---- Q-bus ----------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;   // power-on reset for the VIDEO side (037 + fb_video):
                             // never re-asserted - real-BK display fidelity
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg dmgi, sp;   reg [1:0] pa;
    tri1        virq;  // open-collector: bk_kbd014 requests, vm1 samples
    wire        n_irq2;  // EVNT/IRQ2 replica (assigned below; idle 1 in bk10)
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU -------------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(pa), .pin_sp_n(sp),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n({irq[3], n_irq2, irq[1]}), .pin_virq_n(virq),
        .pin_ad_n(ad), .pin_dout_n(dout), .pin_din_n(din),
        .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
        .pin_dmr_n(dmr), .pin_sack_n(sack), .pin_dmgi_n(dmgi),
        .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel), .pin_bsy_n(bsy)
    );

    // ---- retimed 037 -------------------------------------------------------------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        mem_ext_ram;   // window-1 banked RAM -> 037 a15 force (from u_ms; 0 in bk10)
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready),
        .ext_ram(mem_ext_ram),
        .PIN_R(~dclo_cold), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate)
    );

    // ---- keyboard controller (Phase 6; MONITOR polls 177660/177662) ------------
    // Key events idle: the boot smoke checks the register/no-X behaviour only.
    // (An earlier attempt injected a held boot key under +smk to reach the
    // BIOS's HDD probe - see the +smk note in the header: the probe sits
    // behind the multi-second EMT-0 memory test, out of sim reach.)
    bk_kbd014 u_kbd (
        .clk_fsm(~clk), .clk_p(clk), .init_n(init),
        .ad_n(ad), .sync_n(sync), .din_n(din), .dout_n(dout),
        .cs_n(va_nbs), .iako_n(iako), .rply_n(rply), .virq_n(virq),
        .key_stb(1'b0), .key_code(7'b0), .key_ar2(1'b0), .key_down(1'b0)
    );

    // ---- real video pipeline (ports 1/2/3) ----------------------------------------
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [AB-1:0] f_addr, w_addr;
    wire [DW-1:0] w_wdata;
    wire [DW-1:0] arb_rdata;
    wire        fb_front, fb_front_valid;

    // 177662 taps (qbus_mem) + the ocbk_top vram_base/pal_idx mux replica
    wire        vid_page, vid_irq2m;
    wire [3:0]  vid_pal;
    localparam [23:0] VPAGE0 = 24'h022000;   // qbus_pkg BK11_VPAGE0 (RAM page 1)
    localparam [23:0] VPAGE1 = 24'h02E000;   // qbus_pkg BK11_VPAGE1 (RAM page 7)

    fb_video #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_fbv (
        .clk(sys_clk), .rst_n(dclo_cold), .blank_req(1'b0), .screen_mode(1'b1),
        .vram_base(model11 ? (vid_page ? VPAGE1 : VPAGE0) : 24'h002000),
        .pal_idx(model11 ? vid_pal : 4'd0),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate), .video_va(video_va),
        .f_req(f_req), .f_addr(f_addr), .f_gnt(f_gnt), .f_rvalid(f_rvalid),
        .rdata_i(arb_rdata),
        .w_req(w_req), .w_addr(w_addr), .w_wdata(w_wdata), .w_gnt(w_gnt),
        .fb_front(fb_front), .fb_front_valid(fb_front_valid),
        .err_fetch_ovr(), .err_fifo_ovf()
    );

    wire        init_done;
    reg  [1:0]  prst_sr = 2'b00;
    wire        prst_n  = prst_sr[1];
    always @(posedge pix_clk) prst_sr <= {prst_sr[0], init_done};
    wire        ro_rst_n = srst_n & init_done;

    wire        req_tgl;
    wire [7:0]  req_line;
    wire        lb_we;
    wire [9:0]  lb_waddr, lb_raddr;
    wire [3:0]  lb_wdata, lb_rdata;
    wire        ro_req, ro_gnt, ro_rvalid;
    wire [AB-1:0] ro_addr;

    vga_out u_vga (
        .clk(pix_clk), .rst_n(prst_n),
        .lb_raddr(lb_raddr), .lb_rdata(lb_rdata),
        .req_tgl(req_tgl), .req_line(req_line),
        .fb_valid(fb_front_valid),
        .hsync(), .vsync(), .r(), .g(), .b()
    );
    fb_linebuf u_lb (
        .wclk(sys_clk), .we(lb_we), .waddr(lb_waddr), .wdata(lb_wdata),
        .rclk(pix_clk), .raddr(lb_raddr), .rdata(lb_rdata)
    );
    fb_readout #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_ro (
        .clk(sys_clk), .rst_n(ro_rst_n),
        .req_tgl(req_tgl), .req_line(req_line), .fb_front(fb_front),
        .p_req(ro_req), .p_addr(ro_addr), .p_gnt(ro_gnt), .p_rvalid(ro_rvalid),
        .rdata_i(arb_rdata),
        .lb_we(lb_we), .lb_waddr(lb_waddr), .lb_wdata(lb_wdata),
        .err_line_ovr()
    );

    // ---- SMK512 IDE device + tb disk (live under +smk) -----------------------
    // The Phase-8 IDE increment: the real smk_ide fronted by the behavioral
    // disk model loaded with the synthetic AltPro image (gen_ide_image.py).
    // Under +bk11/bk10 enable=0 keeps ide_rdata at 0 - identical to the old
    // tie-off. +nomedia (DEBUG) reproduces the increment-(a) HARDWARE
    // condition - the SD backend does not exist yet, media tied off: the
    // drive stays absent (reads 0xFFFF) and the BIOS's RDY polls time out.
    // +sdspi (increment (b)): the backend port is served by the REAL
    // sd_backend + sd_model SPI stack (sd_harness) instead of the disk
    // model - proves attach + the AltPro geometry parse through the full
    // SD path under the real BIOS boot. Runtime-muxed (both backends see
    // the requests; only the selected one's replies reach the engine) so
    // one compile serves every leg.
    wire        smk_media = smk && !$test$plusargs("nomedia");
    wire        use_sd    = $test$plusargs("sdspi") != 0;
    wire [15:0] ide_rdata;
    wire        bk_req, bk_wr, bk_bank, bk_we;
    wire [27:0] bk_sector;
    wire [7:0]  bk_baddr;
    wire [15:0] bk_wdata, bk_rdata;
    wire        dm_ack, dm_done, dm_error, dm_media_ok, dm_we;
    wire [27:0] dm_total;
    wire [7:0]  dm_baddr;
    wire [15:0] dm_wdata;
    wire        sd_ack, sd_done, sd_error, sd_media_ok, sd_we;
    wire [27:0] sd_total;
    wire [7:0]  sd_baddr;
    wire [15:0] sd_wdata;
    wire        bk_ack      = use_sd ? sd_ack      : dm_ack;
    wire        bk_done     = use_sd ? sd_done     : dm_done;
    wire        bk_error    = use_sd ? sd_error    : dm_error;
    wire        bk_media_ok = use_sd ? sd_media_ok : dm_media_ok;
    wire [27:0] bk_total    = use_sd ? sd_total    : dm_total;
    assign      bk_baddr    = use_sd ? sd_baddr    : dm_baddr;
    assign      bk_wdata    = use_sd ? sd_wdata    : dm_wdata;
    assign      bk_we       = use_sd ? sd_we       : dm_we;

    smk_ide u_ide (
        .sclk(sys_clk), .reset(~dclo), .enable(smk),
        .ad_n(ad), .sync_n(sync), .din_n(din), .dout_n(dout), .wtbt_n(wtbt),
        .ide_rdata(ide_rdata), .ide_act(),
        .bk_req(bk_req), .bk_wr(bk_wr), .bk_sector(bk_sector),
        .bk_bank(bk_bank), .bk_ack(bk_ack), .bk_done(bk_done),
        .bk_error(bk_error), .bk_media_ok(bk_media_ok), .bk_total(bk_total),
        .bk_baddr(bk_baddr), .bk_wdata(bk_wdata), .bk_we(bk_we),
        .bk_rdata(bk_rdata)
    );

    ide_disk_model #(.MAX_SECTORS(640), .LATENCY(24)) u_disk (
        .sclk(sys_clk), .rst(~dclo),
        .media_in(smk_media && !use_sd), .total_in(28'd640),
        .bk_req(bk_req), .bk_wr(bk_wr), .bk_sector(bk_sector),
        .bk_bank(bk_bank), .bk_ack(dm_ack), .bk_done(dm_done),
        .bk_error(dm_error), .bk_media_ok(dm_media_ok), .bk_total(dm_total),
        .bk_baddr(dm_baddr), .bk_wdata(dm_wdata), .bk_we(dm_we),
        .bk_rdata(bk_rdata)
    );

    sd_harness #(.MAX_SECTORS(640), .LATENCY(24)) u_sd (
        .sclk(sys_clk), .rst(~dclo),
        .media_in(smk_media && use_sd), .total_in(28'd640),
        .bk_req(bk_req), .bk_wr(bk_wr), .bk_sector(bk_sector),
        .bk_bank(bk_bank), .bk_ack(sd_ack), .bk_done(sd_done),
        .bk_error(sd_error), .bk_media_ok(sd_media_ok), .bk_total(sd_total),
        .bk_baddr(sd_baddr), .bk_wdata(sd_wdata), .bk_we(sd_we),
        .bk_rdata(bk_rdata)
    );

    initial if ($test$plusargs("smk")) begin
        $readmemh("ide/ide_image.hex", u_disk.disk);
        $readmemh("ide/ide_image.hex", u_sd.u_card.card);
    end

    // +fastdelay: DEBUG aid for +smk iteration - NOP the BIOS's startup SOB
    // (CPU 166406 = image byte 0o6406) so the ~100 ms delay loop runs once,
    // AND shrink the RDY drive-readiness timeout (MOV #1500,R5 at CPU
    // 166230 -> #2: the nested 1500x1500 SOB wait becomes ~instant - the
    // no-drive path's 2-3.7 s timeouts are what make the real flow take
    // ~10 s). Never use for the real check (it edits the ROM under test).
    initial if ($test$plusargs("fastdelay")) begin
        #1;
        u_mem.mem['h3A000 + (16'o6406 >> 1)] = 16'o000240;
        u_mem.mem['h3A000 + (16'o6232 >> 1)] = 16'o000002;
    end

    // +idetrace: DEBUG aid - I/O-page accesses (capped) + a 1 ms
    // where-is-it-executing sampler off the latched bus address.
    integer itr_n = 0;
    initial if ($test$plusargs("idetrace")) fork
        forever @(negedge din)
            if (~sync && addr >= 16'o177000 && itr_n < 400) begin
                itr_n = itr_n + 1;
                $display("IDETRC R %06o t=%0t", addr, $time);
            end
        forever @(negedge dout)
            if (~sync && addr >= 16'o177000 && itr_n < 400) begin
                itr_n = itr_n + 1;
                $display("IDETRC W %06o <= %06o t=%0t", addr, ~ad, $time);
            end
        forever begin
            #1_000_000;
            $display("IDETRC PC~ %06o t=%0t", addr, $time);
        end
    join

    // ---- integration module + SDRAM model ------------------------------------------
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;

    qbus_mem u_ms (
        .cpu_clk  (~clk),
        .reset    (~dclo),
        .ide_rdata(ide_rdata),
        .init_n   (init),            // peripheral-register reset (Phase 6)
        .kbd_down (1'b0),            // keyboard idle in the boot smoke
        .tape_in  (1'b0),            // no tape signal in this oracle
        .sel1_n   (sel[1]),          // CPU nSEL1/nSEL2 register selects
        .sel2_n   (sel[2]),
        .model_bk11(model11),        // bk10 pass-through, or +bk11 banking
        .smk_en(smk),                // +smk only (never floating: X would poison)
        .boot_active(1'b0),
        .bw_req   (1'b0),
        .bw_addr  ({AB{1'b0}}),
        .bw_wdata ({DW{1'b0}}),
        .bw_gnt   (),
        .sclk     (sys_clk),
        .srst_n   (srst_n),
        .init_done(init_done),
        .ad_n     (ad),
        .sync_n   (sync),
        .din_n    (din),
        .dout_n   (dout),
        .wtbt_n   (wtbt),
        .rply_n   (rply),
        .mem_ready(mem_ready),
        .ext_ram  (mem_ext_ram),
        .v1_req   (ro_req),  .v1_addr(ro_addr),  .v1_gnt(ro_gnt), .v1_rvalid(ro_rvalid),
        .v2_req   (f_req),   .v2_addr(f_addr),   .v2_gnt(f_gnt),  .v2_rvalid(f_rvalid),
        .v3_req   (w_req),   .v3_addr(w_addr),   .v3_wdata(w_wdata), .v3_gnt(w_gnt),
        .v_rdata  (arb_rdata),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
        .bus_addr (),
        .fetch_stb(),
        .vid_page (vid_page),
        .vid_irq2_mask(vid_irq2m),
        .vid_pal  (vid_pal)
    );

    // ---- EVNT/IRQ2: the REAL detector (Phase 9; idle in bk10) ----------------
    // src/bk_evnt.sv, instantiated rather than replicated - so a boot smoke run
    // exercises the same detector the board will fit. Real BOS unmasks 662
    // bit 14, so this leg actually drives the frame interrupt during the run.
    wire      irq2_lvl;
    reg [1:0] irq2_sr;
    initial   irq2_sr = 2'b00;
    bk_evnt evnt (
        .sys_clk(sys_clk), .rst_n(dclo_cold),
        .wti(va_wti), .synco(va_vsync),
        .irq_en(model11 & ~vid_irq2m), .evnt(irq2_lvl)
    );
    always @(posedge clk) irq2_sr <= {irq2_sr[0], irq2_lvl};
    assign n_irq2 = ~irq2_sr[1];

    // deepened for +smk (SMK RAM = SDRAM 0x40000-0x7FFFF); harmless otherwise
    sdram_model #(.MEM_WORDS(1<<19)) u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- check 1: no X on data/reply at every read-reply point ---------------------
    integer xerrs = 0;
    always @(negedge rply) if (aclo === 1'b1) begin   // armed after CPU release
        #1;                                  // let the data settle at the reply edge
        if (!din) begin
            if (^ad === 1'bx && xerrs < 10) begin
                $display("BOOTCHK-X-ERROR: ad=%b addr=%06o t=%0t", ad, addr, $time);
                xerrs = xerrs + 1;
            end
        end
        if (rply === 1'bx && xerrs < 10) begin
            $display("BOOTCHK-X-ERROR: rply=X t=%0t", $time);
            xerrs = xerrs + 1;
        end
    end

    // ---- check 2 + 3: video-RAM writes + bus trace ----------------------------------
    integer vid_writes = 0;
    integer trace_cnt  = 0;
    integer tracef;
    reg     wr_seen;
    reg     saw_662w = 0;       // +bk11: BOS must write the 177662 video register
    always @(negedge rply) if (aclo === 1'b1) begin
        if (!dout && !wr_seen) begin
            wr_seen = 1;
            if (addr >= 16'o040000 && addr < 16'o100000) begin
                vid_writes = vid_writes + 1;
                if (vid_writes <= 4 || vid_writes == VID_TARGET)
                    $display("BOOTCHK: video-RAM write #%0d: [%06o] <= %06o t=%0t",
                             vid_writes, addr, ~ad, $time);
            end
            if (addr == 16'o177662 && !saw_662w) begin
                saw_662w = 1;
                $display("BOOTCHK: 177662 write: %06o t=%0t", ~ad, $time);
            end
            if (trace_cnt < TRACE_N) begin
                $fdisplay(tracef, "W %06o %06o", addr, ~ad);
                trace_cnt = trace_cnt + 1;
            end
        end
        if (!din && trace_cnt < TRACE_N) begin
            $fdisplay(tracef, "R %06o %06o", addr, ~ad);
            trace_cnt = trace_cnt + 1;
        end
    end
    always @(posedge dout) wr_seen = 0;

    // ---- +bk11 check: the first 177716 read must reply the 140000 vector -------
    // Sampled at DIN release: slaves hold read data past it (the pinned vm1
    // hold rule) - at RPLY-assert the qbus_mem I/O data enable may not have
    // caught up yet and only the 037's AD15 assist shows on the bus.
    reg vec_checked = 0;
    always @(posedge din) if (aclo === 1'b1 && addr == 16'o177716
                              && !vec_checked) begin
        vec_checked = 1;
        if (smk && (~ad & 16'o177400) !== 16'o166400) begin
            // the SMK boot hack: the rom7 overlay word ORs onto SEL1 and the
            // start PC must come out 166400 (inside the rom6 BIOS window)
            $display("BOOTCHK-VEC-ERROR: 177716 read = %06o, no 166400 SMK vector",
                     ~ad);
            xerrs = xerrs + 1;
        end else if (model11 && (~ad & 16'o140000) !== 16'o140000) begin
            $display("BOOTCHK-VEC-ERROR: 177716 read = %06o, no 140000 vector", ~ad);
            xerrs = xerrs + 1;
        end else if (model11)
            // the raw word is the merged SEL1 read (start | wflag | idle-kbd
            // 0o100 | tape); the CPU's start PC masks it with 177400
            $display("BOOTCHK: 177716 start-vector read = %06o (PC %06o)",
                     ~ad, (~ad) & 16'o177400);
    end

    // ---- +smk check: the BIOS must EXECUTE from the rom6 window ---------------
    integer bios_fetches = 0;
    always @(negedge din)
        if (aclo === 1'b1 && smk
            && addr >= 16'o160000 && addr < 16'o170000) begin
            bios_fetches = bios_fetches + 1;
            if (bios_fetches == 1 || bios_fetches == SMK_FETCH_TARGET)
                $display("BOOTCHK: SMK BIOS fetch #%0d at %06o", bios_fetches, addr);
        end

    // ---- +smk IDE observables (Phase-8 IDE increment; LOG-ONLY) ---------------
    // The device command byte is the RAW inverted bus low byte (invValue =
    // ad_n), so READ shows as 0x20/0x21 here (the BIOS writes #337).
    // NOT part of the pass condition: the BIOS's drive probe (ZAGHDD/BOOT0
    // -> PARTRD) runs only AFTER INIT's EMT 0 = the full BOS re-init incl.
    // the multi-second БК memory test - out of reach for a sim oracle (the
    // sweep alone is >400 ms sim even with +fastdelay). The drive-engine
    // contract is pinned by sim/ide (the same PARTRD/RWSEC command
    // sequences, transcribed from BkEmu); the real-BIOS-reads-the-drive
    // milestone lands on hardware with the increment-(b) SD backend.
    integer ide_data_reads = 0;
    integer ide_cmds       = 0;
    always @(negedge dout)
        if (aclo === 1'b1 && smk && ~sync && addr == 16'o177740) begin
            ide_cmds = ide_cmds + 1;
            $display("BOOTCHK: IDE command %02x at 177740", ad[7:0]);
        end
    always @(negedge din)
        if (aclo === 1'b1 && smk && ~sync && addr == 16'o177756)
            ide_data_reads = ide_data_reads + 1;

    // +smk pass: the merged start vector + the BIOS executing from rom6 +
    // the BIOS's own banner (662 write + the video-RAM burst) - all with
    // the LIVE smk_ide attached (media present), so the whole boot runs
    // against the sel_ide decode with the no-X monitors armed.
    always @(posedge clk) begin
        // +smk10: no 662 write in the pass condition - on a BK-0010 that
        // write is exactly what must NOT reply (it is the BIOS's own model
        // detect: 177662 bus-times-out -> trap 4 -> the MODE_STD10 commit).
        if (smk && bios_fetches >= SMK_FETCH_TARGET
            && (saw_662w || smk10) && vid_writes >= VID_TARGET) begin
            if (!vec_checked) begin
                $display("BOOTCHK-VEC-ERROR: BIOS ran but 177716 never read");
                xerrs = xerrs + 1;
            end
            if (xerrs == 0) $display("BOOTCHK: PASS");
            else            $display("BOOTCHK: FAIL (%0d X errors)", xerrs);
            $fclose(tracef);
            $finish;
        end
    end

    // ---- +warmreset: reboot mid-screen-clear, MONITOR must come back ----------
    // warm_phase: 0 = cold run, 1 = warm pulse in progress, 2 = warm reboot run
    reg     warmreset;
    integer warm_phase = 0;
    reg     saw_sel1_warm = 0;      // 177716 start-vector read after the reset
    event   do_warm;

    always @(negedge rply)
        if (aclo === 1'b1 && warm_phase == 2 && !din && addr == 16'o177716)
            saw_sel1_warm = 1;

    initial begin
        @(do_warm);
        $display("BOOTCHK: warm reset (reset button) mid-screen-clear...");
        repeat (3) @(posedge sys_clk);
        dclo = 1'b0; aclo = 1'b0;            // pressed, mid-bus-cycle
        repeat (7) @(negedge clk);           // held
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;
        vid_writes = 0;
        warm_phase = 2;
        $display("BOOTCHK: CPU re-released, MONITOR warm reboot...");
    end

    // finish as soon as the screen clear is well underway (twice in +warmreset;
    // +bk11 additionally requires the 177662 write to have been seen).
    // NOT the +smk exit: the SMK BIOS draws its banner BEFORE it probes the
    // drive, so this path would declare victory ahead of the IDE-detection
    // evidence - +smk finishes only through the drive-detection block above.
    always @(vid_writes or saw_662w) begin
        if (!smk && vid_writes >= VID_TARGET && warm_phase != 1
            && (!model11 || saw_662w)) begin
            if (warmreset && warm_phase == 0) begin
                warm_phase = 1;
                -> do_warm;
            end else begin
                if (warmreset && !saw_sel1_warm) begin
                    $display("BOOTCHK-WARM-ERROR: no 177716 read after warm reset");
                    xerrs = xerrs + 1;
                end
                if (xerrs == 0) $display("BOOTCHK: PASS");
                else            $display("BOOTCHK: FAIL (%0d X errors)", xerrs);
                $fclose(tracef);
                $finish;
            end
        end
    end

    // ---- ROM preload (real blob, direct) + reset ------------------------------------
    reg [7:0] blob [0:(1<<19)-1];
    integer ii;
    initial begin
        wr_seen = 0;
        tracef = $fopen("boot_trace.txt", "w");
        $readmemh("../mem/boot_blob_flash.hex", blob, 'h40000);
        for (ii = 0; ii < (1<<19); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        // Authentic DRAM power-on pattern in the RAM region, exactly as
        // src/ram_init.sv leaves it (bkemu-QT InitMemoryValues, Board.cpp /
        // Board_11M.cpp): bk10 word = idx[0]^idx[6]^(idx[5:0]==0 & idx!=0)
        // (64-word phase flip), bk11 word = idx[3]^idx[6].  The CPU must
        // cold-boot on this garbage exactly as on real silicon (this replica
        // preloads it, like the ROM blob above, in lieu of running ram_init
        // through the boot-writer port - that datapath is covered by
        // run_epcs_boot + sim/raminit).
        if (model11)
            for (ii = 0; ii <= 'h0FFFF; ii = ii + 1)
                u_mem.mem['h20000 + ii] = (ii[3] ^ ii[6]) ? 16'hFFFF : 16'h0000;
        else
            for (ii = 0; ii <= 'h03FFF; ii = ii + 1)
                u_mem.mem[ii] =
                    (ii[0] ^ ii[6] ^ ((ii[5:0] == 0) && (ii != 0)))
                        ? 16'hFFFF : 16'h0000;
        for (ii = 0; ii < 16320; ii = ii + 1)
            u_mem.mem[16'h4000 + ii] =
                {blob['h40008 + 2*ii + 1], blob['h40008 + 2*ii]};
        // +bk11/+smk: the window-ROM banks + top ROM; +smk10 needs the same
        // blob purely for the SMK BIOS image at 0x3A000 (on real hardware
        // epcs_boot loads BOTH blobs unconditionally at power-on, exactly so
        // the BIOS is resident whatever DIP 1 says).
        if (model11 || smk) begin
            // 43008 words: incl. the SMK BIOS at 0x3A000 (only reachable
            // under +smk; SMK RAM itself stays zeroed - real hardware powers
            // on garbage there and the BIOS must not depend on it)
            $readmemh("../mem/boot_blob11_flash.hex", blob, 'h48000);
            for (ii = 0; ii < 43008; ii = ii + 1)
                u_mem.mem['h30000 + ii] =
                    {blob['h48008 + 2*ii + 1], blob['h48008 + 2*ii]};
        end

        warmreset = $test$plusargs("warmreset") && !model11;  // bk10-only
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111;
        dclo=1'b0; aclo=1'b0; dclo_cold=1'b0;

        wait (init_done); @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1; dclo_cold = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;
        $display("BOOTCHK: CPU released, %0s cold boot from SDRAM ROM...",
                 model11 ? "BOS (BK-0011M)" : "MONITOR");
    end

    initial begin
        // +smk needs a much longer leash: the real SMK BIOS opens with a
        // SOB-counted startup delay (~5.6k iterations of a 10-word loop at
        // 166362 - ~100 ms at the /24 rate) BEFORE anything visible;
        // 60 ms stays the bound for the bk10/bk11 boots. +longbound (DEBUG)
        // stretches to 2 s for exploring the post-EMT-0 boot flow.
        if ($test$plusargs("longbound"))    #2_000_000_000;
        else if (smk10)                     #550_000_000;   // /32: ~4/3 longer
        else if ($test$plusargs("smk"))     #400_000_000;
        else                                #60_000_000;
        $display("BOOTCHK-TIMEOUT: only %0d video-RAM writes (%0d X errors)",
                 vid_writes, xerrs);
        if (smk)
            $display("BOOTCHK-TIMEOUT: IDE cmds=%0d data_reads=%0d",
                     ide_cmds, ide_data_reads);
        $display("BOOTCHK: FAIL");
        $fclose(tracef);
        $finish;
    end

endmodule
