// fb_video cosim: va_037_sync (free-running video side) + fb_video (palette_apply
// inside) + sdram_arbiter + sdram_ctrl + behavioural sdram_model.
//
// The tb plays the CPU only for 177664 scroll-register writes (the 037's own
// register); no other bus traffic. Video RAM (word 0x2000..0x3FFF) is preloaded
// with a deterministic pattern; an expected framebuffer is accumulated per
// vid_fetch from the TAPPED video_va/vid_line_en (ground truth = the netlist-
// derived 037) and compared word-for-word against the SDRAM back buffer at each
// front-buffer swap.
//
// Frames exercised:
//   A: mono,   full screen (177664 = 0o1330, RA = 0o330 -> screen top = 040000)
//   B: colour, mid-frame scroll write (RA change lands mid-display, per-fetch
//      expected model follows it exactly as the beam does)
//   C: colour, quarter mode (M256 = 0): only 64 rows enabled, rest forced 0
//
// Also checks: scroll convention (row 0 fetches VA[13:6] = RA - 0o330), exactly
// 32 fetches/line and 256 display lines/frame, sticky error flags stay 0.
`timescale 1ns / 1ps

module fb_video_tb;

    localparam int AB = 24;
    localparam int DW = 16;
    localparam [23:0] VRAM_BASE = 24'h002000;
    localparam [23:0] FB0_BASE  = 24'h010000;
    localparam [23:0] FB1_BASE  = 24'h018000;

    // ---- clocks + enables (as ocbk_top / ref037_soc_tb) ----------------------
    reg       sys_clk = 1'b0;
    reg [4:0] divc    = 5'd0;
    always #5 sys_clk = ~sys_clk;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);

    // ---- resets ---------------------------------------------------------------
    reg  [1:0] srst_sr = 2'b00;
    wire       srst_n  = srst_sr[1];
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg        dclo = 1'b0;                       // 037 + fb_video reset (active low)

    // ---- Q-bus (tb drives 177664 writes only) ---------------------------------
    tri1 [15:0] ad;
    reg  [15:0] ad_drv;
    reg         ad_oe   = 1'b0;
    assign ad = ad_oe ? ad_drv : 16'hZZZZ;
    reg         sync_n = 1'b1, din_n = 1'b1, dout_n = 1'b1, wtbt_n = 1'b1;

    // ---- 037 -------------------------------------------------------------------
    wire        vfetch, line_en, hgate, vgate;
    wire [13:1] video_va;
    va_037_sync u_037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(1'b1),
        .PIN_R(~dclo), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync_n), .PIN_nDIN(din_n), .PIN_nDOUT(dout_n),
        .PIN_nWTBT(wtbt_n), .PIN_nRPLY(),
        .PIN_A(), .PIN_nCAS(), .PIN_nRAS(), .PIN_nWE(),
        .PIN_nE(), .PIN_nBS(), .PIN_WTI(), .PIN_WTD(), .PIN_nVSYNC(),
        .cpu_grant(), .video_va(video_va),
        .vid_fetch(vfetch), .vid_line_en(line_en), .hgate(hgate), .vgate(vgate)
    );

    // ---- DUT: fb_video ----------------------------------------------------------
    reg         screen_mode = 1'b1;               // start mono
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [AB-1:0] f_addr, w_addr;
    wire [DW-1:0] w_wdata, arb_rdata;
    wire        fb_front, fb_front_valid, err_fetch_ovr, err_fifo_ovf;

    fb_video #(.ADDR_BITS(AB), .DQ_BITS(DW), .VRAM_BASE(VRAM_BASE),
               .FB0_BASE(FB0_BASE), .FB1_BASE(FB1_BASE)) u_fbv (
        .clk(sys_clk), .rst_n(dclo), .screen_mode(screen_mode),
        .vid_fetch(vfetch), .vid_line_en(line_en), .hgate(hgate), .vgate(vgate),
        .video_va(video_va),
        .f_req(f_req), .f_addr(f_addr), .f_gnt(f_gnt), .f_rvalid(f_rvalid),
        .rdata_i(arb_rdata),
        .w_req(w_req), .w_addr(w_addr), .w_wdata(w_wdata), .w_gnt(w_gnt),
        .fb_front(fb_front), .fb_front_valid(fb_front_valid),
        .err_fetch_ovr(err_fetch_ovr), .err_fifo_ovf(err_fifo_ovf)
    );

    // ---- arbiter (port 2 = fetch, port 3 = FB write; 0/1 idle) ------------------
    localparam int NREQ = 4;
    wire [NREQ-1:0]    p_req    = {w_req, f_req, 2'b00};
    wire [NREQ-1:0]    p_we     = {1'b1,  3'b000};
    wire [NREQ*AB-1:0] p_addr   = {w_addr, f_addr, {(2*AB){1'b0}}};
    wire [NREQ*DW-1:0] p_wdata  = {w_wdata, {(3*DW){1'b0}}};
    wire [NREQ*2-1:0]  p_be     = 8'hFF;
    wire [NREQ-1:0]    p_gnt, p_rvalid;
    assign f_gnt    = p_gnt[2];
    assign f_rvalid = p_rvalid[2];
    assign w_gnt    = p_gnt[3];

    wire            cmd_req, cmd_we, cmd_ready, rd_valid, init_done;
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

    wire [DW-1:0] dq_out, dq_in;
    wire          dq_oe;
    wire [DW-1:0] s_dq;
    wire          s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
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

    // ---- expected-FB model (mirrors the conventions, fed by the 037 taps) -------
    function automatic [63:0] pal_model(input [15:0] w, input le, input mono);
        integer s;
        for (s = 0; s < 16; s = s + 1)
            pal_model[4*s +: 4] = !le  ? 4'd0
                                : mono ? (w[s] ? 4'd15 : 4'd0)
                                : {2'b00, w[2*(s/2) +: 2]};
    endfunction

    reg [15:0] exp_fb [0:32767];
    reg        hgate_d = 1'b0, vgate_d = 1'b1;
    reg        t_first = 1'b1;
    reg [7:0]  t_row = 8'd0;
    reg [4:0]  t_word = 5'd0;
    reg [7:0]  ra_now = 8'd0;            // RA the tb last wrote
    reg [7:0]  ra_eff = 8'd0;            // RA in effect this frame (ALOAD is in vblank)
    reg [7:0]  va_exp;
    reg        mode_eff = 1'b1;
    integer    line_fetches = 0, disp_lines = 0, en_rows = 0, errors = 0;
    integer    scroll_bad = 0;
    reg [63:0] slots;
    integer    k;

    always @(posedge sys_clk) begin
        hgate_d <= hgate;  vgate_d <= vgate;

        if (~vgate & vgate_d) begin                          // display (frame) start
            ra_eff   = ra_now;
            mode_eff = screen_mode;
        end

        if (~hgate & hgate_d & ~vgate) begin                 // line start
            if (line_fetches != 0 && line_fetches != 32) begin
                $display("FAIL: %0d fetches in a display line", line_fetches);
                errors = errors + 1;
            end
            line_fetches = 0;
            t_word = 5'd0;
            t_row  = t_first ? 8'd0 : t_row + 8'd1;
            t_first = 1'b0;
            disp_lines = disp_lines + 1;
        end

        if (vfetch) begin
            line_fetches = line_fetches + 1;
            if (line_fetches == 1 && line_en) en_rows = en_rows + 1;
            // scroll convention: row r fetches VA[13:6] = RA - 0o330 + r (mod 256)
            va_exp = ra_eff - 8'o330 + t_row;
            if (t_word == 0 && video_va[13:6] !== va_exp) begin
                if (scroll_bad < 8)
                    $display("FAIL: row %0d VA[13:6]=%03o expected %03o (RA=%03o)",
                             t_row, video_va[13:6], va_exp, ra_eff);
                scroll_bad = scroll_bad + 1;
                errors = errors + 1;
            end
            slots = pal_model(u_mem.mem[VRAM_BASE + video_va], line_en, screen_mode);
            for (k = 0; k < 4; k = k + 1)
                exp_fb[{t_row, t_word, k[1:0]}] = slots[16*k +: 16];
            t_word = t_word + 5'd1;
        end

        if (vgate & ~vgate_d) begin                          // frame end
            t_first = 1'b1;
        end
    end

    // ---- compare at each swap -----------------------------------------------
    reg fbv_d = 1'b0, fbf_d = 1'b0;
    integer i, frame_n = 0, miss;
    reg [23:0] base;
    always @(posedge sys_clk) begin
        fbv_d <= fb_front_valid;  fbf_d <= fb_front;
        if ((fb_front_valid & ~fbv_d) || (fb_front_valid && (fb_front ^ fbf_d))) begin
            frame_n = frame_n + 1;
            base = fb_front ? FB1_BASE : FB0_BASE;
            miss = 0;
            for (i = 0; i < 32768; i = i + 1)
                if (u_mem.mem[base + i] !== exp_fb[i]) begin
                    if (miss < 5)
                        $display("FAIL: frame %0d fb[%05h] = %04h expected %04h",
                                 frame_n, i, u_mem.mem[base + i], exp_fb[i]);
                    miss = miss + 1;
                end
            if (miss != 0) errors = errors + 1;
            $display("frame %0d: %s (mode=%s lines=%0d en_rows=%0d mism=%0d)",
                     frame_n, miss ? "MISMATCH" : "ok",
                     mode_eff ? "mono" : "colour", disp_lines, en_rows, miss);
            if (disp_lines != 256) begin
                $display("FAIL: frame %0d had %0d display lines", frame_n, disp_lines);
                errors = errors + 1;
            end
            disp_lines = 0;  en_rows = 0;
        end
    end

    // ---- Q-bus write to 177664 (the 037's scroll register) --------------------
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
            repeat (32) @(posedge sys_clk);      // RWR loads RA/M256 (rply is comb)
            dout_n = 1'b1;
            repeat (8)  @(posedge sys_clk);
            sync_n = 1'b1;  ad_oe = 1'b0;
            repeat (8)  @(posedge sys_clk);
            ra_now = val[7:0];
        end
    endtask

    // ---- stimulus --------------------------------------------------------------
    integer f;
    initial begin
        // video RAM pattern + poison both FBs
        for (f = 0; f < 8192; f = f + 1)
            u_mem.mem[VRAM_BASE + f] = 16'hA5A5 ^ f[15:0] ^ {f[12:0], 3'b000};
        for (f = 0; f < 32768; f = f + 1) begin
            u_mem.mem[FB0_BASE + f] = 16'hDEAD;
            u_mem.mem[FB1_BASE + f] = 16'hDEAD;
        end

        wait (init_done);
        repeat (4) @(posedge sys_clk);
        dclo = 1'b1;                              // release 037 + fb_video

        // frame A setup: full screen, standard base, mono
        qbus_write664(16'o001330);
        screen_mode = 1'b1;

        @(posedge fb_front_valid);                // frame A compared above

        // frame B: colour + mid-frame scroll change
        screen_mode = 1'b0;
        wait (~vgate);                            // inside display
        repeat (200000) @(posedge sys_clk);       // ~mid-frame
        qbus_write664(16'o001123);                // RA=0o123, still full screen
        @(fb_front);                              // frame B swap

        // frame C: quarter mode (M256=0); the write lands in early vblank,
        // before this frame's ALOAD, so it is in effect for the whole frame
        wait (vgate);
        qbus_write664(16'o000330);
        @(fb_front);                              // frame C swap
        repeat (16) @(posedge sys_clk);           // let the compare block report

        if (err_fetch_ovr) begin $display("FAIL: err_fetch_ovr"); errors = errors + 1; end
        if (err_fifo_ovf)  begin $display("FAIL: err_fifo_ovf");  errors = errors + 1; end

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;                             // 200 ms backstop
        $display("COSIM FAIL: timeout");
        $finish;
    end

endmodule
