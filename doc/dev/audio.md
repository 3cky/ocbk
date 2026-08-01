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
    would leave the codes rattling. Covox and Menestrel must re-open this and
    find their share of what is left.
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
    177714 already replies via `sel_io`. Read merge deferred (see Open).
    **Since Phase 11 `bk_turbosound` consumes it** (it was dangling and free
    through Phase 10); Covox and Menestrel will hang off the same four wires.
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
