#!/usr/bin/env bash
#
# Phase-4 video pipeline regressions: unit tests + cosims accumulated as the
# pipeline grows (palette_apply -> fb_video -> readout -> full chain).
#
set -euo pipefail
cd "$(dirname "$0")"

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
      exit 1
   fi
}

SRC=../src
run_tb palette_tb $SRC/video/palette_apply.sv video/palette_tb.sv

run_tb fb_video_tb \
   $SRC/bus/va_037_sync.sv $SRC/video/palette_apply.sv $SRC/video/fb_video.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv video/fb_video_tb.sv

run_tb vga_out_tb \
   $SRC/video/vga_timing.sv $SRC/video/vga_out.sv $SRC/video/fb_linebuf.sv \
   $SRC/video/fb_readout.sv $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv video/vga_out_tb.sv

python3 video/gen_expected.py
run_tb video_pipe_tb \
   $SRC/bus/va_037_sync.sv $SRC/video/palette_apply.sv $SRC/video/fb_video.sv \
   $SRC/video/vga_timing.sv $SRC/video/vga_out.sv $SRC/video/fb_linebuf.sv \
   $SRC/video/fb_readout.sv $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv video/video_pipe_tb.sv
