#!/usr/bin/env bash
#
# Phase-9 177662 WRITE-TIME oracle - the calibration of N_VREG, and the
# regression that keeps it calibrated.
#
# SLOW (~1 min for both legs) - deliberately NOT in `make sim`, like
# sim/smktime, run_boot_check.sh and run_draw_check.sh.  Run it whenever
# N_VREG, qbus_mem's reply FSM or the 177662 decode changes.
#
# WHY THIS CONSTANT GOT ITS OWN ORACLE - AND WHAT THE ORACLE FOUND
# ----------------------------------------------------------------
# It was built to test a hypothesis: N_VREG is paid ONCE PER PALETTE WRITE, so
# in a beam-raced multicolor loop an error in it would INTEGRATE down the frame
# (a scanline is only 256 CPU cycles at 4 MHz, so 8-16 writes per line would
# make one wrong cycle per write a 3-6 % per-line stretch) - which is the shape
# of the "progressive skew down the screen" reported against a real BK-0011M.
# It was the only uncalibrated timing left in such a loop: N_RAM + the 037
# steal were measured on hardware in the N_EXT work, 177716 is the vm1's own
# internal reply, EVNT/IRQ2 is sim/evnt against the reference netlist.
#
# **THE HYPOTHESIS IS FALSE, AND THIS ORACLE IS THE PROOF.**  The whole
# N_VREG = 1..4 ladder produces BIT-IDENTICAL cycle counts (`--sweep`): a
# DATO's RPLY, arriving anywhere in that range, lands inside the vm1's fixed
# write cycle and never moves the next SYNC.  Checked on two instruction shapes
# (`MOV R1,(R0)` and the `MOV R1,@#177662` real code uses) with the VREGWR
# probe confirming the FSM genuinely took the other path (fast=192 vs
# slow=192).  So N_VREG cannot skew anything - and equally cannot regress
# anything.  The oracle stays as the regression that keeps that pinned.
#
# WHAT IT MEASURES
# ----------------
# doc/sndtest662.bin (mem/gen_vreg_test.py, and the SAME bytes are what runs on
# a real BK-0011M) toggles the 177716 speaker bit around a loop of **192
# writes** - 8 unrolled `MOV R1,(R0)` x 24 SOB iterations.  One tone
# half-period is therefore dominated by those writes, and one unit of N moves
# it ~192 cycles out of ~4300 = ~4.5 %, where the sndtestsmk hardware readings
# resolved ~1 Hz.
#
# TWO LEGS, ONE IMAGE, TWO ENTRY POINTS - the loop body is BYTE-IDENTICAL and
# the only difference in the whole machine is R0:
#   * 662 : the 192 writes go to 0177662.  Not 037-fronted, no cycle stealing.
#   * RAM : the same writes go to a scratch word in the memory the loop is
#           already resident in (MK_RAM037, N_RAM=4 + the 037 steal).  CONTROL
#           leg: that path is hardware-calibrated to +0.04 %, so it validates
#           the clock rate, the access-count model and the assembler, and
#           isolates any remaining error to N_VREG.  The 037 steal shows up as
#           min != max in the LOOP table (the authentic beat) - the 662 leg is
#           flat, because nothing steals from an I/O register.
#
# The LOOP table is the sharp output: eight identical instructions, so
# `min`/`max` there IS the cost of one write.  The tone is the number a real
# machine can be compared on.
#
# THE VALUE: N_VREG = 1, SCHEMATIC-DERIVED (doc/bk0011m.sch, 2026-07-26).
# Set because it is what the board does, not because anything depends on it.
# ---------------------------------------------------------------------
# The palette register D35 (K555TM9) is clocked by net S1-78 = D6:C (K555LE4
# NOR of the 037's BS, DOUT and the latched address bit D27.9) - the write
# strobe - and THAT SAME NET drives D34.1 (K555LN2, open-collector), whose
# output is wire-ORed onto S1-49 = the K input of D8:B, the flip-flop that
# re-times RPLY onto the CPU's RPLY pin.  So the board replies COMBINATIONALLY,
# one gate after the strobe: the fastest reply there is, the N_KBD = 1 class.
# It has to be that circuit - the bus RPLY net S1-21 has exactly four drivers
# (014, 037, the two RE2A ROMs), the 014 does not reply to a 662 write
# (sim/ref014/README.md) and the 037 decodes only 177664.
#
# HARDWARE CONFIRMATION: not needed for the constant (the sweep shows the CPU
# cannot see it), but doc/sndtest662.bin is a ready-made differential probe if
# a write-path timing question ever comes up: run it on a real BK-0011M (entry
# 0o2000, then again at 0o2006) and on the board and compare the four tones,
# the way sim/smktime does for N_EXT.
#
# `--sweep` reproduces the N_VREG = 1..4 ladder from the RTL by sed-patching a
# COPY of qbus_pkg.sv (the sim/evnt idiom - never an inline replica).
#
# WHAT THE GOLDEN ACTUALLY PINS.  Since the cycle counts are insensitive to
# N_VREG, the LOOP/HALF/RESULT lines are a regression on the FETCH path and the
# 037 steal (the control leg's min != max is that beat), and the VREGWR line is
# the regression on the reply path itself - it is the ONLY line here that moves
# when N_VREG or the vreg_fast branch changes, and it moves to all-slow.  That
# is deliberate and worth keeping: it means a future change to the reply FSM is
# caught, without pretending the timing depends on it.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../../src/cpu
SRC=../../src

