# Peripherals — keyboard, joysticks and the cartridge slot

`src/peripheral/` minus the SMK512 storage devices ([smk512.md](smk512.md)) and
`bk_evnt.sv` ([video.md](video.md)); sound devices live in
[audio.md](audio.md).

## Keyboard

- **Keyboard (Phase 6):** `ps2_rx` → `kbd_ps2bk` (translator, all on
  `cpu_clk`) → `bk_kbd014` (the 1801ВП1-014 bus equivalent at 177660–177663,
  decode = the 037's `PIN_nBS`, netlist-contract-validated — see
  `sim/ref014/README.md` for the full pinned contract). Key facts:
  - **the 014 readme's "nEC1 = РУС/ЛАТ" label is imprecise for the BK**: the
    schematic wires nEC1 to the trigger flipped by the ЗАГЛ/СТР keys (caps),
    while РУС/ЛАТ are ordinary matrix keys emitting 016/017 — mapped here as
    CapsLock = the ЗАГЛ/СТР trigger, LCtrl = РУС, Home = ЛАТ, Insert = СУ
    (held), either Shift = НР, either Alt = АР2, **Delete = СТОП**,
    **Print Screen = screen_mode toggle** and **F12 = turbo toggle** (both
    radial control outputs like СТОП, never a matrix code, power-on-only —
    see the screen_mode note and the turbo bullet; F12 is scancode 0x07,
    single byte, and its branch is `!got_e0`-guarded because the F-key rows
    in the code table are written E0-agnostic;
    Scroll Lock is now unused — CMT tape mode moved to **DIP 4**, see the
    tape note);
  - case algebra per BkEmu (`latin ^ (caps | shift)` on letters, СУ = `&037`
    on 01xx codes); the **silicon auto-274 code group**
    {0,1,2,4,5,6,7,011,013,021} vectors to 0274 without АР2 (measured over
    the netlist matrix scan — MiSTer's arrow flags were wrong);
  - **СТОП is trap-to-4 on a BK-0010 with BASIC** (per the schematic/user):
    nothing decodes 177674/177676, the HALT entry's PC/PSW stores bus-timeout
    (`qbto`, 56..63 clocks) and the CPU traps through RAM vector 4 — the
    160002 word is never used as a vector. `qbus_mem`'s I/O decode is the
    CPU's own nSEL1/nSEL2 pins (177716/177714 only — the registers whose read
    data `ad_oe` delegates externally; everything else in the I/O page,
    177674/76 included, is undecoded and bus-times-out, exactly as a real BK);
    never "helpfully" reply there. СТОП itself is a fixed 64-cpu_clk one-shot
    on nIRQ1. **Phase 7 (BK-0011M): 177716 write bit 12 = СТОП-block**
    (1 = blocked, write-only, `stop_block` in `qbus_mem` gating the one-shot
    launch in `ocbk_top`) — MiSTer's lane rule, matching the real board's
    WR1/WR2 byte-strobe registers: only a write that strobes the HIGH byte
    (word, or the 177717 odd byte) with the bit-11 lane clear touches it;
    low-byte writes never do (BkEmu's implicit re-enable there is a rejected
    emulator artifact). bk11-only (bk10 has no latch), **DCLO-only reset**
    (the map/662 exception: RESET must not re-enable СТОП). Pinned by
    `spk_capture_tb` + `sim/bk11` section 13; that oracle also documents
    that the aborted HALT entry pushes a mid-instruction PC — the trap-4
    frame is NOT RTI-able (real СТОП handlers never return);
  - `N_KBD`/`N_IAK` = 1 (the async chip replies within the strobe cycle) and
    the 177660 **write** reply is combinational (`wr_fast`) — both pinned by
    `golden_kbd.txt`; vm1 slaves must hold read data past DIN release (the
    IAK vector capture relies on it — bus-charge physics on the real board).

## Joysticks

**CONFIRMED ON HARDWARE 2026-08-02** — a two-player game runs off both pads on
the board, which is the acceptance that matters: it exercises the inversion, the
direction remap and *both* byte lanes at once, and a wrong bit anywhere would be
immediately visible as a stuck or crossed control.

