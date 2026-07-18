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
  contention vs the ~64 sys_clk window — the gate never fires. **ROM writes get
  no reply → the CPU's qbto timer → trap 4** (authentic mask/overlay ROM; the
  "write until trap 4" screen-clear idiom relies on it; BkEmu-confirmed). One
  line in `qbus_mem`: `selected = (sel_rom & is_read) | sel_io`. A DATIO RMW to
  ROM traps on its write half too (the vm1's DATIO both-strobes-idle gap drops
  the read reply first — no special handling). Oracle: `sim/romwr/run.sh`
  (DATO + RMW, mutation-tested); `sim/bk11` §6 for window-1 overlays.
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

### Phase 6 — Peripherals ✅ DONE
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
  (DAC unit + directed 177716-capture).
- **Tape (магнитофон) — WORKS ON HARDWARE (2026-07-10):** the **esemsx3
  CMT-jack scheme** — the right sound-DAC ladder doubles as the cassette
  port. **PS/2 Scroll Lock toggles CMT mode** (the same key esemsx3 uses;
  `key_cmt` radial output → 2-FF sys_clk sync, power-on default = audio,
  survives warm reset like a plugged cable; `pLed[1]` = mode tap). In CMT
  mode `bk_audio` switches `pDac_SR` from push-pull audio to the comparator
  network: `[5]` = tape **input** pad (tri-stated, 2-FF-sampled), `[3:2]` =
  `{lvl, ~lvl}` Schmitt positive feedback through the ladder resistors,
  `[1]` = 0, `[0]` = the speaker level = BK tape **out** (bit 6 — record to
  a PC through the same jack). The sampled level feeds **177716 read bit 5**
  (2-FF onto `cpu_clk_n` → `qbus_mem.tape_in`). Bit semantics verified
  against the original MONITOR sources (`bk-0010-sources/d6.mac`): read
  bit 5 polled by duration-timing loops, polarity-insensitive,
  self-calibrating from the pilot — so no tape-image machinery is needed in
  the FPGA: a WAV played into the jack is enough. **Motor-bit gating was
  tried and reverted**: bit 7 (`KPUSK=020`/`KSTOP=220`, 1 = stopped) is
  authentic MONITOR behaviour, but real BK software writes bit 7 = 0
  outside tape ops and wrongly killed the right audio channel on hardware —
  `mot_bit` stays captured in `qbus_mem` (oracle-pinned register semantics)
  but unused in the top. Oracles: `sim/run_audio.sh` (CMT drive pattern +
  feedback in `bk_audio_tb`; bit-5 reads, bit-7 capture and the nINIT
  survival in `spk_capture_tb`); `sim/run_ps2.sh` (the Scroll Lock radial
  toggle). No goldens changed (bit 5 reads 0 with the tie-off).
  **Still open:** Covox; tape-out 3-level fidelity (real BK mixes write
  bits 6+5 resistively — bit 6 alone is the dominant component); an
  optional slow MONITOR-load cosim oracle.
- **Milestone:** interactive — type, run BASIC, hear sound. *(Keyboard part
  of the milestone: pending the hardware smoke — type in MONITOR/BASIC, СТОП
  drops BASIC to the monitor, warm reset keeps РУС/ЛАТ.)*

### Phase 7 — BK-0011M mode ✅ DONE (BK-0011M boots & runs on hardware)
- 128 KB banked RAM, two video pages, 4 MHz CPU, page/control registers, MMU windows.
- System timer + interrupt wiring (50 Hz EVNT/IRQ2 from vsync).
- Runtime model select (BK0010 ↔ BK0011M) via DIP/menu.
- **Milestone:** BK-0011M software boots and runs.
- **Status (2026-07-11): first increment done, confirmed on hardware** —
  runtime model select on
  **DIP 1** (OFF = 0010, ON = 0011M; `model_bk11`, latched in `ocbk_top`
  during any DCLO hold, so the reset button switches models without a power
  cycle) + the **4.03 MHz (/24) CPU clock** in the new `src/cpu_clkgen.sv`
  divider (oracle `sim/run_clkgen.sh` pins /32 BK-0010 mode bit-identical to
  the old `divc[4]` tap; a retarget can never runt the clock). Everything
  else still runs the BK-0010 machine, so DIP 1 ON = that machine at the
  0011M rate; `model_bk11` is the hook the mapper / 177662 palette / timer
  items consume. The CPU=CLKIN/2 phase lock with the 037 holds only in /32
  mode — /24 walks a deterministic 48-sys_clk pattern; 0011M cycle-accuracy
  is the open point below.
