#!/usr/bin/env bash
#
# bk10 cycle-count regression for the vendored vm1 core.
#
# Runs the upstream BK-0010 timing testbench against the FF-register-file core
# configuration we ship (CONFIG_VM1_CORE_REG_USES_RAM=0), reduces the per-fetch
# output to its unique prefix plus one self-loop sample, and diffs against the
# checked-in golden reference. This is the authoritative per-instruction
# cycle-count oracle for the CPU.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../../src/cpu

iverilog -g2012 -o "$SP/bk10_tb.vvp" -s bk10_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   bk10_tb.v 2>&1 | grep -v 'sorry:' || true

# Reduce: print the unique prefix, then a single representative self-loop line.
vvp -n "$SP/bk10_tb.vvp" 2>/dev/null \
   | awk '/^FETCH/ { if ($2=="001076") { if (!s) {print; s=1} } else print }' \
   > "$SP/out.txt"

if diff -u golden.txt "$SP/out.txt"; then
   echo "bk10 cycle counts: PASS"
else
   echo "bk10 cycle counts: FAIL (see diff above)" >&2
   exit 1
fi
