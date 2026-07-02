// palette_apply - BK-0010 fixed palette stage (Phase 4).
//
// Sits between the 037 video fetch and the framebuffer write, modelling the
// palette hardware that is EXTERNAL to the 037 chip. Decodes one fetched 16-bit
// video word into 16 canonical framebuffer slots (4-bit post-palette physical
// colour index each, 512 slots/line in both modes):
//
//   mono-512   (screen_mode=1): bit s        -> slot s        = 0 (black) / 15 (white)
//   colour-256 (screen_mode=0): bits [2k+1:2k] -> slots 2k,2k+1 = index 0..3
//                               (a colour pixel is two mono-dots wide)
//
// Slot order is LSB-first in beam order: slot s lives at slots[4s+3:4s]; the FB
// write client packs slots 4w..4w+3 into FB word w. line_en=0 (row outside the
// M256 quarter window) forces index 0 - the 037 still fetches, the pixel is blank.
//
// screen_mode is the physical monitor/cable switch on a real BK-0010 (static
// config, not address-space state). This module is the seam where BK-0011M's
// programmable beam-raced palette drops in (Phase 7) - FB format, readout and
// arbiter are palette-independent.
module palette_apply (
    input  logic        screen_mode, // 1 = mono-512, 0 = colour-256
    input  logic        line_en,     // 0 = blanked row (M256 quarter mode)
    input  logic [15:0] word,        // fetched BK video word
    output logic [63:0] slots        // 16 x 4-bit colour indices, slot s = [4s+3:4s]
);

    always_comb
        for (int s = 0; s < 16; s++)
            slots[4*s +: 4] = !line_en    ? 4'd0
                            : screen_mode ? (word[s] ? 4'd15 : 4'd0)
                            : {2'b00, word[2*(s/2) +: 2]};

endmodule
