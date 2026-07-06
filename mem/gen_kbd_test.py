#!/usr/bin/env python3
"""Generate the Phase-6 keyboard interrupt-latency oracle program.

Imports the tiny PDP-11 assembler from gen_mem.py and builds a RAM-resident
program (base 001000, inside the sim/ref014 FETCH window 001000-002000) plus
the ROM-region words (bootstrap JMP + the 1801VM1 IRQ1/HALT trap vector at
160002). Run by sim/ref014/run.sh; outputs land next to the testbenches:

  kbd_ram.hex : 16384 words = BK RAM 000000-077777 (vectors 060/0274, the
                program at 001000, the tb ARM mailbox at 000776);
  kbd_rom.hex : 16320 words = ROM region 100000-177577 (JMP @#001000 at
                100000, {PC,PSW} = {stopped, 340} at 160002/160004 - the
                vm1 vmux HALT vector, BkEmu TRAP_VECTOR_HALT).

Program phases (the testbench watches writes to the ARM mailbox 000776 and
injects the key events; see ref014_irq_ref_tb.v):
  1  unmasked plain key   -> VIRQ -> vector 060, ISR verifies the code;
  2  unmasked AR2 key     -> VIRQ -> vector 0274, ISR verifies the code;
  3  masked press         -> no VIRQ; a fixed-count delay loop (injection
     jitter never changes the fetch trace), then ready/code verified and
     read-cleared, unmask verified NOT to retro-fire (the 662 read already
     cleared the trigger - the netlist contract);
  4  tb-driven nIRQ1 fixed pulse (STOP_PULSE wide) during WAIT -> the HALT
     entry starts, its 177676 (HALT PSW store) write gets NO reply - nothing
     decodes 177674/177676 on a real BK - the vm1 bus-timeouts (qbto,
     56..63 clocks) and takes TRAP 4 -> parks at 'stopped' through the RAM
     vector 000004. This trap-4 path is the authentic СТОП behaviour of a
     BK-0010 with the BASIC ROM; the 160002 HALT "vector" is never read
     (here it points at the FAIL park so a wrongly-completed HALT entry
     breaks the golden loudly).

Park loops (fixed at the head, the run.sh reduce keys off them):
  success/stop self-loop PC = 001004
  failure      self-loop PC = 001012
Any verification mismatch parks at the failure loop = a different fetch
trace = the golden diff breaks.
"""
import sys

from gen_mem import Asm, BR, BNE, BEQ

RAM_WORDS = 16384            # 000000-077777
ROM_WORDS = 16320            # 100000-177577
PROG_BASE = 0o001000
ROM_BASE = 0o100000

BPL, BMI = 0o100000, 0o100400

# key codes the testbench key map must generate (see the tb key tables)
CODE1 = 0o141                # phase 1: plain key
CODE2 = 0o146                # phase 2: pressed with AR2 held
CODE3 = 0o143                # phase 3: masked press

# phase-3 fixed delay iterations: must exceed the slowest injection+debounce
# (the vp_014 RC model needs ~0.5 ms; one SOB iteration is ~2 us) with margin
DELAY3 = 0o1750              # 1000. iterations, ~2 ms
DELAY3B = 0o100              # unmask grace window (a VIRQ here would bump R2)


