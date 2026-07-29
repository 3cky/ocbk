# ocbk — BK-0010 / BK-0011M on the 1chipMSX / OneChipBook

Running the Soviet **Elektronika BK-0010/0011M** (PDP-11-class) as alternative
firmware on the OneChipBook board (Altera Cyclone I **EP1C12Q240C8**, Quartus II
11.0). See [CLAUDE.md](CLAUDE.md) — "Platform & system map" for the clock tree,
the hardware-validated constraints and the SDRAM map; the topic bullets below
it for how each part works and why.

## Status: all phases ✅ — both models boot, the SMK512 boots an OS from SD

**The board cold-boots the real BK-0010.01 firmware**: at power-up the EPCS
loader copies the **MONITOR + BASIC Vilnius ROM set** (32 KB, `mem/roms/`, from
the BkEmu project) from the config flash into SDRAM (~22 ms, CPU held in reset),
then the `vm1` (1801ВМ1) core boots it — through the authentic 177716 start
vector — to the **БЕЙСИК ВИЛЬНЮС banner** on the panel.

The retimed **1801ВП1-037** (`va_037_sync`) owns RAM RPLY and its cycle-stealing
grant timing; **BK RAM (000000–077777) and ROM (100000–177577) live in the board
SDRAM** behind a 4-port arbiter (ROM is *not* 037-arbitrated — real mask ROM is
never cycle-stolen — and keeps the fixed `N_ROM` reply, done-gated against a late
SDRAM word). The 037 video fetch is decoded through the 16-palette stage
(BK-0011M `177662` palettes; BK-0010 = palette 0) into a **double-buffered
framebuffer in SDRAM** storing the 4-bit physical colour {R1,B,G,R0} per
pixel, and scanned out at **1024×768@60** (×2H/×3V integer scale, 6-bit R-2R
VGA DAC). `screen_mode` (colour-256 / mono-512, the physical monitor cable
switch on a real BK) is toggled by the PS/2 **Print Screen** key (power-on
default = colour-256). The PS/2 **F12** key toggles **turbo mode** (`pLed[5]`):
a 6.04 MHz CPU with the 037's DRAM cycle-stealing disabled — measured
**1.78x** faster than the authentic BK-0011M rate and **2.23x** than the
BK-0010 one (both halves matter: the clock ratio alone would be 1.5x / 2.0x). It is the one deliberately non-authentic feature here —
video and the 50 Hz frame interrupt are untouched, so a real-time-timed effect
keeps real time while the CPU runs faster. It works in both models, applies
live (no reset needed) and survives the reset button. The BK ROM always runs from the loaded SDRAM image; if
the flash blob fails validation the CPU is held in reset (no on-chip
fallback). **DIP 1 selects the model** (OFF = BK-0010, ON = BK-0011M — Phase
7 done: the 4.03 MHz CPU clock, the 177716 banking mapper, the 177662
screen-page/palette register, the 50 Hz EVNT/IRQ2 timer, the СТОП-block bit,
the two-pass EPCS loader with the 0011M ROM set and the authentic DRAM
power-on pattern are all in — **BK-0011M boots and runs BOS on hardware**;
both models are resident in flash and the reset button switches between them).
**DIP 8 enables the SMK512 controller** (Phase 8 done — increment 1 =
the 512 KB segmented RAM extension: the 0177130 layout register with all 8
BkEmu `SmkMemoryManager` modes over 8 × 4 KB segments, 16 × 32 KB pages in
SDRAM; increment 2 = the SMK BIOS ROM (v2.05) with the authentic boot hack —
in the reset SYS layout the BIOS overlays the register space, the 177716
start-vector read returns the BIOS word and the CPU boots into the BIOS at
166400 — confirmed on hardware 2026-07-17: the SMK BIOS
boots and shows its banner. It works in **both models** (the SMK is an
МПИ expansion board; on a BK-0010 the machine's monitor ROM takes the
place BOS and the banked window hold on a BK-0011M, and the BIOS detects
which machine it is running on by whether a 177662 write replies) —
**confirmed on hardware 2026-07-23: a BK-0010 with the SMK boots the BIOS
and loads an OS from the SD-backed image too**; increment 3 = the IDE drive engine + the
SD/SPI backend: the SMK ATA task file served from a **raw AltPro HDD
image dd'd onto an SD card** in the board's SD slot — **confirmed on
hardware 2026-07-18: the SMK BIOS detects the drive and boots an OS
from the SD-backed image** (pLed[7] = drive-access LED). With no card
the drive reports cleanly absent and the BIOS exits to its command
line; flip DIP 8 OFF and press reset for a stock machine). DIP 2 is
unused.

