#!/usr/bin/env bash
#
# Phase 3 reference-oracle regression: vm1 CPU + real va_037 + behavioural DRAM.
#
# Establishes the ground-truth per-instruction cycle counts WITH the 037 video
# cycle-stealing active (see ref037_tb.v). The reduced output (unique instruction
# prefix + the first few self-loop samples) is diffed against golden_037.txt.
# This is the reference that the retimed va_037_sync (Phase 3) must reproduce
# exactly; the delta vs sim/bk10/golden.txt is the with-/without-display overhead.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../../src/cpu
K037="."

iverilog -g2012 -o "$SP/ref037.vvp" -s ref037_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" "$K037/va_037.v" \
   ref037_tb.v 2>&1 | grep -v 'sorry:' || true

reduce() { awk '/^FETCH/ { if ($2=="001076") { c++; if (c<=4) print } else print }'; }

# Reduce: unique instruction prefix, then the first 4 self-loop samples.
vvp -n "$SP/ref037.vvp" 2>/dev/null | reduce > "$SP/out.txt"

if diff -u golden_037.txt "$SP/out.txt"; then
   echo "ref037 (reference va_037) cycle counts: PASS"
else
   echo "ref037 (reference va_037) cycle counts: FAIL (see diff above)" >&2
   exit 1
fi

# --- Equivalence: the retimed src/va_037_sync.sv must reproduce the same golden ---
iverilog -g2012 -o "$SP/ref037s.vvp" -s ref037_sync_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" ../../src/va_037_sync.sv \
   ref037_sync_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ref037s.vvp" 2>/dev/null | reduce > "$SP/out_sync.txt"

if diff -u golden_037.txt "$SP/out_sync.txt"; then
   echo "ref037 (retimed va_037_sync) equivalence: PASS"
else
   echo "ref037 (retimed va_037_sync) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- SoC integration: va_037_sync owns RAM RPLY, RAM in real SDRAM via the
#     arbiter + cpu_sdram_dp + done-gate, with the 037 fetch streaming contention.
#     Must still reproduce the golden (timing preserved) and run out of SDRAM. ---
iverilog -g2012 -o "$SP/ref037soc.vvp" -s ref037_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/va_037_sync.sv ../../src/cpu_sdram_dp.sv ../../src/sdram_arbiter.sv \
   ../../src/sdram_ctrl.sv ../sdram_model.sv \
   ref037_soc_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ref037soc.vvp" 2>/dev/null | reduce > "$SP/out_soc.txt"

if diff -u golden_037.txt "$SP/out_soc.txt"; then
   echo "ref037 (SoC integration: 037+arbiter+SDRAM+done-gate) equivalence: PASS"
else
   echo "ref037 (SoC integration) equivalence: FAIL (see diff above)" >&2
   exit 1
fi
