#!/usr/bin/env python3
"""Generate the Phase-8 SMK512 segmented-RAM functional oracle program.

Imports the tiny PDP-11 assembler from gen_mem.py (and the check helpers from
gen_bk11_test.py) and builds the images sim/smk/smk_soc_tb.v preloads (a
DATA-checking oracle like sim/bk11, NOT a timing golden):

  smk_page6.hex : 8192 words = physical RAM page 6 (SDRAM 0x2C000-0x2DFFF),
                  the fixed 000000-037777 region: vectors (trap 4 -> the fail
                  park) + stage 2. Page 6 is immune to every SMK mode - the
                  safe residence.
  smk_ram0.hex  : 16384 words = SMK RAM page 0 (abs segments 0-7, SDRAM
                  0x40000-0x43FFF): the stage-0 boot stub at abs-seg-0 word 0
                  and the section-5 mode-switch routine at abs-seg-2 word
                  0o2000. THE PRELOAD IS A TB LIBERTY: real SMK DRAM powers on
                  as garbage, and with the BIOS ROM segments MK_NONE this
                  increment DIP-8-ON hardware is deliberately non-booting -
                  the tb owns the SDRAM model, so it plants the stub where the
                  reset map (mode SYS: seg4 = P+0) puts the 140000 start
                  vector.

Boot: the 177716 read returns SYS_START11 = 140000; under the SMK reset
layout (SYS) that is SMK RAM abs seg 0 word 0 -> the stub JMPs to stage 2 at
001000 in page 6.

Stage 2 walks the BkEmu SmkMemoryManager contract on the real SoC stack:
the 177130 write reply + no-commit-without-arm + write-only read-timeout,
SYS/RAM10/ALL/STD10/STD11/HLT10 layouts with fill/verify and the +4 rotation
aliasing, two extra pages (2 and 8 - the v2/v0 scatter bits end-to-end),
executing FROM SMK RAM and switching the mode under the running code, RMW
(DATIO) in SMK RAM, HLT10 seg-0 read-only (write + RMW write-half -> trap 4,
value intact), the seg-7 0177000 cap, the BIOS-ROM sockets (MK_NONE -> trap
4, incl. 160000 under STD11 - the SMK shadows the MSTD socket), STD11
passthrough (window-1 banking + ROM overlay + top ROM + a 177662 write),
and the RESET instruction preserving the layout (DCLO-only reset). The tb
then re-pulses DCLO: the second boot only reaches the success park again if
DCLO restored SYS (the RUN_FLAG word routes stage 2 to a short re-verify
which also proves SMK RAM content SURVIVED the warm reset).

Park loops (pinned, the tb keys off them):
  success self-loop PC = 001004
  failure self-loop PC = 001012
Every check is BEQ-over-JMP (branch-reach-proof); any bus timeout traps
through vector 4 to the fail park unless a detour expects it.
"""
import sys

from gen_mem import Asm, BR, BEQ
from gen_bk11_test import expect_eq, cmp_mem_imm, bank_write, expect_trap4

PAGE_WORDS = 8192
SMK_IMG_WORDS = 16384        # SMK page 0 = 8 segments x 2 Kwords
PROG_BASE = 0o001000

BIT11 = 0o004000             # the 177716 banking-ENABLE bit
REG = 0o177130               # the SMK layout register
ARM = 0o000006               # the strobe arm pattern

# SMK modes (register bits 6:4; BkEmu SmkMemoryManager)
SYS, STD10, RAM10, ALL = 0o160, 0o060, 0o120, 0o020
STD11, RAM11, HLT10, HLT11 = 0o140, 0o040, 0o100, 0o000

RUN_FLAG = 0o000760          # page-6 scratch: 0 = first pass, !=0 = post-DCLO

# in-segment offsets (bytes). Keep clear of the stub (seg words 0-1) and the
# section-5 routine (abs-seg-2 words 0o2000-0o2007 = byte offset 0o4000).
OFF_S = 0o2000               # fill/verify offset
OFF_B = 0o3000               # RMW / write-probe offset
ROUTINE = 0o124000           # the section-5 routine: seg 2 + byte 0o4000
ROUT_IMG_WORD = 2 * 2048 + 0o2000   # ...at this smk_ram0 image word

SYSPAT = 0o171717
S6PAT = 0o111111
B7PAT = 0o166166
PG2PAT = 0o104104
PG8PAT = 0o140441
W1PAT = 0o031313
S1PAT = 0o054054

# tb-poked markers, shared with the bk11 oracle conventions (keep in sync
# with sim/smk/smk_soc_tb.v: ROMPAT0 at SDRAM 0x30000, the top-ROM stub +
# TOPPAT at 0x38000-0x38002)
ROMPAT0 = 0o123456
TOPPAT = 0o054321


def seg(n):
    return 0o100000 + n * 0o10000


