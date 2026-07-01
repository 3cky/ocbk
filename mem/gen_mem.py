#!/usr/bin/env python3
"""Generate the BK-0010 ROM image for the qbus_sdram on-chip ROM (Phase 2).

Single source of truth for the small ROM-resident RAM-test program. Emits a
$readmemh-compatible hex file (one 16-bit word per line, word-addressed from
ROM base 100000), loadable by both Icarus (cosim) and Quartus (block-RAM init).

The 1801ВМ1 reset reads 177716 -> 100000 and begins executing at 100000, so word
index 0 of this image is the first instruction. The program exercises the
RAM-in-SDRAM datapath: word writes + read-back compares at a few RAM addresses
(crossing an SDRAM row), then a byte write whose masking is verified (the
untouched byte of the word must survive). On any mismatch it branches to a
distinct failure self-loop; on full success it parks in the success self-loop.

  success self-loop PC = 100072 (octal)   <- both oracles / LEDs key off this
  failure self-loop PC = 100100 (octal)

ROM_WORDS words are emitted (zero-filled past the program) to match the
qbus_sdram block-RAM depth.
"""
import sys

ROM_WORDS = 256  # on-chip ROM depth (words), 100000.. ; program uses ~33 words

# word-index (from ROM base 100000) -> value (octal). Branch offsets are
# pre-computed: off = target_word - (branch_word + 1), as an 8-bit signed value
# folded into the low byte of the branch opcode.  fail label = word index 30.
PROG = {
    # --- word-write test @ 001000 ---
    0x00: 0o012700, 0x01: 0o001000,   # MOV #001000,R0
    0x02: 0o012701, 0x03: 0o052525,   # MOV #052525,R1   (pattern P1)
    0x04: 0o010110,                   # MOV R1,(R0)       store word
    0x05: 0o011002,                   # MOV (R0),R2       read back
    0x06: 0o020102,                   # CMP R1,R2
    0x07: 0o001026,                   # BNE fail          (off=30-8=22=o26)
    # --- word-write test @ 002000 (different SDRAM row) ---
    0x08: 0o012700, 0x09: 0o002000,   # MOV #002000,R0
    0x0A: 0o012701, 0x0B: 0o025252,   # MOV #025252,R1   (pattern P2)
    0x0C: 0o010110,                   # MOV R1,(R0)
    0x0D: 0o011002,                   # MOV (R0),R2
    0x0E: 0o020102,                   # CMP R1,R2
    0x0F: 0o001016,                   # BNE fail          (off=30-16=14=o16)
    # --- byte-write masking test @ 003000 ---
    0x10: 0o012700, 0x11: 0o003000,   # MOV #003000,R0
    0x12: 0o012701, 0x13: 0o177777,   # MOV #177777,R1   prime whole word = FFFF
    0x14: 0o010110,                   # MOV R1,(R0)
    0x15: 0o112710, 0x16: 0o000125,   # MOVB #125,(R0)   low byte only -> 0125
    0x17: 0o011002,                   # MOV (R0),R2       read full word back
    0x18: 0o012703, 0x19: 0o177525,   # MOV #177525,R3   expected (hi=0377 kept)
    0x1A: 0o020302,                   # CMP R3,R2
    0x1B: 0o001002,                   # BNE fail          (off=30-28=2=o2)
    # --- success ---
    0x1C: 0o005003,                   # CLR R3            success marker
    0x1D: 0o000777,                   # success: BR .     park (PC=100072)
    # --- failure ---
    0x1E: 0o012704, 0x1F: 0o000001,   # fail: MOV #1,R4   failure marker
    0x20: 0o000777,                   # BR .              park (PC=100100)
}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "ram_test.hex"
    mem = [0] * ROM_WORDS
    for idx, val in PROG.items():
        if idx >= ROM_WORDS:
            raise SystemExit(f"word index {idx:o} exceeds ROM_WORDS={ROM_WORDS}")
        mem[idx] = val
    # One 16-bit hex word per line, word-addressed from 0 (= BK address 100000).
    # No comments: Quartus block-RAM inference via $readmemh is picky.
    with open(out, "w") as f:
        for w in mem:
            f.write(f"{w:04x}\n")
    print(f"wrote {out} ({ROM_WORDS} words)")


if __name__ == "__main__":
    main()
