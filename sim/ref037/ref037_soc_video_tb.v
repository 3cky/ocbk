//
// Phase 4/5 cycle-accuracy gate: the SoC cosim with the REAL video pipeline
// contending on all four arbiter ports (ref037_soc_tb's synthetic port-2
// saturator stays alongside as the worst-case upper bound).
//
//   vm1 CPU (port 0)  +  va_037_sync  +  the REAL integration module
//   qbus_mem (ROM/IO N_ROM FSM + cpu_sdram_dp + sdram_arbiter + sdram_ctrl)
//   +  fb_readout (port 1: paced line prefetch, driven by a real 3:2 pixel
//      clock + vga_out line requests + fb_linebuf)
//   +  fb_video (ports 2+3: video fetch -> palette -> FB write)
//   +  behavioural sdram_model
//
// Two checks, both surfacing as diffs vs the golden (run.sh's reduce keeps
// only /^FETCH/ lines, so every error print carries a FETCH- prefix):
//   1. the boot-window per-instruction cycle counts match the golden exactly
//      (the 60 Hz readout is live from reset - the new port-1 contender);
//   2. the run continues past display start (ports 2+3 go live: 32 fetches +
//      128 FB writes per line) for 64 display lines while the CPU spins in the
//      self-loop; every iteration must stay on the reference pattern.
//
// Default mode (program in RAM at 001000, golden_037.txt): loop iterations in
// the beat pattern cycles in {15,16,17}, every rolling 4-sum = 64.
// +romprog (Phase-5 ROM-in-SDRAM, golden_037_rom.txt): the ROM self-loop is
// FLAT - every display-phase iteration must be exactly 13 cycles (ROM is not
// 037-cycle-stolen; a single done-gate RPLY extension breaks it).
// Both modes also watch FETCH-ROMGATE / FETCH-P0LAT (see ref037_soc_tb.v).
// +warmreset (Phase-5.5 soft reset): after the 64 display lines, DCLO/ACLO are
// re-asserted MID-DISPLAY-LINE (ports 1/2/3 live, a dp access likely in
// flight); SDRAM contents and the sys/pix domains stay up, and the 037 +
// fb_video are NOT reset (power-on only, real-BK display fidelity) - the whole
// video pipeline keeps fetching/writing/displaying across the hold. The
// release is aligned to the next vblank start (matching the cold boot's
// steal-free window position), then the whole sequence - golden window plus
// 64 checked display lines - must repeat exactly (run.sh diffs both passes
// against the same golden).
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5
`define TEST_LO     16'o001000
`define TEST_HI     16'o002000
`define ROM_TEST_LO 16'o101000
`define ROM_TEST_HI 16'o102000

