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

### Phase 3 — 037 arbiter / video address generation ✅ DONE

**Strategy: the 037 becomes the RAM arbiter front-end** (chosen over a side-model that
leaves `qbus_sdram` owning RPLY). Cycle-accuracy is then *structural* — the 037 model
*is* the timing oracle — rather than tuned.

**Done:** reference oracle (`sim/ref037/`, `golden_037.txt`) established the ground-truth
with-display cycle counts; `src/va_037_sync.sv` (retimed 037, bit-exact vs golden),
`src/sdram_arbiter.sv` (4-client fixed-priority non-preemptive + `served` mask),
`src/cpu_sdram_dp.sv` (RAM datapath + done-gate) and `src/qbus_mem.sv` integrate
into `src/ocbk_top.sv` — the 037 owns RAM RPLY, RAM lives in SDRAM via the arbiter, the
done-gate interlock is in place. The SoC cosim (`ref037_soc_tb`) runs the program from
SDRAM and reproduces `golden_037.txt` exactly even under worst-case fetch contention
(done-gate never perturbs timing at 3 MHz). Fits **2199/12060 LEs (18%)**, 1 PLL, timing
closes (all slacks positive). *The remaining item — the real video-fetch read stream on
arbiter port 2 — landed with Phase 4 (`fb_video`).*

- Retarget `va_037` from К565РУ5 strobes to SDRAM requests as a **near-verbatim port**
  (`va_037_sync`): run it off `sys_clk` with two clock-enables — `en_pos` (6.04 MHz,
  the `posedge CLKIN` grid) and `en_neg` (offset by 8, the `negedge CLKIN` grid) — so
  every state transition stays on the original enable grid and **`tb_037` remains a
  valid netlist-equivalence oracle**. Drop the RAS/CAS/AMUX *pins*, keep the logic.
