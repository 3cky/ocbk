// bk_mouse_tb - the device contract for src/peripheral/bk_mouse.sv, the USB
// mouse presented as the BK's Марсианка (УВК-01) on 0177714.
//
// Device only. The BUS side is not this leg's job and saying so out loud is the
// sim/covox and sim/joystick precedent: mouse_word is OR-ed into joy_word at the
// TOP LEVEL, so qbus_mem is untouched by this feature and "the word reaches a
// 0177714 read" stays pinned where it already was - spk_capture_tb section 10
// against the real qbus_mem, and the !sel2_n gate in sim/smk section 2.
//
// One leg per +leg=<name>; see run.sh. Prints "COSIM PASS" only if every check
// in the leg passed.
`timescale 1ns / 1ps

module bk_mouse_tb;

    localparam real USB_NS = 82.7745;   // 12.081 MHz usb_clk
    localparam real CPU_NS = 331.0;     // ~3.02 MHz cpu_clk_n (BK-0010 rate)
    localparam int  STEP   = 8;         // must match the DUT's default

    reg usb_clk = 0, clk = 0;
    always #(USB_NS/2.0) usb_clk = ~usb_clk;
    always #(CPU_NS/2.0) clk     = ~clk;

    reg        hid_report = 0;
    reg  [7:0] hid_btn = 0;
    reg signed [7:0] hid_dx = 0, hid_dy = 0;
    reg  [1:0] hid_typ = 2'd2;          // a mouse, unless a leg says otherwise
    reg [15:0] port_data = 16'h0000;    // powers up 0 = СБРОС asserted

    wire [15:0] mouse_word;
    wire        mouse_active;

    bk_mouse dut (
        .usb_clk(usb_clk), .hid_report(hid_report),
        .hid_btn(hid_btn), .hid_dx(hid_dx), .hid_dy(hid_dy), .hid_typ(hid_typ),
        .clk(clk), .port_data(port_data),
        .mouse_word(mouse_word), .mouse_active(mouse_active)
    );

    // BK bit names, so the checks read like the connector's own table
    localparam UP = 0, RT = 1, DN = 2, LF = 3, KN1 = 5, KN2 = 6;

    integer errors = 0;
    task ck(input cond, input [8*56-1:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL %0s   (word=%06o t=%0t)", what, mouse_word, $time);
            end
        end
    endtask

    // One HID report. dx/dy are cleared the moment the pulse ends, exactly as
    // usb_hid_host's wrapper does - so a DUT that sampled them late would read
    // zero and every movement check here would fail. That re-pins sim/usb's U7
    // contract at this level.
    task report(input signed [7:0] dx, input signed [7:0] dy, input [7:0] btn);
        begin
            @(negedge usb_clk);
            hid_dx = dx; hid_dy = dy; hid_btn = btn; hid_report = 1;
            @(negedge usb_clk);
            hid_report = 0; hid_dx = 0; hid_dy = 0;
            repeat (8) @(posedge clk);          // let the CDC land
        end
    endtask

    // СБРОС. port_data is the BK-TRUE value the program wrote and the port
    // inverts, so bit 3 = 0 asserts the reset and 1 releases it.
    task set_rst(input v);                      // v = 1 -> reset ASSERTED
        begin
            port_data[3] = ~v;
            repeat (4) @(posedge clk);
        end
    endtask

    task release_rst; begin set_rst(0); end endtask
    task assert_rst;  begin set_rst(1); end endtask

    reg [8*16-1:0] leg;

    initial begin
        if (!$value$plusargs("leg=%s", leg)) leg = "sticky";
        repeat (4) @(posedge clk);

        // Power-on: port_data = 0 = СБРОС asserted, so nothing reads back even
        // though a mouse is enumerated. This is the property that keeps the
        // feature invisible to a machine that never drives the mouse.
        ck(mouse_word == 16'h0000, "power-on: held in reset, word 0");
        report(40, 40, 8'h00);
        ck(mouse_word == 16'h0000, "movement during reset is LOST, not queued");

        case (leg)
        // ==================================================================
        "sticky": begin
            $display("=== leg sticky: each direction latches and holds ===");
            release_rst();
            // RIGHT, and it must STAY set across further reportless polls
            report(2*STEP, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "dx>0 -> RIGHT");
            ck(mouse_word[LF] === 1'b0, "and not LEFT");
            report(0, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "RIGHT is STICKY across a still report");
            // LEFT joins it - both can be set at once, the latches are independent
            report(-2*STEP, 0, 8'h00);
            ck(mouse_word[LF] === 1'b1, "dx<0 -> LEFT");
            ck(mouse_word[RT] === 1'b1, "RIGHT still latched");
            // DOWN: HID +y is toward the user = ВНИЗ
            assert_rst(); release_rst();
            report(0, 2*STEP, 8'h00);
            ck(mouse_word[DN] === 1'b1, "dy>0 -> DOWN (HID +y is down)");
            ck(mouse_word[UP] === 1'b0, "and not UP");
            // UP
            assert_rst(); release_rst();
            report(0, -2*STEP, 8'h00);
            ck(mouse_word[UP] === 1'b1, "dy<0 -> UP");
            ck(mouse_word[DN] === 1'b0, "and not DOWN");
            // the unused bits stay clear - 4 (START) and 7 (SELECT) have no source
            ck(mouse_word[4] === 1'b0 && mouse_word[7] === 1'b0,
               "bits 4 and 7 have no source");
            ck(mouse_word[15:8] == 8'h00, "upper byte 0: one port, player 1 only");
        end
        // ==================================================================
        "reset": begin
            $display("=== leg reset: СБРОС is a LEVEL, and its polarity ===");
            release_rst();
            report(2*STEP, 2*STEP, 8'h00);
            ck(mouse_word[RT] === 1'b1 && mouse_word[DN] === 1'b1, "moved");
            // asserting clears, and KEEPS clearing while held
            assert_rst();
            ck(mouse_word[3:0] == 4'b0000, "asserting СБРОС clears the nibble");
            report(2*STEP, 2*STEP, 8'h00);
            ck(mouse_word[3:0] == 4'b0000, "and HOLDS it cleared while asserted");
            report(2*STEP, 2*STEP, 8'h00);
            ck(mouse_word[3:0] == 4'b0000, "still held - a level, not an edge");
            // releasing lets it accumulate again
            release_rst();
            ck(mouse_word[3:0] == 4'b0000, "release alone latches nothing");
            report(2*STEP, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "and movement after release latches");
            // POLARITY: the program writing bit 3 = 0 is what clears. Writing
            // the whole word 0 (MONITOR's CLR @#177714) must clear.
            port_data = 16'h0000;
            repeat (4) @(posedge clk);
            ck(mouse_word[3:0] == 4'b0000, "CLR @#177714 asserts СБРОС");
            port_data = 16'o000010;
            repeat (4) @(posedge clk);
            report(0, -2*STEP, 8'h00);
            ck(mouse_word[UP] === 1'b1, "writing 0o010 releases it");
        end
        // ==================================================================
        "step": begin
            $display("=== leg step: the encoder-resolution divider ===");
            release_rst();
            // sub-step motion must NOT latch: a real encoder produces no
            // transition until the mouse has moved far enough
            report(STEP-1, 0, 8'h00);
            ck(mouse_word[RT] === 1'b0, "a sub-STEP delta latches nothing");
            // but the remainder is KEPT, so two half-steps make a step
            report(1, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "the remainder is kept: 7+1 = one step");
            // the same in the negative direction
            assert_rst(); release_rst();
            report(-(STEP-1), 0, 8'h00);
            ck(mouse_word[LF] === 1'b0, "sub-STEP negative latches nothing");
            report(-1, 0, 8'h00);
            ck(mouse_word[LF] === 1'b1, "and completes to one step");
            // a big swipe latches, and the clamp stops it leaving a long tail:
            // after the reset, a few still reports must not keep re-latching
            assert_rst(); release_rst();
            report(127, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "a swipe latches");
            assert_rst(); release_rst();
            report(0, 0, 8'h00);
            ck(mouse_word[RT] === 1'b0,
               "NO BACKLOG: a swipe leaves no phantom step on the next poll");
            report(0, 0, 8'h00);
            ck(mouse_word == 16'h0000, "and none on the one after");
            // the cross-axis case that caught the backlog bug: X-only motion
            // must never latch a Y direction, however large the delta was
            assert_rst(); release_rst();
            report(100, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "a large X delta latches RIGHT");
            ck(mouse_word[DN] === 1'b0 && mouse_word[UP] === 1'b0,
               "and latches NEITHER Y direction");
        end
        // ==================================================================
        "buttons": begin
            $display("=== leg buttons: levels on 5 and 6, not reset-gated ===");
            release_rst();
            report(0, 0, 8'b0000_0001);
            ck(mouse_word[KN1] === 1'b1, "HID left -> КН1 (bit 5)");
            ck(mouse_word[KN2] === 1'b0, "and not КН2");
            report(0, 0, 8'b0000_0010);
            ck(mouse_word[KN2] === 1'b1, "HID right -> КН2 (bit 6)");
            ck(mouse_word[KN1] === 1'b0, "left released - a LEVEL, not sticky");
            report(0, 0, 8'b0000_0011);
            ck(mouse_word[KN1] === 1'b1 && mouse_word[KN2] === 1'b1, "both");
            // buttons are plain switches on the real device: СБРОС does not
            // touch them
            assert_rst();
            ck(mouse_word[KN1] === 1'b1 && mouse_word[KN2] === 1'b1,
               "СБРОС does NOT clear the buttons");
            // and a report ARRIVING while СБРОС is asserted must still carry
            // them through - the switches are not in the reset's path at all
            report(0, 0, 8'b0000_0011);
            ck(mouse_word[KN1] === 1'b1 && mouse_word[KN2] === 1'b1,
               "a report during СБРОС still delivers the buttons");
            ck(mouse_word[3:0] == 4'b0000, "while the directions stay cleared");
            report(0, 0, 8'h00);
            ck(mouse_word[KN1] === 1'b0 && mouse_word[KN2] === 1'b0, "released");
        end
        // ==================================================================
        "gate": begin
            $display("=== leg gate: only an enumerated MOUSE contributes ===");
            release_rst();
            // a gamepad on the port must leave 0177714 to the DE-9 pads
            hid_typ = 2'd3;
            repeat (4) @(posedge clk);
            ck(mouse_active === 1'b0, "typ=3 (gamepad): not active");
            report(2*STEP, 2*STEP, 8'b0000_0011);
            ck(mouse_word == 16'h0000, "typ=3 contributes NOTHING");
            // nothing attached
            hid_typ = 2'd0;
            repeat (4) @(posedge clk);
            report(2*STEP, 2*STEP, 8'b0000_0011);
            ck(mouse_word == 16'h0000, "typ=0 contributes nothing");
            // a keyboard
            hid_typ = 2'd1;
            repeat (4) @(posedge clk);
            ck(mouse_word == 16'h0000, "typ=1 contributes nothing");
            // and a mouse does
            hid_typ = 2'd2;
            repeat (4) @(posedge clk);
            ck(mouse_active === 1'b1, "typ=2: active");
            report(2*STEP, 0, 8'h00);
            ck(mouse_word[RT] === 1'b1, "typ=2 contributes");
        end
        default: begin
            $display("unknown leg %0s", leg); errors = errors + 1;
        end
        endcase

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("COSIM FAIL (timeout)");
        $finish;
    end
endmodule
