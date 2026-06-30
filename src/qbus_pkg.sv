// qbus_pkg - shared Q-bus constants for the ocbk BK-0010 core.
//
// The Q-bus itself is carried as plain tri-state wires shared at the parent
// (cpu_test) level - every participant (the vm1 core, the qbus_mem slave, and
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

   // System start-up register: reading 177716 returns 100000 (boot from ROM),
   // which steers the 1801ВМ1 reset micro-sequence to the 100000 ROM vector.
   localparam logic [15:0] REG_SYS   = 16'o177716;
   localparam logic [15:0] SYS_START = 16'o100000;

endpackage
