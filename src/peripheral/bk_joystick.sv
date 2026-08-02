// bk_joystick - the two MSX joystick ports as the BK's 0177714 read word.
//
// The board carries two MSX DE-9 general-purpose I/O ports; the BK reads its
// joystick from the 1801VM1's second register-select port, 0177714. This module
// is the level translator between the two - nothing more. It holds no state the
// CPU can see, decodes no address and never touches the bus: qbus_mem's io_word
// takes `joy_word` on its !sel2_n leg (0177714 already replies there, in both
// directions, via sel_io), so the whole attachment is one extra input to a mux
// that already existed.
//
// Pin encoding. MSX DE-9, ACTIVE LOW - a pad is a passive switch to GND and the
// released level comes from the pads' internal weak pull-ups (the .qsf sets
// WEAK_PULL_UP_RESISTOR on all twelve, exactly as esemsx3 does):
//
//   pad[0]=UP  pad[1]=DOWN  pad[2]=LEFT  pad[3]=RIGHT  pad[4]=TRG_A  pad[5]=TRG_B
//
// BK, ACTIVE HIGH:
//
//   bit 0=UP  1=RIGHT  2=DOWN  3=LEFT  4=START  5=A  6=B  7=SELECT
//
// The direction nibbles are NOT the same permutation - MSX is U,D,L,R and the BK
// is U,R,D,L. That one line is the whole error surface of this file, so the
// remap is written out per bit and the oracle walks every one of them.
//
// START (bit 4) and SELECT (bit 7) are tied 0: a DE-9 digital pad has no source
// for them.
//
// Joystick 2 = port B in the upper byte, same layout shifted by 8.
//
// Domain: the caller's clock, which is cpu_clk_n - the clock qbus_mem's read FSM
// and its rdata latch run on. Synchronising here rather than on sys_clk keeps
// the crossing out of qbus_mem entirely; it is the tape_in precedent in
// ocbk_top, and a joystick is far more quasi-static than tape.
//
module bk_joystick (
    input  logic        clk,        // cpu_clk_n (qbus_mem's read-FSM clock)

    input  logic [5:0]  pad_a_n,    // MSX port A, active low, DE-9 order above
    input  logic [5:0]  pad_b_n,    // MSX port B, same encoding

    output logic [15:0] joy_word    // BK-true 0177714 read word, active high:
);                                  //   [7:0] = port A, [15:8] = port B

    // ---- 2-FF metastability synchronisers ---------------------------------
    // Power-up value = the RELEASED pad level, so joy_word is 0 before the first
    // clock edge. That is both the pre-joystick behaviour of 0177714 (every
    // existing golden reads 0 there) and what an unplugged connector produces.
    logic [5:0] a_s0 = 6'b111111, a_s1 = 6'b111111;
    logic [5:0] b_s0 = 6'b111111, b_s1 = 6'b111111;

    always_ff @(posedge clk) begin
        a_s0 <= pad_a_n;  a_s1 <= a_s0;
        b_s0 <= pad_b_n;  b_s1 <= b_s0;
    end

    // ---- invert (MSX active low -> BK active high) ------------------------
    wire [5:0] a = ~a_s1;
    wire [5:0] b = ~b_s1;

    // ---- MSX DE-9 order -> BkEmu bit order --------------------------------
    // Written out rather than folded into a function: Quartus II 11.0's
    // SystemVerilog support is partial, and per-bit lines give the oracle's
    // mutation script clean anchors.
    //                        SELECT  B     A    START  LEFT  DOWN  RIGHT  UP
    assign joy_word[7:0]  = { 1'b0, a[5], a[4], 1'b0, a[2], a[1], a[3], a[0] };
    assign joy_word[15:8] = { 1'b0, b[5], b[4], 1'b0, b[2], b[1], b[3], b[0] };

endmodule
