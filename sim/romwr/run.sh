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

SRC=../../src
CPU=$SRC/cpu
iverilog -g2012 -o "$SP/romwr.vvp" -s romwr_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv $SRC/sdram/cpu_sdram_dp.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv \
   $SRC/bus/qbus_mem.sv ../sdram_model.sv \
   romwr_tb.v 2>&1 | grep -v 'sorry:' || true

run_leg () {   # $1 = label, $2 = vvp plusargs
    vvp -n "$SP/romwr.vvp" $2 2>/dev/null | tee "$SP/out.txt" \
        | grep -E "ROMWR-ERROR|COSIM" || true
    grep -q '^COSIM PASS$' "$SP/out.txt" \
        || { echo "ROM-write-timeout oracle ($1): FAIL" >&2; exit 1; }
    echo "ROM-write-timeout oracle ($1): PASS"
}

run_leg "authentic /32" ""
# Phase-9 turbo leg: in turbo the SAME FSM replies for RAM and must still NOT
# reply for a ROM write.  The conditionless screen clear is the differential -
# it only ends because the march into ROM traps.
run_leg "turbo /16"     "+turbo"
