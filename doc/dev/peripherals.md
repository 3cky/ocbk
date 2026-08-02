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

## Cartridge slot

- Cartridge-slot Q-bus is a **forward seam**: `src/bus/qbus_slot.sv`, default
  `SLOT_ENABLE=0` (drives nothing, slot pins stay reserved-tristated). The full
  slot pin map lives commented in `ocbk_common.qsf`. Real BK hardware needs an
  external 5V↔3.3V level-shifter (Cyclone I is not 5V-tolerant).