**The SMK512's memory now runs at the right speed** (Phase 9, confirmed on
hardware 2026-07-26). Its access-time constant had been a Phase-8 placeholder
that made SMK RAM ~14.5 % too slow. It was calibrated by playing a tone whose
frequency is set purely by the memory the delay loop executes from
(`doc/sndtestsmk.mac`) on a real BK-0011M + SMK512 and on the board, with the
same loop run from ordinary RAM as a control: the board went **514 Hz → 602 Hz
against the real machine's 601**. Oracle: `sim/smktime/run.sh`.

Those two measurements also settle what is left over. Decomposed, both legs
independently imply the real machine's CPU clock is **4.000 MHz** against our
**4.0270** (+0.67 %) — the board's 21.47727 MHz crystal cannot make 4.000
under the one-PLL rule. Normalised to that, the cycle counts agree to +0.04 %
and the 037 cycle-stealing to 0.027 cycles per access, both inside measurement
resolution: the remaining error is a clock *frequency* offset, not a
cycle-accuracy one.

- Fits in **6953 / 12060 LEs (58%)**, **3 M4Ks**, **1 ASMI block**, **1 PLL**;
  timing closes.
- Cycle accuracy holds under full 4-port SDRAM contention for RAM *and* ROM
  execution: the SoC cosims reproduce both goldens (`golden_037.txt`,
  `golden_037_rom.txt` — the ROM self-loop is *flat*, no cycle-stealing) exactly,
  including a run where the SDRAM is populated by the real EPCS loader and
  warm-reset replays where a mid-run reset must reproduce cold-boot timing
  bit-for-bit (`sim/ref037/`, twelve diffs).
- The full-chain video cosim is pixel-exact at the DAC pins against a
  Python-rendered frame (`sim/video/video_pipe_tb.sv`); the real MONITOR
  cold-boot is smoke-checked in sim (`sim/run_boot_check.sh`).

## Layout

