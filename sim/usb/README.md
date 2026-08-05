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
536×4 microcode ROM (upstream `src/firmware/ukp.s`). There is no descriptor
parsing and no CRC arithmetic anywhere in the hardware. So the device model does
not have to be a general USB device — it has to answer exactly this script:

```
wait for the D- pull-up  ->  200 ms  ->  bus reset (10 ms SE0 + 40 ms keep-alive)
SETUP(0,0) + DATA0 GET_DESCRIPTOR(configuration, wLength 24)
  -> three IN(0,0) + ACK pairs draining 24 bytes, which `save` the class triple
bus reset  ->  SET_ADDRESS(1)  ->  SET_CONFIGURATION(1)  ->  IN(1,1) every ~10 ms
```

The class triple lands where it does because of those three fixed 8-byte reads:
descriptor byte 14 = `bInterfaceClass` arrives as `dat[6]` of the second read
(`save 4 6`), byte 15 as `dat[7]` (`save 5 7`), and byte 16 =
`bInterfaceProtocol` as `dat[0]` of the third (`save 6 0`).

## Legs

| leg | what it pins |
|---|---|
| `kbd` | class 3 / sub 1 / proto 1 enumerates end to end — two bus resets, three descriptor reads, address 1, configured — classifies as `typ=1`, and the modifier/key fields decode. Also asserts **every CRC the host emitted was correct**. |
| `mouse` | proto 2 → `typ=2`; buttons decode; and the delta contract below. |
| `pad` | a non-boot HID interface → `typ=3`, with the axis/button decode the wrapper assumes. Its report carries `0xff`, so this is the leg that exercises **bit stuffing**. |
| `nak` | three NAKs per descriptor read plus a NAKed interrupt endpoint: the host must retry (`bnak`) and still enumerate, and a NAK must never be mistaken for a report. |
| `unplug` | detach clears `typ`; a *different* device replugged re-enumerates and is re-classified. |
| `slow` | `kbd` again at the **real 12001-cycle tick** instead of the scaled 61. ~12 s, and it is what proves the scaling in the other five hides nothing about the timer. |

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

## What the CRC checking is for

The host verifies no CRC at all — its own are literals, and it ignores the
device's CRC16 entirely (it reads a fixed 8 payload bytes and stops). So the
model checking them is **the only thing in the tree that can notice a corrupted
`mem/usb_hid_host_rom.hex`**. All three token CRC5s (addr0/ep0, addr1/ep0,
addr1/ep1) and all four DATA0 CRC16s in the image are verified, including the
GET_DESCRIPTOR(device) packet the microcode currently has commented out.

Both need a bit-reversal against the register value, because USB sends a CRC
MSB-first. That was established by computing all seven literals independently and
matching them — so the reversal is not a fudge factor, it is the wire convention.

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

## Mutations

14, `U1`–`U14`, each rewriting one property of a **copy** of the real RTL (the
`sim/evnt` idiom — no inline replica to drift) and required to break a named leg:
the classification tree (U1–U5), the report field plumbing (U6–U10) and the `ukp`
bit engine — `ukprdy` window, strobe alignment, the NAK sample, RX de-stuffing
(U11–U14).
