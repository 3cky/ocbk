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
#
# BK-0010 + SMK (BkEmu BK_0010_SMK512, sections S2/S11): the SMK is an МПИ
# expansion board, so the 177130 register file, the mode table, the rotation,
# the page scatter, the BIOS windows and the extents are model-INDEPENDENT
# and shared across a model flip; the only difference is which standard
# memory a mode deselects - the MONITOR ROM (mon_en) instead of BOS + the
# second banked window. S11 walks all 8 modes from bk10: monitor ROM at segs
# 0,1 in SYS/STD10/STD11/RAM11, the ex-BASIC region DEAD wherever the SMK
# does not cover it (that config has no BASIC ROMs), HLT11 the one mode where
# mon_en shows (segs 0-3 dead), HLT10's HALT-debugger seg-0/extent flags, and
# the low 32K differential-identical to the smk_en=0 reference throughout.
# Mutation-tested x15 (5 increment-1 + 5 increment-2 + 5 bk10): see the tb
# header.
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

iverilog -g2012 -o "$SP/mapper.vvp" -s mapper_tb \
   ../src/qbus_pkg.sv ../src/mem_mapper.sv mapper_tb.sv 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/mapper.vvp" | tee "$SP/out.txt" | grep -E "MAPPER-ERROR|COSIM" || true

grep -q '^COSIM PASS$' "$SP/out.txt" || { echo "mem_mapper oracle: FAIL" >&2; exit 1; }
echo "mem_mapper oracle: PASS"
