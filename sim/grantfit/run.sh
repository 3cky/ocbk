#!/usr/bin/env bash
#
# Phase-9 037 GRANT-RULE BENCH - the whole constraint set, in one table.
#
# SLOW (~several minutes) - deliberately NOT in `make sim`, like sim/smktime,
# sim/vregtime, run_boot_check.sh and run_draw_check.sh.
#
# WHY THIS EXISTS
# ---------------
# The 037-fronted DRAM path diverges from a real BK-0011M, and the divergence
# is PATTERN-DEPENDENT: per DRAM access the real machine costs ~4.37 cycles
# more than un-arbitrated SMK RAM when accesses are ~3.85 slots apart, but
# ~6.60 when they come in back-to-back pairs; ours is flat at ~4.2 either way.
# That is the beam-raced palette skew (Babylona's per-scanline block is 256.1
# cycles = exactly one scanline on a real machine and 240 on ours).
#
# Two arbiter rules have already been tried and rejected, and BOTH times the
# lesson was the same: a rule was judged on ONE leg and wrecked another
# ("no grant in the slot immediately after a grant" does nothing at all;
# ">=3 slots between grants" fits `MOV #imm` and wrecks `SOB`).  So this bench
# never shows one number: it runs EVERY tone program that was measured on the
# real BK-0011M, four of which must MOVE and three of which must NOT.
#
# THE DISCRIMINATOR THAT MAKES THE FIT WELL-POSED is leg B.  A grant rule is
# direction-blind - it delays a second back-to-back access whether that access
# is a read or a write - yet the real machine pays +5.08 cyc on a read+read
# pair (leg C) and only +1.35 on a read+write pair (leg B).  Either one rule
# produces both (the write's extra slot being absorbed by the vm1's fixed DATO
# window - sim/vregtime PROVED such absorption exists: the whole N_VREG = 1..4
# ladder is bit-identical), or the mechanism is not a grant rule at all.  A
# candidate that closes C and D but leaves B flat has not explained the data.
#
# NORMALISATION - READ THIS BEFORE COMPARING ANYTHING
# ---------------------------------------------------
# The `real` column is CPU CYCLES ON THE REAL MACHINE = 4.000e6 / (2 * f_real),
# using the real BK-0011M's own 4.000 MHz clock (schematic-traced: 12 MHz
# quartz / 3).  That makes it directly comparable with the cycle counts this
# bench prints, with our +0.67 % clock offset (4.0270 MHz) EXCLUDED - the
# offset is real but is a property of the board's crystal, not of the memory
# model, and nothing in the RTL can fix it.
#
# The project docs contain a SECOND normalisation: CLAUDE.md's N_EXT table
# converts the same tones at 4.0270 MHz, which answers the different question
# "what would OUR board have to do to emit that tone" and therefore carries the
# clock offset inside it (that is where its "+0.8 %" control-leg residual comes
# from).  Do not mix them.  Same tones, different question.
#
# THE LEGS  (real = measured on a real BK-0011M; see test/sndtest*.mac, whose
# headers carry the readings and the reasoning)
#
#                                                    real  SHIPPED   was (pre-fix)
#   A  sndtest662  @2000  192 x write to 0177662     6734  6744  +0.15   6736
#   B  sndtest662  @2006  192 x write to RAM         6993  7008  +0.21   6736  -3.68 %
#   C  sndtestimm  @2000  192 x MOV #imm,R1 in RAM   6622  6624  +0.03   5648 -14.71 %
#   D  sndtestbaby @2000  24 x the Babylona block    6211  6208  -0.05   5824  -6.23 %
#   E  sndtestsmk  @2046  192 x SOB in RAM           4184  4184  +0.00   4176
#   F  sndtestsmk  @2000  192 x SOB in SMK RAM       3328  3327  -0.03   3327
#   G  sndtestimm2 @2000  192 x MOV #imm in SMK RAM  3929  3927  -0.05   3927
#   H  sndtestimm2 @2046  = leg C's loop, in place    ---  6624  (== C)  5648
#
# SINCE 2026-07-26 THE FIT IS SHIPPED RTL (va_037_sync's GRANT_SETUP = 2 +
# src/bus/bk_rply.sv), so the `SHIPPED` column is what a plain `./run.sh` must
# print, and this file is now the REGRESSION that keeps the calibration pinned.
# Total |delta| = 33 cycles across seven legs; every residual is inside what
# +/-1 Hz of tone-reading error is worth on its leg (+/-23, 25, 22, 19, 9, 6, 8).
#
# The `was` column is the pre-fix behaviour, reproducible with
# `./run.sh --setup 0 --nod8b`.  Each of those eight numbers had been derived
# independently before this bench existed (CLAUDE.md's beam-race A-D table,
# sim/smktime/golden_std for E, qbus_pkg's ideal 3326 for F,
# test/sndtestimm2.mac's ideal 3927 for G, and H must equal C exactly), which is
# what validated the bench in the first place.  If a run does not reproduce
# either column, suspect the bench before believing the result.
#
# A, F and G are the "must not move" legs.  A is the sharpest of them: same
# instruction rate and same fetch stream as B, so any rule that also slows the
# plain fetch path breaks it immediately.  F and G are MK_EXT (N_EXT = 1, not
# 037-fronted, no arbitration, no slot quantisation) - a candidate that moves
# them has reached outside the 037 and is wrong by construction.  H is not a
# hardware leg at all: it is the same loop as C at a different address in a
# different program, so C != H means the bench is measuring the address rather
# than the access pattern.
#
# F and G carry a KNOWN tb artefact: this stack's port-2 video fetch is a
# saturator, harsher than the shipped paced fetch, so a minority of MK_EXT
# reads miss the N_EXT=1 fast reply and take the +1-cycle S_WAIT path.  The
# EXTRD counter makes that exact, and the `ours` column below is CORRECTED
# (avg - slow/halves), which is how qbus_pkg derives the ideal 3327 from
# sim/smktime's measured 3362.
#
# USAGE
#   ./run.sh              the shipped machine - must reproduce the fit
#   ./run.sh --sweep      back each ingredient out again, one table each
#   ./run.sh --legs A,B,C limit to some legs (works with --sweep too)
#   ./run.sh --setup 0 --nod8b     the pre-Phase-9 behaviour
#   ./run.sh --cand "--gap 3"      an ad-hoc patch037 candidate
#
# The two WINNING ingredients are shipped RTL now, so exploring them is not a
# source rewrite any more: the setup window is va_037_sync's GRANT_SETUP
# parameter (`-Ptone_tb.GRANT_SETUP=k`, i.e. `--setup k`) and D8:B is
# src/bus/bk_rply.sv, instantiated for real with `+nod8b` as the bypass.  The
# candidates that did NOT win are still built by patch037.py from a COPY of
# src/bus/va_037_sync.sv (the sim/evnt idiom - anchored rewrites, never an inline
# replica), so the sweep keeps re-rejecting them.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
CPU=$SRC/cpu
MEM=../../mem

