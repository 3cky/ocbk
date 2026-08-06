// bk_mouse - a USB HID mouse presented as the BK's "Marsianka" (UVK-01) on 0177714.
//
// The USB host (src/peripheral/usb_hid_host.v) does the enumeration; this module is
// the translator between its report fields and what Marsianka-aware software
// expects to see at 0177714.
//
// DOMAINS. The USB core runs on usb_clk (12.08 MHz) and everything else here on
// `clk` = cpu_clk_n, the clock qbus_mem's read FSM and bk_joystick already use.
// The report payload crosses on a toggle + held-payload handshake, which is also
// the only safe way to read mouse_dx/dy at all: the wrapper zeroes them the
// cycle after it raises `report`, so they must be captured on the pulse (pinned
// by sim/usb's mouse leg, mutation U7).
module bk_mouse #(
    parameter int  STEP_SHIFT = 3,      // STEP = 1<<STEP_SHIFT HID counts per
                                        // modelled encoder step
    parameter int  RST_BIT    = 3       // the reset bit in the 177714 write
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
    // dx/dy must be sampled on the pulse (see the header). The payload is then
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
    // hid_typ is decoded before the synchroniser, not after: it is two bits and
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
    // The pin is the complement of the program's bit, and reset is active high
    // at the trigger: latches held cleared while the program's bit 3 is 0.
    wire rst_lvl = ~rst_sr[1];

    // ---- the encoder model: divide the HID deltas down to steps ------------
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
            // exactly the trigger's async R beating its clock. Gating here too would
            // be dead code implying the clear was conditional.
            if (x_step) begin
                if (!nx[9]) st_rt <= 1'b1;
                else        st_lf <= 1'b1;
            end
            acc_x <= nx_next;

            // Y: HID is +down, so +ny is DOWN and -ny is UP.
            if (y_step) begin
                if (!ny[9]) st_dn <= 1'b1;
                else        st_up <= 1'b1;
            end
            acc_y <= ny_next;
        end

        // Reset is a level and wins over a same-cycle step, exactly as the trigger's
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
            mouse_word[5] = btn[0];     // left button
            mouse_word[6] = btn[1];     // right button
        end
    end

endmodule
