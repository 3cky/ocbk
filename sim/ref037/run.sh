#!/usr/bin/env bash
#
# Phase 3 reference-oracle regression: vm1 CPU + real va_037 + behavioural DRAM.
#
# Establishes the ground-truth per-instruction cycle counts WITH the 037 video
# cycle-stealing active (see ref037_tb.v). The reduced output (unique instruction
# prefix + the first few self-loop samples) is diffed against golden_037.txt.
# This is the reference that the retimed va_037_sync (Phase 3) must reproduce
# exactly; the delta vs sim/bk10/golden.txt is the with-/without-display overhead.
#
# The fourteen legs are independent processes that only read the goldens, so
# they run in parallel (sim/parlib.sh) and their transcripts are replayed in
# launch order - the output reads exactly like the serial run it replaced. The
# --regen-hw path is forced serial, because there a golden written by one leg
# is read by the next.
#
set -uo pipefail
cd "$(dirname "$0")"
. ../parlib.sh

# --regen-hw regenerates ONLY the golden_037_hw* pair (the shipped-machine
# goldens).  golden_037{,_rom}.txt are the NETLIST goldens and are NEVER
# regenerated from anything but a reference run - see the header.
REGEN_HW=0
[ "${1:-}" = "--regen-hw" ] && REGEN_HW=1

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
CPU=$SRC/cpu
K037="."
CORE="$CPU/vm1_config.v $CPU/vm1.v $CPU/vm1_simlib.v $CPU/vm1_qbus.v \
      $CPU/vm1_plm.v $CPU/vm1_tve.v"

build() {   # build <name> <top> <sources...> - iverilog into $SP/<name>.vvp
   local name="$1" top="$2"; shift 2
   iverilog -g2012 -o "$SP/$name.vvp" -s "$top" "$@" 2>&1 | grep -v 'sorry:' || true
}

# Reduce: unique instruction prefix, then the first 4 self-loop samples.
# $1 = self-loop address (001136 for the RAM program, 101136 for +romprog).
# The sample counter re-arms on any non-loop line: in a +warmreset run the
# program re-executes after the mid-run reset, so each pass keeps its own
# first 4 loop samples (single-pass output is unchanged - the loop address
# only ever appears at the end of a pass).
reduce() { awk -v loop="${1:-001136}" \
   '/^FETCH/ { if ($2==loop) { c++; if (c<=4) print } else { c=0; print } }'; }

# leg [--twice] <message> <golden> <vvp> <loop> [plusargs...]
#   Runs one simulation, reduces it and diffs it against <golden>. --twice
#   diffs against the golden CONCATENATED WITH ITSELF, which is the warm-reset
#   contract: both passes must match the SAME unchanged golden.
leg() {
   local twice=0
   [ "$1" = "--twice" ] && { twice=1; shift; }
   local msg="$1" golden="$2" vvp="$3" loop="$4"; shift 4
   local tag; tag="$(printf '%s' "$msg" | tr -c 'A-Za-z0-9' '_')"
   local out="$SP/$tag.out" exp="$golden"
   vvp -n "$SP/$vvp.vvp" "$@" 2>/dev/null | reduce "$loop" > "$out"
   if [ "$twice" = 1 ]; then
      exp="$SP/$tag.exp"
      cat "$golden" "$golden" > "$exp"
   fi
   if diff -u "$exp" "$out"; then
      echo "ref037 ($msg): PASS"
   else
      echo "ref037 ($msg): FAIL (see diff above)" >&2
      return 1
   fi
}

# regen <golden> <vvp> <loop> [plusargs...] - the --regen-hw writer.
regen() {
   local golden="$1" vvp="$2" loop="$3"; shift 3
   vvp -n "$SP/$vvp.vvp" "$@" 2>/dev/null | reduce "$loop" > "$golden"
   echo "regenerated $golden"
}

# --- the four testbench builds (independent, so built in parallel) ----------
par_init
par_job b_ref build ref037 ref037_tb $CORE "$K037/va_037.v" ref037_tb.v

# --- Retime guard: at GRANT_SETUP=0 the retimed core must STILL be
#     bit-identical to the reference netlist (the window folds away and D8:B is
#     bypassed - one switch, see ref037_sync_tb.v). ---
par_job b_s0 build ref037s0 ref037_sync_tb -Pref037_sync_tb.GRANT_SETUP=0 \
   $CORE $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv ref037_sync_tb.v

# --- The SHIPPED machine's own reference: same stack, shipped GRANT_SETUP +
#     bk_rply. This build GENERATES golden_037_hw* (with --regen-hw); every
#     integration leg below must then reproduce it. ---
par_job b_s  build ref037s ref037_sync_tb \
   $CORE $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv ref037_sync_tb.v

# --- SoC integration: va_037_sync owns RAM RPLY, RAM in real SDRAM via the
#     REAL qbus_mem (ROM/IO FSM + arbiter + cpu_sdram_dp + done-gate),
#     with the 037 fetch streaming contention. ---
par_job b_soc build ref037soc ref037_soc_tb $CORE \
   $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv $SRC/sdram/cpu_sdram_dp.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv $SRC/bus/qbus_mem.sv \
   $SRC/sdram/epcs_boot.sv ../sdram_model.sv ../epcs_model.sv \
   ref037_soc_tb.v

# --- Phase 4 cycle-accuracy gate: same SoC but with the REAL video pipeline on
#     all four arbiter ports (readout on a true 3:2 pixel clock + fetch/palette/
#     FB-write), run on past display start. ---
par_job b_socv build ref037socv ref037_soc_video_tb $CORE \
   $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv $SRC/sdram/cpu_sdram_dp.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv $SRC/bus/qbus_mem.sv \
   $SRC/video/fb_video.sv $SRC/video/palette_apply.sv \
   $SRC/video/fb_readout.sv $SRC/video/fb_linebuf.sv $SRC/video/vga_out.sv \
   $SRC/video/vga_timing.sv ../sdram_model.sv \
   ref037_soc_video_tb.v

