#!/usr/bin/env bash
#
# Turbosound oracles: 2x YM2149 on the 0177714 parallel port.
#
# TWO LEGS:
#   1  ym2149_equiv_tb     THE AUTHORITY. The vendored reference core
#                          (ym2149_ref.sv, upstream MiSTer) and the shipped
#                          Quartus-11 adaptation (src/audio/ym2149.sv) are
#                          elaborated side by side, driven with identical
#                          stimulus and diffed on CHANNEL_A/B/C, ACTIVE and DO
#                          EVERY clock. This is what makes the adaptation
#                          safe - it had to retype a 64-entry volume table,
#                          unroll a loop and hoist eight registers, none of
#                          which any other oracle in this tree can see.
#                          The reference wins every dispute. NEVER regenerate
#                          it from the shipped copy (the sim/ref014 rule).
#   2  bk_turbosound_tb    The device contract on the seam: the BkEmu Ay8910
#                          protocol (word = address, byte = data, inverted,
#                          the odd lane's 0xFF, the 4-bit latch mask), the
#                          0xFF/0xFE chip select, the shared register pointer,
#                          the ACB fold and its headroom bound, nINIT, the
#                          /56 PSG clock enable, and ts_snd (the Covox
#                          arbitration hook, which must LEAD the sample).
#
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt
#           idiom - no inline replica to drift) and requires the named leg to
#           break. 18 mutations: E1-E4 on the core, D1-D10 and D12-D15 on
#           the device.
#
# ONE THING IS DELIBERATELY NOT MUTATION-COVERED, and this says so out loud
# rather than quietly dropping the check (the sd_backend 0xFD/CMD12 precedent).
# The ADDRESS LATCH BROADCAST - bdir0 asserting for a word write even while the
# SECONDARY is selected - cannot be killed, because it is behaviourally
# REDUNDANT. The only route back to the primary is a 0xFF word write, and per
# BkEmu that write itself clobbers the register pointer (currentRegister =
# v & 0x0f runs BEFORE the chip-select check, so 0xFF leaves it at 15). The
# primary's pointer is therefore always rewritten on the way back in and is
# never observed stale. The broadcast stays in the RTL anyway: it is BkEmu's
# actual model - ONE shared currentRegister field, not one per chip - and the
# redundancy that makes it unobservable depends on 0xFF being the only way
# back, which is a fragile thing to rely on. Leg 2 section 6b pins the
# pointer clobber, which is the observable half of the same behaviour.
#
# NOTE ON COVERAGE OF THE VOLUME TABLE. During authoring, leg 1 was run
# against all 64 single-bit table mutations (flip the low bit of each entry in
# turn); all 64 were killed, so every entry is exercised. That sweep takes
# ~4 minutes and is not part of this script - the four representative
# mutations below stand in for it. Re-run the full sweep if the stimulus in
# ym2149_equiv_tb is ever reduced.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
AUD=$SRC/audio
YM=$AUD/ym2149.sv
TS=$AUD/bk_turbosound.sv
MODE="${1:-}"

# iverilog warns about the reference's block-local initialisers ("static
# variable initialization requires explicit lifetime") - benign, and those
# initialisers are load-bearing (see ym2149_ref.sv's header).
filter() { grep -viE 'sorry:|explicit lifetime' || true; }

build_equiv() {  # build_equiv <out> <our-ym2149>
   iverilog -g2012 -o "$1" -s ym2149_equiv_tb \
      ym2149_ref.sv "$2" ym2149_equiv_tb.v 2>&1 | filter
}
build_dev() {    # build_dev <out> <ym2149> <bk_turbosound>
   iverilog -g2012 -o "$1" -s bk_turbosound_tb \
      "$2" "$3" bk_turbosound_tb.v 2>&1 | filter
}

pass() { vvp -n "$1" | grep -q '^COSIM PASS$'; }

# ---- leg 1 ----------------------------------------------------------------
echo "=== leg 1: ym2149 equivalence vs the vendored reference ==="
build_equiv "$SP/equiv.vvp" "$YM"
vvp -n "$SP/equiv.vvp" | tee "$SP/equiv.log" | grep -E 'TS-ERROR|EQUIV:|COSIM' || true
grep -q '^COSIM PASS$' "$SP/equiv.log" || { echo "LEG 1 FAILED"; exit 1; }

# ---- leg 2 ----------------------------------------------------------------
echo "=== leg 2: bk_turbosound device contract ==="
build_dev "$SP/dev.vvp" "$YM" "$TS"
vvp -n "$SP/dev.vvp" | tee "$SP/dev.log" | grep -E 'TS-ERROR|TSDEV:|COSIM' || true
grep -q '^COSIM PASS$' "$SP/dev.log" || { echo "LEG 2 FAILED"; exit 1; }

