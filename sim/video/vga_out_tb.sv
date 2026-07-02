// vga_out + fb_readout + fb_linebuf readout-chain cosim.
//
// True 3:2 clock ratio (sys 96.65 / pixel 64.43 MHz, timescale 1ps), real
// sdram_arbiter + sdram_ctrl + behavioural model with FB0 preloaded directly
// (fb_video bypassed; fb_front pinned to FB0). Checks:
//   * H total = 1344 clk, hsync low = 136 clk, negative polarity
//   * V total = 806 lines, vsync low = 6 lines, negative polarity
//   * from the 2nd frame on (all banks filled): EVERY active pixel equals
//     CLUT(fb nibble at (hpos/2, vpos/3)) - x2H/x3V scale, slot/bit order,
//     CLUT values, prefetch-before-display all covered by the compare
//   * RGB black outside active; err_line_ovr stays 0
`timescale 1ps / 1ps

module vga_out_tb;

    localparam int AB = 24;
    localparam int DW = 16;
    localparam [23:0] FB0_BASE = 24'h010000;
    localparam [23:0] FB1_BASE = 24'h018000;
    localparam int H_TOTAL = 1344;
    localparam int V_TOTAL = 806;

    // ---- clocks: exact 3:2 (sys 10348 ps, pixel 15522 ps) --------------------
    reg sys_clk = 1'b0, pix_clk = 1'b0;
    always #5174 sys_clk = ~sys_clk;
    always #7761 pix_clk = ~pix_clk;

    // sys reset releases immediately; the readout + pixel side are held until
    // SDRAM init_done (as ocbk_top holds the system), so no line requests pile
    // up against a not-yet-ready controller.
    reg [1:0] srst_sr = 2'b00;
    wire      srst_n  = srst_sr[1];
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    wire      init_done;
    reg [1:0] prst_sr = 2'b00;
    wire      prst_n  = prst_sr[1];
    always @(posedge pix_clk) prst_sr <= {prst_sr[0], init_done};
    wire      ro_rst_n = srst_n & init_done;

    // ---- DUT chain ------------------------------------------------------------
    wire       req_tgl;
    wire [7:0] req_line;
    wire       lb_we;
    wire [9:0] lb_waddr, lb_raddr;
    wire [3:0] lb_wdata, lb_rdata;
    wire       ro_req, ro_gnt, ro_rvalid, err_line_ovr;
    wire [AB-1:0] ro_addr;
    wire [DW-1:0] arb_rdata;
    wire       hs, vs;
    wire [5:0] r, g, b;

    vga_out u_vga (
        .clk(pix_clk), .rst_n(prst_n),
        .lb_raddr(lb_raddr), .lb_rdata(lb_rdata),
        .req_tgl(req_tgl), .req_line(req_line),
        .fb_valid(1'b1),
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
        .fb_front(1'b0),
        .p_req(ro_req), .p_addr(ro_addr), .p_gnt(ro_gnt), .p_rvalid(ro_rvalid),
        .rdata_i(arb_rdata),
        .lb_we(lb_we), .lb_waddr(lb_waddr), .lb_wdata(lb_wdata),
        .err_line_ovr(err_line_ovr)
    );

    // ---- arbiter (port 1 = readout; 0/2/3 idle) --------------------------------
    localparam int NREQ = 4;
    wire [NREQ-1:0]    p_req   = {2'b00, ro_req, 1'b0};
    wire [NREQ*AB-1:0] p_addr  = {{(2*AB){1'b0}}, ro_addr, {AB{1'b0}}};
    wire [NREQ-1:0]    p_gnt, p_rvalid;
    assign ro_gnt    = p_gnt[1];
    assign ro_rvalid = p_rvalid[1];

    wire            cmd_req, cmd_we, cmd_ready, rd_valid;
    wire [AB-1:0]   cmd_addr;
    wire [DW-1:0]   cmd_wdata, rd_data;
    wire [1:0]      cmd_be;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(AB), .DQ_BITS(DW)) u_arb (
        .clk(sys_clk), .rst_n(srst_n),
        .p_req(p_req), .p_we({NREQ{1'b0}}), .p_addr(p_addr),
        .p_wdata({(NREQ*DW){1'b0}}), .p_be({(NREQ*2){1'b1}}),
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

    // ---- expected-pixel model ---------------------------------------------------
    function automatic [17:0] clut(input [3:0] idx);   // {r,g,b}
        case (idx)
            4'd1:    clut = {6'h00, 6'h00, 6'h3F};
            4'd2:    clut = {6'h00, 6'h3F, 6'h00};
            4'd3:    clut = {6'h3F, 6'h00, 6'h00};
            4'd15:   clut = {6'h3F, 6'h3F, 6'h3F};
            default: clut = 18'h0;
        endcase
    endfunction

    // pipeline mirrors (compare on negedge: post-edge values settled)
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

    integer errors = 0, pix_bad = 0, pix_checked = 0;
    reg [15:0] fbw;
    reg [3:0]  idx;
    reg [17:0] exp;
    reg [8:0]  slot;
    reg [7:0]  bkl;
    always @(negedge pix_clk) begin
        if (frame_cnt >= 1 && frame_cnt < 3) begin
            if (ap2) begin
                slot = hp2[9:1];
                bkl  = vp2 / 3;
                fbw  = u_mem.mem[FB0_BASE + {bkl, slot[8:2]}];
                idx  = fbw[4*slot[1:0] +: 4];
                exp  = clut(idx);
                if ({r, g, b} !== exp) begin
                    if (pix_bad < 10)
                        $display("FAIL: px(%0d,%0d) rgb=%05h exp=%05h idx=%0d",
                                 hp2, vp2, {r, g, b}, exp, idx);
                    pix_bad = pix_bad + 1;
                end
                pix_checked = pix_checked + 1;
            end else if ({r, g, b} !== 18'h0) begin
                if (pix_bad < 10)
                    $display("FAIL: blanking not black at (%0d,%0d)", hp2, vp2);
                pix_bad = pix_bad + 1;
            end
        end
    end

    // ---- sync geometry checks ----------------------------------------------------
    integer hs_low = 0, hs_period = 0, vs_low_lines = 0, lines_frame = 0;
    reg hs_d = 1'b1, vs_d = 1'b1;
    always @(negedge pix_clk) begin
        hs_period = hs_period + 1;
        if (!hs) hs_low = hs_low + 1;
        if (hs & ~hs_d) begin                       // hsync rise: end of pulse
            if (frame_cnt >= 1 && hs_low != 136) begin
                $display("FAIL: hsync low %0d clk (exp 136)", hs_low);
                errors = errors + 1;
            end
            hs_low = 0;
        end
        if (~hs & hs_d) begin                       // hsync fall: line boundary
            if (frame_cnt >= 1 && hs_period != H_TOTAL) begin
                $display("FAIL: line period %0d clk (exp %0d)", hs_period, H_TOTAL);
                errors = errors + 1;
            end
            hs_period = 0;
            lines_frame = lines_frame + 1;
            if (!vs) vs_low_lines = vs_low_lines + 1;
            if (vs & ~vs_d) begin                   // vsync ended this line
                if (frame_cnt >= 1 && vs_low_lines != 6) begin
                    $display("FAIL: vsync low %0d lines (exp 6)", vs_low_lines);
                    errors = errors + 1;
                end
                vs_low_lines = 0;
            end
            if (~vs & vs_d) begin                   // vsync start: frame marker
                if (frame_cnt >= 1 && lines_frame != V_TOTAL) begin
                    $display("FAIL: %0d lines/frame (exp %0d)", lines_frame, V_TOTAL);
                    errors = errors + 1;
                end
                lines_frame = 0;
            end
            vs_d = vs;
        end
        hs_d = hs;
    end

    // ---- stimulus -----------------------------------------------------------------
    integer i;
    initial begin
        // FB0: pattern hitting all 16 indices; FB1 poisoned
        for (i = 0; i < 32768; i = i + 1) begin
            u_mem.mem[FB0_BASE + i] = i[15:0] ^ {i[8:0], 7'd0} ^ 16'h9E37;
            u_mem.mem[FB1_BASE + i] = 16'hDEAD;
        end

        wait (frame_cnt == 3);
        if (pix_checked != 2 * 1024 * 768) begin
            $display("FAIL: checked %0d pixels (exp %0d)", pix_checked, 2*1024*768);
            errors = errors + 1;
        end
        if (pix_bad != 0) begin
            $display("FAIL: %0d pixel mismatches", pix_bad);
            errors = errors + 1;
        end
        if (err_line_ovr) begin
            $display("FAIL: err_line_ovr");
            errors = errors + 1;
        end
        $display("pixels checked: %0d, mismatches: %0d", pix_checked, pix_bad);
        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #80_000_000_000;                    // 80 ms backstop
        $display("COSIM FAIL: timeout");
        $finish;
    end

endmodule
