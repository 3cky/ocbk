// bk_kbd014 - behavioral 1801ВП1-014 keyboard-controller equivalent (Phase 6).
//
// Serves 177660 (CSR) / 177662 (data) and the interrupt-acknowledge vector
// (060 / 0274) on the shared Q-bus. The bus-visible contract is validated
// against the vendored vp_014 gate netlist by sim/ref014 (both testbenches
// must reproduce the same committed golden_014.txt); the pinned contract is
// documented in sim/ref014/README.md. The netlist-decided points, all
// reproduced here:
//
//  * The code register re-latches on EVERY accepted key make (ready or not)
//    and is NOT cleared by INIT (stale code stays readable).
//  * A make finding ready CLEAR delivers: ready + request trigger set. The
//    trigger sets even when masked - IEN gates only the pin, so unmasking a
//    pending trigger retro-fires the VIRQ line.
//  * A make finding ready SET is queued: when a 177662 read clears ready and
//    the key is STILL HELD (key_down) with its event undelivered, the event
//    re-delivers immediately (ready + trigger again, same code). Releasing
//    the key first cancels the queued delivery. A delivered press never
//    re-fires while held (no hardware typematic).
//  * Reading 177662 returns {1'b0, code} - there is NO АР2 flag in bit 7
//    (netlist + BkEmu `& 0177` + MiSTer all agree); АР2 reaches software
//    only through the vector. The read clears ready AND a pending trigger.
//  * Writing 177662 is NOT replied to - the CPU runs into its bus timeout
//    (trap 4), as on real silicon (MiSTer decodes 662 read-only too).
//  * IAK clears the trigger only (ready survives). IAK with no pending
//    trigger or with a MASKED trigger does not reply (CPU vector timeout).
//  * INIT (the nINIT line: CPU reset AND the RESET instruction) re-masks,
//    clears ready/trigger, keeps the code register.
//
// Interface fidelity: like the real chip, the decode is the external nCS
// (the 037's PIN_nBS, window 177660-177663) plus AD1, both latched at SYNC
// fall; WTBT is ignored (the chip has no such pin - byte writes hit the
// whole register). The IAK cycle is DIN + nIAKI with NO SYNC, so the
// register path is qualified by !sync_n and cannot fire during it.
//
// Domains: FSM and registers on clk_fsm (= pin_clk_n, so RPLY transitions
// on CPU falling edges - the vm1 samples nRPLY there with no synchronizer);
// the VIRQ line gets its final flop on posedge clk_p (pin-sync rule: nVIRQ
// asserts synchronous to the CPU clock rising edge). The key-event inputs
// are launched on posedge clk_p by the translator and sampled here half a
// cycle later - same-divider deterministic, no synchronizers needed.
module bk_kbd014 (
    input  logic        clk_fsm,   // pin_clk_n: bus FSM + register state
    input  logic        clk_p,     // pin_clk_p: final VIRQ pin flop
    input  logic        init_n,    // Q-bus nINIT (active low, synchronous)

    // ---- Q-bus (inverted, active low) -----------------------------------
    inout  wire  [15:0] ad_n,
    input  logic        sync_n,
    input  logic        din_n,
    input  logic        dout_n,
    input  logic        cs_n,      // 037 PIN_nBS (transparent until SYNC fall)
    input  logic        iako_n,
    output wire         rply_n,    // open-collector
    output wire         virq_n,    // open-collector

    // ---- key events (clk_p domain, from the PS/2 translator) -------------
    input  logic        key_stb,   // 1-clk strobe: accepted key make
    input  logic [6:0]  key_code,  // final KOI-7 code for this make
    input  logic        key_ar2,   // vector 0274 event (АР2 held / autoar2)
    input  logic        key_down   // level: key still held (also 177716 bit 6)
);

    import qbus_pkg::*;

    // ---- {cs, a1} latched at SYNC fall (as the real chip latches nCS;
    //      transparent-on-SYNC idiom, an SDC-cut slow clock) ----------------
    logic cs_l, a1_l;
    always_ff @(negedge sync_n) begin
        cs_l <= ~cs_n;
        a1_l <= ~ad_n[1];
    end

    // ---- register state (contract: see header) ----------------------------
    logic       ien;              // 177660 bit 6: 1 = VIRQ disabled (cold/INIT)
    logic       ready;            // 177660 bit 7
    logic       virq_req;         // pending request trigger
    logic       delivered;        // current press already produced its event
    logic [6:0] code = '0;        // data register (no INIT reset - silicon)
    logic       v274 = 1'b0;      // vector select, latched with code

    typedef enum logic [1:0] { S_IDLE, S_WAIT, S_REPLY } state_t;
    state_t      state;
    logic        is_iak;          // current cycle is the vector responder
    logic [2:0]  wcnt;
    logic        reply, drive_data;
    logic [15:0] rdata;

    wire is_read  = !din_n;
    wire is_write = !dout_n;
    wire sel_662  = a1_l;

    always_ff @(posedge clk_fsm) begin
        if (!init_n) begin
            ien       <= 1'b1;
            ready     <= 1'b0;
            virq_req  <= 1'b0;
            delivered <= 1'b1;    // no ghost delivery of a key held across INIT
            state     <= S_IDLE;
            is_iak    <= 1'b0;
            reply     <= 1'b0;
            drive_data<= 1'b0;
            wcnt      <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    reply      <= 1'b0;
                    drive_data <= 1'b0;
                    // Register access: needs SYNC + the latched nBS. A write
                    // to 177662 gets NO reply (silicon: bus timeout).
                    if (!sync_n && cs_l &&
                        (is_read || (is_write && !sel_662))) begin
                        is_iak <= 1'b0;
                        wcnt   <= 3'(N_KBD - 2);
                        state  <= S_WAIT;
                    end
                    // IAK cycle: DIN + IAKI, no SYNC. Only a pending AND
                    // unmasked trigger answers (netlist: the request is
                    // sampled through the IEN gate at DIN fall).
                    else if (!iako_n && !din_n && virq_req && !ien) begin
                        is_iak <= 1'b1;
                        wcnt   <= 3'(N_IAK - 2);
                        state  <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (wcnt == 0) begin
                        reply <= 1'b1;
                        if (is_iak) begin
                            rdata      <= v274 ? 16'o000274 : 16'o000060;
                            drive_data <= 1'b1;
                            virq_req   <= 1'b0;   // IAK clears the trigger only
                        end else if (is_read) begin
                            // data latched BEFORE the side effects below
                            rdata      <= sel_662 ? {9'b0, code}
                                                  : {8'b0, ready, ien, 6'b0};
                            drive_data <= 1'b1;
                            if (sel_662) begin
                                // clear ready + pending trigger; a still-held
                                // undelivered press re-delivers right away
                                ready     <= key_down && !delivered;
                                virq_req  <= key_down && !delivered;
                                delivered <= 1'b1;
                            end
                        end else begin
                            // 177660 write: bit 6 only, live bus data
                            ien <= ~ad_n[6];
                        end
                        state <= S_REPLY;
                    end else
                        wcnt <= wcnt - 1'b1;
                end

                S_REPLY: begin
                    // exit on strobes-idle, never on SYNC-rise: the DOUT
                    // phase of a DATIO RMW on 177660 must find S_IDLE again
                    if (din_n && dout_n) begin
                        reply      <= 1'b0;
                        drive_data <= 1'b0;
                        is_iak     <= 1'b0;
                        state      <= S_IDLE;
                    end
                end
            endcase

            // ---- key make event (after the bus case: on the never-exercised
            //      same-edge collision the event ordering wins) --------------
            if (key_stb) begin
                code <= key_code;
                v274 <= key_ar2;
                if (!ready) begin
                    ready     <= 1'b1;
                    virq_req  <= 1'b1;   // even when masked (retro-fire)
                    delivered <= 1'b1;
                end else
                    delivered <= 1'b0;   // queued: re-delivers on the 662 read
            end
        end
    end

    // ---- VIRQ final flop on posedge clk_p (pin-sync rule: the vm1 samples
    //      rq[] at posedge pin_clk_p with no synchronizer) ------------------
    logic virq_ff = 1'b0;
    always_ff @(posedge clk_p) virq_ff <= virq_req & ~ien;

    // ---- Q-bus drivers (inverted; open-collector rply/virq) ---------------
    assign ad_n   = drive_data ? ~rdata : 16'hZZZZ;
    assign rply_n = reply      ? 1'b0   : 1'bZ;
    assign virq_n = virq_ff    ? 1'b0   : 1'bZ;

endmodule
