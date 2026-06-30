# ocbk — BK-0010 / BK-0011M on the 1chipMSX / OneChipBook

Running the Soviet **Elektronika BK-0010/0011M** (PDP-11-class) as alternative
firmware on the OneChipBook board (Altera Cyclone I **EP1C12Q240C8**, Quartus II
11.0). See [ROADMAP.md](ROADMAP.md) for the full plan.

## Status: Phase 1 — CPU bring-up ✅

The `vm1` (1801ВМ1) core runs standalone on the EP1C12, executing the BK-0010
addressing-mode test program from on-chip block RAM through a deterministic,
cycle-faithful Q-bus memory slave. Cartridge-slot Q-bus exposure is wired as a
disabled forward seam (`qbus_slot`, `SLOT_ENABLE=0`) so real BK hardware can be
attached in a later phase without a refactor.

- Fits in **1817 / 12060 LEs (15%)**, **32 Kbit RAM**, **1 PLL**; timing closes
  (setup/hold/recovery/removal/min-pulse all positive).
- Per-instruction cycle counts match the reference `bk10` timing testbench
  exactly, in both the core oracle and the synthesizable-slave cosim.

## Layout

```
src/cpu/        vendored vm1 core (1801ВМ1) + config + synth RAM stub
src/qbus_pkg.sv shared Q-bus decode / RPLY-latency constants
src/qbus_mem.sv synthesizable Q-bus memory slave (deterministic RPLY)
src/qbus_slot.sv cartridge-slot bridge (forward seam, SLOT_ENABLE=0)
src/ocbk_top.sv top level: PLL/clock tree (x9/2 = 96.65 MHz, 12.08 MHz dot,
                ~3.02 MHz anti-phase CPU clock) + reset + CPU subsystem
                (core + slave + slot seam) + liveness LEDs
mem/gen_mem.py  generates mem/bk10_prog.hex (the RAM test program)
sim/bk10/       cycle-count oracle (bk10_tb.v + golden.txt + run.sh)
sim/qbus_mem_tb.sv + run_cosim.sh  synthesizable-slave cosim vs golden
```

## Build & test

```
make sim       # simulation regressions (Icarus): bk10 oracle + slave cosim
make           # Quartus build: map -> fit -> sta -> asm -> POF (into fw/)
make flash     # program EPCS4 via USB-Blaster (Active Serial)
```

Requires Icarus Verilog for `sim`, and Quartus II 11.0
(`/opt/altera/11.0/quartus`, override with `QUARTUS_HOME=`) for the FPGA build.

## On-board behaviour (LEDs)

- **Red power LED** — solid once the CPU reaches the `BR .` self-loop at `001076`
  (booted from the ROM bootstrap and ran the whole test program).
- **pLed[7]** — system heartbeat off the PLL (FPGA configured / PLL locked).
- **pLed[6:0]** — top bits of a fetch counter (move while the CPU executes;
  `pLed[7]` blinking with `pLed[6:0]` frozen would indicate the CPU is hung).

## Known items (for later phases)

- **Open-collector RPLY combinational loop (benign).** RPLY is a wired-AND of two
  open-drain drivers (the `vm1` internal-register reply + `qbus_mem`), which
  Quartus flags as a 4-node combinational loop. It is mutually exclusive by
  address and cosim-validated; the clean fix (explicit wired-AND via `vm1_qbus`'s
  split `rply_in`/`rply_out`) lands with peripheral/arbitration work (Phase 6).
- **Register file = flip-flops** (`CONFIG_VM1_CORE_REG_USES_RAM=0`); the unused
  `vm1_vcram` RAM is a synth stub (`src/cpu/vm1_vcram_syn.v`). RAM mode would
  need a Cyclone-targeted dual-port regenerate.
- **SYNC address latch** is transparent on the bus strobe (as real bus hardware);
  the SDC declares and cuts that slow clock.
- On-chip RAM is sized to the test program (2K words); full BK RAM moves to SDRAM
  in Phase 2.
