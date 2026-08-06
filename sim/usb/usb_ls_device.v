// usb_ls_device - a behavioural USB 1.1 LOW-SPEED HID device, the protocol peer
// for src/peripheral/usb_hid_host.v.
//
// Models the wire, not a chip: line states, NRZI, bit stuffing, CRC5/CRC16, the
// SETUP/IN/DATA/handshake sequence, and the descriptor set the host's microcode
// actually asks for. It answers exactly the fixed script in the vendored
// microcode (upstream src/firmware/ukp.s), which is the whole contract:
//
//   attach (pull-up on D-) -> 200 ms -> bus reset -> SETUP+DATA0
//   GET_DESCRIPTOR(configuration, wLength 24) -> three IN(0,0)+ACK pairs that
//   drain 24 bytes -> bus reset -> SET_ADDRESS(1) -> SET_CONFIGURATION(1) ->
//   SET_PROTOCOL(boot) -> IN(1,1) interrupt polls
//
// SET_PROTOCOL is microcode hook F1, not upstream: without it a device stays in
// report protocol and sends whatever its report descriptor declares, which for
// most mice is not the 3-byte layout the wrapper decodes. The model therefore
// tracks it (boot_proto, so a caller can change its report layout on it) and can
// STALL it (stall_proto), which is what a non-boot device does.
//
// LOW-SPEED POLARITY, the easy thing to get backwards: for low speed J (idle) is
// D- HIGH / D+ low and K is D+ HIGH / D- low - the inverse of full speed. The
// attach signal is the device's 1.5k pull-up on D-, which is exactly why a
// full-speed device (pull-up on D+) is invisible to this host.
//
// DELIBERATE SIMPLIFICATIONS, so the README does not have to guess at them:
//
//  - Bit timing is a parameter locked to the DUT's actual rate (8 usbclk), not
//    recovered by a modelled device PLL, and there is no modelled clock
//    tolerance. This oracle tests the HOST; a device's clock recovery is not the
//    thing under test, and giving the model its own drifting clock would only
//    test Icarus.
//  - The bit-stuff counter runs continuously from the SYNC field on both sides,
//    matching the host's nrztxct/nrzrxct rather than resetting after SYNC. What
//    matters is that the two agree.
//  - No line-error injection (bad CRC, babble, SE1). The host verifies no CRC at
//    all, so such legs would assert nothing.
//  - One endpoint, one configuration, no string descriptors - the host never asks.
//
// WHAT THE CRC CHECKING IS FOR. The host never computes or verifies a CRC: every
// token and DATA0 it sends is a literal byte string with a pre-computed CRC in
// the microcode ROM, and it ignores our CRC16 entirely (it reads a fixed 8
// payload bytes and stops). So checking the host's CRC5/CRC16 here is not
// protocol pedantry - it is an end-to-end check that the vendored ROM image is
// intact and addressed correctly, which nothing else in the tree can see.
`timescale 1ns / 1ps

module usb_ls_device #(
    parameter real BIT_NS = 662.196     // 8 usbclk at 12.081 MHz
)(
    inout  wire        dp,
    inout  wire        dm,

    input  wire        plugged,         // 1 = attached (asserts the D- pull-up)
    input  wire [7:0]  i_class,         // bInterfaceClass    (3 = HID)
    input  wire [7:0]  i_subclass,      // bInterfaceSubClass (1 = boot)
    input  wire [7:0]  i_protocol,      // bInterfaceProtocol (1 = kbd, 2 = mouse)

    input  wire [63:0] report,          // the 8 report bytes, byte 0 in [7:0]
    input  wire        report_valid,    // 0 = NAK the interrupt IN
    input  wire [7:0]  nak_setup,       // NAK each descriptor IN this many times
    input  wire        stall_proto,     // 1 = STALL SET_PROTOCOL's status stage,
                                        //     i.e. a device that does not
                                        //     support the request

    output reg  [7:0]  dev_addr,        // current device address
    output reg         configured,      // SET_CONFIGURATION seen
    output reg         boot_proto,      // SET_PROTOCOL(0) accepted - the caller
                                        //   switches its report layout on this
    output reg  [7:0]  n_reset,         // bus resets seen
    output reg  [7:0]  n_setup,         // SETUP tokens seen
    output reg  [7:0]  n_set_proto,     // SET_PROTOCOL requests received
    output reg  [7:0]  n_desc_in,       // descriptor IN(0,0) reads answered
    output reg  [7:0]  n_report_in,     // interrupt IN(1,1) reads answered
    output reg  [7:0]  n_nak,           // NAKs we sent
    output reg  [7:0]  n_stall,         // STALLs we sent
    output reg  [7:0]  n_crc_err,       // host packets with a bad CRC5/CRC16
    output reg  [7:0]  n_prot_err       // anything we could not parse
);

    // ---- PIDs, in the byte form the host's microcode uses (LSB sent first) ---
    localparam [7:0] PID_SETUP = 8'h2d, PID_IN    = 8'h69,
                     PID_DATA0 = 8'hc3, PID_DATA1 = 8'h4b,
                     PID_ACK   = 8'hd2, PID_NAK   = 8'h5a,
                     PID_STALL = 8'h1e;

    // ---- line drive ------------------------------------------------------
    // Three states, so SE0 is expressible: 0 = SE0, 1 = J (D- high), 2 = K.
    // Idle is the weak-strength pair below - the board's 10k pull-downs plus the
    // device's 1.5k pull-up on D- - so the host driving strongly always wins and
    // a contention shows up as X instead of being silently absorbed.
    localparam ST_SE0 = 2'd0, ST_J = 2'd1, ST_K = 2'd2;
    reg [1:0] tx_st = ST_J;
    reg       tx_oe = 1'b0;

    assign dp = tx_oe ? (tx_st == ST_K) : 1'bz;
    assign dm = tx_oe ? (tx_st == ST_J) : 1'bz;
    assign (weak1, weak0) dm = tx_oe ? 1'bz : (plugged ? 1'b1 : 1'b0);
    assign (weak1, weak0) dp = tx_oe ? 1'bz : 1'b0;

    wire se0 = (dp === 1'b0) && (dm === 1'b0);

    // ---- CRC helpers (USB: over the field LSB-first, result complemented) ----
    function [4:0] crc5_11;
        input [10:0] d;
        integer i; reg [4:0] c; reg fb;
        begin
            c = 5'b11111;
            for (i = 0; i < 11; i = i + 1) begin
                fb = d[i] ^ c[4];
                c  = {c[3:0], 1'b0};
                if (fb) c = c ^ 5'b00101;
            end
            crc5_11 = rev5(~c);
        end
    endfunction

    // The CRC is sent MSB-first, so the wire value is the bit-reverse of the
    // register. Verified against every literal in the host's ROM: the three
    // token CRC5s (addr0/ep0, addr1/ep0, addr1/ep1) and all four DATA0 CRC16s.
    function [4:0] rev5;
        input [4:0] v;
        begin rev5 = {v[0], v[1], v[2], v[3], v[4]}; end
    endfunction

    function [15:0] rev16;
        input [15:0] v;
        integer i; reg [15:0] r;
        begin
            for (i = 0; i < 16; i = i + 1) r[i] = v[15-i];
            rev16 = r;
        end
    endfunction

    function [15:0] crc16_bytes;
        input [63:0] d;                 // up to 8 bytes, byte 0 in [7:0]
        input integer n;
        integer i, b; reg [15:0] c; reg fb, bit_i;
        begin
            c = 16'hffff;
            for (b = 0; b < n; b = b + 1)
                for (i = 0; i < 8; i = i + 1) begin
                    bit_i = d[b*8 + i];
                    fb = bit_i ^ c[15];
                    c  = {c[14:0], 1'b0};
                    if (fb) c = c ^ 16'h8005;
                end
            crc16_bytes = rev16(~c);
        end
    endfunction

    // ======================================================================
    //  Transmit
    // ======================================================================
    integer tx_ones = 0;

    task tx_bit(input b);
        begin
            if (b) tx_ones = tx_ones + 1;
            else begin
                tx_st   = (tx_st == ST_J) ? ST_K : ST_J;   // NRZI: 0 = transition
                tx_ones = 0;
            end
            #(BIT_NS);
            if (tx_ones == 6) begin                        // stuff a 0 after six 1s
                tx_st   = (tx_st == ST_J) ? ST_K : ST_J;
                tx_ones = 0;
                #(BIT_NS);
            end
        end
    endtask

    task tx_byte(input [7:0] v);
        integer i;
        begin for (i = 0; i < 8; i = i + 1) tx_bit(v[i]); end
    endtask

    task tx_eop;
        begin
            tx_st = ST_SE0; #(2*BIT_NS);    // SE0 for two bit times
            tx_st = ST_J;   #(BIT_NS);      // then one bit time of J
            tx_oe = 1'b0;
        end
    endtask

    // SYNC is 0x80 through the ordinary byte path: LSB-first that is
    // 0,0,0,0,0,0,0,1 = seven transitions then hold = KJKJKJKK, and it leaves
    // the stuff counter at 1, exactly as the host's own `outb 0x80` does.
    // TURNAROUND, and it is load-bearing. rx_packet returns as soon as it sees
    // the SE0 that OPENS the host's EOP, so at that moment the host still has
    // two bit times of SE0 plus one of J to drive, and then several instructions
    // (hiz, jmp rcvdt, ldi, start) before it is actually watching the line. Two
    // bit times - the first thing tried - put our SYNC on top of the host's own
    // EOP: it reached `start` about four bits into the pattern, sampled from
    // there and shifted every captured byte. Six bit times from the SE0 is three
    // bit times after the EOP ends, still far inside the low-speed response
    // window, and the alignment locks.
    task tx_packet_start;
        begin
            #(6*BIT_NS);                    // turnaround - see the note above
            tx_oe = 1'b1; tx_st = ST_J; tx_ones = 0;
            tx_byte(8'h80);
        end
    endtask

    task tx_handshake(input [7:0] pid);
        begin tx_packet_start(); tx_byte(pid); tx_eop(); end
    endtask

    task tx_data(input [7:0] pid, input [63:0] payload, input integer n);
        reg [15:0] c;
        integer i;
        begin
            c = crc16_bytes(payload, n);
            tx_packet_start();
            tx_byte(pid);
            for (i = 0; i < n; i = i + 1) tx_byte(payload[i*8 +: 8]);
            tx_byte(c[7:0]); tx_byte(c[15:8]);
            tx_eop();
        end
    endtask

    // ======================================================================
    //  Receive - lock to the first K of SYNC, then step one bit time
    // ======================================================================
    reg [7:0] rx[0:15];
    integer   rx_n;
    reg       rx_ok;

    task rx_packet;
        integer bits, ones, byten, bitn;
        reg     prev_j, cur_j, b;
        begin
            rx_n = 0; rx_ok = 1'b0; byten = 0; bitn = 0; ones = 0; bits = 0;
            @(posedge dp);                  // K: start of SYNC (EOP has no K,
            #(BIT_NS/2.0);                  // so keep-alives are ignored)
            prev_j = 1'b1;                  // the line was idle J
            while (!se0 && bits < 200) begin
                cur_j  = (dm === 1'b1);
                b      = (cur_j == prev_j); // NRZI: no transition = 1
                prev_j = cur_j;
                if (ones == 6) begin
                    ones = 0;               // stuffed bit: drop it
                end else begin
                    ones = b ? ones + 1 : 0;
                    if (bits >= 8) begin    // bits 0..7 are SYNC
                        rx[byten][bitn] = b;
                        bitn = bitn + 1;
                        if (bitn == 8) begin bitn = 0; byten = byten + 1; end
                    end
                    bits = bits + 1;
                end
                #(BIT_NS);
            end
            rx_n  = byten;
            rx_ok = (bits >= 16);           // at least SYNC + PID
            if (!rx_ok) n_prot_err = n_prot_err + 1;
        end
    endtask

    // ======================================================================
    //  Bus reset: SE0 far longer than an EOP's two bit times (1.3 us)
    // ======================================================================
    real se0_at = -1.0;
    always @(dp or dm) begin
        if (se0) begin
            if (se0_at < 0.0) se0_at = $realtime;
        end else begin
            if (se0_at >= 0.0 && ($realtime - se0_at) > 10.0*BIT_NS) begin
                dev_addr   = 8'h00;
                configured = 1'b0;
                boot_proto = 1'b0;      // a bus reset returns a HID device to
                                        // report protocol (HID 1.11 7.2.6)
                n_reset    = n_reset + 1;
            end
            se0_at = -1.0;
        end
    end

    // ======================================================================
    //  The control / interrupt script
    // ======================================================================
    reg [7:0] setup_type, setup_req, setup_val, desc_idx, nak_left;
    reg [7:0] tok_addr, tok_ep;
    reg       data1_next;

    // SET_PROTOCOL is a class request to an interface, so it is bmRequestType
    // 0x21 / bRequest 0x0b - the type byte matters because bRequest numbering
    // is per-type and 0x0b is GET_INTERFACE among the standard requests.
    // A reg set in the same blocking sequence as setup_type/setup_req, not a
    // continuous assign: the SETUP handler tests it in the delta it decodes
    // them, where an `assign` would still hold the previous request's value.
    reg is_set_proto;

    // The 24 bytes the host asks for: a 9-byte configuration descriptor, a
    // 9-byte interface descriptor carrying the class triple, and the head of a
    // HID descriptor. Byte 14 = bInterfaceClass, 15 = SubClass, 16 = Protocol -
    // exactly where the microcode's `save 4 6` / `save 5 7` / `save 6 0` reach
    // after three 8-byte reads. Byte 0 of each chunk is in [7:0].
    function [63:0] cfg_chunk;
        input [7:0] idx;
        begin
            case (idx)
            // bytes 0-7:  bLength=9 type=2 wTotalLength=0x22 nIf=1 cfgVal=1
            //             iCfg=0 bmAttributes=0xa0
            8'd0: cfg_chunk = {8'ha0, 8'h00, 8'h01, 8'h01,
                               8'h00, 8'h22, 8'h02, 8'h09};
            // bytes 8-15: bMaxPower=0x32 | bLength=9 type=4 ifNum=0 alt=0
            //             nEp=1 CLASS SUBCLASS
            8'd1: cfg_chunk = {i_subclass, i_class, 8'h01, 8'h00,
                               8'h00, 8'h04, 8'h09, 8'h32};
            // bytes 16-23: PROTOCOL iInterface=0 | HID desc head
            default: cfg_chunk = {8'h01, 8'h00, 8'h01, 8'h11,
                                  8'h21, 8'h09, 8'h00, i_protocol};
            endcase
        end
    endfunction

    initial begin
        dev_addr = 0; configured = 0; boot_proto = 0;
        n_reset = 0; n_setup = 0; n_set_proto = 0; n_desc_in = 0;
        n_report_in = 0; n_nak = 0; n_stall = 0; n_crc_err = 0; n_prot_err = 0;
        setup_type = 0; is_set_proto = 0; setup_req = 0; setup_val = 0; desc_idx = 0; nak_left = 0;
        tok_addr = 0; tok_ep = 0; data1_next = 0;
        forever begin
            rx_packet();
            if (rx_ok) case (rx[0])
                // ---- tokens: PID, addr/ep, CRC5 ---------------------------
                PID_SETUP, PID_IN: begin
                    tok_addr = {1'b0, rx[1][6:0]};
                    tok_ep   = {4'b0, rx[2][2:0], rx[1][7]};
                    if (crc5_11({rx[2][2:0], rx[1]}) !== rx[2][7:3])
                        n_crc_err = n_crc_err + 1;
                    if (rx[0] == PID_SETUP) begin
                        n_setup = n_setup + 1;
                    end else if (tok_addr == dev_addr) begin
                        if (tok_ep == 1) begin                  // interrupt IN
                            if (report_valid) begin
                                n_report_in = n_report_in + 1;
                                tx_data(data1_next ? PID_DATA1 : PID_DATA0,
                                        report, 8);
                                data1_next = ~data1_next;
                            end else begin
                                n_nak = n_nak + 1;
                                tx_handshake(PID_NAK);
                            end
                        end else if (setup_req == 8'h06) begin  // GET_DESCRIPTOR
                            if (nak_left != 0) begin
                                nak_left = nak_left - 1;
                                n_nak    = n_nak + 1;
                                tx_handshake(PID_NAK);
                            end else begin
                                n_desc_in = n_desc_in + 1;
                                tx_data(desc_idx[0] ? PID_DATA1 : PID_DATA0,
                                        cfg_chunk(desc_idx), 8);
                                desc_idx = desc_idx + 1;
                                nak_left = nak_setup;
                            end
                        end else if (is_set_proto && stall_proto) begin
                            // A device that does not support SET_PROTOCOL.
                            // The host must survive this and go on polling: its
                            // `nak` flag cannot tell STALL from NAK (both are
                            // handshake PIDs), so an unbounded bnak retry here
                            // would spin until the watchdog reset it.
                            n_stall = n_stall + 1;
                            tx_handshake(PID_STALL);
                        end else begin
                            // status stage of SET_ADDRESS / SET_CONFIGURATION /
                            // SET_PROTOCOL: a zero-length DATA1
                            tx_data(PID_DATA1, 64'h0, 0);
                            if (setup_req == 8'h05) dev_addr   = setup_val;
                            if (setup_req == 8'h09) configured = 1'b1;
                            if (is_set_proto)       boot_proto = (setup_val == 0);
                        end
                    end
                end
                // ---- the SETUP's 8-byte request ---------------------------
                PID_DATA0, PID_DATA1: begin
                    if (rx_n >= 11) begin
                        if (crc16_bytes({rx[8], rx[7], rx[6], rx[5],
                                         rx[4], rx[3], rx[2], rx[1]}, 8)
                            !== {rx[10], rx[9]})
                            n_crc_err = n_crc_err + 1;
                        setup_type   = rx[1];
                        setup_req    = rx[2];
                        setup_val    = rx[3];
                        is_set_proto = (setup_type == 8'h21) &&
                                       (setup_req  == 8'h0b);
                        if (setup_req == 8'h06) begin
                            desc_idx = 0; nak_left = nak_setup;
                        end
                        if (is_set_proto) n_set_proto = n_set_proto + 1;
                        tx_handshake(PID_ACK);
                    end else n_prot_err = n_prot_err + 1;
                end
                PID_ACK: ;                  // the host acknowledging our data
                default: n_prot_err = n_prot_err + 1;
            endcase
        end
    end
endmodule
