//
// vm1 core configuration for the ocbk (BK-0010 on EP1C12) project.
//
// Vendored seam over the upstream cpu11/vm1 core (1801BM1@gmail.com). Only the
// two core defparams are needed here; everything else in the upstream tbe/config.v
// is simulation-bench scaffolding that ocbk does not use.
//______________________________________________________________________________
//
// Each macro is guarded so this file is safe in either flow: the simulation
// command files include it directly, while the Quartus project sets the same
// values via global VERILOG_MACRO assignments (so the file is idempotent).

//
// Register file in a flip-flop array (not the Cyclone-III M9K megafunction).
// Validated cycle-identical to the RAM path against the bk10 timing testbench.
// vm1_reg_ram (-> vm1_vcram, from vm1_simlib.v) is still elaborated but its
// outputs are unused on this path and the synthesiser strips it.
//
`ifndef CONFIG_VM1_CORE_REG_USES_RAM
`define CONFIG_VM1_CORE_REG_USES_RAM   0
`endif

//
// Microcode revision A = 1801ВМ1А = BK-0010 (no VE-timer interrupt, no MUL).
//
`ifndef CONFIG_VM1_CORE_MULG_VERSION
`define CONFIG_VM1_CORE_MULG_VERSION   0
`endif
