#!/usr/bin/env bash
#
# ROM-write-timeout functional oracle (Phase 7; data-checking, NOT a timing
# golden): the gen_romwr_test.py program proves a WRITE to ROM gets no bus
# reply -> the CPU's qbto timer -> trap 4 (authentic mask-ROM behaviour;
# BkEmu agrees). Runs on the real BK-0010 SoC stack (vm1 + va_037_sync +
# qbus_mem with mem_mapper pass-through + SDRAM model + port-2 contention).
# Two sub-tests: the conditionless "write until trap 4" screen-clear (DATO)
# and INC @#100000 (DATIO write-half timeout). See sim/romwr/romwr_tb.v.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../../mem && python3 gen_romwr_test.py ../sim/romwr ) > /dev/null

CPU=../../src/cpu
iverilog -g2012 -o "$SP/romwr.vvp" -s romwr_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/bk_rply.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/mem_mapper.sv \
   ../../src/qbus_mem.sv ../sdram_model.sv \
   romwr_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/romwr.vvp" 2>/dev/null | tee "$SP/out.txt" | grep -E "ROMWR-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "ROM-write-timeout oracle: FAIL" >&2; exit 1; }
echo "ROM-write-timeout oracle: PASS"
