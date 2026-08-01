# sim/covox — the Covox oracle

The pinned contract for `src/audio/bk_covox.sv`, the 8-bit DAC on **0177714**.
Run with `./run.sh` (part of `make sim`) or `./run.sh --mutate`.

Like `bk_turbosound`, the device decodes the BK's programmable parallel port
through the Phase-10 write-capture seam in `qbus_mem`. `qbus_mem` itself is
unchanged by this increment — comment edits only — which is what keeps every
timing golden in the tree byte-identical.

---

## The reference

**BkEmu's `Covox.java` is the contract**, per the standing rule that BkEmu wins
on BK register/software semantics:

```java
int l = ~value & 0xff;
int r = (~value >> 8) & 0xff;
if (!isStereoMode) r = l;
toPcmSampleValue(b) = ((b + Byte.MIN_VALUE) << 8) | b
```

Low byte = left, high byte = right, of the *same* word — one address, two
lanes. The port inverts, so the device complements what `qbus_mem` hands it
(which is the BK-true value the program wrote). The byte map is exactly linear:
`((b-128)<<8)|b == 257*b - 32768`, and since `257*b` is `{b,b}` the whole map
is one inverted bit — the device carries **no** arithmetic and **no** scaling.

The headroom that keeps the mixer from saturating is a compile-time
`SLOT_GAIN` nibble (5/8) in `bk_audio`, not a constant in the device.

## Two deliberate divergences from BkEmu

**1. Per-lane hold, not `value << 8` zero-fill.** On a byte write BkEmu passes
the other lane as 0, so its model reads the *other* channel as `0xFF` — full
scale. That is an artifact of its `writeMemory(value << 8)` signature, not of
the hardware: 177714 is a byte-lane-strobed latch and holds the lane that was
not written, which is exactly what `qbus_mem` does. Same call, and the same
reasoning, as the 177716 `stop_block` lane rule — the real WR1/WR2 byte
strobes win over a BkEmu lane artifact. **Section 3 is the discriminator**, and
mutation X2 is its teeth.

**2. Stereo/mono is DIP 5, not an autodetect.** BkEmu latches stereo on a word
write whose inverted high byte is neither `0x00` nor `0xFF`, and decays back to
mono after 3 s. Both halves exist because a BkEmu device *object* outlives the
program that programmed it — the identical argument that made Phase 11 drop the
TurboSound dead-man timeout. Here it is a switch, read live.

## The arbitration, which no reference has

Covox and TurboSound decode the same address, so with both present each renders
the other's traffic as garbage. The PSGs win: `cx_en = live & ~psg_hold`, where
`live` means **the port is being *modulated*** — a write that CHANGES the code,
inside a ~43 ms one-shot that is already running — and `psg_hold` is a ~694 ms
hold on `bk_turbosound`'s `ts_snd`. The one-shot itself is **value-blind**: any
write reloads it, because only *arming* may demand a change, or a sample run
that repeats a value would drop out mid-note.

Both halves are load-bearing and both have a section:

* **`live` (sections 7 and 10)** is what keeps the never-reset latch off the
  ladders. At power-on `port_data` reads 0, which **inverts to `b = 255` =
  +32767** — full positive scale on both channels. Section 1 asserts both
  halves of that: the sample really is at full scale, *and* `cx_en` is low.
  Without the one-shot the board would sit on a full-scale DC from power-on,
  and the measured −85.8 dBFS idle floor would be gone.
  **Why arming takes a *change*, not just a write — this is a hardware-found
  fix.** Phase 12 shipped `cx_en = (idle_cnt != 0) & (psg_cnt == 0)`, and the
  board clicked several times per boot. MONITOR's system-init routine `MIDMBK`
  ends with a lone `CLR @#APORT` (`APORT = 177714`, `d1.mac:135,270`) — one
  isolated write, of the one value that inverts to full positive scale on both
  lanes — and it runs at boot *and* on every return from a user program. A real
  Covox is never *played* by one write. **Section 10 walks that exact sequence**
  and **X19 is the pre-fix predicate restored verbatim**. Accepted consequence:
  a constant code written forever is inaudible, which is what a real Covox does
  too — its amplifier is AC-coupled, so only transitions are heard.
