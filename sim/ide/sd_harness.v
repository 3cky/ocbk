// ============================================================================
//  sd_harness - drop-in replacement for ide_disk_model wrapping the REAL
//  increment-(b) SD stack (src/peripheral/sd_backend.sv + sd_model.v) behind the
//  identical port list, so the existing smk_ide_tb legs re-run unchanged
//  over the full SPI path (run.sh's -DSD_STACK second pass; also the
//  boot_check +sdspi leg). SPI nets live inside; the dividers and
//  budgets are shrunk to sim speed (/2 both phases - the divider RATIO
//  is not what this oracle pins; run_sd.sh keeps the real dividers).
//
//  media_in: the real slot has NO card-detect pin, so "no media" is
//  modeled by holding the backend (and the card's protocol state) in
//  reset - faithful to the hardware reality that a card change needs
//  the reset button, and the tb only ever flips media around a reset
//  pulse. total_in: the card capacity tracks it via a hierarchical
//  poke; the run.sh SD pass uses the +sdsc personality, whose CSDv1
//  encodes every total the tb uses (640, 2016) EXACTLY - the CSD parse
//  itself is run_sd.sh's job, this pass pins the engine+backend
//  behaviour.
// ============================================================================
`timescale 1ns/1ps
module sd_harness #(
    parameter MAX_SECTORS = 1024,
    parameter LATENCY     = 24      // interface symmetry; unused
)(
    input             sclk,
    input             rst,
    // tb controls (ide_disk_model-compatible)
    input             media_in,
    input      [27:0] total_in,
    // smk_ide backend port
    input             bk_req,
    input             bk_wr,
    input      [27:0] bk_sector,
    input             bk_bank,
    output            bk_ack,
    output            bk_done,
    output            bk_error,
    output            bk_media_ok,
    output     [27:0] bk_total,
    output     [7:0]  bk_baddr,
    output     [15:0] bk_wdata,
    output            bk_we,
    input      [15:0] bk_rdata
);
    wire sd_ck, sd_cs, sd_mosi, sd_miso;

    wire no_media = rst || !media_in;

    sd_backend #(
        .DIV_SLOW_L2 (1),           // sim-speed: /2 both phases
        .DIV_FAST_L2 (1),
        .SETTLE_CLKS (32),
        .INIT_TRIES  (4),
        .ACMD41_TRIES(64),
        .TOK_POLLS   (64),
        .BUSY_POLLS  (64)
    ) u_be (
        .clk        (sclk),
        .rst_n      (!no_media),
        .enable     (1'b1),
        .sd_ck      (sd_ck),
        .sd_cs      (sd_cs),
        .sd_mosi    (sd_mosi),
        .sd_miso    (sd_miso),
        .bk_req     (bk_req),
        .bk_wr      (bk_wr),
        .bk_sector  (bk_sector),
        .bk_bank    (bk_bank),
        .bk_ack     (bk_ack),
        .bk_done    (bk_done),
        .bk_error   (bk_error),
        .bk_media_ok(bk_media_ok),
        .bk_total   (bk_total),
        .bk_baddr   (bk_baddr),
        .bk_wdata   (bk_wdata),
        .bk_we      (bk_we),
        .bk_rdata   (bk_rdata)
    );

    sd_model #(.MAX_SECTORS(MAX_SECTORS)) u_card (
        .rst  (no_media),
        .ck   (sd_ck),
        .cs   (sd_cs),
        .mosi (sd_mosi),
        .miso (sd_miso)
    );

    // capacity tracks the tb's total_in (sd_model's own initial runs at
    // time 0; the #2 re-poke wins before the first reset release)
    initial #2 u_card.capacity = total_in;
    always @(total_in) u_card.capacity = total_in;

endmodule
