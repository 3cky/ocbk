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
// drive - 8 mA on ~SYNC, see the pull-up note), which is how the board already
// runs 5 V MSX cartridges and how the joystick ports are already treated. There
// is no transceiver and no direction control anywhere - the previous version of
// this file claimed pSltBdir_n was one, which was a misreading of MSX BUSDIR.
//
//   PARAMETER SLOT_ENABLE
//     1 (the shipped value) : the bridge is live.
//     0                     : every slot pin is released and the internal bus
//        is untouched, so the machine runs exactly as it did before this module
//        existed. Kept as a one-token escape hatch for the termination question
//        - see the pull-up note further down.
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
// The adapter has no termination of its own, but the OneChipBook pulls three of
// these pads to 3V3 with 1k, and two of them land where the МПИ wants them:
// PIN_128 = ~RPLY (the most critical net on the bus, and now terminated harder
// than the real BK's own 3.3k) and PIN_138 = ~INIT (open-drain here, so exactly
// what a pull-up is for). PIN_131 = ~SYNC is the mismatch - a push-pull output
// on a 1k pull-up, so it takes 8 mA drive in the .qsf instead of 4.
// What is left unterminated is the 16 AD lines and the remaining strobes, on
// the pads' internal ~25k alone. AD is driven push-pull from one end or the
// other for the whole of every cycle and nobody samples the turnaround, so
// measuring its rise time with a module attached is the remaining gating item
// rather than a known problem. Until then:
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
//      calibration target. It was written when ~RPLY was believed to be on a
//      weak internal pull-up alone; with the board's 1k on PIN_128 it can go to
//      0 with more confidence, but leave it until the board says so.

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
    input  wire         e_037_n,   // the 037's E strobe (va_037_sync PIN_nE)
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
    output wire         pSltE_n,
    input  wire         pSltMon10_n,
    input  wire         pSltBas10_n,
    input  wire         pSltBas2_n,
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

            // The 037's E strobe, straight out. On a BK-0010 the TOP ROM window
            // (160000-177577) is read-strobed by E, not by DIN: the machine's
            // own DS19 takes its DIN from XT3.A29, which is E through the series
            // resistor R60, and an МПИ module reads the raw E on XT3.A30 to
            // strobe its own replacement ROM. That is how МСТД's second ROM
            // works, and without this pin such a module can never reply.
            // Already the right polarity and qualification - va_037_sync's
            // PIN_nE is `SYNC | DIN | (A >= 177600)`, i.e. a read cycle outside
            // the I/O page - so it needs no inversion or gating here.
            assign pSltE_n = e_037_n;

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
            // The four disable lines, and which ROM each one really covers -
            // traced from doc/bk0010-01.sch and doc/smk512-scheme-v1.0.sch,
            // NOT guessed. On a BK-0010-01 the ROM set is four RE2A masks:
            //   DS17 017  100000-117777  CE = GND      <- MON10 (a user mod;
            //        the stock CE is hardwired, which is why the SMK512 install
            //        adds a wire)
            //   DS18 106  120000-137777  CE = XT3.A14  <- BAS
            //   DS20 107  140000-157777  CE = XT3.A14  <- BAS  (SAME line)
            //   DS19 108  160000-177577  CE = GND, but its DIN comes from
            //        XT3.A29 (= E through R60), so holding A29 silences it
            //                                        <- BAS2
            // So BAS covers segs 2-5 ONLY. Giving it segs 6,7 as well - the
            // first version of this file did - makes ocbk stand down over a
            // window no module has claimed, and the CPU bus-times-out there.
            // Confirmed on hardware with an МСТД module: FOCAL at 120000 ran,
            // the tests ROM at 160000 died with a bus error.
            // The SMK512 drives all four (P5.B1 MON10, P5.A14 BAS, P5.A29 BAS2,
            // P5.B6 M11 -> its CPLD), so all four are load-bearing for it.
            //
            // The model qualifier is not cosmetic: MON10/BAS/BAS2 are BK-0010
            // lines and M11 is the BK-0011M one, and a module drives whichever
            // its host has. Without the gate a module asserting BAS2 on a bk11
            // would knock out the top ROM by the wrong mechanism.
            logic [2:0] m10_sr, b10_sr, b2_sr, m11_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) begin
                    m10_sr <= 3'b000;
                    b10_sr <= 3'b000;
                    b2_sr  <= 3'b000;
                    m11_sr <= 3'b000;
                end else begin
                    m10_sr <= {m10_sr[1:0], ~pSltMon10_n};
                    b10_sr <= {b10_sr[1:0], ~pSltBas10_n};
                    b2_sr  <= {b2_sr[1:0],  ~pSltBas2_n};
                    m11_sr <= {m11_sr[1:0], ~pSltMon11_n};
                end

            wire mon10 = &m10_sr[2:1] & slot_live & ~model_bk11;
            wire bas10 = &b10_sr[2:1] & slot_live & ~model_bk11;
            wire bas2  = &b2_sr[2:1]  & slot_live & ~model_bk11;
            wire mon11 = &m11_sr[2:1] & slot_live &  model_bk11;

            // Loaded only while the bus is idle, so the value the qbus_mem FSM
            // sees is constant for a whole cycle (qbus_mem re-registers it on
            // sclk under the same condition).
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n)       rom_dsl_vec <= 8'h00;
                else if (sync_n)  rom_dsl_vec <=
                      (mon10 ? 8'b0000_0011 : 8'h00)   // segs 0,1 = 100000-117777
                    | (bas10 ? 8'b0011_1100 : 8'h00)   // segs 2-5 = 120000-157777
                    | (bas2  ? 8'b1100_0000 : 8'h00)   // segs 6,7 = 160000-177577
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
            assign pSltE_n    = 1'bZ;
            assign ad_n       = 16'hZZZZ;
            assign rply_n     = 1'bZ;
            assign rom_dsl_vec = 8'h00;
        end
    endgenerate

endmodule
