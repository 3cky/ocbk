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
    output wire         rply_n,    // open-collector (wired-AND with CPU/memory)
    output wire         virq_n,    // push-pull active-low (sole VIRQ source; see footer)

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

    // Register access: needs SYNC + the latched nBS. A write to 177662 gets
    // NO reply (silicon: bus timeout). IAK cycle: DIN + IAKI, no SYNC; only
    // a pending AND unmasked trigger answers (netlist: the request is
    // sampled through the IEN gate at DIN fall).
    wire start_rd  = !sync_n && cs_l && is_read;
    wire start_wr  = !sync_n && cs_l && is_write && !sel_662;
    wire start_iak = !iako_n && !din_n && virq_req && !ien;

    // Reply-point strobes. N==1 fires at the detection edge itself - the
    // real 014 is an asynchronous chip whose RPLY follows the strobe within
    // ~150 ns (well inside one CPU clock), and the interrupt-latency golden
    // (sim/ref014/golden_kbd.txt, generated by the netlist reference run)
    // only matches with the single-edge reply. N>=2 takes the counted
    // S_WAIT path (the N_ROM-style shape), kept for recalibration.
    wire fire_reg = (state == S_IDLE) ? (start_rd && N_KBD == 1)
                                      : (state == S_WAIT && wcnt == 0 && !is_iak);
    wire fire_iak = (state == S_IDLE) ? (!start_rd && start_iak && N_IAK == 1)
                                      : (state == S_WAIT && wcnt == 0 &&  is_iak);

    // WRITE fast path (N_KBD==1): the vm1 launches DOUT from its falling-
    // edge output stage and the async 014 replies before the next rising
    // edge - half a cycle ahead of anything this negedge-clocked FSM can
    // register (the golden pins it). Assert the write RPLY combinationally,
    // exactly as the async chip does: glitch-safe because the vm1 samples
    // nRPLY only at clock edges and every term is stable across them; the
    // release follows DOUT release, also as the chip behaves. The register
    // update itself stays in the clocked block below (idempotent while the
    // strobe is low - the bus data is held for the whole DOUT window).
    wire wr_fast = (N_KBD == 1) && start_wr;

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
                    if (fire_reg || fire_iak)
                        is_iak <= fire_iak;
                    else if (N_KBD == 1 && start_wr)
                        ien <= ~ad_n[6];   // fast-path write: reply is wr_fast
                    else if (start_rd || start_wr) begin
                        is_iak <= 1'b0;
                        wcnt   <= 3'(N_KBD - 2);
                        state  <= S_WAIT;
                    end else if (start_iak) begin
                        is_iak <= 1'b1;
                        wcnt   <= 3'(N_IAK - 2);
                        state  <= S_WAIT;
                    end
                end

                S_WAIT:
                    if (wcnt != 0)
                        wcnt <= wcnt - 1'b1;

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

            // ---- the reply point (from S_IDLE when N==1, else from S_WAIT) --
            if (fire_reg) begin
                reply <= 1'b1;
                state <= S_REPLY;
                if (is_read) begin
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
                end else
                    ien <= ~ad_n[6];   // 177660 write: bit 6 only, live data
            end
            if (fire_iak) begin
                reply      <= 1'b1;
                state      <= S_REPLY;
                rdata      <= v274 ? 16'o000274 : 16'o000060;
                drive_data <= 1'b1;
                virq_req   <= 1'b0;    // IAK clears the trigger only
            end

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

    // ---- Q-bus drivers (inverted) -----------------------------------------
    // ad_n/rply_n are genuine wired-AND nets (the CPU + memory + this chip all
    // drive them), so they stay open-collector: Quartus infers the wired-AND
    // from the multiple Z-idle drivers. virq_n, by contrast, has a SINGLE
    // driver in Phase 6 (this is the only VIRQ source) - a lone Z-idle
    // tri-state degenerates on Cyclone I (no internal tri-state/pull-up:
    // Quartus "converts the tri-state buffer feeding internal logic into a
    // wire" and ties the idle state to 0 = permanently asserted, so virq_ff
    // loses all fanout and the CPU sees a stuck VIRQ). Drive it push-pull.
    // If a second VIRQ source is ever added (e.g. the cartridge slot), do NOT
    // go back to tri-state Z - OR the active-high asserts and invert at the top.
    assign ad_n   = drive_data        ? ~rdata : 16'hZZZZ;
    assign rply_n = (reply | wr_fast) ? 1'b0   : 1'bZ;
    assign virq_n = ~virq_ff;   // push-pull active-low (sole driver; see above)

endmodule
