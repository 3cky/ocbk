# Phase 6 keyboard-controller contract oracle

Ground-truth bus contract for the BK keyboard controller (1801ВП1-014 at
177660–177663, vectors 060/0274).

- `vp_014.v` — vendored **reference gate netlist**, from
  `~/projects/other/fpga/k1801/014/rtl/vp_014.v` (do not edit; re-sync from
  upstream). Sim-only; the synth path uses the behavioral `src/peripheral/bk_kbd014.sv`.
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
- `ref014_beh_tb.v` — drives the behavioral `src/peripheral/bk_kbd014.sv` through the
  same scenario over the 16-bit shared Q-bus; must diff-match the same golden.
- `golden_014.txt` — committed netlist output. **Regenerate only from the
  netlist run**, never from the behavioral module. Netlist wins all disputes.
- `ref014_irq_ref_tb.v` / `ref014_irq_soc_tb.v` — the **interrupt-latency
  oracle** (reference-first): the `mem/gen_kbd_test.py` program (VIRQ 060 /
  0274 ISRs with code self-checks, a masked press with a fixed-count delay
  loop, a tb-driven nIRQ1 fixed pulse → HALT entry through the 160002
  vector; parks 001004 = success/stop, 001012 = fail) runs on the reference
  stack (vm1 + real va_037 + behavioural memory + the **netlist** with its
  matrix/RC debounce) and on the SoC stack (va_037_sync + qbus_mem +
  SDRAM model + behavioral bk_kbd014). Both reduced FETCH traces must match
  `golden_kbd.txt` (generated ONLY by the reference run). Key injections are
  anchored to the ARM-mailbox (000776) SYNC fall — a vm1-launched edge that
  lands on the identical CPU cycle in both runs; the SoC `P_DLY` recreates
  the reference press→VIRQ latency in whole clocks.
- `golden_kbd.txt` — committed reduced reference trace (park loop collapsed
  to 4 samples).
- `run.sh` — the regression (part of `make sim`).

## What the interrupt oracle pinned (2026-07-06)

- **N_KBD = N_IAK = 1** (qbus_pkg): the async 014 replies within the same
  CPU cycle as the strobe; bk_kbd014 fires at the detection FSM edge, and
  the 177660 **write** reply must be combinational (`wr_fast`) — the vm1
  launches DOUT from its falling-edge stage, half a cycle past anything the
  negedge FSM can register.
- The vm1's IAK data capture relies on read data **held past DIN release**
  (the upstream de0_tb1.v slave convention; bk_kbd014's S_REPLY does it).
  The netlist releases AD combinationally, so `ref014_irq_ref_tb.v` models
  the board reality with a bus-charge keeper on AD[7:0] (open-collector
  lines decay through pull-ups far slower than a CPU cycle).
- The netlist's async nIRQ is retimed onto the CPU rising edge by an
  external flop, as on the real board (bk0011m-sch: D11, К555ТМ9) — the
  same grid as bk_kbd014's posedge virq flop.
- The 1801ВМ1 IRQ1/HALT vector is **160002** (BkEmu TRAP_VECTOR_HALT; vm1
  vmux) and the vector PSW must carry **bit 8** (HALT mode) to mask a still-
  asserted nIRQ1 — the real BASIC ROM loads 0o100412 there; without it a
  held СТОП re-enters the handler forever.
- `qbus_mem`'s ROM/IO FSM must **stand down when the strobes release
  before its reply point**: the vm1 self-replies to 177700-177717 writes
  (the HALT entry's 177716 update) faster than N_ROM, and an unguarded late
  RPLY into the idle bus shifts the next cycle.

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
