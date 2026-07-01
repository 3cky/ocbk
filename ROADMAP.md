# BK-0010 / BK-0011M on the 1chipMSX — Implementation Roadmap

Goal: run **Elektronika BK-0010 / BK-0011M** (Soviet PDP-11-class home computers) as
alternative firmware on the **1chipMSX / OneChipBook** board, with **cycle-accurate CPU
behaviour** and faithful screen output. Target device: **Altera Cyclone I
EP1C12Q240C8**, Quartus II 11.0. This document is the implementation plan.

---

## 1. Source building blocks (already on disk)

| Block | Location | Notes |
|-------|----------|-------|
| **1801ВМ1 CPU** (BK0010 & BK0011M) | `~/projects/other/fpga/cpu11/vm1/hdl/syn` | Synchronous, gate-accurate reverse-engineered model. `vm1.v`, `vm1_qbus.v`; already has a `sim/bk10` timing testbench. No hardware multiply needed (1801ВМ1 has no EIS) — fine, Cyclone I has no multipliers. |
| **1801ВП1-037** memory arbiter + video controller | `~/projects/other/fpga/k1801/037/rtl` | `va_037.v` (refactored), `vp_037.v` (netlist). CLC = 6 MHz, pixel = 12 MHz (CLKIN = pixel/2). Generates К565РУ5 DRAM control + video fetch + sync; **must be retargeted to SDRAM**. |
| **Test harness** | `~/projects/other/fpga/ocb-test` | SystemVerilog. Working VGA + SDRAM + clocking validated here. |
| **Toolchain reference** | `~/projects/other/fpga/ocm-pld-dev/esemsx3` | Pin map, build flow, SDRAM controller shape. |

---

## 2. Platform constraints (validated on hardware)

These are hard facts established during bring-up — design within them:

- **One usable PLL.** The 21.47727 MHz crystal (PIN_28) can feed only ONE PLL. *Every*
  clock must come from a single VCO via output counters. (Two-PLL designs are rejected:
  "input pin cannot feed inclk ports of more than 1 PLL".)