if [ "$MODE" != "--mutate" ]; then
   echo "ALL TURBOSOUND ORACLES PASS"
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

mut_ym() {   # mut_ym <name> <sed-expr>   (leg 1 must break)
   patch "$YM" "$2"
   build_equiv "$SP/m.vvp" "$SP/m.sv"
   if pass "$SP/m.vvp"; then
      echo "  !!! SURVIVED (leg 1): $1"; mfail=$((mfail+1))
   else
      echo "  killed by leg 1: $1"
   fi
}

mut_ts() {   # mut_ts <name> <sed-expr>   (leg 2 must break)
   patch "$TS" "$2"
   build_dev "$SP/m.vvp" "$YM" "$SP/m.sv"
   if pass "$SP/m.vvp"; then
      echo "  !!! SURVIVED (leg 2): $1"; mfail=$((mfail+1))
   else
      echo "  killed by leg 2: $1"
   fi
}

# -- the vendored core: the transcription risks --
mut_ym "E1 volume table entry 27 off by one" \
   "s/6'd27: vol_lut = 8'h88;/6'd27: vol_lut = 8'h89;/"
mut_ym "E2 volume table AY8910 half, entry 50 (pins the MODE=1 coverage)" \
   "s/6'd50: vol_lut = 8'h41;/6'd50: vol_lut = 8'h40;/"
mut_ym "E3 unrolled tone arm 3 reads arm 2's period" \
   "s/tone_gen_cnt3 >= (tone_gen_freq3 - 1'd1)/tone_gen_cnt3 >= (tone_gen_freq2 - 1'd1)/"
mut_ym "E4 poly17 power-up initialiser dropped (core goes X forever)" \
   "s/reg \[16:0\] poly17 = 0;/reg [16:0] poly17;/"

# -- the device: the BkEmu protocol --
mut_ts "D1 word/byte sense inverted (address <-> data)" \
   "s/s_word <= port_word;/s_word <= ~port_word;/"
mut_ts "D2 odd byte uses the STALE low half instead of 0xFF" \
   "s/wdata = port_be\[0\] ? v : 8'hFF;/wdata = v;/"
mut_ts "D3 0xFE no longer activates Turbosound (FF\/FE confused)" \
   "s/end else if (v == 8'hFE \&\& DUAL_ENABLE) begin/end else if (v == 8'hFD \&\& DUAL_ENABLE) begin/"
mut_ts "D4 the single-chip 2*chip0 branch dropped" \
   "s/: {lc0, 1'b0};/: ({1'b0, lc0} + {1'b0, lc1});/"
mut_ts "D5 right fold takes channel A instead of C (ACB pan broken)" \
   "s/rc0 <= {1'b0, c0, 1'b0} + {2'b00, b0};/rc0 <= {1'b0, a0, 1'b0} + {2'b00, b0};/"
mut_ts "D6 centre channel B dropped from the left fold" \
   "s/lc0 <= {1'b0, a0, 1'b0} + {2'b00, b0};/lc0 <= {1'b0, a0, 1'b0};/"
mut_ts "D7 scale x16 instead of x15 (breaks the headroom bound)" \
   "s/wire \[14:0\] lscl = {lsum, 4'b0000} - {4'b0000, lsum};/wire [14:0] lscl = {lsum, 4'b0000};/"
mut_ts "D8 PSG clock rate wrong (\/55 not \/56)" \
   "s/parameter int CE_DIV = 56,/parameter int CE_DIV = 55,/"
mut_ts "D9 nINIT no longer resets the device" \
   "s/wire reset = ~rst_n | ~init_sync;/wire reset = ~rst_n;/"
mut_ts "D10 a DATA write is broadcast to both chips" \
   "s/wire bdir1 = s_wr \& (s_word |  s_sel);/wire bdir1 = s_wr;/"
mut_ts "D12 the 4-bit address mask dropped (silicon semantics, not BkEmu's)" \
   "s/s_di   <= port_word ? {4'b0000, v\[3:0\]} : wdata;/s_di   <= port_word ? v : wdata;/"
mut_ts "D13 ts_snd tied low (the Covox would never mute)" \
   "s/^    wire snd_now = .*/    wire snd_now = 1'b0;/"
mut_ts "D14 ts_snd taken one stage LATE (loses its lead over ts_l\/ts_r)" \
   "s/wire snd_now = (|a0) | (|b0) | (|c0)/wire snd_now = (|lc0) | (|rc0)/"
mut_ts "D15 the secondary's channels ignored in ts_snd (2-chip mute hole)" \
   "s/| (dual_act \& ((|a1)|(|b1)|(|c1)));/;/"

echo
if [ "$mfail" -ne 0 ]; then
   echo "MUTATION TESTING FAILED: $mfail mutation(s) survived"
   exit 1
fi
echo "ALL TURBOSOUND ORACLES PASS (18 mutations killed)"
