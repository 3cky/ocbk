#!/usr/bin/env python3
"""gen_expected.py - render the expected framebuffer for the video-pipe cosim.

Single source of truth for the cosim's video RAM pattern AND its expected
decoded framebuffer: emits

  video_ram.hex   8192 words  - preloaded into the behavioural SDRAM at the
                                BK video RAM (word address 0x2000, BK 040000)
  fb_exp.hex      32768 words - the framebuffer fb_video must produce from it
                                (layout: row*128 + w*4 + k, slot s of a word at
                                bits [4s+3:4s], LSB-first in beam order)

Conventions mirrored from the RTL (palette_apply.sv / fb_video.sv):
  mono-512: vram bit s -> slot s, index 0 (black) / 15 (white)
  scroll:   row r fetches vram line ((RA - 0o330 + r) & 0xFF), 32 words/line
            (convention proven against the 037 netlist in fb_video_tb)

Full-screen mono only (the mode/palette seams are covered by palette_tb and
fb_video_tb; the full chain adds nothing mode-specific).

The video RAM content is the exact picture the ROM test program draws
(mem/gen_mem.py render_image() - single source of truth), so the cosim
validates the shipped image end to end.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "mem"))
from gen_mem import render_image  # noqa: E402

RA = 0o330          # standard full-screen scroll base (177664 = 0o1330)
MODE_MONO = True


def render_fb(vram, ra):
    """BK fetch + palette -> 32768-word framebuffer (mono, full screen)."""
    fb = [0] * 32768
    for r in range(256):
        line = (ra - 0o330 + r) & 0xFF
        for w in range(32):
            word = vram[line * 32 + w]
            for s in range(16):
                idx = 15 if (word >> s) & 1 else 0
                slot = w * 16 + s
                fb[r * 128 + slot // 4] |= idx << (4 * (slot % 4))
    return fb


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    vram = render_image()
    fb = render_fb(vram, RA)

    with open(os.path.join(here, "video_ram.hex"), "w") as f:
        f.write("\n".join(f"{w:04x}" for w in vram) + "\n")
    with open(os.path.join(here, "fb_exp.hex"), "w") as f:
        f.write("\n".join(f"{w:04x}" for w in fb) + "\n")


if __name__ == "__main__":
    main()
