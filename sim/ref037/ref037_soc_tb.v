//
// Phase 3 SoC-integration cosim: the Strategy-A RAM path end to end.
//
//   vm1 CPU  +  va_037_sync (owns RAM RPLY, done-gate)  +  the REAL integration
//   module qbus_mem_sdram (ROM/IO N_ROM FSM + cpu_sdram_dp + sdram_arbiter +
//   sdram_ctrl)  +  behavioural sdram_model
//
// The bk10 test program runs FROM SDRAM (preloaded into the model), RAM RPLY comes
// from the 037 grant gated by the datapath's mem_ready, and the 037 video fetch
// streams worst-case back-to-back reads on arbiter port 2 to contend with the CPU
// (port 0). If the integration is correct the per-instruction cycle counts still
// match sim/ref037/golden_037.txt - i.e. the SDRAM + arbiter + done-gate reproduce
// the reference timing (the interlock never perturbs it at 3 MHz), AND the program
// executes correctly out of SDRAM (it reaches the self-loop).
//
// Default mode: bootstrap from the ON-CHIP ROM image (boot_stub.hex, the Phase-5
// fallback path, rom_ext_en=0), program in SDRAM RAM space -> golden_037.txt.
// +romprog:     rom_ext_en=1 - bootstrap AND program live in the SDRAM ROM region
// (words 0x4000+, the Phase-5 ROM-in-SDRAM path with the done-gated fixed-N_ROM
// reply) -> golden_037_rom.txt. Both runs also watch:
//   * FETCH-ROMGATE-ERROR - the ROM done-gate extended RPLY past the fixed count;
//   * FETCH-P0LAT-ERROR   - a port-0 read exceeded the 48 sys_clk latency budget
//     (the N_ROM=2 window is ~64 sys_clk; worst-case contention estimate is ~28).
// +romprog +bootload: the SDRAM ROM region is NOT preloaded - a synthetic mini
// boot blob (same header format, length 0x130 words) is placed in the EPCS flash
// model instead and the real epcs_boot loader copies it through the boot-writer
// mux on port 0 during reset-hold, exactly as ocbk_top boots. The golden must
// still match: flash -> SDRAM -> fetch, end to end at cycle accuracy.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5
`define TEST_LO     16'o001000
`define TEST_HI     16'o002000
`define ROM_TEST_LO 16'o101000
`define ROM_TEST_HI 16'o102000

