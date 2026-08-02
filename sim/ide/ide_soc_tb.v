//
// Phase-8 IDE SoC FUNCTIONAL oracle (data-checking, NOT a timing golden).
//
//   vm1 CPU + va_037_sync + the REAL qbus_mem (smk_en=1, BK-0011M mode,
//   the new sel_ide decode + reply-point ide_rdata merge) + the REAL
//   src/peripheral/smk_ide.sv + the behavioral ide_disk_model (loaded with
//   mem/gen_ide_image.py's AltPro image) + behavioural sdram_model
//   (1<<19 words) + the port-2 video-fetch saturator for contention.
//
// The mem/gen_ide_test.py program (see there for the section list) drives
// the IDE task file through the real bus/reply machinery: the SYS
// rom7|device OR-merge, IDENTIFY/READ/WRITE with the BSY commit phase,
// ABRT + the CHS-only LBA deviation, SRST, the HLT10 write-only-extent
// broadcast (task-file writes land in SMK RAM AND the device), the ALL
// seg-3 alias readback + extent|device merge, and the absent slave.
//
// Boot rides the REAL SMK mechanism (the sim/smk shape): the synthetic
// BIOS (gen_smk_test build_bios + one merge-marker word) is preloaded at
// SMK_BIOS_BASE; the SYS rom7 register-space overlay turns the initial
// 177716 read into PC=166400 -> the stage-0 JMP into the page-6 program.
//
// Deliberately NOT here (covered elsewhere): the DCLO replay (sim/smk owns
// the SMK-side replay; the IDE's DCLO-only reset is unit-oracle-pinned),
// СТОП/EVNT legs (sim/smk / sim/bk11 own them - the 662-mask guard below
// only pins that IRQ2 never fires while masked).
//
// Pass/fail: 3 consecutive DIN fetches of the success park 001004 ->
// COSIM PASS; any 001012 fetch, an X at a reply edge, or the watchdog ->
// COSIM FAIL.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module ide_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // ---- clocks: sys_clk + /16 037 enables + /24 CPU clock ----------------
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
        if (cdiv >= 4'd11) begin cdiv <= 4'd0; cpu_clk_r <= ~cpu_clk_r; end
        else               cdiv <= cdiv + 1'b1;
    end
    wire clk = cpu_clk_r;

    // ---- Q-bus ------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;
    // D8:B - the board flop that re-times the 037's RPLY onto the CPU
    // clock's falling edge before it reaches the CPU pin.  The REAL
    // module, never a replica (the cpu_clkgen drift lesson).
    wire        rply037_rt_n;
    assign rply = (rply037_rt_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU --------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(pa), .pin_sp_n(sp),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n(irq), .pin_virq_n(virq),
        .pin_ad_n(ad), .pin_dout_n(dout), .pin_din_n(din),
        .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
        .pin_dmr_n(dmr), .pin_sack_n(sack), .pin_dmgi_n(dmgi),
        .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel), .pin_bsy_n(bsy)
    );

    // ---- retimed 037 -------------------------------------------------------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        mem_ext_ram;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .no_steal(1'b0),   // turbo off: authentic 037 arbitration
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

    // ---- video fetch requester (arbiter port 2): worst-case streaming ------
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)              fetch_req <= 1'b0;
        else if (fetch_gnt)     fetch_req <= 1'b0;
        else                    fetch_req <= 1'b1;
    end

    // ---- the SMK512 IDE device + its tb backing store ----------------------
    wire [15:0] ide_rdata;
    wire        bk_req, bk_wr, bk_bank, bk_ack, bk_done, bk_error;
    wire        bk_media_ok, bk_we;
    wire [27:0] bk_sector, bk_total;
    wire [7:0]  bk_baddr;
    wire [15:0] bk_wdata, bk_rdata;

    smk_ide u_ide (
        .sclk(sys_clk), .reset(~dclo), .enable(1'b1),
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
        .media_in(1'b1), .total_in(28'd640),
        .bk_req(bk_req), .bk_wr(bk_wr), .bk_sector(bk_sector),
        .bk_bank(bk_bank), .bk_ack(bk_ack), .bk_done(bk_done),
        .bk_error(bk_error), .bk_media_ok(bk_media_ok), .bk_total(bk_total),
        .bk_baddr(bk_baddr), .bk_wdata(bk_wdata), .bk_we(bk_we),
        .bk_rdata(bk_rdata)
    );

    // ---- the REAL integration module ---------------------------------------
    wire init_done;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire [DW-1:0] v_rdata_nc;
    wire        vid_page, vid_irq2m;
    wire [3:0]  vid_pal;
    wire        stop_block;

    qbus_mem u_ms (
        .turbo(1'b0),      // turbo off: RAM RPLY stays the 037's
        .cpu_clk  (~clk),
        .reset    (~dclo),
        .ide_rdata(ide_rdata),       // <- the device merge under test
        .joy_word(16'o000000), // no joysticks here; never leave it
                               // floating - an X poisons rdata
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(1'b1),
        .smk_en   (1'b1),
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
        .v1_req   (1'b0),
        .v1_addr  ({AB{1'b0}}),
        .v1_gnt   (),
        .v1_rvalid(),
        .v2_req   (fetch_req),
        .v2_addr  (fetch_addr),
        .v2_gnt   (fetch_gnt),
        .v2_rvalid(fetch_rvalid),
        .v3_req   (1'b0),
        .v3_addr  ({AB{1'b0}}),
        .v3_wdata ({DW{1'b0}}),
        .v3_gnt   (),
        .v_rdata  (v_rdata_nc),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
        .bus_addr (bus_addr),
        .fetch_stb(fetch_stb),
        .vid_page (vid_page),
        .vid_irq2_mask(vid_irq2m),
        .vid_pal  (vid_pal),
        .stop_block(stop_block)
    );

    sdram_model #(.MEM_WORDS(1<<19)) u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- 662-mask guard: the program never unmasks IRQ2 --------------------
    // (no IRQ2 wiring here at all - this just catches a stray unmask)
    always @(negedge vid_irq2m) begin
        $display("IDE-ERROR: 177662 IRQ2 unmasked (program never writes 662)");
        $display("COSIM FAIL");
        $finish;
    end

    // ---- X monitor at the reply edges (smk_soc_tb shape) -------------------
    integer xerrs = 0;
    always @(negedge rply) if (aclo === 1'b1) begin
        #1;
        if (!din && ^ad === 1'bx) begin
            $display("IDE-X-ERROR: ad=%b addr=%06o t=%0t", ad, addr, $time);
            xerrs = xerrs + 1;
        end
        if (rply === 1'bx) begin
            $display("IDE-X-ERROR: rply=X t=%0t", $time);
            xerrs = xerrs + 1;
        end
        if (xerrs != 0) begin
            $display("COSIM FAIL");
            $finish;
        end
    end

    // ---- pass/fail: the pinned park loops ----------------------------------
    integer scnt = 0;
    always @(negedge din) begin
        if (~sync) begin
            if (addr == 16'o001004) begin
                scnt = scnt + 1;
                if (scnt == 3) begin
                    $display("COSIM PASS");
                    $finish;
                end
            end else begin
                scnt = 0;
                if (addr == 16'o001012) begin
                    $display("IDE-ERROR: fail park 001012 reached");
                    $display("COSIM FAIL");
                    $finish;
                end
            end
        end
    end

    // ---- +trace: full bus activity (debug aid; reads sampled at the RPLY
    //      edge so the data column is the replied word) ----------------------
    initial if ($test$plusargs("trace")) begin
        fork
            forever begin
                @(negedge rply);
                if (~sync && ~din)
                    $display("TRC R %06o -> %06o @%0t", addr, ~ad, $time);
            end
            forever @(negedge dout)
                if (~sync)
                    $display("TRC W %06o <= %06o @%0t", addr, ~ad, $time);
        join
    end

    // ---- SDRAM + disk preload ----------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<19); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        $readmemh("ide_page6.hex", u_mem.mem, 'h2C000, 'h2DFFF);
        $readmemh("ide_bios.hex", u_mem.mem, 'h3A000, 'h3A7FF);
        $readmemh("ide_image.hex", u_disk.disk);
    end

    // ---- reset (wait SDRAM init) + watchdog --------------------------------
    initial begin
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0; dclo_cold=1'b0;

        wait (init_done);
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1; dclo_cold = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #100_000_000;
        $display("IDE-ERROR: watchdog timeout (last addr %o)", addr);
        $display("COSIM FAIL");
        $finish;
    end


// D8:B, the board's RPLY re-timing flop (src/bus/bk_rply.sv) - the REAL module,
// never a replica (the cpu_clkgen drift lesson).  Placed at the end of the
// module so it cannot depend on where the reset regs are declared.
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo_cold),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
