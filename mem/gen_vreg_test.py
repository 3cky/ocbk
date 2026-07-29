#!/usr/bin/env python3
"""The 177662 write-time measurement program + the sim/vregtime images.

WHY
---
`N_VREG` (qbus_pkg) is the reply count for a BK-0011M 177662 (video page /
palette) write.  It is paid ONCE PER PALETTE WRITE, so inside a beam-raced
multicolor loop the error INTEGRATES - a wrong value shows up as a progressive
skew down the screen, not as a static offset.  Everything else such a loop
touches is already calibrated (RAM fetches = N_RAM + the 037 steal, measured on
hardware in the N_EXT work; 177716 = the vm1's own internal reply; EVNT/IRQ2 =
sim/evnt against the reference netlist), which is what makes this one constant
worth its own program.

THE PROGRAM (BK .BIN, load address 0o2000)
------------------------------------------
**test/sndtest662.mac is the source of truth** - it is what pdpy11 assembles
into test/sndtest662.bin AND test/sndtest662.wav, and the .wav is what gets
played into a real BK-0011M. This script re-assembles the same program
independently (below) and ASSERTS the result matches test/sndtest662.bin
byte-for-byte, then builds the sim images from the .bin verbatim - so the
bytes the oracle runs and the bytes the real machine runs cannot drift apart.
(Rebuild the .bin/.wav with:  cd doc && pdpy11 sndtest662.mac)
Same idea as test/sndtestsmk.mac: a square wave on the 177716 speaker bit whose
half-period is one pass of a loop, so the emitted TONE is a direct readout of
what that loop costs - the only thing measurable on a real machine.

    2000  E662:   MOV #177662,R0     } the two entry points differ in R0
    2004          BR COMMON          } and in NOTHING else
    2006  ERAM:   MOV #SCRATCH,R0    }
    2012          BR COMMON          }
    2014  COMMON: MOV #47400,R1      the written value = def_reg662 (page 0,
    2020          MOV R1,@#177662    EVNT masked, palette 15) - written once
                                     here by BOTH legs so the control leg has
                                     EVNT masked too, and re-written 192x per
                                     half-period by the 662 leg with the SAME
                                     value, so nothing on screen ever changes
    2024          MOV #177716,R5     speaker port
    2030          MOV #360,R2        bit 6 set, bit 7 (motor) set = stopped
    2034          MOV #160,R3        XOR mask: flips bit 6 every pass
    2040  SND:    MOV R2,(R5)        the half-period marker (CPU self-reply,
                                     so it costs nothing on the qbus_mem side)
    2042          XOR R3,R2
    2044          MOV #30,R4         24 outer iterations
    2050  LOOP:   MOV R1,(R0)        x8 unrolled -> 192 writes per half-period
     ...          ...
    2070          SOB R4,LOOP
    2072          BR SND
    2074  SCRATCH:.WORD 0            the control leg's target

Nothing masks the keyboard interrupt: on a real BK a stray keypress perturbs
one half-period out of thousands, and adding a `CLR @#177660` would put a
DATIO on a register that the measurement stack does not model at all.

TWO LEGS, ONE IMAGE, TWO ENTRY POINTS - the loop body is BYTE-IDENTICAL in
both and the only difference in the whole machine state is R0:

  * 662 leg (entry 0o2000, the default): the 192 writes go to the video
    register -> N_VREG, the constant under test.  Not 037-fronted, so no
    cycle stealing.
  * RAM control leg (entry 0o2006): the same 192 writes go to a scratch word
    in the memory the loop is already resident in -> MK_RAM037, N_RAM=4 plus
    the 037 steal.  That path was calibrated against real hardware to +0.04 %
    in the N_EXT work, so this leg validates the clock rate, the access-count
    model and the assembler - and isolates any remaining error to N_VREG.

192 writes per half-period is deliberate high gain: one unit of N moves the
tone by 192 cycles out of ~4300, i.e. ~4.5 % (~20 Hz), where the sndtestsmk
measurements resolved ~1 Hz.

TO MEASURE ON REAL HARDWARE: load test/sndtest662.bin on a BK-0011M, run it
(entry 0o2000) and record the tone; then start it again at 0o2006 and record
that tone.  Compare both against the board.  The per-write difference is
(cycles_662 - cycles_ram) / 192 in CPU cycles.

Emits (word-per-line hex, like the other mem/gen_*.py):
  vreg_ram.hex : 8192 words = BK-0011M physical RAM page 6 (the fixed
                 000000-037777 region, SDRAM 0x2C000-0x2DFFF)
  vreg_top.hex : 64 words = the top-ROM stage-0 stub at BK 140000
                 (SDRAM BK11_TOPROM_BASE = 0x38000): the 177716 start vector
                 on a BK-0011M is 0140000, so the reset fetch lands here and
                 this JMPs to the leg's entry point (the sim/bk11 idiom)
and, with --bin, test/sndtest662.bin itself.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_mem import Asm, BR                    # noqa: E402  the in-repo assembler

PAGE_WORDS = 8192            # BK-0011M RAM page = 8 KWords
TOP_WORDS = 64               # only the stage-0 stub is preloaded
BASE = 0o002000              # program load address
ENTRY_662 = 0o002000         # leg 1: the writes go to 177662
ENTRY_RAM = 0o002006         # leg 2 (control): the same writes go to RAM
FAIL_PARK = 0o001012         # trap-4 target: a self-loop the tb fails on
                             # (pinned - sim/vregtime/vreg_time_tb.v)
UNROLL = 8                   # writes per inner pass
OUTER = 24                   # inner passes per half-period -> 192 writes

TEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test")


def build_program():
    a = Asm(base=BASE)

    a.label("E662")
    a.emit(0o012700, 0o177662)               # MOV #177662,R0
    a.br(BR, "COMMON")

    a.label("ERAM")
    a.emit(0o012700)                         # MOV #SCRATCH,R0
    a.addr("SCRATCH")
    a.br(BR, "COMMON")

    a.label("COMMON")
    a.emit(0o012701, 0o047400)               # MOV #47400,R1
    a.emit(0o010137, 0o177662)               # MOV R1,@#177662  (mask EVNT)
    a.emit(0o012705, 0o177716)               # MOV #177716,R5
    a.emit(0o012702, 0o000360)               # MOV #360,R2
    a.emit(0o012703, 0o000160)               # MOV #160,R3

    a.label("SND")
    a.emit(0o010215)                         # MOV R2,(R5)   speaker toggle
    a.emit(0o074302)                         # XOR R3,R2
    a.emit(0o012704, OUTER)                  # MOV #24.,R4

    a.label("LOOP")
    for _ in range(UNROLL):
        a.emit(0o010110)                     # MOV R1,(R0)
    a.sob(4, "LOOP")
    a.br(BR, "SND")

    a.label("SCRATCH")
    a.emit(0o000000)

    words = a.resolve()
    # the two documented entry points must be where the header says they are
    assert BASE + 2 * a.labels["E662"] == ENTRY_662, "entry 1 moved"
    assert BASE + 2 * a.labels["ERAM"] == ENTRY_RAM, "entry 2 moved"
    return words, a.labels


def load_bin(path):
    """Read a BK .BIN: 2-byte load address, 2-byte length, then the data."""
    with open(path, "rb") as f:
        raw = f.read()
    base = raw[0] | (raw[1] << 8)
    nbytes = raw[2] | (raw[3] << 8)
    data = raw[4:4 + nbytes]
    if len(data) != nbytes:
        sys.exit(f"{path}: header says {nbytes} bytes, file has {len(data)}")
    return base, [data[i] | (data[i + 1] << 8) for i in range(0, nbytes, 2)]


def write_bin(path, words):
    data = bytearray()
    for w in words:
        data += bytes((w & 0xFF, (w >> 8) & 0xFF))
    hdr = bytes((BASE & 0xFF, BASE >> 8, len(data) & 0xFF, len(data) >> 8))
    with open(path, "wb") as f:
        f.write(hdr + data)


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    ramleg = "--ramleg" in sys.argv
    outdir = args[0] if args else "."

    words, labels = build_program()

    # The .bin/.wav pdpy11 built from test/sndtest662.mac is what a real machine
    # runs; refuse to build sim images from anything else.
    binpath = os.path.normpath(os.path.join(TEST, "sndtest662.bin"))
    if os.path.exists(binpath) and "--bin" not in sys.argv:
        base, ref = load_bin(binpath)
        if base != BASE or ref != words:
            sys.exit(f"{binpath} does not match the program assembled here - "
                     f"re-run `cd doc && pdpy11 sndtest662.mac`, or reconcile "
                     f"the two (the .mac is the source of truth)")
        words = ref

    if "--bin" in sys.argv:
        p = os.path.normpath(os.path.join(TEST, "sndtest662.bin"))
        write_bin(p, words)
        print(f"wrote {p} ({len(words)} words at {oct(BASE)})")

    ram = [0] * PAGE_WORDS
    # trap 4 (a bus timeout anywhere) -> the fail park the tb watches for
    ram[0o004 >> 1] = FAIL_PARK
    ram[0o006 >> 1] = 0o000340
    ram[FAIL_PARK >> 1] = 0o000777            # BR . (self-loop)
    for i, w in enumerate(words):
        ram[(BASE >> 1) + i] = w

    entry = ENTRY_RAM if ramleg else ENTRY_662
    top = [0] * TOP_WORDS
    top[0] = 0o000137                         # BK 140000: JMP @#entry
    top[1] = entry

    for name, img in (("vreg_ram.hex", ram), ("vreg_top.hex", top)):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/vreg_ram.hex + vreg_top.hex "
          f"(entry {oct(entry)}, LOOP {oct(BASE + 2 * labels['LOOP'])}, "
          f"{UNROLL}x{OUTER} = {UNROLL * OUTER} writes/half-period)")


if __name__ == "__main__":
    main()
