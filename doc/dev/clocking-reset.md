# Clocking, reset, DIP/LED map and turbo mode

`src/sys/` (`cpu_clkgen.sv`, `turbo_ctl.sv`), the reset sequencer and DIP/LED
latches in `src/ocbk_top.sv`, and `src/sdram/ram_init.sv`.

## Clocking

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

## Soft reset, DIP switches and LEDs

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
  `[4]` = **TurboSound PSG activity**, `[3]` = **TurboSound 2-chip mode
  engaged** (Phase 11; `[3]` previously carried the DIP-5 self-test tone),
  `[2]` = a DAC quantizer clipped (STICKY), `[1]` = the audio mixer saturated
  (STICKY), `[0]` = speaker activity. The two sticky audio flags are bring-up
  observability — the same reasoning that put `spk_active` on `pLed[0]` in
  Phase 6: they turn "it sounds wrong" into "the digital side says the level
  overflowed", otherwise indistinguishable from an analog fault. Neither should
  ever light in normal use; the gain budget, not the saturator, is the mixing
  strategy.

## Authentic DRAM power-on pattern

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

## Turbo mode

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
