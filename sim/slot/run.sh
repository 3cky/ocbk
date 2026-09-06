#!/usr/bin/env bash
#
# МПИ slot functional oracle (slave-only bridge; data-checking, NOT a timing
# golden): the gen_slot_test.py program proves that a real expansion module on
# the far side of src/bus/qbus_slot.sv can be read, written and read-modify-
# written by the CPU, that it can take the host ROM away over the deselect
# lines, and that an address nobody claims still bus-times-out to trap 4.
# Runs on the real BK-0010 SoC stack (vm1 + va_037_sync + qbus_mem with
# mem_mapper pass-through + SDRAM model + port-2 contention) with the REAL
# qbus_slot bridging to sim/slot/mpi_slave_model.v.
#
# Four legs:
#   attached  - the module answers; every sub-test runs.
#   vecboot   - the module ALSO answers the 0177716 start-vector read, driving
#               only and never replying (the vm1 self-replies for its own
#               177700-177717 block). Its 0166400 - the real SMK512 BIOS[07716]
#               - must wire-OR with SYS_START and start the machine at 0166400;
#               0100000, where an unmerged machine lands, is poked with a jump
#               to the fail park. The program then re-reads 0177716 while the
#               module is still driving it and must get the plain 0100100: the
#               window is armed for the start vector alone. THE 2026-09
#               HARDWARE FAILURE - a real SMK512 booted to MONITOR (bk10) or
#               hung (bk11) because the inward path was gated on the module's
#               reply, which this one cycle never sends.
#   mute      - the module never replies (an empty connector): every slot
#               access must qbto to trap 4 and the machine must keep running.
#               The bridge must not invent a reply out of a floating pin.
#   DIP 8     - the internal SMK512 emulation is selected, so the bridge must
#               stand down COMPLETELY. Checked structurally in the tb, not just
#               behaviourally: rom_dsl_vec must stay 0 and slot_rd must never
#               set, so the two SMKs can never both claim an address.
#
# The RMW (DATIO) leg is the CLAUDE.md rule: a slave that re-arms on SYNC-rise
# instead of strobes-idle drops the write half of an INC and the leg sees a
# stale value.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../../mem && python3 gen_slot_test.py ../sim/slot ) > /dev/null

SRC=../../src
CPU=$SRC/cpu
iverilog -g2012 -o "$SP/slot.vvp" -s slot_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv $SRC/sdram/cpu_sdram_dp.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv \
   $SRC/bus/qbus_mem.sv $SRC/bus/qbus_slot.sv ../sdram_model.sv \
   mpi_slave_model.v slot_soc_tb.v 2>&1 | grep -v 'sorry:' || true

run_leg () {   # $1 = label, $2 = vvp plusargs
    vvp -n "$SP/slot.vvp" $2 2>/dev/null | tee "$SP/out.txt" \
        | grep -E "SLOT-ERROR|SLOT-X-ERROR|COSIM" || true
    grep -q '^COSIM PASS$' "$SP/out.txt" \
        || { echo "МПИ slot oracle ($1): FAIL" >&2; exit 1; }
    echo "МПИ slot oracle ($1): PASS"
}

run_leg "module attached" ""
run_leg "start vector"     "+vecboot"
run_leg "empty connector"  "+noreply"
run_leg "DIP 8 stand-down" "+dip8"

# The host-ROM deselect vector, as a UNIT bench: it is the one part of the
# bridge whose contract is per-MODEL, and the SoC legs are all BK-0010. See
# dsl_tb.v - in particular the BK-0011M concede of segments 6,7, which no
# BK-0010 program can reach.
iverilog -g2012 -o "$SP/dsl.vvp" -s dsl_tb \
   $SRC/qbus_pkg.sv $SRC/bus/bk_rply.sv $SRC/bus/qbus_slot.sv \
   dsl_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/dsl.vvp" | tee "$SP/dsl.txt" | grep -E "DSL-ERROR|COSIM" || true
grep -q '^COSIM PASS$' "$SP/dsl.txt" \
    || { echo "МПИ slot oracle (ROM deselect): FAIL" >&2; exit 1; }
echo "МПИ slot oracle (ROM deselect): PASS"

