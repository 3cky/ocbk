#!/usr/bin/env bash
#
# Phase-8 IDE SoC functional oracle: the mem/gen_ide_test.py program on the
# real SoC stack (vm1 + va_037_sync + qbus_mem incl. sel_ide + smk_ide +
# ide_disk_model + sdram_model) at the /24 CPU rate under port-2 contention.
# See sim/ide/ide_soc_tb.v for the leg list and the sim/smk conventions
# (parks 001004/001012, vector 4 -> fail, COSIM PASS).
#
# MUTATION-TESTED at the SoC level (each applied by hand, each must FAIL):
#   1 qbus_mem merge term drop   : rdata loses `| (sel_ide ? ide_rdata : 0)`
#     (the program's very first probe compares 0o146677 -> fail park)
#   2 sel_ide write-claim drop   : `selected` loses sel_ide on writes
#     (`| (sel_ide & is_read)` instead) - the section-1 scount write
#     bus-times-out -> trap 4 -> fail park
#   3 smk_ide DOUT lane swap     : COMMAND taken from w_inv[15:8]
#     (IDENTIFY never starts, DRQ poll hangs -> watchdog)
#
set -euo pipefail
cd "$(dirname "$0")"

python3 ../../mem/gen_ide_image.py .
( cd ../../mem && python3 gen_ide_test.py ../sim/ide )

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../../src/cpu

iverilog -g2012 -o "$SP/ide_soc.vvp" -s ide_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/mem_mapper.sv \
   ../../src/qbus_mem.sv ../../src/smk_ide.sv \
   ide_disk_model.v ../sdram_model.sv ide_soc_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ide_soc.vvp" | tee "$SP/out.txt" | grep -E "IDE-ERROR|IDE-X-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "ide SoC cosim: FAIL" >&2; exit 1; }
echo "ide SoC cosim: PASS"
