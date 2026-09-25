#!/usr/bin/env python3
"""Generate the МПИ slot functional oracle program (slave-only bridge).

Proves that a real expansion module attached through qbus_slot can be read,
written and read-modify-written by the CPU, that it can take the host ROM away
over the deselect lines, and that an address NOBODY claims still bus-times-out
to trap 4. Runs on the BK-0010 SoC stack (see sim/slot/slot_soc_tb.v); the
module itself is sim/slot/mpi_slave_model.v.

Sub-tests, in order:

  0. The START-VECTOR merge window is ARMED, not permanent. Under +vecboot the
     module drives 0166400 at 0177716 on EVERY read of it (no reply - the vm1
     self-replies for its own 177700-177717 block), and reaching this code at
     all already proves the boot merge happened: the tb pokes 0100000, where an
     unmerged machine lands, with a jump to the fail park. This re-read must
     then come back as the PLAIN 0100100 - SYS_START | the idle keyboard bit -
     because the window closed with the start-vector read. A permanently open
     window would return 0166500 here and corrupt every MONITOR poll of the
     keyboard (bit 6) and the tape (bit 5) on a real machine.

  1. DATI  - read the module's preset registers. A wrong address on the pins
     shows up here as wrong DATA, because the model presets a per-word value.
  2. DATO  - word write then read back.
  3. DATOB - byte writes to both lanes, then a word read back. This is what
     pins the dual-purpose WTBT across the bridge (write flag at SYNC, byte
     flag at DOUT).
  4. DATIO - INC @#reg, a read-modify-write under ONE held SYNC. The mandated
     RMW coverage (the AGENTS.md rule): a bridge that let the module re-arm on
     SYNC-rise would drop the write half and this leg would see a stale value.
  5. qbto  - a read of an address neither ocbk nor the module decodes must get
     no reply at all -> trap 4. Proves the bridge does not "helpfully" answer.
  6. Deselect - write the module's control register to make it assert BAS,
     then read 120000: the MODULE's pattern must come back, not ocbk's ROM.
     Then release it and read again: ocbk's ROM must return. Checked in both
     directions so a stuck-asserted deselect cannot pass.
  7. The E-STROBED window, i.e. the МСТД topology. 160000-177577 has its OWN
     deselect (BAS2) and its own read strobe: a module's ROM there is clocked
     by the 037's E, not by DIN. Three parts - BAS2 alone must move only the
     160000 window, releasing it must give that window back, and both deselects
     together must hand over both windows. A bridge that does not export E
     leaves 160000 mute and the read traps, which is what a real МСТД module
     did on the board before E was wired. 7d then asserts **M11** alone and
     requires that NOTHING move: the deselect wires are physically per-model on
     a real machine (BAS/BAS2/MON10 on a BK-0010, M11/P4O on a BK-0011M) while
     the adapter routes all of them in both cases, so the bridge's model gate is
     what emulates which wires exist.

Data-checking oracle (COSIM PASS at the pinned success park), NOT a timing
golden. Park loops match sim/bk11 and sim/romwr: success 001004, fail 001012.
"""
import sys

from gen_mem import Asm, BR, BEQ

PROG_BASE = 0o001000
STACK     = 0o000700

REG_BASE  = 0o177740            # the module's register file (8 words)
REG_A     = REG_BASE + 0o2      # a scratch register used by most legs
CTRL      = REG_BASE + 0o16     # the module's control register
DEAD_ADDR = 0o177600            # decoded by NOBODY -> qbto -> trap 4
SYS_REG   = 0o177716            # the system register / start-vector read
SYS_IDLE  = 0o100100            # SYS_START | bit 6 (no key down), no module
ROM_WIN   = 0o120000            # module ROM window 1 (BAS, normal DIN strobe)
ROM2_WIN  = 0o160000            # module ROM window 2 (BAS2, the E strobe)

# Must match mpi_slave_model.v's presets and pattern.
PRESET0   = 0o125252            # regs[i] = 0125252 + i
PRESET1   = 0o125253
# the model's address-derived words: base ^ addr[13:1] (13 bits, as the RTL).
# Different bases per window - addr[13:1] alone cannot tell 120000 from 160000,
# so a read served by the WRONG window would otherwise still look correct.
ROMPAT0   = 0o052525 ^ ((ROM_WIN  >> 1) & 0x1FFF)
ROMPAT2   = 0o025252 ^ ((ROM2_WIN >> 1) & 0x1FFF)

