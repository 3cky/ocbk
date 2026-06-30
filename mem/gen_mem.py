#!/usr/bin/env python3
"""Generate the BK-0010 RAM image for the qbus_mem block RAM.

Single source of truth for the on-chip test program, transcribed from the
upstream bk10 timing testbench (cpu11/vm1/hdl/syn/sim/bk10/bk10_tb.v). Emits a
$readmemh-compatible hex file (one 16-bit word per line, word-addressed from
000000), loadable by both Icarus (simulation) and Quartus (RAM inference).

The CPU boots from the 2-word ROM bootstrap (JMP @#001000) handled inline in
qbus_mem.sv; this image is only the RAM region 000000-007777.
"""
import sys

RAM_WORDS = 2048  # 000000-007777, word-addressed (byte addr / 2)

# word-index (byte address / 2) -> value (octal). Keyed by the same hex word
# indices used in bk10_tb.v (program at byte 001000 = word 0x100; data at byte
# 002000 = word 0x200; self-loop at byte 001076 = word 0x11F).
PROG = {
    # setup
    0x100: 0o012700, 0x101: 0o002000,   # MOV #002000,R0
    0x102: 0o012701, 0x103: 0o002000,   # MOV #002000,R1
    0x104: 0o012710, 0x105: 0o012345,   # MOV #012345,@R0
    # T01 / T02
    0x106: 0o010002,                    # MOV R0,R2
    0x107: 0o011002,                    # MOV @R0,R2
    # T03 + restore R0
    0x108: 0o012002,                    # MOV (R0)+,R2
    0x109: 0o012700, 0x10A: 0o002000,
    # T04 + restore R0
    0x10B: 0o014002,                    # MOV -(R0),R2
    0x10C: 0o012700, 0x10D: 0o002000,
    # T05 (indexed, 2 words)
    0x10E: 0o016002, 0x10F: 0o000000,   # MOV 0(R0),R2
    # T06 + restore mem[002000]
    0x110: 0o010011,                    # MOV R0,@R1
    0x111: 0o012711, 0x112: 0o012345,
    # T07 + restore R1
    0x113: 0o010021,                    # MOV R0,(R1)+
    0x114: 0o012701, 0x115: 0o002000,
    # T08 + restore R1
    0x116: 0o010041,                    # MOV R0,-(R1)
    0x117: 0o012701, 0x118: 0o002000,
    # T09 (indexed dst, 2 words)
    0x119: 0o010061, 0x11A: 0o000000,   # MOV R0,0(R1)
    # T10 / T11 / T12 + self-loop
    0x11B: 0o005002,                    # CLR R2
    0x11C: 0o000400,                    # BR .+2
    0x11D: 0o012702, 0x11E: 0o001234,   # MOV #001234,R2
    0x11F: 0o000777,                    # BR . (self-loop)
    # data area at 002000
    0x200: 0o012345,
}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "bk10_prog.hex"
    mem = [0] * RAM_WORDS
    for idx, val in PROG.items():
        if idx >= RAM_WORDS:
            raise SystemExit(f"word index {idx:o} exceeds RAM_WORDS={RAM_WORDS}")
        mem[idx] = val
    # No header/comment lines: Quartus RAM inference via $readmemh is picky and
    # may reject comments. One 16-bit hex word per line, word-addressed from 0.
    with open(out, "w") as f:
        for w in mem:
            f.write(f"{w:04x}\n")
    print(f"wrote {out} ({RAM_WORDS} words)")


if __name__ == "__main__":
    main()
