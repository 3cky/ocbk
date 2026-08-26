#!/usr/bin/env bash
#
# The `make sim` regression suite, run in parallel.
#
# Every oracle runner is an independent process: it cd's to its own directory,
# reads the repository and writes only to its own mktemp scratch. So the suite
# is embarrassingly parallel, and serially it is dominated by a few long
# testbenches (see the WEIGHT comments below). Serial the suite takes ~35 min;
# on 16 cores it takes ~4.
#
# Usage:
#   ./sim/run_all.sh                 run everything, one status line per oracle
#   ./sim/run_all.sh ref037 video    run only the oracles whose path matches
#   ./sim/run_all.sh -v              print every oracle's full transcript
#   SIM_JOBS=1 ./sim/run_all.sh      serial (also the fallback when debugging)
#
# A failing oracle always prints its full transcript, whatever the mode.
set -uo pipefail
cd "$(dirname "$0")/.."
. sim/parlib.sh

# The list is ordered LONGEST FIRST. With more oracles than cores the pool is a
# greedy list scheduler, and longest-first is what keeps the makespan near the
# longest single oracle instead of stacking a slow one behind the queue. The
# WEIGHT is the measured serial wall time in seconds on the reference machine -
# it only orders the list, so a stale number costs a little makespan, nothing
# else. Re-measure with the per-oracle times this script prints.
SCRIPTS=(
   ./sim/ref037/run.sh          # WEIGHT 432 -> 140 (14 legs in parallel)
   ./sim/run_video.sh           # WEIGHT 282 -> 112 (4 stage tbs in parallel)
   ./sim/ide/run_soc.sh         # WEIGHT 234 - one long tb, not splittable
   ./sim/run_epcs_boot.sh       # WEIGHT 207 ->  67 (3 blob legs in parallel)
   ./sim/evnt/run.sh            # WEIGHT 156 -> 120 (floor: the netlist leg)
   ./sim/romwr/run.sh           # WEIGHT 145
   ./sim/bk11/run.sh            # WEIGHT 145
   ./sim/ref014/run.sh          # WEIGHT 141
   ./sim/ide/run.sh             # WEIGHT 101
   ./sim/ide/run_sd.sh          # WEIGHT  94
   ./sim/bk10/run.sh            # WEIGHT  72
   ./sim/smk/run.sh             # WEIGHT  57
   ./sim/usb/run.sh             # WEIGHT  43
   ./sim/run_audio.sh           # WEIGHT  22
   ./sim/run_sdram_cosim.sh     # WEIGHT   8
   ./sim/ts/run.sh              # WEIGHT   3
   ./sim/run_mapper.sh          # WEIGHT   2
   ./sim/run_sdram_arbiter.sh   # WEIGHT  <1
   ./sim/run_ps2.sh             # WEIGHT  <1
   ./sim/raminit/run.sh         # WEIGHT  <1
   ./sim/mouse/run.sh           # WEIGHT  <1
   ./sim/joystick/run.sh        # WEIGHT  <1
   ./sim/gamepad/run.sh         # WEIGHT  <1
   ./sim/covox/run.sh           # WEIGHT  <1
   ./sim/run_clkgen.sh          # WEIGHT  <1
)

VERBOSE=0
FILTERS=()
for a in "$@"; do
   case "$a" in
      -v|--verbose) VERBOSE=1 ;;
      -*) echo "run_all.sh: unknown option $a" >&2; exit 2 ;;
      *)  FILTERS+=("$a") ;;
   esac
done

if [ "${#FILTERS[@]}" -gt 0 ]; then
   sel=()
   for s in "${SCRIPTS[@]}"; do
      for f in "${FILTERS[@]}"; do
         case "$s" in *"$f"*) sel+=("$s"); break ;; esac
      done
   done
   [ "${#sel[@]}" -gt 0 ] || { echo "run_all.sh: no oracle matches ${FILTERS[*]}" >&2; exit 2; }
   SCRIPTS=("${sel[@]}")
fi

JOBS="${SIM_JOBS:-$(nproc)}"
[ "${#SCRIPTS[@]}" -lt "$JOBS" ] && JOBS="${#SCRIPTS[@]}"

# The runners that parallelise internally (ref037, run_video, run_epcs_boot,
# evnt) are NOT throttled: rationing them to nproc/JOBS jobs each just serialises
# the longest oracle again, and that is the one that sets the makespan. Let them
# oversubscribe - a vvp process peaks at ~20 MB, so the cost is scheduler
# time-slicing, not memory, and total throughput is unchanged.
if [ "${SIM_JOBS:-}" = 1 ]; then
   export SIM_JOBS_INNER=1          # SIM_JOBS=1 means serial all the way down
else
   unset SIM_JOBS_INNER             # inner pools default to nproc
fi

DONE=0
TOTAL="${#SCRIPTS[@]}"
FAILED=()

on_done() {   # <index> <name> <rc> <seconds>
   DONE=$((DONE + 1))
   local mark="ok  "
   if [ "$3" != 0 ]; then mark="FAIL"; FAILED+=("$1"); fi
   printf '[%2d/%2d] %s %4ds  %s\n' "$DONE" "$TOTAL" "$mark" "$4" "$2"
}

echo ">> sim: ${TOTAL} oracles, ${JOBS} at a time"
T0=$(date +%s)

if [ "$VERBOSE" = 1 ]; then
   par_init "$JOBS"
   for s in "${SCRIPTS[@]}"; do par_job "$s" "$s"; done
   par_wait; st=$?
else
   PAR_ON_DONE=on_done
   par_init "$JOBS"
   for s in "${SCRIPTS[@]}"; do par_job "$s" "$s"; done
   par_drain; st=$?
   for i in "${FAILED[@]}"; do
      echo
      echo "======== FAILED: ${SCRIPTS[i]} ========"
      par_log "$i"
   done
   rm -rf "$_par_dir"
fi

printf '>> sim: %s (%d oracles, %ds wall)\n' \
   "$([ $st = 0 ] && echo 'all green' || echo "${#FAILED[@]} FAILED")" \
   "$TOTAL" "$(( $(date +%s) - T0 ))"
exit $st
