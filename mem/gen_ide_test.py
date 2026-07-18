#!/usr/bin/env python3
"""Generate the Phase-8 IDE SoC oracle program (sim/ide/run_soc.sh).

The directed program runs on the REAL SoC stack (vm1 + va_037_sync +
qbus_mem incl. the sel_ide decode/merge + smk_ide + the tb disk model
loaded with mem/gen_ide_image.py's AltPro image) and proves what the unit
oracle can't: the IDE task file served through the real reply machinery,
in the modes the mapper actually layers over it. Data-checking, sim/smk
conventions (parks 001004/001012, vector 4 -> fail, COSIM PASS).

The CPU-side values are all BUS values (the SMK inverts both directions:
the CPU writes ~X to deliver X and reads back ~core). Boot rides the real
SYS mechanism with gen_smk_test's synthetic BIOS + one added marker word
at image offset 0o7752 (see section 1).

Sections:
  1 (SYS)  status probe (attached master: ~{dar,status} = 0o146677); the
           rom7|device OR-merge at 177752: scount is set to 0xF0 and the
           BIOS marker word 0o000120 ORs into the read -> 0o177537 exactly
           (both contributions visible); a task-file WRITE under SYS is
           replied (every register write here would trap to the fail park
           otherwise - before this increment they bus-timed-out)
  2 (SYS)  IDENTIFY: DRQ poll, word 0 = ~0x0040, word 1 = ~C(=10), drain,
           end status ~{dar,0x50}
  3 (RAM11) pure-device probe (the extent is capped -> MK_NONE: the reply
           is sel_ide alone)
  4 (RAM11) READ sector 2 (CHS 0/0/3): 4 pattern words checked exactly,
           drain, end status
  5 (RAM11) WRITE sector 5, completion poll (BSY phase!), read back and
           verify all 256 words (the write/read bus-inversion pair closes
           program-side: values written = values read back)
  6 (RAM11) ABRT: 0xC4 -> status 0x41/error 0x04; the LBA bit on a READ ->
           ABRT (the documented CHS-only deviation); SRST byte writes to
           177743 recover (error re-seeded 0x01)
  7 (HLT10) broadcast: task-file writes at 177742/177752 land in the
           write-only extent (SMK RAM) AND the device; the device readback
           rides the sel_ide-only reply (the extent read is not replied)
  8 (ALL)  the HLT10-written SMK RAM word read back via the seg-3 mem
           alias 137742; the extent|device merged read at 177752 =
           0 | ~{0,scount} = 0o177400
  9 (RAM11) absent slave: DHR DRV=1 -> reads 0xFFFF, command write
           ignored; master re-select restores
"""
import sys

from gen_mem import Asm, BR, BNE, BEQ
from gen_bk11_test import expect_eq, cmp_mem_imm
from gen_smk_test import (PAGE_WORDS, PROG_BASE, RUN_FLAG, smk_mode,
                          build_bios, SYS, RAM11, HLT10, ALL)

# IDE register addresses
R_COMP0 = 0o177740
R_COMP1 = 0o177742
R_CYLHI = 0o177744
R_CYLLO = 0o177746
R_SNUM = 0o177750
R_COUNT = 0o177752
R_ERR = 0o177754
R_DATA = 0o177756
R_CTRLB = 0o177743          # control register byte address

# bus-value constants (CPU view; core value = ~bus)
ST_IDLE = 0o146677          # ~{dar 0x32, status 0x40}
ST_DONE = 0o146657          # ~{0x32, 0x50}
ST_ABRT = 0o146676          # ~{0x32, 0x41}
ERR_ABRT = 0o177773         # ~0x0004
ERR_SEED = 0o177776         # ~0x0001
CMD_IDENT = 0o177423        # ~0xEC in the low byte
CMD_READ = 0o177737         # ~0x20
CMD_WRITE = 0o177717        # ~0x30
CMD_BAD = 0o177473          # ~0xC4
V0 = 0o177777               # core 0 (cyl/head registers, master DHR)


def inv(x):
    return ~x & 0o177777


# the gen_ide_image.py data pattern, bus view
def pat_bus(s, w):
    return inv((s * 293 + w * 7 + 0x1234) & 0xFFFF)


_n = [0]


def _lbl(stem):
    _n[0] += 1
    return f"__{stem}{_n[0]}"


