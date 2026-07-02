# ocbk — BK-0010 / BK-0011M on the 1chipMSX / OneChipBook

Running the Soviet **Elektronika BK-0010/0011M** (PDP-11-class) as alternative
firmware on the OneChipBook board (Altera Cyclone I **EP1C12Q240C8**, Quartus II
11.0). See [ROADMAP.md](ROADMAP.md) for the full plan.

## Status: Phase 4 — video output pipeline ✅

The `vm1` (1801ВМ1) core runs on the EP1C12 with the retimed **1801ВП1-037**
(`va_037_sync`) owning RAM RPLY and its cycle-stealing grant timing, **BK RAM
(000000–077777) in the board SDRAM** behind a 4-port arbiter, and the full video
path live: the 037 video fetch is decoded through the BK-0010 fixed palette into a
**double-buffered 4-bit-index framebuffer in SDRAM** and scanned out at
**1024×768@60** (×2H/×3V integer scale, 6-bit R-2R VGA DAC). The ROM-resident test
program draws a test picture (colour bars, border, diagonal) into video RAM and
then runs the RAM test. `screen_mode` (colour-256 / mono-512, the physical monitor
cable switch on a real BK) is DIP switch 1 (OFF = colour). The cartridge-slot
Q-bus seam stays a disabled forward seam (`qbus_slot`, `SLOT_ENABLE=0`).

- Fits in **3363 / 12060 LEs (28%)**, **1 M4K**, **1 PLL**; timing closes.
- Cycle accuracy holds under full 4-port SDRAM contention: the SoC cosim
  reproduces the with-display golden (`golden_037.txt`) exactly with the real
  video pipeline running, through 64 display lines of fetch + FB-write + readout
  traffic (`sim/ref037/ref037_soc_video_tb.v`).
- The full-chain video cosim is pixel-exact at the DAC pins against a
  Python-rendered frame of the shipped picture (`sim/video/video_pipe_tb.sv`).

## Layout

```
src/cpu/        vendored vm1 core (1801ВМ1) + config + synth RAM stub
src/qbus_pkg.sv shared Q-bus decode / RPLY-latency constants
src/sdram_ctrl.sv vendored single-word SDR SDRAM controller (+byte-enable)
src/va_037_sync.sv retimed 1801ВП1-037 (RAM RPLY / grants / video counters)
src/sdram_arbiter.sv 4-port fixed-priority SDRAM arbiter (CPU/readout/fetch/FB)
src/cpu_sdram_dp.sv CPU RAM datapath (arbiter port 0) + RPLY done-gate
src/qbus_mem_sdram.sv ROM/IO on-chip (N_ROM) + RAM datapath + arbiter + ctrl
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

The panel shows the test picture full-screen and borderless: four vertical
colour bars (black/blue/green/red), an all-ones border (red in colour mode,
white in mono), and the main diagonal drawn in inverted colour. DIP 1 flips
colour-256 (OFF) / mono-512 (ON) decode.

### LEDs

- **Red power LED** — solid once the CPU reaches the **success** self-loop at
  `100004` (every word/byte RAM-test write verified back out of SDRAM).
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