- **Status (2026-07-11): second increment done (sim)** — the **`mem_mapper`
  sub-module** of `qbus_mem` implements the BK-0011M banking semantics
  (BkEmu `Bk11MemoryManager` = the canonical contract): 177716 word writes
  with bit 11 = banking (window-0 page in bits 14:12; the & 0o033 ROM field
  decoded ONLY as the exact single-bit codes 001/002/010/020 → window-1 ROM
  banks, everything else falls through to the bits-10:8 RAM page — the BkEmu
  quirk, replicated), fixed page 6 low, fixed top ROM, write-only register,
  banking/speaker mutual exclusion, **DCLO-only map reset** (see below).
  **Window-1 banked RAM is a normal `MK_RAM037` access** (037-owned RPLY,
  video cycle-stolen, done-gated on `mem_ready`, read+write through the
  `cpu_sdram_dp` port-0 path with `phys` = the win1 RAM page; BK-0010 mode is
  a bit-identical pass-through — all `golden_037*`/`golden_kbd` oracles
  unchanged). This matches real hardware and **replaces the earlier
  placeholder `MK_EXT`/fixed-`N_EXT` design** (done 2026-07-13): schematic
  tracing of `doc/bk0011m.sch` confirmed the 037 fronts **all** internal RAM,
  the second banked window included — it is the *sole* DRAM controller (all 16
  565РУ5 RAS/CAS from it, the RAM reply is its own RPLY), and its AD15 pin is
  driven by a banking OC-NAND (D10) so that — **accounting for the active-low
  Q-bus** (physical AD15 = 1 across 000000–077777) — its internal A15 =
  `A15_true & ~(window-1-is-RAM)` = true A15 forced low for window-1 RAM. The
  vendored `va_037_sync` gates ownership on the raw latched `A[15]`
  (`RASEL`/`cpu_grant`, va_037_sync.sv:238/:144) — a BK-0010 simplification —
  so we reproduce the force: `mem_mapper` emits `MK_RAM037` for window-1 RAM,
  `qbus_mem` exports `ext_ram` (= `sel_ram && addr[15]`; 0 in bk10) and
  `va_037_sync` uses `a15_037 = A[15] & ~ext_ram`. bk10 stays bit-identical
  (`ext_ram`≡0). The AD15 start-vector assist (va_037_sync.sv:109) is left
  untouched (177716 DIN read only), and the 033-quirk RAM fall-through rides
  the same path. **`MK_EXT`/`N_EXT` are now RESERVED for the Phase-8 SMK512**,
  which genuinely has its own external controller and fixed reply. Remaining
  gap (deferred, 0011M cycle-accuracy envelope): no bk11 *timing* oracle
  exists, so window-1 cycle counts are not machine-checked — correctness is
  covered by the bk11 functional oracle + real-BOS boot. Layout:
  8 RAM pages at SDRAM words 0x20000+, 4 window-1 ROM banks at 0x30000+, top
  ROM at 0x38000+. Oracles: `sim/run_mapper.sh` (unit: full 64K bk10 sweep +
  the banking contract) and `sim/bk11/run.sh` (SoC functional program at the
  /24 rate: fill/verify all pages through both windows, page-6 aliasing, RMW
  in EXT, ROM overlay writes → trap 4, 033 quirk, RESET-preserves-map,
  write-only register).
  **Deferred follow-ups:** bit-12 СТОП-enable (done — fifth increment below);
  the 0011M ROM blob in the EPCS loader + SYS_START 140000 (done — sixth
  increment below); **route window-1 RAM through the 037 via a synthesized
  A15** (done 2026-07-13 — `a15_037 = A[15] & ~ext_ram`, window-1 is now
  `MK_RAM037`, `N_EXT` is SMK512-only; see the mem_mapper item above);
  `N_VREG` recalibration and 0011M cycle-accuracy vs a reference remain (both
  reference-tb-first with golden regeneration).
