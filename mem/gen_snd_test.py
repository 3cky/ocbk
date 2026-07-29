#!/usr/bin/env python3
"""Images for the sim/smktime SMK512 memory-access-time oracle.

The program is NOT assembled here: it is `test/sndtestsmk.bin` consumed
VERBATIM - the exact bytes that were run on the real BK-0011M + SMK512 and
on the board, so the sim and the hardware measurement cannot diverge.

test/sndtestsmk.mac (BK .BIN = 2-byte load address + 2-byte length + data,
load address 0o2000, 64 bytes = 32 words):

    002000  MOV #6,@#177130         } SMK two-phase strobe: arm, then commit
    002006  MOV #60,@#177130        } mode 060 -> field [6:4] = 3 = STD10,
    002014  MOV #0,@#177130         } page 0. Segment 4 (0140000) = SMK RAM.
    002022  MOV #140000,R2          } copy the 12-word tone loop from START
    002026  MOV #002046,R1          } (0o2046) up to 0140000 ...
    002032  MOV #14,R0              }
    002036  MOV (R1)+,(R2)+         }
    002040  SOB R0,.-2              }
    002042  JMP 0140000             } ... and run it from SMK RAM

    002046  START: MOV #177716,R0
    002052         MOV #360,R1
    002056         MOV #160,R2
    002062  SND:   MOV R1,(R0)      speaker = bit 6 (vm1 self-replies 177716)
    002064         XOR R2,R1        toggle bits 7:4 -> bit 6 flips every pass
    002066         MOV #300,R3      192
    002072  DELAY: SOB R3,DELAY
    002074         BR SND
    002076         NOP

One half-period of the emitted tone = one SND..BR pass = **197 instruction
fetches**, 192 of them the `SOB` self-loop, and every one of them from the
memory the loop is resident in.  Nothing else in the loop touches memory (the
177716 write is served by the CPU's own internal reply for the 177700-177717
block), so the tone frequency is a direct readout of that memory's access
time.  See sim/smktime/run.sh for the calibration itself.

TWO LEGS, ONE IMAGE, TWO ENTRY POINTS - the loop code is byte-identical in
both, so the only variable is which memory it executes from:

  * default   : enter at 0o2000, i.e. the whole program - the SMK mode switch,
                the copy, and the loop running from **SMK RAM** (MK_EXT).
  * --stdram  : enter at 0o2046 (START), skipping the mode switch and the
                copy, so the same loop runs in place in **ordinary BK-0011M
                RAM** (037-fronted, cycle-stolen).  This is the control leg:
                that path is already calibrated (N_RAM = 4 + the 037 steal),
                so it validates the clock rate and the access-count model and
                isolates any error to N_EXT.

--bk10 is orthogonal to both: it emits the residence image for a BK-0010 stack
(the machine's own RAM at SDRAM 0x0000) instead of BK-0011M physical RAM page 6.
The program itself is unchanged - the SMK is an МПИ expansion board, mode 060
(STD10) covers segment 4 on either machine, and nothing the loop touches is
model-dependent.

Boot rides the REAL SMK mechanism, exactly as sim/smk does: the reset layout
is SYS, whose rom7 window covers the whole 0170000-0177777 INCLUDING the
register space, so the vm1's initial-start 177716 read returns
bios[0o7716] | SEL1 and PC <- & 0o177400 = 0o166400 - the stage-0 JMP in the
rom6 window, which jumps to this leg's entry point.

Emits (word-per-line hex, like the other mem/gen_*.py):
  snd_page6.hex : 8192 words = BK-0011M physical RAM page 6 (the fixed
                  000000-037777 region, SDRAM 0x2C000-0x2DFFF)
  snd_low10.hex : --bk10 instead: 16384 words = the whole BK-0010 RAM
                  (000000-077777, SDRAM 0x0000)
  snd_bios.hex  : 2048 words = the synthetic SMK BIOS image at SDRAM
                  SMK_BIOS_BASE = 0x3A000
"""
import os
import sys

PAGE_WORDS = 8192            # BK-0011M RAM page = 8 KWords
LOW10_WORDS = 16384          # --bk10: the whole BK-0010 RAM (000000-077777)
BIOS_WORDS = 2048            # one 4 KB SMK BIOS image = one segment

BIN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "test", "sndtestsmk.bin")

ENTRY_SMK = 0o002000         # full program: mode switch + copy + run @140000
ENTRY_STD = 0o002046         # START: run the same loop in place, in RAM

START_W = 0o166421           # BIOS image offset 0o7716: the boot word.  The
                             # vm1 masks it with 0o177400 -> PC = 0o166400;
                             # the junk low bits prove the OR-through (same
                             # value gen_smk_test.py uses).
FAIL_PARK = 0o001012         # trap-4 vector target: a self-loop the tb fails
                             # on (pinned - sim/smktime/smk_time_tb.v)


def load_bin(path):
    """Read a BK .BIN: 2-byte load address, 2-byte length, then the data."""
    with open(path, "rb") as f:
        raw = f.read()
    base = raw[0] | (raw[1] << 8)
    nbytes = raw[2] | (raw[3] << 8)
    data = raw[4:4 + nbytes]
    if len(data) != nbytes:
        sys.exit(f"{path}: header says {nbytes} bytes, file has {len(data)}")
    if base & 1 or nbytes & 1:
        sys.exit(f"{path}: load address / length must be even")
    words = [data[i] | (data[i + 1] << 8) for i in range(0, nbytes, 2)]
    return base, words


def build_bios(entry):
    img = [0] * BIOS_WORDS
    img[0o6400 >> 1] = 0o000137             # stage-0 @ 166400: JMP @#entry
    img[(0o6400 >> 1) + 1] = entry
    img[0o7716 >> 1] = START_W              # THE boot word (PC <- & 177400)
    assert (START_W & 0o177400) == 0o166400
    return img


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    stdram = "--stdram" in sys.argv
    bk10 = "--bk10" in sys.argv
    outdir = args[0] if args else "."

    base, words = load_bin(BIN_PATH)
    if base != 0o002000:
        sys.exit(f"{BIN_PATH}: expected load address 0o2000, got {oct(base)}")

    ram = [0] * (LOW10_WORDS if bk10 else PAGE_WORDS)
    # trap 4 (a bus timeout anywhere) -> the fail park the tb watches for
    ram[0o004 >> 1] = FAIL_PARK
    ram[0o006 >> 1] = 0o000340
    ram[FAIL_PARK >> 1] = 0o000777          # BR . (self-loop)
    for i, w in enumerate(words):
        ram[(base >> 1) + i] = w

    entry = ENTRY_STD if stdram else ENTRY_SMK
    bios = build_bios(entry)
    ram_name = "snd_low10.hex" if bk10 else "snd_page6.hex"

    for name, img in ((ram_name, ram), ("snd_bios.hex", bios)):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/{ram_name} + snd_bios.hex "
          f"({len(words)} program words at {oct(base)}, entry {oct(entry)})")


if __name__ == "__main__":
    main()
