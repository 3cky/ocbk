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
# Three legs:
#   attached  - the module answers; every sub-test runs.
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
run_leg "empty connector"  "+noreply"
run_leg "DIP 8 stand-down" "+dip8"

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
patch "$MUT_SRC" 's|wire slot_live = ~smk_en;|wire slot_live = 1'"'"'b1;|' "$SP/m6.sv"
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

echo "МПИ slot oracle: 8 mutations, all caught"
