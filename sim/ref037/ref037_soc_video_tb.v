//
// Phase 4 cycle-accuracy gate: the SoC cosim with the REAL video pipeline
// contending on all four arbiter ports (ref037_soc_tb's synthetic port-2
// saturator stays alongside as the worst-case upper bound).
//
//   vm1 CPU (port 0)  +  va_037_sync  +  cpu_sdram_dp
//   +  fb_readout (port 1: paced line prefetch, driven by a real 3:2 pixel
//      clock + vga_out line requests + fb_linebuf)
//   +  fb_video (ports 2+3: video fetch -> palette -> FB write)
//   +  sdram_arbiter  +  sdram_ctrl  +  behavioural sdram_model
//
// Two checks, both surfacing as diffs vs golden_037.txt (run.sh's reduce keeps
// only /^FETCH/ lines, so every error print carries a FETCH- prefix):
//   1. the boot-window per-instruction cycle counts match the golden exactly
//      (the 60 Hz readout is live from reset - the new port-1 contender);
//   2. the run continues past display start (ports 2+3 go live: 32 fetches +
//      128 FB writes per line) for 64 display lines while the CPU spins in the
//      RAM self-loop: every iteration must stay in the reference beat pattern
//      (cycles in {15,16,17}, every rolling 4-sum = 64) - a single done-gate
//      RPLY extension breaks it. The video sticky violation flags must stay 0.
//
// ROM (100000-137777) + I/O (177716) stay behavioural on-chip here (fixed N_ROM),
// exactly as in ref037_sync_tb; only the RAM path changed.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5
`define N_ROM       2
`define TEST_LO 16'o001000
`define TEST_HI 16'o002000

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
    reg  [15:0] rom_data, io_data;
    reg         rom_oe, io_oe;
    assign ad = rom_oe ? ~rom_data : 16'hZZZZ;
    assign ad = io_oe  ? ~io_data  : 16'hZZZZ;

    tri1        sync, din, dout, wtbt, rply;
    reg         rply_ext_n;                      // ROM/IO reply (open-collector)
    assign rply = rply_ext_n ? 1'bZ : 1'b0;
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

    // ---- address decode -----------------------------------------------------
    reg [15:0] addr;
    reg        sel_ram, sel_rom, sel_io;
    always @(negedge sync) begin
        addr    = ~ad;
        sel_ram = (addr < 16'o100000);
        sel_rom = (addr >= 16'o100000) && (addr < 16'o140000);
        sel_io  = (addr >= 16'o177600);
    end
    always @(posedge sync) begin sel_ram=0; sel_rom=0; sel_io=0; end

    // ---- ROM / I/O (behavioural, on-chip, fixed N_ROM) ----------------------
    reg [15:0] rom [0:8191];
    always @(negedge din) begin
        if (~sync) begin
            if (sel_rom) begin
                rom_data = rom[addr[13:1]];
                repeat (`N_ROM) @(negedge clk);
                rom_oe = 1'b1; rply_ext_n = 1'b0;
            end else if (sel_io) begin
                io_data = (addr == 16'o177716) ? 16'o100000 : 16'o000000;
                repeat (`N_ROM) @(negedge clk);
                io_oe = 1'b1; rply_ext_n = 1'b0;
            end
        end
    end
    always @(posedge din or posedge dout) begin
        @(negedge clk); rply_ext_n = 1'b1; @(posedge clk); rom_oe=0; io_oe=0;
    end

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

    // ---- retimed 037 (owns RAM RPLY, done-gate = dp.mem_ready) ---------------
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
    integer    disp_lines   = 0;      // completed display lines (run-length control)
    always @(posedge sys_clk) begin
        va_hgate_d <= va_hgate;
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

    // ---- CPU SDRAM datapath (arbiter port 0) --------------------------------
    wire                dp_req, dp_we;
    wire [AB-1:0]       dp_addr;
    wire [DW-1:0]       dp_wdata;
    wire [1:0]          dp_be;
    wire                dp_gnt, dp_rvalid;
    wire [DW-1:0]       arb_rdata;
    wire [15:0]         dp_rdata;
    wire                dp_rdata_oe;
    assign ad = dp_rdata_oe ? ~dp_rdata : 16'hZZZZ;

    cpu_sdram_dp #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_dp (
        .clk(sys_clk), .rst_n(dclo),
        .sync_n(sync), .din_n(din), .dout_n(dout), .wtbt_n(wtbt),
        .sel_ram(sel_ram), .addr(addr), .ad_true(~ad),
        .rdata(dp_rdata), .rdata_oe(dp_rdata_oe), .mem_ready(mem_ready),
        .req(dp_req), .we(dp_we), .addr_o(dp_addr), .wdata_o(dp_wdata), .be_o(dp_be),
        .gnt(dp_gnt), .rvalid(dp_rvalid), .rdata_i(arb_rdata)
    );

    // ---- real video write pipeline: fb_video (arbiter ports 2 + 3) -----------
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [AB-1:0] f_addr, w_addr;
    wire [DW-1:0] w_wdata;
    wire        fb_front, fb_front_valid, err_fetch_ovr, err_fifo_ovf;

    fb_video #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_fbv (
        .clk(sys_clk), .rst_n(dclo), .screen_mode(1'b1),
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

    // ---- arbiter: [0] CPU, [1] readout, [2] fetch, [3] FB write --------------
    localparam int NREQ = 4;
    wire [NREQ-1:0] p_req    = {w_req,   f_req,  ro_req,  dp_req};
    wire [NREQ-1:0] p_we     = {1'b1,    1'b0,   1'b0,    dp_we};
    wire [NREQ*AB-1:0] p_addr  = {w_addr, f_addr, ro_addr, dp_addr};
    wire [NREQ*DW-1:0] p_wdata = {w_wdata, {DW{1'b0}}, {DW{1'b0}}, dp_wdata};
    wire [NREQ*2-1:0]  p_be    = {2'b11, 2'b11, 2'b11, dp_be};
    wire [NREQ-1:0] p_gnt, p_rvalid;

    assign dp_gnt = p_gnt[0];   assign dp_rvalid = p_rvalid[0];
    assign ro_gnt = p_gnt[1];   assign ro_rvalid = p_rvalid[1];
    assign f_gnt  = p_gnt[2];   assign f_rvalid  = p_rvalid[2];
    assign w_gnt  = p_gnt[3];

    wire                cmd_req, cmd_we, cmd_ready, rd_valid;
    wire [AB-1:0]       cmd_addr;
    wire [DW-1:0]       cmd_wdata, rd_data;
    wire [1:0]          cmd_be;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(AB), .DQ_BITS(DW)) u_arb (
        .clk(sys_clk), .rst_n(srst_n),
        .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be),
        .p_gnt(p_gnt), .p_rvalid(p_rvalid), .p_rdata(arb_rdata),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data)
    );

    // ---- SDRAM controller + model -------------------------------------------
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] dq_out, dq_in;  wire dq_oe;
    wire [DW-1:0] s_dq;
    assign s_dq = dq_oe ? dq_out : 'z;
    assign dq_in = s_dq;

    sdram_ctrl #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_ctrl (
        .clk(sys_clk), .rst_n(srst_n),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm),
        .dq_out(dq_out), .dq_oe(dq_oe), .dq_in(dq_in)
    );
    sdram_model u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- timing measurement ---------------------------------------------------
    // Golden window: prints match ref037_soc_tb (which $finishes at loop_n == 6);
    // here the run continues silently, checking every further self-loop iteration
    // against the reference beat pattern (cycles 15..17, rolling 4-sum = 64).
    integer    prev_nclk;   reg [15:0] prev_addr;   reg have_baseline;
    integer    loop_n = 0;
    integer    cyc, hist0, hist1, hist2, hist3, hist_n = 0, loop_bad = 0;
    always @(negedge din) begin
        if (~sync && sel_ram && addr >= `TEST_LO && addr < `TEST_HI) begin
            if (have_baseline && loop_n < 6)
                $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
            if (prev_addr == 16'o001136) begin
                cyc = nclk - prev_nclk;
                if (loop_n >= 6) begin
                    hist3 = hist2; hist2 = hist1; hist1 = hist0; hist0 = cyc;
                    hist_n = hist_n + 1;
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
                loop_n = loop_n + 1;
            end
            prev_nclk = nclk; prev_addr = addr; have_baseline = 1'b1;
        end
    end

    // ---- program: ROM bootstrap + preload SDRAM with the RAM test program ----
    integer ii;
    initial begin
        for (ii = 0; ii < 8192;  ii = ii + 1) rom[ii] = 16'o000000;
        rom[0] = 16'o000137; rom[1] = 16'o001000;
        for (ii = 0; ii < 16384; ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        u_mem.mem[16'h100] = 16'o012700; u_mem.mem[16'h101] = 16'o002000;
        u_mem.mem[16'h102] = 16'o012701; u_mem.mem[16'h103] = 16'o002000;
        u_mem.mem[16'h104] = 16'o012710; u_mem.mem[16'h105] = 16'o012345;
        u_mem.mem[16'h106] = 16'o010002;
        u_mem.mem[16'h107] = 16'o011002;
        u_mem.mem[16'h108] = 16'o012002;
        u_mem.mem[16'h109] = 16'o012700; u_mem.mem[16'h10A] = 16'o002000;
        u_mem.mem[16'h10B] = 16'o014002;
        u_mem.mem[16'h10C] = 16'o012700; u_mem.mem[16'h10D] = 16'o002000;
        u_mem.mem[16'h10E] = 16'o016002; u_mem.mem[16'h10F] = 16'o000000;
        u_mem.mem[16'h110] = 16'o010011;
        u_mem.mem[16'h111] = 16'o012711; u_mem.mem[16'h112] = 16'o012345;
        u_mem.mem[16'h113] = 16'o010021;
        u_mem.mem[16'h114] = 16'o012701; u_mem.mem[16'h115] = 16'o002000;
        u_mem.mem[16'h116] = 16'o010041;
        u_mem.mem[16'h117] = 16'o012701; u_mem.mem[16'h118] = 16'o002000;
        u_mem.mem[16'h119] = 16'o010061; u_mem.mem[16'h11A] = 16'o000000;
        // RMW (DATIO/DATIOB) coverage - see ref037_tb.v; FAIL park 001124.
        u_mem.mem[16'h11B] = 16'o012700; u_mem.mem[16'h11C] = 16'o002000;
        u_mem.mem[16'h11D] = 16'o005010;
        u_mem.mem[16'h11E] = 16'o005210;
        u_mem.mem[16'h11F] = 16'o062710; u_mem.mem[16'h120] = 16'o000005;
        u_mem.mem[16'h121] = 16'o052710; u_mem.mem[16'h122] = 16'o000120;
        u_mem.mem[16'h123] = 16'o042710; u_mem.mem[16'h124] = 16'o000100;
        u_mem.mem[16'h125] = 16'o105210;
        u_mem.mem[16'h126] = 16'o011002;
        u_mem.mem[16'h127] = 16'o020227; u_mem.mem[16'h128] = 16'o000027;
        u_mem.mem[16'h129] = 16'o001401;
        u_mem.mem[16'h12A] = 16'o000777;                 // RMW FAIL park (001124)
        u_mem.mem[16'h12B] = 16'o005002;
        u_mem.mem[16'h12C] = 16'o000400;
        u_mem.mem[16'h12D] = 16'o012702; u_mem.mem[16'h12E] = 16'o001234;
        u_mem.mem[16'h12F] = 16'o000777;                 // self-loop (001136)
        u_mem.mem[16'h200] = 16'o012345;
    end

    // ---- reset (wait SDRAM init) + 037 register init + sim limit ------------
    reg run_done = 1'b0;
    initial begin
        nclk=0; prev_nclk=0; have_baseline=1'b0;
        rom_oe=0; io_oe=0; rply_ext_n=1'b1;
        rom_data=0; io_data=0;
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0;


        wait (init_done); @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        // run through the golden window (all vblank) and then 64 real display
        // lines of full 4-port contention (~8 ms total)
        wait (disp_lines >= 64);
        if (err_fetch_ovr) $display("FETCH-FLAG-ERROR: fb_video fetch overrun");
        if (err_fifo_ovf)  $display("FETCH-FLAG-ERROR: fb_video fifo overflow");
        if (err_line_ovr)  $display("FETCH-FLAG-ERROR: fb_readout line overrun");
        if (hist_n < 1000) $display("FETCH-FLAG-ERROR: only %0d loop samples", hist_n);
        run_done = 1'b1;
        $finish;
    end

    initial begin
        #12_000_000;                       // 12 ms backstop
        if (!run_done) begin
            $display("FETCH-TIMEOUT-ERROR: display lines never reached");
            $finish;
        end
    end

endmodule
