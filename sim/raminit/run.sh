#!/usr/bin/env bash
#
# ram_init unit oracle: the authentic DRAM power-on pattern filler
# (src/sdram/ram_init.sv). Checks the per-model address walk + range, the exact
# bkemu-QT К565РУ6/РУ5 word pattern (InitMemoryValues), the served-mask gap, the power-on /
# same-model / model-change trigger logic, and blank_pulse. See raminit_tb.sv.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
iverilog -g2012 -o "$SP/raminit.vvp" -s raminit_tb \
   $SRC/sdram/ram_init.sv raminit_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/raminit.vvp" | tee "$SP/out.txt" | grep -E "RAMINIT|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "ram_init oracle: FAIL" >&2; exit 1; }
echo "ram_init oracle: PASS"
