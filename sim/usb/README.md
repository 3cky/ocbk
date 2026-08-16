# sim/usb — the USB HID host oracle

The pinned contract for `src/peripheral/usb_hid_host.v` (vendored from
[nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host)), driven at
its real rate against `usb_ls_device.v`, a behavioural low-speed HID device.
Run with `./run.sh` (part of `make sim`) or `./run.sh --mutate`.

The subsystem notes — the port's electrical facts, the clock argument, the
low-speed limitation — are in [../../doc/dev/peripherals.md](../../doc/dev/peripherals.md).
This file is about what the oracle does and does not pin.

## The reference

The host's own microcode is the contract, and it is unusually rigid: **every
token and DATA0 packet is a literal byte string with a pre-computed CRC** in the
668×4 microcode ROM (`mem/usb_hid_host_rom.s`). There is no descriptor
parsing, and no CRC arithmetic on the **transmit** side — the receive side gained
a CRC16 check in hook H7, see below. So the device model does
not have to be a general USB device — it has to answer exactly this script:

```
wait for the D- pull-up  ->  200 ms  ->  bus reset (10 ms SE0 + 40 ms keep-alive)
SETUP(0,0) + DATA0 GET_DESCRIPTOR(configuration, wLength 24)
  -> three IN(0,0) + ACK pairs draining 24 bytes, which `save` the class triple
bus reset  ->  SET_ADDRESS(1)  ->  SET_CONFIGURATION(1)  ->  SET_PROTOCOL(boot)
  ->  IN(1,1) every ~10 ms
```

`SET_PROTOCOL` is **microcode hook F1**, not upstream's — the image is assembled
in-tree from `mem/usb_hid_host_rom.s` by `mem/gen_usb_rom.py`. Without it a
device stays in *report* protocol and sends whatever its report descriptor
declares, which is not the 3-byte layout the wrapper decodes; that is the bug the
`setproto` leg exists for.

The class triple lands where it does because of those three fixed 8-byte reads:
descriptor byte 14 = `bInterfaceClass` arrives as `dat[6]` of the second read
(`save 4 6`), byte 15 as `dat[7]` (`save 5 7`), and byte 16 =
`bInterfaceProtocol` as `dat[0]` of the third (`save 6 0`).

## Legs

| leg | what it pins |
|---|---|
| `kbd` | class 3 / sub 1 / proto 1 enumerates end to end — two bus resets, three descriptor reads, address 1, configured — classifies as `typ=1`, and the modifier/key fields decode. Also asserts **every CRC the host emitted was correct**. |
| `mouse` | proto 2 → `typ=2`; buttons decode; and the delta contract below. Also that `SET_PROTOCOL` is issued exactly once and accepted. |
| `setproto` | **The regression leg for the hardware bug.** The device sends a Report-ID-prefixed report until `SET_PROTOCOL(boot)` lands. On the pre-F1 image the wrapper reads the ID as a held КН1 and the button byte as `dx` — the exact symptom two of three mice showed on the board. |
| `stallproto` | A device that STALLs `SET_PROTOCOL` must not take the host down. `ukp`'s `nak` flag cannot tell STALL from NAK (it samples the first PID bit, 0 for every handshake and 1 for DATA0/DATA1), so the status stage is **unrolled, three attempts**, never a `bnak` loop. `n_reset` staying at 2 is the assertion that no watchdog re-enumeration happened. |
| `pad` | a non-boot HID interface → `typ=3`, with the axis/button decode the wrapper assumes. Its report carries `0xff`, so this is the leg that exercises **bit stuffing**. It also STALLs `SET_PROTOCOL`, which is what a non-boot interface really does. |
| `pad_real` | **the reference pad, from a real capture.** Every frame is a verbatim `usbhid-dump -d 081f:e401 -es` line from the low-speed pad that motivated `bk_gamepad`: idle, each direction, each face button, START and SELECT. Where `pad` drives the layout the wrapper's comment *describes*, this drives what a device actually *sent* — so the guess table stops being a guess. |
| `dupstrobe` | **the regression leg for the board bug (hook H8).** Injects one spurious extra byte strobe mid-frame — the *effect*, not a model of the cause — and requires the frame to arrive intact anyway. Kills `U18`, which puts the capture back on a strobe counter. No other leg can: every other leg has a well-behaved strobe, which is exactly why the defect survived the whole suite and three board builds. |
| `stuffdup` | a payload whose bit-stuffing lands **exactly on the byte strobe**. Pins that this does *not* double-strobe: `bitadr` freezes across a stuff bit so the position is visited twice, but `~nrzon` suppresses one of the two visits. Investigated as a cause of the board bug and ruled out; the leg exists so it is not re-investigated. |
| `nak` | three NAKs per descriptor read plus a NAKed interrupt endpoint: the host must retry (`bnak`) and still enumerate, and a NAK must never be mistaken for a report. |
| `unplug` | detach clears `typ`; a *different* device replugged re-enumerates and is re-classified. |
| `skew` | the device transmitting at **±1.5 %**, the full low-speed tolerance, against `pad_real`'s frames. Only the device's transmit cell moves; its receive sampling and turnaround stay nominal, because those are model machinery. Also investigated as a cause of the board bug and ruled out. |
| `slow` | `kbd` again at the **real 12001-cycle tick** instead of the scaled 61. ~12 s, and it is what proves the scaling in the fast legs hides nothing about the timer. |