def pat_s(n):
    return 0o060600 + n


def smk_mode(a, val):
    """The two-phase strobe write pair (BkEmu test setMode)."""
    a.emit(0o012737, ARM, REG)              # MOV #6,@#177130 (arm)
    a.emit(0o012737, val, REG)              # MOV #mode,@#177130 (commit)


def build_stage2():
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
    a.emit(0o012706, 0o000700)              # MOV #700,SP (stack in page 6)
    a.emit(0o005737, RUN_FLAG)              # TST @#RUN_FLAG
    a.br(BEQ, "first")
    a.emit(0o000137)                        # JMP @#second (post-DCLO pass)
    a.addr("second")
    a.label("first")
    a.emit(0o005237, RUN_FLAG)              # INC @#RUN_FLAG

    # --- 1. the register itself ---------------------------------------------
    # 1a. a commit attempt WITHOUT a prior arm: the write must be REPLIED
    # (parking at fail via trap 4 if not) but must NOT commit - SYS seg 0
    # stays deselected (trap 4 on read).
    a.emit(0o012737, RAM10, REG)
    expect_trap4(a, lambda: a.emit(0o005737, seg(0)))   # TST @#100000
    # 1b. the SYS BIOS-ROM sockets: MK_NONE this increment (no BIOS blob)
    expect_trap4(a, lambda: a.emit(0o005737, seg(6)))
    expect_trap4(a, lambda: a.emit(0o005737, seg(7)))
    # 1c. write-only: a 177130 READ gets no reply -> trap 4 (BkEmu BUS_ERROR;
    # no floppy controller is modelled)
    expect_trap4(a, lambda: a.emit(0o013700, REG))      # MOV @#177130,R0

    # --- 2. SYS fill: seg4 = abs S0, seg2 = abs S6 ---------------------------
    a.emit(0o012737, SYSPAT, seg(4) + OFF_S)
    cmp_mem_imm(a, seg(4) + OFF_S, SYSPAT)
    a.emit(0o012737, S6PAT, seg(2) + OFF_S)
    cmp_mem_imm(a, seg(2) + OFF_S, S6PAT)

    # --- 3. RAM10: aliasing vs SYS, full fill, seg-7 cap ---------------------
    smk_mode(a, RAM10)
    cmp_mem_imm(a, seg(0) + OFF_S, SYSPAT)  # RAM10 seg0 = SYS seg4 = abs S0
    cmp_mem_imm(a, seg(6) + OFF_S, S6PAT)   # RAM10 seg6 = SYS seg2 = abs S6
    for n in range(8):
        a.emit(0o012737, pat_s(n), seg(n) + OFF_S)
    a.emit(0o012737, B7PAT, 0o176776)       # seg-7 boundary word (last mapped)
    for n in range(8):
        cmp_mem_imm(a, seg(n) + OFF_S, pat_s(n))
    cmp_mem_imm(a, 0o176776, B7PAT)
    expect_trap4(a, lambda: a.emit(0o005737, 0o177000))   # the cap: trap 4

    # --- 4. ALL rotation aliasing + pages 2 and 8 ----------------------------
    smk_mode(a, ALL)
    for n in range(8):                      # ALL seg n = abs S(n^4)
        cmp_mem_imm(a, seg(n) + OFF_S, pat_s(n ^ 4))
    smk_mode(a, RAM10 | 0o004)              # page 2 (scatter bit v2)
    a.emit(0o012737, PG2PAT, seg(0) + OFF_S)
    cmp_mem_imm(a, seg(0) + OFF_S, PG2PAT)
    smk_mode(a, RAM10 | 0o001)              # page 8 (scatter bit v0)
    a.emit(0o012737, PG8PAT, seg(0) + OFF_S)
    cmp_mem_imm(a, seg(0) + OFF_S, PG8PAT)
    smk_mode(a, RAM10)                      # back to page 0: isolation intact
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))

    # --- 5. execute FROM SMK RAM and switch the mode under the running code --
    # The preloaded routine at abs-seg-2 word 0o2000 (RAM10 seg2 = 124000)
    # arms+commits STD10 from inside itself - seg2 maps to P+2 in BOTH modes,
    # so its own fetches stay put - then JMPs back here.
    a.emit(0o000137, ROUTINE)               # JMP @#124000
    a.label("ret5")
    expect_trap4(a, lambda: a.emit(0o005737, seg(0)))   # STD10 seg0 deselected
    cmp_mem_imm(a, ROUTINE, 0o012737)       # seg2 still S2: its own opcode
    expect_trap4(a, lambda: a.emit(0o005737, seg(6)))   # STD10 seg6 = BIOS socket

    # --- 6. RMW (DATIO) in SMK RAM (STD10 seg2 = abs S2) ---------------------
    a.emit(0o005037, seg(2) + OFF_B)        # CLR  -> 0
    a.emit(0o005237, seg(2) + OFF_B)        # INC  -> 1
    a.emit(0o006337, seg(2) + OFF_B)        # ASL  -> 2
    a.emit(0o052737, 0o000025, seg(2) + OFF_B)  # BIS #25 -> 27
    cmp_mem_imm(a, seg(2) + OFF_B, 0o000027)

    # --- 7. HLT10: seg 0 is READ-ONLY ----------------------------------------
    smk_mode(a, HLT10)
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))            # readable
    expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(0) + OFF_B))
    expect_trap4(a, lambda: a.emit(0o005237, seg(0) + OFF_S))  # INC: write half
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))            # value INTACT
    a.emit(0o012737, S1PAT, seg(1) + OFF_B)             # seg1 stays writable
    cmp_mem_imm(a, seg(1) + OFF_B, S1PAT)

    # --- 8. STD11 passthrough: the standard machine under the SMK ------------
    smk_mode(a, STD11)
    bank_write(a, BIT11 | (1 << 8))         # window 1 -> RAM page 1
    a.emit(0o012737, W1PAT, seg(0) + OFF_S) # std win-1 RAM (037 path) write
    cmp_mem_imm(a, seg(0) + OFF_S, W1PAT)
    bank_write(a, BIT11 | 0o001)            # window 1 -> ROM overlay bank 0
    cmp_mem_imm(a, seg(0), ROMPAT0)         # the tb-poked overlay marker
    cmp_mem_imm(a, 0o140000, 0o000137)      # std top ROM (BOS socket) visible
    cmp_mem_imm(a, 0o140004, TOPPAT)
    expect_trap4(a, lambda: a.emit(0o005737, seg(6)))   # 160000: SMK shadows MSTD
    cmp_mem_imm(a, seg(7) + OFF_S, pat_s(7))            # seg7 = P+7 (page 0)
    # a 177662 write must be replied; value keeps IRQ2 MASKED (no ISR here).
    # The tb checks the vid taps (page=1, mask=1, pal=0o12) at the first park.
    a.emit(0o012737, 0o145000, 0o177662)

    # --- 9. the RESET instruction preserves the layout (DCLO-only reset) -----
    smk_mode(a, RAM10)
    a.emit(0o000005)                        # RESET (pulses nINIT)
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))  # still RAM10 page 0 (a re-init
                                              # to SYS would trap -> fail)

    # --- 10. success, leaving mode = RAM10 (the tb then re-pulses DCLO) ------
    a.emit(0o000137)
    a.addr("success")

    # --- second pass (post-DCLO): SYS restored, SMK RAM content survived -----
    a.label("second")
    expect_trap4(a, lambda: a.emit(0o005737, seg(0)))   # seg0 deselected again
    cmp_mem_imm(a, seg(2) + OFF_S, pat_s(6))   # SYS seg2 = abs S6 (pattern kept)
    cmp_mem_imm(a, seg(4) + OFF_S, pat_s(0))   # SYS seg4 = abs S0 (pattern kept)
    a.emit(0o000137)
    a.addr("success")

    words = a.resolve()
    return words, a.labels


