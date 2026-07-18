// ============================================================================
//  ide_disk_model - behavioral backing store for the smk_ide backend sector
//  port (increment (a); the increment-(b) SD/SPI engine replaces it on
//  hardware). Word-array disk, loaded by the tb via a hierarchical
//  $readmemh into `disk`. Serves the request/ack/done contract with a
//  parameterised latency; out-of-range sectors complete with bk_error and
//  NO data movement (BkEmu ignores drive.read/write return codes - the
//  engine's buffer keeps stale data, the store is untouched).
//  media/total are tb-driven inputs so the attach/fallback legs can vary
//  them without recompiling.
// ============================================================================
`timescale 1ns/1ps
module ide_disk_model #(
    parameter MAX_SECTORS = 1024,   // array capacity (words = *256)
    parameter LATENCY     = 24      // sclk cycles of seek/latency per request
)(
    input             sclk,
    input             rst,
    // tb controls
    input             media_in,
    input      [27:0] total_in,
    // smk_ide backend port
    input             bk_req,
    input             bk_wr,
    input      [27:0] bk_sector,
    input             bk_bank,      // engine-owned; unused here
    output reg        bk_ack,
    output reg        bk_done,
    output reg        bk_error,
    output            bk_media_ok,
    output     [27:0] bk_total,
    output reg [7:0]  bk_baddr,
    output reg [15:0] bk_wdata,
    output reg        bk_we,
    input      [15:0] bk_rdata
);
    reg [15:0] disk [0:MAX_SECTORS*256-1];

    assign bk_media_ok = media_in;
    assign bk_total    = total_in;

    localparam M_IDLE = 0, M_WAIT = 1, M_RD = 2, M_WR = 3, M_WR2 = 4,
               M_WR3 = 5, M_DONE = 6;
    integer   mst = M_IDLE;
    integer   lat, widx;
    reg        r_wr;
    reg [27:0] r_sector;
    reg        oob;

    always @(posedge sclk) begin
        bk_ack  <= 1'b0;
        bk_done <= 1'b0;
        bk_we   <= 1'b0;
        if (rst) begin
            mst <= M_IDLE; bk_error <= 1'b0;
        end else begin
            case (mst)
                M_IDLE: if (bk_req) begin
                    bk_ack   <= 1'b1;
                    r_wr     <= bk_wr;
                    r_sector <= bk_sector;
                    oob      <= (bk_sector >= total_in)
                                || (bk_sector >= MAX_SECTORS);
                    lat      <= LATENCY;
                    mst      <= M_WAIT;
                end
                M_WAIT: begin
                    if (lat == 0) begin
                        widx <= 0;
                        if (oob) begin
                            bk_error <= 1'b1;
                            bk_done  <= 1'b1;   // complete, no data moved
                            mst <= M_IDLE;
                        end else begin
                            bk_error <= 1'b0;
                            mst <= r_wr ? M_WR : M_RD;
                        end
                    end else
                        lat <= lat - 1;
                end
                M_RD: begin                     // stream 256 words into the bank
                    bk_baddr <= widx[7:0];
                    bk_wdata <= disk[r_sector * 256 + widx];
                    bk_we    <= 1'b1;
                    if (widx == 255) mst <= M_DONE;
                    widx <= widx + 1;
                end
                M_WR: begin                     // present address, then sample
                    bk_baddr <= widx[7:0];      // the registered bk_rdata
                    mst <= M_WR2;
                end
                M_WR2: mst <= M_WR3;            // one settle cycle
                M_WR3: begin
                    disk[r_sector * 256 + widx] <= bk_rdata;
                    if (widx == 255) mst <= M_DONE;
                    else begin widx <= widx + 1; mst <= M_WR; end
                end
                M_DONE: begin
                    bk_done <= 1'b1;
                    mst <= M_IDLE;
                end
            endcase
        end
    end
endmodule
