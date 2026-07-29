# Phase 3 reference oracle

Ground-truth cycle-accurate timing for the 037 arbiter (Phase 3).

- `va_037.v`  — vendored **reference** 1801VP1-037 model, from
  `~/projects/other/fpga/k1801/037/rtl/va_037.v` (do not edit; re-sync from
  upstream). Sim-only; the synth path uses the retimed `src/bus/va_037_sync.sv`.
- `tb_037.v`  — vendored upstream 037 unit testbench (netlist-equivalence oracle
  for the retimed core).
- `ref037_tb.v` — vm1 CPU + `va_037` + behavioural DRAM running the bk10 test
  program; RAM RPLY comes from the 037 (video cycle-stealing active).
- `golden_037.txt` / `golden_037_rom.txt` — reduced ground-truth cycle counts
  (unique instruction prefix + first 4 self-loop samples) **for the vendored
  NETLIST**. Generated ONLY from a reference run. The delta vs
  `sim/bk10/golden.txt` is the with-/without-display overhead.
- `golden_037_hw.txt` / `golden_037_hw_rom.txt` — **the SHIPPED machine**
  (Phase 9). Regenerate with `./run.sh --regen-hw`.
- `run.sh` — the regression (part of `make sim`), **fourteen legs**.

## Two golden sets (Phase 9) — read before touching either

The shipped 037 carries a deliberate, hardware-calibrated deviation from the
netlist: `va_037_sync`'s `GRANT_SETUP` window plus the board's D8:B RPLY flop
(`src/bus/bk_rply.sv`). Its authority is the seven real-BK-0011M tone legs of
`sim/grantfit`, **not** this netlist — which has been shown to reproduce *our*
numbers rather than silicon's (26.46/20.51 cyc against the real 31.7/21.4, with
no SDRAM in the loop), and whose fix was confirmed on hardware by the Babylona
and PALTST artefacts disappearing.

One pair could no longer serve both, so the split is explicit:

| | generated from | who must match it |
|---|---|---|
| `golden_037{,_rom}` | the **netlist** (`ref037_tb`) | `va_037_sync` **at `GRANT_SETUP=0`** |
| `golden_037_hw{,_rom}` | `ref037_sync_tb` at the **shipped** setting | every integration leg |

The retime guard did not weaken — it moved to the stock setting, where
`GRANT_SETUP=0` folds the window away and bypasses D8:B (one switch, see
`ref037_sync_tb.v`). Passing that leg additionally *proves* the parameter folds
away exactly, which is what makes the deviation reversible and measurable.

⚠️ **Never "fix" a `_hw` diff by regenerating from a netlist run.** At the
shipped setting the netlist is not the reference; silicon is. And the
warm-reset rule is unchanged: both passes diff against the same unchanged
golden, so **never regenerate any golden for a warm-reset change**.
