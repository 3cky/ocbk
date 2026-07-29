#!/usr/bin/env bash
#
# Phase-7 cpu_clkgen unit oracle: the model-selected CPU-clock divider vs a
# replica of the pre-Phase-7 divc[4] tap (BK-0010 mode must be bit-identical),
# the /24 BK-0011M rate, and glitch-free retargeting (see sim/clkgen_tb.v).
# This is the ONLY sim coverage of the real divider - the SoC testbenches all
# replicate the chain locally rather than instantiate ocbk_top.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../src
iverilog -g2012 -o "$SP/clkgen.vvp" -s clkgen_tb \
   $SRC/sys/cpu_clkgen.sv clkgen_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/clkgen.vvp" | tee "$SP/out.txt" | grep -E "CLKGEN-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "cpu_clkgen oracle: FAIL" >&2; exit 1; }
echo "cpu_clkgen oracle: PASS"
