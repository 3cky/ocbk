// qbus_slot - the MPI (МПИ) expansion-bus bridge (slave only).
//
// This module connects the internal Q-bus to the physical cartridge-slot pins.
// A real BK expansion module (like an SMK512) can then attach through the passive
// adapter. Check doc/dev/mpi.md for the connector pin by pin description.
//
// SCOPE: slave only. The bridge does data transfer, RPLY and the host-ROM
// deselect. The FPGA is always the bus master. The bridge has no interrupts, no
// DMA or arbitration, and no IAK chain. The adapter connects the MPI pins for
// these functions, but this module does not drive or read them yet.
//
// ELECTRICAL: the MPI is 5 V TTL. The adapter does NOT shift the bus level.
// The pads use the PCI clamp diode (PCI_IO ON in the .qsf) and 4 mA drive.
// ~SYNC uses 8 mA (see SAFETY, IN THREE LAYERS). The board uses the same method
// for 5 V MSX cartridges and for the joystick ports. The bus has no transceiver
// and no direction control.
//
//   PARAMETER SLOT_ENABLE
//     1 (the shipped value) : the bridge is live.
//     0                     : the module releases all slot pins and does not
//        touch the internal bus. The machine then runs exactly as it did
//        before this module existed. This value is a one-token escape hatch
//        for the termination question (see SAFETY, IN THREE LAYERS).
//
// ============ THE INBOUND REPLY GOES THROUGH ITS OWN D8:B ============
// On the real board, the bus RPLY net (S1-49) joins three sources: the
// internal wired-OR (S1-21, through D21 ЛП9), D34 and the connector. After this
// point the net goes to D8:B (the flop that bk_rply models), and then to the
// CPU pin. Thus the reply of an external module arrives BEFORE the re-timing
// flop. Each internal ocbk slave obeys the 1801ВМ1 falling-edge pin-sync rule
// by construction, because its wait FSM runs on cpu_clk_n. For this reason,
// bk_rply applies to the 037 only. An external module is truly asynchronous.
// It is the one reply source that needs the flop. Thus this module has a
// SECOND bk_rply. Do NOT re-time other sources. That would count the
// hardware-calibrated N_EXT / N_VREG / N_KBD delays two times (see the header
// of bk_rply.sv).
//
// ============ AD DIRECTION ============
// The CPU already makes the address window that the bridge must copy.
// vm1_qbus drives ad_oe two cpu_clk BEFORE it pulls SYNC low, and holds it for
// one cpu_clk after. Thus the address is on ad_n well before the latching edge
// of the slave. The bridge only copies that window to the pins.
//
//   slot_ad_oe = din_n & ~slot_rd     // the bridge drives the PINS
//   ad_n       = slot_rd ? pSltAd     // the bridge drives ad_n INWARD
//
// The OUTWARD enable uses din_n, so the pins are released for all of each
// read. It also uses ~slot_rd, so the pins stay released during the data-hold
// time of the module after DIN goes high. If the drivers came on at the
// instant DIN is released, 16 push-pull CMOS lines would oppose a module that
// still drives. That conflict would occur on every read.
//
// The INWARD enable uses slot_rd. slot_rd is a registered flag. It becomes 1
// only when the RE-TIMED reply is asserted. An enable on DIN alone would
// oppose an internal slave on every internal read. An enable on the RAW pin is
// an easy first choice, but it is worse than it looks. It makes an
// unsynchronised, unterminated pin a combinational output-enable on the shared
// internal ad_n. Then one glitch during an INTERNAL read turns on an extra
// driver and ANDs the floating connector into the word. The result is silent
// data corruption, and it gives no advantage. The CPU samples 1.5 cpu_clk after
// the re-timed reply (qreg captures pin_ad_in on the posedge after din_done).
// That is already more setup time than a real slave needs.
//
// DATIO(B) is safe by construction. A read-modify-write does DIN and then DOUT
// in ONE held SYNC. slot_rd becomes 0 only after both strobes are idle for two
// edges. Thus the inward drive continues after the capture. The outward
// drivers are on again well before DOUT, because the vm1 cannot start DOUT
// until the ack of the read reply is clear. The slave at the other end must
// obey the same rule from its side. It must go back to idle on STROBES-IDLE,
// never on SYNC-rise (the CLAUDE.md RMW rule).
//
// DELIBERATE DEVIATION: the outward drivers are off for all of each read.
// Thus a module cannot monitor INTERNAL read data, as it can on the real
// unbuffered board. The slave-only scope does not need this. The alternative
// is to make the outward enable the exact complement of the inward enable. But
// then both sides drive the pins during the combinational turnaround at the
// reply edge.
//
// ============ THE START VECTOR: A MODULE THAT DRIVES BUT NEVER REPLIES ====
// The 177716 start-vector read is the one cycle on this bus where an expansion
// module supplies DATA without its own reply. Thus slot_rd cannot serve it.
// Two facts from the vendored core:
//   * vm1_qbus.v `ad_oe = ... | ~(sel_16 | sel_14 | ~sel_in)`. For a READ of
//     177716/177714, the CPU releases AD. It expects external hardware to put
//     the word there.
//   * vm1_qbus.v `pin_rply_out = (sel_in | sel_out) & ...` is combinational
//     from sel_in. The CPU replies to itself for that read at the instant DIN
//     is asserted. Thus the CPU ignores the RPLY of the module, if the module
//     sends one.
// An SMK512 answers that read with its BIOS word at image offset 07716
// (0166400). This word is wire-ORed with the start constant of the machine
// (0100000 / 0140000). The CPU masks the result with 0177400 and starts at
// 0166400, in the SMK BIOS. Thus a BK with an SMK boots the disk OS, not
// MONITOR. qbus_mem does exactly this merge for the INTERNAL SMK emulation
// (`rdata <= rd_romio | ram_rdata`). A real module can supply its word only
// through the pins.
// slot_rd comes approximately 3 cpu_clk after the reply of the module (2 sync
// flops, bk_rply and the flag itself). The CPU samples 1.5 cpu_clk after DIN.
// Thus slot_rd misses the sample, also when the module sends a reply.
//
// THE MERGE IS A VALUE, NOT A DRIVER. mpi_word goes to io_word in qbus_mem.
// qbus_mem ORs it into the 177716 leg, as it does for ide_rdata and joy_word.
// If this module drove ad_n, the internal bus would have a second driver
// during the one cycle when qbus_mem also drives it. That breaks the
// single-on-chip-driver rule that this design keeps everywhere. It also puts
// the connector pins on an output-enable cone (the enable-cone STA rule). As a
// data mux term, mpi_word changes no reply, no `selected` and no ad_oe.
//
// ARMED FOR ONE READ, NOT PERMANENT. A split bus cannot tell "the module
// released the pins" from "the module drives zeros". The pads have only the
// ~25k pull-up from the .qsf (the adapter has no termination, see
// doc/dev/mpi.md). Thus ~1.5 us after the bridge releases the lines, they are
// still near the levels of the ADDRESS that they carried last. On this
// active-low net, a low pin is an ASSERTED bit. For 177716, that old pattern
// merges as 0177716 and sends the PC to 0177400. The SMK drives 177716 only
// while its rom7 window is open (its SYS reset mode). After the BIOS sets a
// different mode, nothing drives 177716. But MONITOR reads 177716 continuously
// for the keyboard (bit 6) and the tape (bit 5).
// Thus the window opens for exactly ONE read: the start-vector fetch. At that
// time a module is in its reset mode, so it drives by construction. The window
// closes when that read ends. dclo_n arms the window. dclo_n is the reset that
// makes the vm1 run its start sequence, so the СБРОС button arms the window
// again. init_n does NOT arm it, because a RESET instruction must not open the
// window again over a MONITOR keyboard poll.
// If the AD lines had the 3.3k pull-ups of the real board (E1/E4/E5), this
// merge could apply unconditionally on every nSEL read.
//
// ============ SAFETY, IN THREE LAYERS ============
// The adapter has no termination. But the OneChipBook pulls three of these
// pads to 3V3 through 1k. Two of them are on nets where the MPI needs a
// pull-up:
//   * PIN_128 = ~RPLY. This is the most critical net on the bus. Its
//     termination is now stronger than the 3.3k of the real BK.
//   * PIN_138 = ~INIT. It is open-drain here, so a pull-up is correct for it.
// PIN_131 = ~SYNC does not match. It is a push-pull output on a 1k pull-up,
// so the .qsf gives it 8 mA drive, not 4 mA.
// The 16 AD lines and the other strobes have no termination. They have only
// the internal ~25k pull-up of the pad. For all of each cycle, one end or the
// other drives AD push-pull, and nothing samples the turnaround. Thus the rise
// time of AD is not a known problem. Until it is measured, three layers
// give protection:
//   1. slot_live = (the adapter is fitted) & ~smk_en. The internal SMK512
//      emulation and a real module use the same addresses, so they cannot
//      operate together. The slot operates only when DIP 8 is OFF.
//      The adapter ties slot pin 44 to GND. With no adapter, the
//      bridge stays inactive and does not sample a floating MSX edge. The
//      BK-0011M top-window concede also uses slot_live. Thus a bk11 with no
//      adapter keeps its mstd11m image.
//   2. A strobe-window qualifier on the reply. It stops an idle-bus glitch
//      before the glitch gets to the CPU. (The vm1 also ignores RPLY outside
//      a transaction, but the qualifier also keeps the glitch off our
//      internal net.)
//   3. RPLY_FILT: one more agreement sample. It adds one cpu_clk to external
//      replies only.

