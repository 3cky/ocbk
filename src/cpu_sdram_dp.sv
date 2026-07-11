// cpu_sdram_dp - CPU Q-bus <-> SDRAM datapath for the Strategy-A memory subsystem
// (Phase 3 SoC integration).
//
// Under Strategy A the 037 (va_037_sync) owns RAM RPLY and its timing (the grant /
// cycle-stealing); this block is purely the DATA path plus the done-gate signal. On
// a CPU RAM access it issues one word through the sdram_arbiter (port 0), drives the
// read word back onto the bus, and raises mem_ready once the SDRAM access has
// completed. va_037_sync ANDs mem_ready into its RPLY, so a late SDRAM word EXTENDS
// RPLY instead of the CPU latching stale data (the interlock). In the common case
// the read is prefetched at recognition and finishes long before the 037 grants, so
// mem_ready is already high at the grant and RPLY lands on the cycle-accurate edge.
//
// One access is outstanding at a time (the CPU bus is single-threaded), so there is
// no write buffer and no read-after-write hazard. Everything is in the sys_clk
// domain; the bus strobes are synchronous to it (cpu_clk = sys_clk/32), so they are
// sampled directly, exactly as va_037_sync samples them.
//
// DATIO(B) read-modify-write cycles (INC/BIS/XOR/... on memory) are two sequential
// accesses under one SYNC: the read completes (D_DONE), the strobes go idle, then
// DOUT arrives and the write is issued through the normal D_IDLE path (address
// latch and sel_ram are SYNC-framed, so they still hold). mem_ready drops during
// the write phase, done-gating the 037's second RPLY exactly like a plain write.
//
// Phase 5: SDRAM-backed ROM reads (sel_romr) ride the same read path - the linear
// addr[15:1] map puts ROM 100000-177577 at SDRAM words 0x4000-0x7F7F, below the
// framebuffers. ROM is read-only here: a ROM write (or the DOUT phase of a ROM
// DATIO) is never issued to the SDRAM - the qbus_mem front-end replies and
// ignores it, so nothing in this FSM changes for it.
//
// Phase 7: the physical word address now comes from mem_mapper as `phys` (in
// BK-0010 mode it IS addr[15:1], so nothing moves); `addr` stays connected for
// the addr[0] byte-lane select. MK_EXT (sel_ext, the BK-0011M window-1 banked
// RAM) is readable AND writable here, with qbus_mem's wait FSM owning RPLY:
//   * the DATIO RMW note above applies verbatim - the strobes-idle D_DONE exit
//     is what lets an EXT INC/BIS/... issue its write phase;
//   * an EXT write is a posted write (D_WR_REQ -> D_DONE on gnt) with
//     mem_ready as the FSM's write done-gate - the same interlock va_037_sync
//     uses for RAM writes; gnt means the arbiter consumed the command, and
//     port 0 is in-order single-outstanding, so a posted-write-then-RPLY can
//     never be overtaken or reordered.
module cpu_sdram_dp #(
    parameter int ADDR_BITS = 24,
    parameter int DQ_BITS   = 16
) (
    input  logic                 clk,       // sys_clk
    input  logic                 rst_n,

    // ---- Q-bus taps (true-polarity address already decoded upstream) --------
    input  logic                 sync_n,
    input  logic                 din_n,
    input  logic                 dout_n,
    input  logic                 wtbt_n,
    input  logic                 sel_ram,   // this access targets RAM (SYNC-framed)
    input  logic                 sel_romr,  // targets SDRAM-backed ROM (read-only)
    input  logic                 sel_ext,   // targets 0011M banked RAM (read+write,
                                            // FSM-owned RPLY - see header)
    input  logic [15:0]          addr,      // latched bus address (true; byte lanes)
    input  logic [ADDR_BITS-1:0] phys,      // mapped physical SDRAM word address
    input  logic [15:0]          ad_true,   // current bus data (true = ~ad_n), for writes

    // ---- read-data drive + done-gate ----------------------------------------
    output logic [15:0]          rdata,     // RAM read word (true)
    output logic                 rdata_oe,  // drive rdata onto the bus
    output logic                 mem_ready, // 1 = SDRAM access for this cycle complete

    // ---- sdram_arbiter port ---------------------------------------------------
    output logic                 req,
    output logic                 we,
    output logic [ADDR_BITS-1:0] addr_o,
    output logic [DQ_BITS-1:0]   wdata_o,
    output logic [1:0]           be_o,
    input  logic                 gnt,
    input  logic                 rvalid,
    input  logic [DQ_BITS-1:0]   rdata_i
);

    typedef enum logic [2:0] {
        D_IDLE, D_RD_REQ, D_RD_WAIT, D_WR_REQ, D_DONE
    } dstate_t;
    dstate_t state;

    logic [15:0] rd_hold;

    wire is_read  = (sel_ram || sel_romr || sel_ext) && !din_n;
    wire is_write = (sel_ram || sel_ext) && !dout_n; // ROM writes never reach the SDRAM
    // Byte op is WTBT sampled at DOUT time (dual-purpose WTBT).
    wire byte_op  = !wtbt_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= D_IDLE;
            req      <= 1'b0;
            we       <= 1'b0;
            addr_o   <= '0;
            wdata_o  <= '0;
            be_o     <= 2'b11;
            rd_hold  <= '0;
        end else begin
            case (state)
                D_IDLE: begin
                    req <= 1'b0;
                    if (is_read) begin                 // prefetch the read
                        we     <= 1'b0;
                        addr_o <= phys;
                        be_o   <= 2'b11;
                        req    <= 1'b1;
                        state  <= D_RD_REQ;
                    end else if (is_write) begin        // capture + issue the write
                        we      <= 1'b1;
                        addr_o  <= phys;
                        wdata_o <= ad_true;
                        be_o    <= byte_op ? (addr[0] ? 2'b10 : 2'b01) : 2'b11;
                        req     <= 1'b1;
                        state   <= D_WR_REQ;
                    end
                end
                D_RD_REQ:  if (gnt)    begin req <= 1'b0; state <= D_RD_WAIT; end
                D_RD_WAIT: if (rvalid) begin rd_hold <= rdata_i; state <= D_DONE; end
                D_WR_REQ:  if (gnt)    begin req <= 1'b0; state <= D_DONE; end
                D_DONE: begin
                    // Hold done + read data until the CPU releases the strobes.
                    // Exit on strobes-idle, NOT on SYNC: a DATIO/DATIOB read-
                    // modify-write cycle (INC/BIS/XOR/... on memory) runs DIN
                    // then DOUT under ONE continuous SYNC - waiting for SYNC
                    // here would sit through the DOUT phase and silently drop
                    // the write. With the strobes-idle exit the write phase
                    // re-enters D_IDLE and issues as a normal posted write.
                    if (din_n && dout_n) state <= D_IDLE;
                end
                default: state <= D_IDLE;
            endcase
        end
    end

    assign mem_ready = (state == D_DONE);
    assign rdata     = rd_hold;
    assign rdata_oe  = (state == D_DONE) && !din_n && (sel_ram || sel_romr || sel_ext);

endmodule
