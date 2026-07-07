// kbd_ps2bk - PS/2 scan codes -> BK keyboard events (Phase 6 translator).
//
// Consumes scan-code bytes from ps2_rx and produces the event interface of
// bk_kbd014 (make strobe + final KOI-7 code + АР2 flag + any-key-down
// level), plus the СТОП strobe for the nIRQ1 one-shot in ocbk_top. All on
// cpu_clk; power-on init, except the ЗАГЛ/СТР + РУС/ЛАТ state, which resets
// on ACLO (power-on AND the reset button - see the case-algebra note below).
//
// This module is the software-visible half of the real BK keyboard: the
// hardware 1801ВП1-014 forms its code from the matrix position and the
// modifier PINS (НР=nSHIFT, СУ=nCTRL, АР2=EC2, and nEC1 = the external
// ЗАГЛ/СТР trigger - the 014 readme's "РУС/ЛАТ modifier" label is imprecise
// for the BK: the schematic wires nEC1 to the trigger flipped by the
// ЗАГЛ/СТР keys, while РУС/ЛАТ are ordinary matrix keys emitting 016/017).
//
// PS/2 mapping (user-chosen):
//   НР    = either Shift (12/59)          АР2  = either Alt (11 / E0 11)
//   СУ    = Insert (E0 70), held          ЗАГЛ/СТР trigger = CapsLock
//   РУС   = LCtrl (14)  -> code 016       ЛАТ  = Home (E0 6C) -> code 017
//   СТОП  = Delete (E0 71) -> key_stop strobe (radial, never a matrix code)
//
// Case algebra per BkEmu KeyboardManager (the canonical BK behaviour):
// letters take low register = latin ^ (caps_upper | shift); СУ masks codes
// with bit 0100 down to &037; non-letters take shift through the scan-code
// table (PC-layout symbol pairs). The latin shadow follows the emitted
// 016/017 codes - it mirrors the monitor's software РУС/ЛАТ state. Both it
// and the caps trigger are BK hardware cells clocked off ACLO (74LS74:
// D=GND, C=ACLO), so they reset to the power-on default (ЛАТ / ЗАГЛ) on
// power-on AND the reset button - matching the MONITOR's own re-init, which
// keeps them in sync across a warm reset. They are NOT reset by the RESET
// instruction (nINIT only), unlike the bk_kbd014 registers.
//
// Typematic repeats and multi-key: a 4-slot held-key list suppresses the
// repeated makes of held keys (the real 014 delivers one event per press -
// no hardware typematic) and drives key_down (177716 bit 6 source) as
// "any code-producing key held". Pure modifiers and СТОП do not count -
// they are not matrix keys on the real BK.
module kbd_ps2bk (
    input  logic       clk,        // cpu_clk
    input  logic       aclo_n,     // ACLO: resets the ЗАГЛ/СТР + РУС/ЛАТ state
    input  logic [7:0] ps2_byte,
    input  logic       ps2_stb,

    output logic       key_stb,    // 1-clk: accepted key make -> bk_kbd014
    output logic [6:0] key_code,
    output logic       key_ar2,
    output logic       key_down,   // any-key-held level (177716 bit 6)
    output logic       key_stop    // 1-clk: СТОП make -> nIRQ1 one-shot
);

    // ---- prefix tracking --------------------------------------------------
    // The E0/F0 prefixes are cleared by the following code byte; if that
    // byte gets dropped (parity error, cable glitch), a stale prefix would
    // swallow the next key's make as a break - the ~10 ms dead-man clears
    // them (real inter-byte gaps within a sequence are under a millisecond).
    logic        got_e0 = 1'b0;
    logic        got_f0 = 1'b0;
    logic [14:0] pfx_tout = '0;

    // ---- modifier levels / latches -----------------------------------------
    logic mod_shift_l = 1'b0, mod_shift_r = 1'b0;
    logic mod_alt     = 1'b0;      // АР2
    logic mod_su      = 1'b0;      // СУ = Insert held
    logic caps_upper  = 1'b1;      // ЗАГЛ/СТР trigger; ACLO/power-on = ЗАГЛ
    logic latin       = 1'b1;      // РУС/ЛАТ shadow;   ACLO/power-on = ЛАТ
    logic stop_down   = 1'b0;      // СТОП key level (repeat suppression)
    wire  mod_shift   = mod_shift_l | mod_shift_r;

    // ---- held-key list (code-producing keys only) ---------------------------
    // 4 slots of {valid, e0, scan}; a make already present = typematic repeat.
    logic [3:0] hk_v = '0;
    logic [8:0] hk   [3:0];
    initial for (int i = 0; i < 4; i++) hk[i] = '0;

    wire [8:0] scan_id = {got_e0, ps2_byte};
    logic [3:0] hk_match;
    always_comb
        for (int i = 0; i < 4; i++)
            hk_match[i] = hk_v[i] && (hk[i] == scan_id);
    wire hk_hit  = |hk_match;
    assign key_down = |hk_v;

    // ---- scan-code -> {autoar2, koi7} table (adapted from MiSTer
    //      BK0011M_MiSTer/rtl/translate.v; deviations documented above) ------
    logic [7:0] tbl;               // [7] = autoar2, [6:0] = base code
    always_comb begin
        tbl = 8'h00;
        casex ({mod_shift, got_e0, ps2_byte})
            // --- symbols (PC layout, shift picks the pair member) ---------
            10'bx_x_00101001: tbl = 8'h20;  // Space
            10'b1_0_00010110: tbl = 8'h21;  // !
            10'b1_0_01010010: tbl = 8'h22;  // "
            10'b1_0_00100110: tbl = 8'h23;  // #
            10'b1_0_00100101: tbl = 8'h24;  // $
            10'b1_0_00101110: tbl = 8'h25;  // %
            10'b1_0_00111101: tbl = 8'h26;  // &
            10'b0_0_01010010: tbl = 8'h27;  // '
            10'b1_0_01000110: tbl = 8'h28;  // (
            10'b1_0_01000101: tbl = 8'h29;  // )
            10'b1_0_00111110: tbl = 8'h2a;  // *
            10'b1_0_01010101: tbl = 8'h2b;  // +
            10'b0_0_01000001: tbl = 8'h2c;  // ,
            10'b0_0_01001110: tbl = 8'h2d;  // -
            10'b0_0_01001001: tbl = 8'h2e;  // .
            10'b0_0_01001010: tbl = 8'h2f;  // /
            10'b0_0_01000101: tbl = 8'h30;  // 0
            10'b0_0_00010110: tbl = 8'h31;  // 1
            10'b0_0_00011110: tbl = 8'h32;  // 2
            10'b0_0_00100110: tbl = 8'h33;  // 3
            10'b0_0_00100101: tbl = 8'h34;  // 4
            10'b0_0_00101110: tbl = 8'h35;  // 5
            10'b0_0_00110110: tbl = 8'h36;  // 6
            10'b0_0_00111101: tbl = 8'h37;  // 7
            10'b0_0_00111110: tbl = 8'h38;  // 8
            10'b0_0_01000110: tbl = 8'h39;  // 9
            10'b1_0_01001100: tbl = 8'h3a;  // :
            10'b0_0_01001100: tbl = 8'h3b;  // ;
            10'b1_0_01000001: tbl = 8'h3c;  // <
            10'b0_0_01010101: tbl = 8'h3d;  // =
            10'b1_0_01001001: tbl = 8'h3e;  // >
            10'b1_0_01001010: tbl = 8'h3f;  // ?
            10'b1_0_00011110: tbl = 8'h40;  // @
            10'b0_0_01010100: tbl = 8'h5b;  // [
            10'b0_0_01011101: tbl = 8'h5c;  // \
            10'b0_0_01011011: tbl = 8'h5d;  // ]
            10'b1_0_00110110: tbl = 8'h5e;  // ^
            10'b1_0_01001110: tbl = 8'h5f;  // _
            10'b0_0_00001110: tbl = 8'h60;  // `
            10'b1_0_01010100: tbl = 8'h7b;  // {
            10'b1_0_01011101: tbl = 8'h7c;  // |
            10'b1_0_01011011: tbl = 8'h7d;  // }
            10'b1_0_00001110: tbl = 8'h7e;  // ~
            // --- letters: lowercase base, the case algebra shifts them ----
            10'bx_0_00011100: tbl = 8'h61;  // a
            10'bx_0_00110010: tbl = 8'h62;  // b
            10'bx_0_00100001: tbl = 8'h63;  // c
            10'bx_0_00100011: tbl = 8'h64;  // d
            10'bx_0_00100100: tbl = 8'h65;  // e
            10'bx_0_00101011: tbl = 8'h66;  // f
            10'bx_0_00110100: tbl = 8'h67;  // g
            10'bx_0_00110011: tbl = 8'h68;  // h
            10'bx_0_01000011: tbl = 8'h69;  // i
            10'bx_0_00111011: tbl = 8'h6a;  // j
            10'bx_0_01000010: tbl = 8'h6b;  // k
            10'bx_0_01001011: tbl = 8'h6c;  // l
            10'bx_0_00111010: tbl = 8'h6d;  // m
            10'bx_0_00110001: tbl = 8'h6e;  // n
            10'bx_0_01000100: tbl = 8'h6f;  // o
            10'bx_0_01001101: tbl = 8'h70;  // p
            10'bx_0_00010101: tbl = 8'h71;  // q
            10'bx_0_00101101: tbl = 8'h72;  // r
            10'bx_0_00011011: tbl = 8'h73;  // s
            10'bx_0_00101100: tbl = 8'h74;  // t
            10'bx_0_00111100: tbl = 8'h75;  // u
            10'bx_0_00101010: tbl = 8'h76;  // v
            10'bx_0_00011101: tbl = 8'h77;  // w
            10'bx_0_00100010: tbl = 8'h78;  // x
            10'bx_0_00110101: tbl = 8'h79;  // y
            10'bx_0_00011010: tbl = 8'h7a;  // z
            // --- BK control keys -------------------------------------------
            10'bx_x_01100110: tbl = 8'o030; // Backspace: delete last char
            10'bx_0_00001101: tbl = 8'o011; // Tab
            10'bx_x_01110110: tbl = 8'o003; // Esc: КТ
            10'bx_0_01011010: tbl = 8'o012; // Enter
            10'bx_1_01011010: tbl = 8'o012; // keypad Enter
            10'bx_0_01110001: tbl = 8'o026; // keypad . : |<=
            10'bx_0_01110000: tbl = 8'o027; // keypad 0 : |=>
            10'bx_x_01110101: tbl = 8'o032; // Up
            10'bx_x_01110010: tbl = 8'o033; // Down
            10'bx_x_01101011: tbl = 8'o010; // Left
            10'bx_x_01110100: tbl = 8'o031; // Right
            10'bx_0_01101100: tbl = 8'o034; // keypad 7: up-left
            10'bx_x_01111101: tbl = 8'o035; // PgUp: up-right
            10'bx_x_01101001: tbl = 8'o037; // End: down-left
            10'bx_x_01111010: tbl = 8'o036; // PgDn: down-right
            10'bx_x_00000101: tbl = 8'o201; // F1: ПОВТ (АР2 code)
            10'bx_x_00000110: tbl = 8'o023; // F2: ВС
            10'bx_x_00000100: tbl = 8'o225; // F3: graphics (АР2 code)
            10'bx_x_00000011: tbl = 8'o231; // F5: kill-to-EOL (АР2 code)
            10'bx_x_00001011: tbl = 8'o202; // F6: ИНД СУ (АР2 code)
            10'bx_x_10000011: tbl = 8'o204; // F7: БЛОК РЕД (АР2 code)
            10'bx_x_00001010: tbl = 8'o220; // F8: ШАГ (АР2 code)
            10'bx_x_00000001: tbl = 8'o014; // F9: СБР
            // --- РУС / ЛАТ: ordinary code keys (flip the latin shadow) -----
            10'bx_0_00010100: tbl = 8'o016; // LCtrl: РУС
            10'bx_1_01101100: tbl = 8'o017; // Home:  ЛАТ
            default: tbl = 8'h00;
        endcase
    end

    // ---- case algebra (BkEmu KeyboardManager semantics) ---------------------
    wire       is_letter = (tbl[6:0] >= 7'h61) && (tbl[6:0] <= 7'h7a);
    wire       low_reg   = latin ^ (caps_upper | mod_shift);
    logic [6:0] xcode;
    always_comb begin
        xcode = tbl[6:0];
        if (is_letter && !low_reg)
            xcode = tbl[6:0] - 7'h20;          // upper register
        if (mod_su && xcode[6])
            xcode = {2'b00, xcode[4:0]};        // СУ: &037 on 01xx codes
    end

    // The 014 silicon vectors these FINAL codes to 0274 on its own, without
    // the АР2 pin (measured over the full vp_014 netlist matrix scan across
    // all modifier combinations; arrows are NOT in the group - MiSTer's
    // table flag was wrong there): {000,001,002,004,005,006,007,011,013,021}
    wire auto274 = (xcode == 7'o000) || (xcode == 7'o001) || (xcode == 7'o002)
                || (xcode == 7'o004) || (xcode == 7'o005) || (xcode == 7'o006)
                || (xcode == 7'o007) || (xcode == 7'o011) || (xcode == 7'o013)
                || (xcode == 7'o021);

    // ---- byte processing -----------------------------------------------------
    always_ff @(posedge clk) begin
        key_stb  <= 1'b0;
        key_stop <= 1'b0;

        if ((got_e0 || got_f0) && !ps2_stb) begin
            pfx_tout <= pfx_tout + 1'b1;
            if (&pfx_tout) begin
                got_e0 <= 1'b0;
                got_f0 <= 1'b0;
            end
        end else
            pfx_tout <= '0;

        if (ps2_stb) begin
            if (ps2_byte == 8'hE0)
                got_e0 <= 1'b1;
            else if (ps2_byte == 8'hF0)
                got_f0 <= 1'b1;
            else begin
                got_e0 <= 1'b0;
                got_f0 <= 1'b0;

                // -- pure modifiers ------------------------------------------
                if (!got_e0 && ps2_byte == 8'h12)      mod_shift_l <= !got_f0;
                else if (!got_e0 && ps2_byte == 8'h59) mod_shift_r <= !got_f0;
                else if (ps2_byte == 8'h11)            mod_alt     <= !got_f0;   // АР2
                else if (got_e0 && ps2_byte == 8'h70)  mod_su      <= !got_f0;   // СУ = Ins
                else if (!got_e0 && ps2_byte == 8'h58) begin
                    if (!got_f0) caps_upper <= ~caps_upper;    // ЗАГЛ/СТР trigger
                end
                // -- СТОП (radial: strobe on make, level for suppression) ----
                else if (got_e0 && ps2_byte == 8'h71) begin
                    if (!got_f0 && !stop_down) key_stop <= 1'b1;
                    stop_down <= !got_f0;
                end
                // -- code-producing keys --------------------------------------
                else if (got_f0) begin
                    // break: drop from the held-key list
                    for (int i = 0; i < 4; i++)
                        if (hk_match[i]) hk_v[i] <= 1'b0;
                end else if (tbl != 8'h00) begin
                    if (!hk_hit) begin          // not a typematic repeat
                        key_code <= xcode;
                        // АР2 held, a PC key emulating a BK АР2 chord (the
                        // F-key table entries), or the silicon auto-274 group
                        key_ar2  <= mod_alt | tbl[7] | auto274;
                        key_stb  <= 1'b1;
                        if (tbl[6:0] == 7'o016) latin <= 1'b0;   // РУС
                        if (tbl[6:0] == 7'o017) latin <= 1'b1;   // ЛАТ
                        // track it (a 5th concurrent key goes untracked)
                        if (!hk_v[0])      begin hk_v[0] <= 1'b1; hk[0] <= scan_id; end
                        else if (!hk_v[1]) begin hk_v[1] <= 1'b1; hk[1] <= scan_id; end
                        else if (!hk_v[2]) begin hk_v[2] <= 1'b1; hk[2] <= scan_id; end
                        else if (!hk_v[3]) begin hk_v[3] <= 1'b1; hk[3] <= scan_id; end
                    end
                end
            end
        end

        // ЗАГЛ/СТР caps trigger and the РУС/ЛАТ shadow are hardware cells the
        // BK schematic clocks off ACLO (74LS74: D=GND, C=ACLO) - reset to the
        // power-on default (ЗАГЛ / ЛАТ) on power-on AND the reset button (both
        // pulse ACLO), matching the MONITOR re-init. NOT reset by the RESET
        // instruction (that pulses nINIT only, never ACLO). Placed last so the
        // reset wins over any same-cycle CapsLock toggle / 016-017 emit.
        if (!aclo_n) begin
            caps_upper <= 1'b1;    // ЗАГЛ
            latin      <= 1'b1;    // ЛАТ
        end
    end

endmodule
