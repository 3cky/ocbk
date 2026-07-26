#!/usr/bin/env python3
"""Images for the sim/grantfit 037 grant-rule bench - any doc/sndtest*.bin.

This is mem/gen_snd_test.py generalised: the program is never assembled here,
it is one of the tracked `doc/sndtest*.bin` images consumed VERBATIM - the
exact bytes that were run on the real BK-0011M and on the board, so the sim and
the hardware measurement cannot diverge.  Which image and which entry point are
command-line arguments, because the bench's whole point is to evaluate ONE
candidate 037 change against SEVEN different memory-access patterns at once.

    gen_tone_test.py --image sndtest662 --entry 2006 [--smk] [--bk10] OUTDIR

`--entry` is octal (with or without a leading 0o).  The tone programs and their
entry points are catalogued in sim/grantfit/run.sh; each `.mac` in doc/ is the
source of truth for its own `.bin`.

BOOT.  Two mechanisms, selected by --smk, both already used by the existing
oracles - this script just emits the images for whichever one the leg needs:

  * stock (default): the vm1's initial-start 177716 read returns SYS_START11 =
    0140000, the fixed top ROM, where tone_top.hex plants a stage-0 JMP to the
    entry point.  The sim/bk11 + sim/vregtime idiom.  With --bk10 the start
    vector is SYS_START = 0100000 instead, i.e. the base of the linear ROM map
    (SDRAM word 0x4000), so the stub goes in tone_rom10.hex.
  * --smk: the REAL SMK512 mechanism (sim/smk, sim/smktime).  The reset layout
    is SYS, whose rom7 window covers the whole 0170000-0177777 INCLUDING the
    register space, so the initial-start read returns bios[0o7716] | SEL1 and
    PC <- & 0o177400 = 0o166400 - the stage-0 JMP in the rom6 window.

Both images are emitted unconditionally (the unused one is harmless: in stock
mode nothing maps at SMK_BIOS_BASE, and with the SMK the top-ROM stub is never
fetched), which keeps the tb's preload unconditional.

Emits (word-per-line hex, like the other mem/gen_*.py):
  tone_ram.hex  : 8192 words = BK-0011M physical RAM page 6 (the fixed
                  000000-037777 region, SDRAM 0x2C000-0x2DFFF)
                  --bk10 instead: 16384 words = the whole BK-0010 RAM
                  (000000-077777, SDRAM 0x0000)
  tone_top.hex  : 64 words = the top-ROM stage-0 stub at BK 140000
                  (SDRAM BK11_TOPROM_BASE = 0x38000)
  tone_rom10.hex: 64 words = the same stub at BK 100000 (SDRAM 0x4000), which
                  is where a BK-0010's start vector points
  tone_bios.hex : 2048 words = the synthetic SMK BIOS image at SDRAM
                  SMK_BIOS_BASE = 0x3A000
"""
import os
import sys

PAGE_WORDS = 8192            # BK-0011M RAM page = 8 KWords
LOW10_WORDS = 16384          # --bk10: the whole BK-0010 RAM (000000-077777)
TOP_WORDS = 64               # only the stage-0 stub is preloaded
BIOS_WORDS = 2048            # one 4 KB SMK BIOS image = one segment

DOC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "doc")

START_W = 0o166421           # BIOS image offset 0o7716: the boot word.  The
                             # vm1 masks it with 0o177400 -> PC = 0o166400;
                             # the junk low bits prove the OR-through (the same
                             # value gen_smk_test.py / gen_snd_test.py use).
FAIL_PARK = 0o001012         # trap-4 vector target: a self-loop the tb fails
                             # on (pinned - sim/grantfit/tone_tb.v)


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


def opt(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 >= len(sys.argv):
            sys.exit(f"{name} needs a value")
        return sys.argv[i + 1]
    return default


def main():
    image = opt("--image")
    entry_s = opt("--entry")
    if image is None or entry_s is None:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    smk = "--smk" in sys.argv
    bk10 = "--bk10" in sys.argv

    # positional OUTDIR = the one argument that is neither a flag nor a value
    consumed = {image, entry_s}
    args = [x for x in sys.argv[1:]
            if not x.startswith("--") and x not in consumed]
    outdir = args[0] if args else "."

    entry = int(entry_s, 8)
    binpath = os.path.normpath(os.path.join(DOC, f"{image}.bin"))
    if not os.path.exists(binpath):
        sys.exit(f"{binpath}: no such tone image")

    base, words = load_bin(binpath)
    if entry < base or entry >= base + 2 * len(words):
        sys.exit(f"entry {oct(entry)} is outside {image} "
                 f"({oct(base)}..{oct(base + 2 * len(words))})")

    ram = [0] * (LOW10_WORDS if bk10 else PAGE_WORDS)
    # trap 4 (a bus timeout anywhere) -> the fail park the tb watches for
    ram[0o004 >> 1] = FAIL_PARK
    ram[0o006 >> 1] = 0o000340
    ram[FAIL_PARK >> 1] = 0o000777          # BR . (self-loop)
    if (base >> 1) + len(words) > len(ram):
        sys.exit(f"{image} does not fit the residence image")
    for i, w in enumerate(words):
        ram[(base >> 1) + i] = w

    top = [0] * TOP_WORDS
    top[0] = 0o000137                       # BK 140000: JMP @#entry
    top[1] = entry

    for name, img in (("tone_ram.hex", ram), ("tone_top.hex", top),
                      ("tone_rom10.hex", top),
                      ("tone_bios.hex", build_bios(entry))):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/tone_{{ram,top,bios}}.hex "
          f"({image}, {len(words)} words at {oct(base)}, entry {oct(entry)}, "
          f"{'SMK' if smk else 'stock'}{', bk10' if bk10 else ''})")


if __name__ == "__main__":
    main()
