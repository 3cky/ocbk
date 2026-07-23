#!/usr/bin/env bash
#
# ram_init unit oracle: the authentic DRAM power-on pattern filler
# (src/ram_init.sv). Checks the per-model address walk + range, the exact
# bkemu-QT К565РУ6/РУ5 word pattern (InitMemoryValues), the served-mask gap, the power-on /
# same-model / model-change trigger logic, and blank_pulse. Since Phase 8 it
# also covers the SECOND fill segment - the SMK512's 256 Kwords at 0x40000,
# ZERO-filled (no reference pattern exists; see the RTL header) on a power-on
# or a DIP-8 0->1 only: the segment sequence within one pass, the sticky
# smk_valid, and blank_pulse staying silent for an SMK-only fill.
# See raminit_tb.sv.
#
# Mutation-tested (each must drop COSIM PASS; all verified 2026-07-23):
#   1 the ~seg zero fold dropped from valb, i.e.
#     seg 1 patterned instead of zeroed          -> wdata compare @ 040000
#   2 need_smk drops the sticky smk_valid        -> "fill started with nothing needed"
#   3 LASTSMK off by one                         -> "pass ended mid-segment"
#   4 the seg_next gap fix-up dropped (w_addr+1
#     instead of jumping to BASESMK)             -> seg1 addr 030000 != 040000
#   5 the start address always the main base     -> seg1 addr 000000 != 040000
#   6 seg never advancing to 1 in the gap        -> wdata compare @ 040008
#   7 blank_pulse <= ram_valid (no need_main
#     term), i.e. blanking an SMK-only fill      -> blank_pulse compare
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -o "$SP/raminit.vvp" -s raminit_tb \
   ../../src/ram_init.sv raminit_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/raminit.vvp" | tee "$SP/out.txt" | grep -E "RAMINIT|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "ram_init oracle: FAIL" >&2; exit 1; }
echo "ram_init oracle: PASS"