The board's **two MSX DE-9 ports** are read as the BK's joystick word at
**0177714** (the CPU's nSEL2 register — the same address the Covox and the
TurboSound decode for *writes*). `src/peripheral/bk_joystick.sv` is a pure
level translator: no bus, no state the CPU can see, no reset. Oracle:
`sim/joystick/README.md` (device) + `sim/audio`'s `spk_capture_tb` section 10
(the bus side) + `sim/smk` section 2 (the gate, below).

- **The remap is the whole error surface.** MSX DE-9 order is U,D,L,R; the BK's
  is U,R,D,L — different permutations, so a pass-through is wrong in a way that
  still "works" for UP. Pads are **active low** (a passive switch to GND against
  the pads' weak pull-ups), the BK word is **active high**:

  | DE-9 pin | MSX index | control | BK bit | BK mask |
  |---|---|---|---|---|
  | 1 | `pJoy[0]` | UP | 0 | `0o001` |
  | 2 | `pJoy[1]` | DOWN | 2 | `0o004` |
  | 3 | `pJoy[2]` | LEFT | 3 | `0o010` |
  | 4 | `pJoy[3]` | RIGHT | 1 | `0o002` |
  | 6 | `pJoy[4]` | TRIGGER A | 5 | `0o040` |
  | 7 | `pJoy[5]` | TRIGGER B | 6 | `0o100` |

  Reference: BkEmu's `PeripheralPort.read()` (returns the state verbatim, **no**
  inversion — unlike the write-side devices, which each do their own `~value`)
  and `JoystickManager`'s masks. Pins: `pJoyA` = PIN_1/3/5/7/2/4, `pJoyB` =
  PIN_8/12/14/16/11/13, all with `WEAK_PULL_UP_RESISTOR` + `PCI_IO` (the 5 V
  clamp) — esemsx3's exact treatment. `pStrA`/`pStrB` (DE-9 pin 8, PIN_6/PIN_15)
  are left reserved-tristated: a digital pad does not use them, and they stay
  free for a later mouse/paddle.
- **Joystick 2 is the UPPER byte**, same layout shifted by 8. BkEmu models one
  joystick and leaves `[15:8]` at 0, so nothing in the reference pins the high
  byte — but **real two-player BK software does read it**, which is what the
  2026-08-02 hardware run demonstrated, and that is the authority here rather
  than the emulator's single-pad model. The cost is explicit and worth knowing:
  software reading 0177714 **word-wide** (`TST`, not `TSTB`) sees player 2 as
  well as player 1.
- **START (bit 4) and SELECT (bit 7) are tied 0** — a DE-9 digital pad has no
  source for them. Deliberately *not* an A+B chord (a heuristic; the standing
  answer to those here is a hard user-selected mode, never a guess) and *not*
  PS/2 keys OR-ed in (phantom presses during ordinary typing).
- **The `!sel2_n` gate on the merge is load-bearing.** The read is a leg of
  `qbus_mem`'s `io_word`, and `io_word` is `rd_romio`, which is OR-ed into
  `rdata` at *every* reply point — including the SMK I/O-page overlay merge for
  the whole 0177600–0177777 page and the `sel_ide`/`sel_fdd` replies. An ungated
  else-leg leaks joystick bits into SMK BIOS and IDE task-file reads. This is
  the one fact a future editor will get wrong; `sim/smk` section 2 exists to
  catch it (0177714 = BIOS | joystick, 0177776 = BIOS **alone**).
- **The merge did not touch the reply/OE cone**, which is why it closed the
  deferred item cheaply: `sel_io` already replied at 0177714 in **both**
  directions, so `selected`, the `wcnt` load, `drive_data`, `ad_oe` and
  `mem_ready` are all unchanged. With the sticks idle the word is 0 — exactly
  what the address read before — so every timing golden stayed byte-identical.
- **No debounce.** The MSX PSG debounces nothing, BkEmu returns the state
  verbatim, and the BK's 0177714 is a passive buffer — there is no debouncing
  element in the real path. Games poll at frame rate and take a snapshot, so a
  bouncing contact costs at most one frame, as on real hardware. The two flops
  are a **metastability synchroniser** on `cpu_clk_n` (the clock `qbus_mem`'s
  read FSM runs on — the `tape_in` resync precedent in `ocbk_top`), not a
  debouncer.
