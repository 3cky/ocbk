#!/usr/bin/env bash
#
# Phase-7 BK-0011M banking functional oracle (data-checking, NOT a timing
# golden): the gen_bk11_test.py program runs the full Bk11MemoryManager
# contract on the real SoC stack (vm1 + va_037_sync + qbus_mem with
# mem_mapper in BK-0011M mode + SDRAM model + port-2 contention) at the
# /24 = 4.03 MHz CPU rate. See sim/bk11/bk11_soc_tb.v.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../../mem && python3 gen_bk11_test.py ../sim/bk11 ) > /dev/null

CPU=../../src/cpu
iverilog -g2012 -o "$SP/bk11.vvp" -s bk11_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/bk_rply.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/mem_mapper.sv \
   ../../src/qbus_mem.sv ../../src/bk_evnt.sv ../../src/turbo_ctl.sv \
   ../sdram_model.sv \
   bk11_soc_tb.v 2>&1 | grep -v 'sorry:' || true

run_leg () {   # $1 = label, $2 = vvp plusargs
    vvp -n "$SP/bk11.vvp" $2 2>/dev/null | tee "$SP/out.txt" \
        | grep -E "BK11-ERROR|COSIM" || true
    grep -q '^COSIM PASS$' "$SP/out.txt" \
        || { echo "bk11 banking oracle ($1): FAIL" >&2; exit 1; }
    echo "bk11 banking oracle ($1): PASS"
}

run_leg "authentic /24"  ""
# Phase-9 turbo legs: the SAME contract at /16 with the 037 out of the RAM path
# (qbus_mem replies at N_TURBO). Nothing about the contract may change - only
# the timing - so a diff here means the reply-owner switch is wrong, not slow.
# The second leg toggles F12 THROUGHOUT the run: it is the only leg that can
# kill a mutation of turbo_ctl's bus-idle qualification (an unqualified swap
# drops a reply mid-cycle -> qbto -> trap 4 -> the vector-4 fail park).
run_leg "turbo /16"      "+turbo"
run_leg "turbo live-flip" "+turboflip"