# The host's own ROM words the tb pokes at each window, so both deselects can be
# checked in BOTH directions. HOSTROM2 is basic10_3.rom word 0, the real image.
HOSTROM   = 0o017171
HOSTROM2  = 0o104405

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
    a.emit(0o005003)                        # 001002  CLR R3
    a.label("sloop")
    a.emit(0o000777)                        # 001004  BR .   <- success
    a.label("fail")
    a.emit(0o012704, 0o000001)              # 001006  MOV #1,R4
    a.label("floop")
    a.emit(0o000777)                        # 001012  BR .   <- failure

    a.label("start")
    a.emit(0o012706, STACK)                 # MOV #STACK,SP

    # --- 0. the start-vector window is spent -------------------------------
    # Getting here at all is the boot-merge check (the tb sends 100000 to the
    # fail park under +vecboot). This is the ARMING check: the module may still
    # be driving 177716, and it must no longer reach the CPU.
    cmp_mem_imm(a, SYS_REG, SYS_IDLE)

    # --- 1. DATI: the module's presets come back through the bridge ---------
    cmp_mem_imm(a, REG_BASE, PRESET0)
    cmp_mem_imm(a, REG_A,    PRESET1)

    # --- 2. DATO: word write, read back ------------------------------------
    a.emit(0o012737, 0o007070, REG_A)       # MOV #007070,@#REG_A
    cmp_mem_imm(a, REG_A, 0o007070)

    # --- 3. DATOB: both byte lanes (the dual-purpose WTBT) ------------------
    a.emit(0o112737, 0o000377, REG_A)       # MOVB #377,@#REG_A      (low lane)
    cmp_mem_imm(a, REG_A, 0o007377)
    a.emit(0o112737, 0o000125, REG_A + 1)   # MOVB #125,@#REG_A+1    (high lane)
    cmp_mem_imm(a, REG_A, 0o052777)

    # --- 4. DATIO: read-modify-write under one SYNC ------------------------
    a.emit(0o012737, 0o000100, REG_A)       # MOV #100,@#REG_A
    a.emit(0o005237, REG_A)                 # INC @#REG_A    <- the RMW
    cmp_mem_imm(a, REG_A, 0o000101)
    a.emit(0o005337, REG_A)                 # DEC @#REG_A    <- and back
    cmp_mem_imm(a, REG_A, 0o000100)

    # --- 5. an address nobody decodes must trap 4 --------------------------
    a.emit(0o012737)                        # MOV #dead_ok,@#4
    a.addr("dead_ok")
    a.emit(0o000004)
    a.emit(0o013700, DEAD_ADDR)             # MOV @#DEAD_ADDR,R0  -> must trap
    a.emit(0o000137)                        # replied?! -> JMP @#fail
    a.addr("fail")
    a.label("dead_ok")                      # trap-4 entry
    a.emit(0o062706, 0o000004)              # ADD #4,SP (the frame is not RTI-able)
    a.emit(0o012737)                        # MOV #fail,@#4 (restore)
    a.addr("fail")
    a.emit(0o000004)

    # --- 6a. deselect ON: the MODULE answers in the BASIC region -----------
    a.emit(0o012737, 0o000001, CTRL)        # MOV #1,@#CTRL   (assert BAS only)
    cmp_mem_imm(a, ROM_WIN, ROMPAT0)
    # BAS covers 120000-157777 ONLY. 160000 is BAS2's window and must still be
    # the HOST's - a mask that hands segs 6,7 to BAS makes ocbk stand down over
    # a window no module has claimed, and this read traps instead.
    cmp_mem_imm(a, ROM2_WIN, HOSTROM2)

    # --- 6b. deselect OFF: ocbk's own ROM answers again --------------------
    a.emit(0o005037, CTRL)                  # CLR @#CTRL      (release BAS)
    cmp_mem_imm(a, ROM_WIN, HOSTROM)

    # --- 7. the E-STROBED window (the МСТД topology) -----------------------
    # 160000-177577 is a SEPARATE deselect (BAS2) AND a separate read strobe:
    # the module's ROM there is clocked by the 037's E, not by DIN. A bridge
    # that does not export E leaves this window mute and the read traps - which
    # is exactly what a real МСТД module did on the board.
    # 7a. BAS2 alone must NOT disturb window 1's owner...
    a.emit(0o012737, 0o000004, CTRL)        # MOV #4,@#CTRL   (assert BAS2 only)
    cmp_mem_imm(a, ROM_WIN,  HOSTROM)       #   120000 still the host's
    cmp_mem_imm(a, ROM2_WIN, ROMPAT2)       #   160000 now the module's, via E
    # 7b. ...and releasing it gives 160000 back to the host.
    a.emit(0o005037, CTRL)                  # CLR @#CTRL
    cmp_mem_imm(a, ROM2_WIN, HOSTROM2)

    # 7d. M11 MUST BE IGNORED ON A BK-0010, even though the module asserts it.
    # The wire is physically present only on a BK-0011M; the adapter routes it
    # in both cases, so the bridge's model gate is what emulates that. Note the
    # gate. On a BK-0011M M11 takes BOS at 140000-157777 (segs 4,5) so the
    # module can put RAM there - a DIFFERENT window from the 160000 one, which
    # needs no wire at all because МСТД is itself an МПИ board and comes out
    # when another module goes in. This stays as the BK-0010 half of the
    # contract; sim/slot/dsl_tb.v owns the BK-0011M half.
    a.emit(0o012737, 0o000010, CTRL)        # MOV #10,@#CTRL  (assert M11 only)
    cmp_mem_imm(a, ROM_WIN,  HOSTROM)       #   120000 still the host's
    cmp_mem_imm(a, ROM2_WIN, HOSTROM2)      #   160000 still the host's - M11 is
                                            #   a BK-0011M wire and this is a
                                            #   BK-0010
    a.emit(0o005037, CTRL)                  # CLR @#CTRL

    # 7c. both windows at once, the real МСТД configuration.
    a.emit(0o012737, 0o000005, CTRL)        # MOV #5,@#CTRL   (BAS | BAS2)
    cmp_mem_imm(a, ROM_WIN,  ROMPAT0)
    cmp_mem_imm(a, ROM2_WIN, ROMPAT2)
    a.emit(0o005037, CTRL)                  # CLR @#CTRL

    # --- all checks passed -> success park ---------------------------------
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

    ram = [0] * 16384                       # BK RAM 000000-077777
    ram[0o004 >> 1] = word_at("fail")       # trap 4 -> fail park by default
    ram[0o006 >> 1] = 0o000340
    for i, w in enumerate(prog):
        ram[(PROG_BASE >> 1) + i] = w

    with open(f"{outdir}/slot_ram.hex", "w") as f:
        for w in ram:
            f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/slot_ram.hex ({len(prog)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
