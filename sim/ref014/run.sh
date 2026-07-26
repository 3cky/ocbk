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

# --- Phase-6 interrupt-latency oracle (reference-first, per the repo
#     discipline): the gen_kbd_test.py program (VIRQ 060/0274 ISRs, masked
#     press, nIRQ1 fixed pulse -> HALT entry via the 160002 vector) runs on
#     (a) the REFERENCE stack - vm1 + real va_037 + behavioural memory + the
#     vp_014 GATE NETLIST with its matrix/RC debounce (this run is what
#     generated golden_kbd.txt - never regenerate it from the SoC run), and
#     (b) the SoC stack - vm1 + va_037_sync + qbus_mem + SDRAM model +
#     behavioral bk_kbd014. Both reduced FETCH traces must match the same
#     golden; this diff is what calibrated N_KBD/N_IAK (=1: the async chip
#     replies inside the same CPU cycle) and bk_kbd014's write fast path. ---
( cd ../../mem && python3 gen_kbd_test.py ../sim/ref014 ) > /dev/null

CPU=../../src/cpu
iverilog -g2012 -o "$SP/irqref.vvp" -s ref014_irq_ref_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../ref037/va_037.v lib_1801.v vp_014.v \
   ref014_irq_ref_tb.v 2>&1 | grep -v 'sorry:' || true

# reduce: keep everything, collapse the trailing 001004 park loop to 4 samples
reduce() { awk '/^FETCH/ { if ($2=="001004") { c++; if (c<=4) print } else { c=0; print } }'; }

vvp -n "$SP/irqref.vvp" 2>/dev/null | reduce > "$SP/out_irqref.txt"

if diff -u golden_kbd.txt "$SP/out_irqref.txt"; then
   echo "ref014 (interrupt latency, vp_014 netlist reference): PASS"
else
   echo "ref014 (interrupt latency, netlist reference): FAIL (see diff above)" >&2
   exit 1
fi

iverilog -g2012 -o "$SP/irqsoc.vvp" -s ref014_irq_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/bk_rply.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/mem_mapper.sv ../../src/qbus_mem.sv \
   ../../src/bk_kbd014.sv ../sdram_model.sv \
   ref014_irq_soc_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/irqsoc.vvp" 2>/dev/null | reduce > "$SP/out_irqsoc.txt"

if diff -u golden_kbd.txt "$SP/out_irqsoc.txt"; then
   echo "ref014 (interrupt latency, SoC integration) equivalence: PASS"
else
   echo "ref014 (interrupt latency, SoC integration) equivalence: FAIL (see diff above)" >&2
   exit 1
fi
