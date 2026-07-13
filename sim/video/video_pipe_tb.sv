// video_pipe_tb - full Phase-4 chain, pixel-exact against a Python-rendered frame.
//
//   va_037_sync (free-running, tb writes 177664) -> fb_video (palette inside,
//   arbiter ports 2+3) -> SDRAM double-buffered FB -> fb_readout (port 1, paced)
//   -> fb_linebuf -> vga_out -> RGB/sync pins
//
// Real sdram_arbiter + sdram_ctrl + behavioural model; true 3:2 sys:pixel clock
// ratio. Video RAM and the expected decoded framebuffer both come from
// gen_expected.py (run by run_video.sh) - the tb compares EVERY active pixel of
// one full panel frame at the DAC outputs against CLUT(expected fb nibble at
// (hpos/2, vpos/3)), covering fetch, palette, FB layout, double-buffering,
// prefetch scheduling, CDC, x2/x3 scale and CLUT end to end.
//
// This is also the first cosim where readout, video fetch and FB write all
// contend on the arbiter concurrently - the sticky violation flags (fetch
// overrun / FIFO overflow / line-fill overrun) prove the readout pacing keeps
// ports 2/3 inside their slot budget.
`timescale 1ps / 1ps

module video_pipe_tb;

    localparam int AB = 24;
    localparam int DW = 16;
    localparam [23:0] VRAM_BASE = 24'h002000;
    localparam [23:0] FB0_BASE  = 24'h010000;
    localparam [23:0] FB1_BASE  = 24'h018000;
    localparam int V_TOTAL = 806;

    // ---- clocks: exact 3:2 (sys 10348 ps, pixel 15522 ps) --------------------
    reg sys_clk = 1'b0, pix_clk = 1'b0;
    always #5174 sys_clk = ~sys_clk;
    always #7761 pix_clk = ~pix_clk;

    // ---- resets (as ocbk_top: sys immediate, the rest after init_done) --------
    reg [1:0] srst_sr = 2'b00;
    wire      srst_n  = srst_sr[1];
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    wire      init_done;
    reg       dclo = 1'b0;                        // 037 + fb_video reset
    reg [1:0] prst_sr = 2'b00;
    wire      prst_n  = prst_sr[1];
    always @(posedge pix_clk) prst_sr <= {prst_sr[0], init_done};
    wire      ro_rst_n = srst_n & init_done;

    // ---- 037 enables ------------------------------------------------------------
    reg [4:0] divc = 5'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);

    // ---- Q-bus (tb drives 177664 writes only) ------------------------------------
    tri1 [15:0] ad;
    reg  [15:0] ad_drv;
    reg         ad_oe  = 1'b0;
    assign ad = ad_oe ? ad_drv : 16'hZZZZ;
    reg         sync_n = 1'b1, din_n = 1'b1, dout_n = 1'b1, wtbt_n = 1'b1;

    wire        vfetch, line_en, hgate, vgate;
    wire [13:1] video_va;
    va_037_sync u_037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(1'b1), .ext_ram(1'b0),
        .PIN_R(~dclo), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync_n), .PIN_nDIN(din_n), .PIN_nDOUT(dout_n),
        .PIN_nWTBT(wtbt_n), .PIN_nRPLY(),
        .PIN_A(), .PIN_nCAS(), .PIN_nRAS(), .PIN_nWE(),
        .PIN_nE(), .PIN_nBS(), .PIN_WTI(), .PIN_WTD(), .PIN_nVSYNC(),
        .cpu_grant(), .video_va(video_va),
        .vid_fetch(vfetch), .vid_line_en(line_en), .hgate(hgate), .vgate(vgate)
    );

    // ---- write pipeline: fb_video (ports 2+3) -------------------------------------
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [AB-1:0] f_addr, w_addr;
    wire [DW-1:0] w_wdata, arb_rdata;
    wire        fb_front, fb_front_valid, err_fetch_ovr, err_fifo_ovf;

    fb_video #(.ADDR_BITS(AB), .DQ_BITS(DW),
               .FB0_BASE(FB0_BASE), .FB1_BASE(FB1_BASE)) u_fbv (
        .clk(sys_clk), .rst_n(dclo), .screen_mode(1'b1),
        .vram_base(VRAM_BASE), .pal_idx(4'd0),    // bk10: fixed base, palette 0
        .vid_fetch(vfetch), .vid_line_en(line_en), .hgate(hgate), .vgate(vgate),
        .video_va(video_va),
        .f_req(f_req), .f_addr(f_addr), .f_gnt(f_gnt), .f_rvalid(f_rvalid),
        .rdata_i(arb_rdata),
        .w_req(w_req), .w_addr(w_addr), .w_wdata(w_wdata), .w_gnt(w_gnt),
        .fb_front(fb_front), .fb_front_valid(fb_front_valid),
        .err_fetch_ovr(err_fetch_ovr), .err_fifo_ovf(err_fifo_ovf)
    );

    // ---- read pipeline: fb_readout (port 1) + linebuf + vga_out --------------------
    wire       req_tgl;
    wire [7:0] req_line;
    wire       lb_we;
    wire [9:0] lb_waddr, lb_raddr;
    wire [3:0] lb_wdata, lb_rdata;
    wire       ro_req, ro_gnt, ro_rvalid, err_line_ovr;
    wire [AB-1:0] ro_addr;
    wire       hs, vs;
    wire [5:0] r, g, b;

    vga_out u_vga (
        .clk(pix_clk), .rst_n(prst_n),
        .lb_raddr(lb_raddr), .lb_rdata(lb_rdata),
        .req_tgl(req_tgl), .req_line(req_line),
        .fb_valid(fb_front_valid),
        .hsync(hs), .vsync(vs), .r(r), .g(g), .b(b)
    );

    fb_linebuf u_lb (
        .wclk(sys_clk), .we(lb_we), .waddr(lb_waddr), .wdata(lb_wdata),
        .rclk(pix_clk), .raddr(lb_raddr), .rdata(lb_rdata)
    );

    fb_readout #(.ADDR_BITS(AB), .DQ_BITS(DW),
                 .FB0_BASE(FB0_BASE), .FB1_BASE(FB1_BASE)) u_ro (
        .clk(sys_clk), .rst_n(ro_rst_n),
        .req_tgl(req_tgl), .req_line(req_line),
        .fb_front(fb_front),
        .p_req(ro_req), .p_addr(ro_addr), .p_gnt(ro_gnt), .p_rvalid(ro_rvalid),
        .rdata_i(arb_rdata),
        .lb_we(lb_we), .lb_waddr(lb_waddr), .lb_wdata(lb_wdata),
        .err_line_ovr(err_line_ovr)
    );

    // ---- arbiter: [1]=readout [2]=fetch [3]=FB write; [0]=CPU idle -----------------
    localparam int NREQ = 4;
    wire [NREQ-1:0]    p_req    = {w_req, f_req, ro_req, 1'b0};
    wire [NREQ-1:0]    p_we     = {1'b1, 3'b000};
    wire [NREQ*AB-1:0] p_addr   = {w_addr, f_addr, ro_addr, {AB{1'b0}}};
    wire [NREQ*DW-1:0] p_wdata  = {w_wdata, {(3*DW){1'b0}}};
    wire [NREQ*2-1:0]  p_be     = 8'hFF;
    wire [NREQ-1:0]    p_gnt, p_rvalid;
    assign ro_gnt    = p_gnt[1];
    assign ro_rvalid = p_rvalid[1];
    assign f_gnt     = p_gnt[2];
    assign f_rvalid  = p_rvalid[2];
    assign w_gnt     = p_gnt[3];

    wire            cmd_req, cmd_we, cmd_ready, rd_valid;
    wire [AB-1:0]   cmd_addr;
    wire [DW-1:0]   cmd_wdata, rd_data;
    wire [1:0]      cmd_be;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(AB), .DQ_BITS(DW)) u_arb (
        .clk(sys_clk), .rst_n(srst_n),
        .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be),
        .p_gnt(p_gnt), .p_rvalid(p_rvalid), .p_rdata(arb_rdata),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data)
    );

    wire [DW-1:0] dq_out, dq_in, s_dq;
    wire          dq_oe, s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]    s_ba, s_dqm;
    wire [12:0]   s_addr;
    assign s_dq  = dq_oe ? dq_out : {DW{1'bz}};
    assign dq_in = s_dq;

    sdram_ctrl #(.CLK_FREQ_HZ(96_650_000)) u_ctrl (
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

    // ---- expected frame (gen_expected.py) -------------------------------------------
    reg [15:0] vram_img [0:8191];
    reg [15:0] fb_exp   [0:32767];

    // Physical-colour decode (Phase 7, mirrors vga_out.sv): the FB nibble is
    // {R1, B, G, R0}; red levels 0/0x23/0x30/0x3F for R0/R1 weighting.
    function automatic [17:0] clut(input [3:0] idx);   // {r,g,b}
        reg [5:0] rr;
        begin
            case ({idx[3], idx[0]})
                2'b11:   rr = 6'h3F;
                2'b10:   rr = 6'h30;
                2'b01:   rr = 6'h23;
                default: rr = 6'h00;
            endcase
            clut = {rr, idx[1] ? 6'h3F : 6'h00, idx[2] ? 6'h3F : 6'h00};
        end
    endfunction

    // ---- pixel compare (pipeline mirrors, sampled on negedge) ------------------------
    reg [11:0] hp1, hp2, vp1, vp2;
    reg        ap1, ap2;
    always @(posedge pix_clk) begin
        hp1 <= u_vga.hpos;  hp2 <= hp1;
        vp1 <= u_vga.vpos;  vp2 <= vp1;
        ap1 <= u_vga.act_t; ap2 <= ap1;
    end

    integer frame_cnt = 0;
    reg [11:0] vpos_d = 12'd0;
    always @(posedge pix_clk) begin
        if (u_vga.vpos == 12'd0 && vpos_d == V_TOTAL - 1)
            frame_cnt = frame_cnt + 1;
        vpos_d <= u_vga.vpos;
    end

    reg        cmp_en = 1'b0;
    integer    errors = 0, pix_bad = 0, pix_checked = 0;
    reg [15:0] fbw;
    reg [3:0]  idx;
    reg [8:0]  slot;
    reg [7:0]  bkl;
    always @(negedge pix_clk) begin
        if (cmp_en && ap2) begin
            slot = hp2[9:1];
            bkl  = vp2 / 3;
            fbw  = fb_exp[{bkl, slot[8:2]}];
            idx  = fbw[4*slot[1:0] +: 4];
            if ({r, g, b} !== clut(idx)) begin
                if (pix_bad < 10)
                    $display("FAIL: px(%0d,%0d) rgb=%05h exp=%05h idx=%0d",
                             hp2, vp2, {r, g, b}, clut(idx), idx);
                pix_bad = pix_bad + 1;
            end
            pix_checked = pix_checked + 1;
        end
    end

    // ---- Q-bus write to 177664 --------------------------------------------------------
    task qbus_write664(input [15:0] val);
        begin
            @(posedge sys_clk);
            ad_drv = ~16'o177664;  ad_oe = 1'b1;
            repeat (16) @(posedge sys_clk);
            sync_n = 1'b0;
            repeat (8)  @(posedge sys_clk);
            ad_drv = ~val;
            repeat (8)  @(posedge sys_clk);
            dout_n = 1'b0;
            repeat (32) @(posedge sys_clk);
            dout_n = 1'b1;
            repeat (8)  @(posedge sys_clk);
            sync_n = 1'b1;  ad_oe = 1'b0;
            repeat (8)  @(posedge sys_clk);
        end
    endtask

    // ---- stimulus -----------------------------------------------------------------------
    integer i, cmp_frame;
    initial begin
        $readmemh("video/video_ram.hex", vram_img);
        $readmemh("video/fb_exp.hex",    fb_exp);
        for (i = 0; i < 8192; i = i + 1)
            u_mem.mem[VRAM_BASE + i] = vram_img[i];
        for (i = 0; i < 32768; i = i + 1) begin
            u_mem.mem[FB0_BASE + i] = 16'hDEAD;
            u_mem.mem[FB1_BASE + i] = 16'hDEAD;
        end

        wait (init_done);
        repeat (4) @(posedge sys_clk);
        dclo = 1'b1;
        qbus_write664(16'o001330);          // full screen, standard base, mono

        wait (fb_front_valid);              // first complete BK frame in the FB
        wait (frame_cnt >= 1);
        cmp_frame = frame_cnt + 1;          // next panel frame is fully coherent
        wait (frame_cnt == cmp_frame);
        cmp_en = 1'b1;
        wait (frame_cnt == cmp_frame + 1);  // one full compared frame
        cmp_en = 1'b0;
        repeat (4) @(posedge pix_clk);

        if (pix_checked != 1024 * 768) begin
            $display("FAIL: checked %0d pixels (exp %0d)", pix_checked, 1024*768);
            errors = errors + 1;
        end
        if (pix_bad != 0) begin
            $display("FAIL: %0d pixel mismatches", pix_bad);
            errors = errors + 1;
        end
        if (err_fetch_ovr) begin $display("FAIL: err_fetch_ovr"); errors = errors + 1; end
        if (err_fifo_ovf)  begin $display("FAIL: err_fifo_ovf");  errors = errors + 1; end
        if (err_line_ovr)  begin $display("FAIL: err_line_ovr");  errors = errors + 1; end

        $display("pixels checked: %0d, mismatches: %0d", pix_checked, pix_bad);
        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #150_000_000_000;                   // 150 ms backstop
        $display("COSIM FAIL: timeout");
        $finish;
    end

endmodule
