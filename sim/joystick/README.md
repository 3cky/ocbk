# sim/joystick — the joystick oracle

The pinned contract for `src/peripheral/bk_joystick.sv`, the two MSX pads as the
BK's **0177714** read word. Run with `./run.sh` (part of `make sim`) or
`./run.sh --mutate`.

The device holds no state the CPU can see, decodes no address and never touches
the bus: `qbus_mem`'s `io_word` takes `joy_word` on its `!sel2_n` leg, where
0177714 already replies in both directions via `sel_io`. The whole bus-side
delta is one extra input to a mux that already existed, which is what keeps
every timing golden in the tree byte-identical.

---

## The reference

**BkEmu wins on BK register semantics**, so `PeripheralPort` + `JoystickManager`
are the contract:

```java
// PeripheralPort.java — ADDRESSES = { Cpu.REG_SEL2 }  (= 0177714)
public int read(long cpuTime, int address) { return getState(); }

// JoystickManager.java
JOYSTICK_UP = 1;  JOYSTICK_RIGHT = 1<<1;  JOYSTICK_DOWN = 1<<2;  JOYSTICK_LEFT = 1<<3;
JOYSTICK_BUTTON_START = 1<<4;  JOYSTICK_BUTTON_A = 1<<5;
JOYSTICK_BUTTON_B     = 1<<6;  JOYSTICK_BUTTON_SELECT = 1<<7;
```

**Active high, read-only, no inversion** — note the contrast with the write-side
devices on the same address, which each do their own `~value` for the port
inversion. Pressed = bit set; nothing held = 0, which is also what 0177714 read
before this increment existed.

MiSTer's BK core agrees on the direction nibble (its mouse mode drives the same
`[0]`=up `[1]`=right `[2]`=down `[3]`=left and buttons on `[5]`/`[6]`).

## The remap, which is the whole error surface

The MSX DE-9 order and the BK order are **different permutations** of the four
directions — MSX is U,D,L,R and the BK is U,R,D,L. A pass-through is therefore
wrong in a way that still looks right for UP, which is why the tb walks all
twelve inputs individually and checks *which* bit each lands on.

| DE-9 pin | MSX index | control | BK bit | BK mask |
|---|---|---|---|---|
| 1 | `pad[0]` | UP | 0 | `0o001` |
| 2 | `pad[1]` | DOWN | 2 | `0o004` |
| 3 | `pad[2]` | LEFT | 3 | `0o010` |
| 4 | `pad[3]` | RIGHT | 1 | `0o002` |
| 6 | `pad[4]` | TRIGGER A | 5 | `0o040` |
| 7 | `pad[5]` | TRIGGER B | 6 | `0o100` |

Pads are **active low** (a passive switch to GND against the pads' internal weak
pull-ups); the BK word is **active high**. All six held on one port therefore
reads `0o157`, and on both ports `0o067557`.

## Three deliberate divergences from BkEmu

**1. Joystick 2 lives in the UPPER byte.** *(Vindicated on hardware 2026-08-02:
a real two-player BK game reads it.)* BkEmu models a single joystick and
leaves `[15:8]` at 0; the board has two ports, so port B gets the same layout
shifted by 8. Nothing outside this file and this oracle pins the high byte. The
cost is explicit: software that reads 0177714 **word-wide** (`TST` rather than
`TSTB`) now sees player 2 as well as player 1.

**2. START (bit 4) and SELECT (bit 7) are tied 0.** A DE-9 digital pad has no
source for them. Deliberately *not* synthesised from an A+B chord and *not*
OR-ed in from PS/2 keys — the first is a heuristic, and the project's standing
answer to those is a hard user-selected mode, never a guess; the second would
inject phantom presses during ordinary typing. Section 7 is the assertion.

