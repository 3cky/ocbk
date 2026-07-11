// palette_apply - BK palette stage (Phase 4; BK-0011M palettes in Phase 7).
//
// Sits between the 037 video fetch and the framebuffer write, modelling the
// palette hardware that is EXTERNAL to the 037 chip. Decodes one fetched 16-bit
// video word into 16 canonical framebuffer slots. Since Phase 7 the canonical
// 4-bit FB index IS the BK-0011M physical colour nibble {R1, B, G, R0} (2-bit
// red, 1-bit blue/green - the machine's whole colour space is exactly 16
// colours; vga_out decodes the nibble combinationally, no CLUT):
//
//   mono-512   (screen_mode=1): bit s          -> slot s = 0 (black) / 15 (white);
//                               pal_idx ignored (as the real hardware)
//   colour-256 (screen_mode=0): bits [2k+1:2k] -> slots 2k,2k+1 =
//                               PALROM[pal_idx] nibble {p[0],p[1]} (a colour
//                               pixel is two mono-dots wide)
//
// PALROM is the 16-palette table from MiSTer BK0011M rtl/video.sv, VERBATIM -
// the reference for the 177662 register (BkEmu's handling is simplified).
// Note the nibble select is bit-SWAPPED ({p[0],p[1]}, not {p[1],p[0]}) exactly
// as MiSTer's `pal[{dotc[0],dotc[1],2'b00} +:4]`. Palette 0 = {0,4,2,9} =
// black/blue/green/red is the BK-0010 palette: a bk10 build ties pal_idx to 0
// (MiSTer def_reg662 bk10 semantics), so bk10 behaviour is palette-table-exact.
//
// Slot order is LSB-first in beam order: slot s lives at slots[4s+3:4s]; the FB
// write client packs slots 4w..4w+3 into FB word w. line_en=0 (row outside the
// M256 quarter window) forces index 0 - the 037 still fetches, the pixel is blank.
//
// screen_mode is the physical monitor/cable switch on a real BK-0010 (static
// config); pal_idx is 177662 bits 11:8 on a BK-0011M (beam-raced: it rides
// with each fetch, so a mid-frame write takes effect at the next fetched word).
module palette_apply (
    input  logic        screen_mode, // 1 = mono-512, 0 = colour-256
    input  logic        line_en,     // 0 = blanked row (M256 quarter mode)
    input  logic [3:0]  pal_idx,     // BK-0011M palette select (bk10: tie to 0)
    input  logic [15:0] word,        // fetched BK video word
    output logic [63:0] slots        // 16 x 4-bit colour nibbles, slot s = [4s+3:4s]
);

    // MiSTer rtl/video.sv palettes[16], packed palette 0 at [15:0]; each
    // palette = 4 nibbles of {R1, B, G, R0}, nibble n for pixel {p[0],p[1]}=n.
    localparam logic [255:0] PALROM = {
        16'hF620, 16'hFB20, 16'hF6B0, 16'h6920,   // 15 14 13 12
        16'h96B0, 16'h8AC0, 16'h1350, 16'hDC50,   // 11 10  9  8
        16'hBA30, 16'h9810, 16'hFFF0, 16'hFD60,   //  7  6  5  4
        16'hB260, 16'hD640, 16'h9BD0, 16'h9420    //  3  2  1  0
    };

    logic [15:0] pw;    // the selected palette's 4 colour nibbles

    always_comb begin
        pw = PALROM[16 * pal_idx +: 16];
        for (int s = 0; s < 16; s++)
            slots[4*s +: 4] =
                  !line_en    ? 4'd0
                : screen_mode ? (word[s] ? 4'd15 : 4'd0)
                : pw[4 * {word[2*(s/2)], word[2*(s/2)+1]} +: 4];
    end

endmodule
