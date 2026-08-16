#!/usr/bin/env bash
#
# Gamepad oracle: a USB HID pad as the BK's 0177714 read word.
#
# ONE LEG:
#   1  bk_gamepad_tb   The device contract: the power-on word before any clock
#                      edge (there is no reset - the sync chain's and the arming
#                      flop's initial values are the only thing making 0177714
#                      read 0), the typ==3 gate that keeps the pad and the mouse
#                      off each other's word, the arming flop that stops a
#                      re-plugged pad presenting the previous session's stale
#                      levels, the per-control walk of all ten host outputs onto
#                      their BK bits, X/Y joining A/B, the upper byte staying 0
#                      on every edge, whole-frame latching at the report pulse
#                      (this module's half of the board bug of 2026-08-16 - the
#                      other half, corrupt packets, is hook H7's CRC16 and lives
#                      in sim/usb's `crc` leg), and the synchroniser being
#                      exactly two deep on every edge.
#
# WHY ONE LEG AND NOT TWO. The report DECODE - which byte of a HID report
# carries which button - is not this leg's job. sim/usb owns it: its pad legs
# drive real low-speed USB traffic through the vendored usb_hid_host and check
# the ten game_* outputs, including the leg built from the captured frames of
# the reference pad (081f:e401). Everything upstream of this module's inputs is
# that oracle's contract; everything downstream of its output word is
# sim/audio's spk_capture_tb (section 10, the REAL qbus_mem) and sim/smk
# (section 2, the !sel2_n gate). Device here, decode there, seam elsewhere -
# the same division of labour as sim/joystick and sim/covox.
#
# THE MOUSE SIDE of the typ exclusion is asserted from the other end by
# sim/mouse's `gate` leg, which requires typ==3 to contribute nothing to
# mouse_word. Both directions are pinned, in the oracle that owns each module.
#
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt
#           idiom - no inline replica to drift) and requires the leg to break.
#           22 mutations, G1-G22.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

GP=../../src/peripheral/bk_gamepad.sv
MODE="${1:-}"

build() {   # build <out> <bk_gamepad>
   iverilog -g2012 -o "$1" -s bk_gamepad_tb "$2" bk_gamepad_tb.v 2>&1 \
      | grep -v 'sorry:' || true
}

pass() { vvp -n "$1" | grep -q '^COSIM PASS$'; }

# ---- leg 1 ----------------------------------------------------------------
echo "=== leg 1: bk_gamepad device contract ==="
build "$SP/dev.vvp" "$GP"
vvp -n "$SP/dev.vvp" | tee "$SP/dev.log" | grep -E 'PAD-ERROR|PADDEV:|COSIM' || true
grep -q '^COSIM PASS$' "$SP/dev.log" || { echo "LEG 1 FAILED"; exit 1; }

if [ "$MODE" != "--mutate" ]; then
   echo "ALL GAMEPAD ORACLES PASS"
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
   patch "$GP" "$2"
   build "$SP/m.vvp" "$SP/m.sv"
   if pass "$SP/m.vvp"; then
      echo "  !!! SURVIVED: $1"; mfail=$((mfail+1))
   else
      echo "  killed: $1"
   fi
}

# -- the type gate: the pad and the mouse must not share joy_word --
mut "G1 gate on typ==2, i.e. the pad claims the MOUSE's device type" \
   "s/hid_typ == 2'd3/hid_typ == 2'd2/"
mut "G2 type gate dropped (any device drives the pad word)" \
   "s/wire is_pad = (hid_typ == 2'd3);/wire is_pad = 1'b1;/"

# -- the arming flop and whole-frame latching --
mut "G3 never arms (the report never sets the flop)" \
   "s/            armed   <= 1'b1;/            armed   <= 1'b0;/"
mut "G4 never disarms - a re-plugged pad shows the stale levels" \
   "s/            pl_hold <= 8'h00; armed <= 1'b0;/            pl_hold <= pl_hold;/"
mut "G5 pad_active reports the raw type gate, not the armed state" \
   "s/act_sr <= {act_sr\[0\], armed};/act_sr <= {act_sr[0], is_pad};/"
mut "G6 the arming flop has no initial value (power-on word is X)" \
   "s/logic       armed   = 1'b0;/logic       armed;/"
# G7 IS THE BOARD-BUG REGRESSION for this module's half of it: sampling the
# levels instead of latching them at the pulse shows the BK half-decoded frames,
# and after hook H7 it is also what would let a corrupt frame's transient level
# outputs through - H7 gates the PULSE, not the decode.
mut "G7 the payload is sampled freely instead of latched at the report" \
   "s/        p_s0   <= pl_hold;/        p_s0   <= pl;/"
mut "G8 the payload latches on every clock, not on the report pulse" \
   "s/        end else if (hid_report) begin/        end else if (1'b1) begin/"

# -- the remap: the host's l/r/u/d is NOT the BK's U,R,D,L --
mut "G9 RIGHT and DOWN swapped" \
   "s/g_sta, g_l, g_d, g_r, g_u/g_sta, g_l, g_r, g_d, g_u/"
mut "G10 UP and LEFT swapped" \
   "s/g_sta, g_l, g_d, g_r, g_u/g_sta, g_u, g_d, g_r, g_l/"
mut "G11 LEFT and DOWN swapped" \
   "s/g_sta, g_l, g_d, g_r, g_u/g_sta, g_d, g_l, g_r, g_u/"
mut "G12 START and SELECT swapped" \
   "s/{ g_sel, (g_b | g_y | g_tl), (g_a | g_x | g_tr), g_sta,/{ g_sta, (g_b | g_y | g_tl), (g_a | g_x | g_tr), g_sel,/"
mut "G13 A and B swapped" \
   "s/(g_b | g_y | g_tl), (g_a | g_x | g_tr)/(g_a | g_x | g_tr), (g_b | g_y | g_tl)/"

# -- four face buttons onto two triggers --
mut "G14 X does not join A" \
   "s/(g_a | g_x | g_tr)/(g_x | g_tr)/"
mut "G15 Y does not join B" \
   "s/(g_b | g_y | g_tl)/(g_y | g_tl)/"
# -- the shoulder triggers (hook H9): R joins A, L joins B --
mut "G20 the R trigger does not reach A" \
   "s/(g_a | g_x | g_tr)/(g_a | g_x)/"
mut "G21 the L trigger does not reach B" \
   "s/(g_b | g_y | g_tl)/(g_b | g_y)/"
mut "G22 the two triggers swapped (L to A, R to B)" \
   "s/(g_b | g_y | g_tl), (g_a | g_x | g_tr)/(g_b | g_y | g_tr), (g_a | g_x | g_tl)/"

# -- the read word and the synchroniser --
mut "G16 the pad leaks into player 2's byte" \
   "s/assign pad_word    = {8'h00, p_s1};/assign pad_word    = {p_s1, p_s1};/"
mut "G17 only one sync stage (the output taken from the first flop)" \
   "s/assign pad_word    = {8'h00, p_s1};/assign pad_word    = {8'h00, p_s0};/"
mut "G18 the second sync stage re-samples the source (one flop on a CDC)" \
   "s/p_s1   <= p_s0;/p_s1   <= pl_hold;/"
mut "G19 the sync chain's initial values dropped (power-on word is X)" \
   "s/logic \[7:0\] p_s0 = 8'h00, p_s1 = 8'h00;/logic [7:0] p_s0, p_s1;/"

echo
if [ "$mfail" -ne 0 ]; then
   echo "MUTATION TESTING FAILED: $mfail mutation(s) survived"
   exit 1
fi
echo "ALL GAMEPAD ORACLES PASS (22 mutations killed)"
