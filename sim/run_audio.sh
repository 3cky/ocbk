#!/usr/bin/env bash
#
# Audio subsystem oracles: the BK speaker + the self-test tone -> mixer ->
# noise-shaped 6-bit DAC -> the board's two R-2R sound ladders, plus the CMT
# (cassette) jack and the 177714 parallel-port capture that the future sound
# devices will hang off.
#
# FOUR LEGS:
#   1  bk_audio_tb     the SUBSYSTEM: the speaker's static rails (the hardware-
#                      confirmed behaviour this rework must not regress), the CMT
#                      oe split / comparator network / anti-echo force / raw
#                      tape-out, true stereo, the CMT mono fold, tone routing,
#                      the 6 dB staircase, DAC-tick discipline at the pads, and
#                      the device slot maps - the TurboSound and Covox pan
#                      orientations, the Covox 5/8 gain and its mute enable,
#                      and the re-opened gain budget.
#   2  spk_capture_tb  directed Q-bus cycles into the REAL qbus_mem: the
#                      177716 bit-6/7 speaker+motor captures, the 177716 read
#                      assembly, and the 177714 (nSEL2) port-write capture.
#   3  audio_ns6_tb    THE RESOLUTION ORACLE. The DC identity that proves the
#                      6-bit code stream carries a value to <1/1000 of a ladder
#                      step, exact silence, the clamp, and - the sharpest single
#                      check in the audio work - a signal of HALF ONE LADDER
#                      STEP reconstructed to ~1% of a code, which a plain 6-bit
#                      truncating path renders as silence or a 1-bit square.
#   4  audio_mixer_tb  slots, compile-time gain/pan, runtime enable, saturation
#                      (never wrapping), exact latency, the NSRC=1 pass-through
#                      invariant and the planned NSRC=10 shape.
#
# --long    raises leg 3's DC sweep from 4096 to 65536 ticks per input. The
#           assertion is an identity so its bound does not loosen at the default;
#           --long only tightens the relative demonstration.
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt idiom -
#           no inline replica to drift) and requires the oracle to break. Each
#           mutation names the leg that must catch it. 28 mutations: N1-N7 on
#           the shaper, M1-M7 on the mixer, O1-O4 on the output stage, A1-A5
#           on bk_audio's slot map and Q1-Q5 on the qbus_mem capture seam.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../src
AUD=$SRC/audio
MODE="${1:-}"

DCTICKS=""
[ "$MODE" = "--long" ] && DCTICKS="+dcticks=65536"

# ---- leg builders ---------------------------------------------------------
# Each takes the audio source directory to use, so a mutation can point at a
# patched copy of one file while the rest come from the tree.
build_sub() {   # build_sub <out> <ns6> <mixer> <tone> <out.sv> <bk_audio>
   iverilog -g2012 -o "$1" -s bk_audio_tb \
      "$2" "$3" "$4" "$5" "$6" audio/bk_audio_tb.v 2>&1 | grep -v 'sorry:' || true
}
build_ns6() {   # build_ns6 <out> <ns6>
   iverilog -g2012 -o "$1" -s audio_ns6_tb \
      "$2" audio/audio_ns6_tb.v 2>&1 | grep -v 'sorry:' || true
}
build_mix() {   # build_mix <out> <mixer>
   iverilog -g2012 -o "$1" -s audio_mixer_tb \
      "$2" audio/audio_mixer_tb.v 2>&1 | grep -v 'sorry:' || true
}

pass() {   # pass <vvp> [plusargs...]  -> 0 if the leg passed
   local v="$1"; shift
   vvp -n "$v" "$@" 2>/dev/null | grep -q '^COSIM PASS$'
}

N6=$AUD/audio_ns6.sv
MX=$AUD/audio_mixer.sv
TN=$AUD/audio_tone.sv
OT=$AUD/audio_out.sv
BA=$AUD/bk_audio.sv

# --- Leg 1: the audio subsystem -------------------------------------------
build_sub "$SP/sub.vvp" "$N6" "$MX" "$TN" "$OT" "$BA"
vvp -n "$SP/sub.vvp" | tee "$SP/sub.txt" | grep -E "AUDIO-ERROR|COSIM|staircase" || true
grep -q '^COSIM PASS$' "$SP/sub.txt" || { echo "audio subsystem cosim: FAIL" >&2; exit 1; }
echo "audio subsystem cosim: PASS"

