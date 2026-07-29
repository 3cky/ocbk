#!/usr/bin/env bash
#
# Phase-8 increment-(b) SD backend unit oracle: src/peripheral/sd_backend.sv (the
# SPI-mode SD host serving the smk_ide backend sector port) against the
# protocol-checking sd_model.v card, loaded with mem/gen_ide_image.py's
# AltPro image. Seven vvp runs of one compile: the SDHC personality, +sdsc
# (v1 byte-addressed card), +noinit, +rderr, +wrrej, +cmd0busy and
# +cmd8junk - see the tb header for the leg list (leg 4 = warm-reset
# recovery with the card deliberately NOT reset). The card model checks the
# wire protocol itself (CMD0/CMD8 CRCs, CMD55 pairing, SDSC 512-alignment,
# init ordering) and its violations fail the run alongside the tb's data
# checks.
#
# The multi-block (CMD18/CMD25) legs and their seven mutations were removed
# with the tier-2 revert (2026-07-23; see the sd_backend.sv header). The
# model still SPEAKS multi-block - a real card does - so the coverage can
# come back with the feature if it is ever revisited.
#
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
#  10 preamble removed     : S_DUMMY jumps straight to S_CMD0 -> leg 4: the
#     half-block the card still holds is never flushed, so it feeds CMD0's
#     R1 poll and outlasts the retries; media_ok never returns
#     NOT MUTATION-COVERED, deliberately: the preamble's 0xFD and CMD12
#     only matter to a card left mid-multi-block, and since the tier-2
#     revert nothing in this design can open such a stream. They are
#     insurance against other firmware / a card in an unknown state, so no
#     leg here can kill their removal. Said out loud rather than left as a
#     silent gap in the list.
#  11 flush removed        : the preamble's CMD12 returns to S_PRE_END
#     instead of S_PRE_FLUSH -> leg 4: the half-block the card still holds
#     is fed to CMD0's R1 poll, every CMD0_TRIES fails, media_ok never
#     returns
#  12 flush exits early     : S_PRE_FLUSH also exits on x_ff, i.e. as soon as
#     the bus LOOKS idle -> leg 4: the sector's leading 0xFF run (what a BK
#     disk really looks like on the card - the IDE layer inverts) ends the
#     flush inside the residue, so the recovery needs a second pass and the
#     "one pass is enough" check in warm_reset fires (leg 4). NOTE this mutation
#     SURVIVES without that check, because the automatic retry rescues it -
#     which is exactly why the check is written as a positive assertion on
#     dbg_retried rather than just "media_ok came back"
#  13 recovery not re-run   : S_RETRY re-sends CMD0 alone instead of
#     re-entering S_SETTLE -> +cmd0busy: the bare re-send loop is ~1 ms of
#     traffic and gives up long before the card stops being busy, so init
#     dies (the field symptom: one reset press is not enough)
#  14 CMD0-only retry        : S_RETRY only re-runs when dbg_fail == 1, i.e.
#     the pre-fix structure where a failure PAST CMD0 was fatal -> +cmd8junk:
#     one junk CMD8 response types the SDHC card as v1, ACMD41 goes out
#     without HCS, the card never leaves idle and init dies with no retry
#
set -euo pipefail
cd "$(dirname "$0")"

python3 ../../mem/gen_ide_image.py .

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

SRC=../../src
iverilog -g2012 -o "$SP/sd.vvp" -s sd_backend_tb \
   $SRC/peripheral/sd_backend.sv sd_model.v sd_backend_tb.v 2>&1 \
   | grep -v 'sorry:' || true

for leg in "" "+sdsc" "+noinit" "+rderr" "+wrrej" "+cmd0busy" "+cmd8junk"; do
    vvp -n "$SP/sd.vvp" $leg | tee "$SP/out.txt" | grep -E "SD-ERROR|COSIM" || true
    grep -q '^COSIM PASS$' "$SP/out.txt" \
        || { echo "sd backend unit cosim (${leg:-sdhc}): FAIL" >&2; exit 1; }
    echo "sd backend unit cosim (${leg:-sdhc}): PASS"
done
