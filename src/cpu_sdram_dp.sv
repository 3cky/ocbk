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
// the addr[0] byte-lane select. BK-0011M window-1 banked RAM is a normal
// MK_RAM037 access (sel_ram) - it reads AND writes through this same datapath
// with `phys` pointing at the win1 RAM page, and the 037 owns its RPLY (a15_037
// forced low), done-gated on mem_ready exactly like the low 32K. The DATIO RMW
// note above applies verbatim (the strobes-idle D_DONE exit lets a window-1
// INC/BIS/... issue its write phase); a window-1 write is a posted write
// (D_WR_REQ -> D_DONE on gnt) with mem_ready as the write done-gate.
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
    input  logic                 sel_ram,   // this access targets RAM (SYNC-framed;
                                            // incl. 0011M window-1 banked RAM)
    input  logic                 sel_romr,  // targets SDRAM-backed ROM (read-only)
    input  logic                 sel_ramw,  // write-ONLY RAM leg (Phase-8 SMK
                                            // HLT-mode seg-7 extent): issues the
                                            // write like sel_ram but has NO read
                                            // path - a read is structurally never
                                            // fetched/driven (the smk_wo mirror
                                            // of sel_romr's never-issued write)
    input  logic                 rd_noe,    // fetch but do NOT drive this read
                                            // (Phase-8 I/O-page overlay: the
                                            // qbus_mem FSM drives the OR-merged
                                            // word instead); sampled into the
                                            // issue-time was_drive flop - never
                                            // gates the pad OE combinationally
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
    logic        was_read;   // the in-flight access is a read (set at issue)
    logic        was_drive;  // ...and this FSM drives its data (issue-time
                             // ~rd_noe; the pad-OE rule - see rdata_oe)

    wire is_read  = (sel_ram || sel_romr) && !din_n;
    wire is_write = (sel_ram || sel_ramw) && !dout_n; // ROM writes never reach
                                                      // the SDRAM; sel_ramw is
                                                      // the write-only leg
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
            was_read <= 1'b0;
            was_drive <= 1'b0;
        end else begin
            case (state)
                D_IDLE: begin
                    req <= 1'b0;
                    if (is_read) begin                 // prefetch the read
                        we       <= 1'b0;
                        addr_o   <= phys;
                        be_o     <= 2'b11;
                        req      <= 1'b1;
                        was_read <= 1'b1;
                        was_drive <= !rd_noe;
                        state    <= D_RD_REQ;
                    end else if (is_write) begin        // capture + issue the write
                        we       <= 1'b1;
                        addr_o   <= phys;
                        wdata_o  <= ad_true;
                        be_o     <= byte_op ? (addr[0] ? 2'b10 : 2'b01) : 2'b11;
                        req      <= 1'b1;
                        was_read <= 1'b0;
                        was_drive <= 1'b0;
                        state    <= D_WR_REQ;
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
    // Drive gate uses the ISSUE-TIME selection flag (was_read), not the live
    // sel_ram/sel_romr: behaviourally identical (the selects are SYNC-framed
    // and D_DONE is only ever reached inside the selecting SYNC window; a
    // write-half D_DONE has din_n released anyway), but it keeps the mapper's
    // combinational translate OUT of the bus-pad output-enable cone - the
    // live gate looped mapper regs -> kind -> OE -> ad pads -> the register
    // write snoops' data pins, a functionally false path (DIN and DOUT are
    // mutually exclusive) that cost the Phase-8 netlist its sys_clk timing
    // closure. Cycle-identical: every ref037 golden pins it. was_drive is the
    // same idea for the I/O-page overlay reads (rd_noe sampled at issue): the
    // word is fetched for the qbus_mem FSM's OR-merge, never driven from here.
    assign rdata_oe  = (state == D_DONE) && !din_n && was_read && was_drive;

endmodule
