# sim/ts — Turbosound (2× YM2149) oracles

The pinned contract for `src/audio/ym2149.sv` and `src/audio/bk_turbosound.sv`.
Run with `./run.sh` (part of `make sim`) or `./run.sh --mutate`.

The device decodes **0177714**, the BK's programmable parallel port, through
the Phase-10 write-capture seam in `qbus_mem`. It is the first consumer of
that seam; `qbus_mem` itself is unchanged by this increment, which is what
keeps every timing golden in the tree byte-identical.

---

## The reference, and why it is not byte-pristine

`ym2149_ref.sv` is MiSTer's `BK0011M_MiSTer/rtl/ym2149.sv` (MikeJ 2005,
Sorgelig 2016-2019). **It is the authority: where it and the shipped copy
disagree, it is right and the shipped copy gets fixed. Never regenerate it
from `src/audio/ym2149.sv`** — the `sim/ref014` and `sim/ref037` rule.

It carries 46 changed lines against upstream, in three groups, all enumerated
in its own header and all mechanical:

* **A — Icarus-blocking SystemVerilog-2009.** `iverilog -g2012` errors out on
  `reg [7:0] ymreg[16]`, `ymreg <= '{default:0}`, `'1`, `'0`.
* **B — declaration-before-use.** Icarus binds in source order, so three
  `assign`s and one `reg` declaration move. Text only.
* **C — power-up initialisers on the un-reset state.** **Required, not
  cosmetic.** `poly17`'s re-seed term is `!poly17`, which is X when `poly17`
  is X, so from an X start the LFSR never recovers and the *entire core* stays
  X for the whole simulation — no tone, no noise, and a diff that passes
  vacuously. `= 0` is also exactly what the hardware does: Cyclone FFs power
  up to 0 and Quartus honours the initialiser.

