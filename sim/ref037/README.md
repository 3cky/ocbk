# Phase 3 reference oracle

Ground-truth cycle-accurate timing for the 037 arbiter (Phase 3).

- `va_037.v`  — vendored **reference** 1801VP1-037 model, from
  `~/projects/other/fpga/k1801/037/rtl/va_037.v` (do not edit; re-sync from
  upstream). Sim-only; the synth path uses the retimed `src/va_037_sync.sv`.
- `tb_037.v`  — vendored upstream 037 unit testbench (netlist-equivalence oracle
  for the retimed core).
- `ref037_tb.v` — vm1 CPU + `va_037` + behavioural DRAM running the bk10 test
  program; RAM RPLY comes from the 037 (video cycle-stealing active).
- `golden_037.txt` — reduced ground-truth cycle counts (unique instruction prefix
  + first 4 self-loop samples). `va_037_sync` must reproduce these exactly; the
  delta vs `sim/bk10/golden.txt` is the with-/without-display overhead.
- `run.sh` — the regression (part of `make sim`).
