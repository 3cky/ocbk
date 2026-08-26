# sim/parlib.sh - a small job pool for the oracle runners.
#
# The oracles are independent processes that only read the repository and write
# to their own mktemp scratch, so they can run at the same time. This file gives
# the runners a pool that keeps at most N jobs alive and REPLAYS EACH JOB'S
# OUTPUT IN LAUNCH ORDER, so a parallel transcript reads the same as a serial
# one. Source it, then:
#
#   par_init [jobs]           start a pool (default: $SIM_JOBS_INNER, then
#                             $SIM_JOBS, then nproc)
#   par_job <name> <cmd...>   run <cmd> in the background, capped at <jobs>
#   par_wait                  wait for all, print the logs, return 1 on any fail
#
# <cmd> can be a shell function of the sourcing script - it runs in a subshell,
# so it must not pass state back through variables, only through files.
#
# Set jobs to 1 to get the exact serial behaviour back (SIM_JOBS=1). That is
# also what a runner must do for a --regen leg, because a golden written by one
# leg is read by the next.
#
# PAR_ON_DONE=<function> gets called as <function> <index> <name> <rc> <seconds>
# the moment a job is reaped, for runners that want live progress.

par_init() {
   _par_jobs="${1:-${SIM_JOBS_INNER:-${SIM_JOBS:-$(nproc)}}}"
   [ "$_par_jobs" -ge 1 ] 2>/dev/null || _par_jobs=1
   _par_dir="$(mktemp -d)"
   _par_n=0
   _par_names=()
   _par_rc=()
   _par_sec=()
   _par_t0=()
   unset _par_idx
   declare -gA _par_idx=()
}

par_job() {
   local name="$1"; shift
   while [ "${#_par_idx[@]}" -ge "$_par_jobs" ]; do _par_reap; done
   local i="$_par_n"
   _par_n=$((i + 1))
   _par_names[i]="$name"
   _par_t0[i]="$(date +%s)"
   ( "$@" ) > "$_par_dir/$i.log" 2>&1 &
   _par_idx[$!]="$i"
}

_par_reap() {
   local pid rc=0 i
   wait -n -p pid || rc=$?
   # A pid we do not own (or no children left) must not spin the caller.
   [ -n "${pid:-}" ] || return 0
   i="${_par_idx[$pid]:-}"
   [ -n "$i" ] || return 0
   unset "_par_idx[$pid]"
   _par_rc[i]="$rc"
   _par_sec[i]="$(( $(date +%s) - _par_t0[i] ))"
   if [ -n "${PAR_ON_DONE:-}" ]; then
      "$PAR_ON_DONE" "$i" "${_par_names[i]}" "$rc" "${_par_sec[i]}"
   fi
}

# par_wait - drain the pool, replay every log in launch order, return 1 if any
# job failed. The logs are printed here (not as they finish) so that a run with
# -j16 produces the same readable transcript as a serial one.
par_wait() {
   local st=0 i
   while [ "${#_par_idx[@]}" -gt 0 ]; do _par_reap; done
   for ((i = 0; i < _par_n; i++)); do
      cat "$_par_dir/$i.log"
      [ "${_par_rc[i]}" = 0 ] || st=1
   done
   rm -rf "$_par_dir"
   return $st
}

# par_log <index> - the captured log of one job (for a caller that prints the
# failures itself instead of using par_wait's replay).
par_log() { cat "$_par_dir/$1.log"; }

# par_drain - wait for all jobs WITHOUT printing anything; return 1 on any fail.
par_drain() {
   local st=0 i
   while [ "${#_par_idx[@]}" -gt 0 ]; do _par_reap; done
   for ((i = 0; i < _par_n; i++)); do [ "${_par_rc[i]}" = 0 ] || st=1; done
   return $st
}
