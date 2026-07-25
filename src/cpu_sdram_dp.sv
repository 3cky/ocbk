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
//
// Phase 9 - the EARLY (SYNC-time) read issue, `fast_rd`. Normally a read is
// issued when DIN asserts, and by the time the reply point comes round the
// SDRAM word is long since there. That stops being true for a reply shorter
// than the SDRAM latency: the SMK512 RAM is calibrated at N_EXT = 1, i.e.
// qbus_mem replies at the very first cpu_clk_n edge after DIN (~12 sys_clk),
// while an SDRAM read needs ~8 of its own plus another 4..14 waiting for the
// arbiter grant - measured 12..22 end to end. The done-gate would then extend
// the RPLY on some cycles and not others: the fixed count would silently
// become "whenever the SDRAM got there", which is both non-deterministic and a
// cycle-accuracy hole. So for that one leg the read starts at SYNC instead,
// buying the whole SYNC->DIN gap on top - 22 sys_clk of head start, measured.
// This is not speculation: WTBT at SYNC time flags a DATO(B), so WTBT
// deasserted means a read (or the read half of a DATIO) is certain to follow.
// `fast_rd` is driven ONLY for the MK_EXT mem-region read leg, so the
// MK_RAM037 / MK_ROM paths are untouched and no existing timing golden can
// move. sim/smktime counts the reads that still miss by an edge (EXTRD
// fast/slow, in its golden) and fails on dbg_romgate, i.e. on any read that
// misses by more than one.
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
    input  logic                 fast_rd,   // Phase-9: this SYNC-framed access is
                                            // a short-reply (N=1) read leg - issue
                                            // the SDRAM read at SYNC, not at DIN,
                                            // so mem_ready is up before the reply
                                            // point (see the header note)
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
    logic        oe_arm;     // "in D_DONE off a read this FSM drives" - one
                             // flop standing in for (state==D_DONE && was_read
                             // && was_drive) so the pad-OE cone is a single
                             // register (see rdata_oe)

    wire is_read  = (sel_ram || sel_romr) && !din_n;
    wire is_write = (sel_ram || sel_ramw) && !dout_n; // ROM writes never reach
                                                      // the SDRAM; sel_ramw is
                                                      // the write-only leg
    // Byte op is WTBT sampled at DOUT time (dual-purpose WTBT).
    wire byte_op  = !wtbt_n;

    // ---- the early (SYNC-time) read issue - see the header note ------------
    // qbus_mem's address latch is clocked by `negedge sync_n`, a slow logic
    // clock asynchronous to sys_clk, so `phys` needs a moment to settle before
    // it can be sampled: sync sync_n in and require it low for 2 cycles.
    //
    // TWO cycles, not one, and that is a deliberate timing-safety call. The
    // SYNC latch is `qbus_sync` in ocbk_constrains.sdc, false-pathed in BOTH
    // directions, so the arc addr -> mem_mapper translate -> this addr_o
    // register is NOT checked by STA at all. Today it has ~124 ns of real
    // slack (nothing samples it before DIN); sampling at sync_sr[1] cuts that
    // to ~20.7 ns, at sync_sr[0] to ~10.35 ns. Measured (sim/smktime), the
    // one-cycle-earlier version is worth 601.7 Hz vs 598.9 against a real
    // board's 601 Hz - i.e. ~0.5 %, against halving the margin on a path no
    // tool is checking. Not worth it: the SEED-3 lesson in CLAUDE.md is
    // exactly about unverified placement luck at this end of the design.
    // There are ~22 sys_clk between the issue and an N=1 reply point.
    // pre_done keeps it to ONE early issue per SYNC, which is what keeps a
    // DATIO correct: the read half is served from this issue, then the write
    // half re-enters D_IDLE through the ordinary is_write path without
    // re-triggering a read.
    //
    // early_pend is the other half of it, and the non-obvious half: D_DONE
    // normally exits on strobes-idle, and during the address phase the strobes
    // ARE idle - so an early-issued read would land in D_DONE, drop straight
    // back to D_IDLE, and take mem_ready down with it before DIN ever arrived
    // (the whole point being to have mem_ready UP when DIN arrives). While
    // early_pend is set, D_DONE therefore holds through the address phase and
    // only releases once DIN has come and gone. It is cleared the moment DIN
    // asserts, so from there on the cycle behaves exactly like a DIN-issued
    // read - including the DATIO write half.
    //
    // WTBT must be LATCHED, not sampled live: it is dual-purpose, and the
    // address-phase meaning ("this cycle is a DATO(B)") is only on the wire for
    // the ~120 ns of the address phase - the vm1 asserts it BEFORE SYNC and
    // releases it about 12 sys_clk after. Sampling it live meant every write
    // cycle looked like a read the moment WTBT went away, fired an early read,
    // and left the FSM parked so the write was silently dropped. wtbt_hold
    // captures it one sys_clk into the SYNC, while it is still valid.
    logic [1:0] sync_sr;
    logic       pre_done;
    logic       early_pend;
    logic       wtbt_hold;                         // 1 = not a DATO(B) = a read
    wire        sync_lo   = sync_sr[1];
    wire        early_rd  = fast_rd && sync_lo && !pre_done
                            && din_n && dout_n && wtbt_hold;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_sr    <= 2'b00;
            pre_done   <= 1'b0;
            early_pend <= 1'b0;
            wtbt_hold  <= 1'b0;
        end else begin
            sync_sr <= {sync_sr[0], ~sync_n};
            if (sync_sr == 2'b01)                  // one clock into the SYNC,
                wtbt_hold <= wtbt_n;               //   while WTBT still means it
            if (sync_n)                            // re-arm at the end of the cycle
                pre_done <= 1'b0;
            else if (early_rd && state == D_IDLE)  // ...only once it really issued
                pre_done <= 1'b1;

            // cycle over, or a strobe took it (DIN = as intended; DOUT = the
            // safety case below)
            if (sync_n || !din_n || !dout_n)
                early_pend <= 1'b0;
            else if (early_rd && state == D_IDLE)
                early_pend <= 1'b1;
        end
    end

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
            oe_arm   <= 1'b0;
        end else begin
            case (state)
                D_IDLE: begin
                    req <= 1'b0;
                    if (is_read || early_rd) begin     // prefetch the read
                        we       <= 1'b0;
                        addr_o   <= phys;
                        be_o     <= 2'b11;
                        req      <= 1'b1;
                        was_read <= 1'b1;
                        was_drive <= !rd_noe;
                        oe_arm   <= 1'b0;
                        state    <= D_RD_REQ;
                    end else if (is_write) begin        // capture + issue the write
                        we       <= 1'b1;
                        addr_o   <= phys;
                        wdata_o  <= ad_true;
                        be_o     <= byte_op ? (addr[0] ? 2'b10 : 2'b01) : 2'b11;
                        req      <= 1'b1;
                        was_read <= 1'b0;
                        was_drive <= 1'b0;
                        oe_arm   <= 1'b0;
                        state    <= D_WR_REQ;
                    end
                end
                D_RD_REQ:  if (gnt)    begin req <= 1'b0; state <= D_RD_WAIT; end
                D_RD_WAIT: if (rvalid) begin rd_hold <= rdata_i; state <= D_DONE;
                                             oe_arm <= was_drive; end
                D_WR_REQ:  if (gnt)    begin req <= 1'b0; state <= D_DONE; end
                D_DONE: begin
                    // Hold done + read data until the CPU releases the strobes.
                    // Exit on strobes-idle, NOT on SYNC: a DATIO/DATIOB read-
                    // modify-write cycle (INC/BIS/XOR/... on memory) runs DIN
                    // then DOUT under ONE continuous SYNC - waiting for SYNC
                    // here would sit through the DOUT phase and silently drop
                    // the write. With the strobes-idle exit the write phase
                    // re-enters D_IDLE and issues as a normal posted write.
                    // early_pend suspends that exit for an early-issued read
                    // whose DIN has not arrived yet - see its declaration.
                    // SAFETY: if DOUT arrives instead (an early read on what
                    // turned out to be a write - impossible with wtbt_hold
                    // right, catastrophic if it ever is not, because the write
                    // would be dropped) release at once so D_IDLE issues it.
                    if (early_pend && !dout_n) begin
                        state <= D_IDLE; oe_arm <= 1'b0;
                    end else if (din_n && dout_n && !early_pend) begin
                        state <= D_IDLE; oe_arm <= 1'b0;
                    end
                end
                default: begin state <= D_IDLE; oe_arm <= 1'b0; end
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
    //
    // Phase 9 takes that one step further: even the state decode is gone. The
    // whole (state==D_DONE && was_read && was_drive) term is precomputed into
    // `oe_arm` at the transitions into and out of D_DONE - identical by
    // construction (D_DONE is entered from D_RD_WAIT with was_read=1, from
    // D_WR_REQ with was_read=0, and left only to D_IDLE) - because that loop
    // came back as the design's worst sys_clk path (-0.023 ns) once the N_EXT
    // work re-placed the fitter. Same rule, one level shorter: register the
    // decision at issue, never re-derive it at the drive point.
    assign rdata_oe  = oe_arm && !din_n;

endmodule
