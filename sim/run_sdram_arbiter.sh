#!/usr/bin/env bash
#
# Unit cosim for the Phase-3 SDRAM arbiter (src/sdram/sdram_arbiter.sv) against the real
# sdram_ctrl + behavioural sdram_model: datapath (word/byte), read-return routing,
# fixed-priority ordering, and non-preemptive progress.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../src
iverilog -g2012 -o "$SP/arb.vvp" -s sdram_arbiter_tb \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   sdram_model.sv sdram_arbiter_tb.sv 2>&1 | grep -v 'sorry:' || true

OUT="$(vvp -n "$SP/arb.vvp" 2>/dev/null)"
echo "$OUT"

if echo "$OUT" | grep -q '^COSIM PASS'; then
   echo "sdram_arbiter cosim: PASS"
else
   echo "sdram_arbiter cosim: FAIL (see above)" >&2
   exit 1
fi
