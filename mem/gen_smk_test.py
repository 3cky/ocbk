#!/usr/bin/env python3
"""Generate the Phase-8 SMK512 functional oracle program (RAM + BIOS ROM).

Imports the tiny PDP-11 assembler from gen_mem.py (and the check helpers from
gen_bk11_test.py) and builds the images sim/smk/smk_soc_tb.v preloads (a
DATA-checking oracle like sim/bk11, NOT a timing golden):

  smk_page6.hex : 8192 words = physical RAM page 6 (SDRAM 0x2C000-0x2DFFF),
                  the fixed 000000-037777 region: vectors (trap 4 -> the fail
                  park) + stage 2. Page 6 is immune to every SMK mode - the
                  safe residence.
  smk_bios.hex  : 2048 words = the SYNTHETIC SMK BIOS image at SDRAM
                  SMK_BIOS_BASE (0x3A000) - the tb preloads it exactly where
                  the EPCS loader puts the real one. Marker words at the
                  window head / the 177130 offset / the register-space
                  offsets, the stage-0 entry at image offset 0o6400, and the
                  LOAD-BEARING start word at offset 0o7716 (see Boot below).

Boot rides the REAL SMK mechanism (increment 2): the reset layout is SYS with
BOTH BIOS windows live, rom7 covering the whole 0170000-0177777 incl. the
register space, so the CPU's initial-start 177716 read returns
START_W | SEL1 (the open-collector wire-OR; qbus_mem's I/O-page merge) and
PC <- value & 0o177400 = 0o166400 - the stage-0 JMP @#001000 executing FROM
the BIOS ROM (rom6 window). No SMK-RAM preload remains: the section-5
mode-switch routine is copied into SMK RAM by the program itself.

Stage 2 walks the BkEmu SmkMemoryManager contract on the real SoC stack:
the 177130 write reply + no-commit-without-arm, the BIOS windows (one image
at BOTH 160000 and 170000, writes -> trap 4, 177130 READ = BIOS data under
SYS but write-only again elsewhere), the I/O-page overlay OR-merge (177714
pure-BIOS, 177776 BIOS-only reply, 177716 = START_W | SEL1) with the kbd
(177660, trap 4) and vm1-internal (177712, self-served) carve-outs,
SYS/RAM10/ALL/STD10/STD11/HLT10 layouts with fill/verify and the +4 rotation
aliasing, two extra pages (2 and 8 - the v2/v0 scatter bits end-to-end),
executing FROM SMK RAM and switching the mode under the running code, RMW
(DATIO) in SMK RAM, HLT10 seg-0 read-only (write + RMW write-half -> trap 4,
value intact), the per-mode seg-7 restricted extent (HLT10 writes replied
incl. 177674/76 + reads trap; ALL reads back the HLT-written words through
the seg-3 mem-region aliases + writes trap; STD10 fully capped), STD11
passthrough (window-1 banking + ROM overlay + top ROM + a 177662 write +
160000 = BIOS, the SMK shadowing MSTD), the RESET instruction preserving
the layout (DCLO-only reset), and the authentic СТОП/HALT-entry leg: in
HLT10 the program plants the HALT vector at 160002/4 (= SMK RAM seg 6), the
tb pulses key_stop, the vm1's HALT-entry PSW/PC stores at 177676/74 land in
the writable extent (on a stock BK they bus-time-out -> trap 4), and the
handler - reached through the SMK-RAM vector - verifies the stored PC via
the ALL alias. The tb then re-pulses DCLO: the second boot re-runs the real
boot mechanism and only reaches the success park if DCLO restored SYS (BIOS
windows + overlay back, RUN_FLAG routes to a re-verify which also proves SMK
RAM content SURVIVED the warm reset).

--bk10 (BkEmu BK_0010_SMK512) builds the SAME program for a BK-0010 stack,
emitting smk_low10.hex (16384 words = the machine's own RAM 000000-077777 at
SDRAM 0x0000) instead of smk_page6.hex - identical layout, since the SMK never
touches anything below 0100000. The SMK machinery is model-independent, so
only the standard-memory legs differ: the MONITOR ROM stands in for BOS + the
banked window at segs 0,1 (mon_en; read-checked against tb-poked markers and
write-traps like any ROM), the ex-BASIC region 0120000-0157777 is DEAD
wherever the SMK does not cover it (STD11/RAM11 - that configuration carries
no BASIC ROMs), HLT11 is the one mode where mon_en is observable (segs 0-3 all
trap), the STD11 window-1-banking/662/top-ROM section is replaced by those
dead-segment checks, the 177716 merges are against SYS_START = 0100000, and
under SYS a 177662 write must TRAP - the model-detect mechanism the real BIOS
uses (doc/smk64.mac START; a bk11 replies there).

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
LOW10_WORDS = 16384          # --bk10: the whole BK-0010 RAM (000000-077777)
BIOS_WORDS = 2048            # one 4 KB image = one segment
PROG_BASE = 0o001000

BIT11 = 0o004000             # the 177716 banking-ENABLE bit
REG = 0o177130               # the SMK layout register
ARM = 0o000006               # the strobe arm pattern

# SMK modes (register bits 6:4; BkEmu SmkMemoryManager)
SYS, STD10, RAM10, ALL = 0o160, 0o060, 0o120, 0o020
STD11, RAM11, HLT10, HLT11 = 0o140, 0o040, 0o100, 0o000

RUN_FLAG = 0o000760          # page-6 scratch: 0 = first pass, !=0 = post-DCLO

# СТОП magic scratch write (tb watches address AND value - sim/bk11 §13 shape)
STOP_MAGIC_ADDR = 0o000750
STOP_MAGIC_VAL = 0o123321

# in-segment offsets (bytes). Keep clear of the section-5 routine (abs-seg-2
# words 0o2000-0o2007 = byte offset 0o4000) and the HALT vector (seg-6 words
# 1,2).
OFF_S = 0o2000               # fill/verify offset
OFF_B = 0o3000               # RMW / write-probe offset
ROUTINE = 0o124000           # the section-5 routine: RAM10 seg 2 + byte 0o4000

SYSPAT = 0o171717
S6PAT = 0o111111
B7PAT = 0o166166
PG2PAT = 0o104104
PG8PAT = 0o140441
W1PAT = 0o031313
S1PAT = 0o054054

# synthetic-BIOS marker words (also read back through both windows)
BIOSPAT0 = 0o125252          # image word 0 (160000 AND 170000)
BIOSPAT130 = 0o052525        # image offset 0o7130 (the 177130 read under SYS)
BIOSPAT14 = 0o135531         # image offset 0o7714 (177714: pure-BIOS merge)
BIOSPAT76 = 0o117117         # image offset 0o7776 (177776: BIOS-only reply)
START_W = 0o166421           # image offset 0o7716: start 166400 + junk low
                             # bits (proves the low-bit OR-through)
VOLATILE = 0o000144          # SEL1 bits masked in merged compares: kbd (6),
                             # tape (5), write-flag (2)

# seg-7 extent probes: HLT10 writes (land in abs P+7), read back via the ALL
# seg-3 mem-region aliases; EXTPATs planted at abs P+3 in RAM10, read via the
# ALL extent addresses.
HP74 = 0o031031              # HLT10 write @ 177674 (the HALT-debugger word)
HP76 = 0o042042              # HLT10 write @ 177676
HP00 = 0o015015              # HLT10 write @ 177000 (extent low boundary)
HPTOP = 0o106106             # HLT10 write @ 177776 (extent top)
EXTPAT74 = 0o124512          # planted @ 137674 (RAM10) -> ALL extent 177674
EXTPAT16 = 0o120421          # planted @ 137716 (RAM10) -> ALL merged 177716
                             # (bit 15 SET - agrees with the 037 AD15 assist;
                             # no VOLATILE bits)

# --- BK-0010 leg (--bk10; BkEmu BK_0010_SMK512) -----------------------------
# tb-poked markers in the bk10 ROM image (SDRAM 0x4000+ = BK 100000+): the
# MONITOR ROM at segs 0,1 (what mon_en selects) and one word inside the
# ex-BASIC region that must NEVER show through - in that configuration there
# are no BASIC ROMs, so every segment the SMK does not cover is DEAD.
MONPAT0 = 0o152525           # BK 100000 (SDRAM 0x4000)
MONPAT1 = 0o063636           # BK 117776 (SDRAM 0x4FFF), the seg-1 top
BASPAT = 0o177077            # BK 120000 (SDRAM 0x5000) - must stay invisible


def seg(n):
    return 0o100000 + n * 0o10000


def pat_s(n):
    return 0o060600 + n


def smk_mode(a, val):
    """The two-phase strobe write pair (BkEmu test setMode)."""
    a.emit(0o012737, ARM, REG)              # MOV #6,@#177130 (arm)
    a.emit(0o012737, val, REG)              # MOV #mode,@#177130 (commit)


def cmp_reg_imm(a, addr, imm, mask):
    """Read @#addr into R0, clear the mask bits, compare with imm."""
    a.emit(0o013700, addr)                  # MOV @#addr,R0
    a.emit(0o042700, mask)                  # BIC #mask,R0
    a.emit(0o020027, imm)                   # CMP R0,#imm
    expect_eq(a)