module qbus_slot #(
    parameter bit SLOT_ENABLE = 1'b1,
    parameter bit RPLY_FILT   = 1'b1
) (
    // ---- clocks / reset ---------------------------------------------------
    input  wire         cpu_clk,   // CPU clock: D8:B re-timing and the syncs
    input  wire         rst_n,     // power-on reset only (vid_rst_n), as 037
    input  wire         dclo_n,    // CPU reset: arms the start-vector merge

    // ---- shared internal Q-bus (inverted, active low) --------------------
    inout  wire  [15:0] ad_n,
    input  wire         sync_n,    // CPU strobes (the FPGA is the bus master)
    input  wire         din_n,
    input  wire         dout_n,
    input  wire         wtbt_n,
    input  wire         sel1_n,    // CPU nSEL1: 177716/17 register select
    input  wire         init_n,    // nINIT, to the module
    input  wire         e_037_n,   // E strobe of the 037 (va_037_sync PIN_nE)
    inout  wire         rply_n,    // open-collector: the module replies here

    // ---- configuration / state -------------------------------------------
    input  wire         model_bk11,// DIP 1, quasi-static: sets WHICH deselect
                                   //   wires physically exist (see the
                                   //   deselect note)
    input  wire         smk_en,    // DIP 8, quasi-static: 1 = internal SMK512,
                                   //   and the slot is fully disabled
    input  wire         rom3,      // 177716 bits 3/4 (mem_mapper's D36 Q4/Q5)
    input  wire         rom4,

    // ---- host-ROM deselect, one bit for each 4 KB segment -> qbus_mem ----
    output logic [7:0]  rom_dsl_vec,

    // ---- the 177716 contribution of the module -> qbus_mem's io_word -----
    // TRUE bus value (active high). It is not zero only in the one armed
    // start-vector read. At all other times it is 0, so a tie-off gives
    // identical behaviour. See the start-vector section of the header.
    output logic [15:0] mpi_word,

    // ---- the MPI ~ROM4 read-back -> qbus_mem -> mem_mapper ---------------
    // 1 = a module holds XT3.A22 low. Latched while the bus is idle. Gated by
    // the model.
    output logic        rom4_force,

    // ---- physical MPI pins ------------------------------------------------
    inout  wire  [15:0] pSltAd,
    output wire         pSltSync_n,
    output wire         pSltDin_n,
    output wire         pSltDout_n,
    output wire         pSltWtbt_n,
    input  wire         pSltRply_n,
    inout  wire         pSltInit_n,
    output wire         pSltRom3_n,
    inout  wire         pSltRom4_n,   // WIRED-AND, not an output (see below)
    output wire         pSltE_n,
    input  wire         pSltMon10_n,
    input  wire         pSltBas10_n,
    input  wire         pSltBas2_n,
    input  wire         pSltMon11_n,  // bk11 BOS 140000-157777 (segs 4,5)
    input  wire         pSltPresent_n // slot pin 44: low = adapter fitted
);

    generate
        if (SLOT_ENABLE) begin : g_on

            // ---- is the MPI adapter fitted? -------------------------------
            // The adapter ties slot pin 44 (FPGA 179) to GND. Without the
            // adapter, the pad pull-up holds the pin high. Thus low = fitted.
            // Without the adapter, the MPI pins are a bare MSX edge: the
            // inputs float, and the outputs drive a cartridge bus. The pin
            // also sets whether the BK-0011M concedes its top window (see
            // mstd_slot). Thus a bk11 with no adapter keeps its mstd11m image
            // and does not find an empty 160000.
            // The pin has a 3-FF sync, as the deselect wires have. It is a
            // hard tie, not a signal. But it must not be a metastable input
            // to slot_live, and slot_live goes into an OUTPUT-ENABLE cone
            // (slot_ad_oe). The CLAUDE.md enable-cone rule says that a
            // quasi-static term there gets its own flop, not an extra level
            // of logic.
            logic [2:0] pres_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) pres_sr <= 3'b000;
                else        pres_sr <= {pres_sr[1:0], ~pSltPresent_n};

            logic slot_live;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) slot_live <= 1'b0;
                else        slot_live <= &pres_sr[2:1] & ~smk_en;

            // ---- outward: the strobes are direct buffered copies ----------
            assign pSltSync_n = sync_n;
            assign pSltDin_n  = din_n;
            assign pSltDout_n = dout_n;
            assign pSltWtbt_n = wtbt_n;

            // nINIT: pull low or release, never drive high. On the real
            // board, the MPI net is a wired-OR: the CPU, the 014 and the
            // СБРОС keys all pull it low. This is a truly bidirectional PAD,
            // and the tri1 gotcha does not ban it. That rule is about a lone
            // Z-idle net that drives INTERNAL logic. We never read the pin. An
            // input here would let a floating connector hold the machine in
            // reset.
            assign pSltInit_n = init_n ? 1'bZ : 1'b0;

            // Window-1 ROM socket selects: the 177716 latch bits D36 Q4/Q5
            // go to the connector as ~ROM3/~ROM4. (Q is the INVERTED bus bit.
            // For this reason, these pins carry ~rom3/~rom4, not the raw bits.)
            assign pSltRom3_n = ~rom3;

            // ~ROM4 IS NOT AN OUTPUT. On the real board, S1-66 is a WIRED-AND.
            // D36 Q5 (К555ТМ9, a totem pole) drives it. D32.5 (К555ЛИ6) reads
            // it as one half of the Q4·Q5 "window 1 = internal RAM" term.
            // XT3.A22 lets a module pull the same net low OPEN-DRAIN and win.
            // That is how an SMK gets window 1 on a BK-0011M.
            // Thus the pin is OPEN-DRAIN OUT, and we read the resolved level
            // back. Pull the pin low when our own Q5 is low (rom4 set).
            // Release it at other times, and let the pad pull-up supply the
            // high. A22 is quasi-static: it changes only when the CPU
            // writes 177716 or the module writes its own register. Thus the RC
            // of the pull-up is not important here. (On AD, it is important.)
            // This is a PAD tri-state, and the tri1 gotcha permits it. The
            // gotcha bans a lone Z-idle net that feeds INTERNAL logic. The
            // read-back below is a synchronised pin, not a Z net.
            assign pSltRom4_n = rom4 ? 1'b0 : 1'bZ;

            // The read-back. The resolved level IS the effective Q5, so
            // ~pSltRom4_n is the effective bit 4. This is true when the low
            // comes from us and when it comes from the module. That is exactly
            // the wired-AND. It uses two sync flops and an agreement stage
            // (the deselect idiom).
            // MODEL-GATED: A22 is physically connected only on a BK-0011M
            // (the connector of a BK-0010 has no such line). But the adapter
            // carries A22 for both models. The deselect lines have the same
            // gate for the same reason.
            logic [2:0] r4_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) r4_sr <= 3'b000;
                else        r4_sr <= {r4_sr[1:0], ~pSltRom4_n};

            // This means "a module forces the line low", not only "the line
            // is low". When WE drive it low, the mapper already knows, because
            // rom4 is its own state. A second assertion here would add a
            // redundant path into the banking cone.
            wire r4_forced = &r4_sr[2:1] & ~rom4 & slot_live & model_bk11;

            // Latched while the bus is idle, as rom_dsl_vec is. A module
            // changes this line as a side effect of a write to its own
            // register. Thus it must not change during a cycle of the qbus_mem
            // FSM. (qbus_mem registers it again on sclk under the same
            // condition.)
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n)      rom4_force <= 1'b0;
                else if (sync_n) rom4_force <= r4_forced;

            // The E strobe of the 037, sent directly to the pin. On a BK-0010,
            // E (not DIN) strobes the reads of the TOP ROM window
            // (160000-177577). The DS19 of the machine gets its DIN from
            // XT3.A29, which is E through the series resistor R60. An MPI
            // module reads the raw E on XT3.A30 to strobe its own replacement
            // ROM. The second ROM of MSTD works this way. Without this pin,
            // such a module can never reply.
            // The polarity and the qualification are already correct.
            // va_037_sync's PIN_nE is `SYNC | DIN | (A >= 177600)`, i.e. a read
            // cycle outside the I/O page. Thus it needs no inversion or gate.
            assign pSltE_n = e_037_n;

            // ---- the reply of the module ---------------------------------
            logic [1:0] rply_sr;
            always_ff @(posedge cpu_clk or negedge rst_n)
                if (!rst_n) rply_sr <= 2'b00;
                else        rply_sr <= {rply_sr[0], ~pSltRply_n};

            wire rply_sampled = RPLY_FILT ? (rply_sr[1] & rply_sr[0])
                                          : rply_sr[0];
            // Only in a live strobe window, and only when slot_live is 1 (the
            // adapter is fitted and the internal SMK is off).
            wire slot_rply = rply_sampled & slot_live
                             & ~sync_n & (~din_n | ~dout_n);

            wire slot_rply_rt_n;
            bk_rply u_rply_slot (
                .cpu_clk   (cpu_clk),
                .rst_n     (rst_n),
                .rply_037_n(~slot_rply),  // the port name is historical
                .rply_n    (slot_rply_rt_n)
            );
            // Open-collector onto the shared net, as the 037 leg in ocbk_top.
            // The 4-state compare keeps an X off the shared bus.
            assign rply_n = (slot_rply_rt_n === 1'b0) ? 1'b0 : 1'bZ;

            // ---- read-data ownership -------------------------------------
            // slot_rd becomes 1 on the same negedge that the re-timed reply
            // gets to the bus. Thus the inward data and the reply that the CPU
            // sees are coherent. slot_rd becomes 0 only after both strobes are
            // idle for two edges. That covers the DATIO turnaround and the
            // output-disable time of the module.
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
            // sel1_n is the OWN register-select pin of the CPU. It is stable
            // for all of the SYNC window (sel_16 registers on clk_p while SYNC
            // is idle). Thus internal, synchronous terms open and close this
            // window. No connector pin is an enable here.
            logic vec_arm;      // 1 = the start-vector read is not done yet
            logic sel1_rd_q;    // edge detect: closes the window when DIN rises
            wire  sel1_rd = ~sync_n & ~din_n & ~sel1_n & slot_live;

            always_ff @(negedge cpu_clk or negedge rst_n)
                if (!rst_n) begin
                    vec_arm   <= 1'b1;
                    sel1_rd_q <= 1'b0;
                end else begin
                    sel1_rd_q <= sel1_rd;
                    // Arm again while the CPU is in reset. Thus a warm reset
                    // (СБРОС -> the dclo/aclo sequencer) runs the start
                    // sequence again with the window open.
                    if (!dclo_n)                    vec_arm <= 1'b1;
                    // Disarm when that first read ENDS, never at its detection
                    // edge. The CPU samples 1.5 cpu_clk after DIN.
                    else if (sel1_rd_q & ~sel1_rd)  vec_arm <= 1'b0;
                end

            // TRUE bus value: the pins are inverted. An absent or released
            // module reads as all ones, which gives 0. 0 is the identity for
            // the OR in io_word.
            assign mpi_word = (vec_arm & sel1_rd) ? ~pSltAd : 16'h0000;

            // ---- AD, both directions (see the header) --------------------
            wire slot_ad_oe = din_n & ~slot_rd & slot_live;

            assign pSltAd = slot_ad_oe ? ad_n   : 16'hZZZZ;
            assign ad_n   = slot_rd    ? pSltAd : 16'hZZZZ;

            // ---- host-ROM deselect ---------------------------------------
            // A 2-FF sync and one agreement stage, then the model selects a
            // mask for each segment. The masks align with the segments to the
            // byte, so no address comparator is necessary: seg = addr[14:12],
            // and each MK_ROM branch of the mapper already implies addr[15]=1.
            // The mapper already makes 0177600-0177777 MK_NONE. Thus "seg 7"
            // stops at 0177577, which is exactly the BASIC/MSTD top of the
            // blob.
            //
            // The four disable lines, and the ROM that each line really
            // covers. On a BK-0010-01 the ROM set is four RE2A masks:
            //   DS17 017  100000-117777  CE = GND      <- MON10 (a user mod.
            //        The stock CE is hardwired. For this reason, the SMK512
            //        installation adds a wire.)
            //   DS18 106  120000-137777  CE = XT3.A14  <- BAS
            //   DS20 107  140000-157777  CE = XT3.A14  <- BAS  (SAME line)
            //   DS19 108  160000-177577  CE = GND, but its DIN comes from
            //        XT3.A29 (= E through R60), so a held A29 silences it
            //                                        <- BAS2
            // Thus BAS covers segs 2-5 ONLY. The SMK512 drives all four lines
            // (P5.B1 MON10, P5.A14 BAS, P5.A29 BAS2, P5.B6 M11 -> its CPLD).
            // Thus it needs all four.
            //
            // THE MODEL QUALIFIER IS THE REAL WIRING OF EACH MODEL.
            // BAS/BAS2/MON10 are **physically connected only on a BK-0010**.
            // M11 and P4O are connected only on a BK-0011M. The installation
            // adds different wires to each host.
            // But the ADAPTER routes all of them from the MSX edge for both
            // models. Thus the FPGA sees each line that the module drives, for
            // each model. This gate changes that back into the real machine:
            // it emulates which wires EXIST.
            // The module drives the lines with no data about its host.
            // Thus, on a BK-0010, the module silences the BASIC ROMs from
            // power-on, and the start vector goes into its own BIOS. On a
            // BK-0011M, those wires go nowhere. There, two OTHER mechanisms
            // do the takeover:
            //   * The host concedes the segments that the start vector needs.
            //     MSTD is itself an MPI card, so it is not there when the
            //     module is (see mstd_slot below).
            //   * The P4O wired-AND takes window 1 (see doc/dev/mpi.md).
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

            // M11 deselects the BK-0011M **BOS** ROM at 140000-157777 (segs
            // 4,5), and the module puts a RAM window there. As MON10 on a
            // BK-0010, M11 is an after-market wire that the SMK512
            // installation adds. For this reason, no stock BK-0011M schematic
            // shows it. It is NOT the 160000 window. That window needs no
            // wire, because MSTD is itself an MPI card (see mstd_slot below).
            wire mon11 = &m11_sr[2:1] & slot_live &  model_bk11;

            // On a BK-0011M, 160000-177577 is not motherboard ROM. MSTD is on
            // an MPI card there, so it cannot be in the slot together with a
            // different module.
            wire mstd_slot = slot_live & model_bk11;

            // Loaded only while the bus is idle. Thus the value that the
            // qbus_mem FSM sees is constant for a full cycle. (qbus_mem
            // registers it again on sclk under the same condition.)
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
            // Disabled: release all slot pins and the internal bus. Keep the
            // host ROM fully selected.
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
