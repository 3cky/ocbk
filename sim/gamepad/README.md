# sim/gamepad — the USB gamepad oracle

The pinned contract for `src/peripheral/bk_gamepad.sv`, a USB HID gamepad
presented as the BK's joystick word on **0177714**. Run with `./run.sh` (part of
`make sim`) or `./run.sh --mutate`.

## What this module is

A pure level translator, the USB twin of `bk_joystick`: it takes the ten
`game_*` outputs `usb_hid_host` already produces and puts them in BkEmu's bit
order, gated on a pad actually being enumerated. It holds nothing the CPU can
see, decodes no address and never touches the bus — `pad_word` is OR-ed into
`joy_word` at the **top level**, exactly as `mouse_word` is, so `qbus_mem` is
untouched by the feature and every timing golden stays byte-identical.

```
bit 0 = UP      <- game_u          bit 4 = START   <- game_sta
bit 1 = RIGHT   <- game_r          bit 5 = A       <- game_a | game_x | game_tr
bit 2 = DOWN    <- game_d          bit 6 = B       <- game_b | game_y | game_tl
bit 3 = LEFT    <- game_l          bit 7 = SELECT  <- game_sel
bits 15:8 = 0 (always)
```

Two things about that table are decisions, not translations, and the leg pins
both. **Six buttons fold onto two**: X and the RIGHT shoulder trigger join A, Y
and the LEFT trigger join B — a pad has four face buttons plus two shoulders and
the BK has two fire bits, so everything a thumb lands on should fire. **START and SELECT are real here** — a DE-9
pad has no source for bits 4 and 7 and `bk_joystick` ties them 0, so a USB pad
is the only thing in the design that can reach the full `0o377`.

**Player 1, always.** The board has one USB-A port, so the upper byte is 0 — the
same argument as `bk_mouse`'s read word. A USB pad and a DE-9 pad on port B give
two players.

## The four things it can get wrong

1. **The remap.** The host names its outputs `l/r/u/d`; the BK word is
   `U,R,D,L`. A pass-through is wrong in a way that still "works" for UP, so all
   ten inputs are walked individually and checked for *which* bit they land on.
   Same error surface, same treatment, as `sim/joystick`'s twelve.

2. **The type gate.** `usb_hid_host` reports **one** `typ`, so `bk_mouse`
   (`typ == 2`) and `bk_gamepad` (`typ == 3`) must never both contribute to
   `joy_word`. Section 2 drives every input high under `typ` 0, 1 and 2 and
   requires zero. The **other direction** is asserted by `sim/mouse`'s `gate`
   leg, which requires `typ == 3` to contribute nothing to `mouse_word` — both
   halves pinned, each in the oracle that owns its module.

3. **The arming flop.** The host clears `typ` on disconnect but **not** the
   `game_*` levels — they hold the last report's values indefinitely, since only
   the power-up `initial` (hook H5) ever zeroes them. Without the flop a
   re-plugged pad would present the previous session's buttons for up to a poll
   interval. Sections 3 and 7 are the whole reason it exists: enumerated but not
   yet reported reads 0, and so does a re-plug whose stale levels are still high.

4. **Whole frames.** The payload must be latched at the report pulse, never
   sampled — the board bug below, and the one item on this list that hardware
   found rather than review.

## The board bug of 2026-08-16 — this module's half

On hardware, with nothing pressed, **BK bit 6 flickered at random** — and did not
on a PC. Two independent causes; only one of them belonged here.

**This module's half: the payload was sampled, not latched.** `game_*` are levels
only *between* reports. While one is arriving the wrapper rewrites them byte by
byte as `rcvct` walks 0→7, spanning ~43 µs ≈ 170 `cpu_clk_n` cycles, so a free
sample shows the BK half-decoded frames. It is now latched at the `report` pulse.
Section 7b pins it: moving every input with **no** report must change nothing at
all. After hook H7 this is **load-bearing rather than tidy** — H7 gates the
report *pulse* and not the decode, so the wrapper's level outputs are still
transiently wrong during a corrupt frame, and latching at the pulse is precisely
what makes that invisible.

**The other half was corrupt packets, and it is not fixed here.** This host
checked no CRC, so a frame corrupted on the wire was decoded as a real report.
That is fixed at the source by hook H7 in `usb_hid_host.v`, and `sim/usb`'s `crc`
leg owns the contract.

