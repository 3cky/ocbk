// vga_timing - parameterized VGA timing generator.
//
// Drives horizontal/vertical sync, a data-enable ("active") strobe, and the
// raw pixel coordinates from a free-running counter pair clocked by the pixel
// clock. All timing is expressed as the four standard VESA segments per axis
// (active, front porch, sync, back porch); sync polarity is selectable so the
// same module serves modes that need positive or negative sync.
//
// hpos/vpos are the full counter values (0..H_TOTAL-1 / 0..V_TOTAL-1); during
// the active region they double as the on-screen pixel coordinate.
module vga_timing #(
    parameter int H_ACTIVE = 640,
    parameter int H_FP     = 16,
    parameter int H_SYNC   = 96,
    parameter int H_BP     = 48,
    parameter int V_ACTIVE = 480,
    parameter int V_FP     = 10,
    parameter int V_SYNC   = 2,
    parameter int V_BP     = 33,
    parameter bit HS_POS   = 1'b0,  // 1 = active-high hsync, 0 = active-low
    parameter bit VS_POS   = 1'b0   // 1 = active-high vsync, 0 = active-low
) (
    input  logic        clk,    // pixel clock
    input  logic        rst_n,  // async reset, active low (PLL locked)
    output logic        hsync,
    output logic        vsync,
    output logic        active, // data enable: high inside the visible area
    output logic [11:0] hpos,
    output logic [11:0] vpos
);

    localparam int H_TOTAL      = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam int V_TOTAL      = V_ACTIVE + V_FP + V_SYNC + V_BP;
    localparam int H_SYNC_START = H_ACTIVE + H_FP;
    localparam int H_SYNC_END   = H_ACTIVE + H_FP + H_SYNC;
    localparam int V_SYNC_START = V_ACTIVE + V_FP;
    localparam int V_SYNC_END   = V_ACTIVE + V_FP + V_SYNC;

    logic [11:0] hcnt = '0;
    logic [11:0] vcnt = '0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= '0;
            vcnt <= '0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= '0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 12'd0 : vcnt + 1'b1;
        end else begin
            hcnt <= hcnt + 1'b1;
        end
    end

    // Sync windows (raw = asserted during the sync segment), then apply polarity.
    logic hs_raw, vs_raw;
    assign hs_raw = (hcnt >= H_SYNC_START) && (hcnt < H_SYNC_END);
    assign vs_raw = (vcnt >= V_SYNC_START) && (vcnt < V_SYNC_END);

    assign hsync  = HS_POS ?  hs_raw : ~hs_raw;
    assign vsync  = VS_POS ?  vs_raw : ~vs_raw;
    assign active = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    assign hpos   = hcnt;
    assign vpos   = vcnt;

endmodule
