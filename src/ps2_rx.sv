// ps2_rx - minimal receive-only PS/2 front end (Phase 6 keyboard).
//
// Runs entirely on cpu_clk (~3.02 MHz): the PS/2 clock is 10-16 kHz, so a
// 2-FF synchronizer plus falling-edge detection oversamples it ~100x - no
// extra clock domain. Frames are the standard 11 bits (start 0, 8 data
// LSB-first, odd parity, stop 1); a frame failing the start/parity/stop
// checks is dropped silently, and a ~340 us dead-man timer abandons a
// half-received frame (cable glitch) so the receiver can never wedge.
//
// Host-to-device transmission is not implemented - the pins are inputs
// here and stay tri-stated at the top level (keyboards power up in scan
// code set 2 with typematic on, which is all we need; the translator
// suppresses typematic repeats itself).
//
// Power-on init only (register initial values); nothing here needs a reset
// - a dropped frame self-heals within one keystroke.
module ps2_rx (
    input  logic       clk,        // cpu_clk
    input  logic       ps2_clk_i,  // from the pin (pulled up, driven Z)
    input  logic       ps2_dat_i,

    output logic [7:0] byte_o,     // received scan-code byte
    output logic       stb_o       // 1-clk strobe: byte_o valid
);

    // 2-FF sync + previous state for edge detection
    logic [2:0] csr = 3'b111;
    logic [1:0] dsr = 2'b11;
    always_ff @(posedge clk) begin
        csr <= {csr[1:0], ps2_clk_i};
        dsr <= {dsr[0],   ps2_dat_i};
    end
    wire ps2c_fall = (csr[2:1] == 2'b10);
    wire ps2d      = dsr[1];

    // frame receiver
    logic [3:0]  nbit  = '0;       // 0..10
    logic [10:0] shreg = '0;       // {stop, parity, data[7:0], start}
    // Dead-man for a half-received frame. 11 bits: ~680 us at 3.02 MHz, ~510 at
    // 4.03, ~340 at the 6.04 MHz turbo rate - it is counted in cpu_clk, so it
    // has to be sized for the FASTEST rate. At 10 bits turbo gave ~170 us =
    // only ~1.7 PS/2 bit-times (the bus runs at 10-16 kHz), close enough to a
    // stretched clock-low period to false-abort a good frame. Erring long is
    // free: this only ever recovers from a frame that was already lost.
    logic [10:0] tout  = '0;

    // shreg after the 11th shift: [10]=stop [9]=parity [8:1]=data [0]=start
    wire [10:0] frame  = {ps2d, shreg[10:1]};
    wire        f_ok   = frame[10] && !frame[0] && (^frame[9:1]);  // odd parity

    always_ff @(posedge clk) begin
        stb_o <= 1'b0;
        if (ps2c_fall) begin
            shreg <= {ps2d, shreg[10:1]};
            tout  <= '0;
            if (nbit == 4'd10) begin
                nbit <= '0;
                if (f_ok) begin
                    byte_o <= frame[8:1];
                    stb_o  <= 1'b1;
                end
            end else
                nbit <= nbit + 1'b1;
        end else if (nbit != 0) begin
            // mid-frame dead-man: abandon after the window above with no edge
            tout <= tout + 1'b1;
            if (&tout)
                nbit <= '0;
        end
    end

endmodule
