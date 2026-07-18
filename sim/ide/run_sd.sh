#!/usr/bin/env bash
#
# Phase-8 increment-(b) SD backend unit oracle: src/sd_backend.sv (the
# SPI-mode SD host serving the smk_ide backend sector port) against the
# protocol-checking sd_model.v card, loaded with mem/gen_ide_image.py's
# AltPro image. Five vvp runs of one compile: SDHC personality, +sdsc
# (v1 byte-addressed card), +noinit, +rderr, +wrrej - see the tb header
# for the leg list. The card model checks the wire protocol itself
# (CMD0/CMD8 CRCs, CMD55 pairing, SDSC 512-alignment, init ordering) and
# its violations fail the run alongside the tb's data checks.
#
# MUTATION-TESTED (each applied by hand to src/sd_backend.sv, each must FAIL):
#   1 SDSC x512 drop        : A_DISPATCH cmd_arg always the block address
#   2 CMD8 CRC wrong        : cmd_crc <= 8'h86 in S_CMD8
#   3 HCS drop              : S_CMD41 cmd_arg always 32'h0 (SDHC never readies)
#   4 CSD capacity off-by-one: v2 branch drops the +1 (bk_total 0 -> every
#     read oob) / v1_total drops the +1
#   5 LE byte swap          : A_RDATA bk_wdata <= {lo_byte, x_rx}
#   6 commit settle drop    : A_WFETCH -> A_WSAMP directly (skips A_WWAIT;
#     stale bk_rdata shifts the write stream one word)
#   7 R1 poll break         : F_R1 takes ANY byte as R1 (drops the !x_rx[7]
#     guard; the 0xFF NCR filler parses as no-response -> init dies)
#   8 oob guard drop        : A_DISPATCH compares > instead of >= (the
#     sector==bk_total request reaches the card -> model protocol error)
#   9 dummy-clock cut       : S_SETTLE loads 8 instead of 80 (model counts
#     <74 pre-CMD0 clocks)
#
set -euo pipefail
cd "$(dirname "$0")"

python3 ../../mem/gen_ide_image.py .

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -o "$SP/sd.vvp" -s sd_backend_tb \
   ../../src/sd_backend.sv sd_model.v sd_backend_tb.v 2>&1 \
   | grep -v 'sorry:' || true

for leg in "" "+sdsc" "+noinit" "+rderr" "+wrrej"; do
    vvp -n "$SP/sd.vvp" $leg | tee "$SP/out.txt" | grep -E "SD-ERROR|COSIM" || true
    grep -q '^COSIM PASS$' "$SP/out.txt" \
        || { echo "sd backend unit cosim (${leg:-sdhc}): FAIL" >&2; exit 1; }
    echo "sd backend unit cosim (${leg:-sdhc}): PASS"
done