### The filter that was wrong, and why it is recorded

The first attempt put a **two-frame agreement filter** here: present a payload
only after two consecutive reports agree. The board disproved it. The fault
turned out to be **data-dependent** — it tracked which button was held (`A` and
`LEFT` flickered, `X` and `RIGHT` did not) — so it was *systematic*, not random
noise. Consecutive frames therefore agreed on the same wrong value and the filter
only thinned the symptom, which is exactly what the second board run showed.

It is worth recording as a general trap: **a repeat-agreement filter is only
valid against independent errors**, and "it got better" is not evidence that a
fix was right. The filter also cost ~10 ms on every press and release; both it
and that latency are gone.

## Why there is no toggle handshake

`bk_mouse` needs one because `mouse_dx/dy` self-clear the cycle after `report`,
so they must be captured *on* the pulse. Once latched, this payload moves only
at the ~10 ms poll rate, so it is genuinely quasi-static and a plain 2-FF sync
per bit carries it — what `bk_joystick` does with twelve asynchronous DE-9 pins.

Bit skew across that crossing is **accepted**, as it is there. A payload change
can land either side of one `cpu_clk_n` edge, so a single BK read can in
principle see a torn word, and the next read is correct. A pad is not a bus.

## The synchroniser depth is a continuous invariant

`pad_word` must equal `pl_hold` delayed **exactly two** `clk` posedges, checked
on *every* edge of the run rather than in one section. Hand-counted edges were
tried first and were the wrong tool: once the agreement filter landed, an input
change and a payload change stopped being the same event, and the count raced
the report helper. Section 8 now only guards the monitor against vacuity.

## Two properties of the testbench that are load-bearing

Both exist because a mutation survived without them, and both correspond to a
real board condition rather than a simulation convenience:

- **Every input starts held, at `t=0`.** "All levels high with nothing
  enumerated" is the state a board powers up into after a pad has been used and
  unplugged, since the host never clears `game_*`. Starting them released makes
  the arming flop's power-up value unobservable — a wrongly-armed flop would leak
  a *zero* payload and look correct.
- **`clk` takes its first edge before `usb_clk`.** In `ocbk_top` the two come
  from different dividers with no defined start relationship, so the BK side can
  sample this module before the USB side has run at all. A design that emits X in
  that window is a real hazard, and the X watchdog is what catches it.

The upper byte is checked on **every** clock edge rather than per-section:
player 2 must be unreachable by any input combination, not merely by the ones a
section happens to drive.

## What nothing here tests, deliberately

- **The report decode** — which byte of a HID report carries which button.
  `sim/usb` owns it: its `pad` legs drive real low-speed USB traffic through the
  vendored `usb_hid_host` and check the ten `game_*` outputs, including the
  `pad_real` leg built from captured frames of the reference pad. Everything
  upstream of this module's inputs is that oracle's contract.
- **The bus side** — that a read of 0177714 returns `joy_word` at all, and the
  `!sel2_n` gate that keeps it out of the SMK I/O-page overlay merge. Those stay
  pinned where they already were: `sim/audio`'s `spk_capture_tb` section 10
  against the real `qbus_mem`, and `sim/smk` section 2. Device here, decode
  there, seam elsewhere — the `sim/joystick` and `sim/covox` precedent.
- **Which physical button a player calls "A".** The host's `game_a`/`game_x`
  naming follows the report bit order, not the legends printed on any particular
  pad. Since X joins A and Y joins B, a pad whose face legends are rotated still
  fires both triggers; only the START/SELECT pair could read swapped, and that is
  a hardware observation, not a simulable one.

## Mutations

22, `G1`–`G22`, each rewriting one property of a **copy** of the real RTL (the
`sim/evnt` idiom — no inline replica to drift) and required to break the leg:
the type gate (G1–G2), the arming flop and whole-frame latching (G3–G8), the
remap (G9–G13), X/Y joining A/B (G14–G15), and the read word and synchroniser
(G16–G19).

**`G7` is this module's board-bug regression**: it samples the levels instead of
latching them at the pulse. `G8` is its neighbour — latching on every clock
rather than on the report.
