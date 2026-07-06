#!/usr/bin/env bash
#
# Phase-6 PS/2 front-end unit cosim: ps2_rx + kbd_ps2bk driven by a
# synthetic ~12 kHz PS/2 device; every translator event checked against a
# hand-written expected list (see sim/ps2_tb.sv).
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -o "$SP/ps2.vvp" -s ps2_tb \
   ../src/ps2_rx.sv ../src/kbd_ps2bk.sv ps2_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ps2.vvp" | tee "$SP/out.txt" | grep -E "PS2-ERROR|COSIM|events" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "ps2 front-end cosim: FAIL" >&2; exit 1; }
echo "ps2 front-end cosim: PASS"
