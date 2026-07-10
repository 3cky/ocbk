// ocbk.f — SystemVerilog filelist for the ocbk FPGA build.
//
// Consumed by the VS Code slang-server (mshr-h.veriloghdl) via .slang/server.json
// for cross-file navigation, and usable directly by verilator/slang for lint.
// This mirrors the synthesis source set in ocbk_common.qsf — keep the two in sync.
//
// The vendored vm1 (1801ВМ1) core is configured through global Verilog macros;
// Quartus passes them as VERILOG_MACRO, so we replicate the same two defaults here
// (src/cpu/vm1_config.v is the source of truth). Nothing `include`s that file, and
// slang keeps each file its own macro scope, so they must be global +define+.
+define+CONFIG_VM1_CORE_REG_USES_RAM=0
+define+CONFIG_VM1_CORE_MULG_VERSION=0

+incdir+src
+incdir+src/cpu

// --- package first ---
src/qbus_pkg.sv

// --- vendored vm1 core (src/cpu) ---
// NOTE: vm1_simlib.v is sim-only and defines the same vcram module as the synth
// stub below — include only the stub, matching CONFIG_VM1_CORE_REG_USES_RAM=0.
src/cpu/vm1.v
src/cpu/vm1_qbus.v
src/cpu/vm1_vcram_syn.v
src/cpu/vm1_plm.v
src/cpu/vm1_tve.v

// --- SoC / peripherals (src) ---
src/sdram_ctrl.sv
src/sdram_arbiter.sv
src/va_037_sync.sv
src/cpu_sdram_dp.sv
src/qbus_mem_sdram.sv
src/ps2_rx.sv
src/kbd_ps2bk.sv
src/bk_kbd014.sv
src/epcs_boot.sv
src/qbus_slot.sv
src/palette_apply.sv
src/fb_video.sv
src/fb_readout.sv
src/fb_linebuf.sv
src/vga_timing.sv
src/vga_out.sv
src/bk_audio.sv
src/ocbk_top.sv
