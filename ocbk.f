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
+incdir+src/bus
+incdir+src/sdram
+incdir+src/video
+incdir+src/peripheral
+incdir+src/audio
+incdir+src/sys

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

// --- SDRAM datapath (src/sdram) ---
src/sdram/sdram_ctrl.sv
src/sdram/sdram_arbiter.sv
src/sdram/cpu_sdram_dp.sv
src/sdram/epcs_boot.sv
src/sdram/ram_init.sv

// --- Q-bus front end (src/bus) ---
src/bus/va_037_sync.sv
src/bus/bk_rply.sv
src/bus/mem_mapper.sv
src/bus/qbus_mem.sv
src/bus/qbus_slot.sv

// --- peripherals (src/peripheral) ---
src/peripheral/smk_ide.sv
src/peripheral/sd_backend.sv
src/peripheral/ps2_rx.sv
src/peripheral/kbd_ps2bk.sv
src/peripheral/bk_kbd014.sv
src/peripheral/bk_evnt.sv

// --- audio subsystem (src/audio) ---
src/audio/audio_ns6.sv
src/audio/audio_mixer.sv
src/audio/audio_tone.sv
src/audio/audio_out.sv
src/audio/ym2149.sv
src/audio/bk_turbosound.sv
src/audio/bk_audio.sv

// --- video pipeline (src/video) ---
src/video/palette_apply.sv
src/video/fb_video.sv
src/video/fb_readout.sv
src/video/fb_linebuf.sv
src/video/vga_timing.sv
src/video/vga_out.sv

// --- clocking / CPU-rate control (src/sys) ---
src/sys/cpu_clkgen.sv
src/sys/turbo_ctl.sv

// --- top ---
src/ocbk_top.sv
