// usb_hid_host_tb - the device contract for src/peripheral/usb_hid_host.v.
//
// Drives the real core at its real rate (12.081 MHz = the usb_clk cpu_clkgen
// makes) against usb_ls_device, and checks what ocbk will actually consume: the
// device classification, the report strobe, and the decoded report fields.
//
// One leg per +leg=<name>; see run.sh. Prints "COSIM PASS" only if every check
// in the leg passed.
`timescale 1ns / 1ps

module usb_hid_host_tb;

    // 12.0810 MHz: 96.6477/8, the usb_clk rate. Period 82.7745 ns, so a
    // low-speed bit (8 usbclk) is 662.196 ns.
    localparam real CLK_NS = 82.7745;
    localparam real BIT_NS = 8.0 * CLK_NS;

    // scaled by default; run.sh overrides for the slow leg
`ifndef MS_TICKS
 `define MS_TICKS 61
`endif
    localparam integer MS_TICKS = `MS_TICKS;
    // Every wait budget below is in scaled microseconds: TSCALE is 1 for the
    // fast legs and ~197 for the slow leg at the real 12001-cycle tick, so the
    // same numbers work for both.
    localparam integer TSCALE = (MS_TICKS + 60) / 61;

    reg usbclk = 0, usbrst_n = 0;
    always #(CLK_NS/2.0) usbclk = ~usbclk;

    wire dp, dm;

    // ---- device side -----------------------------------------------------
    reg         plugged      = 0;
    reg  [7:0]  i_class      = 8'h03;
    reg  [7:0]  i_subclass   = 8'h01;
    reg  [7:0]  i_protocol   = 8'h01;
    reg  [63:0] report       = 64'h0;
    reg         report_valid = 0;
    reg  [7:0]  nak_setup    = 8'h00;

    wire [7:0] dev_addr, n_reset, n_setup, n_desc_in, n_report_in;
    wire [7:0] n_nak, n_crc_err, n_prot_err;
    wire       configured;

    usb_ls_device #(.BIT_NS(BIT_NS)) dev (
        .dp(dp), .dm(dm),
        .plugged(plugged),
        .i_class(i_class), .i_subclass(i_subclass), .i_protocol(i_protocol),
        .report(report), .report_valid(report_valid), .nak_setup(nak_setup),
        .dev_addr(dev_addr), .configured(configured),
        .n_reset(n_reset), .n_setup(n_setup), .n_desc_in(n_desc_in),
        .n_report_in(n_report_in), .n_nak(n_nak),
        .n_crc_err(n_crc_err), .n_prot_err(n_prot_err)
    );

    // ---- the DUT ---------------------------------------------------------
    wire [1:0] typ;
    wire       hid_report, conerr, dev_connected;
    wire [7:0] key_modifiers, key1, key2, key3, key4;
    wire [7:0] mouse_btn;
    wire signed [7:0] mouse_dx, mouse_dy;
    wire       game_l, game_r, game_u, game_d;
    wire       game_a, game_b, game_x, game_y, game_sel, game_sta;
    wire [63:0] dbg_hid_report;
    wire [55:0] dbg_regs;

    // MS_TICKS scaled (hook H6): the microcode's 200 ms attach wait plus its
    // 10 ms + 40 ms bus reset would otherwise cost ~250 ms of simulated time -
    // 3M clocks - per leg. 61 clocks per "ms" keeps every ratio in the script
    // intact (attach 200, reset 10, keep-alive 40, poll interval 9) while a leg
    // finishes in ~1.3 ms of sim time. run.sh's `slow` leg uses the real 12001.
    //
    // IT MUST BE ODD, which is why this is 61 and not 60. interval_cy is true
    // for one clock in MS_TICKS, but ukp evaluates an instruction only every
    // SECOND clock (the inst_ready toggle), so with an even MS_TICKS the two
    // phases lock and the `wait` instruction can sit through hundreds of ticks
    // without ever sampling the one cycle it needs - the attach wait then takes
    // 1000x longer than it should. Upstream's 12001 is odd for the same reason.
    usb_hid_host #(.MS_TICKS(MS_TICKS)) dut (
        .usbclk(usbclk), .usbrst_n(usbrst_n),
        .usb_dp(dp), .usb_dm(dm),
        .typ(typ), .report(hid_report), .conerr(conerr),
        .key_modifiers(key_modifiers),
        .key1(key1), .key2(key2), .key3(key3), .key4(key4),
        .mouse_btn(mouse_btn), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
        .game_l(game_l), .game_r(game_r), .game_u(game_u), .game_d(game_d),
        .game_a(game_a), .game_b(game_b), .game_x(game_x), .game_y(game_y),
        .game_sel(game_sel), .game_sta(game_sta),
        .dbg_hid_report(dbg_hid_report), .dbg_regs(dbg_regs),
        .dev_connected(dev_connected)
    );

    // The shipped default ROMFILE is project-root relative, for Quartus; this
    // leg runs from sim/usb, so point it at the same image from here. Overriding
    // it rather than copying the image is the point of the parameter.
    defparam dut.ukp.ukprom.ROMFILE = "../../mem/usb_hid_host_rom.hex";

    // ---- report-pulse capture (the pulse is one usbclk wide) --------------
    // THE DELTAS MUST BE SAMPLED ON THE PULSE. The wrapper zeroes mouse_dx/dy
    // the cycle AFTER it raises `report`, so anything that reads them later
    // always sees 0 - a consumer (the Марсианка adapter) has to accumulate them
    // at the strobe. Latching here is what lets the leg below check both halves:
    // the values at the pulse, and the self-clear right after it.
    integer n_pulses = 0;
    reg [7:0] lat_btn = 0, lat_mod = 0, lat_k1 = 0, lat_k2 = 0;
    reg signed [7:0] lat_dx = 0, lat_dy = 0;
    always @(posedge usbclk) if (hid_report) begin
        n_pulses = n_pulses + 1;
        lat_btn <= mouse_btn; lat_dx <= mouse_dx; lat_dy <= mouse_dy;
        lat_mod <= key_modifiers; lat_k1 <= key1; lat_k2 <= key2;
    end

    // ---- checking ---------------------------------------------------------
    integer errors = 0;
    task ck(input cond, input [8*48-1:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL %0s   (t=%0t)", what, $time);
            end
        end
    endtask
    task ck_eq(input [63:0] got, input [63:0] exp, input [8*48-1:0] what);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("  FAIL %0s: got %0h expected %0h  (t=%0t)",
                         what, got, exp, $time);
            end
        end
    endtask

    // Waits for enumeration to finish: the host toggles its connect flag after
    // SET_CONFIGURATION's status stage, and the classification lands with the
    // third descriptor read.
    task wait_enum(input integer limit_us);
        integer i;
        begin
            i = 0;
            while (!(dev_connected && configured) && i < limit_us) begin
                #1000; i = i + 1;
            end
        end
    endtask

    // Waits for n interrupt reports to be delivered to the wrapper.
    task wait_reports(input integer n, input integer limit_us);
        integer i, target;
        begin
            target = n_pulses + n; i = 0;
            while (n_pulses < target && i < limit_us) begin #1000; i = i + 1; end
        end
    endtask

    reg [8*16-1:0] leg;

    initial begin
        if (!$value$plusargs("leg=%s", leg)) leg = "kbd";
        if ($test$plusargs("vcd")) begin
            $dumpfile("usb.vcd"); $dumpvars(0, usb_hid_host_tb);
        end

        // power-on: the port is empty, both lines pulled down = SE0
        repeat (10) @(posedge usbclk);
        usbrst_n = 1;
        repeat (10) @(posedge usbclk);
        ck(typ === 2'd0,        "empty port: typ = 0");
        ck(dev_connected === 1'b0, "empty port: not connected");

        case (leg)
        // ==================================================================
        "kbd": begin
            $display("=== leg kbd: a boot keyboard enumerates and reports ===");
            i_class = 3; i_subclass = 1; i_protocol = 1;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck(dev_connected === 1'b1, "connected");
            ck(configured    === 1'b1, "device configured");
            ck_eq(dev_addr, 8'h01,     "device address set to 1");
            ck_eq(typ, 2'd1,           "typ = 1 (keyboard)");
            ck_eq(n_reset,   8'd2,     "two bus resets");
            ck_eq(n_desc_in, 8'd3,     "three descriptor reads");
            ck_eq(n_crc_err, 8'd0,     "host CRC5/CRC16 all valid");
            ck_eq(n_prot_err,8'd0,     "no protocol errors");
            ck_eq(dbg_regs[39:32], 8'd3, "regs[4] = bInterfaceClass");
            ck_eq(dbg_regs[47:40], 8'd1, "regs[5] = bInterfaceSubClass");
            ck_eq(dbg_regs[55:48], 8'd1, "regs[6] = bInterfaceProtocol");

            // A: modifier = LeftShift (0x02), keys 0x04 'a' and 0x05 'b'
            report = {8'h00, 8'h00, 8'h00, 8'h00,
                      8'h05, 8'h04, 8'h00, 8'h02};
            report_valid = 1;
            wait_reports(1, 2000*TSCALE);
            ck(n_pulses > 0, "a report pulse arrived");
            ck_eq(key_modifiers, 8'h02, "key_modifiers = LeftShift");
            ck_eq(key1, 8'h04, "key1 = 0x04");
            ck_eq(key2, 8'h05, "key2 = 0x05");
            ck_eq(lat_mod, 8'h02, "modifiers already valid at the pulse");
            ck_eq(lat_k1,  8'h04, "key1 already valid at the pulse");
            ck_eq(key3, 8'h00, "key3 = 0");
            ck_eq(key4, 8'h00, "key4 = 0");
            ck_eq(dbg_hid_report, report, "dbg_hid_report = the 8 bytes sent");

            // B: all released - the fields must follow, not latch
            report = 64'h0;
            wait_reports(2, 2000*TSCALE);
            ck_eq(key1, 8'h00, "key1 released");
            ck_eq(key_modifiers, 8'h00, "modifiers released");
            ck(typ === 2'd1, "typ still 1 while attached");
        end
        // ==================================================================
        "mouse": begin
            $display("=== leg mouse: a boot mouse enumerates and reports ===");
            i_class = 3; i_subclass = 1; i_protocol = 2;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck(dev_connected === 1'b1, "connected");
            ck_eq(typ, 2'd2, "typ = 2 (mouse)");
            ck_eq(n_crc_err, 8'd0, "host CRC5/CRC16 all valid");

            // buttons = left|right, dx = +5, dy = -3
            report = {8'h00, 8'h00, 8'h00, 8'h00,
                      8'h00, 8'hfd, 8'h05, 8'h03};
            report_valid = 1;
            wait_reports(1, 2000*TSCALE);
            ck_eq(lat_btn, 8'h03, "mouse_btn = left|right at the pulse");
            ck_eq({{56{lat_dx[7]}}, lat_dx},  64'sd5, "mouse_dx = +5 at the pulse");
            ck_eq({{56{lat_dy[7]}}, lat_dy}, -64'sd3, "mouse_dy = -3 at the pulse");
            // and they self-clear, or motion would integrate for ever
            ck_eq(mouse_dx, 8'h00, "mouse_dx cleared after the pulse");
            ck_eq(mouse_dy, 8'h00, "mouse_dy cleared after the pulse");
            ck_eq(mouse_btn, 8'h03, "mouse_btn is a level, NOT cleared");
        end
        // ==================================================================
        "pad": begin
            // Kept even though a low-speed pad has not been found on hardware
            // (the Sony pad measured is full speed and invisible to this core):
            // the typ=3 branch and the button decode are part of the vendored
            // contract, and the model presents its own descriptors.
            $display("=== leg pad: a non-boot HID device is a gamepad ===");
            i_class = 3; i_subclass = 0; i_protocol = 0;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck(dev_connected === 1'b1, "connected");
            ck_eq(typ, 2'd3, "typ = 3 (gamepad)");
            ck_eq(n_crc_err, 8'd0, "host CRC5/CRC16 all valid");

            // The layout the wrapper assumes: d[3]/d[4] axes (0x00 = min,
            // 0xff = max), d[5][7:4] = YBAX, d[6][5:4] = START,SELECT.
            report = {8'h00, 8'h30, 8'hf0, 8'hff,
                      8'h00, 8'h80, 8'h80, 8'h00};
            report_valid = 1;
            wait_reports(2, 3000*TSCALE);
            ck(game_l === 1'b1, "d[3]=0x00 -> LEFT");
            ck(game_r === 1'b0, "not RIGHT");
            ck(game_d === 1'b1, "d[4]=0xff -> DOWN");
            ck(game_u === 1'b0, "not UP");
            ck(game_x === 1'b1, "d[5][4] -> X");
            ck(game_a === 1'b1, "d[5][5] -> A");
            ck(game_b === 1'b1, "d[5][6] -> B");
            ck(game_y === 1'b1, "d[5][7] -> Y");
            ck(game_sel === 1'b1, "d[6][4] -> SELECT");
            ck(game_sta === 1'b1, "d[6][5] -> START");
        end
        // ==================================================================
        "nak": begin
            $display("=== leg nak: NAKs are retried, not mistaken for data ===");
            i_class = 3; i_subclass = 1; i_protocol = 1;
            nak_setup = 3;              // every descriptor IN gets 3 NAKs first
            plugged = 1;
            wait_enum(6000*TSCALE);
            ck(dev_connected === 1'b1, "connected despite NAKs");
            ck_eq(typ, 2'd1, "typ = 1 - the class survived the retries");
            ck(n_nak >= 8'd9, "at least 9 NAKs were sent");
            ck_eq(n_desc_in, 8'd3, "still exactly three descriptor reads");
            ck_eq(n_prot_err, 8'd0, "no protocol errors");

            // a NAK on the interrupt endpoint must not fake a report
            report_valid = 0;
            n_pulses = 0;
            #(2_000_000*TSCALE);               // 2 ms - many poll intervals
            ck_eq(n_pulses, 0, "no report pulse while NAKing");
            ck(n_nak > 8'd9, "the interrupt INs were NAKed too");
        end
        // ==================================================================
        "unplug": begin
            $display("=== leg unplug: detach clears typ, replug re-enumerates ===");
            i_class = 3; i_subclass = 1; i_protocol = 2;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck_eq(typ, 2'd2, "mouse enumerated");

            plugged = 0;                // SE0 - the device is gone
            begin : wait_gone
                integer i;
                for (i = 0; i < 500*TSCALE; i = i + 1) begin
                    #1000;
                    if (typ === 2'd0 && dev_connected === 1'b0)
                        disable wait_gone;
                end
            end
            ck_eq(typ, 2'd0, "typ cleared on detach");
            ck(dev_connected === 1'b0, "not connected on detach");

            i_class = 3; i_subclass = 1; i_protocol = 1;   // a keyboard this time
            plugged = 1;
            wait_enum(6000*TSCALE);
            ck(dev_connected === 1'b1, "re-enumerated after replug");
            ck_eq(typ, 2'd1, "the new device's class was picked up");
            ck_eq(n_prot_err, 8'd0, "no protocol errors across the replug");
        end
        default: begin
            $display("unknown leg %0s", leg);
            errors = errors + 1;
        end
        endcase

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #(60_000_000*TSCALE);
        $display("COSIM FAIL (timeout)");
        $finish;
    end
endmodule
