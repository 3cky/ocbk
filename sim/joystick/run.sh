#!/usr/bin/env bash
#
# Joystick oracle: the two MSX pads as the BK's 0177714 read word.
#
# ONE LEG:
#   1  bk_joystick_tb  The device contract: the power-on word before any clock
#                      edge (there is no reset - the sync chain's initial values
#                      are the only thing making 0177714 read 0), the MSX
#                      active-low -> BkEmu active-high inversion, the per-control
#                      walk of all twelve inputs onto their BK bits, the two
#                      ports landing in their own bytes, START/SELECT having no
#                      DE-9 source, and the synchroniser being exactly two deep.
#
# WHY ONE LEG AND NOT TWO. The BUS side is not this leg's job and saying so
# out loud is the sim/covox and sim/ts precedent. That a read of 0177714 returns
# this word, and that a DATIO(B) read half sees it while the write half still
# reaches the Covox/AY capture seam, are pinned by sim/audio's spk_capture_tb,
# which drives the REAL qbus_mem (its section 10, mutations Q6-Q9 in
# sim/run_audio.sh). The !sel2_n GATE - the half that keeps the word out of the
# SMK I/O-page overlay merge - needs a real SDRAM behind that overlay, which
# leg 2 there has no model for, so sim/smk owns it (its section 2 reads 177714,
# 177776 and 177716 against a non-zero joy_word). Device here, seam there.
#
# WHAT NOTHING TESTS, DELIBERATELY. The pads themselves - the weak pull-ups that
# make a released control read 1 and an unplugged connector read all-released,
# and the PCI_IO clamp - are .qsf I/O properties copied from esemsx3. They are a
# hardware bring-up item (empty-connector check first), not a simulable one.
#
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt
#           idiom - no inline replica to drift) and requires the leg to break.
#           15 mutations, J1-J15.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

JS=../../src/peripheral/bk_joystick.sv
MODE="${1:-}"

build() {   # build <out> <bk_joystick>
   iverilog -g2012 -o "$1" -s bk_joystick_tb "$2" bk_joystick_tb.v 2>&1 \
      | grep -v 'sorry:' || true
}

pass() { vvp -n "$1" | grep -q '^COSIM PASS$'; }

# ---- leg 1 ----------------------------------------------------------------
echo "=== leg 1: bk_joystick device contract ==="
build "$SP/dev.vvp" "$JS"
vvp -n "$SP/dev.vvp" | tee "$SP/dev.log" | grep -E 'JOY-ERROR|JOYDEV:|COSIM' || true
grep -q '^COSIM PASS$' "$SP/dev.log" || { echo "LEG 1 FAILED"; exit 1; }

if [ "$MODE" != "--mutate" ]; then
   echo "ALL JOYSTICK ORACLES PASS"
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
   patch "$JS" "$2"
   build "$SP/m.vvp" "$SP/m.sv"
   if pass "$SP/m.vvp"; then
      echo "  !!! SURVIVED: $1"; mfail=$((mfail+1))
   else
      echo "  killed: $1"
   fi
}

# -- the inversion (MSX active low -> BK active high) --
mut "J1 port A inversion dropped" \
   "s/wire \[5:0\] a = ~a_s1;/wire [5:0] a = a_s1;/"
mut "J2 port B inversion dropped" \
   "s/wire \[5:0\] b = ~b_s1;/wire [5:0] b = b_s1;/"

# -- the remap: MSX U,D,L,R is NOT the BK's U,R,D,L --
mut "J3 port A direction nibble passed through unmapped" \
   "s/a\[2\], a\[1\], a\[3\], a\[0\] };/a[3], a[2], a[1], a[0] };/"
mut "J4 port A LEFT and RIGHT swapped" \
   "s/a\[2\], a\[1\], a\[3\], a\[0\] };/a[3], a[1], a[2], a[0] };/"
mut "J5 port A UP and DOWN swapped" \
   "s/a\[2\], a\[1\], a\[3\], a\[0\] };/a[2], a[0], a[3], a[1] };/"
mut "J6 port A trigger A lands on START (bit 4) instead of A (bit 5)" \
   "s/{ 1'b0, a\[5\], a\[4\], 1'b0,/{ 1'b0, a[5], 1'b0, a[4],/"
mut "J7 port A trigger B lands on SELECT (bit 7) instead of B (bit 6)" \
   "s/{ 1'b0, a\[5\], a\[4\], 1'b0,/{ a[5], 1'b0, a[4], 1'b0,/"
mut "J8 port A triggers swapped" \
   "s/{ 1'b0, a\[5\], a\[4\], 1'b0,/{ 1'b0, a[4], a[5], 1'b0,/"
mut "J9 port B remap wrong while port A is right (asymmetry)" \
   "s/b\[2\], b\[1\], b\[3\], b\[0\] };/b[3], b[2], b[1], b[0] };/"
mut "J12 START and SELECT invented (tied 1) on port A" \
   "s/{ 1'b0, a\[5\], a\[4\], 1'b0,/{ 1'b1, a[5], a[4], 1'b1,/"

# -- the two bytes --
mut "J10 port B collapses onto port A (the high byte is a copy)" \
   "s/assign joy_word\[15:8\] = { 1'b0, b\[5\], b\[4\], 1'b0, b\[2\], b\[1\], b\[3\], b\[0\] };/assign joy_word[15:8] = joy_word[7:0];/"
mut "J11 the two ports swapped (port A reads pad B)" \
   "s/a_s0 <= pad_a_n;/a_s0 <= pad_b_n;/"

# -- the synchroniser and the power-on word --
mut "J13 the second sync stage dropped (one flop on an async pad)" \
   "s/a_s1 <= a_s0;/a_s1 <= pad_a_n;/"
mut "J14 joy_word taken combinationally from the pads" \
   "s/wire \[5:0\] a = ~a_s1;/wire [5:0] a = ~pad_a_n;/"
mut "J15 the declaration-time initial values dropped (power-on word is X)" \
   "s/logic \[5:0\] a_s0 = 6'b111111, a_s1 = 6'b111111;/logic [5:0] a_s0, a_s1;/"

echo
if [ "$mfail" -ne 0 ]; then
   echo "MUTATION TESTING FAILED: $mfail mutation(s) survived"
   exit 1
fi
echo "ALL JOYSTICK ORACLES PASS (15 mutations killed)"
