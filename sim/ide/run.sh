#!/usr/bin/env bash
#
# Phase-8 IDE unit oracle: src/peripheral/smk_ide.sv (the SMK512 IDE register block +
# ATA engine + AltPro geometry parse) against the behavioral ide_disk_model
# loaded with mem/gen_ide_image.py's synthetic AltPro image. The tb
# transcribes BkEmu IdeControllerTest + the SmkIdeController bus packing;
# see sim/ide/smk_ide_tb.v for the leg list.
#
# SECOND PASS (increment (b)): the SAME tb legs re-run with -DSD_STACK,
# swapping ide_disk_model for sd_harness = the REAL sd_backend + sd_model
# SPI stack (+sdsc personality: CSDv1 encodes the tb's totals exactly) -
# every transcribed BkEmu leg, incl. the every-sector CHS sweep and the
# DCLO geometry replays, must pass over the full SPI path. Slower (~2 min).
#
# MUTATION-TESTED (each applied by hand to src/peripheral/smk_ide.sv, each must FAIL):
#   1 inversion drop            : ide_rdata <= blk ? rd_word : 0
#   2 COMP_0 packing byte-swap  : rd_word[0] = {status, dar}
#   3 COMMAND accepted at 741   : drop the !w_a0 guard on the dispatch
#   4 E_DRAIN swap branch gone  : ptr==256 always completes -> leg 6's
#                                 second DRQ poll times out (chain stops)
#   5 CHS advance off-by-one    : x_snum wrap compares > instead of >=
#   6 1-based snum drop         : MRET_LBA1 omits the "- 28'd1" on mul_acc
#   7 checksum loop bound       : G_SUM ends at g_ptr 254 (skips the C word)
#   8 checksum seed             : compare against 012700
#   9 DHR 0xA0 forcing drop     : dhr <= w_inv[7:0] (no | DHR_FIXED)
#  --- tier-1 prefetch (each traced to a catching leg) ---
#  10 prefetch lands in drain bank : drop bank_fetch<=~bank_fetch -> 6/6b
#                                    data compare
#  11 swap without pf_ready        : E_DRAIN swaps unconditionally -> 6c
#                                    stale-bank data (+ BSY-window check)
#  12 dispatch flush removed       : no E_FLUSH on bk_busy -> 6d d1 wrong
#                                    data / d3 dropped fill words
#  13 CHS advanced at prefetch-done: bump snum on the prefetch bk_done ->
#                                    6b mid-drain SNUM check
#  14 scount!=1 guard dropped      : issue a prefetch past chain end ->
#                                    6b ack_cnt (5 != 4)
#
set -euo pipefail
cd "$(dirname "$0")"

python3 ../../mem/gen_ide_image.py .

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
iverilog -g2012 -o "$SP/ide.vvp" -s smk_ide_tb \
   $SRC/peripheral/smk_ide.sv ide_disk_model.v smk_ide_tb.v 2>&1 \
   | grep -v 'sorry:' || true

vvp -n "$SP/ide.vvp" | tee "$SP/out.txt" | grep -E "IDE-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "ide unit cosim: FAIL" >&2; exit 1; }
echo "ide unit cosim: PASS"

iverilog -g2012 -DSD_STACK -o "$SP/ide_sd.vvp" -s smk_ide_tb \
   $SRC/peripheral/smk_ide.sv $SRC/peripheral/sd_backend.sv \
   sd_model.v sd_harness.v smk_ide_tb.v 2>&1 \
   | grep -v 'sorry:' || true

vvp -n "$SP/ide_sd.vvp" +sdsc | tee "$SP/out_sd.txt" \
   | grep -E "IDE-ERROR|SD-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out_sd.txt" \
   || { echo "ide unit cosim (SD stack): FAIL" >&2; exit 1; }
# the tb's verdict counts its own errors; card protocol errors fail here
grep -q 'SD-ERROR' "$SP/out_sd.txt" \
   && { echo "ide unit cosim (SD stack): FAIL (card protocol)" >&2; exit 1; }
echo "ide unit cosim (SD stack): PASS"
