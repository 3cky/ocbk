#!/usr/bin/env bash
#
# Phase-7 mem_mapper unit oracle: BK-0010 mode swept over all 64K addresses
# against the pre-Phase-7 inline decode (map-content-independent), and the
# BK-0011M banking semantics (windows/pages, ROM overlay codes + the 033-quirk
# fall-through, word-write-only banking, DCLO-only re-init). See sim/mapper_tb.sv.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -o "$SP/mapper.vvp" -s mapper_tb \
   ../src/qbus_pkg.sv ../src/mem_mapper.sv mapper_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/mapper.vvp" | tee "$SP/out.txt" | grep -E "MAPPER-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "mem_mapper oracle: FAIL" >&2; exit 1; }
echo "mem_mapper oracle: PASS"
