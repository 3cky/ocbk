#!/usr/bin/env bash
#
# Phase-2 cosim: the synthesizable RAM-in-SDRAM datapath (src/qbus_sdram.sv +
# src/sdram_ctrl.sv) against the vm1 core and a behavioural SDRAM model, running
# the ROM-resident RAM-test program. Proves the datapath is correct and the RAM
# RPLY latency is deterministic (SDRAM hidden) before fitting.
#
set -euo pipefail
cd "$(dirname "$0")"

# ensure the ROM image exists (single source of truth = mem/gen_mem.py)
( cd ../mem && python3 gen_mem.py ram_test.hex >/dev/null )

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../src/cpu

iverilog -g2012 -o "$SP/cosim.vvp" -s qbus_sdram_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../src/qbus_pkg.sv ../src/sdram_ctrl.sv ../src/qbus_sdram.sv \
   sdram_model.sv qbus_sdram_tb.sv 2>&1 | grep -v 'sorry:' || true

OUT="$(vvp -n "$SP/cosim.vvp" 2>/dev/null)"
echo "$OUT"

if echo "$OUT" | grep -q '^COSIM PASS'; then
   echo "qbus_sdram cosim: PASS"
else
   echo "qbus_sdram cosim: FAIL (see above)" >&2
   exit 1
fi