- **No reset.** BkEmu's reset-to-0 is an artifact of a model that holds state;
  the hardware path is a buffer with no reset pin. Zeroing the sync chain is
  invisible (it reloads on the next edge) and would cost a 24-flop reset cone.
  Same class as the never-reset 0177714 write latch — one step further, since a
  joystick has no latch at all. The power-on word is pinned by the sync chain's
  declaration-time initial values, which is also what makes an **unplugged
  connector** read 0.
- **No enable DIP**, deliberately: with nothing plugged in the ports read 0, so
  there is nothing to disable. `pDip[6]` is the recorded escape hatch if
  hardware bring-up ever finds a conflict (see [open-items.md](open-items.md)).

## USB HID host

`src/peripheral/usb_hid_host.v` + `usb_hid_host_rom.v` (vendored from
[nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host)), a
CPU-less **low-speed** USB host: a 16-instruction microcode engine (`ukp`) plus a
536×4 microcode ROM in one M4K, classifying the device from
`bInterfaceClass/SubClass/Protocol` and exposing keyboard, mouse and gamepad
report fields. Oracle: `sim/usb/README.md`.

**CONFIRMED ON HARDWARE 2026-08-05** — a USB keyboard enumerates as `typ`=1 and
a mouse as `typ`=2 on the OneChipBook's side USB-A port. **Hook F1
(`SET_PROTOCOL`) CONFIRMED ON HARDWARE 2026-08-06** — the four mice below all
report correctly with it; before it, three of four were wrong in three different
ways.