```
src/cpu/        vendored vm1 core (1801ВМ1) + config + synth RAM stub
src/qbus_pkg.sv shared Q-bus decode / RPLY-latency constants
src/sdram_ctrl.sv vendored single-word SDR SDRAM controller (+byte-enable)
src/va_037_sync.sv retimed 1801ВП1-037 (RAM RPLY / grants / video counters)
src/sdram_arbiter.sv 4-port fixed-priority SDRAM arbiter (CPU/readout/fetch/FB)
src/cpu_sdram_dp.sv CPU RAM datapath (arbiter port 0) + RPLY done-gate
src/qbus_mem.sv ROM/IO front-end (N_ROM + done-gate) + datapath + arbiter
                + ctrl + the boot-writer mux (EPCS loader -> port 0)
src/epcs_boot.sv EPCS flash -> SDRAM boot loader (SPI via cyclone_asmiblock)
mem/roms/       BK-0010.01 ROM set (monit10 + BASIC Vilnius, from BkEmu)
mem/gen_boot_blob.py boot-blob builder (header/checksum + COF hex page)
src/fb_video.sv  037 fetch -> palette -> FB writer (ports 2+3, buffer swap)
src/palette_apply.sv 16-palette stage (MiSTer palette ROM; bk10 = palette 0)
src/fb_readout.sv paced FB line prefetcher (port 1) + pixel-side CDC
src/fb_linebuf.sv dual-clock ping-pong line buffer (1 M4K)
src/vga_out.sv   1024x768@60 scan-out: scheduling, colour decode, x2/x3 scale
src/vga_timing.sv vendored VESA timing generator (ocb-test, board-proven)
src/qbus_sdram.sv Phase-2 RAM-in-SDRAM slave (retired from build; cosim only)
src/qbus_slot.sv cartridge-slot bridge (forward seam, SLOT_ENABLE=0)
src/ocbk_top.sv top level: PLL (x9/2 = 96.65 MHz clk0 + extclk0 to pMemClk,
                x9/3 = 64.43 MHz pixel clk1) + resets (gated on SDRAM
                init_done) + DIP-1 model latch + CPU + video + LEDs
src/cpu_clkgen.sv fabric divider chain: dot/037-CLKIN enables + the anti-phase
                CPU clock, /32 = 3.02 MHz (BK-0010) or /24 = 4.03 MHz (BK-0011M)
mem/gen_mem.py  ROM program assembler + the test picture (render_image())
sim/bk10/       cycle-count oracle (bk10_tb.v + golden.txt + run.sh)
sim/ref037/     with-display oracles: reference 037, retimed 037, SoC cosim,
                SoC + real video pipeline (the Phase-4 cycle-accuracy gate)
sim/video/      video cosims: palette, fb_video, readout, full chain (pixel-
                exact vs gen_expected.py), run_draw_check.sh (slow, one-off)
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

## On-board behaviour

Power-up shows the **BASIC Vilnius startup screen** full-screen and borderless
(keyboard input arrives with Phase 6; СТОП will then drop to the MONITOR
prompt). The **reset button** warm-restarts the machine (hold = held in reset,
release = reboot in <1 s): the authentic 1801ВМ1 DCLO→ACLO power-up sequence is
re-run while SDRAM init, the flash ROM load and memory contents stay untouched —
BK hardware-reset semantics. The display is **not** affected (as on a real BK,
whose video controller ignores CPU DCLO/ACLO): the screen keeps showing video
RAM while the button is held, until MONITOR's screen clear. The PS/2 **Print
Screen** key toggles colour-256 / mono-512 decode live (it stands in for the
monitor-cable switch of a real BK). **DIP 1** selects the model: OFF =
BK-0010 (3.02 MHz), ON = BK-0011M (4.03 MHz CPU clock; boots BOS). It is
latched while the CPU is in reset, so flip it and
press the reset button to switch models without a power cycle; flipping it
mid-run does nothing until the next reset. DIP 2 is unused (it was the
on-chip test-ROM force, removed along with the on-chip ROM fallback — the BK
ROM always runs from the loaded SDRAM image).

### LEDs

- **Red power LED** — combined power/boot-status: **solid** once SDRAM
  `init_done`, but **blinks** if the flash blob failed validation (the CPU is
  then held in reset — there is no on-chip fallback). Dark only during the
  ~200 µs SDRAM init at power-on.
- **pLed[7]** — SMK512 drive access: **blinks at ~11.5 Hz** while the drive is
  busy (a boot, a multi-sector load), one ~43 ms flash for an isolated op
  (`ide_act` stretched to ~87 ms), dark when idle.
- **pLed[6]** — CMT tape-in mode (DIP 4; lit = the right jack is the cassette
  port).
- **pLed[0]** — BK speaker activity (solid while a tone plays; audio bring-up tap).
- **pLed[5]** — turbo mode (PS/2 F12; lit = 6.04 MHz CPU, no 037 cycle-stealing).
- **pLed[4:1]** — unused.

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
  stable because an SDRAM access finishes inside the RPLY window — with **one
  exception since the Phase-9 access-time calibration**: the SMK512 RAM's reply
  (`N_EXT = 1`) lands sooner than a strobe-time SDRAM read could finish, so that
  one leg starts its fetch at **SYNC**, the address phase, instead. General
  rule: a fixed reply shorter than the SDRAM latency must prefetch from the
  address phase, never from the strobe.
- **ROM writes get NO reply** → the CPU's bus-timeout → **trap 4**, exactly as a
  real BK's mask/overlay ROM (done in Phase 7; the conditionless "write until
  trap 4" fast screen-clear idiom depends on it). Applies to the fixed top ROM
  and the BK-0011M window-1 overlays alike. Oracle: `sim/romwr/run.sh`.
- Keyboard (177660–177663, the 1801ВП1-014), the 1-bit speaker and the tape
  interface are in (Phase 6). **Tape** uses the right sound-jack channel as
  the cassette port (esemsx3 CMT scheme), selected by **DIP 4**
  (`pLed[6]` lights while CMT mode is on): switch it on, play a BK tape
  recording (e.g. a WAV rendered from a `.BIN`) into the right channel and
  use MONITOR's СЧИТ / BASIC CLOAD; ЗАПИС/CSAVE records BK→PC through the
  same jack. Switch it off to get right-channel audio back. Interrupts
  (50 Hz EVNT/IRQ2) arrive with Phase 7.
