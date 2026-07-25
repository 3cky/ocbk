// qbus_pkg - shared Q-bus constants for the ocbk BK-0010 core.
//
// The Q-bus itself is carried as plain tri-state wires shared at the parent
// (cpu_test) level - every participant (the vm1 core, the qbus_sdram slave, and
// the optional qbus_slot bridge) connects to the same inverted, active-low nets
// and follows open-collector / drive-Z discipline, exactly as vm1.v already does
// (`x ? 1'b0 : 1'bZ` and `ad_n = ena ? ~out : 1'bZ`). SystemVerilog interfaces
// are avoided deliberately: neither Quartus II 11.0 nor Icarus handle tri-state
// interface members reliably, and plain nets resolve multiple drivers naturally.
//
// This package only carries the decode bounds and the deterministic RPLY latency
// reproduced from the bk10 timing testbench.
package qbus_pkg;

   // True-polarity address decode (octal), matching bk10_tb:
   //   RAM : address  < 100000
   //   ROM : 100000 <= address < 177600
   //   I/O : address >= 177600
   localparam logic [15:0] RAM_TOP = 16'o100000;
   localparam logic [15:0] IO_BASE = 16'o177600;

   // Deterministic RPLY latency, in slave-clock cycles. The on-chip slave hides
   // its (zero) memory latency behind these fixed counts so the CPU stalls for
   // exactly as many cycles as on real К565РУ5 DRAM / mask ROM.
   //   N_RAM : RPLY this many cycles after DIN/DOUT asserted for RAM
   //   N_ROM : ditto for ROM and I/O
   localparam int unsigned N_RAM = 4;
   localparam int unsigned N_ROM = 2;

   // Keyboard controller (bk_kbd014, Phase 6): fixed RPLY latency for the
   // 177660/177662 register accesses and for the IAK vector cycle, in
   // cpu_clk FSM edges (N_ROM convention; N==1 = reply at the detection
   // edge itself). Calibrated against the vp_014 netlist reference run by
   // the interrupt-latency golden (sim/ref014/golden_kbd.txt): the real 014
   // is an asynchronous chip - its RPLY follows the strobe within ~150 ns,
   // which only the single-edge reply reproduces.
   localparam int unsigned N_KBD = 1;
   localparam int unsigned N_IAK = 1;

   // ---- Phase-7 mem_mapper region kinds (BK-0011M banking) -----------------
   // Plain localparams (no enum) - Quartus II 11.0 chokes on package enums used
   // across module boundaries. Writability is encoded by the kind itself:
   //   MK_NONE   : undecoded -> no reply, the CPU's qbto timer -> trap 4
   //   MK_RAM037 : 037-owned RPLY (the arbitrated DRAM window; read+write) -
   //               ALL internal RAM, incl. BK-0011M window-1 banked RAM (the
   //               real 037 fronts it too: qbus_mem exports ext_ram so
   //               va_037_sync forces A15 low - see the a15_037 note there)
   //   MK_EXT    : Phase-8 SMK512 external RAM (its own controller on the real
   //               Q-bus -> a genuine fixed-latency FSM reply, NOT 037-owned /
   //               cycle-stolen). Rides the same cpu_sdram_dp port-0 datapath
   //               with the mapper's phys; read+write, done-gated both ways.
   //               The mapper's smk_ro flag (HLT10 seg 0 / the ALL-mode seg-7
   //               extent) turns off the write reply -> a write bus-times-out
   //               -> trap 4, exactly the MK_ROM write rule; the mirror smk_wo
   //               (the HLT-mode write-only extent) turns off the READ reply.
   //               Not used by internal RAM (window 1 is MK_RAM037).
   //   MK_ROM    : FSM-owned RPLY on reads; read-only. WRITES get NO reply ->
   //               the CPU's qbto timer -> trap 4 (authentic mask/overlay ROM;
   //               the "write until trap 4" screen-clear idiom relies on it).
   //               BkEmu agrees (ReadOnlyMemory.write -> not-written -> BUS_ERROR
   //               -> vector 4). Applies to the fixed top ROM AND BK-0011M
   //               window-1 ROM overlays alike.
   localparam logic [1:0] MK_NONE   = 2'd0;
   localparam logic [1:0] MK_RAM037 = 2'd1;
   localparam logic [1:0] MK_EXT    = 2'd2;
   localparam logic [1:0] MK_ROM    = 2'd3;

   // MK_EXT fixed reply count = the SMK512 RAM reply. CALIBRATED 2026-07-25
   // against a real BK-0011M + SMK512 (was the Phase-8 placeholder N_RAM = 4),
   // CONFIRMED ON HARDWARE 2026-07-26: the board plays 602 Hz against the real
   // machine's 601.
   //
   // Method (sim/smktime, the oracle that keeps it honest): doc/sndtestsmk.mac
   // toggles the 177716 speaker bit around a 192-iteration SOB delay loop, so
   // one tone half-period = 197 instruction fetches and NOTHING else that
   // touches memory (the vm1 self-replies for 177700-177717). Run the loop
   // from SMK RAM and the tone is a direct readout of this constant; run the
   // same loop from ordinary RAM and it is a control for everything else.
   //
   //                     loop in SMK RAM     loop in ordinary RAM (control)
   //     real            601 Hz (3351 cyc)   478 Hz (4212 cyc)
   //     board @4        514 Hz (3918 cyc)   482 Hz (4177 cyc)  -14.5% / +0.84%
   //     board @1        602 Hz              482 Hz             +0.17% / +0.84%
   //     sim/smktime @1  599 Hz (3362 cyc)   482 Hz (4176 cyc)
   //
   // The control leg being right to +0.8% is what makes this a measurement of
   // N_EXT and not of the clock rate or the CPU core. One unit of N is exactly
   // one CPU cycle, and the gap was 567 cycles / 197 accesses = 2.88, putting
   // the real board at N ~= 1: it replies WITHIN the strobe cycle, like any
   // async external SRAM board - the same reason N_KBD = 1 for the 1801ВП1-014.
   //
   // The sim reads 599 rather than the ideal 3327 cyc / 605 Hz because a
   // minority of reads miss the detection edge by one and take the S_WAIT
   // fallback (see the cpu_sdram_dp note; sim/smktime's EXTRD line pins the
   // rate). That is a testbench artefact: its port-2 model SATURATES the
   // arbiter, while the shipped video fetch is paced - which is exactly why
   // the board lands HIGHER than the sim, at 602. The bk10 leg, whose slower
   // CPU clock gives the fetch more head start, already reaches 3328 = ideal.
   //
   // WHAT THE RESIDUAL IS, now that the board has been measured: NOT a uniform
   // global bias. SMK RAM is +0.17% while ordinary RAM stays +0.84%, so a
   // clock/core error can be at most ~0.17% - the other ~0.67% belongs to the
   // 037 CYCLE-STEALING model alone. In cycles: the control leg is 36 short
   // over 197 accesses, i.e. we steal ~0.18 cycles per access too FEW (1.31
   // against the real ~1.49). That is the next thing this method can calibrate,
   // and sim/smktime's control leg is already the instrument for it.
   //
   // N = 1 is a reply at the detection edge itself, which the wait FSM's wcnt
   // cannot count (see `ext_fast` in qbus_mem) AND which lands before the SDRAM
   // read would normally have been issued - so the MK_EXT read leg starts its
   // fetch at SYNC instead of at DIN (cpu_sdram_dp's fast_rd).
   // Changing this constant back to >= 2 is safe: both mechanisms are gated on
   // N_EXT == 1 and fold away. The wait FSM's 3-bit wcnt caps any N at 9.
   localparam int unsigned N_EXT = 1;

   // SMK512 memory-layout register 177130 (the floppy control register the SMK
   // "ab-uses"; BkEmu SmkMemoryManager). Write-only fixed reply count for the
   // qbus_mem positive-decode write path. PLACEHOLDER like N_EXT/N_VREG:
   // recalibrate reference-tb-first (the real register is board logic, not the
   // 037).
   localparam int unsigned N_SMKREG = N_ROM;

   // SMK512 IDE task file 0177740-0177756 (Phase-8 IDE increment; BkEmu
   // SmkIdeController is the reference). Eight word registers - DATA 177756,
   // ERROR/FEATURES 177754, SECTOR COUNT 177752, SECTOR NUMBER 177750,
   // CYL LOW 177746, CYL HIGH 177744, COMP_1 177742 (read {alt-status,
   // drive/head}, write-at-exact-742 = drive/head, byte 177743 = control
   // register), COMP_0 177740 (read {drive-addr, status}, write-at-exact-740
   // = command, byte 177741 ignored). ALL data is bit-inverted on the bus
   // (~ both directions - the active-low Q-bus convention); the backing
   // store holds TRUE data (raw AltPro image). The block sits INSIDE the
   // seg-7 extent / rom7 zone, so reads OR-merge with whatever the mapper
   // translation returns there, exactly as BkEmu Computer.readMemory ORs
   // memory and device reads; the device (sel_ide) owns the RPLY both
   // directions. Fixed reply count, N_ROM family per the I/O-page rule
   // (the 037's early start-vector-assist argument; see the N_ROM-not-N_EXT
   // comment in qbus_mem). PLACEHOLDER like N_SMKREG: recalibrate
   // reference-tb-first.
   localparam logic [15:0] SMK_IDE_BASE = 16'o177740;
   localparam int unsigned N_IDE = N_ROM;

   // 177662 write register (BK-0011M only; MiSTer rtl/video.sv is the
   // reference - BkEmu's handling is simplified). Fixed reply count for the
   // qbus_mem write-only reply path. PLACEHOLDER like N_EXT: recalibrate
   // reference-testbench-first with the 0011M cycle-accuracy item.
   localparam int unsigned N_VREG = N_ROM;

   // BK-0011M physical SDRAM layout (word addresses). The BK-0010 image
   // (RAM 0x0000-0x3FFF, ROM 0x4000-0x7F7F, FB0/FB1 up to 0x1FFFF) is
   // untouched; the 0011M banked space starts above the framebuffers.
   // Page/bank bases are power-of-two aligned so the mapper's physical
   // translation is pure concatenation - no adders.
   localparam logic [23:0] BK11_RAM_BASE    = 24'h020000; // 8 RAM pages x 0x2000
   localparam logic [23:0] BK11_WROM_BASE   = 24'h030000; // 4 window-1 ROM banks
   localparam logic [23:0] BK11_TOPROM_BASE = 24'h038000; // fixed 140000-177577 ROM
                                                          // (tops out at 0x39FBF)

   // Phase-8 SMK512 external RAM: 512 KB = 256 Kwords at 0x40000-0x7FFFF,
   // 2^18-aligned so the mapper's translation stays pure concatenation:
   //   phys = SMK_RAM_BASE | {abs_seg[6:0], addr[11:1]}
   // (128 segments x 2 Kwords; abs_seg = page[3:0]*8 + rel_seg[2:0]).
   localparam logic [23:0] SMK_RAM_BASE = 24'h040000;

   // Phase-8 SMK512 BIOS ROM: ONE 4 KB image (2048 words, appended to the
   // bk11 blob right after MSTD) backing BOTH selectable windows (rom6
   // @160000, rom7 @170000 - selection per SMK mode in mem_mapper). 2^11-
   // aligned so phys = SMK_BIOS_BASE | addr[11:1]. Reads reuse the fixed
   // N_ROM reply (placeholder family - recalibrate reference-tb-first).
   localparam logic [23:0] SMK_BIOS_BASE = 24'h03A000;

   // BK-0011M displayed-screen bases (177662 bit 15): screen 0 = RAM page 1,
   // screen 1 = RAM page 7 (BkEmu Computer wiring; MiSTer screen_bank).
   localparam logic [23:0] BK11_VPAGE0 = BK11_RAM_BASE + 24'h002000; // page 1
   localparam logic [23:0] BK11_VPAGE1 = BK11_RAM_BASE + 24'h00E000; // page 7

   // System start-up register: reading 177716 returns the start vector
   // (100000 = MONITOR on BK-0010, 140000 = BOS on BK-0011M), which steers
   // the 1801ВМ1 reset micro-sequence to that ROM vector.
   // Bits 15:8 are the startup address; bit 2 is the write-flag (set on any
   // write to the register, cleared after a read) - BkEmu semantics.
   // Read bit 6 = keyboard key-down (active low), read bit 5 = tape input
   // (the CMT comparator level). Write bit 6 = speaker/tape-out, write bit 7 =
   // tape motor relay (1 = stopped) - MONITOR tape-driver (d6.mac) semantics;
   // both write bits are software-owned latches captured in qbus_mem.
   localparam logic [15:0] REG_SYS   = 16'o177716;
   localparam logic [15:0] SYS_START = 16'o100000;
   // BK-0011M start vector = BOS in the fixed top ROM (BkEmu Computer.java:
   // 0100000 for BK_0010 models, 0140000 otherwise). Bit 15 still agrees with
   // the 037's AD15 start-vector assist; bit 14 is qbus_mem-only - the 037
   // drives AD14:10 Z during the 177716 read, so there is no bus fight.
   localparam logic [15:0] SYS_START11 = 16'o140000;

endpackage
