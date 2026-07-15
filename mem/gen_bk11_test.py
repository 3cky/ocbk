#!/usr/bin/env python3
"""Generate the Phase-7 BK-0011M banking functional oracle program.

Imports the tiny PDP-11 assembler from gen_mem.py and builds the two SDRAM
page images sim/bk11/bk11_soc_tb.v preloads (this is a DATA-checking oracle,
not a timing golden - see sim/bk11/):

  bk11_page0.hex : 8192 words = physical RAM page 0 (SDRAM 0x20000-0x21FFF).
                   Stage 1 at BK 100000. Boot (Phase 7): the 177716 read
                   returns SYS_START11 = 140000, so the first post-reset
                   fetch hits the tb's stage-0 stub in the fixed top ROM
                   (JMP @#100000); the reset map shows page 0 in window 1
                   (MK_EXT), so stage 1's fetches exercise the EXT path:
                   set SP, one EXT sanity read, then JMP @#001000 into the
                   fixed page-6 region.
  bk11_page6.hex : 8192 words = physical RAM page 6 (SDRAM 0x2C000-0x2DFFF),
                   the fixed 000000-037777 region: vectors (trap 4 -> the
                   fail park - any bus timeout parks loudly) + stage 2.

Stage 2 walks the whole Bk11MemoryManager contract: page fill/verify through
window 0, EXT verify through window 1, page-6 aliasing both directions, RMW
(DATIO) in EXT - the CLAUDE.md RMW-coverage rule; this is the one bus path
with no bk10 coverage - ROM overlay codes with write-timeout (a write to a
mapped ROM overlay gets no reply -> trap 4, proven via a vector-4 detour;
authentic mask-ROM behaviour, BkEmu-confirmed) and empty-socket read-timeout
(the unpopulated stock-BK-0011M banks 2,3 also time out on READS -> trap 4,
so BOS's reverse probe skips them instead of executing HALT), the 033-quirk
fall-through, the fixed top ROM, nINIT preserve (RESET instruction), the
write-only map register, and (Phase 7) the 177662 video register: word
writes replied + RESET-preserved (the tb checks the vid_* taps), reads
un-replied (write-only; trap-4 detour proves the timeout), plus the
EVNT/IRQ2 frame interrupt (section 12: bit-14 mask gates the asserted
vgate level, one vector-0100 fire per blanking window) and the СТОП-enable
bit (section 13: 177716 bit 12 gates the tb-pulsed СТОП one-shot; the
MiSTer lane rule - word/odd-byte writes reach the latch, even-byte and
banking writes don't - and RESET preserves it). Pattern offsets
are >= 0o20000 within a window so page-6 writes never clobber the
vectors/code/stack at the bottom of page 6.

Park loops (pinned, the tb keys off them):
  success self-loop PC = 001004
  failure self-loop PC = 001012
The unrolled program is far longer than a branch reach, so every check uses
BEQ-over-JMP: BEQ .+6 / JMP @#fail.

ROMPAT0/TOPPAT below must match the tb's SDRAM pokes at word
0x30000 / 0x38002 (TOPPAT sits after the stage-0 boot stub at
0x38000/0x38001 - keep the two in sync). Banks 2,3 (0x34000/0x36000) are
empty sockets - no marker, they time out on read.
"""
import sys

from gen_mem import Asm, BR, BNE, BEQ

PAGE_WORDS = 8192            # one 0011M RAM page = 040000 bytes
PROG_BASE = 0o001000
STAGE1_BASE = 0o100000

BIT11 = 0o004000             # the 177716 banking-ENABLE bit

W0 = 0o040000                # window 0 base (always RAM)
W1 = 0o100000                # window 1 base (RAM page or ROM overlay)
OFF_A = 0o20000              # pattern offsets within a window (>= 0o20000:
OFF_B = 0o30000              #   page-6 writes stay above vectors/code/stack)
OFF_C = 0o24000              # page-6 aliasing scratch