def poll_drq(a):
    """Spin until the bus status byte shows DRQ (bus bit 3 == 0)."""
    l, done = _lbl("pd"), _lbl("pdd")
    a.label(l)
    a.emit(0o013700, R_COMP0)               # MOV @#COMP0,R0
    a.emit(0o032700, 0o000010)              # BIT #10,R0
    a.br(BEQ, done)                         # bus bit3 clear = DRQ set
    a.br(BR, l)
    a.label(done)


def poll_done(a):
    """Spin until not-BSY and not-DRQ (bus bits 7 AND 3 both 1)."""
    l, done = _lbl("pc"), _lbl("pcd")
    a.label(l)
    a.emit(0o013700, R_COMP0)               # MOV @#COMP0,R0
    a.emit(0o042700, 0o177567)              # BIC #~0o210,R0
    a.emit(0o020027, 0o000210)              # CMP R0,#210
    a.br(BEQ, done)
    a.br(BR, l)
    a.label(done)


def drain(a, n):
    """Read-and-discard n data words."""
    l = _lbl("dr")
    a.emit(0o012702, n)                     # MOV #n,R2
    a.label(l)
    a.emit(0o005737, R_DATA)                # TST @#DATA (a DATI read)
    a.emit(0o005302)                        # DEC R2
    a.br(BNE, l)