def build_stage2(bk10=False):
    a = Asm(base=PROG_BASE)
    # the 177716 system-register start bits (BkEmu Sel1RegisterSystemBits)
    sys_start = 0o100000 if bk10 else 0o140000

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

    # --- 1. the register + the SYS BIOS windows -----------------------------
    # 1a. a commit attempt WITHOUT a prior arm: the write must be REPLIED
    # (parking at fail via trap 4 if not) but must NOT commit - the SYS layout
    # stays live. bk11 proves it through seg 0 (deselected -> trap 4); on a
    # bk10 seg 0 is the monitor ROM, so the proof is the rom7 register-space
    # overlay instead (RAM10 would show the FDD stub's 0 at 177130).
    a.emit(0o012737, RAM10, REG)
    if bk10:
        cmp_mem_imm(a, REG, BIOSPAT130)
    else:
        expect_trap4(a, lambda: a.emit(0o005737, seg(0)))   # TST @#100000
    # 1b. ONE image, BOTH windows: rom6 @160000, rom7 @170000
    cmp_mem_imm(a, seg(6), BIOSPAT0)
    cmp_mem_imm(a, seg(7), BIOSPAT0)
    # 1c. BIOS ROM writes get NO reply -> trap 4 (the ROM-write rule)
    expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(6)))
    expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(7) + 0o1000))
    # 1d. 177130 READ under SYS = the BIOS word (rom7 covers it; the refined
    # invariant - the register decode owns only the WRITE)
    cmp_mem_imm(a, REG, BIOSPAT130)
    # 1e. the kbd-block read carve-out: nothing replies at 177660 in this tb
    # (no bk_kbd014 here), and the overlay must NOT either -> trap 4
    expect_trap4(a, lambda: a.emit(0o005737, 0o177660))
    # 1f. the vm1-internal block: 177712 is self-served (CPU drives its own
    # read data; the overlay must stay silent - the tb's X monitor is the
    # real check here, this read is its tripwire)
    a.emit(0o013700, 0o177712)              # MOV @#177712,R0 (no compare)
    # 1g. BK-0010: segs 0,1 are the machine's own MONITOR ROM (mon_en - the
    # bk10 analogue of the bk11 seg_std vector), read-only like any ROM.
    if bk10:
        cmp_mem_imm(a, seg(0), MONPAT0)
        cmp_mem_imm(a, 0o117776, MONPAT1)
        expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(0)))

    # --- 2. the I/O-page overlay OR-merge ------------------------------------
    # 177714 (nSEL2, io_word = 0): the merge returns the pure BIOS word
    cmp_mem_imm(a, 0o177714, BIOSPAT14)
    # 177776 (no register at all): the overlay alone replies
    cmp_mem_imm(a, 0o177776, BIOSPAT76)
    # 177716: BIOS start word | SEL1 (mask the volatile SEL1 bits; the
    # surviving low bits 4,0 prove the OR-through - THE boot mechanism)
    cmp_reg_imm(a, 0o177716, START_W, VOLATILE)

    # --- 3. SYS fill: seg4 = abs S0, seg2 = abs S6 ---------------------------
    a.emit(0o012737, SYSPAT, seg(4) + OFF_S)
    cmp_mem_imm(a, seg(4) + OFF_S, SYSPAT)
    a.emit(0o012737, S6PAT, seg(2) + OFF_S)
    cmp_mem_imm(a, seg(2) + OFF_S, S6PAT)

    # --- 4. RAM10: aliasing vs SYS, full fill, seg-7 cap ---------------------
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
    # outside SYS there is no BIOS word at 177130, but the КНГМД (FDD
    # controller) stub still replies - a real SMK's floppy controller
    # always does; the no-drive control read is 0 (BkEmu FloppyController.
    # readControlRegister with no selected drive). Was expect_trap4 before
    # the FDD stub - OUR simplification, not BkEmu's; the real BIOS's FDD
    # boot attempt crash-restarted on it (hardware 2026-07-18).
    cmp_mem_imm(a, REG, 0)
    cmp_mem_imm(a, REG + 2, 0)                  # 177132 data reg: ditto
    # no overlay outside SYS: 177716 is the plain SEL1 register again
    cmp_reg_imm(a, 0o177716, sys_start, VOLATILE)
    # plant the ALL-extent probes at abs P+3 (RAM10 seg3 = P+3): the ALL
    # extent maps 177xxx -> abs P+3 (seg 7 ^ 4)
    a.emit(0o012737, EXTPAT74, seg(3) + 0o7674)
    a.emit(0o012737, EXTPAT16, seg(3) + 0o7716)
    # copy the section-5 routine into SMK RAM (abs S2 via RAM10 seg 2) - the
    # increment-1 tb preload is gone, the program owns its SMK RAM content
    a.emit(0o012737, 0o012737, ROUTINE + 0o00)
    a.emit(0o012737, ARM,      ROUTINE + 0o02)
    a.emit(0o012737, REG,      ROUTINE + 0o04)
    a.emit(0o012737, 0o012737, ROUTINE + 0o06)
    a.emit(0o012737, STD10,    ROUTINE + 0o10)
    a.emit(0o012737, REG,      ROUTINE + 0o12)
    a.emit(0o012737, 0o000137, ROUTINE + 0o14)
    a.emit(0o012737)                        # MOV #ret5,@#ROUTINE+16
    a.addr("ret5")
    a.emit(ROUTINE + 0o16)

    # --- 5. ALL rotation aliasing + pages 2 and 8 ----------------------------
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

    # --- 6. execute FROM SMK RAM and switch the mode under the running code --
    # The program-copied routine at abs-seg-2 word 0o2000 (RAM10 seg2 =
    # 124000) arms+commits STD10 from inside itself - seg2 maps to P+2 in
    # BOTH modes, so its own fetches stay put - then JMPs back here.
    a.emit(0o000137, ROUTINE)               # JMP @#124000
    a.label("ret5")
    if bk10:                                # STD10 seg0 = the monitor ROM
        cmp_mem_imm(a, seg(0), MONPAT0)
    else:                                   # STD10 seg0 deselected on a bk11
        expect_trap4(a, lambda: a.emit(0o005737, seg(0)))
    cmp_mem_imm(a, ROUTINE, 0o012737)       # seg2 still S2: its own opcode
    cmp_mem_imm(a, seg(6), BIOSPAT0)        # STD10 seg6 = the BIOS window
    expect_trap4(a, lambda: a.emit(0o005737, 0o177000))  # STD10 extent capped

    # --- 7. RMW (DATIO) in SMK RAM (STD10 seg2 = abs S2) ---------------------
    a.emit(0o005037, seg(2) + OFF_B)        # CLR  -> 0
    a.emit(0o005237, seg(2) + OFF_B)        # INC  -> 1
    a.emit(0o006337, seg(2) + OFF_B)        # ASL  -> 2
    a.emit(0o052737, 0o000025, seg(2) + OFF_B)  # BIS #25 -> 27
    cmp_mem_imm(a, seg(2) + OFF_B, 0o000027)

    # --- 8. HLT10: seg 0 READ-ONLY + the WRITABLE extent ---------------------
    smk_mode(a, HLT10)
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))            # readable
    expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(0) + OFF_B))
    expect_trap4(a, lambda: a.emit(0o005237, seg(0) + OFF_S))  # INC: write half
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))            # value INTACT
    a.emit(0o012737, S1PAT, seg(1) + OFF_B)             # seg1 stays writable
    cmp_mem_imm(a, seg(1) + OFF_B, S1PAT)
    # the extent 177000-177777 is WRITABLE (a timeout would trap -> fail):
    # 177674/76 = the HALT-debugger catch words, 177000/177776 = boundaries
    a.emit(0o012737, HP74, 0o177674)
    a.emit(0o012737, HP76, 0o177676)
    a.emit(0o012737, HP00, 0o177000)
    a.emit(0o012737, HPTOP, 0o177776)
    # ...but NOT readable (write-only extent) -> trap 4
    expect_trap4(a, lambda: a.emit(0o005737, 0o177674))
    # a non-arm 177130 write is replied and commits nothing (layout kept)
    a.emit(0o012737, 0o000120, REG)
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))            # still HLT10 page 0

    # --- 8b. BK-0010 HLT11: the ONE mode where mon_en is observable ----------
    # HLT11 deselects the monitor ROM (BkEmu selectBk10MonitorRom(false)) AND
    # leaves segs 0..3 SMK-uncovered, so 0100000-0137777 is DEAD on a BK-0010
    # (on a bk11 the same mode shows the standard banked window there).
    if bk10:
        smk_mode(a, HLT11)
        expect_trap4(a, lambda: a.emit(0o005737, seg(0)))       # monitor gone
        expect_trap4(a, lambda: a.emit(0o005737, 0o117776))     # ...seg 1 too
        expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(1)))  # write
        expect_trap4(a, lambda: a.emit(0o005737, seg(2)))       # seg 2 dead
        cmp_mem_imm(a, seg(4) + OFF_S, pat_s(4))                # seg4 = P+4

    # --- 9. ALL: the READABLE extent + the cross-mode aliases ----------------
    smk_mode(a, ALL)
    # extent reads (ALL seg7 -> abs P+3): the RAM10-planted probe
    cmp_mem_imm(a, 0o177674, EXTPAT74)
    # the HLT10 extent writes landed in abs P+7 = ALL seg 3 (3^4)
    cmp_mem_imm(a, 0o137674, HP74)
    cmp_mem_imm(a, 0o137676, HP76)
    cmp_mem_imm(a, 0o137000, HP00)
    cmp_mem_imm(a, 0o137776, HPTOP)
    # the extent is read-ONLY in ALL -> a write traps
    expect_trap4(a, lambda: a.emit(0o012737, 0o123123, 0o177674))
    # 177716 through the ALL extent: SMK RAM word | SEL1 (the merge again,
    # now with the extent as the memory side)
    cmp_reg_imm(a, 0o177716, EXTPAT16 | sys_start, VOLATILE)

    # --- 10. a COMMITTED SYS re-selects both BIOS windows --------------------
    # (reset-SYS is covered by boot; this exercises the register-commit SYS
    # arm - without it a broken commit-time rom6/rom7 decode hides behind the
    # reset defaults)
    smk_mode(a, SYS)
    cmp_mem_imm(a, seg(6), BIOSPAT0)        # rom6 back via the commit
    cmp_mem_imm(a, REG, BIOSPAT130)         # rom7 overlay back via the commit
    if bk10:
        cmp_mem_imm(a, seg(0), MONPAT0)     # ...and the monitor ROM with it
        # THE model-detect mechanism the real BIOS uses (doc/smk64.mac START):
        # under SYS the rom7 window makes 177662 a ROM write -> no reply ->
        # trap 4 -> its vector-4 handler commits MODE_STD10 ("для 10"). On a
        # bk11 the very same write is REPLIED (qbus_mem's sel_vreg positive
        # decode is model-gated), which is how the BIOS tells the two apart.
        expect_trap4(a, lambda: a.emit(0o012737, 0o145000, 0o177662))

    # --- 10b. STD11 passthrough: the standard machine under the SMK ----------
    if bk10:
        # On a BK-0010 "standard" means the monitor ROM at segs 0,1 and
        # NOTHING at segs 2..5: the BK_0010_SMK512 configuration carries no
        # BASIC ROMs, so the loaded ROM image must not show through there.
        smk_mode(a, STD11)
        cmp_mem_imm(a, seg(0), MONPAT0)
        cmp_mem_imm(a, 0o117776, MONPAT1)
        expect_trap4(a, lambda: a.emit(0o005737, seg(2)))       # ex-BASIC dead
        expect_trap4(a, lambda: a.emit(0o005737, 0o157776))     # ...to seg 5
        expect_trap4(a, lambda: a.emit(0o012737, 0o123123, seg(3)))
        cmp_mem_imm(a, seg(6), BIOSPAT0)                        # seg6 = BIOS
        cmp_mem_imm(a, seg(7) + OFF_S, pat_s(7))                # seg7 = P+7
        # RAM11 on a bk10: monitor at segs 0,1, segs 2,3 dead, 4..7 SMK
        smk_mode(a, RAM11)
        cmp_mem_imm(a, seg(0), MONPAT0)
        expect_trap4(a, lambda: a.emit(0o005737, seg(3)))
        cmp_mem_imm(a, seg(4) + OFF_S, pat_s(4))
        cmp_mem_imm(a, seg(6) + OFF_S, pat_s(6))
    else:
        build_std11_bk11(a)

    # --- 11. the RESET instruction preserves the layout (DCLO-only reset) ----
    smk_mode(a, RAM10)
    a.emit(0o000005)                        # RESET (pulses nINIT)
    cmp_mem_imm(a, seg(0) + OFF_S, pat_s(0))  # still RAM10 page 0 (a re-init
                                              # to SYS would trap -> fail)

    # --- 12. the authentic СТОП/HALT-entry leg (LAST: the CPU stays in HALT
    # mode after it - only the parks follow) ----------------------------------
    # HLT10: seg 6 = SMK RAM holds the HALT vector; the extent catches the
    # vm1's PSW/PC stores at 177676/74 (on a stock BK they bus-time-out and
    # the CPU takes trap 4 - reaching the handler at all proves BOTH stores
    # replied AND the vector was fetched from SMK RAM).
    smk_mode(a, HLT10)
    a.emit(0o012737)                        # MOV #stop_handler,@#160002
    a.addr("stop_handler")
    a.emit(0o160002)
    a.emit(0o012737, 0o000340, 0o160004)    # HALT-vector PSW
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)   # tb -> key_stop pulse
    a.label("stop_spin")
    a.emit(0o000777)                        # BR . (СТОП lands here)
    a.label("stop_handler")
    # verify the stored PC through the ALL seg-3 alias (abs P+7 word 0o3736)
    smk_mode(a, ALL)
    a.emit(0o023727, 0o137674)              # CMP @#137674,#stop_spin
    a.addr("stop_spin")
    expect_eq(a)
    smk_mode(a, RAM10)                      # the tb replay expects RAM10
    a.emit(0o000137)
    a.addr("success")

    # --- second pass (post-DCLO): SYS + the BIOS windows restored, SMK RAM
    # content survived --------------------------------------------------------
    a.label("second")
    if bk10:
        cmp_mem_imm(a, seg(0), MONPAT0)            # monitor back (SYS mon_en)
    else:
        expect_trap4(a, lambda: a.emit(0o005737, seg(0)))  # seg0 deselected
    cmp_mem_imm(a, seg(6), BIOSPAT0)           # rom6 back (SYS restored)
    cmp_mem_imm(a, REG, BIOSPAT130)            # rom7 overlay back over 177130
    cmp_mem_imm(a, seg(2) + OFF_S, pat_s(6))   # SYS seg2 = abs S6 (pattern kept)
    cmp_mem_imm(a, seg(4) + OFF_S, pat_s(0))   # SYS seg4 = abs S0 (pattern kept)
    a.emit(0o000137)
    a.addr("success")

    words = a.resolve()
    return words, a.labels


