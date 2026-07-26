#!/usr/bin/env bash
#
# Phase-5 MONITOR/BASIC boot smoke cosim - SLOW (~10+ min), manual, NOT in
# `make sim` (like sim/video/run_draw_check.sh). Cold-boots the real
# BK-0010.01 ROM set on the full SoC and checks:
#   * no X (bus contention) at any read-reply point;
#   * the MONITOR starts clearing the video RAM within the bound.
# Also dumps the first bus transactions to sim/boot_trace.txt for one-off
# manual diffing against a BkEmu-side trace when debugging.
#
# ./run_boot_check.sh +warmreset additionally re-pulses DCLO/ACLO (the reset
# button) mid-screen-clear and requires the MONITOR to warm-reboot: a second
# 177716 start-vector read + a second screen-clear burst, no X throughout
# (Phase-5.5 soft reset; roughly doubles the runtime).
#
# ./run_boot_check.sh +bk11 (Phase 7) cold-boots the real BK-0011M BOS
# instead: model_bk11=1, /24 CPU clock, the bk11 blob at SDRAM 0x30000+;
# requires the 140000 start-vector reply, a 177662 write and the screen
# clear, no X throughout (+warmreset is bk10-only, ignored here).
#
# ./run_boot_check.sh +smk (Phase 8) cold-boots the real SMK512 BIOS:
# +bk11 stack with smk_en=1, the BIOS image at SDRAM 0x3A000, and - since
# the IDE increment - the LIVE smk_ide + behavioral disk model (the
# gen_ide_image.py AltPro image) attached; requires the merged 166400
# start vector (the rom7 register-space overlay), the BIOS executing from
# the rom6 window, and the BIOS's own banner (its 177662 write + the
# video-RAM burst, after its ~150 ms startup delay - the +smk time bound
# is 400 ms), no X with the sel_ide decode active. The BIOS's DRIVE probe
# is deliberately not required: every boot path runs the multi-second
# EMT-0/БК memory test first (out of sim reach; see the tb header) - the
# drive-engine contract is pinned by sim/ide, and the real BIOS reading a
# real image is the increment-(b) hardware milestone.
#
# ./run_boot_check.sh +smk10 (the bk10+SMK increment) cold-boots the SAME
# real SMK BIOS on a BK-0010 stack (BkEmu BK_0010_SMK512): model_bk11=0, the
# /32 CPU rate, the bk10 ROM blob (its monitor ROM is what the SMK's mon_en
# selects at segs 0,1) plus the bk11 blob for the BIOS image at 0x3A000 -
# both are flash-resident on real hardware whatever DIP 1 says. Same pass
# conditions as +smk except the 177662 write, which on a BK-0010 must NOT
# reply: that bus timeout IS the BIOS's model detect (doc/smk64.mac START).
# The time bound is 550 ms (the BIOS's SOB startup delay at the /32 rate).
# +smk10 +sdspi works too (the sd_harness mux is model-agnostic).
#
# ./run_boot_check.sh +smk +sdspi (increment (b)) swaps the disk model for
# the REAL sd_backend + sd_model SPI stack (sim/ide/sd_harness.v): the
# attach-time sector-7 geometry read rides the full card init + SPI path
# under the real BIOS boot. Same pass conditions as +smk.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../mem && python3 gen_boot_blob.py )
python3 ../mem/gen_ide_image.py ide > /dev/null

CPU=../src/cpu
iverilog -g2012 -o "$SP/boot.vvp" -s boot_check_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../src/qbus_pkg.sv ../src/va_037_sync.sv ../src/bk_rply.sv ../src/cpu_sdram_dp.sv \
   ../src/sdram_arbiter.sv ../src/sdram_ctrl.sv ../src/mem_mapper.sv ../src/qbus_mem.sv ../src/bk_evnt.sv \
   ../src/bk_kbd014.sv ../src/smk_ide.sv ide/ide_disk_model.v \
   ../src/sd_backend.sv ide/sd_model.v ide/sd_harness.v \
   ../src/fb_video.sv ../src/palette_apply.sv ../src/fb_readout.sv \
   ../src/fb_linebuf.sv ../src/vga_out.sv ../src/vga_timing.sv \
   sdram_model.sv boot_check_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/boot.vvp" "$@" 2>/dev/null | tee "$SP/out.txt" | grep BOOTCHK || true

grep -q '^BOOTCHK: PASS$' "$SP/out.txt" || { echo "boot smoke cosim: FAIL" >&2; exit 1; }
echo "MONITOR boot smoke cosim: PASS (trace in sim/boot_trace.txt)"
