# CLAUDE.md

`ocbk` runs the Soviet **Elektronika BK-0010 / BK-0011M** (PDP-11-class) as
alternative firmware on the 1chipMSX / OneChipBook (Altera Cyclone I
**EP1C12Q240C8**, Quartus II 11.0). The headline goal is **cycle-accurate** CPU
behaviour.

**Every phase is done and confirmed on hardware** — README.md has the
user-facing result, `doc/dev/platform.md` the phase table. Two standing rules
come out of that history: **a debug feature does not ship**, and **features
develop on branches; `main` only takes what is shippable.**

This file is the index and the rule list. The detail lives in `doc/dev/`, one
file per subsystem; **read the relevant file before changing that subsystem** —
each carries measurements, calibration values and dead ends that must not be
retried.

**Keep it that way.** A new finding, measurement or design rule goes in the
`doc/dev/` file for its subsystem, however important it is. This file grows only
when a new *non-negotiable* rule or a new subsystem file appears — every line
here is loaded into context for every task, including the ones it has nothing
to do with.

## Read this first

| Before touching | Read |
|---|---|
| anything — clocking, memory layout, where a new file goes | [doc/dev/platform.md](doc/dev/platform.md) — envelope, clock tree, SDRAM map, full source tree, BK-0011M memory model, phase table |
| any RTL at all (what must stay green, and why) | [doc/dev/verification.md](doc/dev/verification.md) — the oracle catalogue |
| `src/sys/`, the reset sequencer, DIP/LED latches, `ram_init` | [doc/dev/clocking-reset.md](doc/dev/clocking-reset.md) — clocking, soft reset, DIP/LED map, turbo mode |
| `src/cpu/`, `src/bus/`, `src/sdram/` | [doc/dev/bus-memory.md](doc/dev/bus-memory.md) — Q-bus conventions, ROM-in-SDRAM, `mem_mapper`, the 037 grant rule and the beam-race fix, arbiter ports |
| `mem_mapper`'s SMK stage, `smk_ide`, `sd_backend` | [doc/dev/smk512.md](doc/dev/smk512.md) — SMK512 RAM/BIOS/IDE/SD, `N_EXT` |
| `src/video/`, `bk_evnt` | [doc/dev/video.md](doc/dev/video.md) — framebuffer conventions, palette, 177662, EVNT/IRQ2 |
| `src/audio/`, the CMT jack | [doc/dev/audio.md](doc/dev/audio.md) — mixer/DAC stage, TurboSound, tape |
| `src/peripheral/` (keyboard, joysticks), `qbus_slot` | [doc/dev/peripherals.md](doc/dev/peripherals.md) |
| Quartus / Icarus / bus behaviour that surprised us once | [doc/dev/gotchas.md](doc/dev/gotchas.md) |
| planning new work | [doc/dev/open-items.md](doc/dev/open-items.md) — what is deferred and why |

Per-oracle contracts live next to their runner: `sim/ref037/`, `sim/ref014/`,
`sim/evnt/`, `sim/audio/`, `sim/ts/`, `sim/grantfit/` each have a `README.md`.