## Findings this oracle produced

Three things came out of building it that are contracts for the consumers, not
test scaffolding:

- **`mouse_dx`/`mouse_dy` must be sampled ON the report pulse.** The wrapper
  zeroes them the cycle *after* raising `report`, so anything that reads them
  later always sees 0. The Марсианка adapter has to accumulate at the strobe.
  `mouse_btn` by contrast is a level and does not clear. Pinned both ways in the
  `mouse` leg; mutation U7.
- **`MS_TICKS` must be odd.** `interval_cy` is true for one clock in `MS_TICKS`,
  but `ukp` evaluates an instruction only every *second* clock, so with an even
  value the two phases lock and a `wait` can sit through hundreds of ticks
  without sampling the cycle it needs. Upstream's 12001 is odd for this reason;
  the first scaled value tried here was 60 and the attach wait took 1000× too
  long. Hook H6's comment carries this.
- **The device's turnaround is load-bearing in the model.** `rx_packet` returns
  on the SE0 that *opens* the host's EOP, at which point the host still has three
  bit times of EOP to drive plus several instructions before it watches the line.
  Replying two bit times later put the model's SYNC on top of the host's own EOP;
  the host reached `start` about four bits into the pattern and every captured
  byte was shifted. Six bit times from the SE0 locks it.

## The two CRC stories, which run in opposite directions

**Transmit — the model checks the host.** Everything the host sends is a literal
with a pre-computed CRC baked into the ROM image, so the model verifying them is
**the only thing in the tree that can notice a corrupted `mem/usb_hid_host_rom.hex`**.
All three token CRC5s (addr0/ep0, addr1/ep0, addr1/ep1) and all four DATA0 CRC16s
are verified on the wire — GET_DESCRIPTOR(configuration), SET_ADDRESS,
SET_CONFIGURATION and SET_PROTOCOL. The fifth literal, GET_DESCRIPTOR(device),
sits behind a commented-out call and was matched by independent computation.

Both need a bit-reversal against the register value, because USB sends a CRC
MSB-first. That was established by computing all seven literals independently and
matching them — so the reversal is not a fudge factor, it is the wire convention.

**Receive — the host checks nothing, deliberately.** A full receive-side CRC16
was built here while chasing the gamepad's phantom BK bit 6, and it is *not* in
the tree: it worked, the board was unchanged, and that is precisely how we
learned the bit stream was never corrupt. It was removed rather than kept
because it cost ~22 LE at 76 % and caused two STA chases for no demonstrated
benefit. `corrupt_byte` survives in the device model — it damages a payload byte
*after* the CRC is computed, which is the only honest way to test a receiver's
CRC — so the escalation is cheap to rebuild if wire corruption ever appears.

## What nothing here tests, deliberately

- **The pads.** The 33 Ω series resistors, the board's 10 kΩ pull-downs and the
  `.qsf`'s deliberate *absence* of a weak pull-up on these two pins are hardware
  properties. Increment 0's LED diagnostic is what checked them, on the board.
- **Full-speed rejection.** A full-speed device pulls up D+ instead of D−, so it
  is invisible rather than mishandled — "the host ignores a line it never reads"
  asserts nothing. The real consequence is device availability, and that belongs
  in the subsystem notes.
- **Metastability on the pad sample.** `ukp` samples with a single flop; a
  zero-delay model cannot show the hazard. Documented at the site instead.
