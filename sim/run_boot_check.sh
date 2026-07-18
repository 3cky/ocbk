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
   ../src/qbus_pkg.sv ../src/va_037_sync.sv ../src/cpu_sdram_dp.sv \
   ../src/sdram_arbiter.sv ../src/sdram_ctrl.sv ../src/mem_mapper.sv ../src/qbus_mem.sv \
   ../src/bk_kbd014.sv ../src/smk_ide.sv ide/ide_disk_model.v \
   ../src/fb_video.sv ../src/palette_apply.sv ../src/fb_readout.sv \
   ../src/fb_linebuf.sv ../src/vga_out.sv ../src/vga_timing.sv \
   sdram_model.sv boot_check_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/boot.vvp" "$@" 2>/dev/null | tee "$SP/out.txt" | grep BOOTCHK || true

grep -q '^BOOTCHK: PASS$' "$SP/out.txt" || { echo "boot smoke cosim: FAIL" >&2; exit 1; }
echo "MONITOR boot smoke cosim: PASS (trace in sim/boot_trace.txt)"
