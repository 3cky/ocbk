# Phase 6 keyboard-controller contract oracle

Ground-truth bus contract for the BK keyboard controller (1801ВП1-014 at
177660–177663, vectors 060/0274).

- `vp_014.v` — vendored **reference gate netlist**, from
  `~/projects/other/fpga/k1801/014/rtl/vp_014.v` (do not edit; re-sync from
  upstream). Sim-only; the synth path uses the behavioral `src/bk_kbd014.sv`.
- `lib_1801.v` — vendored 1801-series cell library the netlist instantiates,
  from `~/projects/other/fpga/k1801/lib/rtl/lib_1801.v`.
- `tb_014.v` — vendored upstream unit testbench (kept for reference: its
  matrix scan is where the position→code map in `ref014_scenario.v` comes
  from; the matrix/RC-debounce model in `ref014_tb.v` is adapted from it).
- `ref014_scenario.v` — the shared scenario: a sequence of `t_*` task calls
  included by both testbenches. The task `$display` formats are the contract.
- `ref014_tb.v` — drives the **netlist** through the scenario (matrix + RC
  model, vm1-shaped bus tasks: IAK = DIN+IAKI with no SYNC, DATIO RMW under
  one SYNC, nCS latched at SYNC fall). Its output IS `golden_014.txt`.
- `ref014_beh_tb.v` — drives the behavioral `src/bk_kbd014.sv` through the
  same scenario over the 16-bit shared Q-bus; must diff-match the same golden.
- `golden_014.txt` — committed netlist output. **Regenerate only from the
  netlist run**, never from the behavioral module. Netlist wins all disputes.
- `run.sh` — the regression (part of `make sim`).

## The netlist-pinned contract (probe evidence, 2026-07-06)

- 177660: bit7 = ready (RO), bit6 = VIRQ mask (RW, 1 = disabled; INIT/cold
  value 0o100). Other write bits ignored.
- 177662 read = `{1'b0, code[6:0]}` — **there is NO АР2 flag in bit7**
  (probed before and after IAK; BkEmu also masks `& 0177` on read, MiSTer
  never sets it). АР2 reaches software only through the vector choice.
  The read clears ready AND a pending (un-IAK'd) request trigger.
- **177662 write: the chip does NOT reply → bus timeout** (trap 4 on a real
  BK; MiSTer decodes 662 as read-only too).
- The code register **re-latches on every accepted press**, ready or not,
  and is NOT cleared by INIT (stale code readable after INIT).
- Press with ready clear = *delivery*: ready=1 + request trigger=1. The
  trigger sets even when masked (IEN gates only the pin) → **unmasking a
  pending trigger retro-fires the VIRQ pin**.
- Press with ready set = *queued*: when a 662 read clears ready and that key
  is **still held**, the chip re-delivers the (re-latched) code — ready and
  trigger set again. Releasing the key before the read cancels the queued
  delivery. A delivered press never re-fires while held (no typematic).
- IAK clears the trigger only; ready survives. IAK with no pending trigger,
  or with a **masked** trigger, does not reply (CPU vector timeout).
- Vector = 0274 when the АР2 (EC2 pin) modifier is held at press time or the
  key is an "autoar2" key (control codes, e.g. 0013); else 060.
- nCS (the 037 nBS) is latched inside the chip at SYNC fall; deasserting it
  mid-cycle does not abort the transaction; without it at SYNC fall the chip
  ignores the cycle entirely.