SWEEP=0; REGEN=0
[ "${1:-}" = "--sweep" ] && SWEEP=1
[ "${1:-}" = "--regen" ] && REGEN=1

build () {   # $1 = qbus_pkg path
    iverilog -g2012 -o "$SP/vregtime.vvp" -s vreg_time_tb \
       "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
       "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
       "$1" "$SRC/va_037_sync.sv" "$SRC/cpu_sdram_dp.sv" \
       "$SRC/sdram_arbiter.sv" "$SRC/sdram_ctrl.sv" "$SRC/mem_mapper.sv" \
       "$SRC/qbus_mem.sv" "$SRC/bk_evnt.sv" ../sdram_model.sv \
       vreg_time_tb.v 2>&1 | grep -v 'sorry:' || true
}

run_leg () {   # $1 = label, $2 = gen flags, $3 = vvp plusargs, $4 = golden|""
    ( cd ../../mem && python3 gen_vreg_test.py $2 ../sim/vregtime ) > /dev/null
    vvp -n "$SP/vregtime.vvp" $3 2>/dev/null | tee "$SP/out.txt" \
        | grep -E "VREGTIME-ERROR|LOOP |HALF |VREGWR |RESULT " || true
    grep -q '^VREGTIME PASS$' "$SP/out.txt" \
        || { echo "177662 write-time oracle ($1): FAIL" >&2; exit 1; }
    if [ -n "${4:-}" ]; then
        grep -E '^(LOOP|HALF|VREGWR|RESULT) ' "$SP/out.txt" > "$SP/got.txt"
        if [ "$REGEN" = 1 ]; then
            cp "$SP/got.txt" "$4"; echo "regenerated $4"
        else
            diff -u "$4" "$SP/got.txt" \
                || { echo "177662 write-time oracle ($1): GOLDEN DIFF" >&2; exit 1; }
        fi
    fi
    echo "177662 write-time oracle ($1): PASS"
}

if [ "$SWEEP" = 1 ]; then
    for n in 1 2 3 4; do
        sed "s/^\( *localparam int unsigned N_VREG *=\).*/\1 $n;/" \
            "$SRC/qbus_pkg.sv" > "$SP/qbus_pkg.sv"
        grep -q "N_VREG = $n;" "$SP/qbus_pkg.sv" || { echo "sweep sed failed" >&2; exit 1; }
        build "$SP/qbus_pkg.sv"
        ( cd ../../mem && python3 gen_vreg_test.py ../sim/vregtime ) > /dev/null
        printf 'N_VREG=%d  ' "$n"
        vvp -n "$SP/vregtime.vvp" +halves=2 2>/dev/null \
            | grep -E '^(RESULT|VREGTIME-ERROR)' || true
    done
    exit 0
fi

build "$SRC/qbus_pkg.sv"
# The half-periods are constant to within a cycle, so a handful is enough.
run_leg "177662"       ""         "+halves=4"         golden_662.txt
run_leg "ordinary RAM" "--ramleg" "+ramleg +halves=4" golden_ram.txt
