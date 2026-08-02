#!/usr/bin/env bash
#
# Phase-8 SMK512 functional oracle (data-checking, NOT a timing golden): the
# gen_smk_test.py program walks the BkEmu SmkMemoryManager contract on the
# real SoC stack (vm1 + va_037_sync + qbus_mem with smk_en=1 in BK-0011M mode
# + a DEEPENED sdram_model + port-2 contention) at the /24 = 4.03 MHz CPU
# rate. Increment 2: it BOOTS through the real SMK mechanism (the SYS rom7
# register-space overlay -> the merged 177716 read -> PC 166400 in the rom6
# BIOS window; the tb preloads a synthetic BIOS image at SMK_BIOS_BASE, and
# nothing in SMK RAM), covers the BIOS windows / the I/O-page OR-merge with
# its carve-outs / the seg-7 extents / the authentic СТОП-HALT-entry catch,
# then a tb DCLO replay proves the SYS re-init (BIOS windows back) + SMK RAM
# survival. See sim/smk/smk_soc_tb.v.
#
# TWO LEGS since the bk10+SMK increment. The second (`--bk10` / `+bk10`,
# BkEmu BK_0010_SMK512) re-runs the whole contract on a BK-0010 stack -
# model_bk11=0, the /32 = 3.02 MHz CPU rate, the program resident in the
# machine's own RAM (SDRAM 0x0000) - because the SMK is an МПИ expansion
# board and everything except which standard memory a mode deselects is
# model-independent. The bk10-specific legs: the MONITOR ROM at segs 0,1 in
# SYS/STD10/STD11/RAM11 (mon_en) and read-only there; the ex-BASIC region
# 0120000-0157777 DEAD wherever the SMK does not cover it (the tb pokes a
# marker at SDRAM 0x5000 that must never show - BK_0010_SMK512 has no BASIC
# ROMs); HLT11, the one mode where mon_en is observable (segs 0-3 all trap);
# RAM11's mixed monitor/dead/SMK layout; and THE model-detect mechanism the
# real BIOS uses - under SYS a 177662 write hits the rom7 ROM window and
# bus-times-out -> trap 4 (on a bk11 the same write is REPLIED by qbus_mem's
# model-gated sel_vreg decode, which is exactly how the BIOS tells the two
# machines apart). The 177716 merge is checked against SYS_START = 0100000.
#
# SECTION 12 (СТОП/HALT entry) NOTE, 2026-07-25: the stored-PC check accepts
# stop_spin OR stop_handler. nIRQ1 is a fixed 64-cpu_clk one-shot while the
# HALT entry (two extent stores + two SMK-RAM vector fetches) takes ~30, so
# whether СТОП re-enters at the handler's first instruction is purely a
# question of how fast SMK RAM is - it did not at the Phase-8 placeholder
# N_EXT = 4, it does at the calibrated N_EXT = 1. Neither the vm1 (СТОП
# ignores PSW priority) nor the program (the re-entry pre-empts instruction 1)
# can suppress it, and both outcomes prove the same thing. See gen_smk_test.py.
#
# MUTATION-TESTED (2026-07-17, increment 1):
#   * qbus_mem `selected` without the sel_ext term -> FAIL (the first SMK
#     access bus-times-out -> fail park): the reply path is load-bearing;
#   * qbus_mem u_dp .sel_ram feed without the RO exclusion (sel_ext
#     unqualified) -> FAIL (the HLT10 seg-0 write LANDS in the SDRAM; the
#     post-trap value check catches it): RO writes are never issued;
#   * mem_mapper page-scatter swap / arm-edge commit / seg-7 cap drop /
#     lane-mask drop / mode-mask break -> the matching sections fail
#     (also pinned, faster, by sim/run_mapper.sh - see its header).
# MUTATION-TESTED (increment 2, the BIOS/boot/extent machinery):
#   * mem_mapper rom7 dropped from the RESET default -> FAIL (the boot
#     mechanism itself: the 177716 read loses the BIOS word, PC lands on
#     zeroed SMK RAM);
#   * mem_mapper rom7 dropped from the SYS COMMIT arm -> FAIL (the
#     committed-SYS re-verify section - reset-SYS alone would mask it);
#   * qbus_mem reply-point merge dropped (rdata <= rd_romio only) -> FAIL
#     (boot: the start read returns plain 140000);
#   * cpu_sdram_dp rd_noe/was_drive inhibit dropped -> FAIL (the tb X
#     monitor: u_dp drives BIOS data against the vm1's 177712 self-served
#     read - the exact pad fight the inhibit prevents);
#   * cpu_sdram_dp sel_ramw dropped from is_write -> FAIL (the HLT10 extent
#     write is replied but never posted; the ALL-alias readback catches it);
#   * qbus_mem's 0177714 joystick merge dropped (`!sel2_n ? joy_word` back to
#     a hard 0) -> FAIL (section 2's 177714 compare); and the !sel2_n GATE
#     dropped (the else-leg made unconditional) -> FAIL (section 2's 177776
#     compare, where io_word must contribute NOTHING). BOTH VERIFIED BY HAND
#     2026-08-02. This oracle owns that gate because it is the only place with
#     a real SDRAM behind the I/O-page overlay: leg 2 of sim/run_audio.sh pins
#     the merge itself (Q6-Q9) but cannot reach an overlay read at all.
#   * qbus_mem kbd_blk read carve-out dropped -> FAIL (the 177660
#     expect-trap-4 check: the overlay must not reply there);
#   * qbus_mem `selected` without the write-side ~m_smk_ro -> FAIL (was the
#     increment-1 documented MASKED mutation; the reworked issued-legs
#     done-gate no longer holds an un-issued RO write in S_WAIT, so the
#     bogus reply now surfaces and the HLT10 trap expectation catches it);
# MUTATION-TESTED (2026-07-23, the bk10 leg - each fails the +bk10 run and
# leaves the bk11 leg passing, i.e. they are genuinely bk10-specific):
#   * mem_mapper std_vec widened to all eight segments in bk10 -> FAIL (the
#     ex-BASIC region shows the ROM blob through; the STD11/RAM11 dead-segment
#     expectations catch it) - this is the "BkEmu has no BASIC in that config"
#     decision, and it is load-bearing, not cosmetic;
#   * mem_mapper mon_en dropped (the monitor always selected) -> FAIL (the
#     HLT11 leg: 0100000-0137777 must be dead when the mode deselects it);
#   * qbus_mem sel_fdd re-gated with model_bk11 -> FAIL (the RAM10 leg's
#     177130/177132 read-0 checks bus-time-out) - and the same for sel_ide by
#     construction (sim/ide/run_soc.sh owns that decode's contract).
#   * the extent direction swap (ALL<->HLT flags) is pinned by
#     sim/run_mapper.sh (S8), whose increment-2 mutations also cover the
#     rom6/rom7 selection swap, the extent boundary off-by-one and a wrong
#     SMK_BIOS_BASE bit.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
CPU=$SRC/cpu
iverilog -g2012 -o "$SP/smk.vvp" -s smk_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   $SRC/qbus_pkg.sv $SRC/bus/va_037_sync.sv $SRC/bus/bk_rply.sv $SRC/sdram/cpu_sdram_dp.sv \
   $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv $SRC/bus/mem_mapper.sv \
   $SRC/bus/qbus_mem.sv $SRC/peripheral/bk_evnt.sv ../sdram_model.sv \
   smk_soc_tb.v 2>&1 | grep -v 'sorry:' || true

# Two legs: BK-0011M (the original) and BK-0010 (+bk10). Each regenerates its
# own images first - the bk11 leg's residence image is physical RAM page 6,
# the bk10 leg's is the machine's own RAM at SDRAM 0x0000.
run_leg () {   # $1 = label, $2 = gen flags, $3 = vvp plusargs
    ( cd ../../mem && python3 gen_smk_test.py $2 ../sim/smk ) > /dev/null
    vvp -n "$SP/smk.vvp" $3 2>/dev/null | tee "$SP/out.txt" \
        | grep -E "SMK-ERROR|COSIM" || true
    grep -q '^COSIM PASS$' "$SP/out.txt" \
        || { echo "SMK512 RAM oracle ($1): FAIL" >&2; exit 1; }
    echo "SMK512 RAM oracle ($1): PASS"
}

run_leg "BK-0011M" "" ""
run_leg "BK-0010"  "--bk10" "+bk10"