def build_routine(ret5_addr):
    """The section-5 mode-switch routine, position-fixed at ROUTINE (124000)."""
    return [
        0o012737, ARM, REG,                 # MOV #6,@#177130 (arm)
        0o012737, STD10, REG,               # MOV #STD10,@#177130 (commit)
        0o000137, ret5_addr,                # JMP @#ret5 (back into page 6)
    ]


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    s2, labels = build_stage2()

    def word_at(label):
        return PROG_BASE + 2 * labels[label]

    # the pinned park addresses the tb keys on
    assert word_at("sloop") == 0o001004, oct(word_at("sloop"))
    assert word_at("floop") == 0o001012, oct(word_at("floop"))
    assert PROG_BASE + 2 * len(s2) <= 0o030000, \
        f"stage 2 too large ({len(s2)} words)"

    page6 = [0] * PAGE_WORDS
    page6[0o004 >> 1] = word_at("fail")     # trap 4 (bus timeout) -> fail park
    page6[0o006 >> 1] = 0o000340
    for i, w in enumerate(s2):
        page6[(PROG_BASE >> 1) + i] = w

    smk0 = [0] * SMK_IMG_WORDS
    smk0[0] = 0o000137                      # abs-seg-0 word 0: JMP @#001000
    smk0[1] = PROG_BASE                     # (the SYS-mode 140000 start vector)
    for i, w in enumerate(build_routine(word_at("ret5"))):
        smk0[ROUT_IMG_WORD + i] = w

    for name, img in (("smk_page6.hex", page6), ("smk_ram0.hex", smk0)):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/smk_page6.hex + smk_ram0.hex "
          f"(stage 2 {len(s2)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
