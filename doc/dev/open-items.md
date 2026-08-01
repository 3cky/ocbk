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
- **Covox and Menestrel are still NOT built** (the third 177714 device,
  **TurboSound**, landed in Phase 11 — see its bullet). Both decode the SAME
  address (BkEmu `REG_SEL2` = 0177714) and differ only in how they read the
  data, so `qbus_mem`'s `port_wr`/`port_data`/`port_word`/`port_be` capture is
  already there, already oracle-pinned, and already has a consumer to copy.
  They belong in **`src/audio/`** (`bk_covox.sv`, `bk_menestrel.sv`) next to
  `bk_turbosound.sv`. Planned arbitration (settled): the PSGs are always live;
  Covox and Menestrel get cycled by a PS/2 radial-toggle key (the
  `key_scrmode`/`key_turbo` pattern). **They must re-open the gain budget**:
  Phase 11 spent it on the speaker (ducked to ±8192) and the TurboSound
  (0..22950), which together already reach 31142 of the 31744 available, so
  there is essentially NO headroom left. Adding a third source means lowering
  one of the two existing gains — a per-device loudness decision, and the
  arithmetic in `bk_audio`'s slot-map comment has to be redone with it.
- **The 177714 READ merge is not implemented.** The Phase-10 seam captures
  WRITES only, deliberately: a write capture is provably reply-inert (177714
  already replies via `sel_io`), while a read merge reaches into the reply/OE
  cone that this change carefully avoids. Covox is write-only, and BkEmu's
  `Ay8910` does not override `read` either (it returns 0), so Phase 11 did not
  need one — `bk_turbosound` leaves the core's `DO` unconnected. If a read is
  ever wanted, follow the `ide_rdata` pattern exactly.
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