- **Status (2026-07-11): third increment done (sim)** — the **177662 video
  register** (screen page / palette select) + the physical-colour video path.
  **MiSTer `BK0011M_MiSTer/rtl/video.sv` is the reference for this register**
  (BkEmu's handling is simplified): write-only (662 reads stay with the 014
  keyboard data register in both models), bk11-only (a bk10 662 write still
  bus-times-out → trap 4), high byte only — bit 15 = displayed screen
  (0 = RAM page 1 → SDRAM `BK11_VPAGE0`, 1 = page 7 → `BK11_VPAGE1`), bit 14
  = frame-IRQ2 mask (captured, consumer = the timer item), bits 11:8 =
  palette (16 palettes); immediate effect, **DCLO-only reset** (defaults =
  MiSTer `def_reg662` 0o047400: page 0, IRQ2 masked, palette 15). `qbus_mem`
  owns the one positive decode besides the nSEL pair (capture in the sclk
  DOUT window next to `spk_bit`; write reply = fixed `N_VREG` placeholder in
  the wait FSM); `bk_kbd014` is untouched. **The canonical 4-bit FB index is
  now the physical colour nibble {R1, B, G, R0}** (2-bit red, 1-bit
  blue/green — the machine's whole colour space): `palette_apply` looks up
  the MiSTer `palettes[16]` ROM verbatim (`pal_idx` rides with each fetch,
  beam-raced), `vga_out` decodes the nibble combinationally (red levels
  0/0x23/0x30/0x3F ≈ the BkEmu 0x8E/0xC0 weights) — bk10 palette 0 =
  {0,4,2,9} produces bit-identical RGB at the DAC, so `video_pipe_tb` passes
  unchanged. `fb_video` gained live `vram_base`/`pal_idx` inputs (the
  `VRAM_BASE` param is gone); `ocbk_top` muxes them on `model_bk11`
  (all sys_clk, no CDC). Oracles: `palette_tb` sweeps all 16 palettes
  against an independently hand-transcribed table; `fb_video_tb` frame D
  fetches from the page-7 base with palette 11 through the real SDRAM path;
  the bk11 SoC program writes 177662 (replied, RESET-preserved, tb-checked
  taps) and proves the read side times out via a vector-4 detour. All bk10
  timing goldens unchanged. Fits 4,208 LE (35%, +219 for the palette ROM +
  decode + register), still 1 M4K, STA closes (setup +0.541 ns).
- **Status (2026-07-11): fourth increment done (sim)** — the **EVNT/IRQ2
  frame interrupt** (the 50 Hz system timer), completing the 177662 bit-14
  consumer. **MiSTer `rtl/video.sv` is the model** (user-confirmed: BK
  software races IRQ2 for CRT-effect timing and the corpus is proven against
  MiSTer): the nIRQ2 level = the vertical blanking window — in our raster
  exactly the 037 netlist's `vgate` (lines 256..319; MiSTer's `irq` sets at
  vc==256, clears at vc==0) — gated `model_bk11 & ~vid_irq2_mask`,
  registered on sys_clk, 2-FF onto posedge cpu_clk in `ocbk_top` (pin-sync
  rule), into the vm1's arm/fire edge detector → one vector-0100 interrupt
  per frame; mask defaults to 1 on DCLO, and BK-0010 mode has **no IRQ2
  source at all** (BkEmu + MiSTer agree), so every bk10 timing golden is
  untouched by construction. Oracle: `sim/bk11` section 12 (mask gates the
  already-asserted level; one fire per window + double-fire grace; PSW
  340↔0 via the RTI idiom) + two tb assertion guards (every nIRQ2 assert
  inside the vgate window AND never while masked — the CPU-side checks alone
  can't catch a broken gate: with the pin stuck asserted the vm1 detector
  never arms, so the first fire just slides to the next frame and passes).
  **Deferred fidelity item (schematic-traced, `doc/bk0011m-sch.pdf`):** the
  real 0011M has no vgate pin — an external detector asserts IRQ2 a few
  *lines into* blanking: WTI (D19/037 pin 31, pulsing only on active lines)
  holds the D28 СТ2 counter reset; in blanking it counts line-rate SYNCO
  edges (via the D6:C NOR) until its tap arms D3:B (ТМ2, clocked by SYNCO)
  → the PRT̄ net (also on the XT3.2 expansion connector) → D11 (К555ТМ9, on
  CLC — the same retimer as RPLY/VIRQ) → the CPU IRQ2 pin; the 662-write
  register bits (D35/D26) gate the counter resets and D3:B's reset.
  Modelling that assert-instant offset goes **reference-tb-first** with the
  0011M cycle-accuracy item (same posture as the D8:B RPLY retimer) — it
  matters for beam-racing software, and is unverifiable until a 0011M
  timing reference exists.
- **Status (2026-07-12): fifth increment done (sim)** — the **СТОП-enable
  bit** (177716 write bit 12, BK-0011M: 1 = СТОП blocked, write-only),
  closing that deferred follow-up. **MiSTer `BK0011M.sv` is the model**
  (`key_stop_block <= dout[12]` on a sysreg write with `~dout[11] &
  wtbt[1]`); BkEmu agrees except its even-byte-write implicit re-enable —
  rejected as an emulator artifact (the real board latches 177716 write
  data in registers clocked by separate WR1/WR2 byte-lane strobes, so only
  a write that strobes the HIGH byte can touch bit 12). Implementation: a
  `stop_block` latch in `qbus_mem` (DOUT-window capture on sclk next to
  the 662 block: word or 177717 odd-byte write, bit-11 lane clear;
  bk11-only, **DCLO-only reset** — the map/662 exception again: RESET must
  not re-enable СТОП under protected software), 2-FF onto cpu_clk in
  `ocbk_top` gating the launch of the existing 64-clk СТОП nIRQ1 one-shot
  (transparent in bk10 mode — the latch never captures — so every bk10
  golden is untouched by construction). Oracles: `spk_capture_tb` pins the
  capture contract (bk10 dead, word/odd-byte reach, low-byte and banking
  excluded, lane-11 exclusion, nINIT-preserve, DCLO default); `sim/bk11`
  section 13 proves the gate end-to-end — the tb pulses `key_stop` on a
  magic scratch write into the ocbk_top replica, an enabled СТОП takes the
  authentic HALT-entry-timeout → trap-4 path (at PSW prio 7: rq[14] is the
  raw pin level, the very reason the bit exists), a blocked one must not
  fire inside a bounded window (mutation-tested both ways). Found and
  documented along the way: the aborted HALT entry pushes a
  **mid-instruction PC**, so the trap-4 frame is not RTI-able — the
  section-13 handler drops the frame and continues via R0 (authentic: real
  СТОП handlers never return; the gen_kbd_test one parks). Fits 4,222 LE
  (35%, +7), still 1 M4K; the netlist perturbation flipped the known
  `sdram_ctrl` wait_cnt→cmd placement-luck path negative at SEED 2 →
  reseeded to 3 per the ocbk.qsf note (setup +0.904 ns, hold/recovery
  clean).