def build():
    a = Asm(base=PROG_BASE)

    # --- fixed park block (addresses hardcoded in run.sh / testbenches) ----
    a.br(BR, "start")                       # 001000
    a.label("stopped")
    a.emit(0o005004)                        # 001002  CLR R4 (stop marker)
    a.label("sloop")
    a.emit(0o000777)                        # 001004  BR .   <- success/stop
    a.label("fail")
    a.emit(0o012704, 0o000001)              # 001006  MOV #1,R4
    a.label("floop")
    a.emit(0o000777)                        # 001012  BR .   <- failure

    a.label("start")
    a.emit(0o012706, 0o000700)              # MOV #700,SP
    a.emit(0o005002)                        # CLR R2 (ISR progress record)
    # the 1801VM1 resets with PSW=340 (priority 7): drop to 0 via RTI (the
    # VM1 has no MTPS and the PSW is not bus-accessible)
    a.emit(0o005046)                        # CLR -(SP) (new PSW = 0)
    a.emit(0o012746)                        # MOV #prio_ok,-(SP) (new PC)
    a.addr("prio_ok")
    a.emit(0o000002)                        # RTI
    a.label("prio_ok")
    a.emit(0o005037, 0o177660)              # CLR @#177660 (unmask VIRQ)

    # --- phase 1: plain key -> vector 060 ----------------------------------
    a.emit(0o012737, 0o000001, 0o000776)    # MOV #1,@#776 (ARM1)
    a.emit(0o000001)                        # WAIT
    a.emit(0o020227, 0o000001)              # CMP R2,#1 (ISR60 ran once)
    a.br(BNE, "fail")

    # --- phase 2: AR2 key -> vector 0274 -----------------------------------
    a.emit(0o012737, 0o000002, 0o000776)    # MOV #2,@#776 (ARM2)
    a.emit(0o000001)                        # WAIT
    a.emit(0o020227, 0o000201)              # CMP R2,#201 (ISR274 added 200)
    a.br(BNE, "fail")

    # --- phase 3: masked press, fixed-length delay, poll after -------------
    a.emit(0o012737, 0o000100, 0o177660)    # MOV #100,@#177660 (mask)
    a.emit(0o012737, 0o000003, 0o000776)    # MOV #3,@#776 (ARM3)
    a.emit(0o012703, DELAY3)                # MOV #DELAY3,R3
    a.label("d3")
    a.sob(3, "d3")                          # fixed-count delay (jitter-proof)
    a.emit(0o105737, 0o177660)              # TSTB @#177660
    a.br(BPL, "fail")                       # ready (bit 7) must be set
    a.emit(0o020227, 0o000201)              # CMP R2,#201 (no ISR ran)
    a.br(BNE, "fail")
    a.emit(0o013704, 0o177662)              # MOV @#177662,R4 (read clears)
    a.emit(0o122704, CODE3)                 # CMPB R4,#CODE3
    a.br(BNE, "fail")
    a.emit(0o105737, 0o177660)              # TSTB @#177660
    a.br(BMI, "fail")                       # ready now clear
    a.emit(0o005037, 0o177660)              # CLR @#177660 (unmask)
    a.emit(0o012703, DELAY3B)               # MOV #DELAY3B,R3
    a.label("d3b")
    a.sob(3, "d3b")                         # grace: a retro-fire would trap
    a.emit(0o020227, 0o000201)              # CMP R2,#201 (still no ISR)
    a.br(BNE, "fail")

    # --- phase 4: nIRQ1 fixed pulse (STOP) -> HALT mode via 160002 ---------
    a.emit(0o012737, 0o000004, 0o000776)    # MOV #4,@#776 (ARM4)
    a.emit(0o000001)                        # WAIT (tb pulses nIRQ1)
    a.br(BR, "fail")                        # must never fall through

    # --- ISRs (in-window: their fetches are part of the golden) ------------
    a.label("isr60")
    a.emit(0o013704, 0o177662)              # MOV @#177662,R4 (read clears)
    a.emit(0o122704, CODE1)                 # CMPB R4,#CODE1
    a.br(BNE, "fail")
    a.emit(0o005202)                        # INC R2
    a.emit(0o000002)                        # RTI

    a.label("isr274")
    a.emit(0o013704, 0o177662)              # MOV @#177662,R4
    a.emit(0o122704, CODE2)                 # CMPB R4,#CODE2 (bit 7 NOT set!)
    a.br(BNE, "fail")
    a.emit(0o062702, 0o000200)              # ADD #200,R2
    a.emit(0o000002)                        # RTI

    words = a.resolve()
    return words, a.labels


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    words, labels = build()
    assert PROG_BASE + 2 * len(words) <= 0o002000, \
        f"program spills out of the FETCH window ({len(words)} words)"

    def word_at(label):
        return PROG_BASE + 2 * labels[label]

    # sanity: the fixed park addresses run.sh keys on
    assert word_at("sloop") == 0o001004, oct(word_at("sloop"))
    assert word_at("floop") == 0o001012, oct(word_at("floop"))

    ram = [0] * RAM_WORDS
    ram[0o004 >> 1] = word_at("stopped")    # trap 4: the authentic СТОП path
    # trap-4 PSW: 0o400 = the vm1 PSW HALT-mode bit; masks the still-asserted
    # nIRQ1 level so the handler cannot be re-entered while СТОП is held
    ram[0o006 >> 1] = 0o000740
    ram[0o060 >> 1] = word_at("isr60")
    ram[0o062 >> 1] = 0o000340
    ram[0o274 >> 1] = word_at("isr274")
    ram[0o276 >> 1] = 0o000340
    for i, w in enumerate(words):
        ram[(PROG_BASE >> 1) + i] = w

    rom = [0] * ROM_WORDS
    rom[0] = 0o000137                       # JMP @#001000
    rom[1] = PROG_BASE
    # The HALT vector must never be consumed: the HALT entry aborts on the
    # un-replied 177676 write (trap 4 above). Point it at the FAIL park so a
    # wrongly-completed HALT entry breaks the golden loudly.
    rom[(0o160002 - ROM_BASE) >> 1] = word_at("fail")
    rom[(0o160004 - ROM_BASE) >> 1] = 0o000740

    with open(f"{outdir}/kbd_ram.hex", "w") as f:
        for w in ram:
            f.write(f"{w:04x}\n")
    with open(f"{outdir}/kbd_rom.hex", "w") as f:
        for w in rom:
            f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/kbd_ram.hex + kbd_rom.hex "
          f"(program {len(words)} words at {oct(PROG_BASE)})")


if __name__ == "__main__":
    main()
