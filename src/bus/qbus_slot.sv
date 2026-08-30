// qbus_slot - the МПИ expansion-bus bridge (slave-only).
//
// Connects the internal Q-bus to the physical cartridge-slot pins so a real BK
// expansion module - an SMK512 - can attach through the passive adapter. The
// connector is traced pin-by-pin in doc/dev/mpi.md; read that before changing
// anything here.
//
// SCOPE: slave-only. Data transfer, RPLY and the host-ROM deselect. The FPGA is
// always the bus master. No interrupts, no DMA/arbitration, no IAK chain - the
// МПИ pins for those are wired in copper on the adapter but nothing here drives
// or reads them yet.
//
// ELECTRICAL: the МПИ is 5 V TTL and the adapter does NOT level-shift the bus.
// The pads take it on the PCI clamp diode (PCI_IO ON in the .qsf, plus 4 mA
// drive), which is how the board already runs 5 V MSX cartridges and how the
// joystick ports are already treated. There is no transceiver and no direction
// control anywhere - the previous version of this file claimed pSltBdir_n was
// one, which was a misreading of the MSX BUSDIR pin.
//
//   PARAMETER SLOT_ENABLE
//     1 (the shipped value) : the bridge is live.
//     0                     : every slot pin is released and the internal bus
//        is untouched, so the machine runs exactly as it did before this module
//        existed. Kept as a one-token escape hatch because the adapter carries
//        NO termination - see the pull-up note at the bottom.
//
// ============ THE INBOUND REPLY GOES THROUGH ITS OWN D8:B ============
// On the real board the bus RPLY net (S1-49) is the internal wired-OR (S1-21,
// via D21 ЛП9) joined by D34 AND by the connector, and only then reaches D8:B -
// the flop bk_rply models - before the CPU pin. So an external module's reply
// lands BEFORE the re-timing flop. Every internal ocbk slave already satisfies
// the 1801ВМ1 falling-edge pin-sync rule by construction (their wait FSM runs
// on cpu_clk_n), which is why bk_rply is applied to the 037 alone; an external
// module is genuinely asynchronous and is the one reply source that needs the
// flop. Hence a SECOND bk_rply here - and hence NOT re-timing anything else,
// which would double-count the hardware-calibrated N_EXT / N_VREG / N_KBD (see
// bk_rply.sv's header).
//
// ============ AD DIRECTION ============
// The CPU already produces the address window we must mirror. vm1_qbus drives
// ad_oe two cpu_clk BEFORE it drops SYNC and holds one cpu_clk after, so the
// address is on ad_n well before the slave's latching edge. The bridge only has
// to copy that window out; the previous version released AD until after SYNC
// had already fallen, which is what left a real slave with no setup at all.
//
//   slot_ad_oe = din_n & ~slot_rd     // the bridge drives the PINS
//   ad_n       = slot_rd ? pSltAd     // the bridge drives ad_n INWARD
//
// OUTWARD is gated on din_n so the pins are released for the whole of any read,
// and on ~slot_rd so they STAY released through the module's data-hold time
// after DIN rises. Re-enabling the drivers the instant DIN releases would put
// 16 lines of push-pull CMOS against a module that is still driving - a real
// fight, on every single read.
//
// INWARD is gated on slot_rd, a registered flag that is set only when the
// RE-TIMED reply is asserted. Gating on DIN alone would fight an internal slave
// on every internal read. Gating on the RAW pin - which is what a first pass at
// this file naturally reaches for - is worse than it looks: it makes an
// unsynchronised, unterminated pin a combinational output-enable on the shared
// internal ad_n, so one glitch during an INTERNAL read turns on an extra driver
// and ANDs the floating connector into the word. Silent data corruption, and it
// buys nothing: the CPU samples 1.5 cpu_clk after the re-timed reply (qreg
// captures pin_ad_in on the posedge after din_done), which is already more
// setup than any real slave needs.
//
// DATIO(B) is safe by construction. A read-modify-write runs DIN then DOUT
// under ONE held SYNC. slot_rd clears only after both strobes have been idle
// for two edges, so the inward drive outlives the capture and the outward
// drivers are back on well before DOUT - the vm1 cannot start DOUT until the
// read reply's ack has cleared. The slave on the other end must obey the same
// rule from its side: return to idle on STROBES-IDLE, never on SYNC-rise (the
// CLAUDE.md RMW rule).
//
// DELIBERATE DEVIATION: because the outward drivers are off for the whole of
// any read, a module cannot snoop INTERNAL read data, which the real unbuffered
// board would show it. Nothing in a slave-only scope needs that, and the
// alternative - making the outward enable the exact complement of the inward
// one - puts both sides on the pins through the combinational turnaround at the
// reply edge.
//
// ============ SAFETY, IN THREE LAYERS ============
// The adapter has NO termination. The BK board terminates every wired-OR МПИ
// net with 3.3k / 2.2k / 22k; here the pads' internal ~25k to 3.3 V is the only
// pull-up in the system, roughly 8x weak and to the wrong rail. Measuring the
// rise time and high level on ~RPLY and AD with a module attached is the gating
// item before bring-up. Until then:
//   1. slot_live = ~smk_en. The internal SMK512 emulation and a real module
//      claim the same addresses, so they are mutually exclusive anyway. Tying
//      the slot to DIP 8 being OFF costs nothing, needs no new switch, and
//      makes the shipped default provably byte-identical: with DIP 8 on, the
//      slot reply and the inward driver are structurally dead.
//   2. A strobe-window qualifier on the reply, so an idle-bus glitch cannot
//      reach the CPU. (The vm1 also ignores RPLY outside a transaction, but
//      this keeps it off our internal net as well.)
//   3. RPLY_FILT: one extra agreement sample. Costs one cpu_clk on external
//      replies only - no internal timing constant moves and the slot has no
//      calibration target - and can be turned off once the pull-ups are fixed.

