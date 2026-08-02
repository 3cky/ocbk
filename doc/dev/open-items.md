# Open / deferred


Nothing here blocks anything; each item has its detail in the bullet named.
Roughly in order of how much they'd be missed.

**Phase 10 is CLOSED (2026-07-31).** Its completion checklist lived here and
is done: all four acceptance recordings collected, the DIP-5 diagnostic
retired from the shipped build (`TONE_ENABLE = 0`, `audio_tone.sv` KEPT — see
the instantiation note in `ocbk_top.sv`), user-facing docs updated, rebuilt,
STA clean and boot-confirmed. What survives it is the rule, which applies to
every future increment: **a debug feature does not ship**, and the residue of
one is retired in the same commit that updates the user-facing docs. The
measurement results are in the audio bullets above and `sim/audio/README.md`.

**Phase 11 (TurboSound) is CONFIRMED ON HARDWARE 2026-07-31 — real
AY/TurboSound demos play on the board.** That is the acceptance that matters
most, and it is a broader test than `test/sndtestts.mac` could be: real
software exercises the whole BkEmu protocol (the word/byte address-vs-data
split, the 0xFF/0xFE chip select, the shared register pointer), the
envelope and noise generators, and the /56 clock rate all at once — any of
which being wrong would be immediately audible as wrong notes, wrong tempo or
silence. So the protocol, the chip select, the clock and the mix are all good.
Sim side: both oracles green with 15 mutations killed, all of `make sim` green
with **every timing golden byte-identical** (`qbus_mem` took a comment edit
only), and the STA chase closed structurally at +0.528 ns.

**The pan ORIENTATION is settled without a listen**, by chaining four things
that are each pinned: `bk_turbosound_tb` proves channel A lands in `ts_l` and
C in `ts_r`; `bk_audio_tb`'s pan section proves `ts_l` reaches the LEFT ladder
only and `ts_r` the RIGHT (mutation A1 — this was a genuine hole until Phase 11
closed it, and a swap there mirrors the stereo image while every other oracle
still passes); `ocbk_top` assigns `dac_l` straight to `pDac_SL`; and Phase 10
established physically that `pDac_SL` is the left jack, since the DIP-5
self-test's RIGHT-ONLY voice B was measured off the jacks as an R−L swing.
So A is left, B centre, C right, end to end.
**Still not separately verified, and cheap to check with `test/sndtestts.mac`**
(it builds a `.wav`, so it loads over the CMT jack): `pLed[4]`/`[3]` tracking
activity and 2-chip mode, `pLed[1]`/`[2]` staying dark, and a reset press
silencing both chips.
**The speaker duck was JUDGED FINE on hardware and is settled**: the BK beep
is ~11.8 dB quieter than the Phase-10 firmware so the PSGs and the speaker can
share the headroom, and that trade is accepted. `SPK_LVL = 8192` is therefore
a shipped constant, not a placeholder. If it is ever revisited anyway, two
things travel with it: keep it a **multiple of 1024** or the speaker stops
being a static `audio_ns6` code and starts rattling the shaper, and redo the
budget arithmetic in `bk_audio`'s slot-map comment — at 12288 the sum would be
35238 and the mixer WOULD saturate, so the TurboSound scale would have to drop
from x15 to x12 to pay for it.