- Keep the decode (`nE`/`nBS`), the scroll register (`177664`) + `M256`, the video
  address counters (СТА/СС), and the **`RASEL` grant FSM** — the grant timing *is* the
  CPU/video cycle-stealing. The 037 owns **RAM RPLY**; ROM/IO stay on-chip with the
  fixed `N_ROM` reply (the 037's `nE` already gates them out of the DRAM path).
- Hand the `177716` start-address register to the 037 (retire the `REG_SYS` fake in
  `qbus_sdram`).
- Split `qbus_sdram` into an `sdram_arbiter` (`sys_clk`) + the physical `sdram_ctrl`.
  The arbiter serves **4 clients**: CPU RAM R/W (timing set by the 037 grant, *not* the
  arbiter), the 037 video fetch (48.8 Hz), the framebuffer write, and the Phase-4
  readout (60 Hz, hard-real-time). Bandwidth is a non-issue (<10 %); the risk is
  worst-case *latency* on one CPU access under readout+refresh contention — this ends
  the Phase-2 "latency fully hidden, no interlock" luxury, so an **RPLY done-gate**
  (extend RPLY on a late read rather than latch stale data) lands here.
- **Milestone:** CPU + 037 share SDRAM; cycle counts match real BK *with display active*
  (the with/without-display timing delta is correct), validated against a reference
  oracle (original `va_037` + behavioural К565РУ5 + CPU).

### Phase 4 — Video output pipeline (1024×768@60) ✅ DONE

Pipeline (three model-independent seams — swappable without touching each other):
**037 fetch → `palette_apply(screen_mode)` → 4-bit-index framebuffer → readout+CLUT+scale.**

- **Decode is beam-synchronous, on the fetch/write side** (not at readout): a
  `palette_apply` block between the 037 fetch and the FB write, modelling the palette
  stage that is *external to the 037*. BK-0010 has a single fixed palette, so this is a
  static map now; the seam is where BK-0011M's programmable, beam-raced palette drops in
  (Phase 7) — one block swap, FB/readout/arbiter unchanged.
- **Framebuffer:** decoded, **4-bit post-palette physical-colour index**, double-buffered
  in SDRAM (swap at BK frame boundary; bounds tearing). *Not* a raw shadow copy — that
  would lose the per-scanline palette history BK-0011M needs. Store a **canonical 512
  mono-position slots/line** in both modes (mono: 1 bit→1 slot; colour: 2 bits→2 identical
  slots), so readout stays mode-agnostic.
- **Screen mode** (mono-512 vs colour-256) is a physical monitor/cable switch on real
  BK-0010 — *not* address-space state. In the FPGA it's a static `screen_mode` config
  input (DIP/menu); it touches only `palette_apply`. The 037 fetch is mode-independent.
- **Fixed CLUT** (4-bit index → RGB): 0=black `0x000000`, 1=blue `0x0000FF`, 2=green
  `0x00FF00`, 3=red `0xFF0000`, 15=white (mono foreground). The CLUT is the CRT
  colour-tweak hook (e.g. green-phosphor mono = index 15 → `0x00FF00`).
- **×2 horizontal / ×3 vertical** integer upscale → exact 1024×768 fill, correct 2:3 BK
  pixel shape. Drive the validated 64.43 MHz / 1024×768@60 timing.
- **Milestone:** BK framebuffer contents shown full-screen, borderless, correctly scaled.

**Done:** `src/fb_video.sv` (037 taps → port-2 fetch → `palette_apply` → FIFO → port-3
FB writes, beam-counter destinations so scroll works like real hardware, back-buffer
swap at the vgate frame edge), `src/fb_readout.sv` (port-1 line prefetch, **paced ≥24
sys_clk/word** — load-bearing, the fixed-priority arbiter has no fairness), dual-clock
ping-pong `src/fb_linebuf.sv` (1 M4K), `src/vga_out.sv` + vendored `src/vga_timing.sv`
(64.43 MHz clk1 off the same PLL, triple-ahead line scheduling, fixed CLUT, RGB gated
until `fb_front_valid`). Verified by `sim/run_video.sh` (palette unit tb; fb_video FB
compare incl. mid-frame scroll + M256; readout pixel-exact vs geometry; full-chain
`video_pipe_tb` pixel-exact at the DAC vs a Python-rendered frame) and the **Phase-4
cycle-accuracy gate** `sim/ref037/ref037_soc_video_tb.v`: golden window exact with the
readout live, then 64 display lines of real 4-port contention with the CPU self-loop
beat pattern intact (any done-gate RPLY extension breaks the diff). ROM test program
(`mem/gen_mem.py`, now a mini-assembler; parks pinned at 100004/100012) draws colour
bars + border + diagonal into video RAM; `sim/video/run_draw_check.sh` (slow, one-off)
proves the PDP-11 draw code matches `render_image()`, which `gen_expected.py` imports —
the cosim validates the exact shipped picture. Fits **3363/12060 LEs (28%)**, 1 M4K,
1 PLL, timing closes (setup +0.409 ns); sys↔pixel false-pathed (same-VCO related pair,
all real crossings toggle-handshake or ping-pong-guarded).

### Phase 5 — SoC integration & boot ✅ DONE (banner confirmed on hardware)

The full **BK-0010.01 ROM set** (monit10 + BASIC Vilnius ×3, 32,640 bytes filling
100000–177577 exactly; committed in `mem/roms/`, sourced from the BkEmu project —
BK ROMs are non-restricted for emulator use) boots from SDRAM:

- **ROM-in-SDRAM:** ROM exceeds on-chip memory (262 Kbit > 239 Kbit device total),
  so ROM reads ride the CPU datapath (`cpu_sdram_dp`, arbiter port 0) via the
  linear `addr[15:1]` map (words 0x4000–0x7F7F, below the framebuffers). ROM is
  always SDRAM-backed (the on-chip ROM fallback was removed). ROM is *not*
  037-arbitrated (real mask ROM is never
  cycle-stolen): `qbus_mem` keeps the fixed `N_ROM=2` reply, **done-gated**
  on `mem_ready` (a late word extends RPLY; sticky `dbg_romgate` diagnostic).
  Measured worst port-0 read latency: 37 sys_clk under full 4-port video
  contention vs the ~64 sys_clk window — the gate never fires. ROM writes:
  reply + ignore (real BK would trap 4 on timeout; fidelity deferred to Phase 9).
- **Cycle-accuracy oracle grown:** `golden_037_rom.txt` (generated from the
  reference netlist only) — the same program words executed *from ROM*; key
  property: ROM execution is **flat** (self-loop constant 13 cycles vs the RAM
  loop's 17,15,16,16 beat). The SoC cosims now instantiate the *real*
  `qbus_mem` and reproduce both goldens; the video tb holds the flat-13
  invariant across 64 display lines of 4-port contention. 9 ref037 diffs total.
- **EPCS boot loader:** `src/epcs_boot.sv` (SPI mode-0, DCLK = sys_clk/8 =
  12.08 MHz; EPCS4 plain READ 0x03 is only ~20–25 MHz-capable) reads the blob at
  flash offset 0x40000 through the `cyclone_asmiblock` primitive, validates
  magic/length/checksum, and streams words through the **boot-writer mux** onto
  arbiter port 0 during reset-hold (~22 ms; CPU DCLO held until `boot_done`).
  On failure (`boot_ok=0`) the CPU is **held in reset** — there is no on-chip
  ROM fallback; the power LED (`pLedPwr`) blinks on a bad blob (solid = SDRAM
  init done). Gates: `sim/run_epcs_boot.sh` (in `make sim`; word-exact SDRAM load +
  corrupted-blob run) and the ref037 `+bootload` run (flash→loader→SDRAM→fetch,
  golden exact).
- **Flash flow:** `mem/gen_boot_blob.py` builds the blob (true bytes in the COF
  HEX — `quartus_cpf` bit-reverses into the RPD and `quartus_pgm -m AS` reverses
  again onto the chip, so an MSB-first SPI read returns the HEX verbatim);
  `ocbk.cof` carries it at offset 262144; `make blob-check` verifies the
  flashable POF page (= rev(blob) in RPD order). `make flash` stays one-shot.
- **Live-boot bug fixes found by the oracle discipline:** `sel_io` replied and
  drove data for 177700–177713 — the 1801ВМ1 decodes that block internally
  (CSR/error/`vm1_tve` timer), a guaranteed bus fight the moment MONITOR touches
  the timer; excluded. I/O stubs now follow BkEmu semantics: 177716 = start
  address + bit-2 write-flag, 177660 = keyboard status stub (bit 6 writable,
  cold 1).
- `sim/run_boot_check.sh` (slow, manual): cold-boots the real MONITOR on the full
  SoC — no bus X, screen clear observed; dumps a bus trace for BkEmu diffing.
- Fits **3660/12060 LEs (30%)**, 1 M4K, 1 ASMI block, 1 PLL; STA closes.
- **EPCS bit-order gotcha (cost one flash cycle):** the RPD is in RBF/LSB-first
  bit order, NOT physical-flash order (RPD Page_0 == `.rbf` verbatim);
  `quartus_cpf` reverses hex_block bytes into it and `quartus_pgm -m AS`
  reverses again onto the chip — the two cancel, so COF hex bytes land on flash
  verbatim for an MSB-first SPI read. The first flash (pre-reversed hex) failed
  validation and *proved the fallback path on hardware*: test picture +
  blinking pLed[6], exactly as designed.
- **Milestone MET (2026-07-03): cold-boots to the BASIC Vilnius banner** on the
  panel; DIP2 regression path (Phase-4 test picture) intact. The MONITOR prompt
  via СТОП comes with the Phase-6 keyboard.

### Phase 5.5 — Soft reset (warm restart) ✅ DONE
- The board's **reset button** (`pSltRst_n`, the slot RESET net at PIN_153,
  external pull-up — esemsx3 uses it the same way) re-enters the reset
  sequencer: pressed = DCLO/ACLO held, release + ~22 ms debounce tail = the
  authentic DCLO→ACLO release. SDRAM init, the EPCS ROM load and memory
  contents are untouched (BK hardware-reset semantics — memory survives), so
  MONITOR/BASIC warm-reboots through the 177716 start vector in <1 s.
- **Display continuity (real-BK fidelity):** the 037 and `fb_video` are
  power-on-reset only (`vid_rst_n`) — a real BK's display controller ignores
  CPU DCLO/ACLO, so the screen keeps showing video RAM across the reset
  (no blanking while the button is held).
- **DIP 2 is unused** (2026-07-10): the on-chip test-ROM fallback it selected was
  removed to free resources — ROM is always the loaded SDRAM image, and a failed
  EPCS boot now holds the CPU in reset instead of falling back.
- Oracle-gated: three warm-reset replay diffs in `sim/ref037/run.sh` (12 total)
  re-pulse DCLO/ACLO mid-run — mid-display-line in the video tb, all four
  arbiter ports live — and both passes must match the **same unchanged golden**:
  a warm reset is cycle-identical to a cold boot (guaranteed by construction:
  `cpu_clk = divc[4]`, so the 037-enable phase is invariant). The MONITOR smoke
  cosim gained `+warmreset` (second 177716 read + second screen clear, no X).
- **Milestone: press reset → banner reboots; the Phase-6 keyboard reset chord
  can OR into the same warm_rst_req line.**

### Phase 6 — Peripherals
- **Reset wiring (real BK): DCLO/ACLO reset the CPU only — all peripherals
  reset via the CPU's nINIT Q-bus line** (asserted during CPU reset and pulsed
  by the RESET instruction). Key every peripheral's reset to `init_n`, never
  to `dclo_n`. **DONE for the keyboard step:** the 177716 write-flag and the
  `bk_kbd014` registers reset on INIT; the translator-side ЗАГЛ/СТР trigger
  and РУС/ЛАТ shadow are power-on only (external-trigger fidelity).