module ref037_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // ---- clocks: sys_clk + ÷16 enables (on CPU edges) + CPU clk (÷32) --------
    reg       sys_clk;
    reg [4:0] divc;
    integer   nclk;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 5'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);
    wire clk    = divc[4];
    always @(posedge clk) nclk = nclk + 1;

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;                        // 037 reply (RAM) -> open-collector
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    // SDRAM-domain reset: released early (a few sys_clk), independent of the CPU
    // reset dclo which waits on init_done (mirrors ocbk_top's srst_n vs dclo).
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- address decode (tb-side, for the measurement window only) -----------
    reg [15:0] addr;
    reg        sel_ram, sel_rom;
    always @(negedge sync) begin
        addr    = ~ad;
        sel_ram = (addr < 16'o100000);
        sel_rom = (addr >= 16'o100000) && (addr < 16'o177600);
    end
    always @(posedge sync) begin sel_ram=0; sel_rom=0; end

    // ---- CPU ----------------------------------------------------------------
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

    // ---- retimed 037 (owns RAM RPLY, done-gate = mem_ready) ------------------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready),
        .PIN_R(~dclo), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate)
    );

    // ---- Phase-4 tap sanity: exactly 32 vid_fetch pulses per display line ----
    // Prints only on error; the FETCH- prefix passes run.sh's reduce filter
    // (which keeps only /^FETCH/ lines), so an error breaks the golden diff.
    reg        vf_line_open = 1'b0;   // saw the hgate fall that opens this line
    reg        va_hgate_d   = 1'b0;
    integer    vf_cnt       = 0;
    always @(posedge sys_clk) begin
        va_hgate_d <= va_hgate;
        if (va_vfetch) vf_cnt = vf_cnt + 1;
        if (va_hgate & ~va_hgate_d) begin          // line-end edge
            if (vf_line_open && vf_cnt != 32)
                $display("FETCH-VIDTAP-ERROR: %0d fetches in display line", vf_cnt);
            vf_line_open = 1'b0;
        end
        if (~va_hgate & va_hgate_d & ~va_vgate) begin  // line-start edge
            vf_line_open = 1'b1;
            vf_cnt       = 0;
        end
    end

    // ---- video fetch requester (arbiter port 2): worst-case streaming reads --
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};   // some RAM word; data dropped
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)              fetch_req <= 1'b0;
        else if (fetch_gnt)     fetch_req <= 1'b0;   // drop on grant (served contract)
        else                    fetch_req <= 1'b1;   // otherwise keep requesting
    end

    // ---- the REAL integration module (ROM/IO FSM + dp + arbiter + ctrl) ------
    reg  romprog;                    // +romprog: ROM-in-SDRAM mode (rom_ext_en)
    reg  bootload;                   // +bootload: populate SDRAM through epcs_boot
    wire init_done;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire [DW-1:0] v_rdata_nc;

    // EPCS loader + flash model (quiet unless +bootload starts them)
    wire spi_dclk, spi_ncs, spi_mosi;
    tri1 spi_miso;
    wire bw_req, bw_gnt, boot_active, boot_done, boot_ok;
    wire [AB-1:0] bw_addr;
    wire [15:0]   bw_wdata;

    epcs_model u_flash (
        .dclk(spi_dclk), .ncs(spi_ncs), .mosi(spi_mosi), .miso(spi_miso)
    );
    epcs_boot #(.ADDR_BITS(AB)) u_boot (
        .clk(sys_clk), .rst_n(srst_n), .start(init_done && bootload),
        .spi_dclk(spi_dclk), .spi_ncs(spi_ncs),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .bw_req(bw_req), .bw_addr(bw_addr), .bw_wdata(bw_wdata), .bw_gnt(bw_gnt),
        .boot_active(boot_active), .boot_done(boot_done), .boot_ok(boot_ok)
    );

    qbus_mem_sdram #(.MEMFILE("boot_stub.hex")) u_ms (
        .cpu_clk  (~clk),            // as ocbk_top: FSM on the inverted CPU clock
        .reset    (~dclo),
        .rom_ext_en(romprog),
        .boot_active(boot_active),
        .bw_req   (bw_req),
        .bw_addr  (bw_addr),
        .bw_wdata (bw_wdata),
        .bw_gnt   (bw_gnt),
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
        .v1_req   (1'b0),            // readout idle here (see ref037_soc_video_tb)
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
        .fetch_stb(fetch_stb)
    );

    sdram_model u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- port-0 read latency + ROM done-gate watchdogs ------------------------
    // Budget: the N_ROM=2 reply window is ~64 sys_clk from DIN; a read must be
    // back well inside it. Estimate under worst contention ~28. Errors carry the
    // FETCH- prefix so they break the golden diff.
    integer scyc = 0, p0_t0 = 0, p0_max = 0;
    reg     p0_pend = 1'b0, romgate_flag = 1'b0;
    always @(posedge sys_clk) begin
        scyc = scyc + 1;
        if (!p0_pend) begin
            if (u_ms.dp_req && !u_ms.dp_we) begin p0_pend <= 1'b1; p0_t0 = scyc; end
        end else if (u_ms.dp_rvalid) begin
            p0_pend <= 1'b0;
            if (scyc - p0_t0 > p0_max) p0_max = scyc - p0_t0;
            if (scyc - p0_t0 > 48)
                $display("FETCH-P0LAT-ERROR: port-0 read latency %0d sys_clk",
                         scyc - p0_t0);
        end
        if (u_ms.dbg_romgate && !romgate_flag) begin
            romgate_flag = 1'b1;
            $display("FETCH-ROMGATE-ERROR: ROM RPLY extended past the fixed count");
        end
    end

    // ---- timing measurement ---------------------------------------------------
    wire [15:0] win_lo    = romprog ? `ROM_TEST_LO : `TEST_LO;
    wire [15:0] win_hi    = romprog ? `ROM_TEST_HI : `TEST_HI;
    wire [15:0] loop_addr = romprog ? 16'o101136   : 16'o001136;
    wire        sel_win   = romprog ? sel_rom      : sel_ram;

    integer    prev_nclk;   reg [15:0] prev_addr;   reg have_baseline;
    integer    loop_n = 0;
    always @(negedge din) begin
        if (~sync && sel_win && addr >= win_lo && addr < win_hi) begin
            if (have_baseline)
                $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
            if (prev_addr == loop_addr) loop_n = loop_n + 1;
            if (loop_n == 6) begin
                $display("P0LAT max=%0d sys_clk (budget 48)", p0_max);
                $finish;       // enough self-loop samples captured
            end
            prev_nclk = nclk; prev_addr = addr; have_baseline = 1'b1;
        end
    end

    // ---- program preload -------------------------------------------------------
    // One word table (identical to ref037_tb.v). Default: program in SDRAM RAM
    // space at 001000, bootstrap from the on-chip stub ROM. +romprog: bootstrap
    // AND program in the SDRAM ROM region (words 0x4000+ = BK 100000+).
    reg [15:0] prog [0:16'h2F];
    integer ii;
    initial begin
        prog['h00] = 16'o012700; prog['h01] = 16'o002000;
        prog['h02] = 16'o012701; prog['h03] = 16'o002000;
        prog['h04] = 16'o012710; prog['h05] = 16'o012345;
        prog['h06] = 16'o010002;
        prog['h07] = 16'o011002;
        prog['h08] = 16'o012002;
        prog['h09] = 16'o012700; prog['h0A] = 16'o002000;
        prog['h0B] = 16'o014002;
        prog['h0C] = 16'o012700; prog['h0D] = 16'o002000;
        prog['h0E] = 16'o016002; prog['h0F] = 16'o000000;
        prog['h10] = 16'o010011;
        prog['h11] = 16'o012711; prog['h12] = 16'o012345;
        prog['h13] = 16'o010021;
        prog['h14] = 16'o012701; prog['h15] = 16'o002000;
        prog['h16] = 16'o010041;
        prog['h17] = 16'o012701; prog['h18] = 16'o002000;
        prog['h19] = 16'o010061; prog['h1A] = 16'o000000;
        // RMW (DATIO/DATIOB) coverage - see ref037_tb.v; FAIL park 001124/101124.
        // This is the only make-sim path exercising read-modify-write through
        // cpu_sdram_dp (a DATIO write phase was silently dropped pre-fix).
        prog['h1B] = 16'o012700; prog['h1C] = 16'o002000;
        prog['h1D] = 16'o005010;
        prog['h1E] = 16'o005210;
        prog['h1F] = 16'o062710; prog['h20] = 16'o000005;
        prog['h21] = 16'o052710; prog['h22] = 16'o000120;
        prog['h23] = 16'o042710; prog['h24] = 16'o000100;
        prog['h25] = 16'o105210;
        prog['h26] = 16'o011002;
        prog['h27] = 16'o020227; prog['h28] = 16'o000027;
        prog['h29] = 16'o001401;
        prog['h2A] = 16'o000777;                 // RMW FAIL park
        prog['h2B] = 16'o005002;
        prog['h2C] = 16'o000400;
        prog['h2D] = 16'o012702; prog['h2E] = 16'o001234;
        prog['h2F] = 16'o000777;                 // self-loop

        for (ii = 0; ii < (1<<17); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        if ($test$plusargs("bootload")) begin : mk_blob
            // +bootload: build a synthetic mini-blob (length 0x130 words) in the
            // flash model; the loader populates the SDRAM ROM region itself.
            reg [15:0] w, csum;
            csum = 16'd0;
            for (ii = 0; ii < 16'h130; ii = ii + 1) begin
                if      (ii == 0)          w = 16'o000137;   // JMP @#101000
                else if (ii == 1)          w = 16'o101000;
                else if (ii >= 16'h100 && ii < 16'h130) w = prog[ii - 16'h100];
                else                       w = 16'o000000;
                u_flash.flash['h40008 + 2*ii]     = w[7:0];
                u_flash.flash['h40008 + 2*ii + 1] = w[15:8];
                csum = csum + w;
            end
            u_flash.flash['h40000] = 8'h42;      // magic "BK"
            u_flash.flash['h40001] = 8'h4B;
            u_flash.flash['h40002] = 8'h30;      // length = 0x0130 words
            u_flash.flash['h40003] = 8'h01;
            u_flash.flash['h40004] = csum[7:0];
            u_flash.flash['h40005] = csum[15:8];
            u_flash.flash['h40006] = 8'h00;
            u_flash.flash['h40007] = 8'h00;
        end else if ($test$plusargs("romprog")) begin
            u_mem.mem[16'h4000] = 16'o000137;    // JMP @#101000 (from SDRAM ROM)
            u_mem.mem[16'h4001] = 16'o101000;
            for (ii = 0; ii < 16'h30; ii = ii + 1)
                u_mem.mem[16'h4100 + ii] = prog[ii];
        end else begin
            for (ii = 0; ii < 16'h30; ii = ii + 1)
                u_mem.mem[16'h100 + ii] = prog[ii];
        end
        u_mem.mem[16'h200] = 16'o012345;
    end

    // ---- reset (wait SDRAM init) + sim limit ---------------------------------
    initial begin
        nclk=0; prev_nclk=0; have_baseline=1'b0;
        romprog  = $test$plusargs("romprog");
        bootload = $test$plusargs("bootload");
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0;

        wait (init_done);
        if (bootload) begin                 // as ocbk_top: CPU held until loaded
            wait (boot_done);
            if (!boot_ok) $display("FETCH-BOOT-ERROR: loader ended boot_ok=0");
        end
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #2_500_000;
        $finish;
    end

endmodule