SWEEP=0
LEGS="A,B,C,D,E,F,G,H"
CAND=""
D8B=""
SETUP=""
ADHOC=0
VERBOSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sweep) SWEEP=1; shift ;;
        --legs)  LEGS="$2"; shift 2 ;;
        --cand)  CAND="$2"; ADHOC=1; shift 2 ;;
        --nod8b) D8B="+nod8b"; ADHOC=1; shift ;;
        --setup) SETUP="$2"; ADHOC=1; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# leg : image : entry : stack : fetch_lo : fetch_hi : loop_lo : loop_n : real : what
LEGTAB="
A:sndtest662:2000:stock:2040:2072:2050:8:6734:192 x write 0177662
B:sndtest662:2006:stock:2040:2072:2050:8:6993:192 x write to RAM
C:sndtestimm:2000:stock:2014:2066:2024:16:6622:192 x MOV #imm,R1 in RAM
D:sndtestbaby:2000:stock:2040:3756:2046:10:6211:24 x Babylona block
E:sndtestsmk:2046:stock:2046:2076:2062:8:4184:192 x SOB in RAM
F:sndtestsmk:2000:smk:140000:140026:140014:8:3328:192 x SOB in SMK RAM
G:sndtestimm2:2000:smk:140000:140066:140024:16:3929:192 x MOV #imm in SMK RAM
H:sndtestimm2:2046:stock:2062:2134:2072:16:0:cross-check of leg C
"

HALVES=4

build () {   # $1 = va_037_sync path; $2 = optional GRANT_SETUP override
    local pset=""
    [ -n "${2:-}" ] && pset="-Ptone_tb.GRANT_SETUP=$2"
    iverilog -g2012 $pset -o "$SP/tone.vvp" -s tone_tb \
       "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
       "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
       "$SRC/qbus_pkg.sv" "$1" "$SRC/bus/bk_rply.sv" "$SRC/sdram/cpu_sdram_dp.sv" \
       "$SRC/sdram/sdram_arbiter.sv" "$SRC/sdram/sdram_ctrl.sv" "$SRC/bus/mem_mapper.sv" \
       "$SRC/bus/qbus_mem.sv" "$SRC/peripheral/bk_evnt.sv" ../sdram_model.sv \
       tone_tb.v 2>&1 | grep -v 'sorry:' || true
    [ -f "$SP/tone.vvp" ] || { echo "grantfit: build failed" >&2; exit 1; }
}