- **The strobe's phase within a byte.** `ukpdat` is latched at `bitadr%8==0` and
  holds, so a strobe anywhere in `001..111` captures the same byte —
  `3'b100 → 3'b101` is an equivalent implementation, not a defect. U12 therefore
  targets the byte *alignment*, which is observable. (Same shape as the project's
  "the 177662 write time is unobservable" finding: worth recording that a knob
  has no observable effect, so nobody later mistakes it for missing coverage.)

## Why the gamepad decode needed a captured pad

The wrapper has **no HID report-descriptor parsing** — not here and nowhere else
in the design. Report layouts are hardcoded per device class, and for a gamepad
the hardcoded table is explicitly a guess (its own comment lists "variations").
For the keyboard and the mouse that is safe, because `SET_PROTOCOL(boot)` forces
a layout the spec fixes. A gamepad is a **non-boot** interface: it STALLs
`SET_PROTOCOL` and sends whatever its report descriptor declares.

So the reference pad was captured on a host before any of `bk_gamepad` was
written, and `pad_real` is that capture. Three properties of this device are
what make the stock decode work **unmodified**, and each would be a trap for a
different pad:

| property | measured | why it matters |
|---|---|---|
| byte 0 rest / swing | `0x7f` / `0x00`,`0xff` | the wrapper discards the whole report when `byte0[1:0] == 2'b10`. A pad resting at `0x7e` or `0x82` would look **dead**. |
| D-pad location | on the axes; byte 5's low nibble is a constant `0x0f` | the wrapper has **no hat decode at all**. A hat-only pad would have no directions. |
| bytes 3, 4 | constant `0x80` | `0x80[7:6]` is `2'b10`, the one value firing **neither** threshold branch. At `0x00` they would force a permanent LEFT+UP. |

`U16` is that third row as a mutation, and it is killed only by `pad_real` —
the synthetic `pad` leg never sends the byte values that expose it.

## What the board taught this oracle

Three hypotheses about the gamepad's phantom BK bit 6 were tested here and **all
three were wrong** — packet corruption, a stuff bit on the byte strobe, and the
device at its bit-rate tolerance limit. The suite passed on a genuinely broken
host every time, because every leg fed it a *well-behaved strobe*. The defect
lived in the wrapper's dependence on strobe COUNTING, which no amount of
well-formed traffic can expose.

Two lessons are worth keeping:

- **When a leg cannot distinguish a healthy DUT from a dead one, it is not a
  test.** `pad_real` checked only the decoded level outputs, which the wrapper
  writes regardless — so a CRC that rejected *every* frame passed it. It now
  asserts the pulse count too, and that is what let the CRC mutations die while it existed.
- **A leg that reads live state can be fooled by the next good frame.** The first
  `dupstrobe` waited for two reports and read `dbg_hid_report` live; it passed on
  a knowingly-broken build because a clean frame had already overwritten the
  damage. It now latches the frame at its own report pulse. The general form: if
  a fault is transient, assert on a value captured *at* the fault, never on
  whatever the DUT happens to be showing later.

## Mutations

22, `U1`–`U22`, each rewriting one property of a **copy** of the real RTL (the
`sim/evnt` idiom — no inline replica to drift) and required to break a named leg:
the classification tree (U1–U5), the report field plumbing (U6–U10), the `ukp`
bit engine — `ukprdy` window, strobe alignment, the NAK sample, RX de-stuffing
(U11–U14), the gamepad decode against the captured frames (U15–U17), and hook
H8's positional byte addressing (U18–U20).

**`U18` is the board-bug regression**: it restores the pre-H7 behaviour of
trusting every packet. `U19`–`U22` are the opposite failure — a CRC that is
present but *wrong* (bad residual, bad window, bad init, bad feedback tap), which
rejects **everything** and kills the device silently. They are targeted at
`mouse`, not `pad_real`, and that retargeting was itself a finding: `pad_real`
checks the level outputs, which the wrapper writes regardless of CRC, so it could
not tell a healthy link from one delivering no reports at all. It now asserts the
pulse count too.

Plus **`F1`, which mutates the microcode source and reassembles the ROM** —
dropping the `SET_PROTOCOL` call restores the shipped-and-broken behaviour, and
`setproto` must notice. It is the only mutation that reaches the image, and the
image is where this subsystem's one field bug actually lived: no rewrite of any
line of Verilog could have expressed it.
