// fb_video - 037 video fetch -> palette_apply -> SDRAM framebuffer writer (Phase 4).
//
// Consumes the va_037_sync Phase-4 taps (vid_fetch / vid_line_en / hgate / vgate /
// video_va) and, per video slot, reads the fetched BK video word over sdram_arbiter
// port 2, decodes it through palette_apply into 16 canonical 4-bit slots, and writes
// them as 4 consecutive FB words over port 3 into the back buffer.
//
// FB destination coordinates come from INDEPENDENT beam counters synced by the
// hgate/vgate edges - NOT from video_va (VA carries the 177664 scroll base, so
// using it as the destination would make scroll a no-op; the fetch *address* is
// VA, the FB *row/word* is the beam position, exactly as on a real CRT).
//
// FB layout (word addresses): fb_base + row*128 + word*4 + k, row 0..255,
// word 0..31 (one fetched BK word -> 4 FB words), k 0..3; slot s of an FB word at
// bits [4s+3:4s], LSB-first in beam order (see palette_apply.sv).
//
// Double buffering: writes go to the back buffer; at the vgate rising edge (frame
// end), once the pipeline has drained, back/front swap and fb_front/_valid publish
// the completed buffer. Everything is in the sys_clk domain - the readout latches
// fb_front when it services its vblank line request (same domain, no CDC here).
//
// Timing budget: one video slot = 8 CLKIN = 128 sys_clk; worst case 1 read +
// 4 writes ~ 50 busy cycles plus contention. One fetch is outstanding at a time;
// the FIFO smooths write bursts across slots. err_fetch_ovr / err_fifo_ovf are
// sticky violation flags for the cosims (never expected to rise).
module fb_video #(
    parameter int ADDR_BITS = 24,
    parameter int DQ_BITS   = 16,
    parameter logic [23:0] FB0_BASE  = 24'h010000,
    parameter logic [23:0] FB1_BASE  = 24'h018000
) (
    input  logic                 clk,        // sys_clk
    input  logic                 rst_n,
    input  logic                 screen_mode, // 1 = mono-512, 0 = colour-256 (static)
    // Video fetch base (word address): bk10 = 24'h002000 (BK 040000, fixed);
    // bk11 = the 177662-selected screen page (BK11_VPAGE0/1). Sampled per
    // fetch - a page flip takes effect at the next fetched word, as on the
    // real hardware (MiSTer applies screen_bank combinationally).
    input  logic [23:0]          vram_base,
    // BK-0011M palette select (177662 bits 11:8); bk10 ties it to 0. Rides
    // with each fetch (dest_pal below), so it is beam-raced like line_en.
    input  logic [3:0]           pal_idx,

    // ---- va_037_sync Phase-4 taps (sys_clk domain) -----------------------
    input  logic                 vid_fetch,
    input  logic                 vid_line_en,
    input  logic                 hgate,
    input  logic                 vgate,
    input  logic [13:1]          video_va,

    // ---- sdram_arbiter port 2: video word fetch (read-only) --------------
    output logic                 f_req,
    output logic [ADDR_BITS-1:0] f_addr,
    input  logic                 f_gnt,
    input  logic                 f_rvalid,
    input  logic [DQ_BITS-1:0]   rdata_i,    // shared arbiter read data

    // ---- sdram_arbiter port 3: FB word write -----------------------------
    output logic                 w_req,
    output logic [ADDR_BITS-1:0] w_addr,
    output logic [DQ_BITS-1:0]   w_wdata,
    input  logic                 w_gnt,

    // ---- front-buffer publication (sys_clk domain) ------------------------
    output logic                 fb_front,       // 0 = FB0 displayed, 1 = FB1
    output logic                 fb_front_valid, // 0 until the first full frame

    // ---- sticky violation flags (cosim assertions) ------------------------
    output logic                 err_fetch_ovr,  // fetch issued while one in flight
    output logic                 err_fifo_ovf    // decode FIFO overflow
);

    // ------------------------------------------------------------------
    // Beam position counters (synced by the hgate/vgate edges)
    // ------------------------------------------------------------------
    logic       hgate_d, vgate_d;
    logic       frame_first;      // next line start is display row 0
    logic [7:0] row;
    logic [4:0] word_idx;
    logic       swap_pending;

    wire line_start = ~hgate & hgate_d & ~vgate;   // entering an active line
    wire frame_end  =  vgate & ~vgate_d;           // entering vertical blank

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hgate_d     <= 1'b0;
            vgate_d     <= 1'b1;
            frame_first <= 1'b1;
            row         <= '0;
            word_idx    <= '0;
        end else begin
            hgate_d <= hgate;
            vgate_d <= vgate;
            if (line_start) begin
                word_idx    <= '0;
                row         <= frame_first ? 8'd0 : row + 8'd1;
                frame_first <= 1'b0;
            end else if (vid_fetch)
                word_idx <= word_idx + 5'd1;
            if (frame_end)
                frame_first <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Fetch FSM (arbiter port 2): one video word per vid_fetch pulse
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { F_IDLE, F_REQ, F_WAIT } fstate_t;
    fstate_t    fstate;
    logic [7:0] dest_row;
    logic [4:0] dest_word;
    logic       dest_len;         // vid_line_en latched with the fetch
    logic [3:0] dest_pal;         // pal_idx latched with the fetch

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate        <= F_IDLE;
            f_req         <= 1'b0;
            f_addr        <= '0;
            dest_row      <= '0;
            dest_word     <= '0;
            dest_len      <= 1'b0;
            dest_pal      <= '0;
            err_fetch_ovr <= 1'b0;
        end else begin
            if (vid_fetch && fstate != F_IDLE)
                err_fetch_ovr <= 1'b1;          // slot overrun: previous fetch alive
            case (fstate)
                F_IDLE: if (vid_fetch) begin
                    f_addr    <= vram_base + ADDR_BITS'(video_va);
                    dest_row  <= row;
                    dest_word <= word_idx;
                    dest_len  <= vid_line_en;
                    dest_pal  <= pal_idx;
                    f_req     <= 1'b1;
                    fstate    <= F_REQ;
                end
                F_REQ:  if (f_gnt)    begin f_req <= 1'b0; fstate <= F_WAIT; end
                F_WAIT: if (f_rvalid) fstate <= F_IDLE;
                default: fstate <= F_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Palette stage + decode FIFO ({row, word, 16 slots} per fetched word)
    // ------------------------------------------------------------------
    wire [63:0] pal_slots;
    palette_apply u_pal (
        .screen_mode (screen_mode),
        .line_en     (dest_len),
        .pal_idx     (dest_pal),
        .word        (rdata_i),
        .slots       (pal_slots)
    );

    localparam int FIFO_W = 8 + 5 + 64;
    logic [FIFO_W-1:0] fifo [0:7];
    logic [2:0]        f_wr, f_rd;
    logic [3:0]        f_cnt;

    // Write FSM state (declared here: pop is a FIFO/W-FSM handshake)
    typedef enum logic [1:0] { W_IDLE, W_REQ, W_GAP } wstate_t;
    wstate_t    wstate;
    logic [1:0] k;
    logic [63:0] slots_w;

    wire push = (fstate == F_WAIT) && f_rvalid;
    wire pop  = (wstate == W_IDLE) && (f_cnt != 0);
    wire [FIFO_W-1:0] head = fifo[f_rd];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_wr <= '0; f_rd <= '0; f_cnt <= '0;
            err_fifo_ovf <= 1'b0;
        end else begin
            if (push) begin
                fifo[f_wr] <= {dest_row, dest_word, pal_slots};
                f_wr       <= f_wr + 3'd1;
                if (f_cnt == 4'd8 && !pop) err_fifo_ovf <= 1'b1;
            end
            if (pop) f_rd <= f_rd + 3'd1;
            f_cnt <= f_cnt + (push ? 4'd1 : 4'd0) - (pop ? 4'd1 : 4'd0);
        end
    end

    // ------------------------------------------------------------------
    // Write FSM (arbiter port 3): 4 FB words per FIFO entry.
    // req drops for one cycle after each grant (arbiter served contract).
    // ------------------------------------------------------------------
    logic back;                    // buffer being written
    wire [23:0] fb_base = back ? FB1_BASE : FB0_BASE;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate  <= W_IDLE;
            w_req   <= 1'b0;
            w_addr  <= '0;
            slots_w <= '0;
            k       <= '0;
        end else begin
            case (wstate)
                W_IDLE: if (pop) begin
                    // head = {row[7:0], word[4:0], slots[63:0]}
                    w_addr  <= fb_base + ADDR_BITS'({head[76:69], head[68:64], 2'b00});
                    slots_w <= head[63:0];
                    k       <= 2'd0;
                    w_req   <= 1'b1;
                    wstate  <= W_REQ;
                end
                W_REQ: if (w_gnt) begin
                    w_req <= 1'b0;
                    if (k == 2'd3)
                        wstate <= W_IDLE;
                    else begin
                        k      <= k + 2'd1;
                        w_addr <= w_addr + 24'd1;
                        wstate <= W_GAP;
                    end
                end
                W_GAP: begin
                    w_req  <= 1'b1;
                    wstate <= W_REQ;
                end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    assign w_wdata = slots_w[16*k +: 16];

    // ------------------------------------------------------------------
    // Double-buffer swap at frame end, once the pipeline has drained
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            back           <= 1'b0;
            fb_front       <= 1'b0;
            fb_front_valid <= 1'b0;
            swap_pending   <= 1'b0;
        end else begin
            if (frame_end)
                swap_pending <= 1'b1;
            else if (swap_pending && fstate == F_IDLE && wstate == W_IDLE
                     && f_cnt == 0) begin
                fb_front       <= back;
                back           <= ~back;
                fb_front_valid <= 1'b1;
                swap_pending   <= 1'b0;
            end
        end
    end

endmodule