# tb-poked ROM overlay / top-ROM markers (sim/bk11/bk11_soc_tb.v pokes these
# at SDRAM words 0x30000 / 0x38000 - keep in sync). Only the POPULATED window-1
# bank 0 has a marker; banks 2,3 are empty sockets (no reply -> trap 4).
ROMPAT0 = 0o123456
TOPPAT = 0o054321

ALIAS1 = 0o167321
ALIAS2 = 0o043210

# section-12 fixed delays (masked window / double-fire grace): ~64 SOB
# iterations, comfortably longer than the write->capture->2-FF-resync
# propagation of the IRQ2 level, far shorter than a blanking window
DELAY12 = 0o100

# section-13 СТОП trigger: the tb watches for this exact word written to this
# fixed page-6 scratch address and pulses key_stop (keep in sync with
# sim/bk11/bk11_soc_tb.v). The no-fire delay must exceed the whole enabled
# path (64-clk one-shot + two ~60-clk HALT-entry store timeouts + the trap):
# ~128 SOB iterations >> ~250 cpu_clk.
STOP_MAGIC_ADDR = 0o000750
STOP_MAGIC_VAL = 0o123321
DELAY13 = 0o200


def pat_a(p):
    return 0o052500 + p


def pat_b(p):
    return 0o125200 + p


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


def bank_write(a, val):
    a.emit(0o012737, val, 0o177716)         # MOV #val,@#177716 (word = banking)


_trap = [0]


