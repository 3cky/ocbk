#!/usr/bin/env bash
#
# Phase-6 audio unit cosim: bk_audio (BK 1-bit speaker -> R-2R sound DAC).
# Drives spk_bit toggles and checks the balanced {lvl,Z,Z,Z,Z,lvl} DAC pattern
# on both channels + high-Z under reset (see sim/audio/bk_audio_tb.v).
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

# --- Leg 1: bk_audio DAC/CDC unit oracle ----------------------------------
iverilog -g2012 -o "$SP/audio.vvp" -s bk_audio_tb \
   ../src/bk_audio.sv audio/bk_audio_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/audio.vvp" | tee "$SP/out.txt" | grep -E "AUDIO-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "audio DAC unit cosim: FAIL" >&2; exit 1; }
echo "audio DAC unit cosim: PASS"

# --- Leg 2: 177716-bit-6 speaker capture in qbus_mem_sdram ------------------
iverilog -g2012 -o "$SP/spk.vvp" -s spk_capture_tb \
   ../src/qbus_pkg.sv ../src/sdram_ctrl.sv ../src/sdram_arbiter.sv \
   ../src/cpu_sdram_dp.sv ../src/qbus_mem_sdram.sv audio/spk_capture_tb.v \
   2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/spk.vvp" | tee "$SP/spk.txt" | grep -E "AUDIO-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/spk.txt" || { echo "speaker capture cosim: FAIL" >&2; exit 1; }
echo "speaker capture cosim: PASS"