**The margin, before anything else**
- **sys_clk setup is +0.254 ns, TNS 0 — met, and BOOT-CONFIRMED 2026-08-02.**
  The chase that "had not had to
  happen yet" through Phase 12 **happened with the joysticks**, and it landed on
  the worst possible cone: +23 LE / +12 pins re-placed the fitter into
  **−0.121, TNS −0.361** on `sdram_ctrl|wait_cnt → s_addr`, the Phase-7
  no-boot cone. Cured structurally with the `wait_zero` flop (the compare moved
  out of an I/O-ring register's enable cone and onto the counter's load path) —
  the full trace, the general rule and the cycle-identity proof are in
  [gotchas.md](gotchas.md). The critical path is now
  `va_037_sync|A[13] → mem_mapper|ext7_w` at +0.254 with **zero clock skew**,
  i.e. ordinary logic-to-logic, and `sdram_ctrl` is off the top-5 entirely.
  The chronic pre-existing cones (`ram_init|filling → sdram_arbiter|cmd_addr[*]`,
  `mem_mapper|mon_en → cpu_sdram_dp|addr_o[*]`) did not surface this time.
  **The next increment still starts here**, and the two documented cures remain:
  re-register the quasi-static high-fanout selector (`fill_active`) locally —
  note it shifts the port-0 handover by a cycle, so it needs `sim/raminit` re-run
  and a boot check, not a drive-by edit — and, more generally, get compares out
  of pad-register enable cones. **Never an SDC exception, never SEED 3**, and
  re-run a hardware boot: this design has been STA-clean and non-booting once
  before, on this exact cone.

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
  **All four are now DONE (2026-07-31)** — (1) here, (2) in the analog-stage
  bullet, (3) in the no-dither bullet, (4) in the tape bullet. The takes
  themselves were not kept; the numbers they produced, recorded in those
  bullets and in `sim/audio/README.md`, are the record. Keep any FUTURE
  recording in `test/` per the existing `.wav` convention.
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
- **Menestrel is still NOT built** (Covox landed in Phase 12, TurboSound in
  Phase 11 — see their bullets). It decodes the SAME address (BkEmu
  `REG_SEL2` = 0177714) and differs only in how it reads the data — by its pin
  field — so `qbus_mem`'s `port_wr`/`port_data`/`port_word`/`port_be` capture
  is already there, already oracle-pinned, and now has TWO consumers to copy.
  It belongs in **`src/audio/`** (`bk_menestrel.sv`). **It must re-open the
  gain budget**, and it cannot expect the free ride Covox got: Phase 11 spent
  the budget on the speaker (±8192) and the TurboSound (0..22950), and Phase 12
  added the Covox (±20480) **without cost only because Covox and the PSGs are
  mutually exclusive** — the Covox mutes itself on `ts_snd`. A third device
  either does the same (mutes on `ts_snd` *and* on the Covox being live) or
  forces a real gain reduction somewhere. The arithmetic in `bk_audio`'s
  slot-map comment has to be redone with it either way.
  **The arbitration decision recorded here through Phase 11 was REPLACED, not
  just implemented.** This bullet used to read "the PSGs are always live;
  Covox and Menestrel get cycled by a PS/2 radial-toggle key". Phase 12 chose
  an AUTOMATIC mute instead — the Covox stands down whenever the PSGs are
  emitting a non-zero sample — plus DIP 5 for mono/stereo. A key toggle would
  have been one more piece of hidden state for a user to get wrong, where the
  automatic rule needs no explanation and no UI, and the residual case (an AY
  setup phase, before any channel sounds, rendered as a ~100 µs click) is
  bounded and documented in the audio file.
- **A Covox artifact that is accepted rather than fixed**, recorded so it is
  not rediscovered as a bug: the start of a TurboSound program clicks faintly,
  because an AY setup writes registers before any channel sounds and the Covox
  is still live for that window. Every alternative discriminator collides with
  stereo Covox, which uses word writes exactly as the AY register latch does.
  If it ever proves audible, the escape hatch is MiSTer's (a hard
  user-selected mode), never a heuristic. Two more known limits of the same
  design: a player that exits leaving PSG channels enabled at volume 0 keeps
  the Covox muted until the next reset instruction or reset press, and a
  mono-only Covox program run with DIP 5 OFF leaves the right channel on the
  stale high lane.
  **A fourth, added when the OS-boot click was fixed:** `live` now takes a
  write that *changes* the code, so **a program that writes a constant code
  forever is inaudible**. That is deliberate and it is what real hardware does
  — a passive DAC into an AC-coupled amplifier reproduces the transitions, not
  the DC. Parallel-**printer** traffic on 177714 does still render as a short
  burst, exactly as it did before and as it would on a real board with a Covox
  hanging off the same connector. The trace and the rejected alternatives are
  in `audio.md`'s Covox section.
- **The 177714 READ merge is DONE and CONFIRMED ON HARDWARE (2026-08-02, the
  joysticks — a two-player game runs off both pads).** It is the
  joystick word, and it did **not** have to reach the reply/OE cone this item
  spent three phases avoiding: `sel_io` already replied at 177714 in *both*
  directions, so the whole change is one extra leg of `io_word` — a data mux.
  `selected`, the `wcnt` load, `drive_data`, `ad_oe` and `mem_ready` are
  untouched, and with the sticks idle the word is 0, i.e. the pre-joystick
  value, so every timing golden stayed byte-identical. The `ide_rdata` pattern
  this item pointed at is still the right answer for a device that needs more
  than that. The one new sharp edge is the **`!sel2_n` gate** on that leg —
  `io_word` is `rd_romio` and reaches every reply point — see
  [peripherals.md](peripherals.md).
- **START (bit 4) and SELECT (bit 7) of the joystick word have no source.** An
  MSX DE-9 digital pad has two triggers and nothing else, so those two bits are
  tied 0. Both alternatives were considered and rejected: an A+B chord is a
  heuristic (the standing answer here is a hard user-selected mode, never a
  guess), and OR-ing in PS/2 keys would inject phantom presses during ordinary
  typing. If a game is ever found that needs START, the honest fix is a
  user-selected mapping, not an invented one.
- **No joystick-disable DIP is shipped**, deliberately: with nothing plugged in
  the ports read all-released and 177714 reads 0, so there is nothing to
  disable, and a toggle is one more piece of hidden state to get wrong (the
  Covox precedent above). The exposure it *would* fix is real but narrow — a
  parallel-port/printer driver polling 177714 for a status line would see
  joystick bits while a control is actually held. Hardware bring-up found no
  conflict, so this stands. **`pDip[6]` is the reserved escape hatch** if one
  ever turns up; the decision and the pin are written down here so it is a
  five-minute change, not a redesign.
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