def build_stage2():
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
    a.emit(0o012706, 0o000700)              # MOV #700,SP
    a.emit(0o005237, RUN_FLAG)              # INC @#RUN_FLAG (single pass)

    # --- 1 (SYS): probe + the rom7|device merge -----------------------------
    cmp_mem_imm(a, R_COMP0, ST_IDLE)
    a.emit(0o012737, 0o177417, R_COUNT)     # scount <- 0xF0 (core)
    cmp_mem_imm(a, R_COUNT, 0o177537)       # 0xFF0F | BIOS 0x0050 = 0xFF5F

    # --- 2 (SYS): IDENTIFY --------------------------------------------------
    a.emit(0o012737, CMD_IDENT, R_COMP0)
    poll_drq(a)
    cmp_mem_imm(a, R_DATA, inv(0x0040))     # word 0: fixed-drive type
    cmp_mem_imm(a, R_DATA, inv(10))         # word 1: cylinders = 10
    drain(a, 254)
    cmp_mem_imm(a, R_COMP0, ST_DONE)

    # --- 3 (RAM11): pure-device probe ---------------------------------------
    smk_mode(a, RAM11)
    cmp_mem_imm(a, R_COMP0, ST_DONE)

    # --- 4 (RAM11): READ sector 2 -------------------------------------------
    a.emit(0o012737, V0, R_CYLLO)
    a.emit(0o012737, V0, R_CYLHI)
    a.emit(0o012737, V0, R_COMP1)           # DHR: master, head 0
    a.emit(0o012737, inv(3), R_SNUM)        # snum 3 -> index 2
    a.emit(0o012737, inv(1), R_COUNT)
    a.emit(0o012737, CMD_READ, R_COMP0)
    poll_drq(a)
    for w in range(4):
        cmp_mem_imm(a, R_DATA, pat_bus(2, w))
    drain(a, 252)
    cmp_mem_imm(a, R_COMP0, ST_DONE)

    # --- 5 (RAM11): WRITE sector 5 + read back ------------------------------
    a.emit(0o012737, inv(6), R_SNUM)        # snum 6 -> index 5
    a.emit(0o012737, inv(1), R_COUNT)
    a.emit(0o012737, CMD_WRITE, R_COMP0)
    poll_drq(a)
    a.emit(0o012701, 0o123400)              # MOV #123400,R1 (fill seed)
    a.emit(0o012702, 256)                   # MOV #256.,R2
    wl = _lbl("wf")
    a.label(wl)
    a.emit(0o010137, R_DATA)                # MOV R1,@#DATA
    a.emit(0o062701, 0o000007)              # ADD #7,R1
    a.emit(0o005302)                        # DEC R2
    a.br(BNE, wl)
    poll_done(a)                            # the BSY commit phase
    cmp_mem_imm(a, R_COMP0, ST_DONE)
    a.emit(0o012737, inv(6), R_SNUM)        # read it back
    a.emit(0o012737, inv(1), R_COUNT)
    a.emit(0o012737, CMD_READ, R_COMP0)
    poll_drq(a)
    a.emit(0o012701, 0o123400)
    a.emit(0o012702, 256)
    rl = _lbl("rv")
    a.label(rl)
    a.emit(0o013700, R_DATA)                # MOV @#DATA,R0
    a.emit(0o020001)                        # CMP R0,R1
    expect_eq(a)
    a.emit(0o062701, 0o000007)
    a.emit(0o005302)
    a.br(BNE, rl)
    cmp_mem_imm(a, R_COMP0, ST_DONE)

    # --- 6 (RAM11): ABRT + LBA + SRST ---------------------------------------
    a.emit(0o012737, CMD_BAD, R_COMP0)
    cmp_mem_imm(a, R_COMP0, ST_ABRT)
    cmp_mem_imm(a, R_ERR, ERR_ABRT)
    a.emit(0o012737, inv(0x40), R_COMP1)    # DHR: LBA bit
    a.emit(0o012737, inv(1), R_COUNT)
    a.emit(0o012737, inv(1), R_SNUM)
    a.emit(0o012737, CMD_READ, R_COMP0)
    cmp_mem_imm(a, R_COMP0, ST_ABRT)        # CHS-only: LBA -> abort
    a.emit(0o012737, V0, R_COMP1)           # DHR back to master/head 0
    a.emit(0o112737, 0o000373, R_CTRLB)     # MOVB: SRST assert (bus bit2=0)
    a.emit(0o112737, 0o000377, R_CTRLB)     # MOVB: SRST release
    cmp_mem_imm(a, R_COMP0, ST_IDLE)
    cmp_mem_imm(a, R_ERR, ERR_SEED)

    # --- 7 (HLT10): the write-only extent broadcast -------------------------
    smk_mode(a, HLT10)
    a.emit(0o012737, 0o000000, R_COUNT)     # bus 0 -> SMK RAM; scount <- 0xFF
    a.emit(0o012737, 0o177772, R_COMP1)     # bus -> SMK RAM; DHR <- 0xA5
    cmp_mem_imm(a, R_COMP1, 0o137532)       # ~{alt 0x40, dhr 0xA5}

    # --- 8 (ALL): the alias readback + the extent|device merge --------------
    smk_mode(a, ALL)
    cmp_mem_imm(a, 0o137742, 0o177772)      # seg-3 alias of the HLT10 write
    cmp_mem_imm(a, R_COUNT, 0o177400)       # 0 | ~{0,scount 0xFF}

    # --- 9 (RAM11): absent slave --------------------------------------------
    smk_mode(a, RAM11)
    a.emit(0o012737, inv(0x10), R_COMP1)    # DHR DRV=1: the absent slave
    cmp_mem_imm(a, R_COMP0, 0o177777)
    a.emit(0o012737, CMD_IDENT, R_COMP0)    # must be ignored
    cmp_mem_imm(a, R_COMP0, 0o177777)
    a.emit(0o012737, V0, R_COMP1)           # master back
    cmp_mem_imm(a, R_COMP0, ST_IDLE)

    a.emit(0o000137)                        # JMP @#success
    a.addr("success")

    return a.resolve(), a.labels


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    s2, labels = build_stage2()

    def word_at(label):
        return PROG_BASE + 2 * labels[label]

    assert word_at("sloop") == 0o001004, oct(word_at("sloop"))
    assert word_at("floop") == 0o001012, oct(word_at("floop"))
    assert PROG_BASE + 2 * len(s2) <= 0o030000, \
        f"stage 2 too large ({len(s2)} words)"

    page6 = [0] * PAGE_WORDS
    page6[0o004 >> 1] = word_at("fail")     # trap 4 (bus timeout) -> fail park
    page6[0o006 >> 1] = 0o000340
    for i, w in enumerate(s2):
        page6[(PROG_BASE >> 1) + i] = w

    bios = build_bios()
    # section-1 merge marker: rom7 covers 177752 under SYS; this word ORs
    # with the device's ~scount read (must have bits only where the device
    # word has zeros: scount 0xF0 -> device 0xFF0F -> marker within 0x00F0)
    assert bios[0o7752 >> 1] == 0
    bios[0o7752 >> 1] = 0o000120            # 0x0050

    for name, img in (("ide_page6.hex", page6), ("ide_bios.hex", bios)):
        with open(f"{outdir}/{name}", "w") as f:
            for w in img:
                f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/ide_page6.hex + ide_bios.hex "
          f"(stage 2 {len(s2)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