Icarus **does** accept the upstream's `wire [7:0] volTable[64] = '{...}` and
`wire [11:0] tone_gen_freq[1:3]`, so the reference keeps them verbatim and
only the shipped copy rewrites them. That asymmetry is the point: the risky
rewrites exist on exactly one side of the diff.

## Why the shipped copy differs further (group D)

Quartus II 11.0 needs four more rewrites, marked inline in
`src/audio/ym2149.sv`: block-local `reg`s hoisted to module level, the
`tone_gen_freq` array split into three wires, the three-iteration tone loop
unrolled, and `volTable` turned into a `function` + 64-way `case`.

**The table is the whole reason leg 1 exists.** A single wrong hex digit there
is a quietly wrong volume step, not a failure — nothing else in this tree
would ever notice.

---

## Leg 1 — `ym2149_equiv_tb` (the authority)

Both cores elaborated into one testbench (the reference declares `YM2149`, the
shipped copy `ym2149` — Verilog is case-sensitive, which is why the module
names differ; **do not rename either**), driven with identical stimulus, and
compared on `CHANNEL_A/B/C`, `ACTIVE` and `DO` **every clock** with `!==` so an
X on one side is an error.

`CE` is a **/7** enable — coprime with the core's own /8 and /16 dividers, so a
mis-gated `CE` in the adaptation cannot hide behind a harmonic.

Stimulus: all 16 fixed volumes on all three channels; tone period 0; short
periods (the burst that earns the edge counts); noise at eight periods
including 0; **all 64 `R7` mixer patterns**; all 16 envelope shapes at two
envelope periods; `R13` retrigger; envelope period 0; **both `MODE` and both
`SEL` values, each with a full envelope sweep *and* a fixed-volume sweep**; the
`DO` read path and the `addr[7:4]` write guard; a mid-flight `RESET`; then a
3000-write pseudo-random soak. ~356k cycles compared.

**Anti-vacuity is checked, because two silent cores compare equal forever:**
the run requires ≥150k cycles compared, ≥20 distinct `CHANNEL_A` code buckets
and ≥600 edges on each channel. Thresholds sit ~2× below what the stimulus
actually achieves (356k / 35 / 1304-957-791); they exist to catch a stimulus
that stopped driving the cores, not to pin an exact number.

### The MODE=1 lesson, recorded so it is not re-learned

An earlier version of section 8 held `MODE` at 1 for 3000 clocks with the
envelope period left at 0x0040 — long enough for `env_vol` to advance about
**1.7 steps**. The upper 32 table entries are reachable *only* through the
envelope (a fixed 4-bit volume maps to `{v[3:0],v[3]}`, which hits just 16 of
the 32 levels), so most of the AY8910 half of the table was never exercised
and a mutation of entry 50 **survived**. Section 8 now sweeps a period-2
envelope across every `MODE`/`SEL` combination. If that section is ever
shortened, re-run the full table sweep below.

### Full volume-table coverage (authoring-time, not in `run.sh`)

During authoring, leg 1 was run against **all 64 single-bit table mutations**
— flip the low bit of each entry in turn. **All 64 were killed**, so every
entry is genuinely exercised. That sweep takes ~4 minutes, so `run.sh` carries
four representative mutations instead. Re-run the sweep if leg 1's stimulus is
ever reduced.

---

## Leg 2 — `bk_turbosound_tb` (the device contract)

Drives `port_wr` / `port_data` / `port_word` / `port_be` exactly as the real
capture produces them: BK-true polarity, one strobe per bus write, and the odd
lane leaving the low half **stale**.

**The observability trick.** Every check runs with tone and noise disabled, in
which case the core's mixer term degenerates and each channel emits its
programmed volume as a steady DC level. So the register file reads out
directly on `CHANNEL_A/B/C` within a cycle and the leg needs no tones, no
waiting and no fuzzy expectations.

**Only two volume-table entries are assumed** — volume 15 → 255 and volume 0 →
0, the endpoints. Everything else about the table is leg 1's job, so this leg
cannot fail for a reason that belongs to the core.

Sections:

1. reset state
2. the protocol: word = address, even byte = data; the ACB pan proven
   channel by channel (A left, C right, **B on both**) and the full-scale
   22950 bound
3. the **odd lane**: a 0177715 write must write `0xFF`, not the stale low half
   — with a control write of `0xAA` proving the check has teeth
4. the **4-bit address mask**: `0x59` selects register 9, per BkEmu's
   `currentRegister = v & 0x0f`
5. `0xFE` activation, `0xFF` return, per-chip steering
6. the shared register pointer; and **6b**, that a chip select *clobbers* it
7. full-scale headroom with both chips
8. `nINIT` reset
9. the **/56** PSG clock enable, measured

---

## The BkEmu contract, and the two places it is not followed

`BkEmu`'s `Ay8910.java` is the reference — it is the only one of the two
sources that implements Turbosound at all (MiSTer's BK core has a single PSG).

**Divergence from MiSTer, deliberate:** MiSTer wires `BC = bus_wtbt[1]`, so an
odd-byte write is an *address latch* there and a *data write* here. BkEmu wins
— this repo's standing rule for BK register semantics.

**Divergence from silicon, deliberate:** the address latch is masked to 4 bits.
A real chip latches all eight and then ignores the following data write when
the high nibble is non-zero. BkEmu masks; we match BkEmu.

**Two pieces of BkEmu are NOT reproduced, and they are the same piece of
behaviour:** the 3-second Turbosound dead-man timeout, and the reset of the
secondary chip at activation. Both exist because a BkEmu chip *object*
outlives the program that programmed it. In hardware `nINIT` does that job,
and dropping the timeout makes the activation reset **unreachable** —
`dual_act` is cleared only by the reset that also clears both chips, so a
"first 0xFE" can never find a dirty secondary. Implementing it would be dead
logic no oracle could kill. **The two go together: if the timeout is ever
added back, the activation reset has to come with it.**

---

## Mutation testing — 15 killed, and one honest gap

`--mutate` rewrites one property of a **copy** of the real RTL (the `sim/evnt`
idiom, so there is no inline replica to drift) and requires the named leg to
break. A `sed` that fails to apply is a hard error, not a silent skip.

E1-E4 hit the core (table entry, the AY-half entry that pins `MODE=1`
coverage, a mis-wired unrolled tone arm, a dropped power-up initialiser).
D1-D10 and D12 hit the device (address/data sense, the odd lane, the `0xFE`
escape, the single-chip branch, the ACB pan both ways, the ×15 scale, the CE
rate, `nINIT`, data-write steering, the address mask).

**The address-latch broadcast is deliberately not covered.** `bdir0` asserting
for a word write *while the secondary is selected* cannot be killed, because
it is behaviourally **redundant**: the only route back to the primary is a
`0xFF` word write, and per BkEmu that write itself clobbers the register
pointer to 15, so the primary's pointer is always rewritten on the way back in
and never observed stale. The broadcast stays in the RTL anyway — it is
BkEmu's actual model (**one** shared `currentRegister` field, not one per
chip), and the redundancy that makes it unobservable depends on `0xFF` being
the only way back, which is a fragile thing to rely on. Section 6b pins the
pointer clobber, which is the observable half of the same behaviour.
