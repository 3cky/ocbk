#!/usr/bin/env bash
#
# Covox oracle: the 8-bit DAC on the 0177714 parallel port.
#
# ONE LEG:
#   1  bk_covox_tb   The device contract on the Phase-10 seam: the port
#                    inversion, BkEmu's byte -> sample map, the PER-LANE HOLD
#                    (the one place this device deliberately departs from
#                    BkEmu), the DIP-5 mono fold and its liveness, the PSG
#                    mute and its hold, the idle one-shot and its retrigger,
#                    nINIT, and the power-on state.
#
# WHY ONE LEG AND NOT TWO. bk_turbosound has the same shape and the same
# single leg: the SEAM itself - one strobe per bus write, the BK-true
# polarity, and the odd lane leaving the other half stale - is pinned
# independently by sim/audio's spk_capture_tb, which drives the REAL qbus_mem
# (mutations Q1-Q5 in sim/run_audio.sh). This leg models that behaviour in its
# write tasks and tests the DEVICE against it, which is the same division of
# labour Phase 11 used.
#
# WHAT THE MIXER SIDE OWNS, AND IS NOT TESTED HERE. bk_covox emits BkEmu's own
# +/-32767 scale; the headroom that keeps the mixer from saturating is one
# compile-time SLOT_GAIN nibble (5/8) in bk_audio. So the gain arithmetic, the
# pan (slot 5 = L, slot 6 = R) and the fact that cx_en actually zeroes the
# slot are all sim/run_audio.sh's job (leg 1 bk_audio_tb, mutations A3/A4/A5) -
# saying so out loud rather than half-testing it here.
#
# THE ONE-SHOT RATES ARE SPLIT BETWEEN TWO CHECKS, deliberately. 2^22 and 2^26
# sys_clk (43 ms and 694 ms) cannot be simulated, so the tb builds a second
# instance with the shipped defaults and asserts the PARAMETER VALUES, while
# all BEHAVIOUR - expiry, retrigger, hold - runs on a scaled instance whose
# measured periods are checked against its own overrides. A mutation of either
# the default or the counter logic dies; a mutation of both together would not,
# and that is the known limit of this leg.
#
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt
#           idiom - no inline replica to drift) and requires the leg to break.
#           13 mutations, X1-X13.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CX=../../src/audio/bk_covox.sv
MODE="${1:-}"

build() {   # build <out> <bk_covox>
   iverilog -g2012 -o "$1" -s bk_covox_tb "$2" bk_covox_tb.v 2>&1 \
      | grep -v 'sorry:' || true
}

pass() { vvp -n "$1" | grep -q '^COSIM PASS$'; }

# ---- leg 1 ----------------------------------------------------------------
echo "=== leg 1: bk_covox device contract ==="
build "$SP/dev.vvp" "$CX"
vvp -n "$SP/dev.vvp" | tee "$SP/dev.log" | grep -E 'CX-ERROR|CXDEV:|COSIM' || true
grep -q '^COSIM PASS$' "$SP/dev.log" || { echo "LEG 1 FAILED"; exit 1; }

if [ "$MODE" != "--mutate" ]; then
   echo "ALL COVOX ORACLES PASS"
   exit 0
fi

# ---- mutations ------------------------------------------------------------
echo
echo "=== mutation testing ==="
mfail=0

# patch <src> <sed-expr>  -> $SP/m.sv, and FAIL LOUDLY if the anchor moved.
patch() {
   sed "$2" "$1" > "$SP/m.sv"
   if cmp -s "$1" "$SP/m.sv"; then
      echo "MUTATION ANCHOR STALE: sed did not apply to $1"
      echo "  expr: $2"
      echo "  Fix the script rather than deleting the mutation."
      exit 1
   fi
}

mut() {   # mut <name> <sed-expr>
   patch "$CX" "$2"
   build "$SP/m.vvp" "$SP/m.sv"
   if pass "$SP/m.vvp"; then
      echo "  !!! SURVIVED: $1"; mfail=$((mfail+1))
   else
      echo "  killed: $1"
   fi
}

# -- the byte map --
mut "X1 the port inversion dropped on the left lane" \
   "s/wire \[7:0\] lb = ~port_data\[7:0\];/wire [7:0] lb = port_data[7:0];/"
mut "X2 the right lane taken from the LOW byte (stereo collapses silently)" \
   "s/mono ? lb : ~port_data\[15:8\];/mono ? lb : ~port_data[7:0];/"
mut "X3 the -32768 offset dropped (a full-scale DC on every sample)" \
   "s/samp_l = \$signed({~lb\[7\], lb\[6:0\], lb});/samp_l = \$signed({1'b0, lb[6:0], lb});/"
mut "X4 the low-byte replication dropped (BkEmu's map truncated to 8 bits)" \
   "s/samp_l = \$signed({~lb\[7\], lb\[6:0\], lb});/samp_l = \$signed({~lb[7], lb[6:0], 8'h00});/"

# -- mono / DIP 5 --
mut "X5 the mono fold inverted (left takes the right lane)" \
   "s/wire \[7:0\] lb = ~port_data\[7:0\];/wire [7:0] lb = mono ? ~port_data[15:8] : ~port_data[7:0];/"
mut "X6 DIP 5 ignored - always stereo" \
   "s/wire \[7:0\] rb = mono ? lb : ~port_data\[15:8\];/wire [7:0] rb = ~port_data[15:8];/"

# -- the arbitration --
mut "X7 the PSG mute dropped entirely" \
   "s/assign cx_en = (idle_cnt != 0) \& (psg_cnt == 0);/assign cx_en = (idle_cnt != 0);/"
mut "X8 the PSG mute has no hold (follows psg_act combinationally)" \
   "s/assign cx_en = (idle_cnt != 0) \& (psg_cnt == 0);/assign cx_en = (idle_cnt != 0) \& ~psg_act;/"
mut "X9 the idle one-shot dropped - the power-on latch reaches the ladders" \
   "s/assign cx_en = (idle_cnt != 0) \& (psg_cnt == 0);/assign cx_en = (psg_cnt == 0);/"
mut "X10 cx_en stuck asserted" \
   "s/assign cx_en = (idle_cnt != 0) \& (psg_cnt == 0);/assign cx_en = 1'b1;/"
mut "X11 the idle one-shot is not retriggerable (reloads only from idle)" \
   "s/else if (port_wr)       idle_cnt <= {IDLE_BITS{1'b1}};/else if (port_wr \&\& idle_cnt == 0) idle_cnt <= {IDLE_BITS{1'b1}};/"

# -- the shipped rates and the reset --
mut "X12 the shipped idle-one-shot default changed" \
   "s/parameter int IDLE_BITS = 22,/parameter int IDLE_BITS = 21,/"
mut "X13 nINIT no longer resets the device" \
   "s/wire reset = ~rst_n | ~init_sync;/wire reset = ~rst_n;/"

echo
if [ "$mfail" -ne 0 ]; then
   echo "MUTATION TESTING FAILED: $mfail mutation(s) survived"
   exit 1
fi
echo "ALL COVOX ORACLES PASS (13 mutations killed)"
