#!/usr/bin/env bash
#
# Phase-7 mem_mapper unit oracle: BK-0010 mode swept over all 64K addresses
# against the pre-Phase-7 inline decode (map-content-independent), and the
# BK-0011M banking semantics (windows/pages, ROM overlay codes + the 033-quirk
# fall-through, word-write-only banking, DCLO-only re-init). See sim/mapper_tb.sv.
#
# Phase 8 (SMK512): a differential smk_en=0 reference instance pins every
# non-SMK configuration bit-identical over full-64K sweeps, plus the directed
# BkEmu SmkMemoryManager contract - the 177130 two-phase strobe (incl. the
# byte-lane masking), the 8-mode x 8-seg table with the SYS/ALL +4 rotation,
# the {v0,v3,v2,v10} page scatter, HLT10 seg-0 read-only (smk_ro), std
# passthrough tracking live banking, DCLO-only reset. Increment 2 (BIOS ROM):
# the rom6/rom7 BIOS windows (rom7 = the SYS register-space boot overlay,
# 177716 included), the per-mode seg-7 restricted extent (ALL readable /
# HLT10-HLT11 writable via smk_wo, others capped -> MK_NONE, boundary exact),
# and 177130-read = BIOS ROM under SYS (write side stays qbus_mem's).
# Mutation-tested x10 (5 increment-1 + 5 increment-2): see the tb header.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -o "$SP/mapper.vvp" -s mapper_tb \
   ../src/qbus_pkg.sv ../src/mem_mapper.sv mapper_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/mapper.vvp" | tee "$SP/out.txt" | grep -E "MAPPER-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "mem_mapper oracle: FAIL" >&2; exit 1; }
echo "mem_mapper oracle: PASS"
