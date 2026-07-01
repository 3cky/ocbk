# CLAUDE.md

Guidance for working in this repo. Keep it current as the project grows.

## What this is

`ocbk` runs the Soviet **Elektronika BK-0010 / BK-0011M** (PDP-11-class) as
alternative firmware on the 1chipMSX / OneChipBook board (Altera Cyclone I
**EP1C12Q240C8**, Quartus II 11.0). The headline goal is **cycle-accurate** CPU
behaviour.

**Read [ROADMAP.md](ROADMAP.md) first** — it is the authoritative implementation
plan: the source building blocks, the validated platform constraints, the settled
clock tree, and the phase-by-phase milestones. Every change should map to a phase
there; update ROADMAP.md when scope or status changes. **Phases 1 (CPU bring-up)
and 2 (BK RAM in SDRAM) are done**; see README.md for the current result.

## Build & test

```
make sim       # Icarus regressions: bk10 cycle-count oracle + slave cosim
make           # Quartus: map -> fit -> sta -> asm -> POF (parked in fw/)
make flash     # program EPCS4 over USB-Blaster (Active Serial; JTAG TDO not wired)
make clean     # remove build intermediates
```

`make sim` needs Icarus Verilog; the FPGA build needs Quartus II 11.0 at
`/opt/altera/11.0/quartus` (override `QUARTUS_HOME=`). Run individual Quartus
stages directly when iterating, e.g. `quartus_map ocbk.qpf`, `quartus_sta ocbk.qpf`.

## Verification discipline (do not skip)

Cycle accuracy is the whole point. Two oracles must stay green:
- `sim/bk10/run.sh` — the upstream timing testbench vs `sim/bk10/golden.txt`
  (the CPU core's per-instruction cycle counts). Independent of the SDRAM work.
- `sim/run_sdram_cosim.sh` — the **synthesizable** `qbus_sdram` slave + its
  `sdram_ctrl` against a behavioural SDRAM model, running the ROM RAM-test program.
  Checks datapath correctness (word/byte read-back) *and* that the RAM RPLY latency
  is deterministic (SDRAM hidden).

Any change touching the core, the Q-bus, memory, or clocking must keep both
passing. When tuning bus/RPLY timing, trace the **reference** waveform first
(instrument `cpu11/vm1/.../sim/bk10/bk10_tb.v`) — that is ground truth. Note the
golden checks *timing*, not write data — only the SDRAM cosim verifies RAM values.

## Architecture & conventions

- The `vm1` (1801ВМ1) core is **vendored** under `src/cpu/` from
  `~/projects/other/fpga/cpu11/vm1/hdl/syn`. Don't edit it casually; re-sync from
  upstream if needed. Core config is via global Verilog macros (see below).
- The Q-bus is **inverted / active-low / open-collector**, carried as shared
  tri-state nets at the `cpu_test` level (no SystemVerilog `interface` — neither
  Quartus 11.0 nor Icarus handle tri-state interface members reliably). Every
  participant (core, `qbus_sdram`, `qbus_slot`) drives `x ? 1'b0 : 1'bZ` /
  `ad_n = ena ? ~out : 1'bZ`.
- Clocking: **one PLL only** (board constraint — the PIN_28 crystal feeds a single
  PLL). New clocks must be a ÷N of the ×9 VCO or a fabric clock-enable; the SDRAM
  chip clock (`pMemClk`) is the PLL's `extclk0` at the same 96.65 MHz as the
  internal `clk0`/`sys_clk` (phase-matched, like esemsx3's c1/e0). The clock tree
  lives in `src/ocbk_top.sv` (no separate `cpu_clk.sv`).
- Cartridge-slot Q-bus is a **forward seam**: `src/qbus_slot.sv`, default
  `SLOT_ENABLE=0` (drives nothing, slot pins stay reserved-tristated). The full
  slot pin map lives commented in `ocbk_common.qsf`. Real BK hardware needs an
  external 5V↔3.3V level-shifter (Cyclone I is not 5V-tolerant).
- On-chip RAM is tight (~239 Kbit). BK RAM (000000–077777) lives in the board
  **SDRAM** via `qbus_sdram` (Phase 2 done); only ROM + I/O stay on-chip. The
  vendored `src/sdram_ctrl.sv` (from `ocb-test`) gained a 2-bit `cmd_be` byte mask
  for the BK's byte writes — re-sync from upstream but keep that hook.

## Gotchas (learned the hard way)

- **Quartus II 11.0 SystemVerilog is limited.** No `import pkg::*;` in a module
  header (put it in the body). It won't propagate `` `define `` across separately
  listed Verilog files, so the core's config selectors are set as global
  `VERILOG_MACRO` in `ocbk_common.qsf` (mirroring `src/cpu/vm1_config.v`, which the
  sim flow includes directly; the macros are `ifndef`-guarded to stay idempotent).
- **`vm1_simlib.v` is sim-only** (dual-write-port behavioural RAM → "multiple
  constant drivers" in Quartus). The FF register-file path
  (`CONFIG_VM1_CORE_REG_USES_RAM=0`) leaves that RAM unused, so the Quartus build
  uses the tied-off stub `src/cpu/vm1_vcram_syn.v` instead.
- **Open-collector RPLY combinational loop** — Quartus flags a benign 4-node loop
  where the CPU's internal-register reply and the slave wire-AND onto RPLY. Cosim-
  validated; clean fix (explicit wired-AND via `vm1_qbus`'s split `rply_in`/
  `rply_out`) deferred to peripheral work (Phase 6).
- The `qbus_sdram` address latch is **transparent on the SYNC strobe** (as real bus
  hardware), so SYNC is a slow logic-derived clock; `ocbk_constrains.sdc` declares
  and cuts it. SDC node names use Quartus `entity:inst|...` form — verify with a
  `quartus_sta -t` script (`get_registers` / `get_pins`) before trusting a pattern.
- **WTBT is dual-purpose** on the Q-bus: at SYNC time it flags a *write* cycle, at
  DOUT time it flags a *byte* op. `qbus_sdram` samples the byte indicator live at
  the write point — do **not** reuse the SYNC-latched value for byte masking (that
  corrupts word writes; the cycle-count oracles never check write data, so it slips
  through sim silently — only the SDRAM cosim verifies values).
- **CDC for SDRAM:** the wait-state FSM (`cpu_clk`) launches an SDRAM access via a
  request-*toggle* into the `sys_clk` adapter; read data is sampled back at the
  fixed RPLY point. This is safe while a worst-case access (~200 ns, incl. a
  refresh collision) finishes inside the RPLY window = (N_RAM-2) CPU clocks — ~3x
  margin at 3.02 MHz, ~1.6x at 6 MHz turbo, breaking only above ~10 MHz CPU clock
  (NOT "one CPU cycle" — the window is ~2 cycles). There is currently **no
  interlock**: a margin violation would latch stale data rather than extend RPLY,
  so re-validate at the 4/6 MHz rates (Phase 7) or add a done-gate first.
  `ocbk_constrains.sdc` false-paths both directions
  of the `cpu_clk`↔`sys_clk` crossing. Reset is gated on SDRAM `init_done` (CPU held
  in reset until the controller's ~200 µs init completes).
- `mem/ram_test.hex` is **generated** by `mem/gen_mem.py` (the single source of
  truth for the ROM-resident RAM-test program; word 0 = BK address 100000) and is
  gitignored — `make` regenerates it.

## Temp files

Use the session scratchpad for throwaway scripts/sims, never the repo root.
