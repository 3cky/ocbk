#!/usr/bin/env python3
"""Generate the BK-0010 ROM image (Phase 2 RAM test + Phase 4 test picture).

Single source of truth for the ROM-resident test program AND the picture it
draws (render_image() below is imported by sim/video/gen_expected.py, so the
video cosim validates the exact shipped image). Emits a $readmemh-compatible
hex file (one 16-bit word per line, word-addressed from ROM base 100000),
loadable by both Icarus (cosim) and Quartus (block-RAM init).

The 1801VM1 reset reads 177716 -> 100000 and begins executing at 100000. The
program:
  1. writes 177664 = 0o1330 (full screen, standard scroll base);
  2. draws the Phase-4 test picture into video RAM 040000-077777 (colour-mode
     semantics, 2 bits/pixel): 4 vertical 64-px bars black/blue/green/red, an
     all-ones border (red in colour mode, white in mono), and a main diagonal
     drawn by inverting the underlying pixel (XOR 3);
  3. runs the Phase-2 RAM-in-SDRAM test (word writes + read-back on two SDRAM
     rows, then a byte-write whose masking is verified);
  4. parks in the success (or failure) self-loop.

The park loops sit at FIXED addresses at the head of the ROM so they never move
as the program grows (they are hardcoded in ocbk_top.sv / qbus_sdram_tb.sv):

  success self-loop PC = 100004 (octal)   <- oracles / pLedPwr key off this
  failure self-loop PC = 100012 (octal)

--core-only emits just the parks + RAM test (no drawing) - used by the Phase-2
qbus_sdram cosim, which would otherwise spend hours simulating the ~8K-word
picture fill.
"""
import sys

ROM_WORDS = 256   # on-chip ROM depth (words), from 100000
ROM_BASE = 0o100000

PC_SUCCESS = 0o100004
PC_FAIL = 0o100012

# BK video RAM and picture geometry (colour mode: 256 px = 32 words / line)
VRAM = 0o040000
BAR_PAT = [0x0000, 0x5555, 0xAAAA, 0xFFFF]   # all-0 / all-1 / all-2 / all-3


