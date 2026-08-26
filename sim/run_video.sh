#!/usr/bin/env bash
#
# Phase 4 video-pipeline oracles, each an independent stage of the same
# pipeline (palette_apply -> fb_video -> readout -> full chain), so all four
# run in parallel (sim/parlib.sh) and their transcripts are replayed in
# pipeline order. SIM_JOBS=1 gets the serial run back.
set -uo pipefail
cd "$(dirname "$0")"
. parlib.sh

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

run_tb () {
   local name="$1"; shift
   iverilog -g2012 -o "$SP/$name.vvp" -s "$name" "$@" 2>&1 | grep -v 'sorry:' || true
   local out
   out="$(vvp -n "$SP/$name.vvp" 2>/dev/null)"
   echo "$out"
   if echo "$out" | grep -q '^COSIM PASS'; then
      echo "$name: PASS"
   else
      echo "$name: FAIL (see above)" >&2
      return 1
   fi
}

SRC=../src

# video_pipe_tb reads the expected scan-out this generates, so it is produced
# before any leg starts.
python3 video/gen_expected.py

par_init

par_job palette run_tb palette_tb $SRC/video/palette_apply.sv video/palette_tb.sv

par_job fbvideo run_tb fb_video_tb \
   $SRC/bus/va_037_sync.sv $SRC/video/palette_apply.sv $SRC/video/fb_video.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv video/fb_video_tb.sv

par_job vgaout run_tb vga_out_tb \
   $SRC/video/vga_timing.sv $SRC/video/vga_out.sv $SRC/video/fb_linebuf.sv \
   $SRC/video/fb_readout.sv $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv video/vga_out_tb.sv

par_job pipe run_tb video_pipe_tb \
   $SRC/bus/va_037_sync.sv $SRC/video/palette_apply.sv $SRC/video/fb_video.sv \
   $SRC/video/vga_timing.sv $SRC/video/vga_out.sv $SRC/video/fb_linebuf.sv \
   $SRC/video/fb_readout.sv $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv video/video_pipe_tb.sv

par_wait