- **Interrupt-pin sync rule (1801ВМ1 doc, confirmed by the real board —
  `doc/bk0011m-sch.pdf` D11, a К555ТМ9 hex D register on the CPU clock):
  nIRQ1–3/nVIRQ assertions must be synchronized to the CPU clock rising edge**
  (nRPLY to the falling edge — the real board's D8:B К531ТВ9 does that; the
  existing RPLY paths already comply edge-wise, full ТВ9 modelling is a
  deferred fidelity item, see CLAUDE.md gotchas). The core samples these pins
  at `posedge pin_clk_p` with **no synchronizer stages**, so every interrupt
  source (vp_014 VIRQ, 50 Hz EVNT/IRQ2) must put its final output flop on
  `posedge cpu_clk`; sources born in `sys_clk`/`pix_clk` (EVNT = vsync) need a
  2-FF resync into `cpu_clk` first. An async assertion is a metastability AND
  a cycle-determinism hazard (interrupt latency would vary run-to-run,
  breaking any interrupt-covering golden oracle).
- **PS/2 keyboard — DONE in sim + built (2026-07-06, hardware smoke pending):**
  `ps2_rx` → `kbd_ps2bk` → `bk_kbd014` (behavioral 1801ВП1-014 at
  `177660–177663` behind the 037's `nBS`, VIRQ 060/0274 + IAK vector
  responder; СТОП = Delete → a fixed 64-clock nIRQ1 one-shot). Netlist-
  contract-validated: `sim/ref014` holds the vendored `vp_014.v` gate netlist,
  a transaction-granular contract golden AND an interrupt-latency golden
  (netlist reference run vs the full SoC stack, line-exact — it calibrated
  `N_KBD`/`N_IAK`=1 and the combinational write reply). Key findings baked
  into the goldens: the press-while-ready delivery queue (re-delivers on the
  662 read while the key is held), retro-fire on unmask, no АР2 flag in 662
  bit 7, 662 writes bus-timeout, the silicon auto-274 code group, and
  **СТОП = trap-to-4** (nothing decodes 177674/177676, the HALT entry's
  stores time out — authentic BK-0010+BASIC behaviour). PS/2 mapping:
  CapsLock = ЗАГЛ/СТР trigger, LCtrl = РУС, Home = ЛАТ, Insert = СУ,
  Alt = АР2, Delete = СТОП. Keyboard reset chord: still open (deferred).
