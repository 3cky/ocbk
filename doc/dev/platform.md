# Overview, platform and system map

What `ocbk` is, the hardware envelope every design decision lives inside, the
settled clock tree, the whole-system shape, the SDRAM word map, the full source
tree and the BK-0011M memory model. Read this before any change that touches
clocking, memory layout, or where a new file belongs.

Per-module design rules live in the sibling files indexed by
[CLAUDE.md](../../CLAUDE.md).

## What this is

`ocbk` runs the Soviet **Elektronika BK-0010 / BK-0011M** (PDP-11-class) as
alternative firmware on the 1chipMSX / OneChipBook board (Altera Cyclone I
**EP1C12Q240C8**, Quartus II 11.0). The headline goal is **cycle-accurate** CPU
behaviour.

**Every phase is done and confirmed on hardware** — see README.md for the
current result. Phase 10 was held open past its hardware confirmation until
its debug feature was retired from the shipped build and all four acceptance
recordings were collected; **that is the standing rule — a debug feature does
not ship, and since the repo went public 2026-07-31, features develop on
branches and `main` only takes what is shippable.** The `doc/dev/` files are now
the authoritative documentation: their per-topic
bullets carry each finding in its most current form, and they, not this
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
| **10** Audio subsystem | `src/audio/`: N-slot stereo **mixer** + a noise-shaped 6-bit output stage (>6-bit audio-band resolution on the same ladders), **true stereo** with a CMT mono fold, the DIP-5 self-test tone, and the **177714 capture seam** for the sound devices. **Infra only — no new sound device** | sim ✅ (25 mutations); ✅ HW 2026-07-31 — the resolution claim measured off the jacks (**−6.047 dB/step over 42 dB, max residual 0.19 dB**, the three sub-ladder-step levels on the line), all four acceptance recordings collected, the DIP-5 diagnostic retired, and the shipped bitstream boots. **+23 LE** |
| **11** TurboSound | `src/audio/bk_turbosound.sv` + the vendored `ym2149.sv`: **2x YM2149 on 0177714**, the first consumer of the Phase-10 seam. BkEmu `Ay8910` protocol, ACB pan folded to two mixer slots, the speaker ducked ~11.8 dB to make room | sim ✅ (15 mutations, incl. a cycle-exact diff of the adapted core against the vendored reference); **+1,182 LE (68 %), sys_clk +0.528 ns after an STA chase**; ✅ HW 2026-07-31 (real AY/TurboSound demos play on the board) |
| **12** Covox | `src/audio/bk_covox.sv`: an **8-bit DAC on 0177714**, the second consumer of the Phase-10 seam. BkEmu `Covox` map transcribed 1:1 (the scale is one `SLOT_GAIN` nibble), per-lane hold instead of BkEmu's zero-fill, **DIP 5 = mono/stereo** instead of its autodetect, and an automatic mute so the PSGs and the Covox — which share the address — never sound together | sim ✅ (13 mutations, + D13–D15 on `sim/ts` and A3/A4/A5 on `sim/run_audio.sh`); **+268 LE (70 %), sys_clk −0.639 → +0.102 ns after an STA chase on the increment's own new path**; HW: PENDING |

## Platform & system map

The hardware envelope and the whole-system picture. The per-module rules live in
the sibling `doc/dev/` files.

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
         spk_bit ───┐   ┌──────────────┐             ┌──────────────┐
   bk_turbosound ───┼──►│ audio_mixer  │─ L,R ──────►│ audio_out    │──► Sound-L
     (2x YM2149)    │   │ gain/pan/en  │  signed 16  │ 2x audio_ns6 │──► Sound-R
        bk_covox ───┤   │  saturating  │ (l+r)>>1 in │ + CMT jack   │  two 6-bit
       Menestrel ───┘   └──────────────┘  CMT mode   └──────────────┘  R-2R ladders
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
--- src/audio/ (audio_* = generic infra, bk_* = BK-specific; SOUND
    DEVICES LIVE HERE TOO - src/peripheral/ is for non-audio peripherals) ---
audio_ns6.sv        1st-order noise-shaped 16->6-bit quantizer (ONE channel)
audio_mixer.sv      N-slot stereo mixer: compile-time gain/pan, runtime enable
audio_tone.sv       the retired self-test: 2 DDS voices + the 6 dB staircase
audio_out.sv        pad stage: DAC rate, 2x ns6, CMT mono fold + the CMT jack
bk_audio.sv         the assembly: speaker CDC/activity + the SLOT MAP
ym2149.sv           vendored MiSTer PSG core, adapted for Quartus 11.0
bk_turbosound.sv    Phase 11: 2x ym2149 on 0177714 (BkEmu Ay8910 protocol)
bk_covox.sv         Phase 12: 8-bit DAC on 0177714 (BkEmu Covox map, DIP 5)
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

