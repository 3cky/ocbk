#!/usr/bin/env bash
#
# Boot-loader unit cosim (Phase 5 + the Phase-7 two-pass bk11 blob): EPCS
# flash model -> epcs_boot -> arbiter port 0 -> sdram_ctrl -> sdram_model.
# Word-for-word SDRAM equality vs BOTH blobs (bk10 at words 0x4000+, bk11 at
# 0x30000+), plus corrupted-blob runs (+corrupt = first blob, +corrupt2 =
# second) that must end boot_ok=0.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

# the blob inputs (mem/roms/*.rom) are committed; the blob itself is generated
( cd ../mem && python3 gen_boot_blob.py )

SRC=../src
iverilog -g2012 -o "$SP/epcs.vvp" -s epcs_boot_tb \
   $SRC/sdram/epcs_boot.sv $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   epcs_model.sv sdram_model.sv epcs_boot_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/epcs.vvp" 2>/dev/null | tee "$SP/out.txt" | grep -E 'EPCS' || true
grep -q '^EPCS-BOOT: PASS$' "$SP/out.txt" || { echo "epcs_boot cosim: FAIL" >&2; exit 1; }

vvp -n "$SP/epcs.vvp" +corrupt 2>/dev/null | tee "$SP/out2.txt" | grep -E 'EPCS' || true
grep -q '^EPCS-BOOT: PASS$' "$SP/out2.txt" || { echo "epcs_boot corrupt-run: FAIL" >&2; exit 1; }

vvp -n "$SP/epcs.vvp" +corrupt2 2>/dev/null | tee "$SP/out3.txt" | grep -E 'EPCS' || true
grep -q '^EPCS-BOOT: PASS$' "$SP/out3.txt" || { echo "epcs_boot corrupt2-run: FAIL" >&2; exit 1; }

echo "epcs_boot loader cosim (clean + corrupted blob/blob11): PASS"
