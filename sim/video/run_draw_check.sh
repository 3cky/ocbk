#!/usr/bin/env bash
#
# One-off (SLOW, ~10 min) gate for mem/gen_mem.py changes: runs the vm1 CPU on
# the full ROM program against behavioural RAM and proves the hand-assembled
# picture-draw code writes EXACTLY render_image() into video RAM. Not part of
# `make sim` - run it whenever the draw code or the picture definition changes.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# regenerate the ROM + the Python-rendered expected picture
( cd ../mem && python3 gen_mem.py ram_test.hex >/dev/null )
python3 - << 'EOF'
import sys, os
sys.path.insert(0, os.path.join("..", "mem"))
from gen_mem import render_image
with open(os.path.join("video", "img_exp.hex"), "w") as f:
    f.write("\n".join(f"{w:04x}" for w in render_image()) + "\n")
EOF

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

CPU=../src/cpu
iverilog -g2012 -o "$SP/draw.vvp" -s draw_check_tb \
   "$CPU/vm1_config.v" "$CPU/vm1.v" "$CPU/vm1_simlib.v" "$CPU/vm1_qbus.v" \
   "$CPU/vm1_plm.v" "$CPU/vm1_tve.v" \
   video/draw_check_tb.v 2>&1 | grep -v 'sorry:' || true

OUT="$(vvp -n "$SP/draw.vvp" 2>/dev/null)"
echo "$OUT"

if echo "$OUT" | grep -q '^COSIM PASS'; then
   echo "draw_check: PASS"
else
   echo "draw_check: FAIL (see above)" >&2
   exit 1
fi
