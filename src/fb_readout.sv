// fb_readout - paced framebuffer line prefetcher (Phase 4, sys_clk domain).
//
// Services line requests from the pixel side (vga_out): on each request it reads
// the 128 FB words of BK line L from the front buffer over sdram_arbiter port 1
// and writes them as 512 nibbles into the fb_linebuf bank L[0]. The pixel side
// requests a full line-TRIPLE ahead (62.6 us window), so the paced fill
// (128 x PACE sys_clk ~ 32 us) always completes before the bank is displayed.
//
// PACING IS LOAD-BEARING, not an optimization: the arbiter is fixed-priority with
// no fairness, and readout (port 1) outranks the 037 fetch (2) and FB write (3) -
// an unpaced 128-word burst would starve them for a whole line. One read is
// issued at most every PACE cycles (default 24 ~ <=40% of the single-word SDRAM
// ceiling during a fill).
//
// CDC: req_tgl is a pixel-domain toggle, 2-FF synced here; req_line is set on the
// same pixel edge as the toggle and stays stable until the next request (>=1 output
// line, ~21 us), so sampling it at the synced edge is race-free. fb_front (from
// fb_video, sys domain) is latched only when servicing the line-0 request - the
// vblank point - so a whole panel frame reads one coherent buffer.
module fb_readout #(
    parameter int ADDR_BITS = 24,
    parameter int DQ_BITS   = 16,
    parameter logic [23:0] FB0_BASE = 24'h010000,
    parameter logic [23:0] FB1_BASE = 24'h018000,
    parameter int PACE      = 24    // min sys_clk between issued reads
) (
    input  logic                 clk,       // sys_clk
    input  logic                 rst_n,

    // ---- request from the pixel side (vga_out) ---------------------------
    input  logic                 req_tgl,   // pixel-domain toggle
    input  logic [7:0]           req_line,  // BK line to fetch (stable at toggle)

    // ---- front buffer publication from fb_video (sys domain) -------------
    input  logic                 fb_front,

    // ---- sdram_arbiter port 1 (read-only) --------------------------------
    output logic                 p_req,
    output logic [ADDR_BITS-1:0] p_addr,
    input  logic                 p_gnt,
    input  logic                 p_rvalid,
    input  logic [DQ_BITS-1:0]   rdata_i,

    // ---- fb_linebuf write port --------------------------------------------
    output logic                 lb_we,
    output logic [9:0]           lb_waddr,
    output logic [3:0]           lb_wdata,

    // ---- sticky violation flag (cosim assertion) --------------------------
    output logic                 err_line_ovr  // request arrived mid-fill
);

    // ---- toggle synchronizer ------------------------------------------------
    logic [2:0] tgl_sr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) tgl_sr <= '0;
        else        tgl_sr <= {tgl_sr[1:0], req_tgl};
    wire tgl_edge = tgl_sr[2] ^ tgl_sr[1];

    // ---- fill FSM -------------------------------------------------------------
    typedef enum logic [1:0] { R_IDLE, R_REQ, R_WAIT, R_PACE } rstate_t;
    rstate_t          state;
    logic [7:0]       line_l;
    logic [23:0]      base;
    logic [6:0]       w;          // FB word within the line (0..127)
    logic [4:0]       pace_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= R_IDLE;
            p_req        <= 1'b0;
            p_addr       <= '0;
            line_l       <= '0;
            base         <= FB0_BASE;
            w            <= '0;
            pace_cnt     <= '0;
            err_line_ovr <= 1'b0;
        end else begin
            if (pace_cnt != 0) pace_cnt <= pace_cnt - 5'd1;
            if (tgl_edge && state != R_IDLE)
                err_line_ovr <= 1'b1;
            case (state)
                R_IDLE: if (tgl_edge) begin
                    line_l   <= req_line;
                    // vblank (line 0) request = the frame-coherency latch point
                    base     <= (req_line == 8'd0) ? (fb_front ? FB1_BASE : FB0_BASE)
                                                   : base;
                    w        <= '0;
                    p_addr   <= ((req_line == 8'd0) ? (fb_front ? FB1_BASE : FB0_BASE)
                                                    : base)
                                + ADDR_BITS'({req_line, 7'd0});
                    p_req    <= 1'b1;
                    pace_cnt <= 5'(PACE - 1);
                    state    <= R_REQ;
                end
                R_REQ:  if (p_gnt) begin p_req <= 1'b0; state <= R_WAIT; end
                R_WAIT: if (p_rvalid) begin
                    if (w == 7'd127) state <= R_IDLE;
                    else begin
                        w     <= w + 7'd1;
                        state <= R_PACE;
                    end
                end
                R_PACE: if (pace_cnt == 0) begin
                    p_addr   <= base + ADDR_BITS'({line_l, w});
                    p_req    <= 1'b1;
                    pace_cnt <= 5'(PACE - 1);
                    state    <= R_REQ;
                end
                default: state <= R_IDLE;
            endcase
        end
    end

    // ---- nibble writer: 4 line-buffer nibbles per returned word ---------------
    logic [15:0] nib_word;
    logic [2:0]  nib_cnt;
    logic [6:0]  nib_w;
    logic [1:0]  nib_k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nib_cnt  <= '0;
            nib_word <= '0;
            nib_w    <= '0;
            nib_k    <= '0;
        end else if (state == R_WAIT && p_rvalid) begin
            nib_word <= rdata_i;
            nib_w    <= w;
            nib_k    <= 2'd0;
            nib_cnt  <= 3'd4;
        end else if (nib_cnt != 0) begin
            nib_cnt <= nib_cnt - 3'd1;
            nib_k   <= nib_k + 2'd1;
        end
    end

    assign lb_we    = (nib_cnt != 0);
    assign lb_waddr = {line_l[0], nib_w, nib_k};
    assign lb_wdata = nib_word[4*nib_k +: 4];

endmodule
