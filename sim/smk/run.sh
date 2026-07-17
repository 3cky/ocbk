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
#   * qbus_mem kbd_blk read carve-out dropped -> FAIL (the 177660
#     expect-trap-4 check: the overlay must not reply there);
#   * qbus_mem `selected` without the write-side ~m_smk_ro -> FAIL (was the
#     increment-1 documented MASKED mutation; the reworked issued-legs
#     done-gate no longer holds an un-issued RO write in S_WAIT, so the
#     bogus reply now surfaces and the HLT10 trap expectation catches it);
#   * the extent direction swap (ALL<->HLT flags) is pinned by
#     sim/run_mapper.sh (S8), whose increment-2 mutations also cover the
#     rom6/rom7 selection swap, the extent boundary off-by-one and a wrong
#     SMK_BIOS_BASE bit.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

( cd ../../mem && python3 gen_smk_test.py ../sim/smk ) > /dev/null

CPU=../../src/cpu
iverilog -g2012 -o "$SP/smk.vvp" -s smk_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/mem_mapper.sv \
   ../../src/qbus_mem.sv ../sdram_model.sv \
   smk_soc_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/smk.vvp" 2>/dev/null | tee "$SP/out.txt" | grep -E "SMK-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "SMK512 RAM oracle: FAIL" >&2; exit 1; }
echo "SMK512 RAM oracle: PASS"
