# CLAUDE.md

Guidance for working in this repo. Keep it current as the project grows.

## What this is

`ocbk` runs the Soviet **Elektronika BK-0010 / BK-0011M** (PDP-11-class) as
alternative firmware on the 1chipMSX / OneChipBook board (Altera Cyclone I
**EP1C12Q240C8**, Quartus II 11.0). The headline goal is **cycle-accurate** CPU
behaviour.

**Read [ROADMAP.md](ROADMAP.md) first** — it is the authoritative implementation
plan: the source building blocks, the validated platform constraints, the settled
clock tree, and the phase-by-phase milestones. Every change should map to a phase
there; update ROADMAP.md when scope or status changes. **Phases 1 (CPU bring-up),
2 (BK RAM in SDRAM), 3 (037 arbiter), 4 (video pipeline), 5 (SoC boot: full
BK-0010.01 ROM in SDRAM + EPCS loader) and the Phase-6 keyboard (PS/2 →
1801ВП1-014 equivalent, VIRQ/IAK + СТОП) are done**; see README.md for the
current result.

## Build & test

```
make sim       # Icarus regressions: bk10 cycle-count oracle + slave cosim
make           # Quartus: map -> fit -> sta -> asm -> POF (parked in fw/)
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
- `sim/ref037/run.sh` — **twelve diffs**, vs `golden_037.txt` (with-display timing,
  program in RAM) and `golden_037_rom.txt` (Phase-5: same program words executed
  *from the ROM region* — ROM is never 037-cycle-stolen, so its self-loop is
  **flat at 13 cycles**; the RAM loop beats 17,15,16,16): the reference netlist,
  the retimed `va_037_sync`, the SoC integration (now instantiating the *real*
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
  the behavioral `src/bk_kbd014.sv` must reproduce it line-for-line (netlist
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
  typematic suppression, multi-key `key_down`, СТОП strobes, parity-error
  and stale-prefix recovery.
- `sim/run_epcs_boot.sh` — the Phase-5 EPCS loader unit cosim (flash model →
  `epcs_boot` → arbiter port 0 → SDRAM): word-exact load + a corrupted-blob run
  that must end `boot_ok=0`.
- `sim/run_sdram_cosim.sh` — the Phase-2 `qbus_sdram` slave (word/byte datapath +
  deterministic RPLY). Runs the `--core-only` ROM (no picture draw — hours slow).
- `sim/run_video.sh` — palette unit tb; `fb_video_tb` (FB words vs a tap-driven
  expected model, mid-frame scroll, M256); `vga_out_tb` (timing geometry + pixel-
  exact readout); `video_pipe_tb` (full chain, every active pixel at the DAC vs a
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
  run it when touching reset/DCLO plumbing.

Any change touching the core, the Q-bus, memory, video, or clocking must keep all
of it passing. When tuning bus/RPLY timing, trace the **reference** waveform first
(instrument `cpu11/vm1/.../sim/bk10/bk10_tb.v`) — that is ground truth. Note the
golden checks *timing*, not write data — only the SDRAM/video cosims verify values.

## Architecture & conventions

- The `vm1` (1801ВМ1) core is **vendored** under `src/cpu/` from
  `~/projects/other/fpga/cpu11/vm1/hdl/syn`. Don't edit it casually; re-sync from
  upstream if needed. Core config is via global Verilog macros (see below).
- The Q-bus is **inverted / active-low / open-collector**, carried as shared
  tri-state nets at the `cpu_test` level (no SystemVerilog `interface` — neither
  Quartus 11.0 nor Icarus handle tri-state interface members reliably). Every
  participant (core, `qbus_sdram`, `qbus_slot`) drives `x ? 1'b0 : 1'bZ` /
  `ad_n = ena ? ~out : 1'bZ`.
- Clocking: **one PLL only** (board constraint — the PIN_28 crystal feeds a single
  PLL). New clocks must be a ÷N of the ×9 VCO or a fabric clock-enable; the SDRAM
  chip clock (`pMemClk`) is the PLL's `extclk0` at the same 96.65 MHz as the
  internal `clk0`/`sys_clk` (phase-matched, like esemsx3's c1/e0). The clock tree
  lives in `src/ocbk_top.sv` (no separate `cpu_clk.sv`).
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
  golden window steal-free and diffable). The Phase-6 keyboard reset chord ORs
  into `warm_rst_req`. "DIP n" = physical switch n = `pDip[n-1]`; **DIP 1 is
  now unused** — screen_mode moved off it onto the PS/2 **Print Screen** key
  (each press toggles colour-256 ↔ mono-512; the `kbd_ps2bk` `key_scrmode`
  radial output → the `smode_sr` 2-FF sync; power-on-only, so it survives a
  warm reset like the real monitor-cable switch and the video pipeline). **DIP
  2 is also now unused** — it forced the on-chip test ROM, removed 2026-07-10
  (ROM is always the loaded SDRAM image).