# --- Leg 2: 177716 speaker/motor + 177714 port capture in qbus_mem --------
iverilog -g2012 -o "$SP/spk.vvp" -s spk_capture_tb \
   $SRC/qbus_pkg.sv $SRC/sdram/sdram_ctrl.sv $SRC/sdram/sdram_arbiter.sv \
   $SRC/sdram/cpu_sdram_dp.sv $SRC/bus/mem_mapper.sv $SRC/bus/qbus_mem.sv audio/spk_capture_tb.v \
   2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/spk.vvp" | tee "$SP/spk.txt" | grep -E "AUDIO-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/spk.txt" || { echo "speaker/port capture cosim: FAIL" >&2; exit 1; }
echo "speaker/port capture cosim: PASS"

# --- Leg 3: the resolution oracle -----------------------------------------
build_ns6 "$SP/ns6.vvp" "$N6"
# shellcheck disable=SC2086
vvp -n "$SP/ns6.vvp" $DCTICKS | tee "$SP/ns6.txt" | grep -E "AUDIO-ERROR|COSIM|^L[0-9]|^L4" || true
grep -q '^COSIM PASS$' "$SP/ns6.txt" || { echo "DAC resolution cosim: FAIL" >&2; exit 1; }
echo "DAC resolution cosim: PASS"

# --- Leg 4: the mixer ------------------------------------------------------
build_mix "$SP/mix.vvp" "$MX"
vvp -n "$SP/mix.vvp" | tee "$SP/mix.txt" | grep -E "AUDIO-ERROR|COSIM" || true
grep -q '^COSIM PASS$' "$SP/mix.txt" || { echo "audio mixer cosim: FAIL" >&2; exit 1; }
echo "audio mixer cosim: PASS"