# ---------------------------------------------------------------------------
# ./run.sh --mutate : the sim/evnt idiom. Each mutation is an anchored sed
# against a COPY of the real RTL; a sed that fails to apply is a HARD ERROR
# (the anchor moved and the mutation is silently not testing anything), and a
# mutation that still passes the oracle means the oracle does not pin it.
# ---------------------------------------------------------------------------
[ "${1:-}" = "--mutate" ] || exit 0

MUT_SRC=$SRC/bus/qbus_slot.sv
MUT_MEM=$SRC/bus/qbus_mem.sv
MUT_MOD=mpi_slave_model.v

patch () {   # $1 = file, $2 = sed, $3 = output
    sed "$2" "$1" > "$3"
    if cmp -s "$1" "$3"; then
        echo "MUTATION ANCHOR STALE: sed did not apply to $1" >&2
        echo "  $2" >&2
        exit 1
    fi
}

mutate_leg () {  # $1 = id, $2 = plusargs, $3 = what it breaks, $4.. = files
    local id="$1" args="$2" what="$3"; shift 3
    iverilog -g2012 -o "$SP/m.vvp" -s slot_soc_tb \
       "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
       "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
       $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv \
       $SRC/sdram/cpu_sdram_dp.sv $SRC/sdram/sdram_arbiter.sv \
       $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv \
       "$@" ../sdram_model.sv slot_soc_tb.v 2>&1 | grep -v 'sorry:' || true
    if vvp -n "$SP/m.vvp" $args 2>/dev/null | grep -q '^COSIM PASS$'; then
        echo "MUTATION $id NOT CAUGHT ($what)" >&2
        exit 1
    fi
    echo "  $id caught: $what"
}

mutate () {  # $1 = id, $2 = what it breaks, $3.. = files (already patched into $SP)
    local id="$1" what="$2"; shift 2
    iverilog -g2012 -o "$SP/m.vvp" -s slot_soc_tb \
       "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
       "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
       $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv \
       $SRC/sdram/cpu_sdram_dp.sv $SRC/sdram/sdram_arbiter.sv \
       $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv \
       "$@" ../sdram_model.sv slot_soc_tb.v 2>&1 | grep -v 'sorry:' || true
    if vvp -n "$SP/m.vvp" 2>/dev/null | grep -q '^COSIM PASS$'; then
        echo "MUTATION $id NOT CAUGHT ($what)" >&2
        exit 1
    fi
    echo "  $id caught: $what"
}

mutate_dsl () {  # $1 = id, $2 = what it breaks, $3 = the patched qbus_slot
    local id="$1" what="$2" f="$3"
    iverilog -g2012 -o "$SP/md.vvp" -s dsl_tb \
       $SRC/qbus_pkg.sv $SRC/bus/bk_rply.sv "$f" dsl_tb.v 2>&1 \
       | grep -v 'sorry:' || true
    if vvp -n "$SP/md.vvp" 2>/dev/null | grep -q '^COSIM PASS$'; then
        echo "MUTATION $id NOT CAUGHT ($what)" >&2
        exit 1
    fi
    echo "  $id caught: $what"
}

echo "mutations:"

# S1 - outward drivers come back the instant DIN releases, while the module is
#      still holding its read data: 16 lines of contention on every read.
patch "$MUT_SRC" 's|din_n & ~slot_rd & slot_live|din_n \& slot_live|' "$SP/m1.sv"
mutate S1 "outward AD not held off through the module's data hold" \
      "$MUT_MEM" "$SP/m1.sv" "$MUT_MOD"

# S2 - the ORIGINAL STUB BUG: AD only reaches the slot after SYNC has already
#      fallen, so a real slave latches its address with no setup at all.
patch "$MUT_SRC" 's|wire slot_ad_oe = din_n|wire slot_ad_oe = ~sync_n \& din_n|' "$SP/m2.sv"
mutate S2 "address released until after SYNC falls (the old stub bug)" \
      "$MUT_MEM" "$SP/m2.sv" "$MUT_MOD"

# S3 - the inward driver turns on for ANY read, not only one the module claimed,
#      so it fights every internal slave.
patch "$MUT_SRC" 's|else if (!din_n)            slot_rd <= ~slot_rply_rt_n;|else if (!din_n)            slot_rd <= 1'"'"'b1;|' "$SP/m3.sv"
mutate S3 "inward AD driven on every read, not only a claimed one" \
      "$MUT_MEM" "$SP/m3.sv" "$MUT_MOD"