par_wait || { echo "ref037: a testbench failed to build" >&2; exit 1; }

# =============================================================================
# TWO GOLDEN SETS, AND WHY (Phase 9)
# =============================================================================
# Up to Phase 9 there was one pair, generated from the reference netlist, and
# every leg reproduced it.  The shipped 037 now carries a DELIBERATE,
# hardware-calibrated deviation from the netlist (va_037_sync's GRANT_SETUP
# window + the board's D8:B flop - see sim/grantfit/README.md), so one pair can
# no longer serve both, and the split is made explicit rather than papered over:
#
#   golden_037{,_rom}.txt      the NETLIST's timing.  Generated ONLY from a
#                              reference run (the legs above).  va_037_sync is
#                              still diffed against them at GRANT_SETUP=0, and
#                              THAT is what still guards the sys_clk retime -
#                              the guard did not weaken, it just moved to the
#                              stock setting.
#   golden_037_hw{,_rom}.txt   the SHIPPED machine.  Generated from the SAME
#                              simplest stack (ref037_sync_tb, behavioural DRAM,
#                              done-gate a no-op) at the shipped setting, and
#                              every integration leg below must reproduce it -
#                              exactly the structure the single pair had.
#                              Its authority is the seven real-BK-0011M tone
#                              legs of sim/grantfit, NOT the netlist.
#
# Never "fix" a _hw diff by regenerating from a netlist run: at GRANT_SETUP=2
# the netlist is not the reference any more, silicon is.

# --regen-hw writes golden_037_hw* that the later legs then read, so that path
# must stay serial and in order.
[ "$REGEN_HW" = 1 ] && par_init 1 || par_init

# --- the netlist reference itself, and the same program words executed FROM
#     ROM (fixed N_ROM reply, no 037 cycle-stealing on fetches; RAM data
#     traffic still stolen). golden_037_rom.txt is generated from this
#     reference run only. Key property: the ROM self-loop is FLAT (constant
#     cycles) - any later SDRAM-induced RPLY extension on ROM fetches breaks
#     this diff. ---
par_job r1 leg "reference va_037 cycle counts" \
   golden_037.txt ref037 001136
par_job r2 leg "reference va_037, ROM-region program" \
   golden_037_rom.txt ref037 101136 +romprog

par_job s1 leg "retimed va_037_sync @GRANT_SETUP=0, netlist equivalence" \
   golden_037.txt ref037s0 001136
par_job s2 leg "retimed @0, ROM-region program, netlist equivalence" \
   golden_037_rom.txt ref037s0 101136 +romprog

if [ "$REGEN_HW" = 1 ]; then
   par_job g1 regen golden_037_hw.txt     ref037s 001136
   par_job g2 regen golden_037_hw_rom.txt ref037s 101136 +romprog
else
   par_job g1 leg "retimed va_037_sync, SHIPPED reference" \
      golden_037_hw.txt ref037s 001136
   par_job g2 leg "retimed, SHIPPED, ROM-region program" \
      golden_037_hw_rom.txt ref037s 101136 +romprog
fi

par_job i1 leg "SoC integration: 037+arbiter+SDRAM+done-gate" \
   golden_037_hw.txt ref037soc 001136
par_job i2 leg "SoC integration, ROM-in-SDRAM program" \
   golden_037_hw_rom.txt ref037soc 101136 +romprog

# --- Phase 5.5 soft reset: mid-run DCLO/ACLO re-pulse (the reset button) with
#     SDRAM and boot state untouched; the program re-executes and BOTH passes
#     must match the same golden - a warm reset is cycle-identical to a cold
#     boot. Run in RAM mode and ROM-in-SDRAM mode. ---
par_job w1 leg --twice "SoC integration, warm-reset replay" \
   golden_037_hw.txt ref037soc 001136 +warmreset
par_job w2 leg --twice "SoC integration, ROM warm-reset replay" \
   golden_037_hw_rom.txt ref037soc 101136 +romprog +warmreset

# --- Phase 5 boot path: the SDRAM ROM region is populated by the REAL EPCS
#     loader (flash model -> epcs_boot -> boot-writer mux on port 0) during
#     reset-hold, exactly as ocbk_top boots. Golden must still match. ---
par_job b1 leg "SoC integration, EPCS-loader boot path" \
   golden_037_hw_rom.txt ref037soc 101136 +romprog +bootload

# --- The video legs: golden window must match exactly; display-phase self-loop
#     iterations are checked against the reference beat pattern inside the tb
#     (violations print FETCH-* lines -> the diff fails). The +romprog leg also
#     holds the ROM self-loop FLAT (13 cycles) for 64 display lines - any
#     done-gate RPLY extension on a ROM fetch breaks it. ---
par_job v1 leg "SoC + real video pipeline, 4-port contention" \
   golden_037_hw.txt ref037socv 001136
par_job v2 leg "SoC + video, ROM-in-SDRAM under 4-port contention" \
   golden_037_hw_rom.txt ref037socv 101136 +romprog

# --- Phase 5.5 soft reset under full video contention: the button pressed
#     MID-DISPLAY-LINE (ports 1/2/3 live), then the whole checked sequence -
#     golden window + 64 display lines with the flat-13 ROM loop invariant -
#     must repeat exactly. ---
par_job v3 leg --twice "SoC + video, ROM warm-reset replay mid-display" \
   golden_037_hw_rom.txt ref037socv 101136 +romprog +warmreset

par_wait
