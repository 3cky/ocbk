# CLAUDE.md

Guidance for working in this repo. Keep it current as the project grows.

## What this is

`ocbk` runs the Soviet **Elektronika BK-0010 / BK-0011M** (PDP-11-class) as
alternative firmware on the 1chipMSX / OneChipBook board (Altera Cyclone I
**EP1C12Q240C8**, Quartus II 11.0). The headline goal is **cycle-accurate** CPU
behaviour.

**Phases 0–9 are done and confirmed on hardware; Phase 10 is functionally
complete and hardware-confirmed but NOT yet marked done** — it still carries a
debug feature (the DIP-5 self-test tone) that must be retired from the shipped
build, and three of its four hardware acceptance recordings are uncollected. The
completion checklist is under Open / deferred. See README.md for the current
result. This file is now the authoritative document: the per-topic
bullets below carry each finding in its most current form, and they, not this
table, are the detail. (ROADMAP.md held the forward-looking plan and was folded
in here once the last phase landed; `git show e85efbf:ROADMAP.md` has the full
phase-by-phase narrative if the history is ever wanted.)

| Phase | Delivered | Confirmed |
|---|---|---|
| **0** Platform | one-PLL clock tree, SDRAM BIST, 1024×768@60 VGA (built in `ocb-test`) | ✅ |
| **1** CPU bring-up | `vm1` (1801ВМ1) on EP1C12 + Q-bus wrap; the `sim/bk10` per-instruction cycle oracle | ✅ |
| **2** BK RAM in SDRAM | Q-bus⇄SDRAM bridge, byte-granular writes, deterministic wait-state FSM | ✅ |
| **3** 037 arbiter | `va_037_sync` (retimed 037) owns RAM RPLY + the cycle-stealing grant; `sdram_arbiter` (4 ports), `cpu_sdram_dp` done-gate; `sim/ref037` goldens | ✅ |
| **4** Video pipeline | 037 fetch → `palette_apply` → 4-bit-index double-buffered FB in SDRAM → `fb_readout` → 1024×768@60 (×2H/×3V) | ✅ |
| **5** SoC boot | full BK-0010.01 ROM in SDRAM + the EPCS loader; ROM writes → trap 4 | ✅ HW 2026-07-03 (BASIC Vilnius banner) |
| **5.5** Soft reset | reset button re-enters the DCLO/ACLO sequencer; memory + display survive | ✅ HW 2026-07-05 |
| **6** Peripherals | PS/2 → 1801ВП1-014 equivalent (VIRQ/IAK, СТОП), 1-bit speaker, CMT tape on the right sound jack | ✅ HW 2026-07-07 (kbd + sound), 2026-07-10 (tape) |
| **7** BK-0011M mode | DIP 1 model select, /24 CPU clock, 177716 banking mapper, 177662 video register, 50 Hz EVNT/IRQ2, СТОП-block, two-pass EPCS loader, authentic DRAM power-on pattern | ✅ HW 2026-07-16 (BOS boots; reset switches models) |
| **8** SMK512 (DIP 8) | 512 KB segmented RAM, BIOS ROM + the SYS register-space boot overlay, IDE drive engine + tier-1 prefetch, SD/SPI backend — in **both** models | ✅ HW 2026-07-23 (BIOS boots an OS off SD) |
| **9** Fidelity & polish | authentic EVNT/IRQ2 instant (`bk_evnt`); `N_EXT` calibrated against a real machine; `N_VREG` closed; palette sample instant; the **037 grant-rule fit** + `bk_rply` (the beam-race skew); **turbo mode** | ✅ HW 2026-07-26 (grant rule: Babylona/PALTST flat), 2026-07-29 (turbo) |
| **10** Audio subsystem | `src/audio/`: N-slot stereo **mixer** + a noise-shaped 6-bit output stage (>6-bit audio-band resolution on the same ladders), **true stereo** with a CMT mono fold, the DIP-5 self-test tone, and the **177714 capture seam** for the sound devices. **Infra only — no new sound device** | 🚧 **IN PROGRESS** — sim ✅ (23 mutations); the resolution claim is ✅ HW 2026-07-31 (staircase off the jacks: −6.047 dB/step over 42 dB, max residual 0.19 dB, the three sub-ladder-step levels on the line) and the shipped bitstream boots, but the phase is **not done until the DIP-5 debug tone is out of the shipped build and the remaining acceptance recordings are collected** — checklist under Open / deferred |

## Platform & system map

The hardware envelope and the whole-system picture. The per-module rules live
under "Architecture & conventions" further down.

### Source building blocks (vendored — re-sync from these, don't reinvent)

| Block | Upstream | Notes |
|-------|----------|-------|
| **1801ВМ1 CPU** | `~/projects/other/fpga/cpu11/vm1/hdl/syn` | Gate-accurate reverse-engineered model → `src/cpu/`. Ships its own `sim/bk10` timing testbench (our first oracle). No EIS — fine, Cyclone I has no multipliers. Keep the marked `pin_sel_n` hook (see the conventions section). |
| **1801ВП1-037** | `~/projects/other/fpga/k1801/037/rtl` | `va_037.v` (refactored) + `vp_037.v` (netlist). **`va_037.v` is the reference `sim/ref037` and `sim/evnt` generate their goldens from** — it is ground truth, and `src/bus/va_037_sync.sv` is its retime. |
| **1801ВП1-014** | vendored into `sim/ref014/` | The keyboard gate netlist + `lib_1801.v`. Wins every dispute with `src/peripheral/bk_kbd014.sv`. |
| **Platform harness** | `~/projects/other/fpga/ocb-test` | Where the clocking, SDRAM and VGA were validated. `src/sdram/sdram_ctrl.sv` and `src/video/vga_timing.sv` come from here. |
| **Toolchain reference** | `~/projects/other/fpga/ocm-pld-dev/esemsx3` | Pin map, build flow, the CMT-jack scheme, the megasd SPI pin roles. |

Behaviour references (not code): **BkEmu** (`~/projects/studio/BkEmu`) is the
canonical BK register/software reference; **MiSTer `BK0011M_MiSTer`** wins on
the 177662 register specifically; `doc/bk0011m.sch` is the real board.

### Platform constraints (validated on hardware — design within them)

- **One usable PLL.** The 21.47727 MHz crystal (PIN_28) can feed only ONE PLL
  ("input pin cannot feed inclk ports of more than 1 PLL"), so *every* clock is
  a ÷N of the single VCO or a fabric clock-enable. Never add a second PLL.
- **PLL VCO ceiling ≈ 400 MHz** on the −8 part: coprime ratios needing a higher
  VCO simply fail to fit. That ceiling plus the one-PLL rule plus the board's
  21.47727 MHz crystal is why the BK-0011M CPU rate is **4.0270 MHz** and not
  the real machine's 4.000 (+0.67 %) — the design's only known sub-1 % timing
  error against real hardware, and unfixable short of a different crystal (see
  the `N_EXT` bullet).
- **On-chip RAM ≈ 239,616 bits (~26 KB).** BK-0010's 32 KB RAM alone exceeds
  it, and the ROM set is 262 Kbit — so **BK RAM *and* ROM live in the board
  SDRAM**, not block RAM. This is the root reason the arbiter/done-gate
  machinery exists at all.
- **The panel is standard-VESA-only (≥~60 Hz).** It matches its input by
  (line-rate, total-lines) against a VESA table, and the native BK 48.83 Hz
  full-screen rate is mis-detected as "not supported" — so the output is
  **1024×768@60** and the 48.83→60 gap is bridged in the framebuffer. This is
  the entire reason for the decoded double-buffered FB rather than a genlocked
  line buffer. A judder-free native path would need a different display
  (multisync CRT on analog RGB, or an OSSC-class scaler).

### Settled clock tree — single ×9 VCO (193.3 MHz)

| Output | Divide | Freq | Use |
|--------|--------|------|-----|
| clk0 | ÷2 | **96.65 MHz** | `sys_clk`: SDRAM controller + the chip clock (`extclk0` → `pMemClk`, phase-matched) |
| clk1 | ÷3 | **64.43 MHz** | `pix_clk`: 1024×768@60 readout |
| (enable) | 96.65 ÷8 | **12.08 MHz** | BK dot clock; 037 CLKIN = ÷2 = 6.04 MHz |

CPU clock = a fabric divider of `sys_clk` in `src/sys/cpu_clkgen.sv`: **/32 =
3.02 MHz (BK-0010), /24 = 4.03 MHz (BK-0011M), /16 = 6.04 MHz (turbo)**. All
integer ratios, so the design is internally cycle-exact; the absolute rate is
+0.674 % with the CLKIN:CPU ratio preserved exactly (see the clocking bullet).

### Whole-system shape

```
                       ┌────────────────────────────────────────┐
   21.477 MHz xtal ──► │ single PLL (×9 VCO): 96.65 / 64.43 MHz │
                       └────────────────────────────────────────┘
                          │ 96.65 (sys/SDRAM)        │ 64.43 (pixel)
                          ▼                          ▼
   ┌─────────┐  Q-bus  ┌───────────────┐  SDRAM   ┌──────────────────┐   ┌────────┐
   │ vm1 CPU │◄───────►│ va_037_sync + │◄────────►│ sdram_arbiter +  │◄─►│ SDRAM  │
   │ 1801ВМ1 │ sync/   │ qbus_mem +    │ reqs     │ sdram_ctrl       │   │ 32 MB  │
   │ 3-6 MHz │ din/dout│ mem_mapper    │          │ (RAM+ROM+FB)     │   └────────┘
   └─────────┘ /rply   │ (RPLY owner,  │          └──────────────────┘
        ▲              │  wait states) │                    │ pixel rows
        │ IRQ/VIRQ     └───────┬───────┘                    ▼
   ┌────┴──────────┐           │ video fetch (port 2)
   │ bk_kbd014,    │           ▼                      ┌──────────────────┐  RGB DAC
   │ bk_evnt,      │   ┌───────────────┐              │ fb_readout →     │─►+ HS/VS
   │ smk_ide/sd    │   │ palette_apply │ FB via SDRAM │ fb_linebuf →     │
   └───────────────┘   │ → fb_video    │─────────────►│ vga_out (1024x   │
                       └───────────────┘              │  768@60, x2/x3)  │
                                                      └──────────────────┘
          spk_bit ──┐   ┌──────────────┐             ┌──────────────┐
   self-test tone ──┼──►│ audio_mixer  │─ L,R ──────►│ audio_out    │──► Sound-L
   177714 devices ··┘   │ gain/pan/en  │  signed 16  │ 2x audio_ns6 │──► Sound-R
        (not built)     │  saturating  │ (l+r)>>1 in │ + CMT jack   │  two 6-bit
                        └──────────────┘  CMT mode   └──────────────┘  R-2R ladders
```

The signal that carries cycle accuracy is the 037's **grant / RPLY timing**:
the SDRAM is far faster than BK's bus, so the contention ("the screen slows the
CPU") is *modelled deliberately*, never left to emerge. From Phase 3 on the
SDRAM is contended by four clients, so a CPU access is not guaranteed to hide
inside its RPLY window by margin alone — the **done-gate** makes a late word
extend RPLY rather than latch stale data.

### SDRAM word map

`src/qbus_pkg.sv` is the source of truth (the `*_BASE` localparams); this is
the orientation copy. All bases are power-of-two aligned so the mapper's
physical translation is pure concatenation — no adders.

| Words | Contents |
|---|---|
| `0x00000–0x03FFF` | BK-0010 RAM `000000–077777` |
| `0x04000–0x07F7F` | BK-0010 ROM `100000–177577` (linear `addr[15:1]`) |
| `0x10000` / `0x18000` | framebuffer FB0 / FB1 (128 words/line × 256 lines) |
| `0x20000` | `BK11_RAM_BASE` — 8 × 0x2000 RAM pages (page 1 = screen 0, page 7 = screen 1) |
| `0x30000` | `BK11_WROM_BASE` — 4 window-1 ROM banks (2 and 3 unpopulated) |
| `0x38000` | `BK11_TOPROM_BASE` — fixed `140000–177577` ROM |
| `0x3A000` | `SMK_BIOS_BASE` — the one 2048-word SMK BIOS image (both windows) |
| `0x40000–0x7FFFF` | `SMK_RAM_BASE` — SMK512 RAM, 128 segments × 2 Kwords |

### Source tree

The split mirrors the groupings this document already used, and follows the
esemsx3 convention: functional subdirectories, the top level and the shared
package loose at the root of `src/`, the vendored core in its own directory.
`ocbk_common.qsf` lists every file one per line **in compile order** — that is
not the directory order and must not be shuffled; `ocbk.f` (the slang/verilator
filelist) mirrors the same set and must be kept in sync with it.

```
src/ocbk_top.sv     top: PLL, resets, DIP latches, LEDs, the sibling peripherals
src/qbus_pkg.sv     shared Q-bus decode + the RPLY-latency constants (N_*)
src/cpu/            vendored vm1 core (1801ВМ1) + config + the synth vcram stub
--- src/bus/ (Q-bus front end, RPLY ownership, address translation) ---
va_037_sync.sv      retimed 1801ВП1-037: RAM RPLY, grants, video counters, GRANT_SETUP
bk_rply.sv          the board's D8:B flop re-timing the 037's reply onto CPU RPLY
qbus_mem.sv         bus front-end: region reply FSM, 177662/spk/stop captures,
                    the SMK/IDE decodes, the boot-writer mux
mem_mapper.sv       the one translate seam: (addr, map regs) -> (kind, phys word)
qbus_sdram.sv       retired Phase-2 RAM slave (kept for its cosim only)
qbus_slot.sv        cartridge-slot bridge (forward seam, SLOT_ENABLE=0)
--- src/sdram/ (the SDRAM datapath and its writers) ---
cpu_sdram_dp.sv     CPU RAM/ROM datapath on arbiter port 0 + the RPLY done-gate
sdram_arbiter.sv    4-port fixed-priority arbiter (CPU/readout/fetch/FB write)
sdram_ctrl.sv       vendored single-word SDR controller (+ the byte-enable hook)
ram_init.sv         authentic К565РУ6/РУ5 power-on DRAM pattern filler
epcs_boot.sv        two-pass EPCS flash -> SDRAM loader (cyclone_asmiblock)
--- src/video/ ---
fb_video.sv         037 fetch -> palette -> FB writer (ports 2+3, buffer swap)
palette_apply.sv    16-palette stage (MiSTer palette ROM; bk10 = palette 0)
fb_readout.sv       paced FB line prefetcher (port 1) + the pixel-side CDC
fb_linebuf.sv       dual-clock ping-pong line buffer (1 M4K)
vga_out.sv          1024x768@60 scan-out: scheduling, colour decode, x2/x3 scale
vga_timing.sv       vendored VESA timing generator (ocb-test, board-proven)
--- src/peripheral/ ---
ps2_rx.sv           PS/2 frame receiver           kbd_ps2bk.sv  scan -> BK codes
bk_kbd014.sv        1801ВП1-014 equivalent (177660-663, VIRQ/IAK)
bk_evnt.sv          the real 0011M D28+D3:B EVNT/IRQ2 missing-pulse detector
smk_ide.sv          SMK512 IDE task file + ATA engine + tier-1 prefetch
sd_backend.sv       SPI-mode SD host serving the smk_ide sector port
--- src/audio/ (Phase 10; audio_* = generic, bk_* = BK-specific) ---
audio_ns6.sv        1st-order noise-shaped 16->6-bit quantizer (ONE channel)
audio_mixer.sv      N-slot stereo mixer: compile-time gain/pan, runtime enable
audio_tone.sv       the DIP-5 self-test: 2 DDS voices + the 6 dB staircase
audio_out.sv        pad stage: DAC rate, 2x ns6, CMT mono fold + the CMT jack
bk_audio.sv         the assembly: speaker CDC/activity + the SLOT MAP
--- src/sys/ (clocking / CPU-rate control) ---
cpu_clkgen.sv       fabric divider: dot/CLKIN enables + the CPU clock (/32,/24,/16)
turbo_ctl.sv        bus-idle-qualified turbo level (the reply-owner swap guard)
--- generators / images ---
mem/gen_mem.py      ROM test-program assembler + the test picture
mem/gen_boot_blob.py boot-blob builder (header/checksum + the COF hex pages)
mem/gen_ide_image.py synthetic AltPro HDD image (also the dd-able ide_image.bin)
mem/gen_*_test.py   the per-oracle SoC test programs
mem/roms/           BK-0010.01 + BK-0011M ROM sets + the SMK BIOS (from BkEmu)
test/               the sndtest* tone programs (.mac source / .bin image /
                    .wav recording) — the real-hardware timing measurements
doc/                bk0011m.sch, bk0011m-sch.pdf, smk64.mac
```

Oracles live in `sim/` — see "Verification discipline" for what each one pins.

### BK-0011M memory model (what the mapper implements)

128 KB RAM as **8 × 16 KB pages**, plus 4 × 16 KB ROM pages. Of the four 16 KB
CPU windows, **two are banked** — `040000–077777` (window 0) and
`100000–137777` (window 1) — while `000000–037777` is a fixed RAM page and
`140000–177777` is fixed top ROM + I/O. Both banked windows draw from the same
8 RAM pages; window 1 can map either a RAM page or one of the ROM pages. The
map lives in **177716** (word writes, bit 11); the displayed video page and
palette live on a *separate* register, **177662**. See the mapper bullet for the
exact bit fields and the reset rule.

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

## Verification discipline (do not skip)