def build_std11_bk11(a):
    """The BK-0011M STD11 leg: the standard machine seen under the SMK."""
    smk_mode(a, STD11)
    bank_write(a, BIT11 | (1 << 8))         # window 1 -> RAM page 1
    a.emit(0o012737, W1PAT, seg(0) + OFF_S) # std win-1 RAM (037 path) write
    cmp_mem_imm(a, seg(0) + OFF_S, W1PAT)
    bank_write(a, BIT11 | 0o001)            # window 1 -> ROM overlay bank 0
    cmp_mem_imm(a, seg(0), ROMPAT0)         # the tb-poked overlay marker
    cmp_mem_imm(a, 0o140000, 0o000137)      # std top ROM (BOS socket) visible
    cmp_mem_imm(a, 0o140004, TOPPAT)
    cmp_mem_imm(a, seg(6), BIOSPAT0)        # 160000: the SMK shadows MSTD
    cmp_mem_imm(a, seg(7) + OFF_S, pat_s(7))            # seg7 = P+7 (page 0)
    # a 177662 write must be replied; value keeps IRQ2 MASKED (no ISR here).
    # The tb checks the vid taps (page=1, mask=1, pal=0o12) at the first park.
    a.emit(0o012737, 0o145000, 0o177662)


# tb-poked markers, shared with the bk11 oracle conventions (keep in sync
# with sim/smk/smk_soc_tb.v: ROMPAT0 at SDRAM 0x30000, the top-ROM stub +
# TOPPAT at 0x38000-0x38002)
ROMPAT0 = 0o123456
TOPPAT = 0o054321