# ---- mutations ------------------------------------------------------------
if [ "$MODE" = "--mutate" ]; then
   patch() {   # patch <src> <dst> <sed script>   (fails loudly if it no-ops)
      sed "$3" "$1" > "$2"
      if cmp -s "$2" "$1"; then
         echo "MUTATION ANCHOR STALE: sed did not apply to $1 - the RTL moved," >&2
         echo "  fix the script rather than deleting the mutation." >&2
         exit 1
      fi
   }
   mut_ns6() {   # mut_ns6 <tag> <sed>
      patch "$N6" "$SP/m.sv" "$2"
      build_ns6 "$SP/m.vvp" "$SP/m.sv"
      if pass "$SP/m.vvp"; then echo "MUT $1: NOT KILLED" >&2; exit 1; fi
      echo "MUT $1: killed (leg 3)"
   }
   mut_mix() {   # mut_mix <tag> <sed>
      patch "$MX" "$SP/m.sv" "$2"
      build_mix "$SP/m.vvp" "$SP/m.sv"
      if pass "$SP/m.vvp"; then echo "MUT $1: NOT KILLED" >&2; exit 1; fi
      echo "MUT $1: killed (leg 4)"
   }
   mut_out() {   # mut_out <tag> <sed>
      patch "$OT" "$SP/m.sv" "$2"
      build_sub "$SP/m.vvp" "$N6" "$MX" "$TN" "$SP/m.sv" "$BA"
      if pass "$SP/m.vvp"; then echo "MUT $1: NOT KILLED" >&2; exit 1; fi
      echo "MUT $1: killed (leg 1)"
   }
   mut_aud() {   # mut_aud <tag> <sed>   (patches bk_audio, runs leg 1)
      patch "$BA" "$SP/m.sv" "$2"
      build_sub "$SP/m.vvp" "$N6" "$MX" "$TN" "$OT" "$SP/m.sv"
      if pass "$SP/m.vvp"; then echo "MUT $1: NOT KILLED" >&2; exit 1; fi
      echo "MUT $1: killed (leg 1)"
   }
   mut_mem() {   # mut_mem <tag> <sed>   (patches qbus_mem, runs leg 2)
      patch "$SRC/bus/qbus_mem.sv" "$SP/m.sv" "$2"
      iverilog -g2012 -o "$SP/m.vvp" -s spk_capture_tb \
         $SRC/qbus_pkg.sv $SRC/sdram/sdram_ctrl.sv $SRC/sdram/sdram_arbiter.sv \
         $SRC/sdram/cpu_sdram_dp.sv $SRC/bus/mem_mapper.sv "$SP/m.sv" \
         audio/spk_capture_tb.v 2>&1 | grep -v 'sorry:' || true
      if pass "$SP/m.vvp"; then echo "MUT $1: NOT KILLED" >&2; exit 1; fi
      echo "MUT $1: killed (leg 2)"
   }

   # ---- audio_ns6: the resolution claim itself ---------------------------
   # N1 the error feedback - without it this is plain truncation
   mut_ns6 N1 's|= s_in + $signed({7.b0, errp});|= s_in;|'
   # N2 q taken as UNSIGNED - negative inputs mangled (a very realistic slip)
   mut_ns6 N2 's|wire signed \[6:0\]  q    = accr\[16:10\];|wire        [6:0]  q    = accr[16:10];|'
   # N3 the post-clip residue re-centring dropped
   mut_ns6 N3 's|errp     <= (clip_hi .. clip_lo) ? 10.d512 : errn;|errp     <= errn;|'
   # N4 the clamp dropped - an overload then WRAPS, i.e. a full-scale sign flip
   mut_ns6 N4 's|code     <= clip_hi ? 6.d63 : clip_lo ? 6.d0 : (6.d32 + q\[5:0\]);|code     <= (6'"'"'d32 + q[5:0]);|'
   # N5 the tick ignored - the DAC would update at 96.65 MHz
   mut_ns6 N5 's|end else if (tick) begin|end else begin|'
   # N6 the quantizer split one bit off - a 2x gain error
   mut_ns6 N6 's|q    = accr\[16:10\];|q    = accr[15:9];|'
   # N7 reset to 0 instead of mid-scale - a DC step/click at power-on
   mut_ns6 N7 's|^            code     <= 6.d32;|            code     <= 6'"'"'d0;|'

   # ---- audio_mixer ------------------------------------------------------
   # M1 wrap instead of saturate (the loudest artifact this path can make)
   mut_mix M1 's|cl_l\[SW-1:0\]|sum_l[SW-1:0]|; s|cl_r\[SW-1:0\]|sum_r[SW-1:0]|'
   # M2 a disabled slot still contributes
   mut_mix M2 's|= src_en\[gi\] ? gained : {AW{1.b0}};|= gained;|'
   # M3 left/right pan swapped
   mut_mix M3 's|localparam PAN_L = PAN\[gi\*2+1\];|localparam PAN_L = PAN[gi*2+0];|; s|localparam PAN_R = PAN\[gi\*2+0\];|localparam PAN_R = PAN[gi*2+1];|'
   # M4 the g/8 gain shifted one bit wrong
   mut_mix M4 's|gained = scaled\[AW+2:3\];|gained = scaled[AW+1:2];|'
   # M5 saturating at 32767 instead of audio_ns6's clip-free 31744
   mut_mix M5 's|localparam signed \[AW-1:0\] SAT_P =  FS_SAT;|localparam signed [AW-1:0] SAT_P =  16'"'"'sd32767;|'
   # M6 dbg_sat not sticky
   mut_mix M6 's|dbg_sat <= dbg_sat .. hit_l .. hit_r;|dbg_sat <= hit_l \|\| hit_r;|'
   # M7 the signed cast on the constant gain dropped - Verilog then does an
   #    UNSIGNED multiply and every negative sample is mangled
   mut_mix M7 's|scaled = raw \* $signed({1.b0, G});|scaled = raw * G;|'

   # ---- audio_out: the pad mux and the CMT jack --------------------------
   # O1 tape-out taken from the shaped code instead of the raw speaker bit
   mut_out O1 's|1.b0, spk_raw}|1'"'"'b0, code_r[0]}|'
   # O2 the anti-echo force dropped - the shaped code bit rattles into 177716
   mut_out O2 's|tape_lvl <= cmt_mode_q ? cmt_meta : 1.b0;|tape_lvl <= cmt_meta;|'
   # O3 the mono fold summed instead of averaged (6 dB too loud, can clip)
   mut_out O3 's|wire signed \[15:0\] mono = msum\[16:1\];|wire signed [15:0] mono = msum[15:0];|'
   # O4 the CMT output-enable split dropped - we would fight the tape input pad
   mut_out O4 's|assign dac_r_oe = cmt_live ? 6.b001111 : 6.b111111;|assign dac_r_oe = 6'"'"'b111111;|'

   # A1: the Turbosound slots swapped in the pack. Nothing else in the tree can
   # see this - bk_turbosound_tb proves A lands in ts_l and C in ts_r, and
   # audio_mixer_tb proves slot 3 is L-only and slot 4 R-only, but only
   # bk_audio_tb's pan section proves ts_l is packed into slot 3. Swapped, the
   # board plays the stereo image MIRRORED and every other oracle still passes.
   mut_aud A1 's|slot_src = {cx_r, cx_l, ts_r, ts_l,|slot_src = {cx_r, cx_l, ts_l, ts_r,|'
   # A2: the speaker rail off a 1024 multiple - it stops being an audio_ns6
   # fixed point and the ladder codes start rattling on a static input.
   mut_aud A2 's|SPK_LVL = 16.sd8192;|SPK_LVL = 16'"'"'sd7936;|'

   # A3: the COVOX pair swapped in the pack - the A1 argument again, one
   # device later. bk_covox_tb proves the low byte lands in cx_l and
   # audio_mixer_tb proves slot 5 is L-only, but only bk_audio_tb's covox
   # section proves cx_l is packed into slot 5. Swapped, the board plays the
   # Covox stereo image MIRRORED and every other oracle still passes.
   mut_aud A3 's|slot_src = {cx_r, cx_l, ts_r, ts_l,|slot_src = {cx_l, cx_r, ts_r, ts_l,|'
   # A4: cx_en ignored in the slot enable. That enable is bk_covox's ONLY mute
   # mechanism (the device keeps presenting its sample while muted - one gate,
   # not two), so without it the PSG arbitration silently does nothing at all
   # and the never-reset 177714 latch reaches the ladders.
   mut_aud A4 's|slot_en  = {cx_en & ~tone_live, cx_en & ~tone_live,|slot_en  = {~tone_live, ~tone_live,|'
   # A5: the Covox slot gain raised from 5/8 to 6/8. That is the largest
   # plausible wrong value and it BREAKS THE HEADROOM PROOF: 32768*6/8 = 24576
   # and 24576 + 8192 = 32768 > FS_SAT. Caught twice over - the covox pan
   # section's exact codes and the budget section's dbg_sat.
   mut_aud A5 's|SLOT_GAIN = 28.h5_5_8_8_8_8_8;|SLOT_GAIN = 28'"'"'h6_6_8_8_8_8_8;|'

   # ---- qbus_mem: the 177714 capture seam --------------------------------
   # Q1 WTBT taken from SYNC time instead of live at DOUT. At SYNC it is
   #    ASSERTED for every write, so a SYNC-latched build calls every access a
   #    byte op - substituted here directly. No cycle-count golden anywhere can
   #    see this; only the tb's two WTBT profiles can.
   mut_mem Q1 's|port_word <= wtbt_n;                              // LIVE at DOUT|port_word <= 1'"'"'b0;|'
   # Q2 the one-strobe qualifier dropped - port_wr then pulses on every sclk of
   #    a DOUT window, and an edge-sensitive device sees one write as dozens
   mut_mem Q2 's|if (!port_dout) port_seen <= 1.b0;|if (1'"'"'b1) port_seen <= 1'"'"'b0;|'
   # Q3 the odd-byte lane merged into the LOW half (BkEmu puts it at <<8)
   mut_mem Q3 's|else if (addr\[0\]) port_data\[15:8\] <= ~ad_n\[7:0\];|else if (addr[0]) port_data[7:0]  <= ~ad_n[7:0];|'
   # Q4 the latch reset by nINIT - it must NOT be (the spk/mot class: a real
   #    Covox is a passive DAC on the port latch with no reset pin)
   mut_mem Q4 's|^        port_wr <= 1.b0;|        port_wr <= 1'"'"'b0;\n        if (!init_n) port_data <= 16'"'"'o000000;|'
   # Q5 decoded off the WRONG nSEL pin (177716 instead of 177714)
   mut_mem Q5 's|wire port_dout = !sync_n \&\& !dout_n \&\& !sel2_n;|wire port_dout = !sync_n \&\& !dout_n \&\& !sel1_n;|'

   echo "audio mutations: all killed"
fi