def expect_trap4(a, emit_access):
    """Assert the access emitted by emit_access() gets NO bus reply -> trap 4.

    Installs a vector-4 detour, runs the access (which must abort into the
    handler), fails if control instead falls through (the access REPLIED), and
    in the handler drops the un-RTI-able bus-error frame (mid-instruction PC -
    the СТОП finding: never RTI) and restores vector 4 to the fail park before
    continuing. Mirrors the section-11 177662-read detour."""
    n = _trap[0]
    _trap[0] += 1
    a.emit(0o012737)                        # MOV #__trapN,@#4 (detour vector 4)
    a.addr(f"__trap{n}")
    a.emit(0o000004)
    emit_access()                           # the access that MUST time out
    a.emit(0o000137)                        # replied?! (no trap) -> JMP @#fail
    a.addr("fail")
    a.label(f"__trap{n}")                   # trap-4 entry (access not replied)
    a.emit(0o062706, 0o000004)              # ADD #4,SP (drop the pushed PC/PSW)
    a.emit(0o012737)                        # MOV #fail,@#4 (restore the vector)
    a.addr("fail")
    a.emit(0o000004)


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

    # --- 1. fill: distinct patterns into every page through window 0 --------
    for p in range(8):
        bank_write(a, BIT11 | (p << 12))
        a.emit(0o012737, pat_a(p), W0 + OFF_A)
        a.emit(0o012737, pat_b(p), W0 + OFF_B)

    # --- 2. verify through window 0 ------------------------------------------
    for p in range(8):
        bank_write(a, BIT11 | (p << 12))
        cmp_mem_imm(a, W0 + OFF_A, pat_a(p))
        cmp_mem_imm(a, W0 + OFF_B, pat_b(p))

    # --- 3. verify through window 1 (MK_EXT reads) ---------------------------
    for p in range(1, 8):
        bank_write(a, BIT11 | (p << 8))
        cmp_mem_imm(a, W1 + OFF_A, pat_a(p))
        cmp_mem_imm(a, W1 + OFF_B, pat_b(p))

    # --- 4. page-6 aliasing, both directions ---------------------------------
    bank_write(a, BIT11 | (6 << 12))
    a.emit(0o012737, ALIAS1, W0 + OFF_C)    # write via window 0...
    cmp_mem_imm(a, OFF_C, ALIAS1)           # ...read via the fixed region
    a.emit(0o012737, ALIAS2, OFF_C)         # write via the fixed region...
    cmp_mem_imm(a, W0 + OFF_C, ALIAS2)      # ...read via window 0

    # --- 5. RMW (DATIO) in EXT: the one bus path with no bk10 coverage -------
    bank_write(a, BIT11 | (2 << 8))
    a.emit(0o005037, W1 + OFF_A)            # CLR  -> 0
    a.emit(0o005237, W1 + OFF_A)            # INC  -> 1
    a.emit(0o006337, W1 + OFF_A)            # ASL  -> 2
    a.emit(0o052737, 0o000025, W1 + OFF_A)  # BIS #25 -> 27
    cmp_mem_imm(a, W1 + OFF_A, 0o000027)

    # --- 6. ROM overlays: a POPULATED bank (0 = BASIC) reads the tb-poked
    #        marker; WRITES to it get NO reply -> trap 4 (authentic mask/overlay
    #        ROM - real ROMs never RPLY on a write; BkEmu agrees: ReadOnlyMemory
    #        .write -> not-written -> BUS_ERROR -> vector 4). The write never
    #        reaches the RAM page under the overlay, so the underlying page-1
    #        pattern stays intact. Both a word-0 and a mid-page (OFF_A) overlay
    #        write are exercised. An UNPOPULATED bank (2,3) times out on READS
    #        too (empty socket) - checked at the end of this section. -----------
    bank_write(a, BIT11 | 0o001 | (1 << 8))  # bank 0 mapped, page field = 1
    cmp_mem_imm(a, W1, ROMPAT0)             # ROM DATI replies (read OK)
    expect_trap4(a, lambda: a.emit(0o012737, 0o123123, W1))          # write @#100000
    expect_trap4(a, lambda: a.emit(0o012737, 0o121212, W1 + OFF_A))  # write @#120000
    bank_write(a, BIT11 | (1 << 8))         # window 1 -> RAM page 1
    cmp_mem_imm(a, W1 + OFF_A, pat_a(1))    # page-1 pattern intact (write trapped)
    cmp_mem_imm(a, W1, 0)                   # page-1 word 0 untouched
    bank_write(a, BIT11 | 0o001)
    cmp_mem_imm(a, W1, ROMPAT0)             # ROMPAT0 intact
    # empty (unpopulated) sockets - stock BK-0011M banks 2,3 = codes 010/020:
    # a READ gets NO reply -> trap 4 (no chip drives the bus), so BOS's reverse
    # 4->1 ROM probe skips them instead of reading 000000 = HALT and looping.
    bank_write(a, BIT11 | 0o010)            # code 010 -> bank 2 (EMPTY socket)
    expect_trap4(a, lambda: a.emit(0o005737, W1))          # TST @#100000 read -> trap
    bank_write(a, BIT11 | 0o020)            # code 020 -> bank 3 (EMPTY socket)
    expect_trap4(a, lambda: a.emit(0o005737, W1 + OFF_A))  # TST @#120000 read -> trap

    # --- 7. the 033-quirk: 003 falls through to RAM; 005 masks to bank 0 -----
    bank_write(a, BIT11 | (5 << 8) | 0o003)
    cmp_mem_imm(a, W1 + OFF_A, pat_a(5))
    bank_write(a, BIT11 | 0o005)
    cmp_mem_imm(a, W1, ROMPAT0)

    # --- 8. fixed top ROM: the stage-0 boot stub (already executed through
    #        the start vector) + the marker word after it ----------------------
    cmp_mem_imm(a, 0o140000, 0o000137)      # stub JMP opcode, via MK_ROM DATI
    cmp_mem_imm(a, 0o140004, TOPPAT)

    # --- 9. nINIT preserve: the RESET instruction must NOT re-init the map ----
    bank_write(a, BIT11 | (3 << 12))
    a.emit(0o000005)                        # RESET (pulses nINIT)
    cmp_mem_imm(a, W0 + OFF_A, pat_a(3))    # window 0 still shows page 3

    # --- 10. write-only register: reads return the system bits, never the map -
    a.emit(0o013700, 0o177716)              # MOV @#177716,R0
    a.emit(0o042700, 0o000144)              # BIC #144,R0 (wflag/tape/kbd volatile)
    a.emit(0o022700, 0o140000)              # CMP #140000,R0 (SYS_START11 - the
                                            #   in-program bk11 start-vector pin)
    expect_eq(a)

    # --- 11. 177662 video register (Phase 7; MiSTer video.sv contract) --------
    # Word writes must be REPLIED (no trap 4 = simply not parking at fail);
    # nINIT must preserve the captured bits (DCLO-only reset, like the map);
    # reads must NOT be replied by qbus_mem (write-only register - here, with
    # no 014 keyboard chip in the tb stack, the read bus-times-out -> trap 4,
    # proven via a temporary vector-4 detour). Final register state (page=1,
    # irq2_mask=0, pal=0o12) differs from the DCLO defaults (0/1/0o17) in
    # EVERY field - the tb checks the vid_* taps after the success park.
    a.emit(0o012737, 0o102400, 0o177662)    # page=1, irq2 unmasked, pal=5
    a.emit(0o012737, 0o105000, 0o177662)    # page=1, irq2 unmasked, pal=0o12
    a.emit(0o000005)                        # RESET: must preserve the register
    a.emit(0o012737)                        # MOV #vread_ok,@#4 (detour vector 4)
    a.addr("vread_ok")
    a.emit(0o000004)
    a.emit(0o013700, 0o177662)              # MOV @#177662,R0 -> MUST time out
    a.emit(0o000137)                        # replied?! -> fail
    a.addr("fail")
    a.label("vread_ok")                     # trap-4 entry (read not replied)
    a.emit(0o062706, 0o000004)              # ADD #4,SP (drop the pushed PC/PSW)
    a.emit(0o012737)                        # MOV #fail,@#4 (restore the vector)
    a.addr("fail")
    a.emit(0o000004)

    # --- 12. EVNT/IRQ2 (Phase 7): the 50 Hz frame interrupt -------------------
    # Entry state: 662 = 0o105000 (page=1, IRQ2 UNMASKED, pal=0o12) from
    # section 11, PSW = 340 (the trap-4 detour's vector PSW kept priority 7,
    # so the already-asserted level never fired). The tb wires nIRQ2 through
    # the ocbk_top replica (~mask & vgate, 2-FF onto cpu_clk).
    # RASTER-PHASE ASSUMPTION: the 037 free-runs from reset with VGATE high
    # for the first 64 lines (~4.1 ms) and stage 2 reaches this point well
    # inside that window, so the level INPUT is already high here: the
    # masked-negative check is a real gating test and the post-unmask fire is
    # immediate. If stage 2 ever outgrows the first blanking window, the spin
    # below just rides to the next frame (slower sim, still correct - the
    # tb's vgate-at-assert guard keeps the window phase pinned).
    a.emit(0o012737)                        # MOV #isr2,@#0100 (frame vector)
    a.addr("isr2")
    a.emit(0o000100)
    a.emit(0o012737, 0o000340, 0o000102)    # MOV #340,@#0102 (ISR at prio 7)
    a.emit(0o005002)                        # CLR R2 (ISR progress record)
    a.emit(0o012737, 0o145000, 0o177662)    # re-mask: page=1, m=1, pal=0o12
    # drop PSW 340 -> 0 via RTI (VM1 has no MTPS; the gen_kbd_test idiom)
    a.emit(0o005046)                        # CLR -(SP) (new PSW = 0)
    a.emit(0o012746)                        # MOV #prio0,-(SP) (new PC)
    a.addr("prio0")
    a.emit(0o000002)                        # RTI
    a.label("prio0")
    # masked window: the vgate level is high, bit 14 alone must gate it
    a.emit(0o012703, DELAY12)               # MOV #DELAY12,R3
    a.label("d12a")
    a.sob(3, "d12a")                        # fixed-count delay
    a.emit(0o020227, 0o000000)              # CMP R2,#0 (no IRQ2 while masked)
    expect_eq(a)
    a.emit(0o012737, 0o105000, 0o177662)    # unmask (= the final 662 state the
                                            #   tb checks after the park)
    # spin until the ISR ran - race-immune (the fire may land between any
    # two instructions); never fires -> the tb watchdog parks the run
    a.label("w12")
    a.emit(0o020227, 0o000000)              # CMP R2,#0
    a.br(BEQ, "w12")
    a.emit(0o020227, 0o000001)              # CMP R2,#1 (exactly one fire)
    expect_eq(a)
    a.emit(0o012703, DELAY12)               # grace: a double fire would bump R2
    a.label("d12b")
    a.sob(3, "d12b")
    a.emit(0o020227, 0o000001)              # CMP R2,#1 (still exactly one)
    expect_eq(a)
    # restore PSW 340: the success park must not take next-frame IRQ2s
    a.emit(0o012746, 0o000340)              # MOV #340,-(SP)
    a.emit(0o012746)                        # MOV #prio7,-(SP)
    a.addr("prio7")
    a.emit(0o000002)                        # RTI
    a.label("prio7")

    # --- 13. СТОП-enable (177716 bit 12; Phase 7) ------------------------------
    # The tb pulses key_stop (one cpu_clk) on every STOP_MAGIC_VAL write to
    # STOP_MAGIC_ADDR and runs the ocbk_top replica: stop_block 2-FF resync
    # gating the 64-clk nIRQ1 one-shot. An enabled СТОП takes the authentic
    # BK path (ref014-pinned shape): HALT entry, its 177676 PSW store bus-
    # times-out, trap through vector 4 -> stop_isr bumps R5. Entry PSW is
    # 340: СТОП must fire even at priority 7 (rq[14] is the raw pin level -
    # the very reason the 0011M grew the bit-12 blocker); the detoured
    # vector-4 PSW carries the HALT-mode bit 0o400 (the gen_kbd_test idiom).
    # RESUME CONTRACT: the aborted HALT entry pushes a MID-INSTRUCTION PC
    # (the vm1 grabs IRQ1 after the opcode fetch), so the trap frame is NOT
    # RTI-able - authentic: real СТОП handlers never return either (the
    # gen_kbd_test one parks). The handler therefore drops the frame and
    # continues at the per-case continuation in R0; fire-must-not-happen
    # cases point R0 at the fail park, so a stray fire parks loudly.
    a.emit(0o012737)                        # MOV #stop_isr,@#4 (detour vector 4)
    a.addr("stop_isr")
    a.emit(0o000004)
    a.emit(0o012737, 0o000740, 0o000006)    # trap-4 PSW: prio 7 + HALT bit
    a.emit(0o005005)                        # CLR R5 (СТОП fire counter)
    # (a) DCLO default = enabled (and prio 7 does not mask СТОП)
    a.emit(0o012700)                        # MOV #c13a,R0 (continuation)
    a.addr("c13a")
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)
    a.label("p13a")                         # park; never fires -> the tb
    a.br(BR, "p13a")                        #   watchdog parks the run
    a.label("c13a")
    a.emit(0o020527, 0o000001)              # CMP R5,#1 (exactly one fire)
    expect_eq(a)
    # (b) word write with bit 12 (bit 11 clear - NOT banking) blocks
    a.emit(0o012700)                        # MOV #fail,R0 (stray fire -> park)
    a.addr("fail")
    a.emit(0o012737, 0o010000, 0o177716)
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)
    a.emit(0o012703, DELAY13)               # bounded no-fire window
    a.label("d13b")
    a.sob(3, "d13b")
    a.emit(0o020527, 0o000001)              # CMP R5,#1 (no new fire)
    expect_eq(a)
    # (c) the RESET instruction must NOT re-enable (DCLO-only, like the map)
    a.emit(0o000005)                        # RESET (pulses nINIT)
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)
    a.emit(0o012703, DELAY13)
    a.label("d13c")
    a.sob(3, "d13c")
    a.emit(0o020527, 0o000001)
    expect_eq(a)
    # (d) an even-address BYTE write can't touch the latch (the MiSTer lane
    #     rule; BkEmu's implicit re-enable here is a rejected artifact)
    a.emit(0o105037, 0o177716)              # CLRB @#177716
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)
    a.emit(0o012703, DELAY13)
    a.label("d13d")
    a.sob(3, "d13d")
    a.emit(0o020527, 0o000001)
    expect_eq(a)
    # (e) the 177717 odd byte DOES reach it (data on AD15:8): re-enable
    a.emit(0o105037, 0o177717)              # CLRB @#177717
    a.emit(0o012700)                        # MOV #c13e,R0
    a.addr("c13e")
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)
    a.label("p13e")
    a.br(BR, "p13e")
    a.label("c13e")
    a.emit(0o020527, 0o000002)
    expect_eq(a)
    # (f) a BANKING write with the bit-12 lane set must not block (mutual
    #     exclusion; window 0 -> page 1 as a side effect, nothing uses it)
    a.emit(0o012737, BIT11 | (1 << 12), 0o177716)
    a.emit(0o012700)                        # MOV #c13f,R0
    a.addr("c13f")
    a.emit(0o012737, STOP_MAGIC_VAL, STOP_MAGIC_ADDR)
    a.label("p13f")
    a.br(BR, "p13f")
    a.label("c13f")
    a.emit(0o020527, 0o000003)
    expect_eq(a)
    # restore vector 4 -> fail (a stray timeout at the park must park loudly)
    a.emit(0o012737)                        # MOV #fail,@#4
    a.addr("fail")
    a.emit(0o000004)
    a.emit(0o012737, 0o000340, 0o000006)

    # --- 14. success ------------------------------------------------------------
    a.emit(0o000137)                        # JMP @#success
    a.addr("success")

    # frame-IRQ2 ISR (vector 0100; runs at priority 7, never falls through)
    a.label("isr2")
    a.emit(0o005202)                        # INC R2
    a.emit(0o000002)                        # RTI

    # СТОП trap-4 ISR (via the section-13 vector detour): count the fire,
    # drop the un-RTI-able frame (mid-instruction PC, see section 13) and
    # continue at the case's continuation (R0) at priority 7
    a.label("stop_isr")
    a.emit(0o005205)                        # INC R5
    a.emit(0o062706, 0o000004)              # ADD #4,SP (drop pushed PC/PSW)
    a.emit(0o012746, 0o000340)              # MOV #340,-(SP) (new PSW)
    a.emit(0o010046)                        # MOV R0,-(SP)   (new PC)
    a.emit(0o000002)                        # RTI

    words = a.resolve()
    return words, a.labels


