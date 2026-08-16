# Audio — the CMT jack, the mixer/DAC stage and the sound devices

`src/audio/`. **Sound devices belong here**, not in `src/peripheral/`. The
cassette port shares the right DAC ladder, so tape is documented here too.

## Tape / the CMT jack

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
  the speaker sounds**. **RE-CONFIRMED ON HARDWARE 2026-07-31 after the
  Phase-10 rework** (acceptance item 4, the regression check on this
  already-shipped feature): a program saved to tape and loaded back
  successfully, the DIP-4-ON and DIP-4-OFF speaker levels measured EQUAL — the
  fold really is an average and really is a no-op for a BOTH-panned source,
  where a sum would have shown 6 dB — and a tape load with DIP 4 OFF saw
  nothing, i.e. the anti-echo force holds now that `pDac_SR[5]` carries a
  rattling shaped code bit instead of the pre-rework quasi-static level. Two
  Phase-10 rules for this jack, both in
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

## The audio subsystem

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
    **A pipeline register sits between the mixer and the shapers** (`audio_out`,
    added 2026-08-16 for STA): without it the chain from the mixer's output
    register was `mix_l → the 17-bit mono add → the CMT mux → the shaper's
    17-bit add → the clip compare → errp`, i.e. **two 17-bit adds and a compare
    in one sys_clk**, and it went to −0.072 ns when an unrelated +22 LE
    re-placed the fitter. The cost is one sys_clk (10.3 ns) on both channels
    equally — a pure delay, not a resampling: `tick` is unchanged, the shapers
    still consume one value per tick, and both channels shift together so the
    stereo image cannot skew. The DC gain of exactly 1 is untouched by a delay,
    which is why the identity leg still holds. **Rewriting the adder instead is
    a proven dead end** — splitting it into its 10-bit and 7-bit halves gave a
    bit-identical fit, because Quartus re-associates it anyway; see gotchas.
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
  * **The gain budget is the mixing strategy, and Phase 11 SOLVED it — by
    ducking the speaker.** The speaker used to be a full-scale source, so by
    itself it used the entire headroom and anything sounding alongside it
    saturated. Phase 10 sidestepped that by having the self-test tone MUTE the
    speaker; Phase 11 had to actually fix it, and did so the way MiSTer does
    (`BK0011M.sv`: `spk_out<<7` alone but `spk_out<<5` with the PSG live) —
    except **unconditionally**, so the speaker's loudness never jumps
    mid-program. `bk_audio`'s `SPK_LVL` is now **±8192** instead of ±31744,
    i.e. the stock BK beep is **~11.8 dB quieter than the Phase-10
    firmware** — a deliberate, user-audible regression, and the price of
    hearing the PSGs and the speaker together. The budget then closes BY
    CONSTRUCTION: `22950 (TurboSound) + 8192 (speaker) = 31142 <= FS_SAT =
    31744`, so the mixer cannot saturate and the shapers cannot clip.
    **8192 is not an arbitrary quarter**: it is 8×1024 exactly, which keeps
    the speaker on a STATIC `audio_ns6` code (40/24) with no shaping activity
    — the structural property the hardware-confirmed speaker path depends on.
    A literal ¼ of 31744 would be 7936 = 7.75×1024, NOT a fixed point, and
    would leave the codes rattling.
    **Phase 12 re-opened this and closed it again for free**: Covox and the
    PSGs are MUTUALLY EXCLUSIVE (same address, so the Covox mutes on
    `ts_snd`), which makes the worst channel `max(22950, 20480) + 8192` — the
    same 31142. See the Covox section for the arithmetic and for why 5/8 is
    the largest legal Covox gain. Menestrel must re-open it once more.
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
    177714 already replies via `sel_io`. **The READ direction of the same
    address is now the joystick word** (a `!sel2_n`-gated leg of `io_word`, see
    [peripherals.md](peripherals.md)) — structurally separate from this
    capture: different direction, different always block, and no sound device
    contributes read data (Covox never reads, `bk_turbosound` leaves the core's
    `DO` unconnected). The seam's contract is unchanged by it.
    **Since Phase 11 `bk_turbosound` consumes it** (it was dangling and free
    through Phase 10) and **`bk_covox` since Phase 12**; Menestrel will hang
    off the same wires.
    The seam itself is oracle-pinned by `spk_capture_tb` driving the real
    `qbus_mem`, independently of any device.
  * **Cost and timing (confirmed) — the SHIPPED audio subsystem costs
    +23 LE.** 6,979 → **7,002 LE (58 % → 58 %)** with the self-test retired
    (`TONE_ENABLE = 0`), M4K unchanged at 3/52, pins unchanged at 98/173, no
    new PLL. That is the whole rework — N-slot stereo mixer, two noise-shaped
    output stages, the CMT mono fold and the 177714 capture seam — for 23
    logic elements, because it REPLACED the pre-rework DAC logic rather than
    adding to it. **sys_clk setup +0.309 ns, TNS 0, zero negative paths.**
    The intermediate builds are the interesting part of this story and worth
    keeping: **with the tone compiled in it was 7,357 LE at +0.034 ns** — so
    the diagnostic cost **355 LE, not the ~130 first estimated** (the two DDS
    voices and the staircase shifter, plus mixer slots 1–2 and their adder
    trees folding away with them), and its removal took the margin from
    +0.034 → +0.309. **No STA chase was needed at any point**, which is
    unusual for this design and is down to every stage being one carry chain
    deep and every pad driven from a flop.
    ⚠️ **The +0.034 ns intermediate is the lesson, not the +0.309.** Between
    the +0.260 and +0.034 builds the *only* RTL delta was the one-constant
    `STEP_B` fix (+1 LE) — **placement fragility, not an audio-path cost**,
    the same shape as the +19 LE that once took an untouched module
    +0.481 → −0.414. The worst path in every one of these builds is the same
    chronic cone: `mem_mapper|rom7_en → cpu_sdram_dp|wdata_o[*]`, with
    `model_bk11` and `mon_en` right behind it into the same `wdata_o`/`addr_o`
    endpoints. **Budget for an STA chase on the next increment, and do not
    chase margin by changing SEED 3** (see `ocbk.qsf`'s header and the
    SDC-exception rule). **That prediction came true in Phase 11** — the same
    cone went to −0.271 ns on the first TurboSound build; see the fix in the
    TurboSound bullet below.