- **PLL VCO ceiling ≈ 400 MHz** on the −8 part. Coprime ratios needing a higher VCO fail.
- **On-chip RAM ≈ 26 KB** (239,616 bits). BK0010's 32 KB RAM alone exceeds it, so **BK RAM
  lives in the board SDRAM**, not block RAM. (BK0011M's 128 KB likewise.)
- **Display is standard-VESA-only (≥~60 Hz).** The 1024×768 panel matches input by
  (line-rate, total-lines) against a VESA table; native BK 48.8 Hz full-screen is mis-
  detected ("not supported"). → Output **1024×768@60** and bridge the 48.8→60 gap in a
  framebuffer. A judder-free native-48.8 path would require a different display
  (multisync CRT on analog RGB, or an OSSC-class scaler).

### Settled clock tree — single ×9 VCO (193.3 MHz)

| Output | Divide | Freq | Use |
|--------|--------|------|-----|
| clk0 | ÷2 | **96.65 MHz** | SDRAM controller + chip (extclk) |
| clk1 | ÷3 | **64.43 MHz** | 1024×768@60 video readout |
| (enable) | 96.65 ÷8 | **12.08 MHz** | BK dot clock (CLC = ÷2 → 6.04; CPU = ÷4/÷3/÷2) |
| (alt) | ÷8 | 24.16 MHz | only if a native-rate scan-doubler path is ever used |

BK CPU enables off the 12.08 MHz dot: ÷4 → 3.02 MHz (BK0010), ÷3 → 4.03 MHz (BK0011M),
÷2 → 6.04 MHz (turbo). All integer-ratio → internally cycle-exact; absolute rate +0.6%.

---

## 3. Target architecture

```
                       ┌──────────────────────────────────────────┐
   21.477 MHz xtal ──► │ single PLL (×9 VCO): 96.65 / 64.43 MHz     │
                       └──────────────────────────────────────────┘
                          │ 96.65 (sys/SDRAM)        │ 64.43 (pixel)
                          ▼                          ▼
   ┌─────────┐  Q-bus  ┌──────────────┐  SDRAM   ┌──────────────────┐   ┌────────┐
   │ vm1 CPU │◄───────►│ 037-derived   │◄────────►│ SDRAM controller │◄─►│ SDRAM  │
   │ 1801ВМ1 │ sync/   │ arbiter +     │  reqs    │ (BK RAM + ROM +  │   │ 32 MB  │
   │ @~3-6MHz│ din/dout│ video addr +  │          │  framebuffer)    │   └────────┘
   └─────────┘ /rply   │ wait-states   │          └──────────────────┘
        ▲              └──────┬────────┘                   │ pixel rows
        │ IRQ/timer           │ BK video page                ▼
   ┌────┴─────┐               ▼                     ┌──────────────────┐   RGB DAC
   │ peripherals│      ┌──────────────┐  line     │ ×2/×3 upscaler +  │──►+ HS/VS
   │ PS/2 kbd,  │      │ BK pixel     │──buf────►  │ 1024×768@60 timing│   (full screen)
   │ tape/audio,│      │ decode (mono │           └──────────────────┘
   │ timer      │      │ /4-colour)   │
   └────────────┘      └──────────────┘
```

Key signal preserved for cycle accuracy: the 037's **RPLY / wait-state timing** must be
reproduced in the 12.08 MHz BK domain so the CPU stalls during video fetch exactly as on
real hardware ("screen slows the CPU"). The SDRAM is far faster than BK's bus, so the
contention must be *modelled deliberately*, not left to emerge.

---

## 4. Phases

Each phase ends with a concrete, testable milestone.

### Phase 0 — Platform validation ✅ DONE Built/validated in `ocb-test`.
- Clocking (single ×9 VCO), SDRAM BIST, VGA output, display bring-up.
- **Done:** 1024×768@60 displays full-screen; SDRAM passes BIST at 96.65 MHz; one-PLL
  tree fits and closes timing.

### Phase 1 — CPU bring-up ✅ DONE
- Bring `vm1` (1801ВМ1) up standalone on EP1C12 (currently only fitted for Cyclone III/DE0).
- Wrap its Q-bus (`sync/din/dout/wtbt/rply`, inverted `ad[15:0]`, `dclo/aclo` reset).
- Port the `sim/bk10` timing methodology; confirm per-instruction cycle counts.
- **Milestone:** CPU executes from a block-RAM test program; instruction timing matches
  the reference cycle counts.

### Phase 2 — Memory subsystem (BK RAM in SDRAM) ✅ DONE
- Q-bus ⇄ SDRAM bridge (`src/qbus_sdram.sv` + vendored `src/sdram_ctrl.sv`): RAM
  `000000–077777` now lives in the board SDRAM; ROM `100000–177577` + I/O
  `177600–177777` stay on-chip. Byte-granular writes (DQM) supported.
- Deterministic **wait-state FSM** in the CPU-clock domain keeps RPLY at the fixed
  N_RAM/N_ROM counts; the SDRAM controller runs in the 96.65 MHz domain and is
  reached via a request-toggle CDC handshake. Because `cpu_clk = sys_clk/32`, an
  SDRAM access completes far inside one CPU cycle, so its latency is fully hidden.
- ROM image: a small ROM-resident **RAM-test program** (`mem/gen_mem.py`) rather
  than the full MONITOR — word + byte writes are read back and verified from SDRAM.
- **Done:** fits **2149 / 12060 LEs (18 %)**, 1 PLL; timing closes (all slacks
  positive). Cosim (`sim/run_sdram_cosim.sh`) proves the datapath correct and the
  RAM RPLY latency deterministic; on-board the RAM-test parks in its success loop.
  *(Full BK MONITOR ROM deferred — it needs the video path, Phases 3–5.)*

### Phase 3 — 037 arbiter / video address generation
- Retarget `va_037`/`vp_037` logic from К565РУ5 strobes to SDRAM requests, keeping the
  decode (`nE`/`nBS`), the scroll register (`177664`), video address counters (СТА/СС),
  and **arbitration timing**.
- Reproduce the CPU/video cycle-stealing so RPLY timing tracks raster position.
- **Milestone:** CPU + 037 share SDRAM; cycle counts match real BK *with display active*
  (the with/without-display timing delta is correct).

### Phase 4 — Video output pipeline (1024×768@60)
- Decode BK video page: 512×256 monochrome and 256×256 4-colour, honouring vertical
  scroll.
- Framebuffer in SDRAM (BK writes at 48.8 Hz; readout at 60 Hz, double-buffered to bound
  tearing) **or** direct line-buffered read.
- **×2 horizontal / ×3 vertical** integer upscale → exact 1024×768 fill, correct 2:3 BK
  pixel shape. Drive the validated 64.43 MHz / 1024×768@60 timing.
- **Milestone:** BK framebuffer contents shown full-screen, borderless, correctly scaled.

### Phase 5 — SoC integration & boot
- Wire vm1 + 037 + SDRAM + ROM + reset/IPL into one top.
- **Milestone:** cold-boots to the BK MONITOR prompt on screen.

### Phase 6 — Peripherals
- PS/2 keyboard → BK keyboard matrix at `177660–177663` (037 decodes `nBS`).
- Tape/audio: 1-bit speaker + covox via the board audio PWM/DAC; tape in/out.
- System timer + interrupt wiring (vector/IRQ on the Q-bus).
- **Milestone:** interactive — type, run BASIC, hear sound.

### Phase 7 — BK-0011M mode
- 128 KB banked RAM, two video pages, 4 MHz CPU, page/control registers, MMU windows.
- Runtime model select (BK0010 ↔ BK0011M) via DIP/menu.
- **Milestone:** BK-0011M software boots and runs.

### Phase 8 — Storage
- SD card (reuse esemsx3 SD/SPI infrastructure) for disk images / file loading;
  emulate the BK FDD / disk controller as software sees it.
- **Milestone:** load and run programs/disks from SD.

### Phase 9 — Fidelity & polish
- Cycle-accuracy regression vs reference traces; turbo (6 MHz) mode.
- Optional CRT effects (scanline dim/gamma) in the upscaler.
- Config: DIP/menu for model, turbo, video filter.
- **Milestone:** validated, configurable, documented release.

---

## 5. Cross-cutting concerns

- **Cycle accuracy** is the headline goal: `vm1` is gate-faithful, so the risk is the
  *memory/arbitration* side — reproducing the 037's RPLY/wait timing on a much faster
  SDRAM. Keep all wait-states in the 12.08 MHz domain; validate against the `bk10`
  methodology at every phase that touches memory (2, 3, 7).
- **One-PLL discipline:** never add a second PLL. New clocks must be ÷N of the ×9 VCO or
  fabric clock-enables.
- **Resource budget:** vm1 + 037 + SDRAM ctrl + scaler is a small fraction of the 12,060
  LEs (the full MSX core fit in 99%); headroom is comfortable.
- **Display dependency:** the 60 Hz framebuffer path is locked in for the current panel.
  Judder is mild for BK content; revisit only if a 48.8-capable display is used.

## 6. Open questions / decisions deferred

- Framebuffer vs. direct line-buffered readout in Phase 4 (framebuffer chosen for the
  48.8→60 reclock; confirm bandwidth headroom — budget says <10% of SDRAM, ample).
- Exact BK MONITOR / BASIC ROM images and licensing for bundling.
- BK FDD/disk controller variant to emulate in Phase 8 (and Nextor-like vs native).
- Whether to keep a native-rate analog-RGB output as a secondary, judder-free path.

---

*Status: Phases 0–2 complete. Next: Phase 3 (037 arbiter / video address generation).*
*See also the project memory note `bk-on-1chipmsx-feasibility` for the bring-up history.*
