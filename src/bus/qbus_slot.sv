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
// ============ THE START VECTOR: A MODULE THAT DRIVES BUT NEVER REPLIES ====
// The 177716 start-vector read is the one cycle on this bus where an expansion
// module supplies DATA with no reply of its own, and slot_rd therefore cannot
// serve it. Two facts from the vendored core:
//   * vm1_qbus.v `ad_oe = ... | ~(sel_16 | sel_14 | ~sel_in)` - for a READ of
//     177716/177714 the CPU releases AD and expects external hardware to put
//     the word there;
//   * vm1_qbus.v `pin_rply_out = (sel_in | sel_out) & ...` is combinational off
//     sel_in - the CPU self-replies for that read the instant DIN asserts, so
//     the module's own RPLY, if it sends one at all, is irrelevant to it.
// An SMK512 answers that read with its BIOS word at image offset 07716
// (0166400), which wire-ORs with the machine's start constant (0100000 /
// 0140000); the CPU masks the result with 0177400 and starts at 0166400 inside
// the SMK BIOS. That is what makes an SMK'd BK boot to the disk OS instead of
// to MONITOR. qbus_mem performs exactly this merge for the INTERNAL SMK
// emulation (`rdata <= rd_romio | ram_rdata`); a real module can only reach it
// through the pins.
// slot_rd is ~3 cpu_clk behind the module's reply (2 sync flops + bk_rply +
// the flag itself) while the CPU samples 1.5 cpu_clk after DIN, so it misses
// the sample even when a reply does come.
//
// THE MERGE IS A VALUE, NOT A DRIVER. mpi_word goes out to qbus_mem's io_word
// and is OR-ed into the 177716 leg there, the same way ide_rdata and joy_word
// already reach that latch. Driving ad_n from here instead would put a second
// driver on the internal bus for the one cycle qbus_mem is also driving it -
// the single-on-chip-driver rule this design keeps everywhere - and it would
// put the connector pins on an output-enable cone (the enable-cone STA rule).
// As a data mux term it changes no reply, no `selected` and no ad_oe.
//
// ARMED FOR ONE READ, NOT PERMANENT. A split bus cannot tell "the module
// released the pins" from "the module is driving zeros": the pads carry the
// .qsf's ~25k pull-up alone (the adapter has no termination - see
// doc/dev/mpi.md), so ~1.5 us after the bridge releases them the lines are
// still near the level of the ADDRESS they last carried, and a low pin is an
// ASSERTED bit on this active-low net. For 177716 that stale pattern merges as
// 0177716 and sends the PC to 0177400. The SMK drives 177716 only while its
// rom7 window is up (its SYS reset mode); after the BIOS commits another mode
// nothing drives it, and 177716 is read constantly by MONITOR for the keyboard
// (bit 6) and the tape (bit 5).
// So the window is opened for exactly ONE read - the start-vector fetch, where
// a module sits in its reset mode and is driving by construction - and closes
// when that read ends. The arm is keyed to dclo_n, the same reset that makes
// the vm1 run its start sequence, so the СБРОС button re-arms it; it is NOT
// keyed to init_n, because a RESET instruction must not re-open the window
// over a MONITOR keyboard poll.
// Fitting the AD lines with the real board's 3.3k pull-ups (E1/E4/E5) is what
// would let this become an unconditional merge on every nSEL read.
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
//   1. slot_live = (the adapter is fitted) & ~smk_en. The internal SMK512
//      emulation and a real module claim the same addresses, so they are
//      mutually exclusive anyway; tying the slot to DIP 8 being OFF costs
//      nothing, needs no new switch, and makes the shipped default provably
//      byte-identical - with DIP 8 on, the slot reply and the inward driver
//      are structurally dead. The adapter term came later (2026-09-06) and
//      does the same job for the OTHER way the slot can be absent: slot pin
//      44 is tied to GND by the adapter, so with no adapter the bridge stands
//      down rather than sampling a floating MSX edge - and, since the
//      BK-0011M top-window concede hangs off slot_live, a bk11 with no
//      adapter keeps its mstd11m image.
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
    input  wire         dclo_n,    // CPU reset: re-arms the start-vector merge

    // ---- shared internal Q-bus (inverted, active low) --------------------
    inout  wire  [15:0] ad_n,
    input  wire         sync_n,    // CPU-driven strobes (the FPGA is bus master)
    input  wire         din_n,
    input  wire         dout_n,
    input  wire         wtbt_n,
    input  wire         sel1_n,    // CPU nSEL1: 177716/17 register select
    input  wire         init_n,    // nINIT, out to the module
    input  wire         e_037_n,   // the 037's E strobe (va_037_sync PIN_nE)
    inout  wire         rply_n,    // open-collector: the module replies here

    // ---- configuration / state -------------------------------------------
    input  wire         model_bk11,// DIP 1, quasi-static: WHICH deselect wires
                                   //   physically exist - see the deselect note
    input  wire         smk_en,    // DIP 8, quasi-static: 1 = internal SMK512,
                                   //   so the slot stands down entirely
    input  wire         rom3,      // 177716 bits 3/4 (mem_mapper's D36 Q4/Q5)
    input  wire         rom4,

    // ---- host-ROM deselect, one bit per 4 KB segment -> qbus_mem ---------
    output logic [7:0]  rom_dsl_vec,

    // ---- the module's 177716 contribution -> qbus_mem's io_word ----------
    // TRUE bus value (active high), non-zero only inside the one armed
    // start-vector read; 0 always otherwise, so a tie-off is behaviour-
    // identical. See the start-vector section of the header.
    output logic [15:0] mpi_word,

    // ---- the МПИ ~ROM4 read-back -> qbus_mem -> mem_mapper ---------------
    // 1 = a module is holding XT3.A22 low. Bus-idle latched, model-gated.
    output logic        rom4_force,

    // ---- physical МПИ pins ------------------------------------------------
    inout  wire  [15:0] pSltAd,
    output wire         pSltSync_n,
    output wire         pSltDin_n,
    output wire         pSltDout_n,
    output wire         pSltWtbt_n,
    input  wire         pSltRply_n,
    inout  wire         pSltInit_n,
    output wire         pSltRom3_n,
    inout  wire         pSltRom4_n,   // WIRED-AND, not an output - see below
    output wire         pSltE_n,
    input  wire         pSltMon10_n,
    input  wire         pSltBas10_n,
    input  wire         pSltBas2_n,
    input  wire         pSltMon11_n,  // bk11 BOS 140000-157777 (segs 4,5)
    input  wire         pSltPresent_n // slot pin 44: low = the adapter is on
);

    generate
        if (SLOT_ENABLE) begin : g_on

            // ---- is the МПИ adapter fitted? -------------------------------
            // Slot pin 44 (FPGA 179) is tied to GND by the adapter and pulled
            // up in the pad otherwise, so low = fitted. Without it the МПИ pins
            // are a bare MSX edge: floating inputs to sample and a cartridge
            // bus to drive. It also decides whether the BK-0011M top window is
            // conceded - see mstd_slot - so a bk11 with no adapter keeps its
            // mstd11m image instead of finding nothing at 160000.
            // 3-FF synced like the deselect wires. It is a hard tie, not a
            // signal, but it must not be a metastable input to slot_live, and
            // slot_live reaches OUTPUT-ENABLE cones (slot_ad_oe, pSltInit_n):
            // the CLAUDE.md enable-cone rule says a quasi-static term there
            // gets its own flop rather than an extra level of logic.
            logic [2:0] pres_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) pres_sr <= 3'b000;
                else        pres_sr <= {pres_sr[1:0], ~pSltPresent_n};

            logic slot_live;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) slot_live <= 1'b0;
                else        slot_live <= &pres_sr[2:1] & ~smk_en;

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

            // Window-1 ROM socket selects: the 177716 latch bits D36 Q4/Q5,
            // out to the connector as ~ROM3/~ROM4. (Q is the INVERTED bus bit,
            // which is why these carry ~rom3/~rom4 and not the raw bits.)
            assign pSltRom3_n = ~rom3;

            // ~ROM4 IS NOT AN OUTPUT. On the real board S1-66 is a WIRED-AND:
            // D36 Q5 (К555ТМ9, a totem pole) drives it, D32.5 (К555ЛИ6) reads
            // it as half of the Q4·Q5 "window 1 = internal RAM" term, and
            // XT3.A22 lets a module OPEN-DRAIN the same net and win. That is
            // how an SMK takes window 1 on a BK-0011M, and it is the ONLY thing
            // such a module does to the host at reset: smk64.vhd drives p4o
            // through an `opndrn` buffer from extended_reg(2) = 0 at reset, so
            // the line is pulled low from power-on. Driving this pin push-pull
            // - which this file did until 2026-09-06 - fights that open drain
            // on every access AND hides the bank force, which is why a real
            // SMK512 never booted a BK-0011M.
            // So: OPEN-DRAIN OUT, and read the resolved level back in. Pull low
            // when our own Q5 is low (rom4 set), release otherwise and let the
            // pad pull-up - WEAK_PULL_UP_RESISTOR on PIN_161 in the .qsf, added
            // with this - supply the high. A22 is quasi-static (it moves only
            // when the CPU writes 177716 or the module writes its own register)
            // so the pull-up's RC is irrelevant here, unlike on AD.
            // This is a PAD tri-state, which the tri1 gotcha permits; what it
            // bans is a lone Z-idle net feeding INTERNAL logic, and the
            // read-back below is a synchronised pin, not a Z net.
            assign pSltRom4_n = rom4 ? 1'b0 : 1'bZ;

            // The read-back. The resolved level IS the effective Q5, so
            // ~pSltRom4_n is the effective bit 4 - true whether the low came
            // from us or from the module, which is exactly the wired-AND. Two
            // sync flops plus an agreement stage, the deselect idiom.
            // MODEL-GATED: A22 is physically wired only on a BK-0011M (a
            // BK-0010's connector has no such line), while the adapter carries
            // it in both cases - the same reason the deselect lines are gated.
            logic [2:0] r4_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) r4_sr <= 3'b000;
                else        r4_sr <= {r4_sr[1:0], ~pSltRom4_n};

            // "A module is forcing it", not merely "the line is low": when WE
            // are driving it low the mapper already knows (rom4 is its own
            // state) and re-asserting it here would be a second, redundant
            // path into the banking cone.
            wire r4_forced = &r4_sr[2:1] & ~rom4 & slot_live & model_bk11;

            // Bus-idle latched, like rom_dsl_vec: a module moves this as a side
            // effect of a write to its own register, so it must not change
            // under the qbus_mem FSM mid-cycle. (qbus_mem re-registers it on
            // sclk under the same condition.)
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n)      rom4_force <= 1'b0;
                else if (sync_n) rom4_force <= r4_forced;

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

            // ---- the armed start-vector merge (see the header) -----------
            // sel1_n is the CPU's OWN register-select pin, stable for the whole
            // SYNC window (sel_16 registers on clk_p while SYNC is idle), so
            // this window opens and closes off internal, synchronous terms - no
            // connector pin is ever an enable here.
            logic vec_arm;      // the start-vector read is still to come
            logic sel1_rd_q;    // edge detect, to close the window on DIN rise
            wire  sel1_rd = ~sync_n & ~din_n & ~sel1_n & slot_live;

            always_ff @(negedge cpu_clk or negedge rst_n)
                if (!rst_n) begin
                    vec_arm   <= 1'b1;
                    sel1_rd_q <= 1'b0;
                end else begin
                    sel1_rd_q <= sel1_rd;
                    // Re-arm for as long as the CPU is held in reset, so a
                    // warm reset (СБРОС -> the dclo/aclo sequencer) re-runs
                    // the start sequence with the window open.
                    if (!dclo_n)                    vec_arm <= 1'b1;
                    // ...and spend it when that first read ENDS, never at its
                    // detection edge: the CPU samples 1.5 cpu_clk after DIN.
                    else if (sel1_rd_q & ~sel1_rd)  vec_arm <= 1'b0;
                end

            // TRUE bus value: the pins are inverted, and an absent or released
            // module reads all-ones -> 0, the identity for the OR in io_word.
            assign mpi_word = (vec_arm & sel1_rd) ? ~pSltAd : 16'h0000;

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
            // THE MODEL QUALIFIER IS THE REAL PER-MODEL WIRING, and it took a
            // wrong turn to establish that. BAS/BAS2/MON10 are **physically
            // wired only on a BK-0010**, M11 and P4O only on a BK-0011M - the
            // installation adds different wires to each host. The ADAPTER,
            // though, routes all of them from the MSX edge in both cases, so
            // the FPGA sees whatever the module drives on every line whichever
            // model is selected. This gate is what turns that back into the
            // real machine: it emulates which wires EXIST.
            // The module drives them with no idea which host it is in, and the
            // module's own RTL shows it cannot: in ~/projects/other/fpga/smk
            // (smk64.vhd - same family, its control register is the "ab-used"
            // floppy register of doc/smk64.mac) `bas` and `bas2` are TIED
            // ASSERTED with no model input anywhere, while mon10/mon11 come
            // from extended_reg, "0000000" at reset. So on a BK-0010 the module
            // silences the BASIC ROMs from power-on and the start vector lands
            // in its own BIOS; on a BK-0011M those wires go nowhere and the
            // takeover is two OTHER mechanisms: the segments the start vector
            // needs are conceded because МСТД is itself an МПИ card and so is
            // not there (see mstd_slot below), and window 1 is taken by the P4O
            // wired-AND (see doc/dev/mpi.md). Honouring bas/bas2 on a bk11 is therefore WRONG,
            // and doing it deselected 0120000-0177577 on a machine no module
            // had claimed: tried on hardware 2026-09-05, it made the BK-0011M
            // no-boot worse, not better.
            // That the reset state matches BkEmu's MODE_SYS on the BK-0010 side
            // - BAS + BAS2 asserted (segs 2-5 = SMK RAM, segs 6,7 = the BIOS
            // windows), MON10 released (mon_en=1, the MONITOR stays) - also
            // fixes the polarity: '1' on the МПИ is ASSERTED, inverted to
            // active-low by the adapter's BSS138.
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

            // M11 takes the BK-0011M **BOS** ROM at 140000-157777 - segs 4,5 -
            // and the module puts a RAM window there instead. Like MON10 on a
            // BK-0010 it is an AFTER-MARKET wire, added by the SMK512
            // installation, which is why it is on no stock BK-0011M schematic.
            // It is NOT the 160000 window: that one needs no wire at all,
            // because МСТД is itself an МПИ card (see mstd_slot below).
            wire mon11 = &m11_sr[2:1] & slot_live &  model_bk11;

            // 160000-177577 on a BK-0011M is NOT motherboard ROM. МСТД lives on
            // an МПИ card there, so it is mutually exclusive with any other
            // module: plug in an SMK512 and the МСТД board comes out. Our blob
            // carries mstd11m because that is the stock fit, so when the slot is
            // live on a BK-0011M the connector owns those two segments and the
            // image must stand down - no deselect wire is involved, the host
            // simply has nothing there. On a BK-0010 the same addresses ARE on
            // the motherboard (BASIC bank 3), which is what BAS2 takes away.
            // M11 is a SEPARATE window, not this one: it takes BOS at
            // 140000-157777 (segs 4,5) so the module can put RAM there. Both
            // are needed, and neither substitutes for the other.
            wire mstd_slot = slot_live & model_bk11;

            // Loaded only while the bus is idle, so the value the qbus_mem FSM
            // sees is constant for a whole cycle (qbus_mem re-registers it on
            // sclk under the same condition).
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n)       rom_dsl_vec <= 8'h00;
                else if (sync_n)  rom_dsl_vec <=
                      (mon10 ? 8'b0000_0011 : 8'h00)   // segs 0,1 = 100000-117777
                    | (bas10 ? 8'b0011_1100 : 8'h00)   // segs 2-5 = 120000-157777
                    | (bas2  ? 8'b1100_0000 : 8'h00)   // segs 6,7 = 160000-177577
                    | (mon11 ? 8'b0011_0000 : 8'h00)   // segs 4,5 = BOS 140000-157777
                    | (mstd_slot ? 8'b1100_0000 : 8'h00); // segs 6,7, bk11 card

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
            assign rom4_force  = 1'b0;
            assign pSltE_n    = 1'bZ;
            assign ad_n       = 16'hZZZZ;
            assign rply_n     = 1'bZ;
            assign rom_dsl_vec = 8'h00;
            assign mpi_word    = 16'h0000;
        end
    endgenerate

endmodule
