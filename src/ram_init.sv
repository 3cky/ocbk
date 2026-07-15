// ram_init - authentic DRAM power-on pattern filler (Phase 7 UX).
//
// Fills the selected model's BK RAM region in the board SDRAM with the
// К565РУ6 (BK-0010) / К565РУ5 (BK-0011M) power-on garbage pattern that BkEmu
// reproduces (RandomAccessMemory.initData): each 16-bit word is all-ones or
// all-zeros,
//     word = (idx[0] == idx[N]) ? 0177777 : 0,   N = 6 (РУ6) or 7 (РУ5).
// Every RAM page/bank base is 0x2000-word aligned (low 13 bits zero) and N < 13,
// so BkEmu's per-instance word index reduces to the physical word address:
//     w_wdata = (w_addr[0] == w_addr[N]) ? 16'hFFFF : 16'h0000.
// The result is the real BK startup screen - a structured garbage pattern that
// MONITOR/BOS then clears - instead of undefined FPGA SDRAM noise.
//
// Runs while the CPU is held in DCLO and the EPCS loader is done (enable), so
// arbiter port 0 is otherwise idle; the top level muxes this and epcs_boot onto
// the shared port-0 boot-writer port (bw_*), so qbus_mem is unchanged. Follows
// the same served-mask contract as every port-0 writer: assert w_req with the
// payload stable until w_gnt, then drop w_req for one cycle (the req/gap toggle
// below) before the next word - sdram_arbiter holds a granted port ineligible
// until it sees w_req low again.
//
// Trigger: fill at power-on (ram_valid=0) and re-fill on a warm reset ONLY when
// the model changed (model_bk11 != model_seen). model_bk11 only ever changes
// while DCLO is held (ocbk_top's latch), so a re-fill always lands inside a
// reset hold with the CPU parked. A same-model warm reset leaves RAM untouched
// (BK reset semantics). fill_busy holds the CPU past the warm-reset tail until
// the fill finishes; blank_pulse (a re-fill only, i.e. ram_valid already 1)
// clears fb_video's fb_front_valid so the display blacks out then reveals the
// fresh pattern - the first power-on fill needs no pulse (the existing
// power-on black-out already hides it).
module ram_init #(
    parameter int ADDR_BITS = 24
) (
    input  logic                 clk,        // sys_clk
    input  logic                 rst_n,      // srst_n (power-on only)
    input  logic                 model_bk11, // DIP-1 model select (DCLO-stable)
    input  logic                 enable,     // boot done & port 0 free (CPU held)

    // ---- SDRAM write port (top-level 2:1 mux with epcs_boot onto port 0) ----
    output logic                 w_req,
    output logic [ADDR_BITS-1:0] w_addr,
    output logic [15:0]          w_wdata,
    input  logic                 w_gnt,

    // ---- status ------------------------------------------------------------
    output logic                 fill_active, // owns the port-0 mux while high
    output logic                 fill_busy,   // hold the CPU until this drops
    output logic                 blank_pulse  // 1-cyc: re-fill -> clear fb valid
);

    // Per-model fill range (word addresses); bases are 0x2000-word aligned.
    //   bk10: 0x00000..0x03FFF (16384 words, incl. fixed video page 0x2000)
    //   bk11: 0x20000..0x2FFFF (65536 words, incl. video pages 0x22000/0x2E000)
    localparam logic [23:0] BASE10 = 24'h000000, LAST10 = 24'h003FFF;
    localparam logic [23:0] BASE11 = 24'h020000, LAST11 = 24'h02FFFF;

    wire [ADDR_BITS-1:0] base = model_bk11 ? BASE11 : BASE10;
    wire [ADDR_BITS-1:0] last = model_bk11 ? LAST11 : LAST10;

    logic ram_valid;    // 0 at power-on -> the first fill; then stays 1
    logic model_seen;   // the model whose pattern currently occupies RAM
    logic filling;      // a fill pass is in progress
    logic issuing;      // 1 = w_req asserted this word, 0 = the one-cycle gap

    wire need_fill = !ram_valid || (model_bk11 != model_seen);
    assign fill_busy   = need_fill || filling;
    assign fill_active = filling;

    // Pattern word: combinational from the (stable-while-req) write address.
    wire pat_n = model_bk11 ? w_addr[7] : w_addr[6];
    assign w_wdata = (w_addr[0] == pat_n) ? 16'hFFFF : 16'h0000;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_valid   <= 1'b0;
            model_seen  <= 1'b0;
            filling     <= 1'b0;
            issuing     <= 1'b0;
            w_req       <= 1'b0;
            w_addr      <= '0;
            blank_pulse <= 1'b0;
        end else begin
            blank_pulse <= 1'b0;            // default: single-cycle pulse
            if (w_gnt) w_req <= 1'b0;       // served-mask contract

            if (!filling) begin
                if (enable && need_fill) begin
                    filling     <= 1'b1;
                    issuing     <= 1'b1;
                    w_addr      <= base;
                    w_req       <= 1'b1;
                    blank_pulse <= ram_valid;   // re-fill (model change) -> blank
                end
            end else if (issuing) begin
                if (w_gnt) begin
                    issuing <= 1'b0;            // enter the one-cycle gap
                    if (w_addr == last) begin   // last word granted -> done
                        filling    <= 1'b0;
                        model_seen <= model_bk11;
                        ram_valid  <= 1'b1;
                    end
                end
            end else begin                     // gap cycle: advance and re-issue
                w_addr  <= w_addr + 1'b1;
                w_req   <= 1'b1;
                issuing <= 1'b1;
            end
        end
    end

endmodule
