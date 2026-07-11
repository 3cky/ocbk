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

   // System start-up register: reading 177716 returns 100000 (boot from ROM),
   // which steers the 1801ВМ1 reset micro-sequence to the 100000 ROM vector.
   // Bits 15:8 are the startup address; bit 2 is the write-flag (set on any
   // write to the register, cleared after a read) - BkEmu semantics.
   // Read bit 6 = keyboard key-down (active low), read bit 5 = tape input
   // (the CMT comparator level). Write bit 6 = speaker/tape-out, write bit 7 =
   // tape motor relay (1 = stopped) - MONITOR tape-driver (d6.mac) semantics;
   // both write bits are software-owned latches captured in qbus_mem.
   localparam logic [15:0] REG_SYS   = 16'o177716;
   localparam logic [15:0] SYS_START = 16'o100000;

endpackage
