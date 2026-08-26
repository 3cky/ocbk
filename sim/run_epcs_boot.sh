#!/usr/bin/env bash
#
# Boot-loader unit cosim (Phase 5 + the Phase-7 two-pass bk11 blob): EPCS
# flash model -> epcs_boot -> arbiter port 0 -> sdram_ctrl -> sdram_model.
# Word-for-word SDRAM equality vs BOTH blobs (bk10 at words 0x4000+, bk11 at
# 0x30000+), plus corrupted-blob runs (+corrupt = first blob, +corrupt2 =
# second) that must end boot_ok=0.
#
set -uo pipefail
cd "$(dirname "$0")"
. parlib.sh

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

# the blob inputs (mem/roms/*.rom) are committed; the blob itself is generated
( cd ../mem && python3 gen_boot_blob.py )

SRC=../src
iverilog -g2012 -o "$SP/epcs.vvp" -s epcs_boot_tb \
   $SRC/sdram/epcs_boot.sv $SRC/sdram/sdram_arbiter.sv $SRC/sdram/sdram_ctrl.sv \
   epcs_model.sv sdram_model.sv epcs_boot_tb.sv 2>&1 | grep -v 'sorry:' || true

# The three blob variants are independent runs of the same image.
leg() {   # leg <label> [plusargs...]
   local label="$1"; shift
   local out="$SP/$label.txt"
   vvp -n "$SP/epcs.vvp" "$@" 2>/dev/null | tee "$out" | grep -E 'EPCS' || true
   grep -q '^EPCS-BOOT: PASS$' "$out" || { echo "epcs_boot $label: FAIL" >&2; return 1; }
}

par_init
par_job clean    leg clean
par_job corrupt  leg corrupt  +corrupt
par_job corrupt2 leg corrupt2 +corrupt2
par_wait || exit 1

echo "epcs_boot loader cosim (clean + corrupted blob/blob11): PASS"