- **Keyboard (Phase 6):** `ps2_rx` → `kbd_ps2bk` (translator, all on
  `cpu_clk`) → `bk_kbd014` (the 1801ВП1-014 bus equivalent at 177660–177663,
  decode = the 037's `PIN_nBS`, netlist-contract-validated — see
  `sim/ref014/README.md` for the full pinned contract). Key facts:
  - **the 014 readme's "nEC1 = РУС/ЛАТ" label is imprecise for the BK**: the
    schematic wires nEC1 to the trigger flipped by the ЗАГЛ/СТР keys (caps),
    while РУС/ЛАТ are ordinary matrix keys emitting 016/017 — mapped here as
    CapsLock = the ЗАГЛ/СТР trigger, LCtrl = РУС, Home = ЛАТ, Insert = СУ
    (held), either Shift = НР, either Alt = АР2, **Delete = СТОП**,
    **Print Screen = screen_mode toggle** (a `key_scrmode` radial control
    output, never a matrix code, power-on-only — see the screen_mode note above);
  - case algebra per BkEmu (`latin ^ (caps | shift)` on letters, СУ = `&037`
    on 01xx codes); the **silicon auto-274 code group**
    {0,1,2,4,5,6,7,011,013,021} vectors to 0274 without АР2 (measured over
    the netlist matrix scan — MiSTer's arrow flags were wrong);
  - **СТОП is trap-to-4 on a BK-0010 with BASIC** (per the schematic/user):
    nothing decodes 177674/177676, the HALT entry's PC/PSW stores bus-timeout
    (`qbto`, 56..63 clocks) and the CPU traps through RAM vector 4 — the
    160002 word is never used as a vector. `qbus_mem` excludes
    177674–177677 from `sel_io` to reproduce this; never "helpfully" reply
    there. СТОП itself is a fixed 64-cpu_clk one-shot on nIRQ1;
  - `N_KBD`/`N_IAK` = 1 (the async chip replies within the strobe cycle) and
    the 177660 **write** reply is combinational (`wr_fast`) — both pinned by
    `golden_kbd.txt`; vm1 slaves must hold read data past DIN release (the
    IAK vector capture relies on it — bus-charge physics on the real board).
- Cartridge-slot Q-bus is a **forward seam**: `src/qbus_slot.sv`, default
  `SLOT_ENABLE=0` (drives nothing, slot pins stay reserved-tristated). The full
  slot pin map lives commented in `ocbk_common.qsf`. Real BK hardware needs an
  external 5V↔3.3V level-shifter (Cyclone I is not 5V-tolerant).
- On-chip RAM is tight (~239 Kbit). BK RAM (000000–077777) lives in the board
  **SDRAM** via the 037-fronted arbiter path (`qbus_mem`; the Phase-2
  `qbus_sdram` is retired from the build but kept for its cosim). The vendored
  `src/sdram_ctrl.sv` (from `ocb-test`) gained a 2-bit `cmd_be` byte mask for
  the BK's byte writes — re-sync from upstream but keep that hook.
  `src/vga_timing.sv` is likewise vendored verbatim from `ocb-test`.
- **ROM-in-SDRAM (Phase 5):** the full BK-0010.01 ROM (`mem/roms/`, committed;
  canonical source = the BkEmu project, also the reference for BK register
  semantics) is 262 Kbit > the device's 239 Kbit, so ROM reads ride the CPU
  datapath (arbiter port 0, linear `addr[15:1]` map → SDRAM words 0x4000–0x7F7F),
  keeping the fixed `N_ROM=2` reply, **done-gated** on
  `mem_ready` (ROM is NOT 037-arbitrated — mask ROM is never cycle-stolen; the
  flat ROM self-loop in `golden_037_rom.txt` pins that). ROM writes reply+ignore
  (real BK would bus-timeout → trap 4; fidelity deferred to Phase 9). Boot:
  `src/epcs_boot.sv` copies the blob from EPCS offset 0x40000 through the
  boot-writer mux onto port 0 during reset-hold (DCLO held until `boot_done`).
  ROM is **always** the loaded SDRAM image — the on-chip 256-word test-ROM
  fallback and its **DIP2** force were removed (2026-07-10) to free resources.
  A failed EPCS boot (`boot_ok=0`) now **holds the CPU in reset** (the reset
  sequencer gates on `bo_sync`); it does not fall back. The ref037 SoC oracles'
  default-mode bootstrap JMP therefore lives in the SDRAM ROM region (word
  0x4000 → RAM program) instead of an on-chip stub — timing-identical (same
  fixed `N_ROM`), `golden_037.txt` unchanged.
- **Video pipeline conventions (Phase 4)** — mirror these in RTL, cosims and
  `gen_expected.py` alike: FB = 512 slots/line × 4-bit post-palette index ×
  256 lines, 128 words/line, slot `s` of a word at bits `[4s+3:4s]`, LSB-first in
  beam order; FB0 = SDRAM word `0x010000`, FB1 = `0x018000`, double-buffered
  (writer swaps at the vgate frame edge, reader latches `fb_front` at its vblank
  line-0 request). FB *destination* comes from beam counters, fetch *address* from
  `video_va` (else scroll breaks). Scroll: row r fetches vram line
  `(RA − 0o330 + r) & 0xFF` (netlist-proven). CLUT (in `vga_out`): 0=black 1=blue
  2=green 3=red 15=white — also the CRT colour-tweak hook. `screen_mode`
  (mono-512 / colour-256) is toggled by the PS/2 Print Screen key (power-on
  default = colour-256), touches only `palette_apply`.
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
- **`vm1_simlib.v` is sim-only** (dual-write-port behavioural RAM → "multiple
  constant drivers" in Quartus). The FF register-file path
  (`CONFIG_VM1_CORE_REG_USES_RAM=0`) leaves that RAM unused, so the Quartus build
  uses the tied-off stub `src/cpu/vm1_vcram_syn.v` instead.
- **Open-collector RPLY combinational loop** — Quartus flags a benign 4–6-node
  loop where the CPU's internal-register reply and the slave wire-AND onto RPLY.
  Cosim-validated; clean fix (explicit wired-AND via `vm1_qbus`'s split
  `rply_in`/`rply_out`) deferred to peripheral work (Phase 6).
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
  posedge D) re-times IRQ1–3/VIRQ *plus ACLO and DMR*. Modelling D8:B in our
  RPLY path is a deferred fidelity item: it quantizes assert AND release to
  falling edges, shifting cycle counts (ROM/IO by a full cycle — N_ROM would
  need recalibration), so it must go reference-tb-first with golden
  regeneration from the reference run, per the verification discipline.
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
- **CDC for SDRAM:** the wait-state FSM (`cpu_clk`) launches an SDRAM access via a
  request-*toggle* into the `sys_clk` adapter; read data is sampled back at the
  fixed RPLY point. This is safe while a worst-case access (~200 ns, incl. a
  refresh collision) finishes inside the RPLY window = (N_RAM-2) CPU clocks — ~3x
  margin at 3.02 MHz, ~1.6x at 6 MHz turbo, breaking only above ~10 MHz CPU clock
  (NOT "one CPU cycle" — the window is ~2 cycles). There is currently **no
  interlock**: a margin violation would latch stale data rather than extend RPLY,
  so re-validate at the 4/6 MHz rates (Phase 7) or add a done-gate first.
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
- `mem/boot_blob.{bin,hex}` + `boot_blob_flash.hex` are **generated** by
  `mem/gen_boot_blob.py` from the committed `mem/roms/*.rom` (gitignored,
  `make` regenerates). **EPCS bit-order (hardware-verified, subtle):** the COF
  Intel HEX carries **true bytes**. `quartus_cpf` bit-reverses `hex_block`
  bytes into the POF/RPD — but the RPD is in **RBF/LSB-first bit order, not
  physical-flash order** (its Page_0 equals the `.rbf` verbatim) — and
  `quartus_pgm -m AS` reverses **again** onto the chip, so the two cancel and
  an MSB-first SPI READ returns the HEX bytes verbatim. Do NOT pre-reverse
  (that was tried; on the board the loader read rev(blob) and fell back).
  `make blob-check` verifies the RPD page = rev(blob).

## Temp files

Use the session scratchpad for throwaway scripts/sims, never the repo root.
