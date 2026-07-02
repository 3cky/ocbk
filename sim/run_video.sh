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

run_tb palette_tb ../src/palette_apply.sv video/palette_tb.sv

run_tb fb_video_tb \
   ../src/va_037_sync.sv ../src/palette_apply.sv ../src/fb_video.sv \
   ../src/sdram_arbiter.sv ../src/sdram_ctrl.sv \
   sdram_model.sv video/fb_video_tb.sv