# run_one <leg-record> <extra vvp plusargs>  -> prints "cycles corrected"
run_one () {
    local rec="$1" extra="${2:-}"
    local leg image entry stack flo fhi llo ln real what
    IFS=: read -r leg image entry stack flo fhi llo ln real what <<< "$rec"

    local smkflag="" plusmk=""
    [ "$stack" = "smk" ] && { smkflag="--smk"; plusmk="+smk"; }

    ( cd "$MEM" && python3 gen_tone_test.py --image "$image" --entry "$entry" \
        $smkflag "$SP" ) > /dev/null

    ( cd "$SP" && vvp -n tone.vvp $plusmk $extra \
        "+halves=$HALVES" "+fetch_lo=$flo" "+fetch_hi=$fhi" \
        "+loop_lo=$llo" "+loop_n=$ln" < /dev/null ) > "$SP/out.txt" 2>/dev/null || true

    grep -q '^TONE PASS$' "$SP/out.txt" || {
        echo "LEG $leg FAILED:" >&2
        grep -E 'TONE-ERROR|TONE FAIL' "$SP/out.txt" >&2 || tail -3 "$SP/out.txt" >&2
        return 1
    }
    cp "$SP/out.txt" "$SP/leg_$leg.txt"

    local avg slow corrected
    avg=$(sed -n 's/.*RESULT .*avg=\([0-9.]*\).*/\1/p' "$SP/out.txt")
    slow=$(sed -n 's/^EXTRD fast=[0-9]* slow=\([0-9]*\).*/\1/p' "$SP/out.txt")
    corrected=$(python3 -c "print(f'{$avg - $slow/$HALVES:.1f}')")
    echo "$avg $corrected"
}

table () {   # table <label> <extra vvp plusargs>
    local label="$1" extra="${2:-}"
    printf '\n=== %s ===\n' "$label"
    printf '%-3s %-28s %8s %9s %8s %8s  %s\n' \
           leg program real ours delta 'delta%' note
    local total=0 rec leg image entry stack flo fhi llo ln real what
    local cyc corr d dp
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        IFS=: read -r leg image entry stack flo fhi llo ln real what <<< "$rec"
        case ",$LEGS," in *",$leg,"*) ;; *) continue ;; esac
        read -r cyc corr <<< "$(run_one "$rec" "$extra")"
        if [ "$real" = "0" ]; then
            printf '%-3s %-28s %8s %9s %8s %8s  %s\n' \
                   "$leg" "$what" "-" "$corr" "-" "-" "$image @$entry"
        else
            d=$(python3 -c "print(f'{$corr - $real:+.1f}')")
            dp=$(python3 -c "print(f'{100*($corr - $real)/$real:+.2f}')")
            total=$(python3 -c "print(f'{$total + abs($corr - $real):.1f}')")
            printf '%-3s %-28s %8s %9s %8s %8s  %s\n' \
                   "$leg" "$what" "$real" "$corr" "$d" "$dp" "$image @$entry"
        fi
        # --verbose: the per-fetch gap table, i.e. the cost of each instruction
        # (or of each HALF of a two-word one) - which is what says WHY a
        # candidate fits, not just that it does
        [ "$VERBOSE" = 1 ] && sed -n 's/^LOOP /      LOOP /p' "$SP/leg_$leg.txt"
    done <<< "$LEGTAB"
    printf '%-3s %-28s %8s %9s %8s\n' '' 'TOTAL |delta| vs real' '' '' "$total"
}

if [ "$SWEEP" = 0 ] && [ "$ADHOC" = 0 ]; then
    build "$SRC/bus/va_037_sync.sv"
    table "SHIPPED RTL (GRANT_SETUP=2 + bk_rply)"
    exit 0
fi

if [ "$ADHOC" = 1 ]; then
    if [ -n "$CAND" ]; then
        python3 patch037.py --out "$SP/cand.sv" $CAND
        build "$SP/cand.sv" "$SETUP"
    else
        build "$SRC/bus/va_037_sync.sv" "$SETUP"
    fi
    table "CANDIDATE ${CAND:-(shipped 037)}${SETUP:+ setup=$SETUP} ${D8B}" "$D8B"
    exit 0
fi

# ---- the sweep ------------------------------------------------------------
# Since 2026-07-26 the winning combination IS the shipped RTL, so the sweep now
# runs BACKWARDS: it starts from the shipped machine and backs each ingredient
# out again.  The first table is therefore the regression that keeps the fit
# pinned, and "GRANT_SETUP=0 +nod8b" reproduces the pre-Phase-9 numbers.
build "$SRC/bus/va_037_sync.sv"
table "SHIPPED RTL (GRANT_SETUP=2 + bk_rply)  <- must stay at the fit"
table "shipped setup, D8:B backed out"                    "+nod8b"

for k in 0 1 3; do
    build "$SRC/bus/va_037_sync.sv" "$k"
    table "GRANT_SETUP=$k + bk_rply"
    table "GRANT_SETUP=$k, D8:B backed out" "+nod8b"
done

# The candidates that did NOT win, kept so the sweep keeps re-rejecting them.
# Each is applied ON TOP of the shipped configuration.
for t in neg both; do
    python3 patch037.py --out "$SP/t_$t.sv" --trply "$t"
    build "$SP/t_$t.sv"
    table "shipped + TRPLY clear quantised to $t (was inert)"
done

for g in 2 3; do
    python3 patch037.py --out "$SP/g$g.sv" --gap "$g"
    build "$SP/g$g.sv"
    table "shipped + minimum inter-grant gap = $g slots (rejected)"
done
