#!/usr/bin/env python3
"""Generate the ROM-write-timeout functional oracle program (Phase 7).

Proves that a WRITE to ROM gets NO bus reply -> the CPU's qbto timer expires
(56..63 clocks) -> trap 4. This is authentic mask-ROM behaviour (real BK ROMs
never assert RPLY on a write) and BkEmu agrees (ReadOnlyMemory.write ->
not-written -> BUS_ERROR -> vector 4). Two sub-tests on the BK-0010 SoC stack:

  1. The conditionless "write until trap 4" fast screen-clear idiom: a CLR (R0)+
     loop with NO counter, marching up through screen RAM; the write at 100000
     (the start of mask ROM) traps -> a vector-4 handler ends the clear. The RAM
     below 100000 is verified cleared; the ROM word at 100000 is verified
     UNCHANGED (the write never landed).
  2. RMW-to-ROM: INC @#100000 - a DATIO(B) whose read half legitimately replies
     but whose write half must still time out -> trap 4 (the qbus_mem S_REPLY
     ROM-cycle early-release; the one sharp edge of the change).

Data-checking oracle (COSIM PASS at the pinned success park), NOT a timing
golden. Park loops match sim/bk11: success 001004, fail 001012 - the tb keys
off them. The ROM stub (JMP @#001000 at BK 100000) is poked directly by the tb
into the SDRAM ROM region (word 0x4000); see sim/romwr/romwr_tb.v.
"""
import sys

from gen_mem import Asm, BR, BNE, BEQ

PROG_BASE = 0o001000
STACK     = 0o000700            # SP: below the program, above the vectors
SCR_LO    = 0o077000            # start of the conditionless clear (marches 256
                                #   words up into 100000). Real routines start at
                                #   040000 - the RAM->ROM boundary trap is the
                                #   point, not the size of the cleared region.
ROM_BASE  = 0o100000            # first mask-ROM word (a write here must trap 4)
ROMSTUBW  = 0o000137            # tb pokes this (JMP opcode) at ROM word 0; the
                                #   boot stub AND the read-back invariant
FILLPAT   = 0o125252            # pre-fill so "cleared" is a real change

_ok = [0]


def expect_eq(a):
    """After a CMP: fall through if equal, else JMP @#fail (branch-reach-proof)."""
    n = _ok[0]
    _ok[0] += 1
    a.br(BEQ, f"__ok{n}")
    a.emit(0o000137)                        # JMP @#fail
    a.addr("fail")
    a.label(f"__ok{n}")


def cmp_mem_imm(a, addr, imm):
    a.emit(0o023727, addr, imm)             # CMP @#addr,#imm
    expect_eq(a)


def build_program():
    a = Asm(base=PROG_BASE)

    # --- fixed park block (addresses hardcoded in the tb) -------------------
    a.br(BR, "start")                       # 001000
    a.label("success")
    a.emit(0o005003)                        # 001002  CLR R3 (success marker)
    a.label("sloop")
    a.emit(0o000777)                        # 001004  BR .   <- success
    a.label("fail")
    a.emit(0o012704, 0o000001)              # 001006  MOV #1,R4
    a.label("floop")
    a.emit(0o000777)                        # 001012  BR .   <- failure

    a.label("start")
    a.emit(0o012706, STACK)                 # MOV #STACK,SP

    # --- pre-fill SCR_LO..077776 with FILLPAT (so "cleared" is a real change),
    #     stopping exactly at 100000 so the pre-fill never writes ROM ----------
    a.emit(0o012700, SCR_LO)                # MOV #SCR_LO,R0
    a.emit(0o012701, FILLPAT)               # MOV #FILLPAT,R1
    a.label("pf")
    a.emit(0o010120)                        # MOV R1,(R0)+
    a.emit(0o022700, ROM_BASE)              # CMP #100000,R0
    a.br(BNE, "pf")

    # --- 1. conditionless clear: CLR (R0)+ with NO counter; only the trap-4
    #        from the write at 100000 (mask ROM) breaks the loop ---------------
    a.emit(0o012737)                        # MOV #clr_done,@#4 (install handler)
    a.addr("clr_done")
    a.emit(0o000004)
    a.emit(0o012700, SCR_LO)                # MOV #SCR_LO,R0
    a.label("clr")
    a.emit(0o005020)                        # CLR (R0)+   <- conditionless
    a.br(BR, "clr")                         # BR clr      (trap-4 is the only exit)
    a.label("clr_done")                     # trap-4 entry (write at 100000 refused)
    a.emit(0o062706, 0o000004)              # ADD #4,SP (drop the un-RTI-able frame)
    a.emit(0o012737)                        # MOV #fail,@#4 (restore the vector)
    a.addr("fail")
    a.emit(0o000004)

    # the clear reached the RAM->ROM boundary: last RAM word cleared, ROM intact
    cmp_mem_imm(a, SCR_LO, 0)               # first cleared word == 0
    cmp_mem_imm(a, ROM_BASE - 2, 0)         # last RAM word (077776) == 0
    cmp_mem_imm(a, ROM_BASE, ROMSTUBW)      # ROM word 0 UNCHANGED (write trapped)

    # --- 2. RMW-to-ROM: INC @#100000 - read half replies, write half must trap
    a.emit(0o012737)                        # MOV #rmw_done,@#4 (install handler)
    a.addr("rmw_done")
    a.emit(0o000004)
    a.emit(0o005237, ROM_BASE)              # INC @#100000  (DATIO write must trap)
    a.emit(0o000137)                        # replied?! (no trap) -> JMP @#fail
    a.addr("fail")
    a.label("rmw_done")                     # trap-4 entry (write half refused)
    a.emit(0o062706, 0o000004)              # ADD #4,SP (drop the frame)
    a.emit(0o012737)                        # MOV #fail,@#4 (restore the vector)
    a.addr("fail")
    a.emit(0o000004)
    cmp_mem_imm(a, ROM_BASE, ROMSTUBW)      # ROM unchanged by the aborted INC

    # --- all checks passed -> success park -----------------------------------
    a.emit(0o000137)                        # JMP @#success
    a.addr("success")

    return a.resolve(), a.labels


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    prog, labels = build_program()

    def word_at(label):
        return PROG_BASE + 2 * labels[label]

    # the pinned park addresses the tb keys on
    assert word_at("sloop") == 0o001004, oct(word_at("sloop"))
    assert word_at("floop") == 0o001012, oct(word_at("floop"))
    # the program must stay below the screen RAM it clears
    assert PROG_BASE + 2 * len(prog) <= SCR_LO, \
        f"program spills into the screen area ({len(prog)} words)"

    ram = [0] * 16384                       # BK RAM 000000-077777
    ram[0o004 >> 1] = word_at("fail")       # trap 4 (bus timeout) -> fail park;
    ram[0o006 >> 1] = 0o000340              #   the handlers temporarily re-point it
    for i, w in enumerate(prog):
        ram[(PROG_BASE >> 1) + i] = w

    with open(f"{outdir}/romwr_ram.hex", "w") as f:
        for w in ram:
            f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/romwr_ram.hex ({len(prog)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
