#!/usr/bin/env bash
#
# Phase-9 SMK512 memory-ACCESS-TIME oracle - the calibration of N_EXT, and the
# regression that keeps it calibrated.
#
# SLOW (~1 ms of simulated time per measured tone half-period, ~2 min for all
# three legs) - deliberately NOT in `make sim`, like run_boot_check.sh /
# run_draw_check.sh.  Run it whenever N_EXT, the qbus_mem reply FSM or the
# cpu_sdram_dp issue path changes.
#
# WHAT IT MEASURES
# ----------------
# test/sndtestsmk.bin (consumed VERBATIM - the exact bytes run on the real
# machine; see mem/gen_snd_test.py) toggles the 177716 speaker bit around a
# 192-iteration SOB delay loop.  One tone half-period = one SND..BR pass = 197
# instruction fetches, ALL from the memory the loop is resident in, and nothing
# else in the loop touches memory (the 177716 write is served by the CPU's own
# internal reply for the 177700-177717 block).  So the tone frequency is a
# direct, high-gain readout of that memory's access time: in qbus_mem one unit
# of N is exactly one CPU cycle, so one unit of N moves the tone by ~197 cycles
# out of ~3400, i.e. ~6 %.
#
# THREE LEGS, one image - byte-identical loop code, so the only variable is
# which memory (and which machine) executes it:
#   * SMK   : the whole program - SMK mode 060 (STD10) is committed, the loop is
#             copied to 0140000 (segment 4 = SMK RAM) and runs there.  MK_EXT,
#             fixed N_EXT reply, NOT 037-fronted -> no cycle stealing.
#   * STD   : entry at START (0o2046), so the same loop runs in place in
#             ordinary BK-0011M RAM.  MK_RAM037 - N_RAM=4 plus the 037 steal,
#             which shows as min != max (the authentic beat).  This leg is the
#             CONTROL: that path was already calibrated, so it validates the
#             clock rate and the access-count model and isolates any error to
#             N_EXT.
#   * SMK10 : the SMK leg again on a **BK-0010 stack** (model_bk11=0, /32 CPU
#             rate, the program resident in the machine's own RAM) - the SMK is
#             an МПИ expansion board and DIP 8 works in both models, so bk10+SMK
#             is a shipped configuration whose memory timing nothing else
#             measures. At /32 the SYNC->DIN gap is long enough that the
#             prefetched word can land BEFORE DIN, which is where the
#             `early_pend` interlock earns its keep (and the only place any
#             oracle can kill its removal). 3328 cyc = essentially the ideal
#             3327, EXTRD slow 6/788.
#
# THE HARDWARE CALIBRATION (2026-07-25/26, real BK-0011M + SMK512 vs the board)
# ----------------------------------------------------------------------------
#                  loop in SMK RAM      loop in ordinary RAM (control)
#   real           601 Hz  (3351 cyc)   478 Hz  (4212 cyc)
#   board @ N=4    514 Hz  (3918 cyc)   482 Hz  (4177 cyc)   -14.5 % / +0.84 %
#   board @ N=1    602 Hz               482 Hz               +0.17 % / +0.84 %
#   this sim @ N=1 599 Hz  (3362 cyc)   482 Hz  (4176 cyc)
#
# The board reads HIGHER than this sim, and that is expected: the port-2 model
# below SATURATES the arbiter where the shipped video fetch is paced, so a few
# more reads here miss their reply edge (see THE RESIDUAL). Do not "fix" the
# sim towards 602 by weakening the contention - the saturator is the pessimal
# case on purpose.
#
# The board result also identifies the LEFTOVER error, and it is OUR CPU CLOCK,
# not the memory model.  Both legs run the identical instruction stream, so
#   C = C_internal + reply_overhead + 037_steal
# and the N=4 board pair separates the terms (at N=4 both legs carry the same
# 197*3 overhead, so their DIFFERENCE is the steal): C_internal = 3326.3,
# steal = 260.1 = 1.320/access.  Ask what real CPU clock reconciles the real
# machine's tones with THOSE cycle counts and the legs answer independently -
# 3.998 MHz (SMK) and 3.994 MHz (control), agreeing to 0.12 %, i.e. 4.000 MHz,
# the documented BK-0011M rate, against our 96.6477/24 = 4.0270 (+0.67 %; the
# OneChipBook's 21.47727 MHz crystal cannot make 4.000 under the one-PLL rule).
# Normalised to 4.000 MHz the leftovers are C_internal +0.04 % and steal
# +0.027 cycles/access, both INSIDE the +-8.7 cycles that +-1 Hz on the 478 Hz
# reading is worth - so no memory-model debt remains, the 037 steal included.
#
# TRAP, made once here and shipped for a few hours: do NOT get a per-access
# error by dividing a whole-leg gap by the access count (35 cyc / 197 =
# "0.18/access").  That charges the memory for every non-memory error too.
#
# The control leg being right to +0.8 % is what makes this a measurement of
# N_EXT and not of anything else.  The gap is 567 cycles / 197 accesses =
# 2.88 cycles per access; at one cycle per unit of N that puts the real
# SMK512 board at N ~= 1, i.e. it replies WITHIN the strobe cycle - an async
# external SRAM board, exactly the N_KBD=1 case already pinned for the
# 1801VP1-014.  Ladder (`--sweep` reproduces it from the RTL):
# N_EXT=4 -> 514 Hz, 3 -> 541, 2 -> 571, 1 -> 599 Hz in sim / 602 on the board,
# against the real 601.
#
# THE RESIDUAL, and why it is not zero
# ------------------------------------
# At N_EXT = 1 the reply lands at the detection edge, which needs the SDRAM
# word already fetched - hence the early (SYNC-time) read issue in
# cpu_sdram_dp.  That gives ~22 sys_clk of head start; the SDRAM itself needs
# ~8, but the arbiter grant costs another 4..14 under THIS TB'S WORST-CASE
# port-2 saturator.  So a minority of reads (see the EXTRD line) miss by one
# edge and take the ordinary S_WAIT path, +1 CPU cycle each - which is why the
# SMK leg reads 3362 cycles rather than the ideal 3327, and why its SOB gap is
# 17..18 rather than a flat 17.  The shipped design's port 2 is PACED, not
# saturating, so the board lands slightly faster than this sim - predicted, and
# then measured: 602 Hz vs the sim's 599.  Two things keep that honest:
#   * EXTRD fast/slow is in the golden, so the jitter is a pinned number;
#   * `dbg_romgate` must NEVER fire - that is the reply being held for MORE
#     than one extra edge, i.e. the early issue not working at all, the fixed
#     count silently becoming "whenever the SDRAM got there".
#
# MUTATION-TESTED x5 (2026-07-25; "bk11/bk10" = which leg kills it):
#   * N_EXT reverted 1 -> 4        -> 3918 cyc / 514 Hz, EXTRD all-slow (both);
#   * fast_rd tied 0 (no early issue) -> the reply point can never see
#                                     mem_ready in time: 3524 cyc / 571 Hz,
#                                     i.e. exactly the N=2 the clamp gives
#                                     (both legs);
#   * early_pend removed           -> **bk10 only**, and that is the point of
#                                     having that leg: at /24 the prefetched
#                                     word never arrives before DIN, so D_DONE
#                                     is never reached during the address phase
#                                     and the interlock is dead code; at /32 it
#                                     is, and without it mem_ready falls again
#                                     before DIN - fast 782 -> 611;
#   * wtbt_hold replaced by live wtbt_n -> caught by the `early` counter
#                                     (992 -> 1004 = the program's 12-word copy
#                                     into SMK RAM, every write cycle firing a
#                                     spurious early read once WTBT drops).
#                                     Timing survives it because cpu_sdram_dp's
#                                     D_DONE safety exit releases for the write
#                                     - that exit is why this is a wasted-
#                                     bandwidth bug and not a dropped-write one
#                                     (which is what it WAS before the exit
#                                     existed);
#   * qbus_mem's ext_fast branch removed -> the wcnt clamp gives N=2: 3524 cyc
#                                     / 571 Hz (both legs).
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
CPU=$SRC/cpu