def build_bios():
    """The synthetic BIOS image (word-indexed; byte offset = 2*index)."""
    img = [0] * BIOS_WORDS
    img[0] = BIOSPAT0                       # window head (160000 AND 170000)
    img[0o7130 >> 1] = BIOSPAT130           # the 177130 read under SYS
    img[0o6400 >> 1] = 0o000137             # stage-0 @ 166400: JMP @#001000
    img[(0o6400 >> 1) + 1] = PROG_BASE
    img[0o7714 >> 1] = BIOSPAT14            # 177714 pure-BIOS merge
    img[0o7716 >> 1] = START_W              # THE boot word (PC <- & 177400)
    img[0o7776 >> 1] = BIOSPAT76            # 177776 BIOS-only reply
    assert (START_W & 0o177400) == 0o166400
    return img


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    bk10 = "--bk10" in sys.argv
    outdir = args[0] if args else "."

    s2, labels = build_stage2(bk10)

    def word_at(label):
        return PROG_BASE + 2 * labels[label]

    # the pinned park addresses the tb keys on
    assert word_at("sloop") == 0o001004, oct(word_at("sloop"))
    assert word_at("floop") == 0o001012, oct(word_at("floop"))
    assert PROG_BASE + 2 * len(s2) <= 0o030000, \
        f"stage 2 too large ({len(s2)} words)"

    # The residence image: BK-0011M physical RAM page 6 (the fixed
    # 000000-037777 region, SDRAM 0x2C000) or, for the bk10 leg, the whole
    # BK-0010 RAM (000000-077777, SDRAM 0x0000). Identical layout either way -
    # the SMK never touches addresses below 0100000.
    ram_words = LOW10_WORDS if bk10 else PAGE_WORDS
    ram = [0] * ram_words
    ram[0o004 >> 1] = word_at("fail")       # trap 4 (bus timeout) -> fail park
    ram[0o006 >> 1] = 0o000340
    for i, w in enumerate(s2):
        ram[(PROG_BASE >> 1) + i] = w

    bios = build_bios()
    ram_name = "smk_low10.hex" if bk10 else "smk_page6.hex"

    for name, img in ((ram_name, ram), ("smk_bios.hex", bios)):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/{ram_name} + smk_bios.hex "
          f"(stage 2 {len(s2)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