# S4 - THE CLAUDE.md RMW RULE, from the module's side: a slave that re-arms on
#      SYNC-rise sits through the DOUT half of a DATIO and drops the write.
patch "$MUT_MOD" 's|if (strobes_idle) begin|if (pSltSync_n) begin|' "$SP/m4.v"
mutate S4 "module re-arms on SYNC-rise instead of strobes-idle (DATIO write lost)" \
      "$MUT_MEM" "$MUT_SRC" "$SP/m4.v"

# S5 - the deselect never reaches the reply decode, so the host ROM answers in
#      a region the module has taken over: two drivers, one address.
patch "$MUT_MEM" 's|(mkind == MK_ROM) && !rom_dsl|(mkind == MK_ROM)|' "$SP/m5.sv"
mutate S5 "host ROM still replies in a deselected region" \
      "$SP/m5.sv" "$MUT_SRC" "$MUT_MOD"

# S6 - the slot does not stand down for DIP 8, so the internal SMK512 and a real
#      module could both claim an address.
patch "$MUT_SRC" 's|else        slot_live <= &pres_sr\[2:1\] & ~smk_en;|else        slot_live <= 1'"'"'b1;|' "$SP/m6.sv"
iverilog -g2012 -o "$SP/m.vvp" -s slot_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv \
   $SRC/sdram/cpu_sdram_dp.sv $SRC/sdram/sdram_arbiter.sv \
   $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv \
   "$MUT_MEM" "$SP/m6.sv" "$MUT_MOD" ../sdram_model.sv slot_soc_tb.v 2>&1 \
   | grep -v 'sorry:' || true
if vvp -n "$SP/m.vvp" +dip8 2>/dev/null | grep -q '^COSIM PASS$'; then
    echo "MUTATION S6 NOT CAUGHT (slot does not stand down for DIP 8)" >&2
    exit 1
fi
echo "  S6 caught: slot does not stand down for DIP 8"

# S7 - THE HARDWARE BUG, 2026-08-30: the bridge does not export the 037's E, so
#      a module's top-window ROM (160000-177577, read-strobed by E rather than
#      DIN) never gets a strobe and can never reply. Found with a real МСТД
#      module: FOCAL at 120000 ran, the tests ROM at 160000 died with a bus
#      error. This is the mutation that would have caught it.
patch "$MUT_SRC" 's|assign pSltE_n = e_037_n;|assign pSltE_n = 1'"'"'b1;|' "$SP/m7.sv"
mutate S7 "the 037's E strobe not exported (the МСТД top-ROM failure)" \
      "$MUT_MEM" "$SP/m7.sv" "$MUT_MOD"

# S8 - BAS given the whole BASIC region instead of 120000-157777. On real
#      hardware BAS gates DS18+DS20 only; the 160000 window is BAS2's. With the
#      wide mask ocbk stands down over a window no module has claimed.
patch "$MUT_SRC" 's|(bas10 ? 8.b0011_1100 : 8.h00)|(bas10 ? 8'"'"'b1111_1100 : 8'"'"'h00)|' "$SP/m8.sv"
mutate S8 "BAS mask covers segs 6,7 (which belong to BAS2)" \
      "$MUT_MEM" "$SP/m8.sv" "$MUT_MOD"

# S9 - THE HARDWARE BUG, 2026-09: no start-vector merge at all. The module
#      DRIVES 0166400 at 177716 but never REPLIES (the vm1 self-replies for its
#      own 177700-177717 block), so a bridge that only takes data inward on its
#      own re-timed reply hands the CPU the bare SYS_START and the machine boots
#      to MONITOR instead of to the SMK BIOS. Only the +vecboot leg can see it.
patch "$MUT_SRC" 's|assign mpi_word = (vec_arm & sel1_rd) ? ~pSltAd : 16.h0000;|assign mpi_word = 16'"'"'h0000;|' "$SP/m9.sv"
mutate_leg S9 "+vecboot" "the start vector is not merged (the SMK512 no-boot)" \
      "$MUT_MEM" "$SP/m9.sv" "$MUT_MOD"

# S10 - the merge window never closes. The module drives 177716 on every read,
#       so MONITOR's keyboard (bit 6) and tape (bit 5) polls get the vector
#       ORed in - and on the board, where the pins are unterminated, an
#       UNDRIVEN 177716 would merge the stale address instead and send the PC to
#       0177400. Caught behaviourally by the program's re-read AND structurally
#       by the tb's one-open-per-DCLO counter.
patch "$MUT_SRC" 's|else if (sel1_rd_q & ~sel1_rd)  vec_arm <= 1.b0;|else if (1'"'"'b0)               vec_arm <= 1'"'"'b0;|' "$SP/m10.sv"
mutate_leg S10 "+vecboot" "the start-vector window never closes" \
      "$MUT_MEM" "$SP/m10.sv" "$MUT_MOD"

