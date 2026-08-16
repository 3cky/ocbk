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

    // DEVICE BIT-RATE SKEW, in ppm. Low-speed USB allows the device +/-1.5%
    // (15000 ppm) and our own clock is +0.674% off nominal besides, so a real
    // device is NEVER exactly 8 usbclk per bit - the host resynchronises on
    // every D- transition precisely because of that. Nothing here exercised it
    // until the second board bug (hook H8): the byte strobe was derived from a
    // `timing` comparison, and a resync landing in the wrong place inside a bit
    // fired it TWICE, duplicating a byte while leaving the bit stream perfect.
    // At zero skew the resync never falls there and the defect is invisible,
    // which is why every leg passed on a broken host.
`ifndef DEV_SKEW_PPM
 `define DEV_SKEW_PPM 0
`endif
    localparam real DEV_BIT_NS = BIT_NS * (1.0 + (`DEV_SKEW_PPM) / 1000000.0);

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
    reg  [63:0] report_rp    = 64'h0;   // what the device sends BEFORE it is put
                                        // into boot protocol (see the setproto
                                        // leg); ignored while it is 0
    reg         report_valid = 0;
    reg  [7:0]  nak_setup    = 8'h00;
    reg         stall_proto  = 0;
    reg [3:0] corrupt_byte = 0;   // 0 = off; else the payload byte to damage

    wire [7:0] dev_addr, n_reset, n_setup, n_set_proto, n_desc_in, n_report_in;
    wire [7:0] n_nak, n_stall, n_crc_err, n_prot_err;
    wire       configured, boot_proto;

    // The device's report layout follows its protocol state, exactly as a real
    // one does: report protocol until SET_PROTOCOL(boot) lands, boot layout
    // after. report_rp = 0 means "this leg does not care", i.e. boot layout all
    // along - which is how a mouse whose descriptor happens to match behaves.
    wire [63:0] dev_report = (boot_proto || report_rp == 0) ? report : report_rp;

    usb_ls_device #(.BIT_NS(BIT_NS), .TX_BIT_NS(DEV_BIT_NS)) dev (
        .dp(dp), .dm(dm),
        .plugged(plugged),
        .i_class(i_class), .i_subclass(i_subclass), .i_protocol(i_protocol),
        .report(dev_report), .report_valid(report_valid), .nak_setup(nak_setup),
        .stall_proto(stall_proto), .corrupt_byte(corrupt_byte),
        .dev_addr(dev_addr), .configured(configured), .boot_proto(boot_proto),
        .n_reset(n_reset), .n_setup(n_setup), .n_set_proto(n_set_proto),
        .n_desc_in(n_desc_in),
        .n_report_in(n_report_in), .n_nak(n_nak), .n_stall(n_stall),
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
    wire       game_tl, game_tr;
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
        .game_tl(game_tl), .game_tr(game_tr),
        .dbg_hid_report(dbg_hid_report), .dbg_regs(dbg_regs),
        .dev_connected(dev_connected)
    );

    // The shipped default ROMFILE is project-root relative, for Quartus; this
    // leg runs from sim/usb, so point it at the same image from here. Overriding
    // it rather than copying the image is the point of the parameter.
    defparam dut.ukp.ukprom.ROMFILE = "../../mem/usb_hid_host_rom.hex";

    wire [11:0] game_bits = {game_tr, game_tl, game_sta, game_sel, game_y,
                             game_x, game_b, game_a, game_r, game_d,
                             game_l, game_u};

    // ---- report-pulse capture (the pulse is one usbclk wide) --------------
    // THE DELTAS MUST BE SAMPLED ON THE PULSE. The wrapper zeroes mouse_dx/dy
    // the cycle AFTER it raises `report`, so anything that reads them later
    // always sees 0 - a consumer (the Марсианка adapter) has to accumulate them
    // at the strobe. Latching here is what lets the leg below check both halves:
    // the values at the pulse, and the self-clear right after it.
    integer n_pulses = 0;
    reg [7:0] lat_btn = 0, lat_mod = 0, lat_k1 = 0, lat_k2 = 0;
    reg signed [7:0] lat_dx = 0, lat_dy = 0;
    reg [11:0] lat_game = 0;     // the game bits AS A CONSUMER SEES THEM, i.e.
                                // sampled at the pulse - what bk_gamepad does
    reg [63:0] lat_report = 0;  // the eight bytes of THAT frame, likewise - a
                                // later clean frame must not be able to hide
                                // damage done to an earlier one
    always @(posedge usbclk) if (hid_report) begin
        n_pulses = n_pulses + 1;
        lat_btn <= mouse_btn; lat_dx <= mouse_dx; lat_dy <= mouse_dy;
        lat_mod <= key_modifiers; lat_k1 <= key1; lat_k2 <= key2;
        lat_game <= game_bits;
        lat_report <= dbg_hid_report;
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

    // ---- gamepad frames, in wire order ------------------------------------
    // usbhid-dump prints byte 0 first; dbg_hid_report packs dat[7] first. This
    // task takes the bytes the way the capture prints them, so a leg below can
    // be read off against the pasted dump line by line, and then waits for the
    // frame to be decoded.
    task pad_frame(input [7:0] b0, input [7:0] b1, input [7:0] b2,
                   input [7:0] b3, input [7:0] b4, input [7:0] b5,
                   input [7:0] b6, input [7:0] b7);
        begin
            report = {b7, b6, b5, b4, b3, b2, b1, b0};
            wait_reports(2, 3000*TSCALE);
        end
    endtask


    localparam [11:0] P_NONE = 12'b000000000000;
    localparam [11:0] P_U    = 12'b000000000001;
    localparam [11:0] P_L    = 12'b000000000010;
    localparam [11:0] P_D    = 12'b000000000100;
    localparam [11:0] P_R    = 12'b000000001000;
    localparam [11:0] P_A    = 12'b000000010000;
    localparam [11:0] P_B    = 12'b000000100000;
    localparam [11:0] P_X    = 12'b000001000000;
    localparam [11:0] P_Y    = 12'b000010000000;
    localparam [11:0] P_SEL  = 12'b000100000000;
    localparam [11:0] P_STA  = 12'b001000000000;
    localparam [11:0] P_TL   = 12'b010000000000;   // hook H9: shoulder triggers
    localparam [11:0] P_TR   = 12'b100000000000;

    // Checks ALL ten outputs at once, so a frame cannot assert the bit it is
    // named for while quietly also asserting three others.
    task ck_pad(input [8*48-1:0] what, input [11:0] exp);
        begin
            if (game_bits !== exp) begin
                errors = errors + 1;
                $display("  FAIL %0s: got %b expected %b  (t=%0t)",
                         what, game_bits, exp, $time);
            end
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
            ck_eq(n_set_proto, 8'd1, "SET_PROTOCOL issued exactly once");
            ck(boot_proto === 1'b1,   "the device is in boot protocol");

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
            // A non-boot interface STALLs SET_PROTOCOL - it is a boot-device
            // request. The host sends it unconditionally (the microcode cannot
            // branch on the saved class triple), so this leg is also where the
            // gamepad path proves it survives the STALL; `stallproto` asserts
            // the survival directly.
            stall_proto = 1;
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
        "pad_real": begin
            // THE REFERENCE PAD, FROM A REAL CAPTURE. Every frame below is a
            // verbatim `usbhid-dump -d 081f:e401 -es` line taken from the pad
            // that motivated bk_gamepad (a "USB gamepad", low speed, HID class 3
            // / subclass 0 / protocol 0, 8-byte interrupt IN, bInterval 10).
            //
            // The `pad` leg above drives the layout the vendored wrapper's
            // comment DESCRIBES. This one drives what a device actually sent, so
            // the guess table stops being a guess. Three properties of this pad
            // are what make the stock decode work unmodified, and each is a
            // trap if a future pad differs:
            //
            //   * byte 0 rests at 0x7f and swings to 0x00/0xff, so the wrapper's
            //     `valid <= (ukpdat[1:0] != 2'b10)` gate is never tripped. A pad
            //     resting at 0x7e or 0x82 would have its WHOLE report discarded.
            //   * the D-pad is on the axes, not the hat: byte 5's low nibble is
            //     a constant 0x0f. The wrapper has no hat decode at all.
            //   * bytes 3 and 4 are constant 0x80, and 0x80[7:6] is 2'b10 - the
            //     one value that fires NEITHER of the wrapper's threshold
            //     branches. At 0x00 they would force a permanent LEFT+UP.
            $display("=== leg pad_real: captured 081f:e401 frames ===");
            i_class = 3; i_subclass = 0; i_protocol = 0;
            stall_proto = 1;            // a non-boot interface STALLs it
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck(dev_connected === 1'b1, "connected");
            ck_eq(typ, 2'd3, "typ = 3 (gamepad)");
            ck_eq(n_crc_err, 8'd0, "host CRC5/CRC16 all valid");
            ck_eq(dbg_regs[39:32], 8'd3, "regs[4] = bInterfaceClass 3");
            ck_eq(dbg_regs[47:40], 8'd0, "regs[5] = bInterfaceSubClass 0");
            ck_eq(dbg_regs[55:48], 8'd0, "regs[6] = bInterfaceProtocol 0");

            //                b0    b1    b2    b3    b4    b5    b6    b7
            report_valid = 1;
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("idle: nothing asserted", P_NONE);
            ck_eq(dbg_hid_report, 64'h00000f8080007f7f,
                  "the eight captured bytes arrive intact");

            pad_frame(8'h7f, 8'h00, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("UP", P_U);
            pad_frame(8'h7f, 8'hff, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("DOWN", P_D);
            pad_frame(8'h00, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("LEFT", P_L);
            pad_frame(8'hff, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("RIGHT", P_R);

            // Back to centre between the axes and the buttons: the directions
            // are latched by the wrapper and only byte 0's clear releases them,
            // so a release that does not work would show up as a stuck bit in
            // every remaining frame.
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("released back to centre", P_NONE);

            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h10, 8'h00);
            ck_pad("SELECT", P_SEL);
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h20, 8'h00);
            ck_pad("START", P_STA);
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h1f, 8'h00, 8'h00);
            ck_pad("X", P_X);
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h8f, 8'h00, 8'h00);
            ck_pad("Y", P_Y);
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h2f, 8'h00, 8'h00);
            ck_pad("A", P_A);
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h4f, 8'h00, 8'h00);
            ck_pad("B", P_B);

            // The shoulder triggers, captured the same way. They sit in byte 6's
            // LOW bits, which upstream ignored entirely - it reads only [5:4].
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h01, 8'h00);
            ck_pad("L trigger", P_TL);
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h02, 8'h00);
            ck_pad("R trigger", P_TR);
            // ...and they must not disturb START/SELECT, which share the byte.
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h33, 8'h00);
            ck_pad("START+SELECT+both triggers together",
                   P_STA | P_SEL | P_TL | P_TR);

            // Not captured but reachable: the pad can press a direction and a
            // button at once, and the two decode paths must not interfere.
            pad_frame(8'h00, 8'h00, 8'h00, 8'h80, 8'h80, 8'h2f, 8'h20, 8'h00);
            ck_pad("up-left + A + START", P_U | P_L | P_A | P_STA);

            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_pad("everything released again", P_NONE);

            // ck_pad reads the LEVEL outputs, which the wrapper writes as bytes
            // arrive - so on its own it cannot tell a healthy link from one
            // delivering no reports at all. Assert the pulses too, or a CRC
            // check with a bad window or constant would reject every frame here
            // and still look fine (it did: mutations U19-U22 survived until
            // this line existed).
            ck(n_pulses >= 10, "report pulses actually fired for these frames");
            ck_eq({52'd0, lat_game}, {52'd0, P_NONE},
                  "and the consumer view tracked the last frame");
        end
        // ==================================================================
        "stuffdup": begin
            // THE REGRESSION LEG FOR HOOK H8 - a BIT-STUFF landing exactly on
            // the byte strobe.
            //
            // Upstream fired the strobe on (bitadr[2:0]==3'b100) & (timing==2),
            // guarded by ~nrzon. But nrzon is only set at the bit's SAMPLE
            // (timing==4), while a stuff bit FREEZES bitadr - so during a stuff
            // bit at that position the strobe condition is true again while
            // nrzon still reads 0 from the previous real bit. The wrapper takes
            // the same ukpdat twice, rcvct advances twice, and every later byte
            // lands one slot late: a DUPLICATED BYTE from a perfectly valid bit
            // stream. CRC16 (hook H7) cannot see it, which is why it survived.
            //
            // This payload is chosen, not arbitrary: its stuffing puts a stuff
            // bit at bitadr 52, i.e. >= 28 (past ukprdy) and == 4 mod 8 (on the
            // strobe), which duplicates byte 3. The assertion is the strongest
            // available - the raw eight bytes must come back exactly as sent.
            $display("=== leg stuffdup: a stuff bit on the byte strobe ===");
            i_class = 3; i_subclass = 0; i_protocol = 0;
            stall_proto = 1;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck_eq(typ, 2'd3, "typ = 3 (gamepad)");

            report_valid = 1;
            pad_frame(8'hCF, 8'h21, 8'h84, 8'hC7, 8'h8F, 8'h34, 8'h6D, 8'hF3);
            ck_eq(dbg_hid_report, 64'hF36D348FC78421CF,
                  "the eight bytes arrive UNDUPLICATED");
            ck(n_pulses > 0, "and the frame was actually delivered");

            // The pad's own idle frame must still be exact afterwards, so the
            // fix cannot have shifted the ordinary case.
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h0f, 8'h00, 8'h00);
            ck_eq(dbg_hid_report, 64'h00000f8080007f7f,
                  "and an ordinary frame is still exact");
        end
        // ==================================================================
        "dupstrobe": begin
            // THE REGRESSION LEG FOR HOOK H8 - fault injection, not a model.
            //
            // The board shows a frame arriving with a byte DUPLICATED at index
            // 3 or 4: every later byte lands one slot late. It was confirmed
            // with a sticky LED signature (byte 6 goes non-zero, which only a
            // one-byte-late shift reaches; byte 2 stayed clean and there was no
            // re-enumeration). Three candidate mechanisms for the extra strobe
            // were tested here and ALL THREE are ruled out - packet corruption
            // (the `crc` leg), a stuff bit on the strobe (`stuffdup`), and the
            // device at the edge of its bit-rate tolerance (`skew`).
            //
            // So this leg does not reproduce a cause. It injects the EFFECT
            // directly - one spurious extra byte strobe - and demands the frame
            // arrive intact anyway. That is the property hook H8 provides:
            // bytes are addressed by POSITION (from bitadr, which is
            // authoritative) instead of by counting strobes, so a duplicate
            // writes the same slot twice and a lost one is re-written by the
            // next. Counting cannot survive either.
            $display("=== leg dupstrobe: an extra byte strobe must not shift the frame ===");
            i_class = 3; i_subclass = 0; i_protocol = 0;
            stall_proto = 1;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck_eq(typ, 2'd3, "typ = 3 (gamepad)");

            report = 64'h00000f8080007f7f;      // the pad's real idle frame
            report_valid = 1;

            // Inject inside the payload: wait for the data window to open, run
            // a few byte times in, then hold the strobe high for exactly one
            // usbclk - one extra rising edge for the wrapper's edge detector.
            @(posedge dut.data_rdy);
            #(20*BIT_NS);
            @(negedge usbclk);
            force dut.data_strobe = 1'b1;
            @(negedge usbclk);
            release dut.data_strobe;

            // Check THE INJECTED FRAME, not a later one: wait for exactly the
            // pulse that ends it and read the latched copy. (Waiting for two
            // and reading dbg_hid_report live was the first version of this
            // leg, and it PASSED on a knowingly-broken build - the next clean
            // frame had already overwritten the damage.)
            wait_reports(1, 3000*TSCALE);
            ck_eq(lat_report, 64'h00000f8080007f7f,
                  "frame exact despite a DOUBLE byte strobe");
            ck_eq({52'd0, lat_game}, {52'd0, P_NONE},
                  "and it decodes as idle, not as a phantom button");

            // ...and a second, clean frame still works afterwards.
            pad_frame(8'h7f, 8'h7f, 8'h00, 8'h80, 8'h80, 8'h2f, 8'h00, 8'h00);
            ck_pad("a later clean frame is unaffected", P_A);
        end
        // ==================================================================
        "setproto": begin
            // THE REGRESSION LEG FOR THE HARDWARE BUG (microcode hook F1).
            // Three mice were tried on the board and two misbehaved, because
            // the host left them in report protocol and the wrapper decodes
            // boot-protocol offsets. This device sends the layout that produced
            // the worst of the three (0000:3825): a Report ID byte in front, so
            // byte 0 reads as a permanently pressed КН1 and both axes are gone.
            $display("=== leg setproto: report protocol is switched to boot ===");
            i_class = 3; i_subclass = 1; i_protocol = 2;
            // report protocol: [ID=1, buttons=middle, X=+7, Y=-7, 0...]
            report_rp = {8'h00, 8'h00, 8'h00, 8'h00,
                         8'hf9, 8'h07, 8'h04, 8'h01};
            // boot protocol: [buttons=middle, X=+7, Y=-7] - the same motion,
            // one byte earlier
            report    = {8'h00, 8'h00, 8'h00, 8'h00,
                         8'h00, 8'hf9, 8'h07, 8'h04};
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck_eq(typ, 2'd2, "typ = 2 (mouse)");
            ck_eq(n_set_proto, 8'd1, "SET_PROTOCOL issued exactly once");
            ck_eq(n_crc_err, 8'd0, "including its CRC5 and CRC16");
            ck(boot_proto === 1'b1, "the device switched to boot protocol");

            report_valid = 1;
            wait_reports(1, 2000*TSCALE);
            // The whole point: these are the BOOT values. On the pre-F1
            // microcode the device stays in report protocol and the wrapper
            // reads btn=0x01 (the ID), dx=0x04 (the button byte) and dy=+7 (X) -
            // the stuck button and the swapped axis seen on the board.
            ck_eq(lat_btn, 8'h04, "mouse_btn = middle, NOT the report ID");
            ck_eq({{56{lat_dx[7]}}, lat_dx},  64'sd7, "mouse_dx = +7");
            ck_eq({{56{lat_dy[7]}}, lat_dy}, -64'sd7, "mouse_dy = -7");
            ck_eq(dbg_hid_report[7:0], 8'h04,
                  "report byte 0 is the button byte, not an ID");
        end
        // ==================================================================
        "stallproto": begin
            // A device that does not support SET_PROTOCOL must not take the
            // host down with it. ukp's `nak` flag is set by ANY handshake PID -
            // it samples the first PID bit, which is 0 for ACK/NAK/STALL and 1
            // for DATA0/DATA1 - so a STALL is indistinguishable from a NAK and
            // an unbounded `bnak` retry on the status stage would spin until the
            // 1.4 s watchdog reset pc, re-enumerating for ever. n_reset staying
            // at 2 is what proves that did not happen.
            $display("=== leg stallproto: a STALLed SET_PROTOCOL is survived ===");
            i_class = 3; i_subclass = 1; i_protocol = 2;
            stall_proto = 1;
            plugged = 1;
            wait_enum(4000*TSCALE);
            ck(dev_connected === 1'b1, "connected despite the STALL");
            ck_eq(typ, 2'd2, "typ = 2 (mouse)");
            ck(n_stall >= 8'd1, "the device did STALL SET_PROTOCOL");
            ck(boot_proto === 1'b0, "and stayed in report protocol");

            report = {8'h00, 8'h00, 8'h00, 8'h00,
                      8'h00, 8'h02, 8'h01, 8'h01};
            report_valid = 1;
            wait_reports(2, 3000*TSCALE);
            ck(n_pulses >= 2, "reports still arrive");
            ck_eq(lat_btn, 8'h01, "and still decode");
            ck_eq(n_reset, 8'd2, "no watchdog re-enumeration (still 2 resets)");
            ck_eq(n_prot_err, 8'd0, "no protocol errors");
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