module qbus_slot #(
    parameter bit SLOT_ENABLE = 1'b1,
    parameter bit RPLY_FILT   = 1'b1
) (
    // ---- clocks / reset ---------------------------------------------------
    input  wire         cpu_clk,   // the CPU clock: D8:B re-timing + the syncs
    input  wire         rst_n,     // power-on only (vid_rst_n), like the 037

    // ---- shared internal Q-bus (inverted, active low) --------------------
    inout  wire  [15:0] ad_n,
    input  wire         sync_n,    // CPU-driven strobes (the FPGA is bus master)
    input  wire         din_n,
    input  wire         dout_n,
    input  wire         wtbt_n,
    input  wire         init_n,    // nINIT, out to the module
    inout  wire         rply_n,    // open-collector: the module replies here

    // ---- configuration / state -------------------------------------------
    input  wire         model_bk11,// DIP 1, quasi-static: resolves the deselect
    input  wire         smk_en,    // DIP 8, quasi-static: 1 = internal SMK512,
                                   //   so the slot stands down entirely
    input  wire         rom3,      // 177716 bits 3/4 (mem_mapper's D36 Q4/Q5)
    input  wire         rom4,

    // ---- host-ROM deselect, one bit per 4 KB segment -> qbus_mem ---------
    output logic [7:0]  rom_dsl_vec,

    // ---- physical МПИ pins ------------------------------------------------
    inout  wire  [15:0] pSltAd,
    output wire         pSltSync_n,
    output wire         pSltDin_n,
    output wire         pSltDout_n,
    output wire         pSltWtbt_n,
    input  wire         pSltRply_n,
    inout  wire         pSltInit_n,
    output wire         pSltRom3_n,
    output wire         pSltRom4_n,
    input  wire         pSltMon10_n,
    input  wire         pSltBas10_n,
    input  wire         pSltMon11_n
);

    generate
        if (SLOT_ENABLE) begin : g_on

            wire slot_live = ~smk_en;

            // ---- outward: the strobes are plain buffered copies -----------
            assign pSltSync_n = sync_n;
            assign pSltDin_n  = din_n;
            assign pSltDout_n = dout_n;
            assign pSltWtbt_n = wtbt_n;

            // nINIT: pull low or let go, never drive high - the МПИ net is a
            // wired-OR (the CPU, the 014 and the СБРОС keys all pull it on the
            // real board). This is a genuinely bidirectional PAD, which the
            // tri1 gotcha does not ban; that rule is about a lone Z-idle net
            // driving INTERNAL logic. We never read the pin: an input here
            // would let a floating connector hold the machine in reset.
            assign pSltInit_n = init_n ? 1'bZ : 1'b0;

            // Window-1 ROM socket selects, active low on the bus.
            assign pSltRom3_n = ~rom3;
            assign pSltRom4_n = ~rom4;

            // ---- the module's reply --------------------------------------
            logic [1:0] rply_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) rply_sr <= 2'b00;
                else        rply_sr <= {rply_sr[0], ~pSltRply_n};

            wire rply_sampled = RPLY_FILT ? (rply_sr[1] & rply_sr[0])
                                          : rply_sr[0];
            // Only inside a live strobe window, and only when the internal SMK
            // is off.
            wire slot_rply = rply_sampled & slot_live
                             & ~sync_n & (~din_n | ~dout_n);

            wire slot_rply_rt_n;
            bk_rply u_rply_slot (
                .cpu_clk   (cpu_clk),
                .rst_n     (rst_n),
                .rply_037_n(~slot_rply),  // the port name is historical
                .rply_n    (slot_rply_rt_n)
            );
            // Open-collector onto the shared net, exactly like the 037's leg in
            // ocbk_top. The 4-state compare keeps an X off the shared bus.
            assign rply_n = (slot_rply_rt_n === 1'b0) ? 1'b0 : 1'bZ;

            // ---- read-data ownership -------------------------------------
            // Set on the same negedge the re-timed reply reaches the bus, so
            // the inward data and the CPU-visible reply are coherent. Cleared
            // only after both strobes have been idle for two edges: that covers
            // the DATIO turnaround and the module's output-disable time.
            logic       slot_rd;
            logic       idle_q;
            wire        strobes_idle = din_n & dout_n;

            always_ff @(negedge cpu_clk or negedge rst_n)
                if (!rst_n) begin
                    slot_rd <= 1'b0;
                    idle_q  <= 1'b1;
                end else begin
                    idle_q <= strobes_idle;
                    if (idle_q && strobes_idle) slot_rd <= 1'b0;
                    else if (!din_n)            slot_rd <= ~slot_rply_rt_n;
                end

            // ---- AD, both directions (see the header) --------------------
            wire slot_ad_oe = din_n & ~slot_rd & slot_live;

            assign pSltAd = slot_ad_oe ? ad_n   : 16'hZZZZ;
            assign ad_n   = slot_rd    ? pSltAd : 16'hZZZZ;

            // ---- host-ROM deselect ---------------------------------------
            // 2-FF sync plus one agreement stage, then model-resolved into a
            // per-segment mask. The masks are segment-aligned to the byte, so
            // no address comparator is needed: seg = addr[14:12] and every
            // MK_ROM branch of the mapper already implies addr[15]=1.
            // 0177600-0177777 is MK_NONE in the mapper already, so "seg 7"
            // self-truncates at 0177577 - exactly the blob's BASIC/MSTD top.
            //
            // The model qualifier is not cosmetic: a real BK-0011M has NO
            // MON10/BAS10 pin (XT3 has no A14/B1/B6 - those positions are
            // BK-0010 only), and the adapter routes them from the MSX edge
            // regardless. Without the gate, a module asserting BAS10 would
            // knock out the BK-0011M top ROM, which no real machine can do.
            logic [2:0] m10_sr, b10_sr, m11_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) begin
                    m10_sr <= 3'b000;
                    b10_sr <= 3'b000;
                    m11_sr <= 3'b000;
                end else begin
                    m10_sr <= {m10_sr[1:0], ~pSltMon10_n};
                    b10_sr <= {b10_sr[1:0], ~pSltBas10_n};
                    m11_sr <= {m11_sr[1:0], ~pSltMon11_n};
                end

            wire mon10 = &m10_sr[2:1] & slot_live & ~model_bk11;
            wire bas10 = &b10_sr[2:1] & slot_live & ~model_bk11;
            wire mon11 = &m11_sr[2:1] & slot_live &  model_bk11;

            // Loaded only while the bus is idle, so the value the qbus_mem FSM
            // sees is constant for a whole cycle (qbus_mem re-registers it on
            // sclk under the same condition).
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n)       rom_dsl_vec <= 8'h00;
                else if (sync_n)  rom_dsl_vec <=
                      (mon10 ? 8'b0000_0011 : 8'h00)   // segs 0,1 = 100000-117777
                    | (bas10 ? 8'b1111_1100 : 8'h00)   // segs 2-7 = 120000-177577
                    | (mon11 ? 8'b1100_0000 : 8'h00);  // segs 6,7 = 160000-177577

        end
        else begin : g_off
            // Disabled: release every slot pin and the internal bus, and hold
            // the host ROM fully selected.
            assign pSltAd     = 16'hZZZZ;
            assign pSltSync_n = 1'bZ;
            assign pSltDin_n  = 1'bZ;
            assign pSltDout_n = 1'bZ;
            assign pSltWtbt_n = 1'bZ;
            assign pSltInit_n = 1'bZ;
            assign pSltRom3_n = 1'bZ;
            assign pSltRom4_n = 1'bZ;
            assign ad_n       = 16'hZZZZ;
            assign rply_n     = 1'bZ;
            assign rom_dsl_vec = 8'h00;
        end
    endgenerate

endmodule
