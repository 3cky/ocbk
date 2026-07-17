#!/usr/bin/env bash
#
# Phase-8 SMK512 segmented-RAM functional oracle (data-checking, NOT a timing
# golden): the gen_smk_test.py program walks the BkEmu SmkMemoryManager
# contract on the real SoC stack (vm1 + va_037_sync + qbus_mem with smk_en=1
# in BK-0011M mode + a DEEPENED sdram_model + port-2 contention) at the /24 =
# 4.03 MHz CPU rate, then a tb DCLO replay proves the SYS re-init + SMK RAM
# survival. See sim/smk/smk_soc_tb.v.
#
# MUTATION-TESTED (2026-07-17):
#   * qbus_mem `selected` without the sel_ext term -> FAIL (the first SMK
#     access bus-times-out -> fail park): the reply path is load-bearing;
#   * qbus_mem u_dp .sel_ram feed without the RO exclusion (sel_ext
#     unqualified) -> FAIL (the HLT10 seg-0 write LANDS in the SDRAM; the
#     post-trap value check catches it): RO writes are never issued;
#   * qbus_mem `selected` without the write-side ~m_smk_ro -> PASSES
#     (documented, deliberate): the RO write is then "selected" but its
#     datapath never issues (the u_dp RO feed), so mem_ready never rises and
#     the widened done-gate holds the FSM in S_WAIT without ever asserting
#     RPLY - the CPU qbto-traps identically. The ~m_smk_ro term is kept
#     anyway as the DIRECT statement of the contract (the exact mirror of
#     the `sel_rom & is_read` ROM-write rule), not an emergent property of
#     the late-SDRAM interlock; the smk_ro flag itself is pinned by the
#     mapper oracle's HLT10 checks.
#   * mem_mapper page-scatter swap / arm-edge commit / seg-7 cap drop /
#     lane-mask drop / mode-mask break -> the matching sections fail
#     (also pinned, faster, by sim/run_mapper.sh - see its header).
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../../mem && python3 gen_smk_test.py ../sim/smk ) > /dev/null

CPU=../../src/cpu
iverilog -g2012 -o "$SP/smk.vvp" -s smk_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/mem_mapper.sv \
   ../../src/qbus_mem.sv ../sdram_model.sv \
   smk_soc_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/smk.vvp" 2>/dev/null | tee "$SP/out.txt" | grep -E "SMK-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "SMK512 RAM oracle: FAIL" >&2; exit 1; }
echo "SMK512 RAM oracle: PASS"
