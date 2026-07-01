# ocbk — BK-0010 / BK-0011M on the 1chipMSX / OneChipBook

Running the Soviet **Elektronika BK-0010/0011M** (PDP-11-class) as alternative
firmware on the OneChipBook board (Altera Cyclone I **EP1C12Q240C8**, Quartus II
11.0). See [ROADMAP.md](ROADMAP.md) for the full plan.

## Status: Phase 2 — BK RAM in SDRAM ✅

The `vm1` (1801ВМ1) core runs on the EP1C12 with **BK RAM (000000–077777) backed
by the board SDRAM** through the synthesizable `qbus_sdram` slave; ROM and I/O stay
on-chip. A small ROM-resident RAM-test program writes word and byte patterns and
verifies them back out of SDRAM. The deterministic, cycle-faithful RPLY timing of
Phase 1 is preserved: the SDRAM controller runs at 96.65 MHz while the wait-state
FSM still counts CPU cycles, and because `cpu_clk = sys_clk/32` the SDRAM latency
is fully hidden behind the fixed RPLY window. The cartridge-slot Q-bus seam stays a
disabled forward seam (`qbus_slot`, `SLOT_ENABLE=0`).

- Fits in **2149 / 12060 LEs (18%)**, **1 PLL**; timing closes (setup/hold/
  recovery/removal/min-pulse all positive).
- The SDRAM-path cosim reproduces correct word/byte read-back and a deterministic
  RAM RPLY latency; the independent `bk10` timing oracle stays green.

## Layout

```
src/cpu/        vendored vm1 core (1801ВМ1) + config + synth RAM stub
src/qbus_pkg.sv shared Q-bus decode / RPLY-latency constants
src/sdram_ctrl.sv vendored single-word SDR SDRAM controller (+byte-enable)
src/qbus_sdram.sv Q-bus RAM-in-SDRAM slave: deterministic RPLY front-end +
                ROM/IO on-chip + SDRAM datapath with a CDC request handshake
src/qbus_slot.sv cartridge-slot bridge (forward seam, SLOT_ENABLE=0)
src/ocbk_top.sv top level: PLL/clock tree (x9/2 = 96.65 MHz clk0 + extclk0 to
                pMemClk, 12.08 MHz dot, ~3.02 MHz anti-phase CPU clock) + reset
                (gated on SDRAM init_done) + CPU subsystem + liveness LEDs
mem/gen_mem.py  generates mem/ram_test.hex (the ROM-resident RAM-test program)
sim/bk10/       cycle-count oracle (bk10_tb.v + golden.txt + run.sh)
sim/sdram_model.sv  behavioural SDRAM model (sim only)
sim/qbus_sdram_tb.sv + run_sdram_cosim.sh  RAM-in-SDRAM datapath cosim
```

## Build & test

```
make sim       # simulation regressions (Icarus): bk10 oracle + SDRAM-path cosim
make           # Quartus build: map -> fit -> sta -> asm -> POF (into fw/)
make flash     # program EPCS4 via USB-Blaster (Active Serial)
```

Requires Icarus Verilog for `sim`, and Quartus II 11.0
(`/opt/altera/11.0/quartus`, override with `QUARTUS_HOME=`) for the FPGA build.

## On-board behaviour (LEDs)

- **Red power LED** — solid once the CPU reaches the **success** self-loop at
  `100072` (every word/byte RAM-test write verified back out of SDRAM).
- **pLed[7]** — system heartbeat off the PLL (FPGA configured / PLL locked).
- **pLed[6]** — SDRAM `init_done` (lit once the controller finished its init).
- **pLed[5:0]** — top bits of a transaction counter (move while the CPU executes;
  heartbeat blinking with these frozen would indicate the CPU is hung).

## Known items (for later phases)

- **Open-collector RPLY combinational loop (benign).** RPLY is a wired-AND of two
  open-drain drivers (the `vm1` internal-register reply + `qbus_sdram`), which
  Quartus flags as a 4-node combinational loop. It is mutually exclusive by
  address and cosim-validated; the clean fix (explicit wired-AND via `vm1_qbus`'s
  split `rply_in`/`rply_out`) lands with peripheral/arbitration work (Phase 6).
- **Register file = flip-flops** (`CONFIG_VM1_CORE_REG_USES_RAM=0`); the unused
  `vm1_vcram` RAM is a synth stub (`src/cpu/vm1_vcram_syn.v`). RAM mode would
  need a Cyclone-targeted dual-port regenerate.
- **SYNC address latch** is transparent on the bus strobe (as real bus hardware);
  the SDC declares and cuts that slow clock.
- **WTBT is dual-purpose** on the Q-bus: asserted at SYNC time it flags a *write*
  cycle, asserted at DOUT time it flags a *byte* op. `qbus_sdram` samples the byte
  indicator live at the write point (not the SYNC-latched value) — getting this
  wrong silently corrupts word writes (only timing, never data, was checked before).
- **CDC:** the wait-state FSM (`cpu_clk`) and the SDRAM controller (`sys_clk`)
  exchange data only through a request-toggle handshake + synchronisers; the SDC
  false-paths both directions. Read data is sampled at the (fixed) RPLY point,
  guaranteed stable because an SDRAM access finishes well within one CPU cycle.
- Full BK MONITOR/BASIC ROM and the video path arrive in Phases 3–5; the ROM region
  beyond the small RAM-test program is currently unmapped (reads return 0).
