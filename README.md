# ocbk - BK-0010 / BK-0011M on the OneChipBook

Alternative firmware that turns the OneChipBook board (Altera Cyclone I
**EP1C12Q240C8**) into a Soviet **Elektronika BK-0010(.01)** or **BK-0011M** -
the PDP-11-class home computers built around the 1801ВМ1 CPU. It runs the real
ROMs, boots to the real firmware, and aims at **cycle-accurate** timing rather
than "close enough": the 1801ВП1-037's memory arbitration is reproduced, so the
screen slows the CPU exactly as it does on real silicon, and beam-raced demo
effects land where their authors intended.

## What works

Everything below is confirmed running on the board.

- **BK-0010.01** - MONITOR + BASIC Vilnius, 3.02 MHz.
- **BK-0011M** - BOS, 4.03 MHz, banked memory, two video pages, the 16-colour
  programmable palette and the 50 Hz frame interrupt.
- **Display** - full-screen borderless **1024×768@60** on the panel, integer
  ×2 horizontal / ×3 vertical scaling (so the BK's 2:3 pixel shape is right).
  Both colour-256 and mono-512 modes.
- **Keyboard** - a PS/2 keyboard behaves as the BK's own, including the
  Russian/Latin and case triggers, СУ/АР2/НР modifiers and СТОП.
- **Sound** - the 1-bit speaker, through the board's audio jacks.
- **Tape** - the right audio jack doubles as the cassette port. Load real BK
  tape recordings from a PC, and save back to one.
- **SMK512** - the 512 KB RAM extension, its BIOS, and an IDE drive backed by
  an SD card. Boots an OS from a standard AltPro HDD image.
- **Turbo** - an optional 6.04 MHz mode, roughly **1.8×** (BK-0011M) to
  **2.2×** (BK-0010) faster than authentic.
- **Reset button** - warm-restarts the machine with memory intact, like a real
  BK's reset. Also how you switch models.

## Controls

### DIP switches

| Switch | Function |
|--------|----------|
| **1** | **Model**: OFF = BK-0010, ON = BK-0011M. Needs reset when switched |
| **4** | **Tape mode**: ON = the right audio jack is the cassette port |
| **8** | **SMK512**: ON = the storage controller is present. Needs reset when switched |

### Special keys and buttons

| Key or Button | Does |
|-----|------|
| **FN+R** | **Reset** |
| **F12** / **F button** / **FN+F** | **Turbo** on/off |
| **Print Screen** / **V button** | display mode: colour-256 ↔ mono-512 |
| Delete | **СТОП** |
| Caps Lock | **ЗАГЛ/СТР** - the upper/lower case trigger |
| Left Ctrl | **РУС** - switch to Russian |
| Home | **ЛАТ** - switch to Latin |
| Insert | **СУ** - control modifier (hold) |
| Alt | **АР2** - the second-function modifier (hold) |
| Shift | **НР** - the BK's own shift |
| Esc / F2 / F9 | КТ / ВС / СБР |
| F1, F3, F5 | ПОВТ, graphics, kill-to-end-of-line |
| F6, F7, F8 | ИНД СУ, БЛОК РЕД, ШАГ |
| Arrows | cursor movement |

Turbo and the display mode are remembered across the reset button; they reset
only on power-off.

### LEDs

| LED | Meaning |
|-----|---------|
| **Red power LED** | solid = running. **Blinking = the firmware image in flash failed its checksum** and the CPU is held in reset. Dark only for the first ~200 µs at power-on. |
| **7** | SMK512 drive access - blinks while the drive is busy, one short flash for a single access |
| **6** | tape mode is on |
| **5** | turbo is on |
| **0** | speaker activity |

## Using it

### Tape

Switch **DIP 4** on (LED 6 lights). Play a BK tape recording - e.g. a WAV
rendered from a `.BIN` - into the **right** audio channel, then load it the
normal way. Switch DIP 4 off when you're done - that jack is the right audio channel otherwise.

### SD card (SMK512)

Write a raw **AltPro HDD image** to the card starting at the very beginning -
no partition table, no filesystem, just the image at sector 0:

```
sudo dd if=your_image.img of=/dev/sdX bs=1M conv=fsync status=progress
```

Put the card in the board's SD slot, switch **DIP 8** on, and press reset: the
SMK BIOS finds the drive and boots from it. There is no card-detect pin, so
insert the card first, *then* reset.

With DIP 8 on and no card, the BIOS reports no drive and drops to its own
command line - the same as a real SMK with nothing attached. Switch DIP 8 off
and reset for a plain machine.

## Building and flashing

```
make          # build the bitstream (Quartus II 11.0) -> fw/
make flash    # write it to the board's config flash over USB-Blaster
```

Needs Quartus II 11.0 at `/opt/altera/11.0/quartus` (override with
`QUARTUS_HOME=`). Flashing is Active Serial over a USB-Blaster; it programs
the FPGA configuration *and* the BK ROM images in one shot, so the board comes
up standalone afterwards.

The BK ROM images live in `mem/roms/` and are built into the flash image
automatically - nothing to load at runtime. If that image is ever corrupt the
board refuses to run the CPU and blinks the power LED rather than booting
something broken.

## Under the hood

It fits in **6,979 of 12,060 logic elements (58 %)**, 3 memory blocks and the
board's single PLL.

Developer documentation - the architecture, the platform constraints, the
memory map, the per-module design rules and the simulation oracles that keep
the timing honest - is in **[CLAUDE.md](CLAUDE.md)**. Start with "Platform &
system map".

## Credits

- The **1801ВМ1** CPU and **1801ВП1-037/014** chip models are reverse-engineered
  gate-level designs from the [cpu11](https://github.com/1801BM1/cpu11) and
  [k1801](https://github.com/1801BM1/k1801) projects - the reason this can be
  cycle-accurate at all rather than merely compatible.
- The BK ROM images and the reference for BK register behaviour come from the
  **BkEmu** emulator. BK ROMs are not subject to distribution restrictions.
- The board bring-up (clocking, SDRAM, VGA) builds on **esemsx3** from
  [ocm-pld-dev](https://github.com/gnogni/ocm-pld-dev), the 1chipMSX firmware
  project.