- **The port was already wired as a real host**, it just never had firmware:
  D− on **PIN_238** (esemsx3's `pUsbN2`), D+ on **PIN_239** (`pUsbP2`), **10 kΩ
  pull-downs**, **33 Ω series resistors**, VBUS on +5 V. The other pair
  (PIN_236/237) has no connector on this board, so there is **one port** and
  therefore one device at a time — the core has no hub support.
  10 kΩ is outside the spec's 14.25–24.8 kΩ but harmless: against a device's
  1.5 kΩ pull-up, D− idles at ≈2.87 V (2.61 V worst case), far above LVTTL V<sub>IH</sub>.
- **These two pins must NOT get the `.qsf`'s usual weak pull-up** — the one place
  the convention is wrong, and the `.qsf` says so inline. The internal ~25 kΩ
  against the board's 10 kΩ idles the pin at ≈0.94 V, above LVTTL's 0.8 V
  V<sub>IL</sub> max, so an empty port would read indeterminate instead of the
  SE0 the core's connect detect and watchdog need.
- **Its own 12.08 MHz clock (`usb_clk`), not the same-rate `dot_ena` enable.**
  Measured standalone on this part, the core's **Fmax is 79.4 MHz** — as a
  clock-enabled block in `sys_clk` it would inject a −2.25 ns path into the
  96.65 MHz domain. In its own domain it closes with ~63 ns of slack, i.e. the
  USB core contributes nothing to the fast-domain critical path; its cost is
  placement pressure only (+261 LE, 71 % → 73 %, sys_clk +0.254 → +0.161).
  `usb_clk_r` is a toggle register in `cpu_clkgen` off the existing `divc`, so
  the SDC needs one `create_generated_clock` and **no exception** — one counter,
  one reset, edges coincident with `cpu_clk` every 8 (/16, /32) or 24 (/24)
  sys_clk. It takes a global line (it landed on GCLK3, displacing `dclo_n`'s
  promotion), and the design is now at 8/8 globals.
- **Reset is `vid_rst_n`, power-on only** — the audio/video precedent. A warm
  reset must not drop the USB link and force re-enumeration; hot-plug is the
  core's own watchdog.
- **LOW-SPEED ONLY, and that is a device-availability limitation, not a detail.**
  A low-speed device announces itself with a 1.5 kΩ pull-up on **D−**, a
  full-speed one pulls up **D+**, and this core only ever watches D−: a
  full-speed device is not misclassified but **invisible** (`connected` never
  asserts). Measured — a Sony pad (**054c:0cda**) does not appear at all, while
  keyboards and mice enumerate normally. Since most modern gamepads are
  full-speed, **a USB gamepad may be no easier to obtain than an MSX DE-9 pad**,
  which was the motivation; the gamepad consumer is therefore gated on having a
  pad that enumerates. Full-speed support is not a reparameterisation: 48 MHz
  sampling would fit under the 79 MHz Fmax, but every timing constant and the
  microcode assume 1.5 Mb/s.
- **The microcode is fully hard-coded** — every token and DATA0 packet is a
  literal byte string with a pre-computed CRC5/CRC16. The host never computes or
  checks a CRC. Its enumeration is: wait for the D− pull-up → 200 ms → bus reset
  → GET_DESCRIPTOR (configuration, wLength 24) drained by three IN(0,0)+ACK pairs
  which `save` the class/subclass/protocol bytes → bus reset → SET_ADDRESS(1) →
  SET_CONFIGURATION(1) → **SET_PROTOCOL(boot)** → then IN(1,1) interrupt polls
  every ~10 ms.
- **The microcode source is in-tree and the image is ours** —
  `mem/usb_hid_host_rom.s` assembled by `mem/gen_usb_rom.py` (both vendored from
  upstream's `src/firmware/`, the assembler adapted to take paths) into
  `mem/usb_hid_host_rom.hex`, with a Makefile rule. Assembling upstream's
  unmodified `ukp.s` with that script reproduces the previously vendored image
  byte for byte, so hook F1 below is the only difference. **The memory depth in
  `usb_hid_host_rom.v` must equal the nibble count the script prints** (668
  now, 1024 = one M4K is the ceiling).
- **MICROCODE HOOK F1 — SET_PROTOCOL(boot), and why it is not optional.** The
  wrapper decodes a mouse report at boot-protocol offsets (byte 0 buttons, 1 dx,
  2 dy), but HID 1.11 §7.2.6 says a device powers up in **report** protocol,
  sending whatever its report descriptor declares. Only the plainest mice match
  boot layout by accident. Measured on the board, all three `bInterfaceSubClass
  1`:

  | device | endpoint | report-protocol layout | symptom |
  |---|---|---|---|
  | `093a:2510` | 4 bytes | `[btn, X, Y, wheel]` | worked |
  | `046d:c05b` | 6 bytes | packed **12-bit** axes | X worked, **Y dead** |
  | `0000:3825` | 6 bytes | **Report ID** prefix | КН1 **stuck on**, both axes dead |

  Keyboards hid the problem because their descriptors nearly always *do* match
  boot layout. The same fix, with the byte-identical CRC16, is upstream in the
  m1nl fork (commit `64d83ce`).
- **F1's status stage is unrolled, three attempts, never a `bnak` loop.** `nak`
  is set by *any* handshake PID: it samples the first PID bit, which is 0 for
  ACK/NAK/STALL and 1 for DATA0/DATA1, so the host cannot tell a STALL from a
  NAK. A non-boot device STALLs this request — it is a boot-device request and
  the microcode cannot branch on the saved class triple — and an unbounded retry
  would spin until the ~1.4 s watchdog reset `pc`, re-enumerating for ever. A
  counted loop is impossible because `rcvdt` clobbers `W`. `sim/usb`'s
  `stallproto` leg pins the survival; `setproto` pins the fix itself.
- **Vendored hooks and two deliberate non-fixes** (the single-flop pad sample,
  the `ug <= 9` typo) are enumerated in the file header — read it before a
  re-sync.

## Марсианка mouse

`src/peripheral/bk_mouse.sv` — a USB HID mouse presented as the BK's **УВК-01
«Марсианка»** on **0177714**. The first consumer of the USB host. Oracle:
`sim/mouse/README.md`.

**CONFIRMED ON HARDWARE 2026-08-06** — four different USB mice drive real
Марсианка-aware software correctly, **with both parameters left at their
defaults**. That settles the two items this module shipped as unproven:
`RST_BIT = 3` (the СБРОС bit, which the УВК-01 sheets do not carry — GID's value
was the only evidence, and a board run is now the second) and `STEP_SHIFT = 3`
(the encoder-resolution divide, which wanted a calibration and did not need one:
the boot-protocol report rate is the same for every mouse, so one value suits
all four).

**This is the one subsystem where BkEmu has nothing and GID is not the
authority.** BkEmu does not implement the mouse; GID's is the only software
implementation and its own docs disavow it (*«Работает отвратительно»*). The
contract is therefore derived from the **УВК-01 schematic sheets** — two axes ×
two phases of АЛ107Б/ФД-265 optopairs, each sliced by a К561ЛП2 XOR (1.5 MΩ
feedback = hysteresis) clocking one half of a К561ТМ2, two flip-flops per axis,
`Q`/`/Q` buffered by a К561ПУ4 (six channels = four `Q` + two `/Q`) and
cross-combined by four КМ133ЛА15 NANDs. Sheet 2's connector table is the pinout:
`1 = вверх`, `2 = вправо`, `3 = вниз`, `4 = влево`, `5/6 = КН1/КН2`,
**`9 = СБРОС`**, `10 = +5В`, `7,8 = Общ.`

- **Read word** = the joystick layout, so it needs no new bus path at all:
  bit 0 UP, 1 RIGHT, 2 DOWN, 3 LEFT, 5 = КН1, 6 = КН2. `mouse_word` is OR-ed into
  `joy_word` **at the top level**, so `qbus_mem` is untouched and every one of its
  goldens stays byte-identical — the same trick that made the joystick cheap.
- **Two GID behaviours are rejected as emulator artifacts**, and the oracle
  asserts the opposite of both. There is **no arming**: the NAND outputs sit on
  the connector unconditionally, so nothing gates a read. And **СБРОС is a LEVEL**,
  not an edge — pin 9 wires straight to the ТМ2 `R` inputs with `S` grounded, so
  while it is asserted the latches are *held* cleared and movement is lost rather
  than queued. (GID clears on a wall-clock timer that is 10 ms at one call site
  and 40 ms at another, which is what first suggested it was not real.)
- **Polarity, and why the default is safe.** The 0177714 output port is
  physically inverted (the same `~port_data` the Covox and TurboSound apply) and
  СБРОС is active high at the ТМ2, so the latches are held cleared while the
  program's bit 3 is **0**. `port_data` powers up at 0 and MONITOR's lone
  `CLR @#177714` writes 0 — so a machine that never drives the mouse holds it in
  reset and reads no movement.
- **`STEP` models the encoder's resolution, and it is the one real constant.** The
  sticky bits are binary, so pointer speed is set by the software's poll rate, not
  by how fast the mouse moves — except through how often a poll sees any movement,
  which is the encoder resolution. A Марсианка is coarse (~100 dpi) and a modern
  optical mouse reports 8–16× more counts, so the deltas are divided down.
  `STEP_SHIFT = 3` is a starting point wanting a board calibration.
  **Only the sub-step remainder carries** — an early version kept a multi-step
  backlog and a single flick then re-latched for eight polls, surfacing as a
  phantom DOWN on X-only motion. See the oracle README.
- **Gated on `typ == 2`** (a USB mouse is enumerated), decoded *before* the
  synchroniser because `typ` is two bits and 1→2 flips both. With a pad, a
  keyboard or an empty port it contributes 0, so the DE-9 pads behave exactly as
  before; a DE-9 pad on port B and a USB mouse work at once.
- **Covox interlock**, at the top level: a poll loop pulses СБРОС, which is
  exactly the "port is being modulated" condition the Covox arms on, so
  `mouse_active` joins `psg_act` (named for TurboSound, but its role is "another
  0177714 owner is active"). GID's docs record the same conflict from the other
  side — *«Autodetect AY/COVOX … не работает с Менестрелем и мышью»*.
- **Which write bit is СБРОС is not proven.** The sheets give pin 9 but not the
  cable's mapping onto the port's output bits; bit 3 is GID's and the only
  evidence. It is the `RST_BIT` parameter.

## Cartridge slot

- Cartridge-slot Q-bus is a **forward seam**: `src/bus/qbus_slot.sv`, default
  `SLOT_ENABLE=0` (drives nothing, slot pins stay reserved-tristated). The full
  slot pin map lives commented in `ocbk_common.qsf`. Real BK hardware needs an
  external 5V↔3.3V level-shifter (Cyclone I is not 5V-tolerant).
