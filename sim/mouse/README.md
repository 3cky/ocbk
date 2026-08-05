# sim/mouse — the Марсианка mouse oracle

The pinned contract for `src/peripheral/bk_mouse.sv`, a USB HID mouse presented as
the BK's **УВК-01 «Марсианка»** on **0177714**. Run with `./run.sh` (part of
`make sim`) or `./run.sh --mutate`.

## The reference is the schematic, not the emulator

This is the one place in the tree where **BkEmu has nothing and GID's emulator is
not the authority**. BkEmu does not implement the mouse at all; GID's is the only
software implementation, and its own documentation disavows it — *«Работает
отвратительно. Поэтому лучше не включать»*. So the contract here is derived from
the УВК-01 schematic sheets (`Устройство логическое УЛ УВК`):

- 4× АЛ107Б LED / ФД-265 photodiode pairs = **two axes, two phases each**. Each
  phase passes a К561ЛП2 XOR wired as a slicer (1.5 MΩ feedback = hysteresis) and
  clocks one half of a К561ТМ2 D flip-flop. **Two flip-flops per axis**; their
  `Q`/`/Q` are buffered by a К561ПУ4 — six channels, i.e. four `Q` plus two `/Q`,
  exactly what the pairing needs — and cross-combined by four КМ133ЛА15 NANDs
  into the four direction lines.
- Connector `X` (`Розетка ОНП-КГ-56-10`), from sheet 2's own table:
  `1 = "У"(вверх)`, `2 = "X"(вправо)`, `3 = "-У"(вниз)`, `4 = "X"(влево)`,
  `5 = КН1`, `6 = КН2`, **`9 = СБРОС`**, `10 = +5В`, `7,8 = Общ.`

**Two things in GID fall away as artifacts**, and the legs here assert the
opposite of both:

1. **Nothing arms a read.** The NAND outputs sit on the connector
   unconditionally — there is no output enable anywhere in the device. GID's "a
   rising edge of write bit 3 arms exactly one read" has no counterpart in the
   circuit.
2. **СБРОС is a level, not an edge.** Pin 9 wires straight to the ТМ2 `R` inputs
   with no gate between, and `S` is grounded. While it is asserted the latches
   are *held* cleared and movement is lost, not queued. GID clears on a
   wall-clock timer instead — and that timer is 10 ms at one call site and 40 ms
   at another in the same program, which is what first suggested it was an
   artifact.

## Legs

| leg | what it pins |
|---|---|
| `sticky` | each direction latches and **holds** until СБРОС; all four walked independently, since the bit map is the error surface here just as the `U,D,L,R → U,R,D,L` remap is in `sim/joystick`. Includes HID `+y` being ВНИЗ, and bits 4, 7 and the whole upper byte having no source. |
| `reset` | СБРОС is a **level**: it clears, and keeps clearing while held. Plus the **polarity** — the port inverts, so the program writing bit 3 = **0**, including MONITOR's lone `CLR @#177714`, is what asserts it. |
| `step` | the encoder-resolution divider: sub-STEP motion latches nothing, the sub-step remainder is kept so two half-steps make a step, and a large delta leaves **no backlog**. |
| `buttons` | КН1/КН2 are **levels** on bits 5/6, unaffected by СБРОС even while it is asserted — they are plain switches, not in the reset's path. |
| `gate` | only an enumerated **mouse** contributes: `typ` 0/1/3 all give a zero word, so a pad, a keyboard or an empty port leave the DE-9 joystick word untouched. |

## The bug this oracle caught

Worth recording, because it is the one genuinely non-obvious thing in the design.
The first version carried a **multi-step accumulator backlog** (clamped at eight
steps), on the reasoning that no motion should ever be lost. That is wrong: a
report carrying `dx = 40` describes motion that *already happened* — a real
encoder emitted its ~5 transitions during it, and a binary sticky latch cannot
tell five transitions from one. The backlog made a single flick keep re-latching
for the next eight polls, and it surfaced as a **phantom DOWN appearing on an
X-only movement**, from residue an earlier diagonal had left in the Y
accumulator. Only the sub-step remainder carries now, and the `step` leg pins
both halves: the remainder *is* kept, and a large delta leaves nothing behind.

A second, smaller finding: the `~rst_lvl` term originally guarding the latch sets
was **dead code**, because the trailing level clear is a later assignment in the
same block and always wins — which is exactly the ТМ2's async `R` beating its
clock. It is gone, so the code no longer implies the clear is conditional.

## What nothing here tests, deliberately

- **The bus side.** `mouse_word` is OR-ed into `joy_word` at the **top level**, so
  `qbus_mem` is untouched by this feature and "the word reaches a 0177714 read"
  stays pinned where it already was: `spk_capture_tb` section 10 against the real
  `qbus_mem`, and the `!sel2_n` gate in `sim/smk` section 2. Device here, bus side
  there — the `sim/covox` and `sim/joystick` precedent.
- **Which write bit is СБРОС.** The sheets give the connector pinout (pin 9) but
  not the cable's mapping onto the BK port's output bits. Bit 3 is GID's and the
  only evidence there is; it is the `RST_BIT` parameter so a board measurement can
  move it without touching logic.
- **`STEP` itself.** The divider models the encoder's resolution (a Марсианка is
  coarse, ~100 dpi; a modern optical mouse reports 8–16× more counts for the same
  motion). `STEP_SHIFT = 3` is a starting point, and the *feel* of it is a
  hardware calibration against real software — the oracle pins the mechanism, not
  the constant.
- **The Covox interlock**, which lives at the top level: a mouse poll loop pulses
  СБРОС and that is exactly the "port is being modulated" condition the Covox arms
  on, so `mouse_active` joins `psg_act`. GID's docs record the same conflict from
  the other side (*«Autodetect AY/COVOX … не работает с Менестрелем и мышью»*).

## Mutations

13, `K1`–`K13`, each rewriting one property of a **copy** of the real RTL (the
`sim/evnt` idiom) and required to break a named leg: the direction decode and bit
map (K1–K4), СБРОС polarity/level/bit (K5–K7), the step divider (K8–K9), the
clock-domain crossing including the capture-on-the-pulse contract (K10–K11), and
the buttons and `typ` gate (K12–K13).
