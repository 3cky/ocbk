#!/usr/bin/env bash
#
# Phase 3 reference-oracle regression: vm1 CPU + real va_037 + behavioural DRAM.
#
# Establishes the ground-truth per-instruction cycle counts WITH the 037 video
# cycle-stealing active (see ref037_tb.v). The reduced output (unique instruction
# prefix + the first few self-loop samples) is diffed against golden_037.txt.
# This is the reference that the retimed va_037_sync (Phase 3) must reproduce
# exactly; the delta vs sim/bk10/golden.txt is the with-/without-display overhead.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../../src/cpu
K037="."

iverilog -g2012 -o "$SP/ref037.vvp" -s ref037_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" "$K037/va_037.v" \
   ref037_tb.v 2>&1 | grep -v 'sorry:' || true

# Reduce: unique instruction prefix, then the first 4 self-loop samples.
# $1 = self-loop address (001136 for the RAM program, 101136 for +romprog).
# The sample counter re-arms on any non-loop line: in a +warmreset run the
# program re-executes after the mid-run reset, so each pass keeps its own
# first 4 loop samples (single-pass output is unchanged - the loop address
# only ever appears at the end of a pass).
reduce() { awk -v loop="${1:-001136}" \
   '/^FETCH/ { if ($2==loop) { c++; if (c<=4) print } else { c=0; print } }'; }

vvp -n "$SP/ref037.vvp" 2>/dev/null | reduce > "$SP/out.txt"

if diff -u golden_037.txt "$SP/out.txt"; then
   echo "ref037 (reference va_037) cycle counts: PASS"
else
   echo "ref037 (reference va_037) cycle counts: FAIL (see diff above)" >&2
   exit 1
fi

# --- Phase 5 ROM-region oracle: the same program words executed FROM ROM
#     (fixed N_ROM reply, no 037 cycle-stealing on fetches; RAM data traffic
#     still stolen). golden_037_rom.txt is generated from this reference run
#     only. Key property: the ROM self-loop is FLAT (constant cycles) - any
#     later SDRAM-induced RPLY extension on ROM fetches breaks this diff. ---
vvp -n "$SP/ref037.vvp" +romprog 2>/dev/null | reduce 101136 > "$SP/out_rom.txt"

if diff -u golden_037_rom.txt "$SP/out_rom.txt"; then
   echo "ref037 (reference va_037, ROM-region program) cycle counts: PASS"
else
   echo "ref037 (reference, ROM-region) cycle counts: FAIL (see diff above)" >&2
   exit 1
fi

# --- Equivalence: the retimed src/va_037_sync.sv must reproduce the same golden ---
iverilog -g2012 -o "$SP/ref037s.vvp" -s ref037_sync_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" ../../src/va_037_sync.sv \
   ref037_sync_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ref037s.vvp" 2>/dev/null | reduce > "$SP/out_sync.txt"

if diff -u golden_037.txt "$SP/out_sync.txt"; then
   echo "ref037 (retimed va_037_sync) equivalence: PASS"
else
   echo "ref037 (retimed va_037_sync) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

vvp -n "$SP/ref037s.vvp" +romprog 2>/dev/null | reduce 101136 > "$SP/out_sync_rom.txt"

if diff -u golden_037_rom.txt "$SP/out_sync_rom.txt"; then
   echo "ref037 (retimed va_037_sync, ROM-region program) equivalence: PASS"
else
   echo "ref037 (retimed, ROM-region) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- SoC integration: va_037_sync owns RAM RPLY, RAM in real SDRAM via the
#     REAL qbus_mem_sdram (ROM/IO FSM + arbiter + cpu_sdram_dp + done-gate),
#     with the 037 fetch streaming contention. Must still reproduce the golden
#     (timing preserved) and run out of SDRAM. Run twice: program in RAM
#     (bootstrap JMP in the SDRAM ROM region) and +romprog (Phase-5 ROM-in-SDRAM). ---
iverilog -g2012 -o "$SP/ref037soc.vvp" -s ref037_soc_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/qbus_mem_sdram.sv \
   ../../src/epcs_boot.sv ../sdram_model.sv ../epcs_model.sv \
   ref037_soc_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ref037soc.vvp" 2>/dev/null | reduce > "$SP/out_soc.txt"

if diff -u golden_037.txt "$SP/out_soc.txt"; then
   echo "ref037 (SoC integration: 037+arbiter+SDRAM+done-gate) equivalence: PASS"
else
   echo "ref037 (SoC integration) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

vvp -n "$SP/ref037soc.vvp" +romprog 2>/dev/null | reduce 101136 > "$SP/out_soc_rom.txt"

if diff -u golden_037_rom.txt "$SP/out_soc_rom.txt"; then
   echo "ref037 (SoC integration, ROM-in-SDRAM program) equivalence: PASS"