- **Status (2026-07-12): sixth increment done (sim)** — the **BK-0011M ROM
  blob in the EPCS + SYS_START 140000**, so DIP1-ON now boots BOS. The BK
  ROM set (`basic11m_0/basic11m_1/ext11m/bos11m/mstd11m`, from BkEmu, per its
  `Computer.configure()` 0011M arm) is committed to `mem/roms/` and packed by
  `gen_boot_blob.py` into a **second same-format blob** at EPCS flash 0x48000
  → SDRAM words 0x30000–0x39FFF (40960 words, contiguous: bank-0 BASIC at
  0x30000, bank-1 basic11m_1+ext11m at 0x32000, the two unpopulated
  window-ROM sockets zero-filled at 0x34000/0x36000, BOS at 0x38000, MSTD at
  0x39000). `epcs_boot` is now a **two-pass loader** (a per-pass
  flash/base/cap mux + an inter-pass nCS-high `B_GAP`, ~77 ms total); it
  loads **both** blobs unconditionally (the DIP-1 model latch re-samples at
  every warm reset, so both images must always be resident) and
  `boot_ok` = every pass header-valid + checksum-good. `SYS_START11 =
  0o140000` (BkEmu `Computer.java:267`) muxes the 177716 read on
  `model_bk11` — bit 15 still agrees with the 037 AD15 assist, bit 14 is
  qbus_mem-only. `ocbk.cof` gains a second `hex_block` (`quartus_cpf`
  accepts both; the map file + `make blob-check` confirm rev(blob) at BOTH
  0x40000 and 0x48000). Oracles: `run_epcs_boot.sh` now three legs (clean
  loads both regions word-exact, `+corrupt`/`+corrupt2` each end boot_ok=0);
  the ref037 `+bootload` leg gets a minimal valid second blob (goldens
  unchanged — a longer boot can't shift the clk-aligned DCLO release); the
  bk11 oracle boots through a top-ROM stage-0 stub (177716→140000 fetch→JMP
  100000 into the EXT window; TOPPAT marker moved to 140004); and
  `run_boot_check.sh +bk11` cold-boots the real BOS on the full SoC (/24
  clock, both blobs preloaded, 177662+fb mux replica) — 140000 vector reply,
  a 177662 write, screen clear, no bus X.
- **Status (2026-07-12): hardware boot regression fixed (sdram_ctrl retimed).**
  The sixth increment (bk11 ROM blob) built and simmed clean but **did not boot
  on hardware in either model** — power LED solid, no start. Root cause was NOT
  the loader: the added netlist tipped the long-documented placement-marginal
  `sdram_ctrl` `wait_cnt → s_dqm/dq_out/s_addr` paths into an **outright setup
  violation** at SEED 3 (STA-invisible before because it was merely *marginal*),
  corrupting the SDRAM ROM as it was written so the CPU came out of reset on
  garbage. `boot_ok` is a flash checksum, not a SDRAM read-back, so it still read
  1 (LED solid). A user experiment (forcing the `epcs_boot` reset state) masked
  it by placement luck — proven inert by sim (identical two-pass run, boot_ok=1),
  i.e. it only perturbed P&R. **Real fix (`src/sdram_ctrl.sv`):** the one 15-bit
  `wait_cnt` served both the 200 µs power-up wait (compare gates a state only)
  and every short runtime wait (compare fans into the SDRAM output I/O regs) —
  a ~15-input comparator on an output-setup path. Split into a wide `init_cnt`
  (ST_INIT_WAIT only) + a narrow **3-bit** `wait_cnt` (all runtime waits).
  Cycle-identical (same load values/decrements); `make sim` green,
  `run_epcs_boot.sh` word-exact on the real controller. STA: worst setup
  −0.068 → **+0.674**, the critical path leaves `sdram_ctrl` entirely, its worst
  internal path now +1.62 ns; 4,253 LE. `SEED 3` kept for bitstream repro but no
  longer load-bearing (ocbk.qsf comment updated). **CONFIRMED ON HARDWARE
  2026-07-12** — `make`/`make flash` boots both BK-0010 and BK-0011M.
- **Status: authenticity increments done (sim + hardware).** After the core
  0011M machine booted, three fidelity items closed the phase: (1) **ROM writes
  time out → trap 4** (2026-07-14) — a write to any ROM region gets no RPLY →
  qbto → vector 4, enabling the conditionless "write until trap 4" screen-clear
  idiom (the whole RTL delta is `selected = (sel_rom & is_read) | sel_io` in
  `qbus_mem`; BkEmu-confirmed; oracle `sim/romwr`). (2) **Unpopulated window-1
  ROM sockets → `MK_NONE`** (2026-07-15) — banks 2/3 (codes 010/020) are empty
  on a stock BK-0011M, so the mapper emits no-reply (not zero-fill ROM), letting
  BOS's reverse 4→1 socket probe skip them instead of executing a HALT
  (`mem_mapper` `WIN1_ROM_PRESENT`). (3) **Authentic DRAM power-on pattern**
  (`src/ram_init.sv`, 2026-07-15) — the SDRAM RAM region is pre-filled with the
  real К565РУ6/РУ5 power-on garbage so startup screens look like real silicon;
  the per-model pattern follows **bkemu-QT `InitMemoryValues`** (2026-07-16:
  bk10 `w_addr[0]^w_addr[6]^(w_addr[5:0]==0 & w_addr!=0)`, bk11
  `w_addr[3]^w_addr[6]`; oracle `sim/raminit`, tb an independent transcription
  of the C loops). All confirmed on hardware. **Milestone met** — BK-0011M
  software boots and runs. Remaining 0011M **cycle-accuracy vs a reference**
  stays a deferred, reference-tb-first fidelity item (see the open points below
  / Phase 9), not a blocker for the phase.

**Memory model & banking — design notes** (BkEmu remains the authoritative
register/behaviour reference for the exact bit fields):
- BK-0011M RAM is 8 × 16 KB pages (128 KB) plus 4 × 16 KB ROM pages. Of the four
  16 KB CPU windows, **two are banked** (`040000–077777` and `100000–137777`);
  `000000–037777` is a fixed RAM page and `140000–177777` is fixed top ROM + I/O.
  The two banked windows share the same 8 RAM pages; the *second* window can map
  either a RAM page or one of the ROM pages.
- Banking is driven by the **177716 (SEL1)** register — a WORD write
  reconfigures the map only when its ENABLE bit is set (bit 11). The map
  resets to config 0 on **DCLO ONLY** (BkEmu `Bk11MemoryManager`: a hardware
  reset re-inits the map; the RESET instruction / nINIT **preserves** it — a
  RESET executed from a banked window must not swap the page under the
  running code). This is a documented exception to the "peripherals reset on
  nINIT" rule, like the software-owned `spk_bit` latch. The displayed **video
  page + palette live on a separate register (177662)**, not 177716.
  **Speaker interaction (done):** a word write with bit 11 SET is a banking
  write and does NOT update `spk_bit`/`mot_bit` (BkEmu
  `Speaker.BK0011M_ENABLE_BIT`; MiSTer gates its `spk_out` the same way) —
  the `qbus_mem` DOUT-window capture is gated by the mapper's `bank_wr`
  (byte writes can never carry bit 11 and always capture; bk10 mode ignores
  bit 11 entirely — pinned by `spk_capture_tb`).
- **Capacity is a non-issue:** the SDRAM dwarfs everything the design uses (the
  BK-0010 RAM + ROM + two framebuffers occupy a fraction of a percent). Phase 7
  is not about finding room — it is about **address translation**.
- The core change is a **page-translation stage on the CPU→SDRAM path**
  (`cpu_sdram_dp`): today's flat `addr[15:1]` map becomes a per-window,
  page-register-indexed base + in-window offset. BK-0010 mode is the same path
  with banking disabled, so both models can stay resident in SDRAM and the
  runtime model select becomes a base-address swap rather than a reload.
- **Factor this out as a memory-mapper sub-module of `qbus_mem`, not a rewrite.**
  The mapper is the *generalization* of three things `qbus_mem` already does
  inline — the region decode (`sel_ram`/`sel_rom`/`sel_io`), the physical-address
  map, and the (currently static) RPLY-owner split — into one config-driven unit:
  *(CPU address, mapping registers) → (physical SDRAM word, region kind, RPLY
  owner, writable?)*. `qbus_mem` stays the bus-slave + SDRAM-datapath + arbiter
  host and consumes the mapper's outputs; the mapper owns the mapping registers
  (snooping their bus writes) and is independently cosim-able. BK-0010 mode is a
  pass-through, so the existing `golden_037*` oracles stay the regression anchor.
- **Design the `100000–177777` window with an explicit "who owns it" hook**
  (not just the 0011M banker): Phase 8's SMK512 controller re-maps that same
  window on a finer 4 KB granularity from its own register. Making window
  ownership a selectable source now (0011M banker vs. a later extension) keeps
  Phase 8 a layer-in rather than a rewrite of the translate stage.
- **Open points to settle reference-tb-first** (per the verification discipline):
  - *RPLY ownership becomes dynamic* — the `100000–137777` window is banked RAM
    in one mapping and ROM (fixed `N_ROM`, not stolen) in another. *Mechanics
    are in (the mapper's region kind selects the owner); the open part is the
    TIMING.* **Resolved-in-principle 2026-07-12 (user/hardware):** 0011M
    banked RAM **is** 037-style cycle-stolen — the real 037 fronts all
    internal RAM including window 1, its A15 decode fed by the banking
    circuitry, not the CPU. So the answer is NOT to recalibrate `N_EXT` but
    to **route window-1 RAM through the 037 via a synthesized `a15_037`**
    (forced low for MK_EXT accesses), collapsing it into `MK_RAM037`;
    `MK_EXT`/`N_EXT` (the current FSM-owned fixed reply) is a placeholder
    that survives only as the **SMK512** external-RAM path (its own
    controller → a genuine fixed reply). Still reference-tb-first (needs a
    0011M timing reference + golden regeneration). See the mem_mapper status
    bullet above for the full detail.
  - *Video fetch base* — DONE (third increment): `fb_video`'s `vram_base`
    input follows the 177662 page select (same sys_clk domain, no sync
    needed; sampled per fetch).
  - *0011M cycle-stealing may differ from the 037 model* — validate the banked
    RAM timing against a reference before trusting the current 037 for 0011M.

### Phase 8 — Storage (SMK512)
- Emulate the **SMK512** controller — the mainstream BK HDD/storage controller —
  backing its disk operations with an SD card (reuse the esemsx3 SD/SPI
  infrastructure). BkEmu is the authoritative behaviour reference.
- **Milestone:** boot the SMK BIOS and load/run programs from an SD-backed HDD
  image — ✅ **ACHIEVED 2026-07-18: the SMK BIOS boots an OS from the SD card
  on the board.**

**SMK512 — design notes.** The SMK512 is *three* devices on one board, so Phase 8
is not a single peripheral:
- **IDE/HDD interface** — ✅ **increment (a) — the drive engine — DONE,
  CONFIRMED ON HARDWARE 2026-07-18** (with no drive the BIOS times out its
  probes and exits to its command line like a real driveless SMK;
  `src/smk_ide.sv`; the SD/SPI backend is increment (b) — ✅ done, see the
  next bullet).
  The standard ATA task-file at word addresses **0177740–0177756** (BkEmu
  `SmkIdeController`/`IdeController` is the contract, `IdeControllerTest`
  the transcribed oracle): ALL data **bit-inverted** both directions at the
  bus adapter — the backing store holds TRUE data, a **raw AltPro image**
  (user-settled: same bytes BkEmu attaches, dd-able to the card in (b)) —
  composite registers 177740 (rd {drive-addr, status} / wr-at-exact-740 =
  COMMAND) and 177742 (rd {alt-status, DHR|0xA0} / wr-742 = DHR / byte 743
  = control incl. SRST), ONE master drive (absent slave = bus 0xFFFF),
  **CHS only** (LBA bit ⇒ ABRT, documented deviation), commands
  **IDENTIFY / READ 0x20-21 / WRITE 0x30-31** + BkEmu's own ABRT default.
  Geometry parsed **in hardware from image sector 7** (the AltPro
  partition table, checksum 012701; fallback 63/16/total÷1008, C==0 ⇒
  absent). Status shows **BSY during backend work** — a required deviation
  from BkEmu's zero-latency model. Bus seam: an `ocbk_top` sibling that
  never drives the bus; qbus_mem's `sel_ide` decode owns RPLY both ways
  (fixed `N_IDE`, N_ROM family) and ORs `ide_rdata` into the reply-point
  merge (BkEmu's memory|device OR). Reset DCLO-only (the 5th nINIT
  exception). The 2-bank sector buffer (2 M4Ks) + the req/ack/done sector
  port are the (b) seam — ping-pong-ready for prefetch overlap (tier 1:
  fetch N+1 while the CPU drains N; tier 2: SD multi-block; tier 3
  speculative cross-command read-ahead only if the measured command mix
  wants it), strictly sequential in (a). LBA math rides a serial
  shift-add multiplier (single-cycle products broke sys_clk closure; the
  engine has bus-scale time budgets). Hardware shipped (a) with the port
  tied "no media" (DIP-8-ON showed the BIOS a cleanly ABSENT drive
  instead of bus-timeout probes) — superseded by (b): with a card
  present the drive attaches. Includes the **177130/177132 КНГМД
  (FDD-controller) register stub** (hardware fix 2026-07-18: the BIOS's
  FDD boot attempt — which follows a failed HDD boot — crash-restarted
  the machine when its status polls bus-timed-out; a real SMK's floppy
  controller always replies, no-drive reads = 0 per BkEmu
  FloppyController) and a **drive-access LED on pLed[2]** (~87 ms
  stretch). Oracles: `sim/ide/run.sh` (unit,
  mutation-tested ×9) + `sim/ide/run_soc.sh` (SoC, ×3) +
  `sim/run_boot_check.sh +smk` (the real BIOS boots to its banner with
  the LIVE smk_ide + disk model attached, no X; its actual drive probe
  sits behind the multi-second EMT-0/БК memory test — smk64.mac-traced,
  out of sim reach — so real-BIOS drive I/O was the (b) hardware
  milestone, achieved 2026-07-18; the BIOS driver's PARTRD/RWSEC command
  sequences are the same contract sim/ide transcribes from BkEmu).
- **SD/SPI backend** — ✅ **increment (b) DONE, CONFIRMED ON HARDWARE
  2026-07-18 — the Phase-8 milestone: the SMK BIOS detects the drive and
  boots an OS from the SD-backed HDD image on the board.**
  `src/sd_backend.sv`: an SPI-mode SD host on sys_clk serving the (a)
  sector port — megasd slot PIN_61–66, esemsx3 SPI-mode pin roles
  (DAT3 = CS, CMD = MOSI, DAT0 = MISO; the "reuse esemsx3 SD/SPI"
  reality check: megasd.v is a Z80-mapped single-byte shifter with ALL
  SD protocol in MSX firmware, so the pin map + the two-speed regime
  were the reusable parts and the host FSM is new, in the epcs_boot
  shifter idiom). Init ladder CMD0/CMD8/ACMD41(HCS)/CMD58/(CMD16)/CMD9
  at /256 = 377 kHz then /8 = 12.08 MHz data; **SDSC and SDHC/SDXC**
  (byte vs block addressing, CSDv1 AND CSDv2 capacity → bk_total = the
  full card capacity); CMD17/CMD24 single-block read/write, SPI-default
  CRC policy. The **raw AltPro image is dd'd at card LBA 0**
  (`gen_ide_image.py` emits the dd-able `ide_image.bin`; any
  BkEmu-attachable image works as-is). Reset DCLO-only = card re-init at
  power-on AND warm reset (no card-detect pin: insert card, press
  reset); a failed/absent-card init parks media-absent — the (a)
  behaviour exactly. Oracles: `sim/ide/run_sd.sh` (unit: the
  protocol-checking `sd_model` card, both personalities, injection
  legs, **mutation-tested ×9**), the `sim/ide/run.sh` **`-DSD_STACK`
  second pass** (EVERY transcribed BkEmu smk_ide_tb leg re-run over the
  real SPI stack via `sd_harness` — the decisive integration oracle)
  and `sim/run_boot_check.sh +smk +sdspi` (the real BIOS boot with
  attach riding the full card-init + SPI path). Fit 6,767 LE (56 %),
  STA met TNS 0 (worst +0.077 ns on the quasi-static
  model_bk11→mapper cone; no SDC exception — the SEED-3 rule).
  **Deferred to later increments:** the prefetch/multi-block tiers,
  real data CRC16, MMC cards.
- **512 KB segmented RAM extension** — ✅ **increment 1 DONE IN SIM 2026-07-17**
  (BK-0011M only, enable = **DIP 8**, DCLO-hold-latched like DIP 1). The
  memory-layout piece, and it *was* the Phase-7 coupling: 8 × 4 KB segments
  (seg = `addr[14:12]`) mapped into the `100000–177777` window from the
  0177130 control register (the floppy control register the SMK "ab-uses";
  write-only, two-phase strobe: low nibble == 06 arms, the FOLLOWING write
  commits mode `v[6:4]` + 32 KB page `{v0,v3,v2,v10}`), layered into the
  Phase-7 window-ownership hook as a second `mem_mapper` translate stage —
  NOT a bolt-on. The 512 KB = 256 Kwords live at SDRAM `SMK_RAM_BASE =
  0x40000` (`phys = base | {page, rel, addr[11:1]}`, concatenation-only);
  SMK RAM is `MK_EXT` = the FSM-owned fixed `N_EXT` reply (an external
  controller's RAM is NOT 037-fronted), done-gated both directions on the
  same cpu_sdram_dp port-0 datapath; HLT10's read-only seg 0 = `smk_ro` (a
  write falls out un-replied → trap 4, the ROM-write rule). All 8 BkEmu
  modes (SYS reset default / STD10 / RAM10 / ALL / STD11 / RAM11 / HLT10 /
  HLT11 incl. the SYS/ALL +4 rotation and the BOS/second-window deselects);
  BkEmu `SmkMemoryManager` beat MiSTer on every divergence (reset default
  SYS not STD11, low-nibble strobe compare, per-BkEmu byte-lane masking).
  **Deliberately deferred (now landed in increment 2 — see the next
  bullet):** the BIOS ROM windows and the seg-7 extents. Still deferred:
  bk10+SMK (BkEmu `BK_0010_SMK512`); the SMK-RAM power-on DRAM pattern
  (`ram_init`). Oracles: `sim/run_mapper.sh` (differential smk_en=0
  reference + the directed contract, mutation-tested) and `sim/smk/run.sh`
  (SoC functional oracle with a DCLO-replay second pass, mutation-tested).
- **SMK BIOS ROM + boot** — ✅ **increment 2 DONE, CONFIRMED ON HARDWARE
  2026-07-17** (DIP-8-ON boots the SMK BIOS to its banner on the board): ONE
  4 KB image (`mem/roms/smk512_v205.rom`, BkEmu res/raw) backing BOTH
  selectable windows — rom6 @160000 (SYS/STD10/STD11) and rom7 @170000 (SYS
  only) — appended to the bk11 blob (40960 → 43008 words, SDRAM
  `SMK_BIOS_BASE = 0x3A000`; no third EPCS pass). **The boot hack**
  (user-lore-confirmed, verified against the image): in SYS the rom7 window
  covers the FULL 0170000–0177777 *including the register space*, so the
  vm1's initial-start 177716 read returns `bios[0o7716] | SEL1` (the
  open-collector wire-OR; BkEmu `Computer.readMemory` ORs memory and device
  reads) and PC ← & 177400 = **166400**, inside rom6 — **DIP-8-ON now
  boots the SMK BIOS**. qbus_mem reproduces the merge by latching
  `io_word | ram_rdata` and driving it itself (u_dp fetches via an
  issue-time `rd_noe`/`was_drive` inhibit — the pad-OE rule), with two
  carve-outs (documented deviations): 177700–177717 (vm1-internal; never
  replied/driven, extent writes still posted silently) and 177660–177667
  reads (kbd/037 drive their own data; the smk64 replica carves the same
  hole). Seg-7 restricted extent per mode: ALL = readable (`smk_ro`),
  HLT10/HLT11 = writable (`smk_wo` — the 177674/76 HALT-debugger catch:
  the vm1's HALT-entry stores land in SMK RAM, the vector comes from
  160002/4 = SMK RAM seg 6), others capped → MK_NONE. The 177130 invariant
  refined: the mapper never claims the WRITE there (SYS reads return BIOS
  data). I/O-page MK_EXT accesses take the N_ROM count (the 037's
  start-vector assist replies EARLY at 177716; N_EXT landed the merged
  word after the vm1's sample point — found in sim). With no IDE engine
  the BIOS's drive probes bus-time-out; **observed on hardware: the BIOS
  boots and shows its banner** (the IDE increment brings the drives up).
  Oracles: `sim/run_mapper.sh` (BIOS windows,
  extents, boundary — mutation-tested ×10 total) and `sim/smk/run.sh`
  (boots through the REAL mechanism with a synthetic BIOS image, overlay
  merges, extents, the authentic СТОП/HALT-entry leg, DCLO replay —
  mutation-tested, incl. the increment-1 masked mutation now KILLED);
  `sim/run_boot_check.sh +smk` cold-boots the real BIOS on the full SoC.
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
30% / 1 M4K / 1 ASMI / 1 PLL / timing closes. The Phase-6 keyboard and 1-bit
speaker are **confirmed on hardware 2026-07-07** (typing + keyclick; PS/2 →
1801ВП1-014 equivalent, netlist-golden-validated incl. interrupt latency and
the СТОП trap-4 path). Phase-6 tape **works on hardware 2026-07-10** (the CMT
jack on the right sound channel, Scroll-Lock-gated after the motor-bit
experiment broke right audio; oracle-tested). The Phase-7 50 Hz EVNT/IRQ2
frame interrupt is wired (sim-proven, bk11-only), and the BK-0011M ROM set now
rides a second EPCS blob with SYS_START 140000 — **Phase 7 is done and
confirmed on hardware 2026-07-16: BK-0011M boots and runs BOS, the reset
button switches models**. Phase 8 has started: increment 1 (the SMK512
512 KB segmented RAM extension on DIP 8, BK-0011M only) and increment 2 (the
SMK BIOS ROM + the SYS register-space boot overlay — DIP-8-ON boots the SMK
BIOS through the merged 177716 start vector) are done, **increment 2 confirmed
on hardware 2026-07-17: the SMK BIOS boots to its banner** (see the Phase-8
section). Remaining deferred items: the SMK IDE/SD increment, bk10+SMK, the
SMK-RAM ram_init pattern, `N_VREG`/`N_EXT`/`N_SMKREG` calibration and 0011M
cycle-accuracy vs a reference (reference-tb-first).*
*See also the project memory notes `bk-on-1chipmsx-feasibility` (bring-up history),
`bk-video-pipeline-decision` (Phase 3/4 design) and `bkemu-reference-and-roms`
(BkEmu is the canonical BK reference; ROMs committed in-tree).*