- Audio: **1-bit speaker CONFIRMED ON HARDWARE** (MONITOR keyclick audible) —
  bit 6 of the 177716 write (`spk_bit`, a plain software-owned latch, NOT
  nINIT-reset). The
  vm1 self-replies for 177700-177717, so the write is captured **directly in the
  DOUT window on sys_clk** in `qbus_mem` (reply-independent — the wait-FSM
  never sees it), then `bk_audio` (2-FF resync + **push-pull mono R-2R drive**,
  ocb-test-proven; idle = mid-scale) → board sound DAC `pDac_SL`/`pDac_SR`
  (PIN_105-114/115-120). `pLed[0]` = speaker-activity tap. Oracles: `sim/run_audio.sh`
  (DAC unit + directed 177716-capture). **Still open:** Covox / tape bit 5 (MiSTer
  models bit 5 too), tape in/out.
- **Milestone:** interactive — type, run BASIC, hear sound. *(Keyboard part
  of the milestone: pending the hardware smoke — type in MONITOR/BASIC, СТОП
  drops BASIC to the monitor, warm reset keeps РУС/ЛАТ.)*

### Phase 7 — BK-0011M mode
- 128 KB banked RAM, two video pages, 4 MHz CPU, page/control registers, MMU windows.
- System timer + interrupt wiring (50 Hz EVNT/IRQ2 from vsync).
- Runtime model select (BK0010 ↔ BK0011M) via DIP/menu.
- **Milestone:** BK-0011M software boots and runs.

