# Audio oracles — the pinned contract

`../run_audio.sh` runs four legs; `--mutate` runs 28 mutations, each of which
must break one of them. This file records *what is pinned and why*, because the
central claim of the audio subsystem — that a 6-bit R-2R ladder carries far more
than 6 bits of audio-band resolution — needs a written justification and not
just an assertion. (Same discipline as `sim/evnt/README.md` and
`sim/ref014/README.md`.)

## The resolution claim, honestly stated

Three separate things, routinely conflated:

1. **Small-signal / interpolation resolution: ≥ 10 bits in the 0–20 kHz band.**
   A signal one tenth of a ladder step is reproduced rather than lost. This is
   the property a *mixer* needs — a quiet AY channel under a loud one — and it
   is what noise shaping actually buys.
2. **Absolute full-scale linearity: unchanged, ~6.5–7 bits, ladder-INL-limited.**
   Noise shaping does not fix resistor mismatch. Full-scale THD does not improve.
3. **There are still six bits at the pins.** Nothing in simulation can speak to
   (2). Sim proves the *digital* claim; the analog half needs a jack recording
   and an FFT (see "Hardware acceptance" below).

## Leg 3 — `audio_ns6_tb`, the resolution oracle

The load-bearing leg. `audio_ns6` accumulates the truncation error and feeds it
back, so the emitted code stream's short-term average carries the full 16-bit
input. The proof is an **identity, not a tolerance**:

```
1024*sum(code) - M*(32*1024 + s)  ==  errp_0 - errp_M   ∈ [-1023, 1023]
```

It telescopes out of `accr == (q<<10) + errn`, which holds bit-exactly by
construction, so the bound is true for *every* M and every in-range `s`. Plain
6-bit truncation is off by up to 512 units on **each** sample, i.e. `M*512` in
total — the discrimination is ~M-fold. Measured: the residual is **0** for every
input in the sweep. `--long` raises M from 4096 to 65536; it tightens the
relative demonstration but cannot loosen the bound.

**L4 is the sharpest single check in the audio work.** The code stream and the
ideal value go through the *same* single-pole IIR and are compared:

| stimulus | worst filtered error |
|---|---|
| full-scale triangle (±31744) | **9 / 1024 of a code** |
| **amplitude 512 = HALF ONE LADDER STEP** | **10 / 1024 of a code** |

A plain 6-bit truncating path renders that second signal as either silence or a
1-bit 31/32 square wave at the signal frequency — an in-band error of ~256+
units. Passing it *is* the increment's premise. The tolerance is 40 (≈4× the
measured value, ≈6× below what truncation would give): deliberately
discriminating rather than comfortable.

Also pinned: `code ∈ [1,63]` with `dbg_clip` clear for every in-range input;
**exact silence** (`s=0` ⇒ code 32 on every tick, and one tick to return there
after a loud passage); the clamp and post-clip recovery; tick discipline; and the
reset state.

### Three fixed points (verified, and the reason `FS_SAT = 31744`)

| input | `accr` | `q` | `errn` | code |
|---|---|---|---|---|
| `s = 0` | 512 | 0 | 512 | **32, static forever** |
| `s = +31744` | 32256 | +31 | 512 | **63, static** |
| `s = -31744` | −31232 | −31 | 512 | **1, static** |

Consequences worth knowing:

- **Silence produces zero pin activity.** That matters on this board because
  `pDac_SR[5]` doubles as the CMT input pad, and it makes "silent at silence" a
  sharp binary assertion instead of a statistical one.
