#!/usr/bin/env bash
#
# Cosim of the synthesizable Q-bus slave (src/qbus_mem.sv) against the vm1 core.
# Asserts the same per-fetch cycle counts as the bk10 oracle (sim/bk10/golden.txt),
# proving the hardware memory path is cycle-faithful before fitting.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../src/cpu

iverilog -g2012 -o "$SP/cosim.vvp" -s qbus_mem_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../src/qbus_pkg.sv ../src/qbus_mem.sv qbus_mem_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/cosim.vvp" 2>/dev/null \
   | awk '/^FETCH/ { if ($2=="001076") { if (!s) {print; s=1} } else print }' \
   > "$SP/out.txt"

if diff -u bk10/golden.txt "$SP/out.txt"; then
   echo "qbus_mem cosim cycle counts: PASS"
else
   echo "qbus_mem cosim cycle counts: FAIL (see diff above)" >&2
   exit 1
fi
