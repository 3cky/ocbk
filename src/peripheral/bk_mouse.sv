// bk_mouse - a USB HID mouse presented as the BK's "Марсианка" (УВК-01) on 0177714.
//
// A real Марсианка is unobtainium and an MSX mouse on the DE-9 ports speaks a
// different protocol, so USB is the only way this board gets a BK mouse. The
// USB host (src/peripheral/usb_hid_host.v) does the enumeration; this module is
// the translator between its report fields and what Марсианка-aware software
// expects to see at 0177714.
//
// ============================ THE REFERENCE ================================
// SCHEMATIC-DERIVED (the УВК-01 sheets, `Устройство логическое УЛ УВК`), which
// beats GID's emulator - the only software implementation, and one its own
// documentation disavows ("Работает отвратительно"). The real device is:
//
//   4x АЛ107Б LED / ФД-265 photodiode pairs = two axes, two phases each. Each
//   phase goes through a К561ЛП2 XOR wired as a slicer (1.5M feedback = the
//   hysteresis) and clocks one half of a К561ТМ2 D flip-flop. Two flip-flops
//   per axis; their Q / /Q are buffered by a К561ПУ4 (six channels: four Q plus
//   two /Q - which is exactly what the pairing needs) and cross-combined by four
//   КМ133ЛА15 NANDs into the four direction lines.
//
//   Connector X (`Розетка ОНП-КГ-56-10`), from sheet 2's own table:
//     1 = "У"(вверх)   2 = "X"(вправо)   3 = "-У"(вниз)   4 = "X"(влево)
//     5 = КН1          6 = КН2           9 = СБРОС        10 = +5В   7,8 = Общ.
//
// THREE CONSEQUENCES, and the first two contradict GID:
//
//  1. THE READ IS ALWAYS LIVE. The NAND outputs sit on the connector
//     unconditionally - there is no output enable and nothing arms a read. GID's
//     "a rising edge of write bit 3 arms exactly one read" is an emulator
//     artifact, of the same family as its 10/40 ms decay timer (two different
//     constants at two call sites in one program). Neither is implemented here.
//
//  2. СБРОС IS A LEVEL, NOT AN EDGE. Pin 9 wires straight to the ТМ2 R inputs
//     with no gate in between, and S is grounded. So while it is asserted the
//     four direction latches are HELD cleared, and movement during that window
//     is simply lost - as on the real device, where encoder transitions that
//     arrive while R is high do nothing.
//
//  3. THE STICKY BITS ARE THE WHOLE MECHANISM. A latch means "this direction
//     moved at least once since СБРОС was released", nothing more - there is no
//     count and no magnitude anywhere in the device. Software therefore paces
//     the pointer itself: read the word, pulse СБРОС, read again. Distance comes
//     out as the number of polls that saw movement, which is why the encoder's
//     resolution is the thing that has to be modelled (see STEP below).
//
// POLARITY. The 0177714 output port is physically inverted - qbus_mem's
// `port_data` is the BK-true value the program wrote, and the pin is its
// complement (the same `~port_data` the Covox and TurboSound apply). СБРОС at
// the ТМ2 is active high, so the latches are held cleared while the program's
// bit 3 reads 0, and accumulate while it is 1. That makes the DEFAULT SAFE:
// `port_data` powers up at 0 and MONITOR's lone `CLR @#177714` writes 0, so a
// machine that never drives the mouse holds it in reset and reads no movement.
//
// WHICH write bit is СБРОС is a cable fact these two sheets do not carry; bit 3
// (0o010) is GID's, and it is the only evidence there is. It is a parameter so a
// board measurement can move it without touching the logic.
//
// READ WORD - the joystick layout, which is what the connector's pin order says
// and what BkEmu's JoystickManager already gives 0177714:
//
//   bit 0 = UP     bit 1 = RIGHT   bit 2 = DOWN   bit 3 = LEFT
//   bit 5 = КН1 (left button)      bit 6 = КН2 (right button)
//
// The buttons are plain switches on the real device, so they are levels and are
// NOT gated by СБРОС. They land on the same bits as a DE-9 pad's triggers, which
// is unavoidable - it is the same connector.
//
// STEP is the calibration knob, and it is the one real constant here. The sticky
// bits are binary, so pointer speed = poll rate x pixels-per-step and does not
// depend on how fast the mouse is moved - EXCEPT through how often a poll sees
// any movement at all, which is set by the encoder's resolution. A Марсианка is
// coarse (~100 dpi); a modern optical mouse reports 8-16x more counts for the
// same motion, so its deltas are divided down here. STEP = 8 HID counts per
// modelled encoder step is the starting point (STEP_SHIFT = 3); it wants a board
// measurement against real software. The sub-step remainder is kept, so slow
// motion is not lost, and
// the accumulator is deliberately NOT cleared by СБРОС - the encoder's position
// does not reset on the real device, only the latches do.
//
// DOMAINS. The USB core runs on usb_clk (12.08 MHz) and everything else here on
// `clk` = cpu_clk_n, the clock qbus_mem's read FSM and bk_joystick already use.
// The report payload crosses on a toggle + held-payload handshake, which is also
// the only safe way to read mouse_dx/dy at all: the wrapper zeroes them the
// cycle AFTER it raises `report`, so they must be captured ON the pulse (pinned
// by sim/usb's mouse leg, mutation U7).
module bk_mouse #(
    parameter int  STEP_SHIFT = 3,      // STEP = 1<<STEP_SHIFT HID counts per
                                        // modelled encoder step
    parameter int  RST_BIT    = 3       // the СБРОС bit in the 177714 write
)(
    // ---- USB report side (usb_clk domain) --------------------------------
    input  logic        usb_clk,
    input  logic        hid_report,     // 1 usb_clk pulse per HID report
    input  logic [7:0]  hid_btn,        // {.., middle, right, left}
    input  logic signed [7:0] hid_dx,   // +right, valid only AT hid_report
    input  logic signed [7:0] hid_dy,   // +down,  valid only AT hid_report
    input  logic [1:0]  hid_typ,        // usb_hid_host typ; 2 = mouse

    // ---- BK side (clk = cpu_clk_n) ---------------------------------------
    input  logic        clk,
    input  logic [15:0] port_data,      // qbus_mem's 177714 write latch, BK-true
                                        // (sys_clk; quasi-static, synced below)

    output logic [15:0] mouse_word,     // OR-ed into joy_word at the top level
    output logic        mouse_active    // a USB mouse is enumerated (clk domain)
);

    // ---- USB side: capture the report payload and toggle -------------------
    // dx/dy MUST be sampled on the pulse (see the header). The payload is then
    // held until the next report, so the clk side can read it whenever it
    // notices the toggle - no timing relationship to preserve.
    logic signed [7:0] pl_dx = '0, pl_dy = '0;
    logic [7:0]        pl_btn = '0;
    logic              pl_tog = 1'b0;
    always_ff @(posedge usb_clk) begin
        if (hid_report) begin
            pl_dx  <= hid_dx;
            pl_dy  <= hid_dy;
            pl_btn <= hid_btn;
            pl_tog <= ~pl_tog;
        end
    end

    // ---- clk side: 2-FF syncs ---------------------------------------------
    // hid_typ is DECODED BEFORE the synchroniser, not after: it is two bits and
    // 1 -> 2 flips both at once, so syncing the pair and comparing downstream
    // could decode a skewed 00 or 11 for a cycle. Syncing the single decoded bit
    // cannot go wrong, and costs two flops instead of four.
    wire        is_mouse = (hid_typ == 2'd2);
    logic [2:0] tog_sr = '0;            // toggle + edge detect
    logic [1:0] typ_sr = '0;
    logic [1:0] rst_sr = '0;            // port_data[RST_BIT], quasi-static
    always_ff @(posedge clk) begin
        tog_sr <= {tog_sr[1:0], pl_tog};
        typ_sr <= {typ_sr[0], is_mouse};
        rst_sr <= {rst_sr[0], port_data[RST_BIT]};
    end
    wire step_ev  = tog_sr[2] ^ tog_sr[1];      // one clk per HID report
    assign mouse_active = typ_sr[1];
    // The pin is the complement of the program's bit, and СБРОС is active high
    // at the ТМ2: latches held cleared while the program's bit 3 is 0.
    wire rst_lvl = ~rst_sr[1];

    // ---- the encoder model: divide the HID deltas down to steps ------------
    // ONLY THE SUB-STEP REMAINDER CARRIES, and that is the whole subtlety. A
    // report carrying dx=40 describes motion that ALREADY happened: a real
    // encoder emitted its ~5 transitions during it, and a binary latch cannot
    // tell five transitions from one. Carrying a multi-step backlog instead -
    // the first thing tried here - made one flick keep re-latching for the next
    // eight polls, which surfaced as a phantom DOWN on an X-only movement. So a
    // step is taken when the magnitude reaches STEP, and the accumulator keeps
    // only what is left below STEP.
    localparam int STEP = 1 << STEP_SHIFT;

    logic signed [9:0] acc_x = '0, acc_y = '0;   // holds |value| < STEP
    logic st_up = 1'b0, st_dn = 1'b0, st_lf = 1'b0, st_rt = 1'b0;
    logic [7:0] btn = '0;

    // Sign-extended through signed intermediates rather than a size cast:
    // Quartus II 11.0 does not take SystemVerilog's 16'(...) form, and a
    // concatenation-based extension would make the sum UNSIGNED and quietly
    // break every comparison below.
    wire signed [9:0] dxs = pl_dx;
    wire signed [9:0] dys = pl_dy;
    wire signed [9:0] nx  = acc_x + dxs;
    wire signed [9:0] ny  = acc_y + dys;

    wire [9:0] nx_mag = nx[9] ? (~nx + 10'd1) : nx;   // |nx|
    wire [9:0] ny_mag = ny[9] ? (~ny + 10'd1) : ny;
    wire       x_step = (nx_mag >= STEP);
    wire       y_step = (ny_mag >= STEP);
    wire [9:0] nx_rem = {{(10-STEP_SHIFT){1'b0}}, nx_mag[STEP_SHIFT-1:0]};
    wire [9:0] ny_rem = {{(10-STEP_SHIFT){1'b0}}, ny_mag[STEP_SHIFT-1:0]};
    wire signed [9:0] nx_next = x_step ? (nx[9] ? -nx_rem : nx_rem) : nx;
    wire signed [9:0] ny_next = y_step ? (ny[9] ? -ny_rem : ny_rem) : ny;

    always_ff @(posedge clk) begin
        if (step_ev) begin
            btn <= pl_btn;

            // X: +right, -left.
            // No ~rst_lvl term on the sets: the trailing level clear below is
            // a later assignment in the same block and therefore wins, which is
            // exactly the ТМ2's async R beating its clock. Gating here too would
            // be dead code implying the clear was conditional.
            if (x_step) begin
                if (!nx[9]) st_rt <= 1'b1;
                else        st_lf <= 1'b1;
            end
            acc_x <= nx_next;

            // Y: HID is +down, so +ny is ВНИЗ and -ny is ВВЕРХ.
            if (y_step) begin
                if (!ny[9]) st_dn <= 1'b1;
                else        st_up <= 1'b1;
            end
            acc_y <= ny_next;
        end

        // СБРОС is a level and wins over a same-cycle step, exactly as the ТМ2's
        // async R does: movement during the reset window is lost, not queued.
        if (rst_lvl) begin
            st_up <= 1'b0; st_dn <= 1'b0; st_lf <= 1'b0; st_rt <= 1'b0;
        end
    end

    // ---- the read word ----------------------------------------------------
    // Gated on a mouse actually being enumerated, so with no mouse (or a pad,
    // or nothing) this contributes 0 and the DE-9 joystick word is untouched.
    // Upper byte 0: there is one USB port, so this is always "player 1".
    always_comb begin
        mouse_word = 16'h0000;
        if (mouse_active) begin
            mouse_word[0] = st_up;
            mouse_word[1] = st_rt;
            mouse_word[2] = st_dn;
            mouse_word[3] = st_lf;
            mouse_word[5] = btn[0];     // КН1 = left button
            mouse_word[6] = btn[1];     // КН2 = right button
        end
    end

endmodule