- **The BK speaker maps to the two rails**, so it emits a *static* 63 or 1 with
  no shaping activity at all — the one audio feature confirmed working on
  hardware cannot be regressed by any of this. (It was 63/**0** before the
  rework; the one-code trim is what buys the clip-free window. 0.14 dB.)
- Since `|s_in| ≤ 31744` ⇒ `accr ∈ [−31744, 32767]` ⇒ `q ∈ [−31,+31]`,
  **clipping is structurally unreachable** in the shipped configuration.

### Two things that are NOT load-bearing, recorded so they are not "fixed"

- **`errp`'s reset value of 512** is the mid-residue and nothing more. `errp` is
  the residue `accr[9:0]`, not a constant added every tick, so it carries no
  persistent rounding bias. Checked both ways: resetting it to 0 gives the same
  mean (the identity holds for any `errp_0`), the same three fixed points and the
  same noise power — only the limit-cycle phase moves. It is pinned by L7 as
  *documented state*, and there is deliberately **no mutation** for it because
  none would fail.
- **`errp <= 512` on clip is not an anti-windup.** No windup is possible here:
  the residue is a bit-select, so it is bounded by construction. (The classic
  runaway belongs to the other formulation, where the fed-back error is
  `accr - (code_clamped << 10)` in a word wide enough to hold it.) What the line
  buys is that a clamped sample's residue is meaningless, so re-centring makes
  recovery exact from the first tick — pinned by L5's exact post-clip sequence.

### No dither, deliberately

For a DC input with fractional part `p/q` in lowest terms the limit cycle is at
`Fs/q` with amplitude `O(1/q)` codes. In-band needs `q > 300`, so any *in-band*
idle tone is below ≈ −85 dBFS, while the loud short cycles (Fs/2 = 3.02 MHz,
Fs/3) are all ≥ 1 MHz. The exact-zero fixed point is worth more than
decorrelation. Insertion point if ever revisited: `accr = s_in + errp + dither`,
RPDF from an LFSR — it invalidates exactly one leg (L3, silence), which would
have to become a bounded-variance check.

## Leg 4 — `audio_mixer_tb`

Four instances. `dut3` is the shipped config — now **NSRC=7**, and it MUST
track `bk_audio.sv`'s `SLOT_GAIN`/`SLOT_PAN` (enable / pan / the non-unity
Covox gain / saturation / `dbg_sat` / exact 2-cycle latency). Every device
increment extends it the same way: **zero-pad and disable the new slots** in
the older helpers (`set3`, `set5`) so every pre-existing check still means
exactly what it did, and add a helper of its own (`set7`). `dutg` sweeps
gains {8,4,6,3,1,7} against an
**independently written** floor reference (integer division plus an explicit
negative correction, never the RTL's arithmetic shift, so a shift bug cannot
cancel out — the palette-table precedent); `dut1` is the **pass-through
invariant** at `NSRC=1, g=8, BOTH` (the `smk_en=0`/`turbo=0` differential idiom —
what guarantees the speaker-only shipped path cannot be perturbed by mixer
arithmetic); `dut10` walks the planned endgame slot map.

Saturation is checked in the direction that matters: two full-scale slots must
clamp and must **never come out negative**. Mutation M1 shows why — wrapping
turns `+31744 + 31744` into `−2048`, a full-scale sign inversion, the loudest
artifact this path can emit.

Both hard-panned device pairs are pinned for crosstalk and orientation (slots
3/4 TurboSound, 5/6 Covox), and **both shipped worst cases are written down as
assertions**: `22950 + 8192 = 31142` and `20480 + 8192 = 28671`, each inside
`FS_SAT = 31744`. The third combination — TurboSound *and* Covox at once — is
deliberately not tested, because `bk_covox` mutes on `ts_snd` and it cannot
occur. That is said in the file itself so that a future saturation is fixed by
restoring the exclusion, not by raising `FS_SAT`.

## Leg 1 — `bk_audio_tb`, the subsystem

The regression guard for the two hardware-confirmed behaviours:

- **the speaker** — `spk_bit` 1/0 must reach a *static* ladder code 63/1, mono on
  both ladders, with neither `dbg_sat` nor `dbg_clip` ever setting;
- **the CMT jack** — the `oe` split (`6'b001111`), the comparator network
  `{tape_lvl, ~tape_lvl, 0, spk_raw}`, `tape_lvl` following the pad through the
  2-FF sync, reset winning over CMT mode, and the anti-echo force.

Two of those are *stronger* than before the rework, because what the pads now
carry is different:

- **anti-echo is checked on every cycle**, not sampled once. With CMT off we
  drive `pDac_SR[5]`, and since the rework it carries a shaped code bit that can
  toggle at 3 MHz, where before it was a quasi-static mono speaker level.
- **tape-out is checked with the tone running**, so a regression to a shaped
  sample bit is caught rather than aliased against a silent mixer.

It is also where the **slot map** is pinned, and it is the only place that
can be: `bk_turbosound_tb`/`bk_covox_tb` prove what each device puts in its
own left and right outputs, `audio_mixer_tb` proves which slot index is panned
where, and only this leg proves `bk_audio` **packs the left output into the
left-panned slot**. Swap either pair and every other oracle still passes while
the board plays that device's stereo image mirrored (mutations A1 and A3). The
Covox section additionally pins its **5/8 gain** — +16384 against the
speaker's low rail must read code 34 exactly, where 8/8 would read 40 — and
its **mute**: `cx_en = 0` must take both ladders back to the speaker-only
code, because that enable is `bk_covox`'s only mute mechanism (the device
keeps presenting its sample while muted, one gate not two).

New behaviour pinned: true stereo (the ladders must differ on ≥100 of 4000
ticks), the CMT **mono fold** on the left ladder, `tone_en` routing, exact
silence at the pads, DAC-tick discipline, and the staircase actually attenuating
— measured as `dac_r_o - dac_l`, which isolates voice B exactly because it is the
only right-panned source:

```
staircase: R-L swing 17 codes at step 0, 2 codes at step 5
```

(16 and 0.5 expected, ±1 from the two shapers' independent residues.)

Two testbench-timing traps worth knowing before editing this file or
`audio_ns6_tb`, both of which produced confident-looking false failures:

1. **A "changed off-tick" check must gate on the tick that governed the
   *previous* edge**, not the live one — the checker's own history register
   captures the pre-edge value at the same edge the DUT updates, so gating on the
   live tick flags every legitimate update one cycle late.
2. **The staircase window must start at a step boundary.** The dwell is only 1.06
   waveform periods, so a window that starts mid-step spills into the next
   (6 dB quieter) step and reports a blend. `meas_swing` re-arms `tone_en` to get
   a known boundary. And the dwell cannot be shortened below one voice-B period
   (~3854 ticks ≈ 61.7k sys_clk) at all — a step that ends before a full cycle
   has been emitted has no measurable amplitude.

## Leg 2 — `spk_capture_tb`

Directed Q-bus cycles into the **real** `qbus_mem`. The 177716 bit-6/bit-7
speaker and motor captures (including the BK-0011M `bank_wr` exclusion and the
"nINIT must not clear them" rule), the 177716 read assembly including tape bit 5,
and the **177714 (nSEL2) port-write capture** that `bk_turbosound` and
`bk_covox` consume (and Menestrel will).

The load-bearing case there is the **WTBT discriminator**. WTBT is dual-purpose —
"write cycle" at SYNC time, "byte op" at DOUT time — so `port_word` must sample
it *live* at the write point. A SYNC-latched implementation reads "low" in both
profiles and calls every access a byte write; the tb spells both profiles so the
difference shows.

## Hardware acceptance (what sim cannot do)

**Item 1 is DONE — the resolution claim is CONFIRMED ON HARDWARE 2026-07-31.**
Items 2–4 are still open, so the *analog stage* remains uncharacterised; see the
caveat at the end of this section. The discipline for what is still unmeasured
is the same as the BK-0010 `/32` prediction in CLAUDE.md.

1. ✅ **DIP 5 on**, record Sound-L/R while the staircase runs. FFT each step; a
   straight 6 dB/step line down through the sub-ladder-step levels, with the
   1567 Hz line still above the noise floor at the bottom, *is* the end-to-end
   proof. By ear: eight steps, of which the last three are levels a 6-bit path
   cannot produce.

   **Result** (`tones.wav`, 23 s stereo 44.1 kHz off the Sound-L/R jacks,
   4 staircase cycles, narrowband DFT inside each step with 18 % edge guards;
   the recording is deliberately NOT committed — 4 MB — so these numbers are
   the record):

   | step | ampl | ladder steps | ideal dBFS | measured | Δ prev | L-leak | S/N |
   |---|---|---|---|---|---|---|---|
   | 0 | 16384 | 16 | −7.84 | −5.99 | — | −80.0 | 85.1 |
   | 1 | 8192 | 8 | −13.87 | −12.33 | −6.34 | −73.6 | 81.3 |
   | 2 | 4096 | 4 | −19.89 | −18.36 | −6.03 | −70.2 | 71.1 |
   | 3 | 2048 | 2 | −25.91 | −24.38 | −6.02 | −71.0 | 59.4 |
   | 4 | 1024 | **1** | −31.93 | −30.40 | −6.02 | −70.2 | 60.4 |
   | 5 | 512 | **½** | −37.95 | −36.42 | −6.02 | −67.7 | 58.3 |
   | 6 | 256 | **¼** | −43.97 | −42.42 | −6.01 | −54.3 | 55.0 |
   | 7 | 128 | **⅛** | −49.99 | −48.45 | −6.03 | −54.1 | 49.4 |

   Least-squares over all eight: **slope −6.047 dB/step** (ideal −6.021), max
   residual **0.19 dB**, rms 0.09 dB, over a 42 dB range. The uniform +1.53 dB
   offset is analog chain gain and cancels out of the slope — **the slope is the
   claim**, which is why a single-frequency ratio measurement can prove it
   without the analog stage being characterised at all. The three sub-ladder-step
   levels sit on the same line as the full-scale ones, 49–58 dB above the local
   noise floor. Voice A in the left channel held −13.57 dBFS with **0.00 dB
   spread** across all 33 step windows (the measurement anchor), and voice B's
   own 3rd harmonic measured −19.03…−19.17 dB at every step against an ideal
   triangle's −19.08 — i.e. the waveform is reproduced faithfully even at ⅛ of a
   ladder step. Stereo separation 80 dB at the top, floor-limited (not
   leakage-limited) at the bottom.

   **Step 0 is the one outlier** (+0.33 dB off the line, −6.34 dB spacing into
   step 1): the recording ran hot, peaking at −0.47 dBFS, and step 0 is the only
   step whose 3rd harmonic departs from ideal (−17.72 dB). Re-record ~6 dB lower
   and it should join the line. It is not a board defect.

   ⚠️ **Voice A carries ~8.5 dB more 3rd harmonic than a triangle should, and it
   is NOT the digital path.** A bit-exact transcription of `audio_ns6` (residue
   `accr[9:0]`, clip/re-centre, 6.04 MHz tick) fed the real DDS triangles
   reproduces the ideal series exactly — 3rd −19.08, 5th −27.96, 7th −33.80,
   even harmonics >100 dB down, fundamental gain 0.000 dB — at 440 Hz, at
   1567 Hz, and at amplitude 128 where the fundamental emerges at precisely
   −49.99 dBFS. So the excess is analog-side, and it is frequency-selective
   (1320 Hz up 8.5 dB, 2200 Hz down 4.7 dB, small even harmonics present, and
   the 440 Hz component in the right channel expanding 1.54 dB when voice B is
   loud). One recording at two frequencies cannot separate response from
   nonlinearity — **item 2 is what resolves it.** It does not touch the
   staircase result.

   Frequency cross-check that validates the measurement: voice A read
   440.0038 Hz against an actual 440.0149, voice B 1567.4430 against an actual
   1567.4826 — one consistent −25 ppm capture-clock offset on both tones. This
   is also what caught the `STEP_B` transposition (69658 → 69637; see
   `audio_tone.sv`). **The recording predates that fix**, so its voice B is
   0.52 cents sharp of what the shipped RTL now emits; irrelevant to a ratio
   measurement, but do not re-derive a discrepancy from it.

2. **Sweep voice A 100 Hz → 100 kHz** and read the rolloff — this measures the
   board's analog RC corner, currently undocumented, and is what would justify
   changing `RATE_DIV` from 16 to 8 or 32.
3. **Record silence** with DIP 5 off and the machine idle: the noise floor, and
   confirmation that the shaper really is inactive at silence.
4. **CMT regression** in the same session: DIP 4 on, record a BK tone to a PC
   through the right jack and load a WAV back through MONITOR.