RTL and testbench comments cite rules by name ("the CLAUDE.md RMW rule", "the
SEED-3 lesson", "the `model_bk11_q` idiom"). Those passages now live in
`doc/dev/` — grep the quoted phrase.

## Non-negotiable rules

Each of these has cost a build, a boot or a day. The named file explains why.

- **Never add a second PLL.** The crystal can feed only one; every clock is a
  ÷N of the single ×9 VCO or a fabric clock-enable. → platform
- **Never reach for an SDC exception, and never change FITTER SEED 3.** An
  exception is a *fitter input* and has broken the SEED-3 boot with STA still
  clean. Fix timing **structurally**: re-register a quasi-static high-fanout
  signal locally, and keep translate outputs out of **pad-OE and register-enable
  cones**. → gotchas
- **After any increment, budget for an STA chase somewhere else in the design.**
  It is placement-fragile at 68 % LE: added LEs have taken untouched modules
  from +0.481 to −0.414 ns. → gotchas
- **All `make sim` oracles must stay green** for any change touching the core,
  Q-bus, memory, video, clocking or audio. → verification
- **Goldens regenerate ONLY from reference-netlist runs.** Never regenerate a
  `_hw` golden from a netlist run, and never regenerate any golden for a
  warm-reset change — a warm reset must be cycle-identical to a cold boot.
  → verification
- **`ocbk_common.qsf` lists every file in compile order** — not directory order;
  do not shuffle it, and keep `ocbk.f` in sync. → platform
- **BK peripherals reset on `init_n` (nINIT)**, never `dclo_n` — the RESET
  instruction must reset them. The DCLO-only exceptions are enumerated
  (map / 177662 / spk / `stop_block` / IDE / `ram_init`); the ЗАГЛ/СТР and
  РУС/ЛАТ triggers key off `aclo_n`. → clocking-reset
- **Never leave a lone Z-idle tri-state driving internal logic.** Cyclone I has
  no internal tri-state: Quartus ties the idle Z to 0, i.e. stuck-asserted, and
  every sim still passes (the `virq_n` trap). A lone open-collector source must
  be push-pull. The only intentional pad tri-states are `pDac_SR` and the SD
  pins. → gotchas
- **The references, in order:** the vendored netlists (`va_037.v`, `vp_014.v`,
  the `ym2149` reference) win every dispute with our models; **BkEmu** is the
  authority on BK register/software semantics; **MiSTer** wins on 177662
  specifically; `doc/bk0011m.sch` is the real board. → platform
- **Sound devices live in `src/audio/`** (`audio_*` = generic infra, `bk_*` =
  BK-specific); `src/peripheral/` is for non-audio peripherals. → audio
- **Keep the marked local hooks in vendored files** when re-syncing: `vm1.v`'s
  push-pull `pin_sel_n`, `sdram_ctrl`'s `cmd_be` byte mask. `vm1_tve.v` is
  deliberately left stock — a tried-and-rejected hook. → bus-memory
- **Keep RMW (DATIO) coverage in any new bus-path oracle.** A slave FSM must
  return to idle on strobes-idle, never on SYNC-rise; cycle-count goldens cannot
  see the difference. → gotchas
- **Temp files go in the session scratchpad, never the repo root.**

## The envelope

The constraints that shape every decision; details and the reasoning in
`doc/dev/platform.md`.

- **One PLL**, ×9 VCO (193.3 MHz), ceiling ≈400 MHz on the −8 part.

| Output | Divide | Freq | Use |
|--------|--------|------|-----|
| clk0 | ÷2 | **96.65 MHz** | `sys_clk`: SDRAM controller + the chip clock (`extclk0` → `pMemClk`, phase-matched) |
| clk1 | ÷3 | **64.43 MHz** | `pix_clk`: 1024×768@60 readout |
| (enable) | 96.65 ÷8 | **12.08 MHz** | BK dot clock; 037 CLKIN = ÷2 = 6.04 MHz |

- **CPU clock** = a fabric divider of `sys_clk` (`src/sys/cpu_clkgen.sv`):
  **/32 = 3.02 MHz (BK-0010), /24 = 4.03 MHz (BK-0011M), /16 = 6.04 MHz
  (turbo)**. All integer ratios, so the design is internally cycle-exact; the
  absolute rate is **+0.674 %** with the CLKIN:CPU ratio preserved exactly —
  the design's only known sub-1 % error against real hardware, unfixable short
  of a different crystal.
- **On-chip RAM ≈ 239 Kbit**, so BK RAM *and* ROM live in the board SDRAM. That
  is the root reason the arbiter / done-gate machinery exists.
- **The panel is standard-VESA-only**, so the output is 1024×768@60 and the
  48.83→60 Hz gap is bridged in the framebuffer.
- **Current fit: 8,518 / 12,060 LE (71 %)**, 3/52 M4K, 110/173 pins, one PLL,
  sys_clk setup +0.254 ns, TNS 0. Still thin, and it moves with placement: the
  Phase-12 Covox left it at +0.102 on the `ram_init|filling` /
  `mem_mapper|mon_en` cone and the arming fix bought it back for +33 LE; the
  joysticks then drove it to **−0.121** on `sdram_ctrl|wait_cnt → s_addr` — the
  Phase-7 no-boot cone — and the `wait_zero` flop bought it back.
  → audio, gotchas

## Source tree

Directory level only; the full per-file tree is in `doc/dev/platform.md`.

```
src/ocbk_top.sv     top: PLL, resets, DIP latches, LEDs, the sibling peripherals
src/qbus_pkg.sv     shared Q-bus decode + the RPLY-latency constants (N_*)
src/cpu/            vendored vm1 core (1801ВМ1) + config + the synth vcram stub
src/bus/            Q-bus front end, RPLY ownership, address translation (037)
src/sdram/          the SDRAM datapath, arbiter, ram_init, the EPCS loader
src/video/          037 fetch -> palette -> FB -> 1024x768@60 scan-out
src/peripheral/     keyboard, EVNT, SMK IDE + SD backend
src/audio/          mixer, noise-shaped DAC stage, sound devices (TurboSound)
src/sys/            clocking / CPU-rate control (cpu_clkgen, turbo_ctl)
mem/                ROM images, the generators, the boot-blob builder
sim/                the oracles (see doc/dev/verification.md)
test/               tone programs (.mac/.bin/.wav) — hardware timing measurements
doc/                bk0011m.sch, smk64.mac; doc/dev/ = this documentation
```

`ocbk_common.qsf` lists every file one per line **in compile order** — that is
not the directory order and must not be shuffled; `ocbk.f` (the slang/verilator
filelist) mirrors the same set and must be kept in sync with it.

Keep comments concise but precise and clear. Update comments every time the
corresponding code is changed. Avoid using all-uppercase in comments for emphasis
except situations where it is absolutely required.

## Build & test

```
make sim       # Icarus regressions: bk10 cycle-count oracle + slave cosim
make           # Quartus: map -> fit -> sta -> asm -> POF (ocbk.pof in the project root)
make flash     # program EPCS4 over USB-Blaster (Active Serial; JTAG TDO not wired)
make clean     # remove build intermediates
```

`make sim` needs Icarus Verilog; the FPGA build needs Quartus II 11.0 at
`/opt/altera/11.0/quartus` (override `QUARTUS_HOME=`). Run individual Quartus
stages directly when iterating, e.g. `quartus_map ocbk.qpf`, `quartus_sta ocbk.qpf`.

Some oracles are **slow and outside `make sim`** — `sim/smktime`, `sim/vregtime`,
`sim/grantfit`, `sim/video/run_draw_check.sh`, `sim/run_boot_check.sh`. Run them
when the bullet in `doc/dev/verification.md` says to.

## Temp files

Use the session scratchpad for throwaway scripts/sims, never the repo root.