**Memory model & banking — design notes** (BkEmu remains the authoritative
register/behaviour reference for the exact bit fields):
- BK-0011M RAM is 8 × 16 KB pages (128 KB) plus 4 × 16 KB ROM pages. Of the four
  16 KB CPU windows, **two are banked** (`040000–077777` and `100000–137777`);
  `000000–037777` is a fixed RAM page and `140000–177777` is fixed top ROM + I/O.
  The two banked windows share the same 8 RAM pages; the *second* window can map
  either a RAM page or one of the ROM pages.
- Banking is driven by the **177716 (SEL1)** register — a write reconfigures the
  map only when its ENABLE bit is set, and the reset default re-inits the map
  (INIT-keyed, like every peripheral register). The displayed **video page +
  palette live on a separate register (177662)**, not 177716.
- **Capacity is a non-issue:** the SDRAM dwarfs everything the design uses (the
  BK-0010 RAM + ROM + two framebuffers occupy a fraction of a percent). Phase 7
  is not about finding room — it is about **address translation**.
- The core change is a **page-translation stage on the CPU→SDRAM path**
  (`cpu_sdram_dp`): today's flat `addr[15:1]` map becomes a per-window,
  page-register-indexed base + in-window offset. BK-0010 mode is the same path
  with banking disabled, so both models can stay resident in SDRAM and the
  runtime model select becomes a base-address swap rather than a reload.
- **Design the `100000–177777` window with an explicit "who owns it" hook**
  (not just the 0011M banker): Phase 8's SMK512 controller re-maps that same
  window on a finer 4 KB granularity from its own register. Making window
  ownership a selectable source now (0011M banker vs. a later extension) keeps
  Phase 8 a layer-in rather than a rewrite of the translate stage.
- **Open points to settle reference-tb-first** (per the verification discipline):
  - *RPLY ownership becomes dynamic* — the `100000–137777` window is RAM (037
    cycle-stolen, done-gated) in one mapping and ROM (fixed `N_ROM`, not stolen)
    in another, so the reply source depends on the current bank selection.
  - *Video fetch base* moves off the fixed `VRAM_BASE` onto the 177662 page
    select (synced into the video domain like `screen_mode`).
  - *0011M cycle-stealing may differ from the 037 model* — validate the banked
    RAM timing against a reference before trusting the current 037 for 0011M.

### Phase 8 — Storage (SMK512)
- Emulate the **SMK512** controller — the mainstream BK HDD/storage controller —
  backing its disk operations with an SD card (reuse the esemsx3 SD/SPI
  infrastructure). BkEmu is the authoritative behaviour reference.
- **Milestone:** boot the SMK BIOS and load/run programs from an SD-backed HDD image.