module ref037_soc_video_tb;

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

    // pixel clock: exact 3:2 vs sys_clk (as the real 96.65/64.43 MHz pair)
    reg pix_clk = 1'b0;
    always #7.5 pix_clk = ~pix_clk;

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;                        // 037 reply (RAM) -> open-collector
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;   // power-on reset for the VIDEO side (037 + fb_video):
                             // released with the first dclo release, never re-
                             // asserted - a real BK's display ignores CPU resets
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
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready), .ext_ram(1'b0),
        .PIN_R(~dclo_cold), .PIN_C(1'b0),
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
    integer    disp_lines   = 0;      // completed display lines (run-length control)
    always @(posedge sys_clk) begin
        va_hgate_d <= va_hgate;
        if (!dclo_cold) begin                      // 037 in power-on reset only:
            vf_line_open = 1'b0;                   // it free-runs (and stays
            vf_cnt       = 0;                      // checked) across warm resets
        end else begin
            if (va_vfetch) vf_cnt = vf_cnt + 1;
            if (va_hgate & ~va_hgate_d) begin          // line-end edge
                if (vf_line_open) begin
                    disp_lines = disp_lines + 1;
                    if (vf_cnt != 32)
                        $display("FETCH-VIDTAP-ERROR: %0d fetches in display line", vf_cnt);
                end
                vf_line_open = 1'b0;
            end
            if (~va_hgate & va_hgate_d & ~va_vgate) begin  // line-start edge
                vf_line_open = 1'b1;
                vf_cnt       = 0;
            end
        end
    end

    // ---- real video write pipeline: fb_video (arbiter ports 2 + 3) -----------
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [AB-1:0] f_addr, w_addr;
    wire [DW-1:0] w_wdata;
    wire [DW-1:0] arb_rdata;
    wire        fb_front, fb_front_valid, err_fetch_ovr, err_fifo_ovf;

    fb_video #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_fbv (
        .clk(sys_clk), .rst_n(dclo_cold), .blank_req(1'b0), .screen_mode(1'b1),
        .vram_base(24'h002000), .pal_idx(4'd0),   // bk10: fixed base, palette 0
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate), .video_va(video_va),
        .f_req(f_req), .f_addr(f_addr), .f_gnt(f_gnt), .f_rvalid(f_rvalid),
        .rdata_i(arb_rdata),
        .w_req(w_req), .w_addr(w_addr), .w_wdata(w_wdata), .w_gnt(w_gnt),
        .fb_front(fb_front), .fb_front_valid(fb_front_valid),
        .err_fetch_ovr(err_fetch_ovr), .err_fifo_ovf(err_fifo_ovf)
    );

    // ---- real readout pipeline: vga_out + fb_linebuf + fb_readout (port 1) ---
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
    wire        ro_req, ro_gnt, ro_rvalid, err_line_ovr;
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
        .err_line_ovr(err_line_ovr)
    );

    // ---- the REAL integration module (ROM/IO FSM + dp + arbiter + ctrl) ------
    reg  romprog;                    // +romprog: program in the SDRAM ROM region
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;

    qbus_mem u_ms (
        .cpu_clk  (~clk),            // as ocbk_top: FSM on the inverted CPU clock
        .reset    (~dclo),
        .ide_rdata(16'h0000),  // no SMK IDE device in this tb
        .init_n   (init),            // peripheral-register reset (Phase 6)
        .kbd_down (1'b0),            // no keyboard in this oracle
        .tape_in  (1'b0),            // no tape signal in this oracle
        .sel1_n   (sel[1]),          // CPU nSEL1/nSEL2 register selects
        .sel2_n   (sel[2]),
        .model_bk11(1'b0),           // BK-0010 mode: mapper = bit-identical pass-through
        .smk_en(1'b0),               // no SMK512 (never floating: X would poison)
        .boot_active(1'b0),          // loader path gated in ref037_soc_tb
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
        .v1_req   (ro_req),
        .v1_addr  (ro_addr),
        .v1_gnt   (ro_gnt),
        .v1_rvalid(ro_rvalid),
        .v2_req   (f_req),
        .v2_addr  (f_addr),
        .v2_gnt   (f_gnt),
        .v2_rvalid(f_rvalid),
        .v3_req   (w_req),
        .v3_addr  (w_addr),
        .v3_wdata (w_wdata),
        .v3_gnt   (w_gnt),
        .v_rdata  (arb_rdata),
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
    integer scyc = 0, p0_t0 = 0, p0_max = 0;
    reg     p0_pend = 1'b0, romgate_flag = 1'b0;
    always @(posedge sys_clk) begin
        scyc = scyc + 1;
        if (!dclo) begin
            p0_pend <= 1'b0;        // warm reset aborts any in-flight dp read
        end else if (!p0_pend) begin
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
    // Golden window: prints match ref037_soc_tb (which $finishes at loop_n == 6);
    // here the run continues silently, checking every further self-loop iteration:
    //   RAM program: reference beat pattern (cycles 15..17, rolling 4-sum = 64);
    //   ROM program: FLAT - exactly 13 cycles each (golden_037_rom.txt pins it).
    wire [15:0] win_lo    = romprog ? `ROM_TEST_LO : `TEST_LO;
    wire [15:0] win_hi    = romprog ? `ROM_TEST_HI : `TEST_HI;
    wire [15:0] loop_addr = romprog ? 16'o101136   : 16'o001136;
    wire        sel_win   = romprog ? sel_rom      : sel_ram;

    integer    prev_nclk;   reg [15:0] prev_addr;   reg have_baseline;
    integer    loop_n = 0;
    integer    cyc, hist0, hist1, hist2, hist3, hist_n = 0, loop_bad = 0;
    reg        warmreset;            // +warmreset: replay after a mid-run reset
    reg        meas_en = 1'b1;       // window armed (off during the warm pulse)
    always @(negedge din) begin
        if (meas_en && ~sync && sel_win && addr >= win_lo && addr < win_hi) begin
            if (have_baseline && loop_n < 6)
                $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
            if (prev_addr == loop_addr) begin
                cyc = nclk - prev_nclk;
                if (loop_n >= 6) begin
                    hist3 = hist2; hist2 = hist1; hist1 = hist0; hist0 = cyc;
                    hist_n = hist_n + 1;
                    if (romprog) begin
                        if (cyc != 13 && loop_bad < 8) begin
                            $display("FETCH-LOOP-ERROR: ROM iter cycles=%0d (disp_lines=%0d)",
                                     cyc, disp_lines);
                            loop_bad = loop_bad + 1;
                        end
                    end else begin
                        if ((cyc < 15 || cyc > 17) && loop_bad < 8) begin
                            $display("FETCH-LOOP-ERROR: iter cycles=%0d (disp_lines=%0d)",
                                     cyc, disp_lines);
                            loop_bad = loop_bad + 1;
                        end
                        if (hist_n >= 4 && (hist0+hist1+hist2+hist3 != 64)
                            && loop_bad < 8) begin
                            $display("FETCH-LOOP-ERROR: 4-sum=%0d (disp_lines=%0d)",
                                     hist0+hist1+hist2+hist3, disp_lines);
                            loop_bad = loop_bad + 1;
                        end
                    end
                end
                loop_n = loop_n + 1;
            end
            prev_nclk = nclk; prev_addr = addr; have_baseline = 1'b1;
        end
    end

    // ---- program preload (one word table - see ref037_soc_tb.v) ---------------
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

        for (ii = 0; ii < (1<<18); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        if ($test$plusargs("romprog")) begin
            u_mem.mem[16'h4000] = 16'o000137;    // JMP @#101000 (from SDRAM ROM)
            u_mem.mem[16'h4001] = 16'o101000;
            for (ii = 0; ii < 16'h30; ii = ii + 1)
                u_mem.mem[16'h4100 + ii] = prog[ii];
        end else begin
            // Default: program in SDRAM RAM at 001000; bootstrap JMP in the SDRAM
            // ROM region (CPU boots at 100000 = SDRAM word 0x4000). Same fixed-
            // N_ROM fetch as the old on-chip stub -> golden window unchanged.
            u_mem.mem[16'h4000] = 16'o000137;    // JMP @#001000 (RAM program)
            u_mem.mem[16'h4001] = 16'o001000;
            for (ii = 0; ii < 16'h30; ii = ii + 1)
                u_mem.mem[16'h100 + ii] = prog[ii];
        end
        u_mem.mem[16'h200] = 16'o012345;
    end

    // ---- reset (wait SDRAM init) + sim limit ---------------------------------
    reg run_done = 1'b0;

    task check_flags;
        begin
            if (err_fetch_ovr) $display("FETCH-FLAG-ERROR: fb_video fetch overrun");
            if (err_fifo_ovf)  $display("FETCH-FLAG-ERROR: fb_video fifo overflow");
            if (err_line_ovr)  $display("FETCH-FLAG-ERROR: fb_readout line overrun");
            if (hist_n < 1000) $display("FETCH-FLAG-ERROR: only %0d loop samples", hist_n);
        end
    endtask

    initial begin
        nclk=0; prev_nclk=0; have_baseline=1'b0;
        romprog   = $test$plusargs("romprog");
        warmreset = $test$plusargs("warmreset");
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0; dclo_cold=1'b0;

        wait (init_done); @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1; dclo_cold = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        // run through the golden window (all vblank) and then 64 real display
        // lines of full 4-port contention (~8 ms total)
        wait (disp_lines >= 64);
        check_flags;

        if (warmreset) begin
            // Phase-5.5 soft reset: press the button MID-DISPLAY-LINE (ports
            // 1/2/3 live, a dp access likely in flight). The video pipeline is
            // NOT reset and keeps fetching/writing/displaying through the
            // hold; release at the next vblank start (cold 8-then-4 pattern).
            // SDRAM contents, srst_n and the pix domain stay up; the whole
            // checked sequence must repeat exactly.
            meas_en = 1'b0;
            repeat (3) @(posedge sys_clk);
            dclo = 1'b0; aclo = 1'b0;            // reset button pressed
            repeat (7) @(negedge clk);           // held...
            @(posedge va_vgate);                 // ...until the next vblank start
            @(negedge clk);
            repeat (8) @(negedge clk); dclo = 1'b1;
            repeat (4) @(negedge clk); aclo = 1'b1;
            loop_n = 0; have_baseline = 1'b0; prev_addr = 16'hFFFF;
            hist_n = 0; loop_bad = 0; disp_lines = 0;
            meas_en = 1'b1;
            wait (disp_lines >= 64);
            check_flags;
        end

        $display("P0LAT max=%0d sys_clk (budget 48)", p0_max);
        run_done = 1'b1;
        $finish;
    end

    initial begin
        // +warmreset: pass 1 (~8 ms) + hold-to-vblank (up to ~12 ms) + pass 2
        #(($test$plusargs("warmreset")) ? 45_000_000 : 12_000_000);  // backstop
        if (!run_done) begin
            $display("FETCH-TIMEOUT-ERROR: display lines never reached");
            $finish;
        end
    end

endmodule
