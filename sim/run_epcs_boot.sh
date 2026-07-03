#!/usr/bin/env bash
#
# Phase-5 boot-loader unit cosim: EPCS flash model -> epcs_boot -> arbiter
# port 0 -> sdram_ctrl -> sdram_model. Word-for-word SDRAM equality vs the
# blob, plus a corrupted-blob run that must end boot_ok=0.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

# the blob inputs (mem/roms/*.rom) are committed; the blob itself is generated
( cd ../mem && python3 gen_boot_blob.py )

iverilog -g2012 -o "$SP/epcs.vvp" -s epcs_boot_tb \
   ../src/epcs_boot.sv ../src/sdram_arbiter.sv ../src/sdram_ctrl.sv \
   epcs_model.sv sdram_model.sv epcs_boot_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/epcs.vvp" 2>/dev/null | tee "$SP/out.txt" | grep -E 'EPCS' || true
grep -q '^EPCS-BOOT: PASS$' "$SP/out.txt" || { echo "epcs_boot cosim: FAIL" >&2; exit 1; }

vvp -n "$SP/epcs.vvp" +corrupt 2>/dev/null | tee "$SP/out2.txt" | grep -E 'EPCS' || true
grep -q '^EPCS-BOOT: PASS$' "$SP/out2.txt" || { echo "epcs_boot corrupt-run: FAIL" >&2; exit 1; }

echo "epcs_boot loader cosim (clean + corrupted blob): PASS"
