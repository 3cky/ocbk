#!/usr/bin/env bash
#
# Phase 6 keyboard-controller contract oracle: the vendored 1801VP1-014 gate
# netlist (vp_014.v + lib_1801.v) is driven through the shared scenario
# (ref014_scenario.v) and its transaction-granular log is diffed against the
# committed golden_014.txt. The synthesizable src/bk_kbd014.sv must reproduce
# the SAME golden through ref014_beh_tb.v (added in the next step).
#
# golden_014.txt is generated ONLY from the netlist run -- never from the
# behavioral module. Netlist wins all disputes (see README.md for the pinned
# contract).
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -I . -o "$SP/ref014.vvp" -s ref014_tb \
   lib_1801.v vp_014.v ref014_tb.v

vvp -n "$SP/ref014.vvp" | grep -v '\$finish called' > "$SP/out.txt"

if diff -u golden_014.txt "$SP/out.txt"; then
   echo "ref014 (vp_014 netlist contract): PASS"
else
   echo "ref014 (vp_014 netlist contract): FAIL (see diff above)" >&2
   exit 1
fi

# --- Equivalence: the behavioral src/bk_kbd014.sv must reproduce the same
#     golden through the same scenario (translator-side key events instead
#     of the matrix; 16-bit shared Q-bus; nBS-window decode). ---
iverilog -g2012 -I . -o "$SP/beh014.vvp" -s ref014_beh_tb \
   ../../src/qbus_pkg.sv ../../src/bk_kbd014.sv \
   ref014_beh_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/beh014.vvp" | grep -v '\$finish called' > "$SP/out_beh.txt"

if diff -u golden_014.txt "$SP/out_beh.txt"; then
   echo "ref014 (behavioral bk_kbd014) equivalence: PASS"
else
   echo "ref014 (behavioral bk_kbd014) equivalence: FAIL (see diff above)" >&2
   exit 1
fi