# --sweep: report the tone for N_EXT = 1..4 by sed-patching a COPY of
# qbus_pkg.sv (the sim/evnt mutation idiom - never an inline replica).
SWEEP=0
[ "${1:-}" = "--sweep" ] && SWEEP=1
REGEN=0
[ "${1:-}" = "--regen" ] && REGEN=1

build () {   # $1 = qbus_pkg path
    iverilog -g2012 -o "$SP/smktime.vvp" -s smk_time_tb \
       "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
       "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
       "$1" "$SRC/bus/va_037_sync.sv" "$SRC/bus/bk_rply.sv" "$SRC/sdram/cpu_sdram_dp.sv" \
       "$SRC/sdram/sdram_arbiter.sv" "$SRC/sdram/sdram_ctrl.sv" "$SRC/bus/mem_mapper.sv" \
       "$SRC/bus/qbus_mem.sv" "$SRC/peripheral/bk_evnt.sv" ../sdram_model.sv \
       smk_time_tb.v 2>&1 | grep -v 'sorry:' || true
}

run_leg () {   # $1 = label, $2 = gen flags, $3 = vvp plusargs, $4 = golden|""
    ( cd ../../mem && python3 gen_snd_test.py $2 ../sim/smktime ) > /dev/null
    vvp -n "$SP/smktime.vvp" $3 2>/dev/null | tee "$SP/out.txt" \
        | grep -E "SMKTIME-ERROR|LOOP |HALF |EXTRD |RESULT " || true
    grep -q '^SMKTIME PASS$' "$SP/out.txt" \
        || { echo "SMK512 access-time oracle ($1): FAIL" >&2; exit 1; }
    if [ -n "${4:-}" ]; then
        grep -E '^(LOOP|HALF|EXTRD|RESULT) ' "$SP/out.txt" > "$SP/got.txt"
        if [ "$REGEN" = 1 ]; then
            cp "$SP/got.txt" "$4"; echo "regenerated $4"
        else
            diff -u "$4" "$SP/got.txt" \
                || { echo "SMK512 access-time oracle ($1): GOLDEN DIFF" >&2; exit 1; }
        fi
    fi
    echo "SMK512 access-time oracle ($1): PASS"
}