**3. No reset.** BkEmu resets the port state to 0 because it is a model that
holds state; the hardware path is a buffer with no reset pin. Zeroing the sync
chain would be invisible anyway — it reloads from the pads on the very next
edge — while costing a 24-flop reset cone on a placement-fragile design. This is
the `spk`/`mot` class named in `qbus_mem` ("a real Covox is a passive DAC on the
port latch with no reset pin at all"), one step further: a joystick has no latch
at all. Reset-freedom is therefore *structural*, and the sync chain's
declaration-time initial values are the only thing pinning the power-on word.

## No debounce, deliberately

The MSX PSG reads its pad pins through a plain buffer, BkEmu's
`PeripheralPort.read()` returns the state verbatim, and the BK's own 0177714 is
a passive port buffer — there is no debouncing element anywhere in the real
signal path. Games poll at frame rate and take a snapshot, so a bouncing contact
costs at most one frame of a wrong level, which is what a real stick on a real
machine does. **The two flops are a metastability synchroniser, not a
debouncer** — section 8 pins the depth at exactly two so neither a one-flop
chain (a hazard on an asynchronous pad) nor a combinational path (a raw pad in
`qbus_mem`'s `rdata` cone) can slip in.

---

## The leg

| § | what it pins |
|---|---|
| 1 | the **power-on word is 0 before any clock edge** — with no reset, this is purely the declaration-time initial values, and it is what the ten `joy_word` tie-offs in the SoC testbenches rest on |
| 2 | both ports released → 0 (an unplugged connector) |
| 3 | the per-control walk of port A onto the **low** byte, with the high byte held at 0 |
| 4 | the per-control walk of port B onto the **high** byte, with the low byte held at 0 |
| 5 | both ports at once, with patterns sharing no bit position, and the mirror image |
| 6 | diagonals, including one per port simultaneously |
| 7 | everything held = `0o067557` — **START and SELECT stay clear** |
| 8 | the synchroniser is **exactly two deep**, in both directions |
| 9 | anti-vacuity: ≥ 16 distinct words, and `joy_word` never went X |

### Why one leg

The **bus** side is not this leg's job — the same division of labour as
`sim/covox` and `sim/ts`, and it is split across two oracles:

* **`sim/audio`'s `spk_capture_tb`, section 10** (mutations Q6–Q9 in
  `sim/run_audio.sh`) drives the **real** `qbus_mem`: the word reaching the bus,
  0177715 getting the full word, 0177716 staying clean, and the **DATIO(B)** leg
  where the read half returns the sticks while the write half still produces
  exactly one Covox/AY strobe under one SYNC.
* **`sim/smk`, section 2** owns the **`!sel2_n` gate**. It has to: every address
  that could show a leak also takes the mem-region ROM leg, whose reply is
  done-gated on an SDRAM fetch, and `spk_capture_tb` has no SDRAM model — such a
  read would simply hang there. On the full SoC it reads 0177714 (= BIOS |
  joystick), 0177776 (= BIOS **alone**) and 0177716 (nSEL1 wins) against a
  non-zero `joy_word`; both mutations, merge dropped and gate dropped, are
  recorded in that runner's header as verified by hand.

### What nothing tests, deliberately

The pads themselves: the weak pull-ups that make a released control read 1 and
an unplugged connector read all-released, and the `PCI_IO` 5 V clamp. Those are
`.qsf` I/O properties copied from esemsx3 and are a **hardware bring-up** item,
not a simulable one — **done 2026-08-02**, a two-player game on both pads.

## Mutations

15, all killed. J1–J2 the inversion (each port separately); J3–J9 and J12 the
remap (nibble passed through unmapped, LEFT/RIGHT swapped, UP/DOWN swapped,
trigger A onto START, trigger B onto SELECT, triggers swapped, port B wrong
while port A is right, START/SELECT invented); J10–J11 the two bytes (port B
collapsing onto port A, the two ports swapped); J13–J15 the synchroniser and the
power-on word (second stage dropped, taken combinationally, initial values
dropped).

Each is a `sed` against a **copy** of the real RTL — no inline replica to
drift — and a `sed` that fails to apply is a hard error, never a silent skip.
