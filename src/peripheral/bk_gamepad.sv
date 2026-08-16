// bk_gamepad - a USB HID gamepad presented as the BK's 0177714 joystick word.
//
// The USB host (src/peripheral/usb_hid_host.v) does the enumeration and the
// report decode; this module is the level translator between its ten game_*
// outputs and the BK's joystick bit order - the same job bk_joystick does for
// the two MSX DE-9 ports, and it plugs into the same top-level OR seam.
//
// BK, active high (see bk_joystick.sv):
//
//   bit 0=UP  1=RIGHT  2=DOWN  3=LEFT  4=START  5=A  6=B  7=SELECT
//
// A pad has four face buttons plus two shoulder triggers and the BK has two
// fire buttons, so they fold: X and the RIGHT trigger join A, Y and the LEFT
// trigger join B. On a two-button machine everything a thumb lands on should
// fire. START and SELECT are mapped for real here - unlike a DE-9 pad, which
// has no source for them and leaves bits 4 and 7 tied 0.
//
// PLAYER 1, always. The board has one USB-A port, so there is only ever one USB
// pad and the upper byte stays 0 - the same argument as bk_mouse's read word.
// The top level ORs this with the DE-9 pads, so a USB pad and a DE-9 pad on
// port B give two players.
//
// DOMAINS. The USB core runs on usb_clk (12.08 MHz) and everything else here on
// `clk` = cpu_clk_n, the clock qbus_mem's read FSM and bk_joystick already use.
// The payload is LATCHED AT THE REPORT PULSE, like the mouse's - game_* are
// levels only BETWEEN reports; while one is arriving the wrapper rewrites them
// byte by byte, so sampling them freely reads half-decoded frames. That was half
// of the board bug of 2026-08-16; the other half was corrupted packets being
// trusted, fixed at the source by hook H7 (CRC16) in usb_hid_host.v.
//
// Once latched the payload is quasi-static (it moves at the ~10 ms poll rate),
// so a plain 2-FF sync per bit carries it across - no toggle handshake needed,
// unlike the mouse, whose deltas self-clear and must be accumulated. Bit skew
// across that crossing is accepted exactly as bk_joystick accepts it on twelve
// asynchronous DE-9 pins: a change can land either side of one cpu_clk_n edge,
// so one read in tens of thousands can tear, and the next is correct.
//
module bk_gamepad (
    // ---- USB report side (usb_clk domain) --------------------------------
    input  logic        usb_clk,
    input  logic        hid_report,     // 1 usb_clk pulse per HID report
    input  logic [1:0]  hid_typ,        // usb_hid_host typ; 3 = gamepad

    input  logic        g_u, g_d, g_l, g_r,             // directions
    input  logic        g_a, g_b, g_x, g_y,             // face buttons
    input  logic        g_tl, g_tr,                     // shoulder triggers
    input  logic        g_sel, g_sta,                   // SELECT, START

    // ---- BK side (clk = cpu_clk_n) ---------------------------------------
    input  logic        clk,

    output logic [15:0] pad_word,       // OR-ed into joy_word at the top level
    output logic        pad_active      // a USB pad is enumerated and has
);                                      // reported at least once (clk domain)

    // ---- USB side: the type gate and the arming flop ----------------------
    // hid_typ is decoded HERE, in the domain that drives it, and only the
    // decoded single bit ever crosses. Decoding after a synchroniser would be
    // wrong: typ is two bits, and 1 -> 3 or 2 -> 3 can be caught mid-change by
    // the clk domain, so a synced pair could compare equal to 3 for a cycle
    // while the device is neither. One already-decoded bit cannot skew against
    // itself. Same reasoning as bk_mouse's is_mouse.
    wire is_pad = (hid_typ == 2'd3);

    // ---- the remap: host game_* -> BkEmu bit order ------------------------
    // Written out as one concatenation with the bit names above it, the
    // bk_joystick idiom: the tb states the table as data and the RTL states it
    // once here, so the oracle's mutation script has clean per-bit anchors.
    //                SELECT         B                   A            START LEFT DOWN RIGHT UP
    wire [7:0] pl = { g_sel, (g_b | g_y | g_tl), (g_a | g_x | g_tr), g_sta, g_l, g_d, g_r, g_u };

    // ---- whole frames only ------------------------------------------------
    // THE PAYLOAD IS LATCHED AT THE REPORT PULSE, never sampled. game_* are not
    // stable levels while a report is arriving: the wrapper updates them byte by
    // byte as rcvct walks 0->7 (directions cleared and re-set at bytes 0/1/3/4,
    // face buttons at 5, START/SELECT at 6), spanning ~43 us - about 170
    // cpu_clk_n cycles.
    logic [7:0] pl_hold = 8'h00;    // the last CRC-valid frame's payload
    logic       armed   = 1'b0;

    always_ff @(posedge usb_clk) begin
        if (!is_pad) begin
            // The host clears typ on disconnect but NOT game_*, which hold the
            // last report's values indefinitely. Clearing here is what stops a
            // re-plugged pad presenting the previous session's buttons, and it
            // carries the type gate: pl_hold cannot be non-zero unless a pad is
            // enumerated and has reported.
            pl_hold <= 8'h00; armed <= 1'b0;
        end else if (hid_report) begin
            pl_hold <= pl;
            armed   <= 1'b1;
        end
    end

    // ---- clk side: 2-FF syncs ---------------------------------------------
    // pl_hold changes only at report boundaries (~10 ms apart) and is a settled
    // whole frame, so it is genuinely quasi-static and a plain 2-FF sync per bit
    // is correct - the bk_joystick treatment of twelve asynchronous DE-9 pins.
    // Bit skew across the crossing is accepted for the same reason it is there.
    //
    // Declaration-time initial values, no reset: pad_word is 0 before the first
    // clock edge, so this contributes nothing at power-on and adds no reset cone
    // - the bk_joystick precedent, and what lets every SoC testbench keep tying
    // joy_word off without an X propagating into rdata.
    logic [7:0] p_s0 = 8'h00, p_s1 = 8'h00;
    logic [1:0] act_sr = 2'b00;
    always_ff @(posedge clk) begin
        p_s0   <= pl_hold;
        p_s1   <= p_s0;
        act_sr <= {act_sr[0], armed};
    end

    assign pad_word    = {8'h00, p_s1};
    assign pad_active  = act_sr[1];

endmodule