**SMK512 — design notes.** The SMK512 is *three* devices on one board, so Phase 8
is not a single peripheral:
- **IDE/HDD interface** — a standard ATA task-file, memory-mapped as a small
  block of registers in the I/O page. `SECTOR_SIZE = 512`, so the ATA LBA maps
  1:1 onto SD's native sector — the disk image is just an SD-resident sector
  range. The heavy part is an ATA command engine (BSY/DRQ handshake,
  READ/WRITE SECTOR(S), IDENTIFY) with a one-sector buffer; the CPU-visible
  data port is **bit-inverted** on the bus. This part is nearly memory-layout-free.
- **512 KB segmented RAM extension** — the memory-layout piece, and it *is* the
  Phase-7 coupling: 8 × 4 KB segments mapped into the `100000–177777` window,
  reconfigured from its own control register (with several layout modes) that
  also selects/deselects the BK-10 monitor / BK-11 BOS ROM / 0011M second banked
  window. It must slot into the Phase-7 window-ownership hook as an alternative
  mapping source at 4 KB granularity — do **not** design it as a bolt-on. The
  512 KB (256 Kword) lives in SDRAM; capacity is again a non-issue, addressing is
  the work.
- **SMK BIOS ROM** — the code that drives the IDE; a few KB in the SDRAM ROM
  region alongside the other ROM images.
- **Open point:** the extension's cycle-stealing / RPLY behaviour on this window
  interacts with the Phase-7 dynamic-RPLY-ownership question — settle both
  together, reference-tb-first.

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
  methodology at every phase that touches memory (2, 3, 7). From Phase 3 on the SDRAM is
  *contended* (CPU + video fetch + FB write + readout), so a CPU access is no longer
  guaranteed to hide inside its RPLY window by margin alone — an **RPLY done-gate**
  interlock (Phase 3) makes a late read extend RPLY instead of latching stale data.
- **One-PLL discipline:** never add a second PLL. New clocks must be ÷N of the ×9 VCO or
  fabric clock-enables.
- **Resource budget:** vm1 + 037 + SDRAM ctrl + scaler is a small fraction of the 12,060
  LEs (the full MSX core fit in 99%); headroom is comfortable.
- **Display dependency:** the 60 Hz framebuffer path is locked in for the current panel.
  Judder is mild for BK content; revisit only if a 48.8-capable display is used.

## 6. Open questions / decisions deferred

- ~~Framebuffer vs. direct line-buffered readout in Phase 4~~ — **decided:** decoded,
  double-buffered framebuffer in SDRAM (the 48.8→60 reclock + tearing bound require a
  full-frame buffer; a line buffer only works genlocked). Bandwidth <10% of SDRAM.
- Exact BK MONITOR / BASIC ROM images and licensing for bundling.
- BK FDD/disk controller variant to emulate in Phase 8 (and Nextor-like vs native).
- Whether to keep a native-rate analog-RGB output as a secondary, judder-free path.

---

*Status: Phases 0–5 complete — **the board cold-boots the real BK-0010.01
firmware to the BASIC Vilnius banner** (confirmed on hardware 2026-07-03): the
EPCS loader copies MONITOR+BASIC into SDRAM at power-up, ROM executes behind the
done-gated fixed-N_ROM path, oracle-gated for cycle accuracy under full 4-port
contention (`golden_037.txt` + `golden_037_rom.txt`, twelve ref037 diffs incl.
the Phase-5.5 warm-reset replays; the reset button warm-restarts without
re-running SDRAM init or the EPCS load). Fits
30% / 1 M4K / 1 ASMI / 1 PLL / timing closes. The Phase-6 keyboard is in
(PS/2 → 1801ВП1-014 equivalent, netlist-golden-validated incl. interrupt
latency and the СТОП trap-4 path; fits 34%, timing closes) — awaiting the
hardware smoke. Next: hardware smoke, then tape/audio and the 50 Hz
EVNT/IRQ2 wiring.*
*See also the project memory notes `bk-on-1chipmsx-feasibility` (bring-up history),
`bk-video-pipeline-decision` (Phase 3/4 design) and `bkemu-reference-and-roms`
(BkEmu is the canonical BK reference; ROMs committed in-tree).*