if [ "$SWEEP" = 1 ]; then
    for n in 1 2 3 4; do
        sed "s/^\( *localparam int unsigned N_EXT *=\).*/\1 $n;/" \
            "$SRC/qbus_pkg.sv" > "$SP/qbus_pkg.sv"
        grep -q "N_EXT = $n;" "$SP/qbus_pkg.sv" || { echo "sweep sed failed" >&2; exit 1; }
        build "$SP/qbus_pkg.sv"
        ( cd ../../mem && python3 gen_snd_test.py ../sim/smktime ) > /dev/null
        printf 'N_EXT=%d  ' "$n"
        vvp -n "$SP/smktime.vvp" +halves=2 2>/dev/null \
            | grep -E '^(RESULT|SMKTIME-ERROR)' || true
    done
    exit 0
fi

build "$SRC/qbus_pkg.sv"
# Both half-periods turn out to be constant to within a cycle, so a handful is
# enough. Checked once at +halves=20 (a whole 50 Hz frame, ~2.5 min/leg): the
# control leg is 4176 on every single one, i.e. the 037 steal pattern is
# commensurate with the loop and does not drift with the beam position.
run_leg "SMK RAM"        ""         "+halves=4"        golden_smk.txt
run_leg "ordinary RAM"   "--stdram" "+stdram +halves=6" golden_std.txt
run_leg "SMK RAM, bk10"  "--bk10"   "+bk10 +halves=4"  golden_smk10.txt

# ---- Phase-9 TURBO legs (non-authentic: /16 = 6.04 MHz, 037 cycle-stealing
# disabled).  There is no real machine to compare against - turbo is
# ahistorical - so these are a REGRESSION on the speed-up, not a calibration.
# The ordinary-RAM leg is the one that matters: its loop is MK_RAM037, so it
# reads out both halves of the feature at once.  Two things to watch in the
# golden:
#   * the HALF cycle count drops (the /16 clock is only half of it - the rest
#     is the grant slot no longer being waited for);
#   * the per-instruction LOOP table COLLAPSES.  That spread IS the 037 steal
#     beat - a fetch landing at different phases of the 8-CLKIN grant slot -
#     so it is the direct readout of whether anything is still arbitrating.
#     Measured: the SOB fetch goes min=20/max=26 (spread 6, i.e. most of a
#     4-cycle slot) -> min=18/max=19, and every other instruction in the loop
#     goes exactly flat.  The residual 1 is NOT arbitration: it is the
#     done-gate holding the reply one extra cycle when the SDRAM has not
#     landed, which N_TURBO = 2 makes a routine, by-design event (it is why
#     those holds are dbg_turbowait and not dbg_romgate).  A turbo golden that
#     showed a spread of ~6 again would mean no_steal is not reaching the
#     arbiter.  Net at the time of writing: 481.2 -> 856.1 Hz, 1.78x.
run_leg "ordinary RAM, turbo" "--stdram" "+stdram +turbo +halves=6" golden_turbo.txt
run_leg "SMK RAM, turbo"      ""         "+turbo +halves=4"         golden_turbo_smk.txt

# The bk10 pair, which is what makes the turbo speed-up a TABLE rather than one
# number - the same loop in 037-fronted RAM at /32 and at /16:
#
#   BK-0011M /24  481.2 Hz (4184 cyc) -> 856.1 Hz (3527.8) = 1.78x = 1.50 x 1.186
#   BK-0010  /32  384.5 Hz (3928 cyc) -> 856.1 Hz (3527.8) = 2.23x = 2.00 x 1.113
#
# The two factors move OPPOSITE ways across the models, and that is the
# fixed-slot argument in the data: a bk10 gains more overall (clock ratio 2.0)
# but LESS from removing the steal, because an 8-CLKIN grant slot is fixed
# wall-clock time and so costs 4 CPU cycles at /32 against 5.33 at /24 - the
# faster machine was losing more cycles to arbitration to begin with. The steal
# beat says the same: min=20/max=23 here vs 20/26 on bk11, both -> 18/19.
# The turbo leg below must land the SAME 21167 cycles as golden_turbo.txt: in
# turbo neither the rate nor the memory path depends on the model, so a diff
# between those two goldens means a model term leaked into a turbo path.
run_leg "ordinary RAM, bk10"       "--stdram --bk10" "+stdram +bk10 +halves=6" \
        golden_std10.txt
run_leg "ordinary RAM, bk10 turbo" "--stdram --bk10" "+stdram +bk10 +turbo +halves=6" \
        golden_turbo10.txt
