#!/usr/bin/env bash
#
# Phase-9 EVNT/IRQ2 oracle: the authentic BK-0011M frame-interrupt detector
# (src/bk_evnt.sv) - a gate-faithful replica of the motherboard's D28 (K555IE5)
# + D3:B (K555TM2) missing-pulse pair, driven by the 037's WTI and SYNCO pins.
#
# CONTRACT (the sim/ref014 shape): the vendored REFERENCE netlist
# sim/ref037/va_037.v is the timing authority. golden_evnt.txt is generated
# from the reference run ONLY; the retimed src/va_037_sync.sv must then
# reproduce it line-for-line. Never regenerate the golden from a va_037_sync
# run, and never regenerate it to "fix" a detector change.
#
# Legs (all three in one transcript, see evnt_tb.v):
#   L1  full screen (177664 bit 9 set): assert = VGATE rise + 452 CLKIN,
#       deassert = VGATE fall + 452 CLKIN. That 452 CLKIN (~75 us, ~1.18
#       scanlines, ~301 cpu_clk at the /24 rate) is the whole point of the
#       Phase-9 change - the pre-Phase-9 "nIRQ2 = vgate" model fired that much
#       too early, displacing every beam-raced multicolor/gigascreen effect.
#   L2  1/4 screen (bit 9 clear): WTI stops after the 64th displayed line, so
#       the request asserts during ACTIVE video, ~129 lines before the VGATE
#       rise. The old vgate model could not express this at all.
#   L3  mask semantics: masking clears the request immediately (it is D3:B's
#       async R pin, not a combinational gate); UNMASKING mid-blanking must NOT
#       retro-fire - it waits for the next SYNCO edge. Both we and MiSTer used
#       to retro-fire instantly.
#
# MUTATIONS (--mutate): each rewrites one property of a COPY of src/bk_evnt.sv
# and must break the diff. They pin, in order:
#   1  the propagation race - D3:B must capture the OLD qa (the same SYNCO edge
#      toggles qa); sampling the new value shortens the delay by a whole line
#   2  the WTI clear - without it qa never re-arms and the level never tracks
#   3  the D3:B clock edge (rising SYNCO, not falling)
#   4  irq_en as an async clear, not a combinational gate (the L3 retro-fire)
#   5  the QA feedback into CKA - without it qa is not set-once and toggles on
#      every SYNCO edge through blanking
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
REF=../ref037

build() {   # build <outfile> <bk_evnt source> [extra defines]
   local out="$1" evnt="$2"; shift 2
   iverilog -g2012 -o "$out.ref.vvp" -s evnt_tb -DREF037 "$@" \
      "$evnt" "$REF/va_037.v" evnt_tb.v 2>&1 | grep -v 'sorry:' || true
   iverilog -g2012 -o "$out.syn.vvp" -s evnt_tb "$@" \
      "$evnt" "$SRC/va_037_sync.sv" "$SRC/qbus_pkg.sv" evnt_tb.v 2>&1 \
      | grep -v 'sorry:' || true
}

# Only the labelled legs go into the golden: the settling frames and the
# inter-leg 177664 writes are tb sequencing, not contract.
run() { vvp -n "$1" 2>/dev/null | grep -E '^EVNT L[0-9]' ; }

# ---- regenerate the golden from the REFERENCE netlist ---------------------
if [ "${1:-}" = "--regen" ]; then
   build "$SP/g" "$SRC/bk_evnt.sv"
   run "$SP/g.ref.vvp" > golden_evnt.txt
   echo "golden_evnt.txt regenerated from the REFERENCE netlist:"
   wc -l < golden_evnt.txt
   exit 0
fi

build "$SP/e" "$SRC/bk_evnt.sv"

# ---- leg A: reference netlist vs golden -----------------------------------
run "$SP/e.ref.vvp" > "$SP/ref.txt"
if ! diff -u golden_evnt.txt "$SP/ref.txt"; then
   echo "evnt (reference va_037): FAIL (see diff above)" >&2; exit 1
fi
echo "evnt (reference va_037) transcript: PASS"

# ---- leg B: the retimed va_037_sync must match the same golden ------------
run "$SP/e.syn.vvp" > "$SP/syn.txt"
if ! diff -u golden_evnt.txt "$SP/syn.txt"; then
   echo "evnt (retimed va_037_sync): FAIL (see diff above)" >&2; exit 1
fi
echo "evnt (retimed va_037_sync) transcript: PASS"

# ---- mutations -------------------------------------------------------------
if [ "${1:-}" = "--mutate" ]; then
   mutate() {   # mutate <n> <sed script>
      local n="$1" script="$2"
      sed "$script" "$SRC/bk_evnt.sv" > "$SP/mut$n.sv"
      if cmp -s "$SP/mut$n.sv" "$SRC/bk_evnt.sv"; then
         echo "MUT$n: sed did not apply - the RTL moved, fix the script" >&2
         exit 1
      fi
      build "$SP/m$n" "$SP/mut$n.sv"
      if run "$SP/m$n.ref.vvp" | diff -q golden_evnt.txt - >/dev/null 2>&1; then
         echo "MUT$n: NOT KILLED (golden still matches)" >&2; exit 1
      fi
      echo "MUT$n: killed"
   }

   # 1: D3:B captures the NEW qa - the propagation race removed
   mutate 1 's|else if (!synco_d \&\& synco)     evnt <= qa;|else if (!synco_d \&\& synco)     evnt <= (!wti \&\& cka_d \&\& !cka) ? ~qa : qa;|'
   # 2: the WTI clear removed
   mutate 2 's|if (wti)                        qa <= 1.b0;|if (1'"'"'b0)                      qa <= 1'"'"'b0;|'
   # 3: D3:B clocked on the SYNCO falling edge
   mutate 3 's|else if (!synco_d \&\& synco)     evnt <= qa;|else if (synco_d \&\& !synco)     evnt <= qa;|'
   # 4: irq_en as a combinational gate instead of the async clear
   mutate 4 's|if (!irq_en)                    evnt <= 1.b0;|if (1'"'"'b0)                      evnt <= 1'"'"'b0;|'
   # 5: the QA feedback into CKA dropped (qa no longer set-once)
   mutate 5 's|wire  cka = ~(synco \| qa);|wire  cka = ~synco;|'

   echo "evnt mutations: all killed"
fi