* **`psg_hold` (section 6)** must survive the gaps. A PSG square wave is zero
  for half of every period, so `ts_snd` arrives as a pulse train; without the
  hold the Covox would unmute between pulses onto whatever AY register data the
  latch happens to carry — a loud click per note. Section 6c is that case.

`ts_act` (the R7 channel-enable bits, `pLed[4]`) is deliberately **not** used:
a YM2149 channel with tone *and* noise disabled passes its volume register
through as DC — that is how AY "digi" playback works — so `ts_act = 0` does not
imply silence, and a player exiting with channels enabled at volume 0 would
mute the Covox until the next reset.

---

## The leg

`bk_covox_tb` drives `port_wr`/`port_data` exactly as the real capture produces
them, with the write tasks modelling the **latch** (each touches only the lane
its bus cycle touches) rather than the device's expectation of it.

| § | what it pins |
|---|---|
| 0 | the shipped `IDLE_BITS`/`PSG_BITS` defaults |
| 1 | reset state; the power-on latch really is at full scale; muted until a write |
| 2 | the inversion and the byte map at 0/1/64/127/128/129/192/254/255, both lanes |
| 3 | **per-lane hold** — an even-byte write holds the right lane, an odd-byte write holds the left |
| 4 | the mono fold, including that an odd-byte write is inaudible in mono |
| 5 | DIP 5 is **live** — it takes effect with no write and no reset |
| 6 | the PSG mute: it fires, it is held for the right length, and it survives a pulse train |
| 7 | the idle one-shot: it expires at the right length, and it **retriggers** |
| 8 | nINIT clears the device but **not** the latch; the slot stays muted until a fresh burst |
| 10 | **the MONITOR `CLR @#177714` regression** — a lone `CLR` (still at full scale, still muted), two `CLR`s in a row, a constant-code burst, and one changing write that does unmute |
| 9 | anti-vacuity: ≥ 12 distinct samples, both rails reached, the channels differed, ≥ 2 mute/unmute events |

### Why one leg

`bk_turbosound` has the same shape and the same single leg. The **seam** — one
strobe per bus write, BK-true polarity, the odd lane leaving the other half
stale — is pinned independently by `sim/audio`'s `spk_capture_tb`, which drives
the *real* `qbus_mem` (mutations Q1–Q5 in `sim/run_audio.sh`). This leg models
that behaviour and tests the device against it.

### What the mixer side owns

Not tested here, on purpose: the 5/8 slot gain and its headroom arithmetic, the
pan (slot 5 = L, slot 6 = R), and the fact that `cx_en` actually zeroes the
slot. All three are `sim/run_audio.sh` leg 1's job (`bk_audio_tb`, mutations
A3/A4/A5). The device deliberately does **not** zero its own outputs when
muted — one gate, not two, the `bk_turbosound` `lc1`/`rc1` precedent.

### The known limit of this leg

The one-shot rates are split between two checks. 2²² and 2²⁶ `sys_clk` (43 ms
and 694 ms) cannot be simulated, so the tb builds a second instance with the
shipped defaults and asserts the **parameter values**, while all **behaviour**
runs on a scaled instance (2¹⁰ / 2⁸) whose measured periods are checked against
its own overrides. A mutation of either the default (X12) or the counter logic
(X11) dies; a mutation of *both together* would not. Note the tb deliberately
makes the idle one-shot longer than the PSG hold — the inverse of the shipped
ordering — so one write keeps the device live right through a hold measurement.

## Mutations

19, all killed. X1–X4 the map (inversion, right lane, the −32768 offset, the
low-byte replication); X5–X6 mono (fold inverted, DIP 5 ignored); X7–X11 the
arbitration (mute dropped, no hold, arm gate dropped, `cx_en` stuck high,
one-shot not retriggerable); X12 the shipped rate; X13 nINIT; **X14–X19 the
arming rule** — arms on any write, the running-one-shot precondition dropped,
`last_data` never updated, the compare inverted, `live` never clearing, and
**X19, the pre-fix predicate itself**, which dies in section 10a.

Each is a `sed` against a **copy** of the real RTL — no inline replica to
drift — and a `sed` that fails to apply is a hard error, never a silent skip.
