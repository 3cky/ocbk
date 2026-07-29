// vga_out - 1024x768@60 framebuffer readout, colour decode and scan-out.
//
// Pixel-clock (64.43 MHz) side of the readout pipeline. Uses the validated
// ocb-test mode-2 timing (H 1024/24/136/160 = 1344, V 768/3/6/29 = 806, both
// syncs negative, 59.5 Hz) and maps the 512x256 canonical BK framebuffer onto
// the full panel with the exact x2 horizontal / x3 vertical integer scale:
// slot = hpos/2, BK line = vpos/3 (tracked incrementally - no dividers).
//
// Line scheduling (the CDC protocol with fb_readout, sys domain):
//   * at the start of each line-triple (first output line of BK line L) it
//     requests BK line L+1 into line-buffer bank (L+1)&1 - a full triple
//     (62.6 us) ahead of its display, ~2x the paced fill time;
//   * at vpos == V_TOTAL-3 (in vblank) it requests line 0 - fb_readout also
//     latches the front buffer on that request, so every panel frame reads one
//     coherent BK frame.
// The request is a toggle + line payload written on the same pixel edge; the
// payload is stable until the next request (~21 us), race-free for the 2-FF
// toggle sync on the sys side.
//
// Output pipeline is 2 pixel clocks deep (registered line-buffer read, then
// registered RGB decode); hsync/vsync/active are delayed to match, so the image
// stays aligned to the syncs. RGB is forced black outside 'active' and until
// fb_front_valid (synced here) - hides power-on garbage before the first
// complete BK frame lands in the framebuffer.
//
// The FB nibble is the BK-0011M physical colour {R1,B,G,R0} (see
// palette_apply.sv), decoded combinationally into 6 bits/channel for the R-2R
// DAC; the red-level constants below double as the CRT colour-tweak hook.
module vga_out #(
    parameter int H_ACTIVE = 1024, parameter int H_FP = 24,
    parameter int H_SYNC   = 136,  parameter int H_BP = 160,
    parameter int V_ACTIVE = 768,  parameter int V_FP = 3,
    parameter int V_SYNC   = 6,    parameter int V_BP = 29
) (
    input  logic       clk,        // 64.43 MHz pixel clock
    input  logic       rst_n,      // pixel-domain reset (synced PLL locked)

    // ---- fb_linebuf read port ---------------------------------------------
    output logic [9:0] lb_raddr,   // {bank, slot[8:0]}
    input  logic [3:0] lb_rdata,   // registered in fb_linebuf (1 clk)

    // ---- line request to fb_readout (pixel -> sys toggle CDC) --------------
    output logic       req_tgl,
    output logic [7:0] req_line,

    // ---- from fb_video (sys domain, synced here) ----------------------------
    input  logic       fb_valid,   // fb_front_valid

    // ---- VGA pins (all registered on clk) -----------------------------------
    output logic       hsync,
    output logic       vsync,
    output logic [5:0] r,
    output logic [5:0] g,
    output logic [5:0] b
);

    localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    // ---- timing generator (vendored, hardware-validated in ocb-test) --------
    wire        hs_t, vs_t, act_t;
    wire [11:0] hpos, vpos;
    vga_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
        .HS_POS(1'b0), .VS_POS(1'b0)
    ) u_timing (
        .clk(clk), .rst_n(rst_n),
        .hsync(hs_t), .vsync(vs_t), .active(act_t), .hpos(hpos), .vpos(vpos)
    );

    // ---- fb_front_valid synchronizer ----------------------------------------
    logic [1:0] valid_sr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) valid_sr <= '0;
        else        valid_sr <= {valid_sr[0], fb_valid};
    wire fb_valid_s = valid_sr[1];

    // ---- BK line / triple trackers (mirror vga_timing's wrap points) --------
    logic [7:0] bk_row;    // BK line displayed at the current vpos (0..255)
    logic [1:0] tri_cnt;   // vpos within the triple (0..2)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bk_row  <= '0;
            tri_cnt <= '0;
        end else if (hpos == H_TOTAL - 1) begin
            if (vpos == V_TOTAL - 1) begin
                bk_row  <= '0;
                tri_cnt <= '0;
            end else if (tri_cnt == 2'd2) begin
                tri_cnt <= '0;
                bk_row  <= bk_row + 8'd1;
            end else
                tri_cnt <= tri_cnt + 2'd1;
        end
    end

    // ---- line-triple-ahead prefetch requests ---------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_tgl  <= 1'b0;
            req_line <= '0;
        end else if (hpos == 12'd0) begin
            if (vpos < V_ACTIVE && tri_cnt == 0 && bk_row != 8'd255) begin
                req_line <= bk_row + 8'd1;       // next BK line, other bank
                req_tgl  <= ~req_tgl;
            end else if (vpos == V_TOTAL - 3) begin
                req_line <= 8'd0;                // vblank: line 0 + front latch
                req_tgl  <= ~req_tgl;
            end
        end
    end

    // ---- line-buffer read: slot = hpos/2, bank = displayed line LSB ----------
    assign lb_raddr = {bk_row[0], hpos[9:1]};

    // ---- 2-deep pipeline: t1 = lb_rdata valid, t2 = RGB out ------------------
    logic hs_d1, vs_d1, act_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_d1 <= 1'b1; vs_d1 <= 1'b1; act_d1 <= 1'b0;
            hsync <= 1'b1; vsync <= 1'b1;
            r <= '0; g <= '0; b <= '0;
        end else begin
            hs_d1 <= hs_t;  vs_d1 <= vs_t;  act_d1 <= act_t;
            hsync <= hs_d1; vsync <= vs_d1;
            if (act_d1 && fb_valid_s) begin
                // The FB nibble IS the BK-0011M physical colour
                // {R1, B, G, R0} (see palette_apply.sv) - decode it, no CLUT.
                // The two red bits are unequal resistor weights: R1 alone
                // ~0xC0/0xFF, R0 alone ~0x8E/0xFF, both = saturated (the
                // BkEmu colour-table levels; more faithful than MiSTer's
                // equal-weight doubling). bk10 colours land on the same RGB
                // as the old fixed CLUT (blue=4, green=2, red=9, white=15).
                case ({lb_rdata[3], lb_rdata[0]})
                    2'b11:   r <= 6'h3F;
                    2'b10:   r <= 6'h30;
                    2'b01:   r <= 6'h23;
                    default: r <= 6'h00;
                endcase
                g <= lb_rdata[1] ? 6'h3F : 6'h00;
                b <= lb_rdata[2] ? 6'h3F : 6'h00;
            end else begin
                r <= '0; g <= '0; b <= '0;
            end
        end
    end

endmodule