def render_image():
    """The picture the ROM draw code produces, as 8192 vram words (bit-exact
    mirror of the assembly below - keep the two in sync)."""
    vram = [0] * 8192
    for r in range(256):                      # vertical bars
        for w in range(32):
            vram[r * 32 + w] = BAR_PAT[w // 8]
    for w in range(32):                       # top/bottom border lines
        vram[w] = 0xFFFF
        vram[255 * 32 + w] = 0xFFFF
    for r in range(256):                      # left/right edge pixels (red)
        vram[r * 32] |= 0x0003
        vram[r * 32 + 31] |= 0xC000
    for r in range(256):                      # main diagonal: invert the pixel
        vram[r * 32 + r // 8] ^= 0x3 << (2 * (r % 8))
    return vram


class Asm:
    """Tiny PDP-11 word assembler: labels + BR/Bcc/SOB/address fixups."""

    def __init__(self):
        self.words, self.labels, self.fix = [], {}, []

    def label(self, name):
        self.labels[name] = len(self.words)

    def emit(self, *ws):
        self.words.extend(ws)

    def br(self, opc, target):               # BR/BNE/BEQ...
        self.fix.append(("br", len(self.words), opc, target))
        self.words.append(0)

    def sob(self, reg, target):
        self.fix.append(("sob", len(self.words), reg, target))
        self.words.append(0)

    def addr(self, target):                  # absolute byte address of a label
        self.fix.append(("addr", len(self.words), 0, target))
        self.words.append(0)

    def resolve(self):
        for kind, idx, a, t in self.fix:
            tgt = self.labels[t]
            if kind == "br":
                off = tgt - (idx + 1)
                assert -128 <= off <= 127, f"branch to {t} out of range"
                self.words[idx] = a | (off & 0xFF)
            elif kind == "sob":
                off = (idx + 1) - tgt
                assert 0 <= off <= 63, f"SOB to {t} out of range"
                self.words[idx] = 0o077000 | (a << 6) | off
            else:
                self.words[idx] = ROM_BASE + 2 * tgt
        return self.words


BR, BNE, BEQ = 0o000400, 0o001000, 0o001400


def build(core_only):
    a = Asm()

    # --- fixed park block (addresses hardcoded in RTL/testbenches) --------
    a.br(BR, "start")                        # 100000
    a.label("success")
    a.emit(0o005003)                         # 100002  CLR R3 (success marker)
    a.emit(0o000777)                         # 100004  BR .   <- PC_SUCCESS
    a.label("fail")
    a.emit(0o012704, 0o000001)               # 100006  MOV #1,R4 (failure marker)
    a.emit(0o000777)                         # 100012  BR .   <- PC_FAIL

    a.label("start")
    if not core_only:
        # --- video mode: full screen, standard scroll base ----------------
        a.emit(0o012737, 0o001330, 0o177664)  # MOV #1330,@#177664

        # --- vertical bars: 256 lines x (4 bars x 8 words) -----------------
        a.emit(0o012700, VRAM)               # MOV #VRAM,R0
        a.emit(0o012705, 0o000400)           # MOV #256.,R5
        a.label("line")
        a.emit(0o012701)                     # MOV #pat,R1
        a.addr("pat")
        a.emit(0o012704, 0o000004)           # MOV #4,R4
        a.label("bar")
        a.emit(0o012102)                     # MOV (R1)+,R2
        a.emit(0o012703, 0o000010)           # MOV #8.,R3
        a.label("fill")
        a.emit(0o010220)                     # MOV R2,(R0)+
        a.sob(3, "fill")
        a.sob(4, "bar")
        a.sob(5, "line")

        # --- top + bottom border lines (all-ones words) --------------------
        a.emit(0o012700, VRAM)               # MOV #VRAM,R0
        a.emit(0o012703, 0o000040)           # MOV #32.,R3
        a.label("btop")
        a.emit(0o012720, 0o177777)           # MOV #-1,(R0)+
        a.sob(3, "btop")
        a.emit(0o012700, 0o077700)           # MOV #line255,R0
        a.emit(0o012703, 0o000040)           # MOV #32.,R3
        a.label("bbot")
        a.emit(0o012720, 0o177777)           # MOV #-1,(R0)+
        a.sob(3, "bbot")

        # --- left/right edge pixels (red) -----------------------------------
        a.emit(0o012700, VRAM)               # MOV #VRAM,R0
        a.emit(0o012703, 0o000400)           # MOV #256.,R3
        a.label("edge")
        a.emit(0o052710, 0o000003)           # BIS #3,(R0)       left pixel
        a.emit(0o052760, 0o140000, 0o000076) # BIS #140000,76(R0) right pixel
        a.emit(0o062700, 0o000100)           # ADD #100,R0        next line
        a.sob(3, "edge")

        # --- main diagonal: XOR 3 into pixel (r, r) --------------------------
        # word byte offset = (r & ~7)/4; pixel mask = 3 << 2*(r & 7)
        a.emit(0o012700, VRAM)               # MOV #VRAM,R0 (line base)
        a.emit(0o005005)                     # CLR R5        r
        a.label("diag")
        a.emit(0o010501)                     # MOV R5,R1
        a.emit(0o042701, 0o000007)           # BIC #7,R1     r & ~7
        a.emit(0o006201)                     # ASR R1
        a.emit(0o006201)                     # ASR R1        -> byte offset
        a.emit(0o010502)                     # MOV R5,R2
        a.emit(0o042702, 0o177770)           # BIC #~7,R2    r & 7
        a.emit(0o012704, 0o000003)           # MOV #3,R4     pixel mask
        a.emit(0o005702)                     # TST R2
        a.br(BEQ, "dox")
        a.label("dsh")
        a.emit(0o006304)                     # ASL R4
        a.emit(0o006304)                     # ASL R4        mask <<= 2
        a.sob(2, "dsh")
        a.label("dox")
        a.emit(0o010003)                     # MOV R0,R3
        a.emit(0o060103)                     # ADD R1,R3
        a.emit(0o074413)                     # XOR R4,(R3)
        a.emit(0o062700, 0o000100)           # ADD #100,R0   next line
        a.emit(0o005205)                     # INC R5
        a.emit(0o020527, 0o000400)           # CMP R5,#256.
        a.br(BNE, "diag")

    # --- Phase-2 RAM-in-SDRAM test (word x2 rows + byte masking) ----------
    a.emit(0o012700, 0o001000)               # MOV #001000,R0
    a.emit(0o012701, 0o052525)               # MOV #052525,R1
    a.emit(0o010110)                         # MOV R1,(R0)
    a.emit(0o011002)                         # MOV (R0),R2
    a.emit(0o020102)                         # CMP R1,R2
    a.br(BNE, "fail")
    a.emit(0o012700, 0o002000)               # MOV #002000,R0 (other SDRAM row)
    a.emit(0o012701, 0o025252)               # MOV #025252,R1
    a.emit(0o010110)                         # MOV R1,(R0)
    a.emit(0o011002)                         # MOV (R0),R2
    a.emit(0o020102)                         # CMP R1,R2
    a.br(BNE, "fail")
    a.emit(0o012700, 0o003000)               # MOV #003000,R0
    a.emit(0o012701, 0o177777)               # MOV #177777,R1
    a.emit(0o010110)                         # MOV R1,(R0)     prime word
    a.emit(0o112710, 0o000125)               # MOVB #125,(R0)  low byte only
    a.emit(0o011002)                         # MOV (R0),R2
    a.emit(0o012703, 0o177525)               # MOV #177525,R3  expected
    a.emit(0o020302)                         # CMP R3,R2
    a.br(BNE, "fail")
    # --- RMW (DATIO/DATIOB) test: read-modify-write cycles run DIN then DOUT
    #     under ONE SYNC - the write phase must land in SDRAM (this is the bus
    #     shape the picture draw's XOR/BIS depend on) --------------------------
    a.emit(0o012700, 0o001000)               # MOV #001000,R0
    a.emit(0o005010)                         # CLR (R0)
    a.emit(0o005210)                         # INC (R0)        -> 1
    a.emit(0o062710, 0o000005)               # ADD #5,(R0)     -> 6
    a.emit(0o052710, 0o000120)               # BIS #120,(R0)   -> 126
    a.emit(0o042710, 0o000100)               # BIC #100,(R0)   -> 026
    a.emit(0o105210)                         # INCB (R0)       -> 027
    a.emit(0o011002)                         # MOV (R0),R2
    a.emit(0o020227, 0o000027)               # CMP R2,#27
    a.br(BNE, "fail")
    a.br(BR, "success")

    if not core_only:
        a.label("pat")
        a.emit(*BAR_PAT)                     # bar pattern table (data)

    return a.resolve()


def main():
    args = [x for x in sys.argv[1:]]
    core_only = "--core-only" in args
    args = [x for x in args if x != "--core-only"]
    out = args[0] if args else "ram_test.hex"

    words = build(core_only)
    if len(words) > ROM_WORDS:
        raise SystemExit(f"program is {len(words)} words, exceeds ROM_WORDS={ROM_WORDS}")
    mem = words + [0] * (ROM_WORDS - len(words))
    # One 16-bit hex word per line, word-addressed from 0 (= BK address 100000).
    # No comments: Quartus block-RAM inference via $readmemh is picky.
    with open(out, "w") as f:
        for w in mem:
            f.write(f"{w:04x}\n")
    print(f"wrote {out} ({ROM_WORDS} words, program {len(words)} words"
          f"{', core-only' if core_only else ''})")


if __name__ == "__main__":
    main()