def build_stage1():
    a = Asm(base=STAGE1_BASE)
    a.emit(0o012706, 0o000700)              # MOV #700,SP (stack in fixed page 6)
    a.emit(0o013700, STAGE1_BASE)           # MOV @#100000,R0 (EXT sanity read:
    a.emit(0o022700, 0o012706)              #   our own first opcode)
    a.br(BEQ, "go")
    a.emit(0o000137, 0o001006)              # JMP @#fail (park in page 6)
    a.label("go")
    a.emit(0o000137, PROG_BASE)             # JMP @#001000 (stage 2, page 6)
    return a.resolve()


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    s2, labels = build_stage2()

    def word_at(label):
        return PROG_BASE + 2 * labels[label]

    # the pinned park addresses the tb keys on
    assert word_at("sloop") == 0o001004, oct(word_at("sloop"))
    assert word_at("floop") == 0o001012, oct(word_at("floop"))
    # stage 2 must stay below the in-page pattern/scratch offsets
    assert PROG_BASE + 2 * len(s2) <= OFF_A, \
        f"stage 2 spills into the pattern area ({len(s2)} words)"

    page6 = [0] * PAGE_WORDS
    page6[0o004 >> 1] = word_at("fail")     # trap 4 (bus timeout) -> fail park
    page6[0o006 >> 1] = 0o000340
    for i, w in enumerate(s2):
        page6[(PROG_BASE >> 1) + i] = w

    s1 = build_stage1()
    page0 = [0] * PAGE_WORDS
    for i, w in enumerate(s1):
        page0[i] = w

    for name, img in (("bk11_page0.hex", page0), ("bk11_page6.hex", page6)):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/bk11_page0.hex + bk11_page6.hex "
          f"(stage 2 {len(s2)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
