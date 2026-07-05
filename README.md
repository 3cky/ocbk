# ocbk — BK-0010 / BK-0011M on the 1chipMSX / OneChipBook

Running the Soviet **Elektronika BK-0010/0011M** (PDP-11-class) as alternative
firmware on the OneChipBook board (Altera Cyclone I **EP1C12Q240C8**, Quartus II
11.0). See [ROADMAP.md](ROADMAP.md) for the full plan.

## Status: Phase 5 — SoC boot ✅ (BASIC Vilnius banner on screen) + soft reset

**The board cold-boots the real BK-0010.01 firmware**: at power-up the EPCS
loader copies the **MONITOR + BASIC Vilnius ROM set** (32 KB, `mem/roms/`, from
the BkEmu project) from the config flash into SDRAM (~22 ms, CPU held in reset),
then the `vm1` (1801ВМ1) core boots it — through the authentic 177716 start
vector — to the **БЕЙСИК ВИЛЬНЮС banner** on the panel.

The retimed **1801ВП1-037** (`va_037_sync`) owns RAM RPLY and its cycle-stealing
grant timing; **BK RAM (000000–077777) and ROM (100000–177577) live in the board
SDRAM** behind a 4-port arbiter (ROM is *not* 037-arbitrated — real mask ROM is
never cycle-stolen — and keeps the fixed `N_ROM` reply, done-gated against a late
SDRAM word). The 037 video fetch is decoded through the BK-0010 fixed palette
into a **double-buffered 4-bit-index framebuffer in SDRAM** and scanned out at
**1024×768@60** (×2H/×3V integer scale, 6-bit R-2R VGA DAC). `screen_mode`
(colour-256 / mono-512, the physical monitor cable switch on a real BK) is DIP
switch 1 (OFF = colour); **DIP 2 ON** boots the on-chip Phase-4 test ROM instead
(test picture + RAM test — the hardware regression image, also the automatic
fallback if the flash blob fails validation).

- Fits in **3660 / 12060 LEs (30%)**, **1 M4K**, **1 ASMI block**, **1 PLL**;
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
src/qbus_mem_sdram.sv ROM/IO front-end (N_ROM + done-gate) + datapath + arbiter
                + ctrl + the boot-writer mux (EPCS loader -> port 0)
src/epcs_boot.sv EPCS flash -> SDRAM boot loader (SPI via cyclone_asmiblock)
mem/roms/       BK-0010.01 ROM set (monit10 + BASIC Vilnius, from BkEmu)
mem/gen_boot_blob.py boot-blob builder (header/checksum + COF hex page)
src/fb_video.sv  037 fetch -> palette -> FB writer (ports 2+3, buffer swap)
src/palette_apply.sv BK-0010 fixed palette stage (the BK-0011M seam, Phase 7)
src/fb_readout.sv paced FB line prefetcher (port 1) + pixel-side CDC
src/fb_linebuf.sv dual-clock ping-pong line buffer (1 M4K)
src/vga_out.sv   1024x768@60 scan-out: scheduling, CLUT, x2/x3 scale
src/vga_timing.sv vendored VESA timing generator (ocb-test, board-proven)
src/qbus_sdram.sv Phase-2 RAM-in-SDRAM slave (retired from build; cosim only)
src/qbus_slot.sv cartridge-slot bridge (forward seam, SLOT_ENABLE=0)
src/ocbk_top.sv top level: PLL/clock tree (x9/2 = 96.65 MHz clk0 + extclk0 to
                pMemClk, x9/3 = 64.43 MHz pixel clk1, ~3.02 MHz anti-phase CPU
                clock) + resets (gated on SDRAM init_done) + CPU + video + LEDs
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
RAM while the button is held, until MONITOR's screen clear. DIP 1 flips colour-256 (OFF) / mono-512 (ON) decode
live (it is the monitor-cable switch of a real BK). DIP 2 ON boots the on-chip
test image instead: four vertical colour bars, an all-ones border (red in colour
mode, white in mono), the main diagonal in inverted colour, and the SDRAM RAM
test; DIP 2 is sampled **at reset only** — flip it, then press the reset button
(or power-cycle).

### LEDs

- **Red power LED** — normal boot: solid once the ROM blob is loaded, verified
  and selected. Fallback/test mode: solid once the CPU reaches the **success**
  self-loop at `100004` (every word/byte RAM-test write verified from SDRAM).
- **pLed[7]** — system heartbeat off the PLL (FPGA configured / PLL locked).
- **pLed[6]** — SDRAM `init_done`; **blinks** if the flash blob failed
  validation (the board then falls back to the on-chip test image).
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
- **ROM writes are replied-to and ignored** (a real BK would time out to trap 4);
  the timeout-fidelity question is deferred to Phase 9.
- Keyboard (177660–177663, the 1801ВП1-014), tape/audio and interrupts arrive in
  Phase 6 — until then 177660 reads the cold status stub and no key events occur.