## TurboSound

- **TurboSound (Phase 11) — 2× YM2149 on 0177714, `src/audio/`.** The first
  device on the Phase-10 seam. **`src/audio/bk_turbosound.sv`** is the device
  and **`src/audio/ym2149.sv`** the vendored PSG core; both live in
  `src/audio/` — **sound devices belong here, `src/peripheral/` is for
  non-audio bus peripherals** (this supersedes the Phase-10 note that said
  otherwise, which predated any actual device). Instantiated as an `ocbk_top`
  sibling like `smk_ide`: it snoops what `qbus_mem` captured and never touches
  the bus, so **`qbus_mem` is unchanged and no timing golden moves**.
  * **BkEmu's `Ay8910.java` is the contract** — it is the only one of the two
    references that implements TurboSound at all (MiSTer's BK core has ONE
    PSG). `v = ~port_data[7:0]`; a **WORD** write latches a register number
    (masked to `v[3:0]`, broadcast to BOTH chips because BkEmu keeps ONE
    shared `currentRegister`); a **BYTE** write is data into the SELECTED
    chip. An **odd-byte (0177715) write is a data write of `0xFF`**, because
    BkEmu's `Computer.writeMemory` passes `value<<8` whose low byte is 0.
    `0xFF`/`0xFE` in the latch select primary/secondary, and the first `0xFE`
    ever seen activates 2-chip mode.
  * **Two documented divergences.** From **MiSTer**: it wires
    `BC = bus_wtbt[1]`, so an odd-byte write is an ADDRESS latch there and a
    DATA write here — BkEmu wins, the standing rule for BK register semantics.
    From **silicon**: the latch is masked to 4 bits, where a real chip latches
    8 and then ignores the following data write if the high nibble is
    non-zero — BkEmu masks, so we mask.
  * **Two pieces of BkEmu are deliberately NOT reproduced, and they are the
    same piece of behaviour**: the 3-second TurboSound dead-man timeout and
    the reset of the secondary at activation. Both exist because a BkEmu chip
    OBJECT outlives the program that programmed it. `nINIT` does that job in
    hardware, and dropping the timeout makes the activation reset
    **unreachable** — `dual_act` is cleared only by the reset that also clears
    both chips, so a "first 0xFE" can never find a dirty secondary.
    Implementing it would be dead logic no oracle could kill. **If the timeout
    is ever added back, the activation reset has to come with it.**
  * **Clock: `sys_clk`/56 = 1.72585 MHz** against a real BK AY's 12 MHz/7 =
    1.714286 — **+0.674 %, the design's uniform offset**, with **CPU:PSG =
    56:24 = 7:3 exactly** as on real hardware, so the PSGs cannot drift
    against CPU-timed code. The divider is PRIVATE to the module, not a port
    (the `cpu_clkgen` replica-drift lesson, same as `audio_out`'s prescaler).
    `SEL=0`, `MODE=0` — MiSTer's BK settings.
  * **The ACB fold happens IN THE DEVICE, not in the mixer**, and it is two
    slots rather than six: `lc = 2A + B` per chip, then
    `l = dual_act ? (lc0+lc1) : 2*lc0`, then `×15` as `(l<<4) - l` (no
    multiplier). A left, C right, B centre is what BOTH references do. The
    `dual_act` form is BkEmu's "average the two chips" without a divider, so
    the full-scale bound is **1530 → 22950 in both modes** — which is what
    makes the headroom proof hold — at the cost, deliberately reproduced, of
    each chip dropping **6 dB** when TurboSound engages. Six slots would also
    have pushed `audio_mixer` past the ~6-slot tree depth its header warns
    about; two keeps the shipped map at three live slots.
  * **The output is UNIPOLAR (0 at silence) on purpose.** A PSG channel is a
    gated DC level, so its rest value is genuinely zero; subtracting a
    mid-scale offset to "centre" it would put permanent DC on the ladder and
    destroy `audio_ns6`'s exact-zero fixed point — the property that makes
    silence produce no pin activity, measured on hardware. The DC a PLAYING
    PSG carries is real and harmless (`audio_ns6` has DC gain exactly 1, and
    the analog stage measured flat from 100 Hz).
  * **The vendored core needed a Quartus-11.0 adaptation, and that is the
    increment's real risk.** Upstream uses `reg [7:0] ymreg[16]`,
    `'{default:0}`, `'1`, an unpacked array of wires with an assignment
    pattern for the 64-entry `volTable`, `wire [11:0] tone_gen_freq[1:3]`, and
    block-local `reg`s inside `always` blocks. **Icarus rejects it too**, so
    even the sim reference is not byte-pristine — `sim/ts/ym2149_ref.sv` has
    46 changed lines in three enumerated groups. The shipped copy additionally
    turns the table into a `function` + `case`, splits the freq array,
    unrolls the tone loop and hoists the block-local state. **`sim/ts` leg 1
    is what makes all of that safe** (see the oracle bullet).
    ⚠️ **The un-reset state needs `= 0` initialisers or the core simulates as
    all-X forever**: `poly17`'s re-seed term is `!poly17`, which never
    recovers from X. That is also what the hardware does (Cyclone FFs power up
    to 0), so it is faithful, not a sim hack.
  * **Reset is `~init_n`** (2-FF synced) ORed with the power-on reset — the
    standard BK peripheral rule, which `qbus_mem`'s own seam comment names for
    this device class. A RESET instruction silences the PSGs and clears the
    TurboSound latch, as it would on a real board. The CE divider is NOT reset
    by `nINIT` (a real chip's clock keeps running).
  * **Cost and timing (confirmed) — TurboSound costs +1,182 LE, and the STA
    chase Phase 10 told us to budget for HAPPENED, exactly where it said it
    would.** 7,002 → **8,184 LE (58 % → 68 %)**, M4K unchanged at 3/52 (the
    `ymreg` file has many simultaneous combinational readers, so it cannot
    infer RAM), pins unchanged at 98/173, no new PLL. Two YM2149s are ~250 FF
    each before any logic — `ymreg` alone is 128 — plus three 12-bit tone
    compares, a 16-bit envelope compare, the 17-bit LFSR and three 32-entry
    volume LUTs per chip.
    **The first build came in at sys_clk −0.271 ns, TNS −1.146**, on the
    chronic cone this file already names: `mem_mapper|rom6_en →
    cpu_sdram_dp|wdata_o[*]` — a module the increment never touched. Pure
    placement fragility from +1,183 LE, the same shape as the +19 LE that once
    took an untouched module +0.481 → −0.414.
    **Cured structurally, in the established idiom** (never an SDC exception,
    never a SEED change): `cpu_sdram_dp`'s `wdata_o` no longer gates its load
    on `is_write`, which had put the whole mapper decode
    (`rom6_en`/`rom7_en`/`seg_smk` → `kind` → `sel_ram|sel_ramw`) inside a
    16-bit register's ENABLE cone. It now loads on any DOUT while the FSM is
    idle. Behaviour-identical by the `was_read`/`oe_arm` argument: `wdata_o` is
    only ever consumed while `req` is high with `we` set, and `req` only rises
    on a transition OUT of D_IDLE — so every extra load is either the real
    write on that same edge from the same `ad_true`, or dead data nobody can
    read. **Result: −0.271 → +0.528 ns, TNS 0, and −1 LE** — better margin
    than the Phase-10 baseline of +0.309. Same rule as `rdata_oe` before it:
    **keep translate outputs out of a register's enable cone.**
  * `pLed[4]` = PSG activity, `pLed[3]` = 2-chip mode engaged.
    `test/sndtestts.mac` is the hardware acceptance program (pdpy11, with a
    `.wav` so it loads over the CMT jack): the A-major chord and each channel
    solo to prove A-left/B-centre/C-right, noise, an envelope sweep, and the
    TurboSound section. A `DUAL_ENABLE` parameter drops the second chip — a
    documented fitter escape hatch, not the shipped configuration.

## Covox

- **Covox (Phase 12) — an 8-bit DAC on 0177714, `src/audio/bk_covox.sv`.** The
  second device on the Phase-10 seam and, like `bk_turbosound`, an `ocbk_top`
  sibling that only snoops: **`qbus_mem` is unchanged (comment edits only) and
  no timing golden moves.**
  * **BkEmu's `Covox.java` is the contract.** Low byte = LEFT, high byte =
    RIGHT of the *same* word — one address, two lanes, not two addresses. The
    port inverts, so the device does its own `~` (the `bk_turbosound` division
    of labour). The byte map is exactly linear —
    `((b-128)<<8)|b == 257*b − 32768` — and since `257*b` is `{b,b}` the whole
    map is **one inverted bit**: `cx = $signed({~b[7], b[6:0], b})`. The device
    carries no arithmetic and no scaling at all.
  * **`port_word` and `port_be` are NOT ports of this device**, which is the
    structural consequence of the lane rule below: because the latch holds the
    lane a byte write did not touch, the Covox output is a **pure function of
    `port_data`**. Word-vs-byte is the AY's discriminator, not ours. `port_wr`
    is taken for the idle one-shot alone.
  * **Per-lane hold, NOT BkEmu's `value << 8` zero-fill — a deliberate
    divergence.** On a byte write BkEmu passes the other lane as 0, so its
    model reads the *other* channel as `0xFF` = full scale. That is an artifact
    of its `writeMemory` signature, not of the hardware: 177714 is a
    byte-lane-strobed latch and holds what was not written, which is what
    `qbus_mem` already does. Same call and the same reasoning as the 177716
    `stop_block` lane rule — the real WR1/WR2 byte strobes win over a BkEmu
    lane artifact. `sim/covox` section 3 is the discriminator.
  * **Stereo/mono is DIP 5, not BkEmu's autodetect — the second deliberate
    divergence.** BkEmu latches stereo on a word write whose inverted high byte
    is neither `0x00` nor `0xFF`, and decays back to mono after 3 s. Both
    halves exist because a BkEmu device *object* outlives the program that
    programmed it — the identical argument that dropped the TurboSound dead-man
    timeout. Here it is a switch (`~pDip[4]`, live 2-FF sync, `cx_mono` in
    `ocbk_top`; **a separate wire from `tone_en`**, which stays for the
    `TONE_ENABLE = 1` diagnostic build — the two are mutually exclusive by
    build configuration, and sharing one wire would have made the one-token
    diagnostic switch a landmine). **Accepted consequence, documented in
    README:** a mono-only program writes the low lane only, so with DIP 5 OFF
    the right channel carries whatever the high lane holds. That is what the
    switch is for.
  * **The mute is the whole reason the device has state.** Covox and TurboSound
    decode the same address, so each renders the other's traffic as garbage.
    `cx_en = live & ~psg_hold`:
    - `live` — **"the port is being *modulated*", not "the port was
      written".** This is what keeps the **never-reset** latch off the ladders:
      at power-on `port_data` reads 0, which **inverts to `b = 255` = +32767**,
      and a finished program leaves its last sample behind. With the slot
      disabled the mixer contributes *exactly* zero, so `audio_ns6` stays on
      its exact-zero fixed point and silence keeps producing no pin activity —
      the property the −85.8 dBFS measured idle floor and the CMT anti-echo
      argument both rest on.
      The predicate is **a write that CHANGES the code, inside a ~43 ms
      one-shot that is already running** — i.e. at least two writes within
      43 ms, the second one moving the DAC. The one-shot itself
      (`idle_cnt`) stays **value-blind**: any write reloads it, because only
      *arming* may demand a change — a sample run that repeats a value must
      not drop out mid-note.
    - `psg_hold` — a ~0.7 s retriggerable hold on `bk_turbosound`'s new
      **`ts_snd`** output. Load-bearing: a PSG square wave is zero for half of
      every period and goes silent for every rest, so without it the Covox
      would unmute between pulses onto whatever AY register data the latch
      holds — a click per note.
  * **`ts_snd`, not `ts_act`, and taken before the ×15 stage.** `ts_snd` is
    `|lsum | |rsum`, so it **leads `ts_l`/`ts_r` by one cycle** and the mute is
    already asserted on the cycle the PSG sample first becomes non-zero — the
    two sources can never both reach the mixer's stage 0. `ts_act` (`~R7[5:0]`,
    the channel-**enable** bits, `pLed[4]`) would be both insufficient and
    harmful: a channel with tone AND noise disabled passes its volume register
    through as DC (`ym2149.sv:355-357`) — that is how AY "digi" playback works
    — so `ts_act = 0` does not imply silence and the enable bits alone would
    not close the headroom proof; and a player that exits leaving channels
    enabled at volume 0 would mute the Covox until the next reset.
  * **The arming rule is a HARDWARE-FOUND FIX — CONFIRMED ON THE BOARD
    2026-08-01 (the OS boots silent) — and the first cut was wrong.**
    Phase 12 shipped `cx_en = (idle_cnt != 0) & (psg_cnt == 0)` — "a write
    happened recently". On the board the OS **clicked several times per boot**.
    The trace: MONITOR's system-init routine `MIDMBK` ends with
    ```
    CLR  @#APORT            ; APORT = 177714   (d1.mac:135,270)
    ```
    a **single isolated write**, of the one value that inverts to `b = 255` =
    **+32767 on both lanes** — the loudest sample the map can produce. It is
    the only 177714 write in the MONITOR sources, and `MIDMBK` runs at boot
    *and* on every return from a user program. So one `CLR` unmuted the slot
    for the full 43 ms: a pair of ~−3.8 dBFS DC edges on both ladders (through
    5/8 and the shaper, ladder code 24 → 44 → 24), every time.
    **A real Covox is never *played* by one write**, so the fix belongs in the
    predicate, not in a filter: `live` now takes a *changing* write inside a
    running one-shot. `sim/covox` section 10 walks the exact MONITOR sequence
    (one `CLR`, then two, then a constant-code burst), and **mutation X19 is
    the pre-fix predicate restored verbatim** — it must die in 10a.
    **Accepted consequence:** a program that writes a constant code forever,
    never changing it, is inaudible. That is what a real Covox does too — a
    passive DAC into an **AC-coupled** amplifier, where a constant code is a DC
    the coupling capacitor removes and only the transitions are heard. It costs
    nothing in `test/sndtestcx.mac`: `LADDER[0]` is `0200`, the DAC's own zero,
    and every later step changes the code and arms on its first write.
    The alternatives were weighed and rejected — a DC blocker (BkEmu's 10 Hz
    high-pass, BKemu's running-mean `DCOffset`) only *decays* the thump instead
    of removing it, and would cost a wide accumulator plus saturation, re-open
    the headroom proof and threaten `audio_ns6`'s exact-zero fixed point at
    70 % LE and +0.102 ns; MiSTer's hard user-selected mode has no spare DIP.
  * **KNOWN, BOUNDED ARTIFACT — accepted, not engineered around.** An AY
    program's *setup* phase writes registers before any channel sounds, so for
    that window `ts_snd` is low and the Covox renders those register writes as
    samples: a faint click of order 100 µs at the start of a TurboSound
    program. It is bounded by how long a setup takes, it cannot recur while
    music plays, and **every alternative discriminator collides with stereo
    Covox**, which uses word writes exactly as the AY register latch does. If
    it proves audible on the board the escape hatch is MiSTer's — a hard
    user-selected mode — never a heuristic.
  * **The gain budget was re-opened and closed again for free**, because the
    two devices are mutually exclusive. The Covox emits BkEmu's raw ±32767 and
    the **scale is a compile-time `SLOT_GAIN` nibble (5/8) in `bk_audio`**, not
    a constant in the device — `audio_mixer`'s sample domain exists precisely
    so a BkEmu map can transcribe 1:1:
    ```
    speaker           +/- 8192
    TurboSound           0 .. 22950
    Covox           -20480 .. +20479          (+/-32768 at 5/8)
    worst channel   max(22950, 20480) + 8192 = 31142  <=  FS_SAT = 31744
    ```
    the **same 31142** Phase 11 computed. **5/8 is provably the maximum**: at
    6/8 the bound is 24576 and 24576 + 8192 = 32768 > FS_SAT. And
    32768×5/8 = 20480 = 20×1024 exactly, so a Covox parked at a DC still lands
    on a **static** `audio_ns6` code — the `SPK_LVL` multiple-of-1024 property,
    generalised. Menestrel must re-open this once more, and cannot rely on the
    same exclusion unless it mutes on `ts_snd` too.
  * **One gate, not two.** `cx_l`/`cx_r` keep carrying the sample while muted;
    the mixer's runtime slot enable is the single mute mechanism. Zeroing in
    the device as well would be logic no mutation could kill — the
    `bk_turbosound` `lc1`/`rc1` precedent. **The PSG term of `cx_en` is
    deliberately combinational**, and that half is load-bearing: a registered
    `psg_cnt == 0` would arrive a cycle after `ts_l` goes non-zero. The **arm**
    term is a flop (`live`), which is safe in the only direction that matters —
    it can make an *unmute* one cycle late, never a mute — and it **shortens**
    the cone, since the `IDLE_BITS`-wide `!= 0` that used to sit on `cx_en` now
    feeds `live`'s D input.
  * **Reset is `~init_n`** (2-FF synced) ORed with the power-on reset — the
    standard BK peripheral rule, so a RESET instruction silences the Covox. It
    does **not** clear the 177714 latch (`qbus_mem`'s never-runtime-reset
    state; a real Covox is a passive DAC with no reset pin), so after nINIT the
    sample reappears but the slot stays muted until the next write.
  * **Cost and timing (confirmed) — Covox costs +268 LE, and the STA chase
    happened ON THE NEW SIGNAL, which is the interesting part.**
    8,184 → **8,452 LE (68 % → 70 %)**, M4K unchanged at 3/52, pins unchanged
    at 98/173, no new PLL. Most of it is the two one-shot counters (48 flops
    plus their decrement and compare) and the two extra mixer slots; the byte
    map itself is free.
    **The first build came in at sys_clk −0.639 ns, TNS −12.003**, and unlike
    Phase 11's chase this one was NOT placement fragility on an untouched
    module — it was the increment's own new path:
    `bk_turbosound|lc1[*] → bk_covox|psg_cnt[*]`. A combinational
    `(|lsum)|(|rsum)` — an OR-reduce of two 11-bit ADDER outputs — was driving
    the ENABLE of a 26-bit counter in another module across the chip.
    **The exact rule this tree already had, for the third time**: keep
    translate outputs out of a register's enable cone (`rdata_oe`, then
    `wdata_o`, now this).
    **Cured structurally, and for free**: `ts_snd` is now a FLOP fed by the
    predicate taken one stage earlier, off the CHANNEL outputs
    (`(|a0)|(|b0)|(|c0) | dual_act & (…)`). The fold is non-negative and every
    term monotone, so that is the same predicate; and because `lc0`/`rc0`
    register `a0..c0` on the same edge this flop registers, **the one-cycle
    lead is preserved exactly** — which `bk_turbosound_tb` checks every cycle,
    with mutation D14 for the late variant. **Result: −0.639 → +0.102 ns,
    TNS 0**, and the Covox is off the critical path entirely.
    ⚠️ **+0.102 ns is THIN, and that part IS placement.** The worst path is
    now the chronic pre-existing cone this file predicted —
    `ram_init|filling → sdram_arbiter|cmd_addr[*]`, with
    `mem_mapper|mon_en → cpu_sdram_dp|addr_o[*]` right behind it at +0.148 —
    neither of which this increment touched, and which stood at +0.528 before
    it. +268 LE re-placed them. **The next increment must budget for a real
    chase there**, and the cure is the documented one: re-register the
    quasi-static high-fanout selector (`fill_active`) locally — noting that
    doing so shifts the port-0 handover by a cycle, so it needs `sim/raminit`
    re-run, not a drive-by edit. **Never an SDC exception, never SEED 3.**
    **The arming fix then bought that margin back, which was not the plan.**
    `+33 LE` (8,452 → **8,485, still 70 %**; M4K, pins and the PLL unchanged)
    and **sys_clk +0.102 → +0.471 ns, TNS 0**, 0 errors. Part is the shortened
    cone — the `IDLE_BITS`-wide `!= 0` came off `cx_en` and went onto a flop's
    D input — and part is placement luck, in the direction this file has
    usually been bitten in. **The chase it predicted did not have to happen:**
    the worst path is now `sd_backend|st.A_TAIL → st.S_CSD_DATA` at +0.471,
    with `smk_ide|w_inv[*] → ptr[*]` behind it at +0.602, and neither
    `ram_init|filling` nor `mem_mapper|mon_en` is in the top any more. The
    prediction stands for the *next* increment: it is placement, not structure.
  * Oracle: **`sim/covox/run.sh`**, one leg, 19 mutations. The rate is split
    between two checks — 2²² and 2²⁶ `sys_clk` are not simulable, so a second
    instance pins the shipped **parameter defaults** while a scaled instance
    pins the **behaviour**. `sim/ts` gains one assertion (that `ts_snd` leads
    the sample) and mutation D13; `bk_audio_tb` gains the Covox pan section,
    the mute section and the re-opened budget, with mutations A3/A4/A5.
    **Section 10 is the MONITOR `CLR @#177714` regression** and X14–X19 are its
    mutations, X19 being the pre-fix predicate itself.
    `test/sndtestcx.mac` is the hardware acceptance program (pdpy11, with a
    `.wav` so it loads over the CMT jack).
