//
// Phase-5 MONITOR/BASIC boot smoke cosim (slow, manual - run_boot_check.sh,
// NOT part of make sim).
//
// The REAL BK-0010.01 ROM blob (mem/boot_blob_flash.hex) is preloaded directly
// into the SDRAM model ROM region (the EPCS loader path has its own gates:
// run_epcs_boot.sh + the ref037 +bootload golden run) and the full SoC - CPU,
// va_037_sync, qbus_mem_sdram, complete video pipeline on all 4 arbiter ports -
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
// Prints BOOTCHK-* lines; run_boot_check.sh greps for the final verdict.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module boot_check_tb;

    localparam int AB = 24;
    localparam int DW = 16;
    localparam integer VID_TARGET = 200;    // video-RAM writes to declare victory
    localparam integer TRACE_N    = 5000;   // bus transactions to dump

    // ---- clocks (as ref037_soc_video_tb) --------------------------------------
    reg       sys_clk;
    reg [4:0] divc;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 5'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);
    wire clk    = divc[4];

    reg pix_clk = 1'b0;
    always #7.5 pix_clk = ~pix_clk;

    // ---- Q-bus ----------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU -------------------------------------------------------------------
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

    // ---- retimed 037 -------------------------------------------------------------
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

    // ---- real video pipeline (ports 1/2/3) ----------------------------------------
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [AB-1:0] f_addr, w_addr;
    wire [DW-1:0] w_wdata;
    wire [DW-1:0] arb_rdata;
    wire        fb_front, fb_front_valid;

    fb_video #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_fbv (
        .clk(sys_clk), .rst_n(dclo), .screen_mode(1'b1),
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

    // ---- integration module + SDRAM model ------------------------------------------
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;

    qbus_mem_sdram #(.MEMFILE("ref037/boot_stub.hex")) u_ms (
        .cpu_clk  (~clk),
        .reset    (~dclo),
        .rom_ext_en(1'b1),           // the real ROM lives in SDRAM
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
        .v1_req   (ro_req),  .v1_addr(ro_addr),  .v1_gnt(ro_gnt), .v1_rvalid(ro_rvalid),
        .v2_req   (f_req),   .v2_addr(f_addr),   .v2_gnt(f_gnt),  .v2_rvalid(f_rvalid),
        .v3_req   (w_req),   .v3_addr(w_addr),   .v3_wdata(w_wdata), .v3_gnt(w_gnt),
        .v_rdata  (arb_rdata),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
        .bus_addr (),
        .fetch_stb()
    );

    sdram_model u_mem (
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
    always @(negedge rply) if (aclo === 1'b1) begin
        if (!dout && !wr_seen) begin
            wr_seen = 1;
            if (addr >= 16'o040000 && addr < 16'o100000) begin
                vid_writes = vid_writes + 1;
                if (vid_writes <= 4 || vid_writes == VID_TARGET)
                    $display("BOOTCHK: video-RAM write #%0d: [%06o] <= %06o t=%0t",
                             vid_writes, addr, ~ad, $time);
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

    // finish as soon as the screen clear is well underway
    always @(vid_writes) begin
        if (vid_writes >= VID_TARGET) begin
            if (xerrs == 0) $display("BOOTCHK: PASS");
            else            $display("BOOTCHK: FAIL (%0d X errors)", xerrs);
            $fclose(tracef);
            $finish;
        end
    end

    // ---- ROM preload (real blob, direct) + reset ------------------------------------
    reg [7:0] blob [0:(1<<19)-1];
    integer ii;
    initial begin
        wr_seen = 0;
        tracef = $fopen("boot_trace.txt", "w");
        $readmemh("../mem/boot_blob_flash.hex", blob, 'h40000);
        for (ii = 0; ii < (1<<17); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        for (ii = 0; ii < 16320; ii = ii + 1)
            u_mem.mem[16'h4000 + ii] =
                {blob['h40008 + 2*ii + 1], blob['h40008 + 2*ii]};

        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0;

        wait (init_done); @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;
        $display("BOOTCHK: CPU released, MONITOR cold boot from SDRAM ROM...");
    end

    initial begin
        #60_000_000;                         // 60 ms bound
        $display("BOOTCHK-TIMEOUT: only %0d video-RAM writes (%0d X errors)",
                 vid_writes, xerrs);
        $display("BOOTCHK: FAIL");
        $fclose(tracef);
        $finish;
    end

endmodule