# S11 is gone: it pinned the M11 model gate through the SoC leg, and D8 on
# dsl_tb now does that directly - along with D9, which pins M11's WINDOW. M11
# takes the BK-0011M BOS at 140000-157777, not the 160000 one (that window
# needs no wire: МСТД is itself an МПИ card, so it is not in the machine).

# D1..D5 - the ROM deselect vector, on dsl_tb (the per-model contract).
# D1 is THE BK-0011M NO-BOOT, 2026-09-06: without the concede the host answers
# 0166400 out of the blob's mstd11m image - but on a real BK-0011M МСТД is an
# МПИ card and is not there once an SMK512 is plugged in, so the CPU ran MSTD
# payload (177736) instead of the module BIOS entry (000766) and hung.
patch "$MUT_SRC" 's|wire mstd_slot = slot_live & model_bk11;|wire mstd_slot = 1'"'"'b0;|' "$SP/d1.sv"
mutate_dsl D1 "the BK-0011M segs 6,7 concede removed (the bk11 no-boot)" "$SP/d1.sv"

patch "$MUT_SRC" 's|wire mstd_slot = slot_live & model_bk11;|wire mstd_slot = slot_live;|' "$SP/d2.sv"
mutate_dsl D2 "the concede applied on a BK-0010 too (BASIC bank 3 lost)" "$SP/d2.sv"

patch "$MUT_SRC" 's|(mstd_slot ? 8.b1100_0000 : 8.h00)|(mstd_slot ? 8'"'"'b1110_0000 : 8'"'"'h00)|' "$SP/d3.sv"
mutate_dsl D3 "the concede masks one segment too many" "$SP/d3.sv"

patch "$MUT_SRC" 's|wire mon10 = &m10_sr\[2:1\] & slot_live & ~model_bk11;|wire mon10 = \&m10_sr[2:1] \& slot_live;|' "$SP/d4.sv"
mutate_dsl D4 "MON10 honoured on a BK-0011M (the model gate)" "$SP/d4.sv"

patch "$MUT_SRC" 's|wire bas10 = &b10_sr\[2:1\] & slot_live & ~model_bk11;|wire bas10 = \&b10_sr[2:1] \& slot_live;|' "$SP/d5.sv"
mutate_dsl D5 "BAS honoured on a BK-0011M (the model gate)" "$SP/d5.sv"

patch "$MUT_SRC" 's|wire mon11 = &m11_sr\[2:1\] & slot_live &  model_bk11;|wire mon11 = \&m11_sr[2:1] \& slot_live;|' "$SP/d8.sv"
mutate_dsl D8 "M11 honoured on a BK-0010 (it is a bk11-only wire)" "$SP/d8.sv"

patch "$MUT_SRC" 's|(mon11 ? 8.b0011_0000 : 8.h00)|(mon11 ? 8'"'"'b1100_0000 : 8'"'"'h00)|' "$SP/d9.sv"
mutate_dsl D9 "M11 mapped to the 160000 window instead of BOS 140000-157777" "$SP/d9.sv"

patch "$MUT_SRC" 's|else        slot_live <= &pres_sr\[2:1\] & ~smk_en;|else        slot_live <= ~smk_en;|' "$SP/d6.sv"
mutate_dsl D6 "the adapter-presence term dropped (a bare bk11 loses МСТД)" "$SP/d6.sv"

patch "$MUT_SRC" 's|else        pres_sr <= {pres_sr\[1:0\], ~pSltPresent_n};|else        pres_sr <= {pres_sr[1:0], pSltPresent_n};|' "$SP/d7.sv"
mutate_dsl D7 "adapter presence sensed the wrong way round" "$SP/d7.sv"

# NOT mutation-tested, deliberately: the ~model_bk11 gate on BAS2 alone. BAS2
# covers segs 6,7 and a BK-0011M concedes those anyway, so honouring it there
# is provably unobservable. The gate stays for the symmetry of the four wires.

echo "МПИ slot oracle: 19 mutations, all caught"
