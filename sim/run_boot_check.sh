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
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../mem && python3 gen_boot_blob.py )

CPU=../src/cpu
iverilog -g2012 -o "$SP/boot.vvp" -s boot_check_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../src/qbus_pkg.sv ../src/va_037_sync.sv ../src/cpu_sdram_dp.sv \
   ../src/sdram_arbiter.sv ../src/sdram_ctrl.sv ../src/qbus_mem_sdram.sv \
   ../src/fb_video.sv ../src/palette_apply.sv ../src/fb_readout.sv \
   ../src/fb_linebuf.sv ../src/vga_out.sv ../src/vga_timing.sv \
   sdram_model.sv boot_check_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/boot.vvp" "$@" 2>/dev/null | tee "$SP/out.txt" | grep BOOTCHK || true

grep -q '^BOOTCHK: PASS$' "$SP/out.txt" || { echo "boot smoke cosim: FAIL" >&2; exit 1; }
echo "MONITOR boot smoke cosim: PASS (trace in sim/boot_trace.txt)"