Cycle accuracy is the whole point. All `make sim` oracles must stay green:
- `sim/bk10/run.sh` — the upstream timing testbench vs `sim/bk10/golden.txt`
  (the CPU core's per-instruction cycle counts). Independent of the SDRAM work.
- `sim/ref037/run.sh` — **fourteen diffs against TWO golden sets** (Phase 9;
  it was twelve against one). The shipped 037 now carries a deliberate,
  hardware-calibrated deviation from the vendored netlist (the `GRANT_SETUP`
  window + `bk_rply`, see the beam-race bullet), so one pair can no longer
  serve both — and the split is explicit rather than papered over:
  **`golden_037{,_rom}.txt` are the NETLIST's**, generated ONLY from a
  reference run, and `va_037_sync` is still diffed against them **at
  `GRANT_SETUP=0`** — that is what still guards the sys_clk retime, and it
  proves the parameter folds away exactly. **`golden_037_hw{,_rom}.txt` are
  the SHIPPED machine's**, generated from the same simplest stack
  (`ref037_sync_tb`, behavioural DRAM) at the shipped setting via
  `run.sh --regen-hw`, and every integration leg reproduces them — the same
  structure the single pair had, with silicon rather than the netlist as the
  authority. **Never "fix" a `_hw` diff by regenerating from a netlist run.**
  The `_hw` delta is +4 cycles (one /32 slot) on 037-arbitrated fetches only;
  the ROM self-loop stays flat, which is the invariant that matters.
  What the legs cover, vs `golden_037*.txt` (with-display timing,
  program in RAM) and `golden_037*_rom.txt` (Phase-5: same program words executed
  *from the ROM region* — ROM is never 037-cycle-stolen, so its self-loop is
  **flat**; the RAM loop beats): the reference netlist,
  the retimed `va_037_sync` (both settings), the SoC integration (instantiating the *real*
  `qbus_mem`) with a synthetic port-2 saturator, the `+bootload` run (the
  EPCS loader populates SDRAM through the boot-writer mux, then golden must
  still match), **`ref037_soc_video_tb`** — real video pipeline on all 4
  arbiter ports, golden window exact, then 64 display lines with the loop
  invariant intact (RAM beat pattern / ROM flat-13), plus `FETCH-ROMGATE` /
  `FETCH-P0LAT` watchdogs — and three **`+warmreset` replays** (Phase-5.5 soft
  reset: DCLO/ACLO re-pulsed mid-run, mid-display-line in the video tb) where
  BOTH passes are diffed against the *same unchanged golden*: a warm reset must
  be cycle-identical to a cold boot — **never regenerate a golden for a
  warm-reset change**. Error prints carry a `FETCH-` prefix so run.sh's
  `/^FETCH/`-only reduce filter lets them break the diff — keep that convention
  (the reduce's loop-sample counter re-arms on any non-loop line; that is what
  gives each warm-reset pass its own 4 self-loop samples).
- `sim/ref014/run.sh` — the Phase-6 keyboard oracles, **four legs**. Contract:
  the vendored `vp_014.v` **gate netlist** (+ `lib_1801.v`) runs the shared
  transaction-granular scenario (`ref014_scenario.v`) → `golden_014.txt`, and
  the behavioral `src/peripheral/bk_kbd014.sv` must reproduce it line-for-line (netlist
  wins all disputes; the pinned contract — press-while-ready queuing with
  key-held re-delivery, retro-fire on unmask, no АР2 flag in 662 bit 7, 662
  writes bus-timeout, INIT keeps the code register — is in
  `sim/ref014/README.md`). Interrupt latency: the `mem/gen_kbd_test.py`
  program (VIRQ 060/0274 ISRs, masked press, nIRQ1 pulse → **trap 4**, the
  authentic СТОП path) runs on the netlist reference stack →
  `golden_kbd.txt`, and the SoC stack (va_037_sync + qbus_mem + SDRAM
  model + bk_kbd014) must match the same golden — this diff calibrated
  `N_KBD`/`N_IAK` (=1) and the write fast path. **Goldens regenerate only
  from netlist runs.**
- `sim/run_ps2.sh` — the PS/2 front end (`ps2_rx` + `kbd_ps2bk`) against a
  hand-written expected event list: BkEmu case algebra over ЛАТ/РУС ×
  ЗАГЛ/СТР × НР, СУ masking, АР2 + the silicon auto-274 code group,
  typematic suppression, multi-key `key_down`, СТОП strobes, the Print
  Screen radial toggle (screen_mode), the **F12 radial toggle (turbo, §12d:
  one toggle per press, typematic suppressed, never a matrix event, never in
  the held-key list, and an E0-prefixed 07 must NOT be F12)**, Scroll Lock now
  emitting no event (CMT tape mode moved to DIP 4), parity-error and
  stale-prefix recovery.
- `sim/run_audio.sh` — the Phase-10 audio oracles, **four legs, mutation-tested
  ×23**; `sim/audio/README.md` carries the pinned contract and the written
  justification for the resolution claim (the `sim/evnt/README.md` precedent).
  **Leg 3 `audio_ns6_tb` is the one that matters**: it proves the DC **identity**
  `1024·Σcode − M·(32·1024+s) == errp₀ − errp_M ∈ [−1023,1023]` — not a
  tolerance, it telescopes out of the loop and holds for every M, so the mean
  emitted code tracks the input to <1/1000 of a ladder step where plain
  truncation is off by up to 512 units *per sample*. Its sharpest leg (L4b)
  reconstructs **a signal of amplitude 512 = HALF ONE LADDER STEP** to 10/1024
  of a code, which a 6-bit truncating path renders as silence or a 1-bit
  square; plus exact silence, the clamp (an overload must not WRAP), and tick
  discipline. **Leg 4 `audio_mixer_tb`**: gain against an independently written
  floor reference, pan, runtime enable, saturation never wrapping, the
  **`NSRC=1` pass-through invariant** (the `smk_en=0`/`turbo=0` differential
  idiom — what guarantees the speaker-only shipped path is unperturbed) and the
  planned `NSRC=10` shape. **Leg 1 `bk_audio_tb`** is the regression guard for
  the two hardware-confirmed behaviours — the speaker's STATIC rail codes and
  the whole CMT jack (oe split, comparator network, anti-echo, raw tape-out) —
  plus true stereo, the CMT mono fold and the staircase. **Leg 2
  `spk_capture_tb`** keeps the 177716 bit-6/7 captures and gains the **177714
  (nSEL2) port-write capture**, whose load-bearing case is the WTBT
  discriminator (see the audio bullet).
- `sim/run_clkgen.sh` — the Phase-7 `cpu_clkgen` unit oracle: BK-0010 (/32)
  mode **bit-identical** to a replica of the pre-Phase-7 `divc[4]` tap
  (enables included), the /24 BK-0011M rate exact, and a retarget sweep (no
  half-period outside **8..16** sys_clk). The SoC tbs replicate the divider
  locally, so this is the only sim coverage of the real chain. **Leg D is the
  Phase-9 turbo rate** (/16 = 6.04 MHz): the steady half-period exact, turbo
  OVERRIDING the model select both ways, and — because turbo is a LIVE control
  unlike the DCLO-latched model — turbo flips at every count phase plus
  turbo×model cross-flips. `dut0` has turbo tied 0 at the port, so leg A's
  BK-0010 bit-identity is preserved by construction.
- `sim/run_mapper.sh` — the Phase-7 `mem_mapper` unit oracle: BK-0010 mode
  swept over **all 64K addresses** against the pre-Phase-7 inline decode
  (before AND after banking writes — bk10 decode must be map-content-
  independent), plus the full BK-0011M banking contract (window pages, the
  four ROM overlay codes, the & 0o033-quirk fall-through, word-write-only
  banking, `bank_wr` mutual exclusion, DCLO-only re-init, model_bk11 flips
  keeping register content). **Phase 8 (SMK512):** a differential smk_en=0
  reference instance pins every non-SMK configuration bit-identical over
  full-64K sweeps (smk_en=0 both models, disabled-time 177130 writes never
  snooping) and the SMK-live low 32K (000000-077777) identical in BOTH
  models, plus the directed BkEmu
  `SmkMemoryManager` contract: the 177130 two-phase strobe (arm/commit
  edges, re-arm-not-commit, byte-lane masking incl. the junk-low-lane
  vector), the 8-mode × 8-seg table with the SYS/ALL +4 rotation, the
  `{v0,v3,v2,v10}` page scatter, HLT10 seg-0 `smk_ro`, std segs tracking
  live banking, register-file mutual isolation, DCLO-only reset (armed
  strobe cleared), enable/model flips keeping content. **Increment 2 (BIOS
  ROM):** the rom6/rom7 BIOS windows (SYS/STD10/STD11 vs SYS-only; ONE
  shared 2048-word image at `SMK_BIOS_BASE`, rom7 spanning the whole
  segment incl. the register space — the 177716 boot overlay, 177130
  included on the READ side under SYS), and the per-mode seg-7 restricted
  extent 0177000–0177777 (ALL readable/`smk_ro`, HLT10/HLT11
  writable/`smk_wo`, others capped → MK_NONE, boundary exact at 177000).
  **Mutation-tested ×10** (increment 1: scatter swap, arm-edge commit, cap
  drop, lane-mask drop, mode-mask break; increment 2: rom7 drop, rom6/rom7
  selection swap, extent direction swap, extent boundary off-by-one, wrong
  BIOS base bit — all fail). **bk10+SMK (S2 + S11):** the whole 8-mode x
  8-segment table walked from BK-0010 — the monitor ROM at segs 0,1 in
  SYS/STD10/STD11/RAM11 (`mon_en`), the ex-BASIC region MK_NONE wherever
  the SMK does not cover it, HLT11 the one mode where `mon_en` shows (segs
  0-3 dead), HLT10's seg-0 `smk_ro` + the 177674/76 write-only extent, the
  page scatter and rotation shared with bk11 across a model flip, and
  DIP-8-off returning the plain bk10 pass-through (**+5 mutations**: drop
  `mon_en`, widen `std_vec` in bk10, force segs 0/1 to MK_NONE, restore the
  `model_bk11` gate on `smk_act` / on `smk_reg_wr` — all fail).
- `sim/smk/run.sh` — the Phase-8 SMK512 SoC **functional** oracle
  (data-checking, sim/bk11 conventions: pinned parks 001004/001012, vector
  4 → fail, `COSIM PASS`): the `mem/gen_smk_test.py` program **boots
  through the REAL SMK mechanism** — the tb preloads a synthetic BIOS image
  (`smk_bios.hex`) at `SMK_BIOS_BASE` and NOTHING in SMK RAM; the SYS rom7
  register-space overlay makes the initial-start 177716 read return
  `bios[0o7716] | SEL1` → PC 166400 in the rom6 window — and walks the
  whole contract on the real SoC stack (smk_en=1, /24 rate, port-2
  contention, a **1<<19-word sdram_model**): the 177130 write reply +
  no-commit-without-arm, the BIOS windows (one image both windows, writes →
  trap 4, 177130/177132 reads replied everywhere — the КНГМД stub: BIOS
  word merged under SYS, 0 elsewhere), the I/O-page
  OR-merge (177714 pure-BIOS, 177776 BIOS-only, 177716 masked-merged) with
  the kbd (177660 → trap 4) and vm1-internal (177712 self-served, X-monitor
  tripwire) carve-outs, SYS/RAM10 fill/verify with cross-mode aliasing, the
  ALL +4 rotation over all 8 segs, pages 2 and 8 end-to-end, **executing
  FROM SMK RAM and switching the mode under the running code** (the routine
  is program-copied into seg 2 — no tb preload), RMW in SMK RAM, HLT10
  seg-0 read-only (write AND RMW-write-half → trap 4, value intact), the
  per-mode extents (HLT10 writes replied incl. 177674/76 + reads trap; ALL
  reads the HLT-written words back via the seg-3 mem aliases + writes trap;
  STD10 capped), a COMMITTED SYS re-selecting both windows, STD11 std
  passthrough (win-1 banking + overlay + top ROM + a masked 177662 write +
  160000 = BIOS shadowing MSTD), the RESET instruction preserving the
  layout, the **authentic СТОП/HALT-entry leg** (HLT10: the program plants
  the HALT vector in SMK RAM seg 6, the tb pulses key_stop, the vm1's
  PSW/PC stores land in the writable extent, the handler verifies the
  stored PC via the ALL alias), then a **tb DCLO replay**: the second boot
  re-runs the real boot mechanism and re-verifies SYS + BIOS windows
  restored + SMK RAM content survived + the 662 taps back at defaults.
  **A SECOND LEG (`--bk10` / `+bk10`) re-runs the whole contract on a
  BK-0010 stack** (model_bk11=0, /32 rate, the program resident in the
  machine's own RAM at SDRAM 0x0000, SYS_START = 0100000): the monitor ROM
  at segs 0,1 (read + write-traps) in SYS/STD10/STD11/RAM11, the ex-BASIC
  region dead in STD11/RAM11 (a tb marker at SDRAM 0x5000 must never show),
  HLT11's `mon_en` kill, RAM11's mixed layout, and the BIOS's own
  MODEL-DETECT mechanism (a SYS 177662 write must trap on a bk10 — the tb
  additionally requires the 662 taps still at their DCLO defaults at the
  park).
  **Mutation-tested ×8 at the SoC level** (see the run.sh header — incl.
  the increment-1 documented masked mutation, now KILLED by the reworked
  issued-legs done-gate).
- `sim/ide/run.sh` — the Phase-8 **SMK512 IDE unit oracle**: `src/peripheral/smk_ide.sv`
  (the task-file register block + ATA engine + AltPro geometry parse)
  driven with Q-bus-shaped transactions against the behavioral
  `ide_disk_model` loaded with `mem/gen_ide_image.py`'s synthetic AltPro
  image (C/H/S 10/4/16 = 640 sectors, valid sector-7 partition table +
  checksum). Transcribes **BkEmu `IdeControllerTest`** + the
  `SmkIdeController` bus packing: the reset snapshot through the ~
  inversion (plus one raw-inversion pin so a dropped inversion can't
  cancel out), SRST assert/release, the absent slave (bus 0xFFFF, command
  writes ignored), the 740/742 exact-byte-address lane rules (COMMAND only
  at 177740; control register only via byte 177743), DHR |0xA0 forcing,
  IDENTIFY with the full word map + the per-word 0x58-during/0x50-after
  status contract, single-sector READ of **every** sector with an
  explicit per-sector CHS (the wrap boundaries data- and register-checked;
  **last-read semantics** — a command leaves the registers on the sector
  it just transferred, so there is NO cross-command auto-advance, and a
  repeat READ with unchanged CHS re-reads the same sector — the leg-5
  regression), multi-sector chains
  (COUNT=0 ⇒ 256), WRITEs verified against the model's backing store + a
  read-back round trip, ABRT for unsupported opcodes AND the LBA bit (the
  documented CHS-only deviation), data hold across the DIN window, and
  the geometry legs (valid parse; broken checksum ⇒ raw defaults 63/16;
  default C = total/1008 == 0 ⇒ attach fails, drive absent). **Tier-1
  prefetch legs (6b/6c/6d):** 6b a COUNT=4 chain data-exact with a
  mid-drain SNUM read pinning the visible CHS at the CURRENT sector in
  transfer (never advanced early at a prefetch's own bk_done), no BSY window at the boundary (disk pass), and
  exactly one backend op per sector (`ack_cnt`); 6c (disk pass) a slowed
  backend so the drain outruns the prefetch → a real BSY window then the
  swap DRQ; 6d the E_FLUSH mid-command interlock — a fresh COMMAND, an
  SRST, and a WRITE each dispatched while a prefetch is in flight, all
  recovering data-exact (the WRITE's backing-store check catches fill
  words dropped into a backend-owned port). An `overlap_seen` spy asserts
  the overlap actually occurred. **Mutation-tested ×14** (see the run.sh
  header — inversion drop, packing swap, lane rule, E_DRAIN swap-branch
  removed, CHS off-by-one, 1-based snum drop, checksum bound/seed, 0xA0
  drop; + prefetch 10–14: bank-invert drop, unconditional swap, flush
  removed, CHS-at-prefetch-done, scount-guard drop — all fail).
- `sim/ide/run_soc.sh` — the Phase-8 **IDE SoC functional oracle**
  (sim/smk conventions: real boot mechanism, /24 rate, port-2 contention,
  parks 001004/001012, `COSIM PASS`): the `mem/gen_ide_test.py` program
  drives the task file through the real qbus_mem reply machinery — the
  SYS rom7|device OR-merge at 177752 (both contributions visible in one
  exact compare), IDENTIFY/READ/WRITE end-to-end with the **BSY commit
  phase**, ABRT + LBA + SRST recovery, the **HLT10 write-only-extent
  broadcast** (a task-file write lands in SMK RAM AND the device; the
  read back rides the sel_ide-only reply), the ALL-mode seg-3 alias
  readback + extent|device merged read, and the absent slave.
  **Mutation-tested ×3 at the SoC level** (run_soc.sh header: qbus_mem
  merge-term drop, write-claim drop, command lane swap — all fail).
- `sim/ide/run_sd.sh` — the increment-(b) **SD backend unit oracle**:
  `src/peripheral/sd_backend.sv` (the SPI-mode SD host serving the backend sector
  port) against the protocol-checking `sd_model.v` card (CRCs, CMD55
  pairing, SDSC 512-alignment, init ordering — card protocol errors
  fail the run) loaded with the same AltPro image. Legs: the exact
  init transcript (>=74 dummy clocks, CMD0/CMD8/ACMD41-with-HCS/CMD58/
  CMD16-iff-SDSC/CMD9) for BOTH personalities (SDHC/CSDv2 and +sdsc
  v1/CSDv1 — both capacity formulas land exact in bk_total), reads
  data-exact incl. past-image sectors, oob completing with ZERO SPI
  traffic, write/store-check/readback, and the +noinit/+rderr/+wrrej
  injection legs — at the REAL dividers (/256 init, /8 data). **Leg 4 is
  the warm-reset recovery leg:** `rst_n` is pulsed with the CARD LEFT
  UNTOUCHED (what DCLO does on the board), landing MID-single-block-read,
  so the card still holds ~half a block that the preamble must flush
  before CMD0 — and that sector deliberately opens with a long 0xFF run
  (what a BK disk really looks like on the card, since the IDE layer
  inverts), which is the case a flush that stops when the bus merely
  LOOKS idle gets wrong. The leg also asserts `dbg_retried == 0`: ONE
  recovery pass must suffice, so the automatic retry cannot hide a weak
  recovery. Two injection runs cover the retry itself — **`+cmd0busy`**
  (the card answers no CMD0 for 25 ms; only a host that re-runs its
  WHOLE recovery between attempts outlasts it) and **`+cmd8junk`** (an
  SDHC card whose first CMD8 answers illegal-command: a host that only
  retries CMD0 types it v1, sends ACMD41 without HCS and stalls forever
  — the mechanism that made the board need two reset presses).
  **Mutation-tested ×14** (run_sd.sh header:
  SDSC ×512, CMD8 CRC, HCS, capacity off-by-one both formulas, LE byte
  swap, commit settle, R1 poll, oob guard, dummy clocks; + the recovery:
  preamble removed, flush removed, flush exits early, recovery not
  re-run, CMD0-only retry — all fail). The preamble's 0xFD/CMD12 pair is
  deliberately NOT mutation-covered, and the header says so out loud:
  since the revert nothing in this design can open a multi-block stream,
  so no leg can kill their removal — they are insurance against a card
  left streaming by other firmware. `sim/ide/run.sh`
  additionally re-runs the ENTIRE smk_ide_tb leg set with `-DSD_STACK`
  (`sd_harness` swaps the disk model for the real sd_backend+sd_model
  stack; sim-speed /2 dividers there — the ratios are run_sd.sh's job;
  +sdsc because CSDv1 encodes the tb totals 640/2016 exactly) — the
  decisive engine+backend integration pass. It earns that name: it is
  what caught the `enable_q` reset-value bug (an enable registered for
  timing reset to 0, so S_SETTLE's first evaluation parked the backend
  in the DEAD-END `S_DISABLED` state on every reset, card present or
  not) after run_sd.sh alone had been run and passed.
- `sim/bk11/run.sh` — the Phase-7 BK-0011M SoC **functional** oracle, **three
  legs since Phase 9** (authentic /24, `+turbo`, `+turboflip`): the whole
  contract below must pass unchanged in turbo — only the timing may move, so a
  failure there means the reply-owner switch is wrong, not slow — and
  `+turboflip` bangs on F12 THROUGHOUT the run, which is the only leg that can
  kill a mutation of `turbo_ctl`'s bus-idle qualification (an unqualified swap
  drops a reply mid-cycle → qbto → trap 4 → the vector-4 fail park). Note §12's
  no-retro-fire guard now counts **SYNCO rising edges** since the unmask rather
  than sys_clk: "the next SYNCO edge" is the actual contract and how far away
  it is depends on the raster phase the program reaches the unmask at, so the
  old 512-sys_clk threshold was only ever a proxy for one CPU rate (a turbo leg
  lands a perfectly legal edge at ~502). Teeth-tested: the combinational-gate
  mutation still fails it at 34 sys_clk / 0 edges.
  (data-checking, NOT a timing golden — ref037 keeps the timing-reference
  meaning): the `mem/gen_bk11_test.py` program (pinned parks: success
  **001004**, fail **001012**; vector 4 → fail) boots from the EXT window on
  the real SoC stack at the /24 CPU rate under port-2 contention and walks
  the whole Bk11MemoryManager contract: fill/verify all 8 pages through both
  windows, page-6 aliasing both directions, **RMW in EXT** (the one bus path
  with no bk10 coverage — the CLAUDE.md RMW rule), ROM overlays +
  write-ignore, the 033 quirk, fixed top ROM, **RESET-instruction preserves
  the map**, the write-only map register, the **177662 video register**
  (word writes replied + RESET-preserved — the tb checks the `vid_*` taps
  against the DCLO defaults and the final write — and the read side proven
  un-replied via an in-program vector-4 detour), and the **EVNT/IRQ2 frame
  interrupt** (section 12: the 662 bit-14 mask gates the already-asserted
  vgate level, then one vector-0100 fire per blanking window + a double-fire
  grace check; two tb assertion guards pin every nIRQ2 assert inside the
  vgate window AND never-while-masked — the program alone can't catch a
  broken gate: the vm1 arm/fire detector never sees a deassert then, so the
  first fire just slides to the second frame and all CPU-side checks pass),
  and the **СТОП-enable bit** (section 13: the tb pulses `key_stop` on a
  magic scratch write into the ocbk_top replica — gated 64-clk nIRQ1
  one-shot; enabled СТОП takes the authentic HALT-entry-timeout → trap-4
  path even at PSW prio 7, blocked must not fire in a bounded window,
  word/odd-byte writes reach the latch, even-byte/banking writes don't,
  RESET preserves it; the trap-4 frame is NOT RTI-able — the aborted HALT
  entry pushes a mid-instruction PC — so the handler continues via R0).
- `sim/romwr/run.sh` — the ROM-write-timeout functional oracle, **two legs
  since Phase 9** (authentic /32 and `+turbo`); the turbo leg is the sharpest
  test of the turbo `selected` change, because the program's whole point is
  that RAM and ROM must behave DIFFERENTLY in the same FSM — the conditionless
  clear marches out of RAM (which qbus_mem must now reply to) into ROM (which
  must still get no reply), so a wrong term either hangs the clear or ends it
  early. (BK-0010 SoC
  stack, data-checking, `COSIM PASS` at the pinned success park like `sim/bk11`).
  Proves a write to ROM gets NO reply → qbto → trap 4: the **conditionless
  "write until trap 4" screen-clear** (a counter-free `CLR (R0)+` marching into
  100000 — only the trap ends it; RAM cleared, ROM word unchanged) and an
  **INC @#100000 RMW** whose write half must trap while its read half replies.
  Both are **mutation-tested** (reverting the `selected` change hangs the clear;
  the RMW leg also proved the S_REPLY refinement unnecessary — the DATIO gap
  already drops the read reply). The gen program is `mem/gen_romwr_test.py`.
- `sim/evnt/run.sh` — the Phase-9 **EVNT/IRQ2 detector oracle** and the
  authority on `src/peripheral/bk_evnt.sv` (the authentic D28+D3:B missing-pulse pair off
  the 037's WTI/SYNCO pins). Contract = the `sim/ref014` shape: the vendored
  **reference** netlist `sim/ref037/va_037.v` generates `golden_evnt.txt`, and
  the retimed `src/bus/va_037_sync.sv` must reproduce it line-for-line (it does,
  byte-identically). Three legs in one transcript — **L1** full screen
  (assert = VGATE rise + **452 CLKIN**, deassert = VGATE fall + 452 CLKIN,
  every frame), **L2** 1/4 screen (WTI stops after 64 displayed lines, so the
  request fires **during active video**, ~129 lines early), **L3** mask
  semantics (masking clears at once; **unmasking must NOT retro-fire** — it
  waits for the next SYNCO edge). **Mutation-tested ×5** (`--mutate`: the
  old-qa propagation race, the WTI clear, the D3:B clock edge, irq_en as a
  combinational gate, the QA feedback — all fail). Mutations rewrite a *copy*
  of the real RTL via sed, so there is no inline replica to drift. See
  `sim/evnt/README.md`. **Never regenerate the golden from a va_037_sync run.**
- `sim/smktime/run.sh` — **slow (~1 min), not in `make sim`**: the Phase-9
  **SMK512 memory-access-time oracle**, i.e. the calibration of `N_EXT` and the
  regression that keeps it calibrated. Runs `test/sndtestsmk.bin` **verbatim**
  (the exact bytes measured on a real BK-0011M + SMK512) on the sim/smk SoC
  stack and reports the emitted tone: one half-period = 197 instruction
  fetches, all from the memory the loop is resident in, nothing else touching
  memory, so the frequency is a direct high-gain readout of that memory's
  access time — one unit of N moves it ~6 %. **Two legs, one image, two entry
  points** (byte-identical loop code, so the only variable is which memory runs
  it): the loop copied to 0140000 = **SMK RAM** (`MK_EXT`), and the CONTROL leg
  entered at START so the same loop runs in place in **ordinary RAM**
  (`MK_RAM037`, N_RAM=4 + the 037 steal — already calibrated, so it validates
  the clock rate and the access-count model and isolates any error to `N_EXT`).
  Goldens pin the per-instruction gap table (`LOOP addr n min max`), each
  half-period and the `EXTRD fast/slow` fallback rate; `dbg_romgate` must never
  fire. `--sweep` reproduces the N_EXT = 1..4 ladder from the RTL by
  sed-patching a *copy* of `qbus_pkg.sv` (the `sim/evnt` idiom). Run it
  whenever `N_EXT`, the `qbus_mem` reply FSM or the `cpu_sdram_dp` issue path
  changes. **Mutation-tested ×5** (see the run.sh header).
  **Two Phase-9 TURBO legs** (`+turbo`) make this the speed MEASUREMENT for
  turbo mode as well — there is no real machine to compare against, so they are
  a regression on the speed-up, not a calibration. The ordinary-RAM leg is the
  one that matters (its loop is `MK_RAM037`, so it reads out both halves of the
  feature at once): **4184 → 3527.8 cycles, 481.2 → 856.1 Hz, 1.78x**, and the
  per-instruction `LOOP` spread — which IS the 037 steal beat, a fetch landing
  at different phases of the 8-CLKIN grant slot — collapses from min=20/max=26
  to min=18/max=19, every other instruction in the loop going exactly flat. The
  residual 1 is not arbitration but the done-gate, routine by design at
  `N_TURBO` = 2. A turbo golden showing a spread of ~6 again would mean
  `no_steal` is not reaching the arbiter. **The SMK-RAM turbo leg is what found
  that `N_EXT` = 1 cannot survive /16** — it tripped `dbg_romgate` on its first
  fetch — which is why `turbo_mem` covers MK_EXT too.
- `sim/vregtime/run.sh` — **slow (~1 min), not in `make sim`**: the Phase-9
  **177662 write-time oracle**, same shape as `sim/smktime` on a stock
  BK-0011M stack (smk_en=0, /24, port-2 contention, boot via the top-ROM
  stage-0 stub). `test/sndtest662.bin` (`mem/gen_vreg_test.py`, the same bytes
  a real machine would run) puts **192 writes in each tone half-period** — 8
  unrolled `MOV R1,(R0)` × 24 SOB iterations — with two entry points and a
  byte-identical loop whose only difference is R0: the writes go to **177662**
  or to a **scratch word in RAM** (`MK_RAM037`, the hardware-calibrated
  control). The `LOOP addr n min max` table is the sharp output — eight
  identical instructions, so min/max there *is* the cost of one write.
  **It was built to test the hypothesis that `N_VREG` caused the beam-raced
  palette skew, and it FALSIFIED it**: `--sweep` gives bit-identical cycle
  counts for N = 1..4 (see the `N_VREG` note in the 177662 bullet). What the
  golden pins is therefore the fetch path + 037 steal (the control leg's
  min ≠ max is that beat) plus the `VREGWR fast/slow` line, which is the one
  thing that moves when the reply FSM changes. `--regen` regenerates.
- `sim/grantfit/run.sh` — **slow (~30 min for `--sweep`), not in `make sim`, and
  NOT an oracle — a measurement bench.** The Phase-9 037 **grant-rule** study:
  it runs every tracked tone image (`test/sndtest*.bin`, consumed verbatim via
  `mem/gen_tone_test.py`) on the real SoC stack and tabulates it against the
  real-BK-0011M readings — **four legs that must MOVE and three that must
  NOT**, because both earlier arbiter experiments were judged on one leg and
  wrecked another. `tone_tb.v` is the sim/vregtime stack with sim/smktime's
  SMK option folded in (`+smk`, `+bk10`, `+image/+entry/+loop_lo/+fetch_*`);
  `patch037.py` builds candidates by ANCHORED rewrites of a **copy** of
  `src/bus/va_037_sync.sv` (the sim/evnt idiom — it fails loudly if the RTL moved,
  and every register it adds is reset or RASEL goes X and the sim hangs). The
  D8:B candidate is a tb plusarg, not a patch: it is a BOARD chip the 037
  netlist does not contain. **`real` is normalised at 4.000 MHz** — see the
  warning in its header about the second normalisation in this file. The
  baseline reproduces eight independently-derived numbers; if it ever stops,
  suspect the bench before believing the result. See the beam-race bullet for
  what it found.
- `sim/raminit/run.sh` — the Phase-7 `ram_init` unit oracle (the authentic
  DRAM power-on pattern filler): drives ram_init through a served-mask-honoring
  grant model and checks, per fill pass, the exact per-model word pattern
  (bkemu-QT `InitMemoryValues`: bk10 `idx[0]^idx[6]` with a 64-word phase flip,
  bk11 `idx[3]^idx[6]`; the tb is an independent literal transcription of the C
  loops), the contiguous address
  walk over the model's RAM range (bk10 0x0000–0x3FFF / bk11 0x20000–0x2FFFF),
  the served-mask ≥1-cycle req gap, the trigger (power-on fill, NO re-fill on a
  same-model reset, re-fill on a model change), and `blank_pulse` (silent on the
  first fill, one pulse per re-fill). **Mutation-tested** (wrong pattern bit /
  no gap both break it). The SoC-integration side is covered by
  `sim/run_boot_check.sh` (real MONITOR/BOS cold-booting on the pattern) — the
  replica preloads the pattern rather than running ram_init through the
  boot-writer port (that datapath is `run_epcs_boot`'s).
- `sim/run_epcs_boot.sh` — the EPCS loader unit cosim (flash model →
  `epcs_boot` → arbiter port 0 → SDRAM), **three legs**: the clean run loads
  BOTH blobs (Phase-5 bk10 at flash 0x40000 → SDRAM words 0x4000+, Phase-7
  bk11 at 0x48000 → 0x30000+) and word-exact-verifies both regions;
  `+corrupt` (first blob) and `+corrupt2` (second) each must end
  `boot_ok=0` — `+corrupt2` also re-checks the bk10 region is intact
  (two-pass independence).
- `sim/run_sdram_cosim.sh` — the Phase-2 `qbus_sdram` slave (word/byte datapath +
  deterministic RPLY). Runs the `--core-only` ROM (no picture draw — hours slow).
- `sim/run_video.sh` — palette unit tb (slot/bit conventions + all 16
  BK-0011M palettes against an independently hand-transcribed expected
  table — a swizzle bug in the RTL cannot cancel out); `fb_video_tb` (FB
  words vs a tap-driven expected model, mid-frame scroll, M256, and the
  Phase-7 frame D: fetch from the page-7 `vram_base` with palette 11);
  `vga_out_tb` (timing geometry + pixel-exact readout, physical-colour
  decode); `video_pipe_tb` (full chain, every active pixel at the DAC vs a
  Python-rendered frame of the **shipped** picture).
- `sim/video/run_draw_check.sh` — **slow (~10 min), not in `make sim`**: proves
  the ROM's hand-assembled PDP-11 draw code writes exactly `render_image()`.
  Run it whenever `mem/gen_mem.py`'s program or picture changes.
- `sim/run_boot_check.sh` — **slow (~7 min), not in `make sim`**: cold-boots the
  real MONITOR ROM on the full SoC; checks no bus-contention X and that the
  screen clear starts; dumps `sim/boot_trace.txt` (bus R/W trace) for manual
  diffing against a BkEmu-side trace when debugging boot problems. With
  `+warmreset` (~14 min) it also re-pulses DCLO/ACLO mid-screen-clear and
  requires a second 177716 start-vector read + a second screen-clear burst —
  run it when touching reset/DCLO plumbing. **`+bk11`** (Phase 7) instead
  cold-boots the real BK-0011M BOS (model_bk11=1, /24 CPU clock, the bk11
  blob preloaded at SDRAM 0x30000+, the 177662→fb-base/palette + EVNT/IRQ2
  ocbk_top mux replica): the first 177716 read must reply the 140000 start
  vector, then BOS activity = a 177662 write + the screen-clear burst, no X
  (`+warmreset` is bk10-only). `VID_TARGET`/the 60 ms bound are noted
  tunables if BOS's real startup profile needs them. **`+smk`** (Phase 8)
  cold-boots the real SMK512 BIOS: the +bk11 stack with smk_en=1 and the
  43008-word blob (BIOS at SDRAM 0x3A000) — since the IDE increment plus
  the **live `smk_ide`** fronted by the behavioral disk model loaded with
  `gen_ide_image.py`'s AltPro image; requires the merged 166400 start
  vector (the SYS rom7 register-space overlay | SEL1; the raw word also
  carries the idle-kbd 0o100 bit — the PC masks with 177400), ≥200 DIN
  fetches from the rom6 window (the BIOS EXECUTING from ROM), and the
  BIOS's own **banner** (its 177662 write + the video-RAM burst — after
  its ~150 ms SOB startup delay, hence the 400 ms +smk time bound), no X
  with the sel_ide decode active. The BIOS's DRIVE probe is deliberately
  NOT required: smk64.mac (doc/) routes every boot path through INIT →
  EMT 0 = the full BOS re-init incl. the multi-second БК memory test
  before ZAGHDD/BOOT0 touch the task file — out of sim reach (the tb's
  `+fastdelay`/`+idetrace` debug aids exist for exploring that flow); the
  drive contract is `sim/ide`'s, and the real BIOS reading a real image
  was the increment-(b) hardware milestone — **achieved 2026-07-18**.
  **`+smk +sdspi`** swaps the disk model for the real
  `sd_backend`+`sd_model` SPI stack (a runtime mux in the tb): attach +
  the AltPro geometry parse ride the full card-init + SPI path under
  the real BIOS boot, same pass conditions. **`+turbo`** (Phase 9) composes
  with every other leg and runs it at /16 = 6.04 MHz with the 037 out of the
  RAM path: this is the only oracle that executes REAL MONITOR/BOS/BIOS code,
  so it is the one that answers "does a real ROM still boot when qbus_mem owns
  the RAM reply", which no synthetic program can. **`+smk10`** (bk10+SMK) boots
  the SAME real BIOS on a BK-0010 stack: model_bk11=0, the /32 rate, the
  bk10 ROM blob plus the bk11 blob for the BIOS image at 0x3A000 (both
  are flash-resident on hardware whatever DIP 1 says); pass conditions as
  `+smk` MINUS the 177662 write — on a BK-0010 that write must NOT reply,
  it is the BIOS's own model detect — and a 550 ms bound (the startup SOB
  delay at the slower clock). `+smk10 +sdspi` works too.

Any change touching the core, the Q-bus, memory, video, or clocking must keep all
of it passing. When tuning bus/RPLY timing, trace the **reference** waveform first
(instrument `cpu11/vm1/.../sim/bk10/bk10_tb.v`) — that is ground truth. Note the
golden checks *timing*, not write data — only the SDRAM/video cosims verify values.

## Architecture & conventions

- The `vm1` (1801ВМ1) core is **vendored** under `src/cpu/` from
  `~/projects/other/fpga/cpu11/vm1/hdl/syn`. Don't edit it casually; re-sync from
  upstream if needed, but **keep the marked local hook in `vm1.v`**: `pin_sel_n`
  is push-pull there (upstream is open-collector) because `qbus_mem` consumes
  nSEL1/nSEL2 for the 177716/177714 decode and a lone Z-idle OC driver is the
  Cyclone-I stuck-asserted trap (see the virq_n gotcha). Core config is via
  global Verilog macros (see below).
  **`vm1_tve.v` (the 177712 ВЕ timer) is deliberately left upstream-stock —
  a TRIED AND REJECTED hook, do not re-apply it.** Its /128 prescaler
  (`tve_pre`/`tve_div`) is **free-running**: a CSR write reloads `tve_count`
  but not the phase, so the first tick lands 0–127 cpu_clk later depending on
  a phase dating back to power-on. BkEmu does the opposite (`Timer.java`:
  `(cpuTime - settingsChangeTime)/128`, with `updateSettingsChangeTime()` on a
  control write ⇒ phase re-zeroed to the write instant), and since beam-raced
  palette effects restart this timer from each 50 Hz EVNT and count down to a
  scanline, re-zeroing looked like the fix — a PALTST15-style sim harness
  measured it moving the palette-switch train ~3400 sys_clk, out of deep
  active video onto the H-blank edge. **On hardware it made only a MINOR
  difference to the actual artefacts, so it was stashed.** The sim
  prediction did not transfer (that harness had SDRAM contention stripped).
  A comment in the file records this so it does not get re-applied a third
  time.
- The Q-bus is **inverted / active-low / open-collector**, carried as shared
  tri-state nets at the `cpu_test` level (no SystemVerilog `interface` — neither
  Quartus 11.0 nor Icarus handle tri-state interface members reliably). Every
  participant (core, `qbus_sdram`, `qbus_slot`) drives `x ? 1'b0 : 1'bZ` /
  `ad_n = ena ? ~out : 1'bZ`.
- Clocking: **one PLL only** (board constraint — the PIN_28 crystal feeds a single
  PLL). New clocks must be a ÷N of the ×9 VCO or a fabric clock-enable; the SDRAM
  chip clock (`pMemClk`) is the PLL's `extclk0` at the same 96.65 MHz as the
  internal `clk0`/`sys_clk` (phase-matched, like esemsx3's c1/e0). The PLL and
  resets live in `src/ocbk_top.sv`; the fabric divider chain (dot/037-CLKIN
  enables + the CPU clock) is `src/sys/cpu_clkgen.sv` (Phase 7): a toggle divider
  giving **/32 = 3.02 MHz (BK-0010) or /24 = 4.03 MHz (BK-0011M)**, selected by
  `model_bk11` = **DIP 1** (ON = 0011M), latched in `ocbk_top` while DCLO is
  held — power-on AND warm reset, so the reset button switches the model — and
  frozen while the CPU runs. `sim/run_clkgen.sh` pins /32 mode bit-identical
  to the pre-Phase-7 `divc[4]` tap (the SoC tbs replicate the divider locally,
  so that oracle is the divider's only sim coverage). In /32 mode CPU edges
  coincide with the 037 `en_pos`/`en_neg` strobes (CPU=CLKIN/2, the reference
  phase); in /24 they walk a deterministic 48-sys_clk pattern.
  **A third rate, `turbo` = /16 = 6.0405 MHz, is Phase 9's TURBO mode** (PS/2
  F12; see the turbo bullet). It OVERRIDES the model select and, unlike
  `model_bk11`, is a LIVE control — it retargets under a running CPU, which the
  `>=` wrap makes glitch-free (a mid-count change only stretches or shrinks the
  current half-period, now to 8..16 sys_clk). The fixed `divc` chain is NOT
  model- or turbo-dependent and must stay that way: 037 CLKIN is always
  sys_clk/16, which is why video and the 50 Hz EVNT do not move in turbo.
  **The /24 rate is 4.0270 MHz against a real BK-0011M's 4.000 — +0.67 %**, an
  unavoidable consequence of the one-PLL rule and the board's 21.47727 MHz
  crystal. The Phase-9 tone calibration measured this directly (two independent
  legs implying 3.998 and 3.994 MHz; see the `N_EXT` bullet), and it is now the
  design's **only** known sub-1 % timing error against real hardware — a
  frequency offset, not a cycle-count one, so no oracle can see it and nothing
  in the RTL can fix it short of a different crystal.
  **The real board's clock tree, traced pin-by-pin in `doc/bk0011m.sch`
  (2026-07-26) — settles the CPU:CLKIN ratio question for good:** BQ1 is a
  **12 MHz** quartz (D5 К555ЛН1 inverter oscillator → net S1-42). **CLC**
  (the CPU clock, D14.1) comes from **D39** (К555ТМ2 wired as a 3-state
  counter: D1 ← ~Q2, D2 ← Q1, FF2 async-**cleared** by Q1, clocked off the
  *inverted* 12 MHz) = **12/3 = 4.000 MHz exactly** — and note its **1/3 duty
  cycle**, high for one 12 MHz period in three, where ours is a symmetric
  toggle (tested in sim: cycle counts identical, so this is cosmetic).
  **The 037's CLKIN** is **D8:A pin 5 → net S1-29 → D19.33** = **12/2 =
  6.000 MHz**; the same flop's `~Q` (S1-33) is the К155ИР13 pixel shift clock.
  So **the real CLKIN:CPU ratio is 1.5 — exactly ours**, and with the 037's
  384 CLKIN/line × 320 lines/frame that makes a real line **64.00 µs =
  15.625 kHz** (the TV line rate, exactly), a frame **48.83 Hz** (not 50), and
  **one scanline = 256.0 CPU cycles on both machines**. Our whole design is
  therefore uniformly +0.674 % fast with the ratio preserved: no relative
  drift, so **the clock tree cannot skew beam-raced code** — a whole class of
  hypotheses is ruled out here rather than re-argued each time.
- **Soft reset (Phase 5.5):** the board's reset button (`pSltRst_n`, PIN_153 =
  the slot RESET net, external pull-up) re-enters the `ocbk_top` reset
  sequencer via `warm_rst_req` (pressed = hold, release + ~22 ms tail = the
  8/12 DCLO→ACLO release). CPU-side DCLO-keyed state re-inits; `srst_n`, SDRAM
  init, `epcs_boot` and memory contents are untouched — BK hardware-reset
  semantics (memory survives). **The video side (037 `PIN_R` + `fb_video`) is
  power-on-reset ONLY (`vid_rst_n`)** — a real BK's display ignores CPU
  DCLO/ACLO, so the picture stays up across a warm reset; never re-key those
  resets to `dclo_n`. **Reset wiring rule (real BK): DCLO/ACLO go to the CPU
  ONLY; all BK peripherals are reset by the CPU's nINIT Q-bus line** (`vm1`
  drives `pin_init_n` open-collector: asserted during its own reset AND pulsed
  by the RESET instruction). Every Phase-6+ peripheral must key its reset to
  `init_n`, not `dclo_n` — the RESET instruction must reset it too (done for
  the 177716 write-flag and the `bk_kbd014` registers). **Exception: the
  translator-side ЗАГЛ/СТР caps trigger and РУС/ЛАТ shadow are clocked off
  ACLO** (BK schematic: a 74LS74 with D=GND, C=ACLO), so `kbd_ps2bk` resets
  them to the power-on default (ЗАГЛ / ЛАТ) on **`aclo_n`** — power-on AND the
  reset button, both of which pulse ACLO, matching the MONITOR's own re-init
  (this keeps them in sync across a warm reset — no post-reset case desync).
  They are NOT reset by the RESET instruction (that pulses nINIT only, never
  ACLO), so `aclo_n` is exactly right: in `ocbk_top` it is driven only by
  power-on and `warm_rst_req`. In the warm-reset oracle tbs the release is aligned to
  the next vblank start (the free-running 037 makes post-reset timing raster-
  phase-dependent — authentic; the vblank alignment is what keeps the replayed
  golden window steal-free and diffable). A keyboard reset chord would OR into
  `warm_rst_req` — the seam is there (`src/ocbk_top.sv`) but no chord is wired
  yet (see Open / deferred). "DIP n" = physical switch n = `pDip[n-1]`; **DIP 1 =
  model select** (OFF = BK-0010, ON = BK-0011M; Phase 7 — latched during any
  DCLO hold, see the clocking bullet; it used to be screen_mode, which moved
  onto the PS/2 **Print Screen** key: each press toggles colour-256 ↔
  mono-512; the `kbd_ps2bk` `key_scrmode` radial output → the `smode_sr` 2-FF
  sync; power-on-only, so it survives a warm reset like the real
  monitor-cable switch and the video pipeline). **DIP 8 = SMK512 enable**
  (Phase 8; ON = present, **BOTH models** — the SMK is an МПИ expansion
  board, so every SMK term is gated on `smk_en` alone), latched in the SAME
  DCLO-hold block as DIP 1, so model and SMK config switch together on a
  warm reset. **DIP-8-ON boots the SMK BIOS in either model** (the SYS rom7
  register-space overlay redirects the 177716 start vector to 166400 — see
  the SMK512 bullet; the SYS reset layout deselects BOS / covers the BASIC
  region, so it is the BIOS or nothing) and the BIOS **auto-detects the
  model itself** by writing 177662 with vector 4 planted: replied on a
  bk11, bus-timeout → trap 4 → `MODE_STD10` on a bk10. DIP 8 OFF + reset
  returns a stock machine of whichever model DIP 1 selects. **DIP 4 = CMT
  tape-in mode (CONFIRMED ON HARDWARE 2026-07-25)** (ON = the right sound jack `pDac_SR` is the cassette port;
  `~pDip[3]` read LIVE — a 2-FF sys_clk sync, NOT DCLO-latched, since CMT
  never touches the CPU — so flipping it needs no reset; `pLed[6]` = mode
  tap; was the PS/2 Scroll Lock key through Phase 8, see the tape bullet).
  **DIP 5 = the audio self-test tone** (Phase 10; `~pDip[4]`, read LIVE
  through the same 2-FF sys_clk sync as DIP 4 and for the same reason — it
  never touches the CPU, so it needs no reset). A DIAGNOSTIC, not a user
  feature: it plays a 440 Hz reference on BOTH channels plus a 1567 Hz
  RIGHT-ONLY tone whose level steps down 6 dB every ~0.7 s through eight
  steps, the last three of which are BELOW one ladder step — the by-ear
  demonstration that the noise-shaped DAC resolves finer than its six
  physical bits, and (via the two different pans) that stereo works. It
  **mutes the BK speaker while it runs**; see the gain-budget note in the
  audio bullet. `pLed[3]` = mode tap.
  **DIP 2 is unused** — it
  forced the on-chip test ROM, removed 2026-07-10 (ROM is always the loaded
  SDRAM image). **TURBO is NOT a DIP** — it is the PS/2 **F12** key, with
  `pLed[5]` as its indicator (see the turbo bullet). Like screen_mode it is a
  live, power-on-only radial toggle rather than a DCLO-latched config bit, so
  it survives the reset button and needs no reset to take effect. Current LED
  map: `pLed[7]` = SMK drive access, `[6]` = CMT mode, `[5]` = turbo,
  `[3]` = audio self-test tone live (DIP 5), `[2]` = a DAC quantizer clipped
  (STICKY), `[1]` = the audio mixer saturated (STICKY), `[0]` = speaker
  activity, `[4]` unused. The two sticky audio flags are bring-up
  observability — the same reasoning that put `spk_active` on `pLed[0]` in
  Phase 6: they turn "it sounds wrong" into "the digital side says the level
  overflowed", otherwise indistinguishable from an analog fault. Neither should
  ever light in normal use; the gain budget, not the saturator, is the mixing
  strategy.
- **Authentic DRAM power-on pattern (`src/sdram/ram_init.sv`):** the board SDRAM has
  no defined power-on state, so before this the BK startup screen showed FPGA
  garbage / stale content (worst on a model-switch warm reset, where DIP 1
  reinterprets the previous model's screen). `ram_init` fills the selected
  model's RAM region with the К565РУ6 (bk10) / К565РУ5 (bk11) power-on pattern
  that the **bkemu-QT** emulator reproduces (`CMotherBoard[_11M]::InitMemoryValues`
  in `devemu/Board.cpp` / `Board_11M.cpp`). Each word is all-ones/all-zeros per
  a per-model rule, expressed on the physical word address (bases are 0x2000-word
  aligned and both rules use only bits < 13, so the emulator's linear word index
  reduces to `w_addr`): **bk10** `word = w_addr[0] ^ w_addr[6] ^ (w_addr[5:0]==0 &
  w_addr!=0)` (alternating 0/FFFF whose phase flips at each 64-word boundary — the
  C loop's `uint8_t flag==192` extra inversion; index 0 is 0); **bk11** `word =
  w_addr[3] ^ w_addr[6]` (8-word blocks with a 16-word double-block every 64
  words). Both closed forms were verified bit-for-bit against transcriptions of
  the C loops over the full fill ranges; the `sim/raminit` tb re-derives them via
  an **independent literal transcription** of the loops. It
  **fills at power-on and re-fills on a warm reset ONLY when the model changed**
  (model_bk11 only changes during a DCLO hold, so a re-fill always lands with
  the CPU parked); a **same-model warm reset preserves RAM** (BK reset
  semantics — never re-fill it). It shares arbiter port 0 with `epcs_boot`
  through a top-level 2:1 mux (`mem_bw_*` / OR-ed `boot_active`) — they never
  overlap (the fill starts after `boot_done`), so **`qbus_mem` is unchanged**
  and no module-level oracle sees it. `fill_busy` (2-FF into cpu_clk as
  `fb_sync`) is ORed into the reset sequencer hold so the CPU never starts on
  half-filled RAM. On a re-fill (`blank_pulse`, gated on the fill being a
  re-fill i.e. `ram_valid` already 1) it clears `fb_video`'s `fb_front_valid`,
  reusing the existing power-on black-out so the display goes black → reveals
  the fresh pattern → firmware clears it (the first power-on fill needs no pulse
  — video is still in reset then). Oracle: `sim/raminit/run.sh` +
  `sim/run_boot_check.sh` (real MONITOR/BOS cold-boot on the pattern; the
  replica preloads it). **DCLO/model-change-only** — like the map/662/spk
  registers, it is deliberately NOT reset by nINIT (a RESET instruction must
  not re-pattern RAM under the running program).
- **Keyboard (Phase 6):** `ps2_rx` → `kbd_ps2bk` (translator, all on
  `cpu_clk`) → `bk_kbd014` (the 1801ВП1-014 bus equivalent at 177660–177663,
  decode = the 037's `PIN_nBS`, netlist-contract-validated — see
  `sim/ref014/README.md` for the full pinned contract). Key facts:
  - **the 014 readme's "nEC1 = РУС/ЛАТ" label is imprecise for the BK**: the
    schematic wires nEC1 to the trigger flipped by the ЗАГЛ/СТР keys (caps),
    while РУС/ЛАТ are ordinary matrix keys emitting 016/017 — mapped here as
    CapsLock = the ЗАГЛ/СТР trigger, LCtrl = РУС, Home = ЛАТ, Insert = СУ
    (held), either Shift = НР, either Alt = АР2, **Delete = СТОП**,
    **Print Screen = screen_mode toggle** and **F12 = turbo toggle** (both
    radial control outputs like СТОП, never a matrix code, power-on-only —
    see the screen_mode note and the turbo bullet; F12 is scancode 0x07,
    single byte, and its branch is `!got_e0`-guarded because the F-key rows
    in the code table are written E0-agnostic;
    Scroll Lock is now unused — CMT tape mode moved to **DIP 4**, see the
    tape note);
  - case algebra per BkEmu (`latin ^ (caps | shift)` on letters, СУ = `&037`
    on 01xx codes); the **silicon auto-274 code group**
    {0,1,2,4,5,6,7,011,013,021} vectors to 0274 without АР2 (measured over
    the netlist matrix scan — MiSTer's arrow flags were wrong);
  - **СТОП is trap-to-4 on a BK-0010 with BASIC** (per the schematic/user):
    nothing decodes 177674/177676, the HALT entry's PC/PSW stores bus-timeout
    (`qbto`, 56..63 clocks) and the CPU traps through RAM vector 4 — the
    160002 word is never used as a vector. `qbus_mem`'s I/O decode is the
    CPU's own nSEL1/nSEL2 pins (177716/177714 only — the registers whose read
    data `ad_oe` delegates externally; everything else in the I/O page,
    177674/76 included, is undecoded and bus-times-out, exactly as a real BK);
    never "helpfully" reply there. СТОП itself is a fixed 64-cpu_clk one-shot
    on nIRQ1. **Phase 7 (BK-0011M): 177716 write bit 12 = СТОП-block**
    (1 = blocked, write-only, `stop_block` in `qbus_mem` gating the one-shot
    launch in `ocbk_top`) — MiSTer's lane rule, matching the real board's
    WR1/WR2 byte-strobe registers: only a write that strobes the HIGH byte
    (word, or the 177717 odd byte) with the bit-11 lane clear touches it;
    low-byte writes never do (BkEmu's implicit re-enable there is a rejected
    emulator artifact). bk11-only (bk10 has no latch), **DCLO-only reset**
    (the map/662 exception: RESET must not re-enable СТОП). Pinned by
    `spk_capture_tb` + `sim/bk11` section 13; that oracle also documents
    that the aborted HALT entry pushes a mid-instruction PC — the trap-4
    frame is NOT RTI-able (real СТОП handlers never return);
  - `N_KBD`/`N_IAK` = 1 (the async chip replies within the strobe cycle) and
    the 177660 **write** reply is combinational (`wr_fast`) — both pinned by
    `golden_kbd.txt`; vm1 slaves must hold read data past DIN release (the
    IAK vector capture relies on it — bus-charge physics on the real board).
- **Tape (Phase 6):** the esemsx3 **CMT-jack scheme** — `pDac_SR` (right sound
  channel, now `inout`) doubles as the cassette port while CMT mode is on:
  **DIP 4 selects it** (`~pDip[3]`, ON = CMT; read LIVE through a 2-FF
  sys_clk sync in `ocbk_top` — `cmt_sr` — so flipping the switch changes the
  mode with no reset, since CMT never touches the CPU; `pLed[6]` = mode tap.
  Through Phase 8 this was the **PS/2 Scroll Lock** key → a `key_cmt` radial
  toggle, the esemsx3 convention). **Do NOT
  gate CMT on the 177716 motor bit** — that was tried first (authentic:
  MONITOR d6.mac `KPUSK=020`/`KSTOP=220`, bit 7 = 1 = stopped, held 1 outside
  tape ops) but **real BK software writes bit 7 = 0 outside tape operations
  and wrongly killed the right audio channel** (hardware finding 2026-07-10).
  `mot_bit` is still captured next to `spk_bit` in `qbus_mem` (same
  DOUT-window sys_clk capture, same software-owned NOT-nINIT-reset contract,
  oracle-pinned) but left unconnected in the top. In CMT mode `audio_out`
  drives `pDac_SR` as `[5]`=input(Z) `[4]`=Z `[3:2]`={lvl,~lvl} (Schmitt
  feedback through the ladder resistors) `[1]`=0 `[0]`=spk level (BK tape-out
  IS bit 6); the sampled level feeds **177716 read bit 5** (`tape_in`,
  2-FF onto `cpu_clk_n`). **Phase 10 changed what the OTHER ladder does in this
  mode**: audio is now true stereo, so with CMT on the **left** ladder carries
  the L+R **mono fold** (an average, not a sum, so a BOTH-panned source is
  equally loud either way and hard-panned content folds 6 dB down; the average
  also stays inside the shaper's clip-free window with no extra saturator).
  The BK speaker is panned BOTH, so `mix_l == mix_r` for it and the CMT-mode
  left ladder still sits at its rail code — **turning CMT on cannot change how
  the speaker sounds**. Two Phase-10 rules for this jack, both in
  `src/audio/audio_out.sv` and both mutation-pinned: **tape-out
  (`dac_r_o[0]`) stays the RAW speaker bit** — never a mixed sample and never a
  shaped code, because bit 0 is the ladder's LSB tap and a shaped code rattles
  it at up to 3 MHz (which would destroy the duration-coded waveform MONITOR
  writes) and because it would otherwise mix an AY into a tape recording; and
  **the anti-echo force on `tape_lvl` is now MORE load-bearing** than it was,
  since with CMT off `pDac_SR[5]` carries that same rattling code bit where it
  used to carry a quasi-static mono level. The MONITOR read loop is duration-based and
  self-calibrating, so a WAV played into the jack is a valid tape source.
  These pad OEs are the ONE intentional tri-state besides the bus nets — the
  map-report guard grep must not flag them (they drive pins, not internal
  logic). The **original MONITOR asm sources** live at
  `~/projects/other/bk/vak-opensource/bk/bk-0010-sources/` (d6.mac = tape) —
  ground truth for MONITOR behaviour alongside BkEmu. Tape-out fidelity note:
  a real BK mixes write bits 6+5 into a 3-level record waveform; bit 6 alone
  is shipped (dominant component).
- **Audio subsystem (Phase 10) — `src/audio/`: mixer + noise-shaped 6-bit
  output, true stereo. INFRA ONLY, no new sound device.** Naming: `audio_*` is
  generic infrastructure, `bk_*` is BK-specific; the 177714 devices will live in
  `src/peripheral/`.
  * **The mixer** (`audio_mixer.sv`): N slots of signed 16-bit, **full scale
    ±32767 = exactly BkEmu's short domain** (`AudioOutput.MAX_OUTPUT`) so the AY
    volume table, the Covox byte map and the Menestrel counter levels transcribe
    1:1. **Gain (`g/8`) and pan are COMPILE-TIME parameters; the enable is
    RUNTIME** — there is no volume UI and never will be, so gains fold to
    shifted adds on a device with no multipliers, while the enable must be live
    because Covox/Menestrel get key-cycled. **Runtime stereo is not a runtime
    pan**: a device presents ONE SLOT PER CHANNEL with a static pan and decides
    itself what to put in each (that seam decision is what keeps the mixer
    trivial). Saturates at **31744, not 32767** — putting the bound here is what
    makes the shaper's clip-free proof hold; wrapping is unacceptable (it is a
    full-scale sign inversion, the loudest artifact this path can emit). Pan
    masks are compile-time constants, so hard-panned slots fold out of the
    opposite adder tree — **measured**, 392 vs 527 LE at NSRC=10.
  * **The output stage** (`audio_ns6.sv`): **first-order error feedback**, one
    17-bit adder and one 10-bit residue register per channel, at **sys_clk/16 =
    6.04 MHz** (OSR ≈ 151 against a 20 kHz band ⇒ ~60 dB below the raw 6-bit
    floor — we are ladder-limited long before the shaper is). The DC gain is
    exactly 1 by construction, which is what `sim/audio` proves as an identity.
    **Three fixed points make the whole thing safe**: `s=0`, `+31744` and
    `−31744` each sit STATIC (codes 32, 63, 1), so **silence produces zero pin
    activity** and **the BK speaker — which maps to the rails — emits a static
    63/1 with no shaping activity at all**. The speaker path therefore cannot be
    regressed by any of this; the only change is 63/**0** → 63/**1**, 0.14 dB,
    the price of the clip-free window. First order and no dither are both
    deliberate (see Open / deferred for the computed idle-tone bound).
  * **Why not full-rate 96.65 MHz**: six pads driving a discrete ladder cannot
    settle in 10.3 ns (unsettled transitions are code-dependent glitch energy =
    distortion), and a 17-bit carry chain on the every-cycle path against
    +0.3 ns of sys_clk slack invites the STA chase. `RATE_DIV` = 8 or 32 are the
    documented fallbacks if the board dislikes 3 MHz shaped noise or cannot
    settle in 165 ns. The prescaler is PRIVATE to `audio_out`, not a port:
    taking the tick from `cpu_clkgen` would force every audio tb to replicate a
    divider — the replica-drift trap this file records for `cpu_clkgen`.
  * **Why the full ladder rather than esemsx3's 2-tap 1-bit sigma-delta — and a
    correction to what this file and the RTL used to say.** esemsx3 drives a
    1-bit bitstream (`src/sound/dac/esepwm.vhd`, ~21 MHz) onto taps 5 and 0
    only, and **on its own firmware that works and sounds fine; it is not a
    broken scheme and NOT silent on this board.** What was silent was *ocbk's*
    earlier attempt at that pin pattern, because it fed those two taps an
    audio-rate 1-bit LEVEL instead of a modulated bitstream — two taps have
    nothing to average. A bug in the reproduction, not a property of the
    hardware. We use the whole ladder for a POSITIVE reason: the OneChipBook
    schematic provides a real 6-bit WEIGHTED R-2R network, so a 6-bit quantizer
    starts ~30 dB ahead of a 1-bit one at equal oversampling and needs 16× less
    of it.
  * **The gain budget is the mixing strategy, and it is not yet solved for
    devices.** The speaker is a full-scale source: by itself it uses the entire
    headroom, so anything sounding alongside it saturates. Phase 10 sidesteps
    this by having the self-test tone MUTE the speaker (a diagnostic owns the
    output, which also keeps the acceptance FFT free of a BK square wave). The
    first device increment must actually solve it — MiSTer's answer is to drop
    the speaker to 1/4 when its PSG is live.
  * **The 177714 (nSEL2) capture seam** in `qbus_mem`, next to the `spk_bit`
    block: `port_wr` / `port_data[15:0]` / `port_word` / `port_be[1:0]`. All
    three planned devices decode this ONE address and differ only in how they
    read the data, so the bus side is shared. **WTBT is sampled LIVE at the
    write point** (dual-purpose: "write" at SYNC, "BYTE op" at DOUT) — a
    SYNC-latched build calls every access a byte write and **no cycle-count
    golden anywhere can see the difference**, only `spk_capture_tb`'s two WTBT
    profiles. **Exactly one strobe per bus write** (`port_seen`), because unlike
    the idempotent spk latch these devices are edge-sensitive. Polarity is
    BK-true (`~ad_n`) so BkEmu's models, which each do their own `v = ~value`,
    transcribe 1:1. **Never runtime-reset** — the spk/mot class, not a new nINIT
    exception (a real Covox is a passive DAC on the port latch with no reset
    pin). It is a PURE OBSERVER with no path into `selected`/`wcnt`/the
    reply/`io_word`/`ad_oe`/`mem_ready`, which is what makes it timing-inert;
    177714 already replies via `sel_io`. Read merge deferred (see Open). It is
    surfaced in `ocbk_top` as `snd_port_*` wires that **nothing consumes yet**,
    so the fitter removes the entire capture and it costs **0 LE** in this
    build — it is oracle-pinned regardless, because `spk_capture_tb` drives the
    real `qbus_mem` directly. Wiring it to named top-level wires rather than
    omitting the ports is deliberate: it puts the seam where a device
    implementer looks, and keeps the map report free of four
    "dangling port" warnings.
  * **Cost and timing (confirmed):** **6,979 → 7,357 LE (58 % → 61 %)**, +378,
    all of it mixer + shapers + tone; M4K unchanged at 3/52, pins unchanged at
    98/173, no new PLL. **No STA chase was needed for the audio work itself** —
    unusual for this design at 61 % LE, and down to every stage being one carry
    chain deep and every pad being driven from a flop. `TONE_ENABLE = 0` on
    `bk_audio` reclaims ~130 LE if a later increment needs them.
    ⚠️ **But the shipped bitstream's sys_clk margin is THIN: +0.034 ns**
    (TNS 0, zero negative paths; boot-confirmed on hardware 2026-07-31, so it
    is real margin, not a near-miss). The intermediate build measured +0.260,
    and the *only* RTL delta between them was the one-constant `STEP_B` fix in
    `audio_tone` (+1 LE) — i.e. **this is the placement fragility this file
    documents elsewhere, not an audio-path cost**, the same shape as the +19 LE
    that once took an untouched module +0.481 → −0.414. The worst path is
    `mem_mapper|rom7_en → cpu_sdram_dp|wdata_o[11]`, with `model_bk11` and
    `mon_en` right behind it into the same `wdata_o`/`addr_o` endpoints: the
    mapper-translate-into-datapath cone, already this design's chronic one.
    **Budget for an STA chase on the next increment, and do not chase margin by
    changing SEED 3** (see `ocbk.qsf`'s header and the SDC-exception rule).
- Cartridge-slot Q-bus is a **forward seam**: `src/bus/qbus_slot.sv`, default
  `SLOT_ENABLE=0` (drives nothing, slot pins stay reserved-tristated). The full
  slot pin map lives commented in `ocbk_common.qsf`. Real BK hardware needs an
  external 5V↔3.3V level-shifter (Cyclone I is not 5V-tolerant).
- On-chip RAM is tight (~239 Kbit). BK RAM (000000–077777) lives in the board
  **SDRAM** via the 037-fronted arbiter path (`qbus_mem`; the Phase-2
  `qbus_sdram` is retired from the build but kept for its cosim). The vendored
  `src/sdram/sdram_ctrl.sv` (from `ocb-test`) gained a 2-bit `cmd_be` byte mask for
  the BK's byte writes — re-sync from upstream but keep that hook.
  `src/video/vga_timing.sv` is likewise vendored verbatim from `ocb-test`.
- **ROM-in-SDRAM (Phase 5):** the full BK-0010.01 ROM (`mem/roms/`, committed;
  canonical source = the BkEmu project, also the reference for BK register
  semantics) is 262 Kbit > the device's 239 Kbit, so ROM reads ride the CPU
  datapath (arbiter port 0, linear `addr[15:1]` map → SDRAM words 0x4000–0x7F7F),
  keeping the fixed `N_ROM=2` reply, **done-gated** on
  `mem_ready` (ROM is NOT 037-arbitrated — mask ROM is never cycle-stolen; the
  flat ROM self-loop in `golden_037_rom.txt` pins that). **ROM writes get NO
  reply → the CPU's qbto timer → trap 4** (authentic mask/overlay ROM: real BK
  ROMs never RPLY on a write, and the "write until trap 4" fast-screen-clear
  idiom relies on it; BkEmu agrees — `ReadOnlyMemory.write` → not-written →
  BUS_ERROR → vector 4). In `qbus_mem` this is just `selected = (sel_rom &
  is_read) | sel_io` — a ROM write is not selected, so the ROM/IO wait FSM never
  replies. A DATIO(B) RMW to ROM times out on its write half too, with NO special
  handling: the vm1 gates `dout_start` on the read reply's ack having cleared
  (`~rply_ack[2]`), so a DATIO always has a both-strobes-idle gap where the
  S_REPLY exit drops the read reply before the write half re-enters as a fresh
  (un-selected) access. Applies to the fixed top ROM AND BK-0011M window-1 ROM
  overlays alike. Oracle: `sim/romwr/run.sh` (both DATO and RMW legs, mutation-
  tested); `sim/bk11` §6 asserts the overlay-write trap. Boot:
  `src/sdram/epcs_boot.sv` copies the blob from EPCS offset 0x40000 through the
  boot-writer mux onto port 0 during reset-hold (DCLO held until `boot_done`).
  **Phase 7: two-pass loader.** After the bk10 blob (pass 0, → words 0x4000+),
  the same FSM re-runs for the **bk11 ROM set** — flash 0x48000 → SDRAM words
  0x30000–0x39FFF (the mapper's window-ROM banks + fixed top ROM; a per-pass
  flash/base/cap mux + an inter-pass nCS-high `B_GAP`, ~77 ms total). BOTH
  blobs load **unconditionally** regardless of DIP-1: `epcs_boot` runs once
  per power-on but the model latch re-samples at every warm reset, so both
  images must always be resident. `boot_ok` = every pass header-valid +
  checksum-good; a failure holds the CPU in reset (no fallback). SYS_START
  is **model-muxed**: 177716 reads reply 0o100000 in bk10, `SYS_START11 =
  0o140000` (BOS) in bk11 (`qbus_pkg`/`qbus_mem`; BkEmu `Computer.java:267`
  — bit 15 still agrees with the 037 AD15 assist, bit 14 is qbus_mem-only).
  ROM is **always** the loaded SDRAM image — the on-chip 256-word test-ROM
  fallback and its **DIP2** force were removed (2026-07-10) to free resources.
  A failed EPCS boot (`boot_ok=0`) now **holds the CPU in reset** (the reset
  sequencer gates on `bo_sync`); it does not fall back. The ref037 SoC oracles'
  default-mode bootstrap JMP therefore lives in the SDRAM ROM region (word
  0x4000 → RAM program) instead of an on-chip stub — timing-identical (same
  fixed `N_ROM`), `golden_037.txt` unchanged.
- **Memory mapper (Phase 7):** `src/bus/mem_mapper.sv` is the one translation seam
  in `qbus_mem`: *(CPU address, map registers) → (region kind `MK_*`, physical
  SDRAM word)*; the kind encodes the RPLY owner AND writability (see
  `qbus_pkg`). BK-0010 mode is a **bit-identical pass-through** of the old
  inline decode (that's what keeps every timing golden the regression
  anchor). BK-0011M banking = BkEmu `Bk11MemoryManager`: 177716 **word**
  writes with bit 11 (a byte write can never bank — no bit 11; the 177717
  odd byte is never banking), ROM field `& 0o033` decoded only as the exact
  single-bit codes (others fall through to RAM — a replicated BkEmu quirk),
  register write-only on read. The mapper owns the map registers (bus-write
  snoop) and exposes `bank_wr`, which gates the spk/mot capture (banking and
  peripheral writes are mutually exclusive; banking still sets the bit-2
  write-flag). **Map reset is DCLO-only — a deliberate exception to the
  nINIT peripheral-reset rule** (like the software-owned `spk_bit`): the
  RESET instruction must not swap the page under the running code (BkEmu
  semantics; checked by the bk11 SoC oracle). **`model_bk11` is
  re-registered locally (`model_bk11_q`) for the `bank_wr` term (fix
  CONFIRMED ON HARDWARE 2026-07-22):** it is quasi-static but high-fanout, and the route from
  its `ocbk_top` DCLO latch into the `bank_wr` AND tree feeding
  `win0_page`'s next-state LUT was the design's worst sys_clk path for
  three builds running (+0.077 → −0.039 at the CHS fix → −0.230 at
  CMD25). One local flop turns that long route into a plain flop-to-flop
  path: sys_clk −0.230 → **+0.420 ns, TNS 0, zero negative paths**,
  −2 LE, and the worst path moved back into `sd_backend`. The 1-cycle
  latency is invisible — `model_bk11` changes ONLY during a DCLO hold
  (CPU parked, map registers in reset, thousands of sclk before
  release). Deliberately **NOT** used by the combinational translate:
  that cone is already met, and `sim/run_mapper.sh` compares the decode
  combinationally right after a model flip. bk10 stays bit-identical
  (`model_bk11_q` ≡ 0 → `bank_wr` ≡ 0; all twelve ref037 goldens
  byte-identical). **Window-1 banked RAM is a
  normal `MK_RAM037` access — 037-owned RPLY, cycle-stolen, done-gated on
  `mem_ready`, riding the `cpu_sdram_dp` port-0 path** (`phys` from the mapper
  = the win1 RAM page; `addr` kept for byte lanes), identical to the low 32K.
  This matches the real hardware: **the 037 fronts ALL internal RAM, window 1
  included** — schematic-confirmed 2026-07-13 (`doc/bk0011m.sch`): the 037
  (D19) is the *sole* DRAM controller (all 16 565РУ5 RAS/CAS from it; the RAM
  reply is its own RPLY), and its AD15 pin is NOT the CPU A15 wire — it is
  driven by a banking OC-NAND (D10) so that, **accounting for the active-low
  Q-bus** (physical AD15 = 1 across 000000–077777), its internal A15 =
  `A15_true & ~(window-1-is-RAM)` = true A15 **forced low for window-1 RAM**.
  The vendored `va_037` gates ownership on the raw latched `A[15]`
  (va_037_sync.sv:238/:144) — a BK-0010 simplification (upper 32K is always
  ROM/IO there) — so we reproduce the hardware force: `qbus_mem` exports
  `ext_ram` (= a window-1 `MK_RAM037` access, i.e. `sel_ram && addr[15]`; 0 in
  bk10) and `va_037_sync` uses `a15_037 = A[15] & ~ext_ram` in the RASEL /
  cpu_grant terms. bk10 stays bit-identical (`ext_ram`≡0 → `a15_037`≡`A[15]`,
  all ref037 goldens invariant). Leave the AD15 start-vector assist
  (va_037_sync.sv:109) alone — it drives only the 177716 DIN read.
- **SMK512 (Phase 8; DIP 8): 512 KB segmented RAM (increment 1) + BIOS ROM
  and boot (increment 2):** layered into `mem_mapper` exactly at the
  window-ownership hook, as a second translate stage over the bk11 decode
  (`smk_en=0` ⇒ wire-through — every existing golden invariant). **BkEmu
  `SmkMemoryManager.java` (+ its unit test) is the authoritative reference**
  — it beat MiSTer on every divergence (reset default = **SYS** not STD11;
  strobe arming compares the low NIBBLE; byte writes lane-masked per
  `Computer.writeMemory`: odd byte = value<<8). Contract: register
  **0177130** (the floppy control register, "ab-used"), inside the ROM
  window so its reply is a positive decode carved from `sel_rom` in
  qbus_mem (since the IDE increment: `sel_fdd`, the КНГМД-stub block
  177130/177132 replying BOTH directions at the fixed `N_SMKREG`
  placeholder — see the FDD-stub note below) — NOT an nSEL; two-phase strobe (`(value & 017) == 06` arms, the FOLLOWING write
  commits mode `v[6:4]` + 32 KB page `{v0,v3,v2,v10}`); 8 modes × 8 4 KB
  segments (seg = `addr[14:12]`, rel = seg ^ 4 in SYS/ALL) per the BkEmu
  table incl. the BOS/second-window deselects → MK_NONE. SMK RAM = **`MK_EXT`**:
  FSM-owned fixed `N_EXT` reply read AND write (external-controller RAM is
  NOT 037-fronted — `ext_ram` stays MK_RAM037-only so `a15_037` stays high
  and the 037 never grants), done-gated both ways, riding the same
  cpu_sdram_dp port-0 path at `SMK_RAM_BASE = 0x40000` (256 Kwords,
  concatenation-only). HLT10 seg 0 = read-only via the mapper's `smk_ro`:
  the write is not `selected` (the exact ROM-write rule → trap 4) and its
  u_dp feed is `sel_romr`, so it is structurally never issued to SDRAM.
  **Increment 2 — the BIOS ROM and boot:** ONE 4 KB image
  (`mem/roms/smk512_v205.rom`, appended to the bk11 blob → SDRAM
  `SMK_BIOS_BASE = 0x3A000`) backs BOTH windows — **rom6** @160000
  (SYS/STD10/STD11) and **rom7** @170000 (SYS only); MK_ROM (reads via
  u_dp at the fixed `N_ROM`, writes → trap 4). **The boot hack** (what makes
  DIP-8-ON boot): in SYS rom7 covers the FULL 0170000–0177777 *including
  the register space*, so the vm1's initial-start 177716 read returns
  `bios[0o7716] | SEL1` = 166400-based (the open-collector wire-OR; BkEmu
  ORs memory and device reads) → PC = 166400, inside rom6. qbus_mem
  reproduces the merge by latching `io_word | ram_rdata` at the reply point
  and driving it itself; u_dp still fetches but its pad drive is suppressed
  by the issue-time `rd_noe`/`was_drive` flop (the pad-OE rule — never a
  live translate term in an OE cone). TWO carve-outs (documented
  deviations): **177700–177717** (vm1-internal: never replied/driven; the
  boot-critical 177716/14 merge rides the existing nSEL `sel_io` reply;
  extent writes still POST to SMK RAM silently — BkEmu broadcast-write) and
  **177660–177667 READS** (kbd/037 push-pull-drive their own data; the
  smk64 replica carves the same hole; extent writes stay claimed). Seg-7
  restricted extent 0177000–0177777 per mode: ALL = readable (`smk_ro`),
  HLT10/HLT11 = writable (`smk_wo`, the write-only mirror riding a new u_dp
  `sel_ramw` write-only leg — the 177674/76 HALT-debugger catch: СТОП's
  HALT-entry stores land in SMK RAM and the HALT vector comes from 160002/4
  = SMK RAM seg 6), others capped → MK_NONE. All the per-mode window/extent
  flags are decode-at-commit registers next to `seg_*` (the STA rule). The
  **177130/177132 КНГМД (FDD-controller) stub** (IDE-increment hardware
  fix): the SMK board carries a REAL floppy controller, so both registers
  reply BOTH directions REGARDLESS of layout — BkEmu's SMK config always
  attaches FloppyController, whose no-drive control read is 0. qbus_mem's
  `sel_fdd` reproduces that (reads reply 0-merged — under SYS the rom7
  BIOS word still ORs in; the mapper stays the layout-write snooper, never
  the reply owner; in HLT modes the extent u_dp write leg still posts to
  SMK RAM on the pre-commit translate = BkEmu's memory-then-device order,
  so a mode write can't re-map its own cycle). The increment-2 "reads
  trap 4 outside SYS" was OUR simplification, not BkEmu's — the real
  BIOS's FDD boot attempt (which follows a failed HDD boot) trapped on
  its status polls and CRASH-RESTARTED the machine (hardware 2026-07-18).
  SMK-off keeps 177130 plain ROM (sim/romwr contract).
  TIMING: I/O-page MK_EXT accesses take the `N_ROM` count, NOT `N_EXT` —
  the 037's start-vector assist replies EARLY at 177716 (wire-AND) and the
  vm1's data-sample point sits a fixed distance after that assert; the
  `N_EXT` count landed the merged word too late (found in sim). The FSM
  done-gate keys on the legs u_dp actually ISSUES (an smk_wo read / smk_ro
  write never issues — gating on raw `sel_ext` would hold RPLY forever
  where `sel_io` coexists). **IDE increment (a) — the drive engine
  (`src/peripheral/smk_ide.sv`), done in sim:** the SMK IDE task file at word
  addresses **0177740–0177756** (BkEmu `SmkIdeController` over
  `IdeController` is the contract; `IdeControllerTest` the transcribed
  oracle) — ALL data bit-inverted **both** directions at the bus adapter
  (~; the backing store holds TRUE data = a **raw AltPro image**, the
  same bytes BkEmu attaches), the composite registers 177740 (read
  {drive-addr, status}, write-at-exact-740 = COMMAND, byte 741 ignored)
  and 177742 (read {alt-status, DHR |0xA0}, write-at-exact-742 = DHR,
  byte 743 = the control register / SRST), ONE master drive (the absent
  slave reads bus 0xFFFF), **CHS only** (the DHR LBA bit ⇒ ABRT — a
  documented deviation, BkEmu supports LBA), commands **IDENTIFY /
  READ 0x20-21 / WRITE 0x30-31**, everything else BkEmu's own ABRT
  default (0x41/0x04). Geometry parses **in hardware from image sector 7**
  (the AltPro partition table: inverted words, checksum seed 012701,
  records growing down from byte 0770; fallback = BkEmu raw defaults
  S=63 H=16 C=total/1008, C==0 ⇒ attach fails ⇒ absent). Status shows
  **SR_BSY while the backend works** (fetch gaps / write commits) — a
  required deviation from BkEmu's instantaneous model (a !BSY poll after
  the last data word must not see command-complete mid-commit); end
  status is BkEmu's 0x50 exactly. The device is an `ocbk_top` **sibling**
  (all sclk, snoops the bus, never drives it): qbus_mem's `sel_ide`
  decode owns the RPLY both directions (fixed `N_IDE` = N_ROM-family
  placeholder) and ORs the registered `ide_rdata` into its reply-point
  merge — BkEmu `Computer.readMemory`'s memory|device OR (under SYS the
  rom7 BIOS bytes merge in; extent-mode writes still broadcast to SMK
  RAM). Reset is **DCLO-only — the 5th deliberate nINIT exception**
  (BkEmu resets the IDE on hardware reset only; software resets ride
  SRST). The 2-bank 512×16 sector buffer (2 M4Ks) + the backend sector
  port (req/ack/done, 28-bit LBA, bank field, all sclk) are the SD/SPI
  seam AND the tier-1 prefetch ping-pong. **Tier-1 READ prefetch
  (CONFIRMED ON HARDWARE 2026-07-19):** `bank_drain` (CPU-facing: drain /
  E_FILL / E_COMMIT) and
  `bank_fetch` (backend-fill) split the buffer; at each READ sector's
  drain-start (E_FETCH's bk_done for sector 0, the E_DRAIN bank swap for
  the rest) the engine issues `bk_sector+1` (a linear +1 index, so no
  `cur_lba` register) into the idle bank when `scount` says the chain
  continues — the inter-sector BSY gap collapses to ~0 when the CPU is the
  slower drainer, else E_DRAIN parks BSY until the prefetch's `pf_ready`.
  A global ack/done handshake tracks the outstanding op in `bk_out`
  (`bk_busy = bk_req||bk_ack||bk_out`); a mid-command new COMMAND/SRST
  routes to **E_FLUSH**, which waits `!bk_busy` before re-pinning both
  banks (so a stale prefetch stream can't corrupt the new command's bank —
  the WRITE case defers its DRQ past the flush). **Last-read/written CHS
  view:** the visible task-file registers point at the sector CURRENTLY in
  transfer — set to sector 0 at dispatch and held, then advanced only at
  each later sector's drain-start (the E_DRAIN swap for READ, E_COMMIT for
  WRITE), never one-ahead and never at a prefetch's own bk_done — so a
  COUNT=N run ends with them on the last sector handled (BkEmu-faithful
  after the 2026-07-21 fix, CONFIRMED ON HARDWARE — the old code left them
  one past it; no cross-command auto-advance, so consecutive single-sector
  READs must set CHS explicitly). WRITE and SD multi-block stay strictly
  sequential. **pLed[7] = drive-access LED**:
  `ide_act` (command/backend in flight — DRQ phases, backend ops, the
  attach-time geometry read; register pokes alone don't light it)
  stretched to ~87 ms in `ocbk_top` and **blinked at ~11.5 Hz** while lit
  (a second `ocbk_top` counter, `ide_blink`, held at 0 while the LED is
  dark so every burst starts in the ON half: an isolated op is one clean
  ~43 ms flash — the stretch window is exactly one blink period — while
  continuous access, which re-arms the stretch every few µs, blinks
  instead of sitting solid). **Increment (b) — the SD/SPI
  backend (`src/peripheral/sd_backend.sv`) — DONE, CONFIRMED ON HARDWARE
  2026-07-18: the BIOS boots an OS from the SD-backed HDD image.** The
  card in the megasd slot (PIN_61–66, esemsx3 SPI-mode pin roles:
  DAT3 = CS — push-pull per the virq_n lone-Z rule — CMD = MOSI,
  DAT0 = MISO, DAT1/DAT2 pad-only Z with QSF weak pull-ups, the
  pDac_SR class of intentional pad tri-state) holds the raw AltPro
  image dd'd at card LBA 0 (`gen_ide_image.py` also emits the dd-able
  `ide_image.bin`); `bk_total` = the FULL card capacity from the CSD.
  Init ladder: >=74 CS-high dummy clocks, the **warm-reset recovery
  preamble** (see the next bullet), then CMD0/CMD8/ACMD41(HCS)/CMD58/
  (CMD16)/CMD9 at /256 =
  377 kHz, then /8 = 12.08 MHz data (the epcs_boot shifter idiom:
  mode 0, MSB first, launch at the fall, sample late-high); SDSC
  byte- AND SDHC/SDXC block addressing, both CSD capacity formulas;
  CMD17/CMD24 single-block; SPI-default CRC policy (real CRCs only on
  CMD0/CMD8); CMD17/CMD24 single-block only. All sys_clk — no CDC on the
  seam; reset DCLO-only like the engine (card re-init at power-on AND
  warm reset = "insert card, press reset" — the slot has NO card-detect
  pin).
  **TIER-2 MULTI-BLOCK (CMD18/CMD25) WAS REVERTED 2026-07-23** after
  being implemented and hardware-confirmed (2026-07-21/22). It coalesced
  a contiguous run into one streamed transfer, saving the ~10-byte
  command frame per sector — ~7 µs against a 342 µs block at the /8 data
  clock, i.e. **~2%**. That 2% is invisible: the BK drains 256 words
  through the task file at 4.03 MHz (~500–750 µs per sector), so the
  DRAIN is the bottleneck and the tier-1 prefetch already hides the whole
  fetch behind it. Against that it cost a real fault — streams were
  closed LAZILY (only when the next op turned out non-contiguous), so one
  stayed open across idle time, a warm reset left the card streaming
  (DCLO resets us, not the card), and the BIOS could not find the drive
  until a SECOND reset press. Chasing that cost a recovery preamble, a
  whole-ladder retry, an idle-close timer, four structural timing fixes
  and ~150 LE. **If it is ever revisited: close the stream when the
  OPERATION ends** — ao486's `rtl/soc/driver_sd/card_read.v` issues CMD12
  on the last sector of every read, so a stream never outlives the
  transfer — not lazily. (That driver is native 4-bit SD, where responses
  ride a separate CMD line and streaming data cannot corrupt them; SPI
  shares MISO between data and responses, which is why this whole failure
  class exists here and not there.)
  **WARM-RESET RECOVERY PREAMBLE + WHOLE-LADDER RETRY (kept from the
  tier-2 episode):** DCLO resets US but NOT the card, so a warm reset can
  land mid-transfer and leave the card holding the rest of a block. It
  then answers the init ladder with image data, and ONE stray byte
  anywhere in the ladder is fatal — `S_CMD0_R` mis-reads R1, and worse,
  `S_CMD8_R` reads any byte with bit 2 set as "illegal command = a v1
  card", after which an SDHC card gets ACMD41 WITHOUT HCS and by spec
  never leaves idle. Cure, before CMD0: send **0xFD** (stop-tran; inert
  unless something left a write-multiple open — MSB set, so never a
  command start), wait out any program-busy window (`PRE_BUSY_BYTES`,
  time-sized at ~255 ms = the SD write timeout), send **CMD12** (closes a
  read-multiple; a harmless illegal-command otherwise), then **flush a
  FIXED `PRE_FLUSH`=1100 bytes** — a whole block + token + CRC + R1 +
  busy — before waiting for the bus to look idle (`PRE_IDLE`/
  `PRE_FF_RUN`). The fixed drain is load-bearing: the residue is image
  data, and on a BK disk that data is full of 0xFF runs (the IDE layer
  inverts, so BK zero-filled regions are stored as 0xFF), so an
  "exit once the bus looks idle" flush stops INSIDE the residue. Then
  ≥74 CS-high clocks again, immediately before CMD0. States `S_PRE_*`,
  with a private `pre_cnt`/`pre_z` deliberately NOT another `wait_cnt`
  load site. **`S_RETRY`**: EVERY init-stage failure (not just CMD0's)
  re-runs the whole recovery, up to `INIT_TRIES`=8, clearing `v2`/`sdhc`
  so each attempt re-types the card — the automatic equivalent of the
  second reset press, and the only cure that does not depend on guessing
  which byte got corrupted. `dbg_fail` carries WHERE init died (1 CMD0 …
  5 ACMD41-stalled-as-v1 … 10 CSD), available for LED bring-up.
  Oracle: `sim/ide/run_sd.sh` leg 4 + the `+cmd0busy`/`+cmd8junk`
  injections, mutations 10–14; the model gained two real-card tolerances
  (an inert 0xFD and a CMD12 with no stream open, counted apart).
  Enable-gated, so a
  stock machine never clocks the card. A failed/absent-card init parks
  media-absent = exactly the old increment-(a) tie-off; data-op errors
  complete done+error (the engine ignores them — the BkEmu rc rule;
  only the attach-time geometry read honors `bk_error`). BYTE-FSM RULE
  (a design-review catch — the bug would have shifted every command
  frame): a state asserts the byte engine's `x_go`/`x_tx` only in
  NON-`x_done` cycles, so a state change never launches the next byte
  with the old state's data. **STA — the `st` next-state cone is this
  module's chronic critical path** (2026-07-23): every wide compare
  tested at a state decision lands in it, and the FSM is big. Cures, all
  the same shape — precompute into a flop, never re-derive at the
  decision point, and NEVER reach for an SDC exception: `x_ff` ("the byte
  received was 0xFF", computed in the byte engine), `wait_z` (the 20-bit
  timeout zero-test), `pre_z`, `widx_last` (the 8-bit last-word test),
  and `d_oob` (the 28-bit capacity compare, precomputed at the A_IDLE
  capture edge — legal because the port holds its fields until bk_ack).
  Two quasi-static signals needed the `model_bk11_q` treatment as well:
  `smk_en_q` in **qbus_mem** (registered in the PARENT, not in
  mem_mapper, because `run_mapper.sh` flips smk_en and compares the
  decode combinationally with `#1`) and `enable_q` here. **`enable_q`
  must reset to 1**, not 0: `S_SETTLE` parks in the DEAD-END `S_DISABLED`
  the moment it sees `!enable_q`, and it is evaluated on the first cycle
  out of reset — resetting that flop to 0 disabled the backend on every
  reset even with a card present (caught by the `-DSD_STACK` leg).
  Post-fix sys_clk +0.572 ns / TNS 0. **The same shape bit `smk_ide` in
  Phase 9 (2026-07-25):** `scount`'s next-state cone carried the 9-bit
  `ptr == 9'd256` block-complete compare, and when the `N_EXT` work
  re-placed the fitter (+19 LE) that cone went **+0.481 → −0.414 ns** —
  a module the change never touched, which is exactly how placement-
  fragile this design is at 58 % LE. Cure in the same idiom: `ptr` only
  ever holds 0..256 (the E_DRAIN advance runs only with drq and reloads
  at 256; the E_FILL advance is guarded by `ptr != 256`), so the test is
  the single bit `ptr[8]` — `wire ptr_full = ptr[8]`, nine inputs out of
  the cone.
  **BK-0010 + SMK (BkEmu `BK_0010_SMK512`) — DONE, CONFIRMED ON HARDWARE
  2026-07-23 (the BIOS boots and loads an OS on a BK-0010):** the SMK is an МПИ
  expansion board and `SmkMemoryManager` is ONE class shared by both
  configurations, so every SMK term (`smk_reg_wr`, `smk_act`, `sel_fdd`,
  `sel_ide`, the `smk_ide`/`sd_backend` enables) is gated on `smk_en`
  ALONE. The only model-dependent part of the layout logic is WHICH
  standard memory a mode deselects: on bk11 the BOS ROM + the second
  banked window (the `seg_std` vector), on bk10 the **monitor ROM** —
  the new commit-decoded `mon_en` flag (`selectBk10MonitorRom`; set in
  SYS/STD10/STD11/RAM11), consumed through
  `std_vec = model_bk11 ? seg_std : (mon_en ? 8'b0000_0011 : 0)`. So on a
  bk10 a "standard" segment is covered ONLY for segs 0,1 (0100000–0117777
  = the monitor ROM) and only while `mon_en`; **the machine's own BASIC
  region 0120000–0177577 is MK_NONE wherever the SMK does not cover it**
  (STD11 segs 2–5, RAM11/HLT11 segs 2,3) — BkEmu's bk10 SMK config has no
  BASIC ROMs at all, and on real hardware the SMK drives those addresses
  in every other mode. HLT11 is the ONE mode where `mon_en` is observable
  (segs 0–3 all dead). Everything else is shared, so a model flip finds
  the same layout. The BIOS **auto-detects the model** (doc/smk64.mac
  `START`): with vector 4 planted it writes 0177662 — replied on a bk11
  (qbus_mem's model-gated `sel_vreg`), un-decoded on a bk10 where under
  SYS it is a rom7 ROM write → trap 4 → the `MODE_STD10` commit ("для
  10"). HLT10, the SMK HALT-debugger mode (СТОП's HALT-entry stores
  caught by the write-only 177674/76 extent, vector from 160002/4 = SMK
  RAM seg 6) is what that machine is for. No blob change: `epcs_boot`
  loads both blobs unconditionally, so the BIOS is resident at
  `SMK_BIOS_BASE` whatever DIP 1 says.
  **Still deferred:** the SMK-RAM
  `ram_init` pattern, real data CRC16, MMC cards, and
  `N_SMKREG`/`N_IDE` recalibration (`N_EXT` is done — see the next bullet).
  Oracles: `sim/run_mapper.sh` + `sim/smk/run.sh` (**both legs** — bk11
  and `+bk10`) + `sim/ide/run.sh`
  (BOTH passes — disk model AND the `-DSD_STACK` real SPI stack) +
  `sim/ide/run_soc.sh` + `sim/ide/run_sd.sh` (see the sim list) +
  `sim/run_boot_check.sh +smk` / `+smk +sdspi` / `+smk10` +
  `sim/smktime/run.sh`.
- **SMK512 access time `N_EXT` = 1 (Phase 9, CALIBRATED against real hardware
  and CONFIRMED ON HARDWARE 2026-07-26; was the Phase-8 placeholder
  `N_RAM` = 4):** measured with a
  tone-frequency program (`test/sndtestsmk.mac` — 192 `SOB` iterations around a
  177716 speaker toggle, so one half-period is 197 fetches from the resident
  memory and nothing else), run on a **real BK-0011M + SMK512** and on the
  board, with the SAME loop run from ordinary RAM as a control:

  |                       | loop in SMK RAM | loop in ordinary RAM (control) |
  |-----------------------|-----------------|--------------------------------|
  | real                  | 601 Hz (3351 cyc) | 478 Hz (4212 cyc) |
  | board, `N_EXT` = 4    | 514 Hz (3918 cyc) | 482 Hz (4177 cyc) |
  | **board, `N_EXT` = 1**| **602 Hz  (+0.17 %)** | 482 Hz (+0.84 %) |
  | `sim/smktime`, `N_EXT` = 1 | 599 Hz (3362 cyc) | 482 Hz (4176 cyc) |

  The control leg landing at +0.8 % is what makes this a measurement of
  `N_EXT` and not of the clock rate, the access count or the CPU core — all
  three are thereby validated, and the entire −14.5 % sat in that one
  constant. One unit of N is exactly one CPU cycle (independently: `BR` costs
  16 cycles at `N_RAM=4` in `sim/bk10/golden.txt` and 13 at `N_ROM=2` in
  `golden_037_rom.txt`), and the gap was 567 cycles / 197 accesses = 2.88 —
  i.e. the real board replies **within the strobe cycle**, like any async
  external SRAM board, the same reason `N_KBD = 1`.
  **The hardware result also identifies what the residual is: our CPU clock,
  and essentially nothing else.** Both legs run the identical instruction
  stream, so `C = C_internal + reply_overhead + 037_steal`, and the `N_EXT`=4
  board pair separates the terms (at N=4 both legs carry the same 197×3
  overhead, so their *difference* is the steal): `C_internal` = 3326.3,
  steal = 260.1 = 1.320/access. Ask what real CPU clock would reconcile the
  real machine's measured tones with **those** cycle counts and the two legs
  answer independently — **3.998 MHz** from the SMK leg, **3.994 MHz** from
  the control leg, agreeing to 0.12 %, i.e. **4.000 MHz**, the documented
  BK-0011M rate. Ours is 96.6477/24 = **4.0270 MHz, +0.67 %**: the
  OneChipBook's 21.47727 MHz crystal cannot make exactly 4.000 under the
  one-PLL rule. Two independent legs landing on the same implied clock is the
  signature of *the cycle counts are right, the clock is different*.
  Normalised to 4.000 MHz the leftovers are `C_internal` **+1.5 cyc
  (+0.04 %)** and steal **+5.2 cyc (+0.027/access)** — both inside the ±8.7
  cycles that ±1 Hz on the 478 Hz reading is worth. **So no memory-model debt
  remains, the 037 steal included**, and `N_EXT` = 1 is tighter than the raw
  numbers suggested: against a 4.000 MHz machine the real SMK leg is 3327.8
  cycles vs our ideal 3326.3 (N=2 would be 3523).
  ⚠️ Do NOT re-derive a per-access error by dividing a whole-leg gap by the
  access count — 35 cyc / 197 = "0.18/access" double-counts everything that is
  not memory. That mistake was made once here and shipped for a few hours.
  (The board reading HIGHER than the sim's 599 is expected and was predicted:
  the tb's port-2 model saturates the arbiter while the shipped video fetch is
  paced — see the residual note below.)
  Two mechanisms make N=1 expressible, **both gated on `N_EXT == 1` so they
  constant-fold away if it is ever raised**:
  * **`qbus_mem`'s `ext_fast`** — the wait FSM counts `N-2` edges and cannot
    express N=1, so the reply is issued at the *detection edge itself*. Only
    the mem-region `MK_EXT` leg (`sel_ext && !ovl_zone`) takes it; the I/O-page
    extent keeps `N_ROM` for the start-vector-assist reason above. Reads
    require `mem_ready`; **writes do not** — a posted write whose data was
    captured one sclk after DOUT, and u_dp is single-threaded so the next
    cycle's fetch cannot overtake it.
  * **`cpu_sdram_dp`'s `fast_rd`** — at N=1 the reply lands *before* a
    DIN-issued read could have finished, so the MK_EXT read starts at **SYNC**
    instead. **Rule: a fixed reply shorter than the SDRAM latency requires the
    fetch to start at the address phase, not at the strobe.** Three things it
    needs, each a bug that was actually hit: WTBT must be **latched** one sclk
    into the SYNC (`wtbt_hold`) because its address-phase meaning is only on
    the wire for ~120 ns — sampling it live makes every write look like a read,
    fire an early fetch and get **dropped**; `early_pend` must suspend
    `D_DONE`'s strobes-idle exit until DIN arrives, or the fetch completes and
    `mem_ready` falls again during the address phase; and `pre_done` keeps it
    to one issue per SYNC so a DATIO's write half still goes out normally.
    Sampled at `sync_sr[1]` (2 sclk), **not** [0]: that arc is `qbus_sync`,
    false-pathed in the SDC, so STA checks none of it — one sclk earlier is
    worth 601.7 Hz vs 598.9 and halves the margin on a path no tool is
    watching (the SEED-3 lesson).

  Residual: the early read gets ~22 sclk of head start and the SDRAM needs ~8,
  but the arbiter grant costs 4..14 more, so a minority of reads miss by one
  edge and take the ordinary S_WAIT path (+1 cycle, no `dbg_romgate`) — that
  is the 3362 vs the ideal 3327, and `sim/smktime`'s `EXTRD fast/slow` pins it.
  The shipped design's port 2 is paced rather than saturating like the tb, so
  the board should read slightly faster than the sim. Knock-on: the speed-up
  makes СТОП re-enter once inside its fixed 64-cpu_clk one-shot (the HALT entry
  now fits), which `sim/smk` §12 was pinning too tightly — see the note there.
  **Two STA knock-ons, both in modules this change never touched** — worth
  internalising, because it is what "placement-fragile at 58 % LE" means in
  practice: +19 LE re-placed the fitter and took sys_clk +0.481 → −0.414 via
  `smk_ide`'s `scount` cone, then → −0.023 via the mapper↔bus-pad loop. Both
  fixed structurally in the established idioms (`ptr_full = ptr[8]`;
  `rdata_oe = oe_arm && !din_n`), never an SDC exception. Final: **+0.190 ns,
  TNS 0, 6,953 LE**. Rule of thumb: after any increment here, budget for an
  STA chase somewhere else in the design.
  Oracle: **`sim/smktime/run.sh`** (three legs — the third is bk10+SMK).
- **Framebuffer conventions** (mirrored by `fb_video_tb`/`gen_expected.py`
  alike): FB = 512 slots/line × 4-bit colour nibble × 256 lines, 128
  words/line, slot `s` of a word at bits `[4s+3:4s]`, LSB-first in beam order;
  FB0 = SDRAM word `0x010000`, FB1 = `0x018000`, double-buffered (writer swaps
  at the vgate frame edge, reader latches `fb_front` at its vblank line-0
  request). **Since Phase 7 the FB nibble IS the BK-0011M physical colour
  {R1, B, G, R0}** (2-bit red, 1-bit blue/green — the machine's whole colour
  space is 16 colours): `palette_apply` looks up the 16-palette ROM
  (transcribed **verbatim** from MiSTer `BK0011M_MiSTer/rtl/video.sv` — note
  its bit-swapped nibble select `{p[0],p[1]}`); palette 0 = {0,4,2,9} =
  black/blue/green/red is the bk10 palette (bk10 ties `pal_idx` to 0);
  `vga_out` decodes the nibble combinationally, red levels 0/0x23/0x30/0x3F
  (the BkEmu 0x8E/0xC0 weights — also the CRT colour-tweak hook). bk10 RGB
  at the DAC is bit-identical to the old fixed CLUT. FB *destination* comes
  from beam counters, fetch *address* from `video_va` (else scroll breaks);
  the fetch *base* is `fb_video`'s live `vram_base` input (bk10: fixed
  `24'h002000`; bk11: the 177662-selected page). Scroll: row r fetches vram
  line `(RA − 0o330 + r) & 0xFF` (netlist-proven). `screen_mode`
  (mono-512 / colour-256) is toggled by the PS/2 Print Screen key (power-on
  default = colour-256), touches only `palette_apply` (mono ignores the
  palette, as real hardware).
  **The palette is sampled at the word's DISPLAY instant, not its fetch
  (Phase 9, 2026-07-26).** `palette_apply` runs on the FB *write* side, so the
  physical colour is baked in per fetched word — the granularity is right
  (16 dots; two 177662 writes are ≥ ~10 CPU cycles ≈ ≥ 30 dots apart, so word
  quantisation can never merge two), but the *instant* was wrong: `pal_idx`
  rode `vid_fetch`, which is 3 CLKIN before the word actually reaches the
  screen, pushing every raster palette boundary ~6 dots right. On the real
  board the chain is DRAM → **К155ИР13** shift registers (D24/D25) → КР556РТ4А
  palette PROM → CRT with **no latch in between**: the ИР13s take their
  parallel data straight off the DRAM data pins (nets S5-1..16) and their mode
  pin S0 *is* `PIN_WTI`, so the word starts displaying at the WTI load.
  Measured on the reference netlist and the retimed core (one slot = 8 CLKIN):
  `vid_fetch` +0, video CAS and WTI rise +1, **WTI fall +3** — the load edge
  that counts, since the DRAM data is only valid late in its CAS window and
  any earlier edge reloads the same word. Hence `va_037_sync`'s **`vid_pal_stb`**
  tap (`vid_fetch` delayed 3 `en_neg`, generated UNCONDITIONALLY — re-qualifying
  on `~HGATE` would drop the last slot of every line) and `fb_video`'s
  **`F_HOLD`** state, which holds the fetched word until its display-instant
  palette has been sampled. The fetch *address*/page stays on `vid_fetch`,
  deliberately: the page bit re-addresses the DRAM, so its instant is CAS
  (+1), not display. Residual uncertainty is the +1..+3 span (≤ 4 dots) — the
  D8/D10 dot-clock phase would be needed to pin it further.
- **177662 video register (Phase 7, BK-0011M):** **MiSTer `rtl/video.sv` is
  the reference** (BkEmu simplifies it). Write-only (662 reads belong to the
  014 keyboard data register in BOTH models) and bk11-only (a bk10 662 write
  keeps bus-timing-out → trap 4); high byte only: bit 15 = displayed screen
  (0 = RAM page 1 = `BK11_VPAGE0`, 1 = page 7 = `BK11_VPAGE1`), bit 14 =
  frame-IRQ2 mask (active high; irq_en = ~bit14, consumer = the EVNT/IRQ2
  bullet below), bits 11:8 = palette. Immediate effect (no per-line latch —
  BkEmu's per-scanline latch is an emulator artifact); **DCLO-only reset**
  (same deliberate nINIT exception as the map registers), defaults = MiSTer
  `def_reg662` 0o047400 (page 0, IRQ2 masked, palette 15). Implemented in
  `qbus_mem`: the ONE positive decode besides the nSEL pair — sclk
  DOUT-window capture next to `spk_bit`, write reply = fixed `N_VREG`.
  `bk_kbd014` is untouched. `ocbk_top` muxes `vram_base`/`pal_idx` on
  `model_bk11` (all sys_clk — no CDC).
  **`N_VREG` = 1 (Phase 9, 2026-07-26; was the `N_ROM` placeholder) — and the
  measurement that set it also proved the constant is UNOBSERVABLE.** The
  schematic says the board replies combinationally: D35 (the palette register,
  К555ТМ9) is clocked by net S1-78 = **D6:C** (К555ЛЕ4 NOR of the 037's BS
  D19.38, DOUT D19.40 and the latched address bit D27.9), and *that same net*
  drives **D34.1** (К555ЛН2, open-collector) whose output wire-ORs onto
  **S1-49** = the K input of **D8:B**, the flop that re-times RPLY onto the
  CPU's RPLY pin. It has to be that circuit — the bus RPLY net S1-21 has
  exactly four drivers (014, 037, the two RE2A ROMs), the 014 does **not**
  reply to a 662 write (`sim/ref014/README.md`) and the 037 decodes only
  177664. So N=1 is the faithful value (expressed by `qbus_mem`'s `vreg_fast`,
  the `ext_fast` mechanism reused, gated on `N_VREG == 1` so it folds away).
  **But `sim/vregtime`'s `--sweep` shows N = 1..4 give BIT-IDENTICAL cycle
  counts** on two instruction shapes, with the VREGWR probe confirming the FSM
  really took the other path: a DATO's RPLY in that range lands inside the
  vm1's fixed write cycle and never moves the next SYNC. This closes the
  placeholder permanently in BOTH directions — no fidelity risk, and **not** a
  candidate for beam-raced-palette timing artefacts (that was the hypothesis
  the oracle was built to test, and it falsified it).
- **TURBO mode (Phase 9): 6.04 MHz CPU + no 037 cycle-stealing, PS/2 **F12**,
  `pLed[5]` — DONE & CONFIRMED ON HARDWARE 2026-07-29.** The one deliberately
  **NON-AUTHENTIC** feature in the design —
  every timing golden is defined at turbo = 0, and nothing constrains turbo
  behaviour beyond "the program still executes correctly". Two halves, and they
  only work together:
  * **the clock** — `cpu_clkgen`'s third rate, /16 = 6.0405 MHz (see the
    clocking bullet). Overrides the model select; live, not DCLO-latched.
  * **the arbitration** — `va_037_sync`'s new `no_steal` forces the *decoded*
    A15 high (`a15_gnt`, a separate wire — the `a15_037` line itself is a
    verbatim anchor in `sim/grantfit/patch037.py`, leave it byte-for-byte), so
    the 037 treats every CPU access as "not mine": `grant_raw` folds to 0,
    RASEL never rises, TRPLY/RPLY stay 0. `qbus_mem` takes the RAM reply over
    (`sel_turbo`) at the fixed `N_TURBO`.
  **The clock alone would barely help, which is the whole point of doing both:**
  the 037 grants one slot per 8 CLKIN and CLKIN is a FIXED sys_clk/16, so a slot
  that costs 4 CPU cycles at /32 costs **8** at /16 — doubling the clock roughly
  doubles the stall in CPU cycles. Measured (`sim/smktime`, ordinary-RAM leg —
  the same loop resident in 037-fronted RAM, at each authentic rate and in
  turbo):

  |            | authentic          | turbo /16            | speed-up | = clock x cycles |
  |------------|--------------------|----------------------|----------|------------------|
  | BK-0011M /24 | 481.2 Hz (4184 cyc) | 856.1 Hz (3527.8 cyc) | **1.78x** | 1.50 x 1.186 |
  | BK-0010 /32  | 384.5 Hz (3928 cyc) | 856.1 Hz (3527.8 cyc) | **2.23x** | 2.00 x 1.113 |

  **The two factors move in opposite directions across the models, and that is
  the fixed-slot argument showing up in the data:** a BK-0010 gains more overall
  (its clock ratio is 2.0) but LESS from removing the steal (1.113 vs 1.186),
  because an 8-CLKIN grant slot is a fixed wall-clock time and therefore costs
  4 CPU cycles at /32 against 5.33 at /24 — the faster machine was losing more
  cycles to arbitration to begin with. The per-instruction spread that IS the
  steal beat says the same: min=20/max=23 on bk10 and min=20/max=26 on bk11,
  both collapsing to min=18/max=19 in turbo. The turbo cycle count is
  *identical* (21167) in both models, which is the cross-check — in turbo
  neither the rate nor the memory path depends on the model.
  **Why it is cheap here and would not be on real hardware:** `cpu_grant` is
  already unconnected (`ocbk_top`) — the SDRAM fetch rides `qbus_mem`'s
  `sel_ram`, so the 037's ONLY functional contribution to a RAM access is the
  RPLY timing. Every RASEL-derived DRAM pin is unconnected too, and the whole
  video/EVNT side (PC/VA/LC/HGATE/VGATE/WTI/SYNCO) advances on
  `en_pos`/`en_neg` and never looked at RASEL. **So the picture and the 50 Hz
  EVNT/IRQ2 are bit-identical in turbo** — a real-time-timed effect keeps real
  time while CPU-timed loops run 1.78x faster, which is the differential to
  check on the board.
  **The reply-owner swap is the dangerous part, and `src/sys/turbo_ctl.sv` is why it
  is not:** if the level moved mid-cycle, an access could start under one owner
  and finish under the other — and the bad direction is SILENT (the 037 declines
  the grant, qbus_mem is past its detection edge, nobody replies, qbto turns it
  into a spurious trap 4 under the running program: exactly what hitting F12
  during a game would do). So `turbo_ctl` re-registers the level only on an edge
  where SYNC+DIN+DOUT are ALL released, for two consecutive sclk (these are
  resolved wired-AND nets). SYNC framing covers the DATIO RMW gap. It is a real
  module, not inline logic, so the tbs instantiate it (the `cpu_clkgen` replica
  lesson) — `sim/bk11`'s `+turboflip` leg is the only thing that can kill a
  mutation of it.
  **`N_TURBO` = 2 covers ALL THREE SDRAM-backed mem-region legs in turbo — RAM,
  ROM and SMK RAM (`turbo_mem`) — and that uniformity is required, not tidy.**
  The authentic counts were calibrated against a 3–4 MHz machine and two of them
  cannot survive the halved cycle: `N_EXT` = 1 relies on `cpu_sdram_dp`'s early
  SYNC-time fetch beating the reply point, and at /16 the head start is gone
  (found in sim — `sim/smktime`'s turbo SMK leg tripped the gate on its first
  fetch, so `ext_fast` is now `!turbo_mem`-gated); `N_ROM` = 2 is the same
  arithmetic one cycle out. At /16 an SDRAM access (12..22 sclk) is comparable
  to one CPU cycle (16 sclk), so **the `mem_ready` done-gate fires routinely and
  that is BY DESIGN** — the reply lands as soon as the word is there. Those
  holds therefore raise **`dbg_turbowait`, never `dbg_romgate`**: `dbg_romgate`
  means "a fixed-N reply was extended UNEXPECTEDLY" and `sim/smktime` fails a
  run on it, so routing turbo through it would destroy the flag everywhere.
  The I/O page (`ovl_zone`) is excluded — those reads keep `N_ROM` for the 037
  start-vector-assist reason, and 177716 is boot-critical.
  Turbo **survives a warm reset** (a user setting, like `screen_mode`: the
  `kbd_ps2bk` toggle is power-on-init only and outside the ACLO reset;
  `turbo_ctl`'s reset is the PLL lock, never `dclo_n`). It works in **both
  models and with the SMK512**. `ps2_rx`'s mid-frame dead-man was widened 10 →
  11 bits because it is counted in cpu_clk: at 10 bits turbo gave ~170 µs, only
  ~1.7 PS/2 bit-times.
  Oracles: `sim/run_clkgen.sh` leg D (the /16 rate + turbo×model retarget
  sweep), `sim/run_ps2.sh` §12d (the F12 radial toggle), `sim/bk11/run.sh`
  (`+turbo` = the whole contract at /16, `+turboflip` = F12 banged throughout
  the run), `sim/romwr/run.sh +turbo` (the sharpest test of the `selected`
  change — RAM must now be replied to HERE while a ROM write must still trap,
  and the conditionless screen clear only ends because of that trap),
  `sim/smktime/run.sh` (the two turbo legs = the speed measurement + its
  golden), `sim/run_boot_check.sh +turbo` (the real MONITOR/BOS/BIOS firmware
  at /16). Everything else must be **byte-identical at turbo = 0** and is —
  `make sim` green, and `sim/grantfit`'s baseline still reproduces Σ|Δ| = 33.0.
- **Beam-raced palette skew: QUANTIFIED, LOCALISED AND FIXED (2026-07-26).**
  Demos like Babylona (`~/projects/other/bk/Babylona/`) paint
  one unrolled block per scanline with no resync, so the block cost IS the
  vertical scale of the effect. **The real block is 256.1 CPU cycles = exactly
  one scanline; ocbk ran it in 240 — 6.25 % fast, ~32 dots/line. That was the
  slant.** The tone-program family in `test/` (`sndtest662`, `sndtestbaby`,
  `sndtestimm`, `sndtestimm2` — `.mac` is the source of truth, `.bin` tracked,
  `.wav` regenerable by pdpy11; same technique as `sndtestsmk`) measured it
  against a real BK-0011M. **This is the A–D baseline table `sim/grantfit`
  cites** — four numbers derived independently before that bench existed, which
  is what validates it (its legs E/F/G are `sim/smktime/golden_std`, `qbus_pkg`'s
  ideal 3326 and `test/sndtestimm2.mac`'s 3927):

  | | program | real | ocbk (pre-fix) | per unit |
  |---|---|---|---|---|
  | A | 192 × write 0177662 | 297 Hz = 6734 cyc | 6734 | **match** |
  | B | 192 × write to RAM | 286 Hz = 6993 | 6734 | −1.35 cyc/write |
  | C | 24 × Babylona block | 322 Hz = 6211 | 5824 | **−16.1 cyc/block** |
  | D | 192 × `MOV #imm,Rn` | 302 Hz = 6622 | 5648 | **−5.08 cyc/instr** |

  **Every leg that MATCHES contains only ONE-read
  instructions; every leg that DIVERGES does TWO reads back to back**
  (`MOV #imm,Rn` = −5.08 cyc/instr). That is why every earlier calibration
  missed it — `N_EXT` included, they all used 192 × `SOB`.
  **The CPU core and `N_EXT` are RIGHT:** `test/sndtestimm2.mac` runs the same
  loop from SMK RAM (`MK_EXT` — not 037-fronted, no arbitration, no slot
  quantisation) — real 509 Hz = 3929 cyc vs our ideal 3927 (the sim's 4055
  carries the `EXTRD slow` tb-saturation inflation), **0.05 %**.
  **So the whole error is in the 037-fronted DRAM path and is
  PATTERN-DEPENDENT:** per DRAM access the real machine costs 4.37 cycles more
  than SMK RAM when accesses are ~3.85 slots apart, but **6.60** when they come
  in back-to-back pairs; ours is flat at ~4.2 either way.
  **DO NOT re-investigate these — all ruled out by measurement:** `N_VREG`
  (above); the clock tree (the real CLKIN:CPU ratio is 1.5, exactly ours); the
  ВЕ-timer prescaler (hardware-rejected, see the `vm1_tve` note); the **/24
  CPU-clock phase and the 1/3 duty cycle** (12 combinations, all flat at
  26.455/26.457); the board's **D8:B RPLY re-timing flop** (+0.32 cyc only);
  and our 037 retime itself — the **reference netlist** at the exact BK-0011M
  ratio gives 26.46/20.51 against `va_037_sync`'s 26.43/20.52, i.e. *our*
  numbers, not the real machine's, with no SDRAM in the loop.
  **MiSTer cannot arbitrate this — it IS the same design:** same cpu11 vm1
  core, same divider ratios/phases (`ce_6mp/n` = clk_sys/16, `cpu_div` 24/32
  half at 12), and a gate-for-gate identical VP1-037 contention block (RASEL
  set at PC==4 / clear at PC==7, `ack = TRPLY & ~RASEL`, legacy RAM acked only
  by the 037, no fixed `N_RAM`). Its only relevant differences make it
  *faster*, not slower (no `mem_ready` done-gate; combinational ROM/extension
  ack — so it is **not** a ROM timing reference). Untested prediction:
  Babylona should slant on MiSTer too.
  **FIXED — CONFIRMED ON HARDWARE 2026-07-26: the Babylona colour smearing is
  GONE and PALTST's colour ribbons are FLAT on the board.** That is the
  acceptance test for this whole line of work: both artefacts are beam-raced
  effects whose vertical scale IS the per-scanline block cost, and both were
  the visible face of the −6.25 % block. The parametric
  study found a candidate fitting ALL SEVEN hardware tone legs and **it is now
  shipped RTL**: a **request setup window of 2 half-CLKIN phases at the PC==4
  grant decision** (`va_037_sync`'s `GRANT_SETUP` parameter) **+ the board's
  D8:B RPLY re-timing flop on the 037's reply** (`src/bus/bk_rply.sv`). Every
  residual lands inside ±1 Hz of tone-reading error (Σ|Δ| = 33 cycles over
  seven legs); per instruction it adds **exactly one grant slot to the second
  read of a back-to-back pair** and nothing to a fetch 2.5 slots later.
  Neither ingredient works alone. `sim/grantfit/run.sh` is the regression
  (bench + README); `--setup 0 --nod8b` reproduces every pre-fix number
  exactly, so the change is cleanly reversible.
  **The write leg (192 × write to RAM) is what makes it unique** — three
  candidates are identical on every read leg and differ only there, which is
  how the earlier rounds picked wrong; it also proves one direction-blind rule
  produces BOTH the +5.08 read-pair and +1.35 read-write costs (the write's
  slot is absorbed by the vm1's DATO window, per `sim/vregtime`'s N_VREG
  ladder). **Inert / rejected:** TRPLY-clear quantisation (completely inert);
  minimum-gap 2 (inert, as recorded); minimum-gap 3 IS rejected but by the
  write leg (+11 %), **not** by wrecking `SOB` (+0.13 %) as the pre-bench
  record claimed — that scratch RTL is gone, so treat the "wrecks SOB" claim as
  unconfirmed. The conclusion it supported (the rule is wrong) survives either
  way.
  ⚠️ It moves the /32 bk10 path too — **+0.20 % on `SOB` but +15.0 % on
  `MOV #imm`, and NOTHING measures that** (no BK-0010 tone; `sim/bk10`'s golden
  is the core alone, no 037). **Falsifiable prediction: a real BK-0010 running
  `test/sndtestimm.bin` should now match us and be ~15 % slower than the
  pre-2026-07-26 firmware.** Collect that recording if a BK-0010 is ever
  available — it is the one leg of this calibration with no measurement behind
  it. **Oracle consequence: `sim/ref037` now keeps TWO golden sets** — see its
  bullet above and `sim/ref037/run.sh`'s header.
  (Experiment note: an `inh`/`gnt_inh` register added to a scratch copy of
  `va_037_sync` MUST be reset — without it RASEL goes X and the sim hangs.)
- **EVNT/IRQ2 frame interrupt (Phase 9 rework, BK-0011M):** the 50 Hz system
  timer. **The 037 has NO vertical-blanking output pin** — the real board
  synthesises IRQ2 externally, and `src/peripheral/bk_evnt.sv` is a gate-faithful replica
  of that detector (**schematic-traced pin-by-pin in `doc/bk0011m.sch`; see
  `sim/evnt/README.md` for the full trace and contract**): **D28** (К555ИЕ5,
  ÷2 section) with `CKA = ~(SYNCO | QA)` (D6:C, QA fed back) and its async
  clear `R0(1)&R0(2) = CLC & WTI`, feeding **D3:B** (К555ТМ2) clocked by
  **SYNCO** (037 pin 28) with `R` = the 662 enable bit (D35.5 = `~reg662[14]`,
  ACLO-reset), `~Q` → D21 (ЛП9, OC) → the **~PRT** net → D11.4 (К555ТМ9 on
  CLC) → the CPU's IRQ2 pin. WTI pulses once per fetched video word and is
  silent on non-displayed lines, so it pins QA at 0 through the displayed
  area; when WTI stops the next SYNCO edge sets QA (**set-once** — the
  feedback then holds CKA low) and D3:B publishes it one SYNCO edge later.
  **Measured against the reference netlist: assert = VGATE rise + 452 CLKIN,
  deassert = VGATE fall + 452 CLKIN** (~75 µs, ~1.18 scanlines, ~301 cpu_clk
  at the /24 rate), stable every frame. **This REPLACED the Phase-7
  "nIRQ2 = vgate" model, which was MiSTer's (`rtl/video.sv`: set at
  `vc==256`, cleared at `vc==0`) and fired 452 CLKIN too early every frame** —
  a fixed displacement of every beam-raced multicolor/gigascreen effect, which
  is what motivated the rework. Three load-bearing properties, each
  mutation-covered: (1) **the propagation race** — the QA toggle and the D3:B
  clock are the SAME SYNCO edge, and the board's delay makes D3:B capture the
  **old** QA (reproduced by non-blocking assignment ordering; sampling the new
  value loses a whole scanline); (2) **`irq_en` is an async CLEAR, not a
  combinational gate** — so un-masking mid-blanking does **not** retro-fire
  instantly (both our old model and MiSTer do), it waits for the next SYNCO
  edge; (3) **QA is set-once**. In **1/4-screen mode** (177664 bit 9 clear)
  WTI stops after the 64th displayed line, so the request authentically
  asserts **during active video**, ~129 lines before blanking — the old vgate
  model could not express this at all, and `mem/gen_bk11_test.py` §12 now
  writes 177664 = 0o001330 (full screen, as real BOS does) for that reason.
  bk_evnt is all sys_clk (the 037 outputs move on the /16 en_pos/en_neg
  strobes, so edge detection is exact — no CDC), **power-on reset only**
  (`vid_rst_n`; on the board D28 has no reset pin and D3:B's only reset is the
  662 enable bit), then 2-FF onto **posedge cpu_clk** in `ocbk_top` — the
  pin-sync rule, and authentic (D11 does the same on CLC). The vm1's internal
  arm/fire edge detector (arm while deasserted, fire on assert) makes it
  exactly one vector-0100 interrupt per frame; the DCLO default mask=1 keeps
  it silent until software unmasks. **BK-0010 has no IRQ2 source at all**
  (BkEmu attaches `SystemTimer` only for 0011M; MiSTer gates
  `irq_en = ~bk0010 & ...`) — `model_bk11` holds the whole detector cleared,
  never wire one in bk10 mode. Oracles: **`sim/evnt/run.sh`** (the authority —
  reference-netlist golden + the retimed va_037_sync reproducing it
  byte-identically, mutation-tested ×5) plus the `sim/bk11` section-12 leg,
  whose tb guard pins the no-retro-fire-on-unmask semantic (teeth-tested: the
  old wiring fails it at 34 sys_clk). The three SoC tbs (`sim/bk11`,
  `sim/smk`, `sim/boot_check_tb.v`) **instantiate `bk_evnt` rather than
  replicating it** — the `cpu_clkgen` replica-drift lesson.
- **SDRAM arbiter ports** (fixed priority, 0 highest): 0=CPU, 1=panel readout,
  2=037 video fetch, 3=FB write. There is **no fairness** — the readout MUST stay
  paced (`fb_readout` PACE ≥24 sys_clk/word); an unpaced port-1 burst starves
  ports 2/3 for a whole line. Client contract: hold req+fields until the 1-cycle
  gnt, then drop req for ≥1 cycle (`served` mask).

## Gotchas (learned the hard way)

- **Quartus II 11.0 SystemVerilog is limited.** No `import pkg::*;` in a module
  header (put it in the body). It won't propagate `` `define `` across separately
  listed Verilog files, so the core's config selectors are set as global
  `VERILOG_MACRO` in `ocbk_common.qsf` (mirroring `src/cpu/vm1_config.v`, which the
  sim flow includes directly; the macros are `ifndef`-guarded to stay idempotent).
- **A wildcard-imported package parameter must never make its FIRST appearance
  inside a port-connection expression** (Icarus, cost half an hour in Phase 9).
  Written as `.fast_rd((N_EXT == 1) & sel_ext & ...)`, Icarus does not resolve
  `N_EXT` there — port connections are where implicit nets get created, so it
  silently declares a 1-bit **net** of that name, which then **shadows the
  parameter as X for the whole rest of the module**. Everything downstream
  (`(N_EXT == 1)`, `3'(N_EXT-2)`) evaluates to X, with no warning: the symptom
  was a wait FSM whose `wcnt` was X and which therefore never replied. Assign
  the expression to a named `wire` first and connect that. The same import also
  refuses a module-level `localparam` derived from a package parameter ("a
  reference to a net or variable ... is not allowed in a constant expression")
  — spell such expressions inline where they are used.
- **`vm1_simlib.v` is sim-only** (dual-write-port behavioural RAM → "multiple
  constant drivers" in Quartus). The FF register-file path
  (`CONFIG_VM1_CORE_REG_USES_RAM=0`) leaves that RAM unused, so the Quartus build
  uses the tied-off stub `src/cpu/vm1_vcram_syn.v` instead.
- **Open-collector RPLY combinational loop** — Quartus flags a benign 4–6-node
  loop where the CPU's internal-register reply and the slave wire-AND onto RPLY.
  Cosim-validated; clean fix (explicit wired-AND via `vm1_qbus`'s split
  `rply_in`/`rply_out`) deferred to peripheral work (Phase 6).
- **Mapper-to-bus-pad false timing loops** (Phase 8, learned the hard way):
  any COMBINATIONAL path from the mem_mapper translate (`kind`) into an `ad_n`
  output enable closes a loop through the on-chip wired-bus resolution network
  back into the mapper's own register-write snoops (`ad_true` data/enable
  pins). Functionally false — DIN and DOUT are mutually exclusive — but STA
  must see it met, and it broke sys_clk closure at −1.322 ns when the SMK512
  mode decode landed in that cone. **No SDC exception** (the SEED-3 rule: an
  exception is a fitter input); fixed structurally instead: the SMK mode
  table is pre-decoded at COMMIT time into `seg_*` registers (decode-at-commit
  ≡ decode-at-use — the regs change on the same sclk edge), and
  `cpu_sdram_dp.rdata_oe` gates on an issue-time `was_read` flag instead of
  the live `sel_ram||sel_romr` (behaviour-identical: the selects are
  SYNC-framed and stable by D_DONE; ref037's goldens pin the cycle identity).
  Rule: keep translate outputs out of pad-OE cones — register the selection
  at issue, never re-check it live at the drive point. **Phase 9 had to take
  that one level further** (2026-07-25): the loop came back as the worst
  sys_clk path (−0.023 ns) once the `N_EXT` work re-placed the fitter, so
  `rdata_oe` no longer decodes the FSM state either — the whole
  `(state == D_DONE && was_read && was_drive)` term is precomputed into the
  `oe_arm` flop at the transitions into/out of D_DONE (identical by
  construction: D_DONE is entered from D_RD_WAIT with was_read=1, from
  D_WR_REQ with was_read=0, and left only to D_IDLE), leaving
  `rdata_oe = oe_arm && !din_n`. Same rule, one level shorter.
- **A quasi-static signal with big fanout still costs real setup time**
  (Phase 8, fixed 2026-07-22). `model_bk11` (DIP 1, latched during a DCLO
  hold, frozen while the CPU runs) fans out across the mapper, clkgen,
  qbus_mem and the top-level video muxes, so the fitter routes it far;
  landing that route in the `bank_wr` AND tree that feeds `win0_page`'s
  next-state LUT made it the design's worst sys_clk path for three builds
  (+0.077 → −0.039 → −0.230). "It's pseudo-static so the violation is
  false" is TRUE but not a fix — it just re-litigates the same STA
  judgement call on every increment, drifting further negative as the
  design grows. **Cure: re-register the signal locally in the consuming
  module** (one flop; the long route becomes a plain flop-to-flop path and
  the logic downstream is fed from a flop the fitter places nearby). This
  is the same structural-not-SDC philosophy as the `wait_cnt` narrowing and
  the sdram_ctrl counter split — **never reach for an SDC exception**, which
  is a fitter input and has broken the SEED-3 boot before. Safe only where
  a 1-cycle latency provably cannot matter: verify the signal changes only
  while the consumer is in reset / the CPU is parked, and keep the raw
  signal on any cone whose oracle compares combinationally after a flip.
- **A SINGLE-driver open-collector `tri1` net degenerates to stuck-ASSERTED in
  Quartus** (Cyclone I has no internal tri-state/pull-up). This bit the Phase-6
  keyboard on hardware: `bk_kbd014` was the *only* nVIRQ source, driving
  `virq_ff ? 1'b0 : 1'bZ` onto a `tri1` net. Quartus "Converted tri-state buffer
  ... `virq_n` feeding internal logic into a wire" and tied the idle Z to **0**
  (permanently asserted — `virq_ff` then "lost all its fanouts"), so the CPU saw
  a stuck VIRQ and hung the instant MONITOR unmasked (deterministic, no keypress;
  `pin_virq_n=1'b1` or masking cured it). **Every sim passes** — sim honours the
  `tri1` pull-up. Fix: a lone OC source must be **push-pull** (`assign virq_n =
  ~virq_ff;`, net a plain `wire`). The multi-driver bus nets (`ad_n`, `rply_n`)
  are fine — Quartus infers the wired-AND from the several Z-idle drivers (an
  OR-gate in the reports). **Rule: never leave a single Z-idle tri-state driving
  internal logic; if a second nVIRQ source is added (cartridge slot), OR the
  active-high asserts and invert at the top — do NOT go back to tri-state Z.**
  Guard: `grep 'Converted tri-state buffer' ocbk.map.rpt` should list only the
  genuinely multi-driven bus nets, never a peripheral's lone request line.
- **Pin-sync edges (1801ВМ1 doc): nIRQ1–3/nVIRQ must be asserted synchronous
  to the CPU clock rising edge, nRPLY to the falling edge.** The core samples
  all of them at `posedge pin_clk_p` with **no synchronizer flops**
  (`vm1_qbus.v` `rply_ack[1]`, `rq[]`, `irq2`/`irq3` edge detectors). RPLY
  already complies: `qbus_mem`'s wait FSM runs on `cpu_clk_n`
  (falling-edge launch); `va_037_sync` transitions land 1–2 sys_clk after a
  CPU edge (~300 ns setup, deterministic — same divider chain). Any Phase-6+
  interrupt source must put its final flop on `posedge cpu_clk` (2-FF resync
  first if it originates in `sys_clk`/`pix_clk`, e.g. EVNT from vsync) — an
  async assertion is a metastability *and* cycle-determinism hazard. Note the
  SDC false-paths all `sys_clk`↔`cpu_clk` paths, so these margins are safe by
  construction, not STA-checked — re-check at Phase-7 turbo rates.
  **Hardware confirmation** (`doc/bk0011m-sch.pdf`, sheet 1): the real board
  implements both rules as external chips on the CLC (CPU clock) net — D8:B
  (К531ТВ9 negedge JK, J=K̄ via D33:E = a pure D-FF) reclocks the wired-OR bus
  nRPLY onto the CPU's RPLY pin (Q̄→R28→pin 39; the CPU never sees raw bus
  RPLY, only its own internal self-reply bypasses it), and D11 (К555ТМ9 hex
  posedge D) re-times IRQ1–3/VIRQ *plus ACLO and DMR*.
  **D8:B IS NOW MODELLED — `src/bus/bk_rply.sv`, Phase 9 (2026-07-26)**, and it is
  half of the 037 grant-rule fit (see the beam-race bullet). The long-deferred
  worry that it "shifts ROM/IO by a full cycle and N_ROM would need
  recalibration" is resolved by scoping: it re-times **only the 037's reply**,
  because `qbus_mem`'s FSM already runs on `cpu_clk_n` and is therefore
  D8:B-correct by construction — every fixed-`N` slave already launches on the
  falling edge, and re-timing them again would double-count precisely the
  constants calibrated against hardware WITH this flop's contribution inside
  them (`N_EXT`, `N_VREG`, `N_KBD` = 1). So `N_ROM` did not move and no
  fixed-`N` constant needed recalibration. The 037 was the one path where the
  rule held only by accident of the divider phase — and at the /24 rate, not
  at all.
- **177700–177713 is CPU-internal** (with `pin_pa=00`): `vm1_qbus` decodes the
  block itself (`sel177x`), self-replies for all of 177700–177717 AND drives read
  data for 177700–177712 (CSR/error/`vm1_tve` timer). Nothing external may reply
  or drive there — the pre-Phase-5 `sel_io` did, a guaranteed `ad_n` fight the
  moment MONITOR touches the internal timer (no synthetic oracle program ever
  read those addresses, so only the real-ROM smoke cosim would catch it).
  177714/177716 stay externally served (the CPU's `ad_oe` excludes them). I/O
  stub semantics (177716 bit-2 write-flag, 177660 cold `0o100`) follow **BkEmu**
  (`~/projects/studio/BkEmu`) — the canonical BK behaviour reference.
- The `qbus_sdram` address latch is **transparent on the SYNC strobe** (as real bus
  hardware), so SYNC is a slow logic-derived clock; `ocbk_constrains.sdc` declares
  and cuts it. SDC node names use Quartus `entity:inst|...` form — verify with a
  `quartus_sta -t` script (`get_registers` / `get_pins`) before trusting a pattern.
- **WTBT is dual-purpose** on the Q-bus: at SYNC time it flags a *write* cycle, at
  DOUT time it flags a *byte* op. `qbus_sdram` samples the byte indicator live at
  the write point — do **not** reuse the SYNC-latched value for byte masking (that
  corrupts word writes; the cycle-count oracles never check write data, so it slips
  through sim silently — only the SDRAM cosim verifies values).
- **DATIO(B) read-modify-write cycles run DIN then DOUT under ONE SYNC** (INC/BIS/
  XOR/... on memory). A bus slave FSM must return to idle on *strobes-idle*, never
  on SYNC-rise — waiting for SYNC sits through the DOUT phase and silently drops
  the write (found on hardware: the test picture's XOR diagonal vanished while MOV
  bars worked; `cpu_sdram_dp` had exactly this bug). The oracle test programs
  originally contained *no* memory-RMW instruction, so nothing in sim caught it —
  the ref037 program + `golden_037.txt` and the gen_mem RAM test now include an
  RMW block with a value self-check (a wrong result parks at a distinct fail PC,
  which breaks the golden diff). Keep RMW coverage in any future bus-path oracle.
- **CDC for SDRAM — the "no interlock" worry is CLOSED; this bullet described
  the retired `qbus_sdram`, not the shipped path.** It used to say the wait FSM
  launched an access through a request-*toggle* into the `sys_clk` adapter and
  that a margin violation would latch stale data rather than extend RPLY, so
  the 4/6 MHz rates needed re-validating or a done-gate. Both halves are now
  wrong. **There is no such toggle** in the shipped design: `qbus_sdram` is out
  of the build (not in `ocbk_common.qsf`), and `qbus_mem`/`cpu_sdram_dp` share
  `sclk` with the strobes — `cpu_clk` is a *divider* of `sys_clk`, same tree,
  deterministic phase, not an asynchronous domain. **And the done-gate exists**
  on every leg: `mem_ready` gates the 037's RPLY for MK_RAM037
  (`va_037_sync`'s `PIN_nRPLY`) and `qbus_mem`'s own reply point for ROM,
  MK_EXT and turbo RAM. A late word therefore EXTENDS the cycle; it can never
  be latched stale. What actually changes as the clock rises is only how OFTEN
  the gate fires — which is why turbo routes its (expected) holds to
  `dbg_turbowait` and keeps `dbg_romgate` as the alarm. Turbo mode is the
  re-validation that bullet asked for, and the answer was that only `N_EXT` = 1
  needed retiring at /16 (see the turbo bullet). Note the old "~1.6x at 6 MHz"
  figure was pessimistic anyway: it used `(N-2)` CPU clocks and ignored the
  DIN→detection half-period; the real window is `7 + 16(N-1)` sys_clk.
  `ocbk_constrains.sdc` false-paths both directions
  of the `cpu_clk`↔`sys_clk` crossing. Reset is gated on SDRAM `init_done` (CPU held
  in reset until the controller's ~200 µs init completes).
- **sys_clk↔pix_clk are same-VCO *related* clocks** (96.65/64.43, 3:2): without
  the SDC `set_false_path` pair TimeQuest times the ~5.17 ns transfer and fails
  closure spuriously. All real crossings are a toggle+2-FF handshake (line
  request; payload stable ~21 µs around the toggle), the ping-pong `fb_linebuf`
  (a bank is never written while displayed — the triple-ahead scheduling
  guarantees it), or 2-FF-synced quasi-statics (`fb_front_valid`, `screen_mode`).
- **`fb_linebuf` must stay the plainest dual-clock RAM** (one write-always, one
  registered-read-always, same width both ports) — that's what Quartus 11 infers
  a single M4K from and Icarus simulates; mixed widths or dcfifo break one or the
  other. Check the fit report stays at exactly 1 M4K / 4096 bits.
- `mem/ram_test.hex` is **generated** by `mem/gen_mem.py` (the single source of
  truth for the ROM program — a small label-resolving PDP-11 assembler — AND the
  test picture via `render_image()`, imported by `sim/video/gen_expected.py`;
  word 0 = BK address 100000) and is gitignored — `make` regenerates it. The
  success/failure park loops are pinned at **100004/100012** (hardcoded in
  `ocbk_top.sv` and `qbus_sdram_tb.sv`) — they must never move; new code goes
  after the `start` label. After changing the draw code or picture, run
  `sim/video/run_draw_check.sh`.
- `mem/boot_blob{,11}.{bin,hex}` + `boot_blob{,11}_flash.hex` are **generated**
  by `mem/gen_boot_blob.py` from the committed `mem/roms/*.rom` (gitignored,
  `make` regenerates). **Two blobs** (Phase 7): the bk10 set at EPCS flash
  0x40000 and the bk11 set (`basic11m_0`/`basic11m_1`+`ext11m`/zero-filled
  empty banks/`bos11m`/`mstd11m`+**`smk512_v205` — the Phase-8 SMK BIOS,
  43008 words total, → SDRAM 0x3A000**; layout in the script header) at
  0x48000 — both appended to the POF as `ocbk.cof` `hex_block` pages
  (`quartus_cpf` accepts multiple blocks; the map file lists both). The
  script asserts the load-bearing SMK boot word (`bios[0o7716]` = 0o166400). **EPCS bit-order
  (hardware-verified, subtle):** the COF Intel HEX carries **true bytes**.
  `quartus_cpf` bit-reverses `hex_block` bytes into the POF/RPD — but the RPD
  is in **RBF/LSB-first bit order, not physical-flash order** (its Page_0
  equals the `.rbf` verbatim) — and `quartus_pgm -m AS` reverses **again**
  onto the chip, so the two cancel and an MSB-first SPI READ returns the HEX
  bytes verbatim. Do NOT pre-reverse (that was tried; on the board the loader
  read rev(blob) and fell back). `make blob-check` verifies the RPD pages =
  rev(blob) at BOTH 0x40000 and 0x48000.

## Open / deferred

Nothing here blocks anything; each item has its detail in the bullet named.
Roughly in order of how much they'd be missed.

**Phase 10 completion checklist (the phase stays 🚧 until all of it is done)**

Ordered, because the steps constrain each other. The rule this encodes:
**a debug feature does not ship to end users**, and — since the repo went public
2026-07-31 — `main` only takes a feature when it is shippable.

1. **(3) silence ✅ DONE 2026-07-31 — (4) CMT is the ONE recording still
   outstanding**, and it is the one that matters most: a regression check on an
   ALREADY-SHIPPED feature, since Phase 10 changed what the left ladder does in
   CMT mode (it now carries the L+R mono fold where it used to sit at a
   quasi-static level). It works on the CURRENT firmware.
2. ✅ **Sweep, acceptance item (2) — DONE 2026-07-31** on the
   `bringup-audio-sweep` build (that branch exists because DIP 5 plays a FIXED
   440 Hz, so the sweep needed its own firmware). **In-band answered: flat
   100 Hz → 21 kHz, no RC corner, `RATE_DIV` stays 16**; the voice-A harmonic
   anomaly is resolved as ladder mid-scale DNL. See the analog-stage bullet.
   **Still open from it:** the capture's own anti-alias filter brick-walls at
   ~21 kHz, so the board ABOVE the audio band remains unmeasured and needs a
   scope on the jack rather than another recording. That is not a Phase-10
   blocker — the out-of-band bound stands — so it moves to the analog-stage
   bullet rather than holding this checklist.
3. **Retire the tone from the shipped build: set `TONE_ENABLE = 0`** on the
   `bk_audio` instance in `ocbk_top`. **Do NOT delete `audio_tone.sv`.** The
   parameter already gates the whole generator in a generate block
   (`bk_audio.sv:60`), tying `dbg_tone`/`tone_live` to 0 — so this removes the
   user-visible behaviour, frees DIP 5, and reclaims ~130 LE while keeping the
   module, its oracle leg and the ability to rebuild a diagnostic firmware.
   That ability is load-bearing and permanent: **the BK speaker maps to the
   rails and emits a STATIC code with no shaping activity**, so the tone is the
   only stimulus that can exercise this feature on hardware at all — there is
   nothing else to test with when the first 177714 device lands, or after a
   fitter re-place moves timing. Deleting the module buys nothing and is the
   irreversible version.
   **Keep `pLed[1]`/`[2]`** (the sticky mixer-saturated / quantizer-clipped
   flags): they are NOT debug — README documents them as user-facing, and the
   gain budget is genuinely unsolved until a sound device lands. Retire only
   `pLed[3]`, which goes with DIP 5.
4. **Update the user-facing docs in the same commit**: README's "Audio
   self-test" section and its DIP-5 table row both describe the tone as a
   feature.
5. **Rebuild, re-run STA, and boot-test.** Mandatory, not a formality: removing
   ~130 LE re-places the fitter, and this design is placement-fragile (the
   shipped bitstream's sys_clk margin is +0.034 ns — see the audio cost/timing
   bullet). Slack can move either way.
6. **Then merge the branch to `main`** and flip the phase table row to ✅.

**Fidelity, measurable**
- **The Phase-10 >6-bit audio resolution claim is CONFIRMED ON HARDWARE
  2026-07-31 — recipe item (1) of four is done; (2), (3), (4) are still open.**
  The staircase was recorded off the Sound-L/R jacks and measured **−6.047
  dB/step** (ideal −6.021) over 42 dB, max residual **0.19 dB**, with the three
  sub-ladder-step levels (½, ¼, ⅛ of one ladder step) on the same straight line
  as the full-scale ones and 49–58 dB above the noise floor — which a 6-bit
  truncating path renders as silence or a 1-bit square. Full table, method and
  caveats in `sim/audio/README.md`; the recording itself is not committed (4 MB),
  so that table is the record. Two by-products: the recording ran hot, so **step
  0 alone** sits +0.33 dB off the line (peak −0.47 dBFS, and the only step whose
  own 3rd harmonic departs from ideal) — re-record 6 dB lower; and the frequency
  cross-check caught the **`STEP_B` transposition** (69658 → 69637, voice B was
  0.52 cents sharp), fixed in `audio_tone.sv`, which the recording predates.
  Items (2) and (3) are now DONE — see the analog-stage bullet for (2) and the
  no-dither bullet for (3). **Only (4), the CMT re-check through the right
  jack, is still outstanding.** Keep any recording in `test/` per the existing
  `.wav` convention (the three takes so far were not kept — the numbers they
  produced, recorded here and in `sim/audio/README.md`, are the record).
- **The board's analog stage: the AUDIO BAND is now measured, above it is not.**
  The 2026-07-31 sweep (`bringup-audio-sweep`, 192 kHz capture, four cycles,
  `sim/audio/sweep_analyze.py`) gives **0.00 dB response from 100 Hz to 21 kHz**
  on both channels, ±0.9 dB at the very top. **So there is no RC corner in the
  audio band and no rolloff argument for moving `RATE_DIV` off 16.** The
  reference step landed at −13.56 dBFS against the staircase take's −13.57 for
  the same tone — two independent recordings agreeing to 0.01 dB, which is what
  makes the rest of the numbers trustworthy.
  **Out of band is still a BOUND, not a measurement**, and that sweep could not
  fix it: the capture brick-walls at ~21 kHz (full level at 21.0 kHz, −128 dB by
  26.3 kHz — far too steep for a passive RC, so it is the interface's
  anti-alias filter, not the board). Measuring the board above 21 kHz needs a
  SCOPE ON THE JACK, not a sound card. The standing bound is that the shaped
  code never deviates from the plain-truncated code by more than ±1 LSB6, which
  is strictly milder HF content than the 63-code full-swing pad edges this board
  already survives on every BK beep.
  **The voice-A excess-3rd-harmonic anomaly is RESOLVED: it is the R-2R
  ladder's mid-scale (major-carry) DNL, on the BOARD.** The sweep shows the
  distortion is **frequency-INDEPENDENT** — a flat −10.6 dB 3rd and −28.2 dB
  2nd at every step from 100 Hz to 7 kHz — which kills the frequency-selective
  reading the two-tone staircase suggested. Phase-folding a dwell (68 periods
  averaged) shows the mechanism directly: a clean triangle carrying a
  repeatable disturbance **localised at the ZERO CROSSINGS**, 12.8 % rms
  against an ideal triangle. Mixer zero is ladder code 32, where all six bits
  change at once, and `audio_ns6`'s exact zero fixed point parks the output
  right there. Phase-locked to the crossing ⇒ energy on odd harmonics of
  whatever tone plays. **The discriminator against a capture-chain cause is
  that L and R differ consistently** (3rd −10.59 vs −11.17 at EVERY frequency):
  one shared nonlinearity in the interface would read identical in both
  channels, two physically separate resistor networks do not. It is also
  definitively not digital — a bit-exact transcription of `audio_ns6` fed the
  real DDS triangles reproduces the ideal series to 0.00 dB (3rd −19.08, 5th
  −27.96, 7th −33.80, evens >100 dB down, fundamental gain 0.000) at 440 Hz, at
  1567 Hz and at amplitude 128.
  This also explains the staircase reading that looked contradictory: voice A's
  glitch energy lands on harmonics of 440 Hz, while voice B's 3rd harmonic was
  measured at 3×1567 Hz where none of it falls — hence voice A read +8.5 dB
  excess and voice B read textbook-ideal **in the same channel of the same
  recording**.
  **It does not touch the resolution claim**, which is a ratio at ONE frequency
  taken from voice B's FUNDAMENTAL amplitude: a static mid-scale code error is
  a distortion mechanism, not a gain error, and the staircase slope held to
  0.19 dB max residual across 42 dB.
  **VIDEO CROSSTALK INTO THE ANALOG STAGE — a board-level coupling, not an
  audio-path defect (found 2026-07-31 while recording item 3).** Pressing СТОП
  made an audible noise appear until the next keypress. It is a **phase-locked
  line at 15730.04 Hz = EXACTLY the BK horizontal line rate**
  (96.65 MHz/16/384 = 15730.4; the real machine's 15625 +0.674 %), and what
  changes is only its AMPLITUDE — 30 dB, −105.7 → −75.4 dBFS — while its
  frequency and its resolution-limited 0.37 Hz linewidth are IDENTICAL in both
  states. So it is not the arbiter: a halted CPU letting the video fetch fall
  into a regular phase would have SHARPENED the line, and it was already
  maximally sharp. A line-rate-locked carrier whose amplitude swings with
  machine state is the video subsystem coupling through shared supply/ground,
  modulated by how much the video DATA toggles — i.e. **by what is on the
  screen** (СТОП is the trap-4 path here, so it lands in the monitor and
  displays something; the keypress cleared it). The audio path is a bystander:
  the disturbance is perfectly COMMON-MODE (L/R correlation 0.9990, L−R pinned
  at the idle noise floor, −86.7 dBFS), whereas anything driven THROUGH the
  mixer makes L and R differ — that asymmetry is what localised the ladder DNL
  above. Nothing in the RTL can fix this, and at −60 dBFS it is only audible in
  an otherwise silent room. **Unexplained:** the tail decays smoothly to the
  floor over ~2 s after the keypress, where a screen-content change should be a
  step. **Cheap test if it ever matters:** put content on the screen WITHOUT
  touching СТОП (should be noisy) and press СТОП with an already-blank screen
  (should stay quiet) — if both hold it is screen content, full stop.
  Useful by-product: that line has **no harmonics at all** (2× at 31.5 kHz
  reads −130 dBFS, the noise floor), which independently confirms the ~21 kHz
  brick wall is in the CAPTURE — a coupling artifact that sharp must have
  harmonics, so their absence is the filter, not the board.
- **The BK-0010 `/32` prediction is unmeasured.** The 037 grant-rule fit moves
  the bk10 path +0.20 % on `SOB` but **+15.0 % on `MOV #imm`**, and nothing in
  the tree measures it — there is no BK-0010 tone recording, and
  `sim/bk10/golden.txt` is the core alone with no 037. Falsifiable: a real
  BK-0010 running `test/sndtestimm.bin` should now match us and be ~15 % slower
  than the pre-2026-07-26 firmware. **Collect that recording if a BK-0010 is
  ever available** — it is the one leg of the calibration with no measurement
  behind it. See the beam-race bullet.
- **`N_SMKREG` and `N_IDE` are still `N_ROM`-family placeholders.**
  `sim/smktime`'s recipe (a tone whose frequency reads out one memory's access
  time, with an already-calibrated control leg) is the method that settled
  `N_EXT`; these two want the same treatment against a real SMK512.
- **The SMK-RAM power-on `ram_init` pattern.** `src/sdram/ram_init.sv` fills the
  machine's own RAM with the authentic К565РУ6/РУ5 pattern; the SMK512's
  512 KB segment is left zero-filled.

**Peripherals / features not built**
- **The 177714 sound devices — Covox, 2× YM2149 (AY) and Menestrel — are NOT
  built; Phase 10 built the seams they plug into.** All three decode the SAME
  address (BkEmu `REG_SEL2` = 0177714) and differ only in how they read the
  data, so `qbus_mem`'s `port_wr`/`port_data`/`port_word`/`port_be` capture and
  the mixer's slots 3–9 are shared and already exist and are oracle-pinned.
  Planned arbitration (settled): the **AY is always live**; Covox and Menestrel
  are cycled by a PS/2 radial-toggle key (the `key_scrmode`/`key_turbo`
  pattern), landing with the first device. Planned AY core: MiSTer
  `BK0011M_MiSTer/rtl/ym2149.sv`. Devices belong in `src/peripheral/`
  (`bk_covox.sv`, `bk_ay.sv`, `bk_menestrel.sv`) — `src/audio/` is
  mix-and-output infrastructure only. **The first device increment must also
  re-open the gain budget**: the speaker is a full-scale source, so it uses the
  entire headroom by itself and anything sounding alongside it saturates —
  MiSTer's answer is to drop the speaker to 1/4 when its PSG is active
  (`BK0011M.sv`: `spk_out<<7` alone vs `<<5` with the PSG). Phase 10 sidesteps
  this only because the self-test tone mutes the speaker.
- **The 177714 READ merge is not implemented.** The Phase-10 seam captures
  WRITES only, deliberately: a write capture is provably reply-inert (177714
  already replies via `sel_io`), while a read merge reaches into the reply/OE
  cone that this change carefully avoids. Covox is write-only and nothing yet
  establishes that an AY read is needed; if one ever is, follow the
  `ide_rdata` pattern exactly.
- **Tape-out is single-bit.** A real BK mixes write bits 6+5 resistively into a
  3-level record waveform; bit 6 alone (the dominant component) is shipped. See
  the tape bullet. **Phase 10 deliberately did NOT change this** — tape-out is a
  DATA signal, not a mixer output (see the audio bullet's hard rule).
- **No dither on the noise-shaper error path** (`audio_ns6`). Deliberate: the
  exact-zero fixed point means silence produces zero pin activity, which matters
  because `pDac_SR[5]` doubles as the CMT input pad and makes "silent at
  silence" a sharp binary oracle assertion. The cost is bounded and computed —
  for a DC input with fractional part `p/q` in lowest terms the limit cycle is
  at `Fs/q` with amplitude `O(1/q)` codes, so any **in-band** idle tone is below
  ≈ −85 dBFS while the loud short cycles (Fs/2 = 3.02 MHz, Fs/3) are all ≥ 1 MHz.
  **MEASURED AND CONFIRMED — acceptance item (3), 2026-07-31** (DIP 5 off,
  machine idle, 192 kHz capture): the floor is **−85.8 dBFS rms broadband and
  −97 dBFS over 20–2000 Hz**, DC offset **0.0 LSB**, and there are **NO
  discrete idle tones** — the only lines are ≤ −102 dBFS and sit at system
  rates, not at shaper limit-cycle frequencies. The L/R correlation is just
  0.665 with L−R as loud as either channel, i.e. the residual is the CAPTURE's
  own noise and the board is contributing essentially nothing. That is the
  exact-zero fixed point doing what it claims: both quantizers park at static
  code 32 with no pin activity.
  Insertion point if revisited: `accr = s_in + errp + dither`, RPDF from an
  LFSR; it invalidates exactly one oracle leg (L3, silence), which would have to
  become a bounded-variance check.
- **Keyboard reset chord** — `warm_rst_req` has the OR seam, no chord decodes
  into it.
- **Cartridge slot** (`src/bus/qbus_slot.sv`, `SLOT_ENABLE=0`) drives nothing; the
  pin map is commented in `ocbk_common.qsf`. Real 5V BK Q-bus hardware needs an
  external level shifter — Cyclone I is not 5V-tolerant. If a second nVIRQ
  source ever lands here, OR the active-high asserts and invert at the top —
  never go back to tri-state Z (see the `tri1` gotcha).
- **CRT effects** (scanline dim / gamma) in the upscaler — the `vga_out` colour
  decode is the hook.
- **SD data CRC16 and MMC cards** — `sd_backend` uses the SPI-default CRC
  policy (real CRCs only on CMD0/CMD8) and types SD cards only.

**Bigger, probably not worth it**
- **A native-48.8 Hz analog-RGB output** as a judder-free secondary path. The
  panel cannot take it (see the platform constraints); it would need a
  multisync CRT or an OSSC-class scaler. The current framebuffer reclock makes
  judder mild for BK content.
- **An optional slow MONITOR tape-load cosim oracle** — tape is
  hardware-confirmed and unit-oracled, but nothing simulates a whole load.

## Temp files

Use the session scratchpad for throwaway scripts/sims, never the repo root.
