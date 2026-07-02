// fb_linebuf - dual-clock ping-pong BK line buffer (Phase 4 readout CDC).
//
// Two 512-nibble banks (bank = BK line LSB): the sys_clk side fills the bank of
// the NEXT BK line while the pixel side displays the other - the triple-ahead
// scheduling in vga_out/fb_readout guarantees a bank is never written while it
// is being displayed, so the RAM itself is the only sys->pixel crossing (cut in
// the SDC; safe by the ping-pong protocol).
//
// Deliberately the plainest possible dual-clock dual-port RAM - one write-always
// block, one registered-read-always block, same width both ports - so Quartus II
// 11.0 infers a single M4K (4096 bits) and Icarus simulates it as-is. Do not add
// mixed widths, byte enables or a read-during-write bypass here.
module fb_linebuf (
    input  logic       wclk,     // sys_clk
    input  logic       we,
    input  logic [9:0] waddr,    // {bank, slot[8:0]}
    input  logic [3:0] wdata,    // 4-bit colour index

    input  logic       rclk,     // pixel clock
    input  logic [9:0] raddr,    // {bank, slot[8:0]}
    output logic [3:0] rdata     // registered (1 rclk latency)
);

    logic [3:0] mem [0:1023];

    always_ff @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    always_ff @(posedge rclk)
        rdata <= mem[raddr];

endmodule
