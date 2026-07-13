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
   //   MK_EXT    : RESERVED for the Phase-8 SMK512 external RAM (its own
   //               controller -> a genuine fixed-latency FSM reply). No longer
   //               used by internal RAM - window 1 is MK_RAM037.
   //   MK_ROM    : FSM-owned RPLY, read-only (writes are replied to + ignored)
   localparam logic [1:0] MK_NONE   = 2'd0;
   localparam logic [1:0] MK_RAM037 = 2'd1;
   localparam logic [1:0] MK_EXT    = 2'd2;
   localparam logic [1:0] MK_ROM    = 2'd3;

   // MK_EXT fixed reply count. RESERVED for the Phase-8 SMK512 (its external
   // controller gives a genuine fixed latency); no longer used by internal RAM
   // (window 1 is 037-owned MK_RAM037 now). Recalibrate reference-tb-first when
   // the SMK512 lands; the wait FSM's 3-bit wcnt caps any N at 9.
   localparam int unsigned N_EXT = N_RAM;

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