else
   echo "ref037 (SoC integration, ROM-in-SDRAM) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- Phase 5.5 soft reset: mid-run DCLO/ACLO re-pulse (the reset button) with
#     SDRAM and boot state untouched; the program re-executes and BOTH passes
#     must match the same golden - a warm reset is cycle-identical to a cold
#     boot. Run in RAM mode and ROM-in-SDRAM mode. ---
vvp -n "$SP/ref037soc.vvp" +warmreset 2>/dev/null | reduce > "$SP/out_soc_warm.txt"

if cat golden_037.txt golden_037.txt | diff -u - "$SP/out_soc_warm.txt"; then
   echo "ref037 (SoC integration, warm-reset replay) equivalence: PASS"
else
   echo "ref037 (SoC, warm-reset replay) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

vvp -n "$SP/ref037soc.vvp" +romprog +warmreset 2>/dev/null | reduce 101136 \
   > "$SP/out_soc_rom_warm.txt"

if cat golden_037_rom.txt golden_037_rom.txt | diff -u - "$SP/out_soc_rom_warm.txt"; then
   echo "ref037 (SoC integration, ROM warm-reset replay) equivalence: PASS"
else
   echo "ref037 (SoC, ROM warm-reset replay) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- Phase 5 boot path: the SDRAM ROM region is populated by the REAL EPCS
#     loader (flash model -> epcs_boot -> boot-writer mux on port 0) during
#     reset-hold, exactly as ocbk_top boots. Golden must still match. ---
vvp -n "$SP/ref037soc.vvp" +romprog +bootload 2>/dev/null | reduce 101136 \
   > "$SP/out_soc_boot.txt"

if diff -u golden_037_rom.txt "$SP/out_soc_boot.txt"; then
   echo "ref037 (SoC integration, EPCS-loader boot path) equivalence: PASS"
else
   echo "ref037 (SoC, EPCS-loader boot) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- Phase 4 cycle-accuracy gate: same SoC but with the REAL video pipeline on
#     all four arbiter ports (readout on a true 3:2 pixel clock + fetch/palette/
#     FB-write), run on past display start. Golden window must match exactly;
#     display-phase self-loop iterations are checked against the reference beat
#     pattern inside the tb (violations print FETCH-* lines -> the diff fails). ---
iverilog -g2012 -o "$SP/ref037socv.vvp" -s ref037_soc_video_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   ../../src/qbus_pkg.sv ../../src/va_037_sync.sv ../../src/cpu_sdram_dp.sv \
   ../../src/sdram_arbiter.sv ../../src/sdram_ctrl.sv ../../src/qbus_mem_sdram.sv \
   ../../src/fb_video.sv ../../src/palette_apply.sv \
   ../../src/fb_readout.sv ../../src/fb_linebuf.sv ../../src/vga_out.sv \
   ../../src/vga_timing.sv ../sdram_model.sv \
   ref037_soc_video_tb.v 2>&1 | grep -v 'sorry:' || true

vvp -n "$SP/ref037socv.vvp" 2>/dev/null | reduce > "$SP/out_socv.txt"

if diff -u golden_037.txt "$SP/out_socv.txt"; then
   echo "ref037 (SoC + real video pipeline, 4-port contention) equivalence: PASS"
else
   echo "ref037 (SoC + real video pipeline) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- Phase 5 gate: same 4-port contention run but executing FROM the SDRAM ROM
#     region - golden window exact AND the ROM self-loop stays FLAT (13 cycles)
#     for 64 display lines (any done-gate RPLY extension on a ROM fetch breaks it).
vvp -n "$SP/ref037socv.vvp" +romprog 2>/dev/null | reduce 101136 > "$SP/out_socv_rom.txt"

if diff -u golden_037_rom.txt "$SP/out_socv_rom.txt"; then
   echo "ref037 (SoC + video, ROM-in-SDRAM under 4-port contention) equivalence: PASS"
else
   echo "ref037 (SoC + video, ROM-in-SDRAM) equivalence: FAIL (see diff above)" >&2
   exit 1
fi

# --- Phase 5.5 soft reset under full video contention: the button pressed
#     MID-DISPLAY-LINE (ports 1/2/3 live), then the whole checked sequence -
#     golden window + 64 display lines with the flat-13 ROM loop invariant -
#     must repeat exactly. ---
vvp -n "$SP/ref037socv.vvp" +romprog +warmreset 2>/dev/null | reduce 101136 \
   > "$SP/out_socv_rom_warm.txt"

if cat golden_037_rom.txt golden_037_rom.txt | diff -u - "$SP/out_socv_rom_warm.txt"; then
   echo "ref037 (SoC + video, ROM warm-reset replay mid-display) equivalence: PASS"
else
   echo "ref037 (SoC + video, ROM warm-reset replay) equivalence: FAIL (see diff above)" >&2
   exit 1
fi
