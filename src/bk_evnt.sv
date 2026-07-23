// bk_evnt - the BK-0011M 50 Hz EVNT/IRQ2 frame-interrupt detector (Phase 9).
//
// A gate-faithful replica of the real 0011M's external interrupt detector.
// The 1801VP1-037 has NO "vertical blanking" output pin: IRQ2 is synthesised
// on the motherboard from WTI (the video-fetch strobe, 037 pin 31) and SYNCO
// (composite sync, 037 pin 28) by a two-chip missing-pulse detector.
// Schematic trace (doc/bk0011m.sch, verified pin-by-pin):
//
//   D28  K555IE5 (74LS93), the /2 section:
//        CKA  = ~(SYNCO | QA)      -- D6:C (K555LE4 3-input NOR) with QA fed
//                                     back into two of its inputs
//        R0(1)&R0(2) = CLC & WTI   -- async clear
//        QA   -> D3.12
//
//   D3:B K555TM2 (74LS74):
//        C = SYNCO (rising), D = QA, R = D35.5 (active low)
//        ~Q -> D21 (K155LP9, open collector, 22k pull-up E7.2) -> the ~PRT net
//           -> D11.4 (K555TM9, clocked by CLC) -> the CPU's IRQ2 pin
//
//   D35.5 (Q2) is the 662 IRQ-enable bit: D35.D2 <- S1-70 <- D31.8 (K555LL1 OR,
//        other input GND) <- S1-15 = AD14, the *inverted* bus line, so
//        Q2 = ~reg662[14] = "IRQ2 enabled". D35 is reset by ACLO (D35.MR).
//
// How it behaves:
//
//   WTI pulses once per fetched video word (32 per displayed line) and is
//   silent on every non-displayed line, so it pins QA at 0 throughout the
//   displayed area. When WTI stops, the next SYNCO edge toggles QA to 1 - and
//   the QA feedback then holds CKA low, so QA is SET-ONCE until WTI resumes.
//   D3:B re-samples QA on every SYNCO rising edge.
//
//   The QA toggle and the D3:B clock are the SAME SYNCO edge. On the board,
//   propagation delay makes D3:B capture the OLD QA - so the request appears
//   one whole line after QA sets. That race is load-bearing (it is a third of
//   the total offset) and is reproduced here by the non-blocking assignment
//   ordering: `evnt <= qa` in the same cycle as `qa <= ~qa` samples the old qa.
//   Sampling the new value would shorten the delay by a full scanline.
//
//   `irq_en` is an asynchronous CLEAR of the request flop, not a combinational
//   gate. Consequence, and a real divergence from both our pre-Phase-9 model
//   and MiSTer's: un-masking mid-blanking does NOT retro-fire instantly - the
//   flop leaves reset and only sets at the NEXT SYNCO edge.
//
// Measured against the vendored reference netlist (sim/ref037/va_037.v),
// full-screen (177664 bit 9 set), stable every frame:
//
//   assert   = VGATE rise + 452 CLKIN     (~75 us, ~1.18 lines, ~301 cpu_clk)
//   deassert = VGATE fall + 452 CLKIN     (same offset - a clean 64-line level)
//
// and in 1/4-screen mode (177664 bit 9 clear) WTI stops after the 64th
// displayed line, so the request asserts 49604 CLKIN BEFORE the VGATE rise -
// i.e. during active video. That is authentic, and is exactly what the old
// "nIRQ2 = vgate" model could not express.
//
// Domain: all sys_clk. The 037 outputs change on the en_pos/en_neg /16 strobes
// (CLKIN = sys_clk/16), so sys_clk edge detection is exact - no CDC here. The
// pin-sync rule is honoured downstream: ocbk_top puts the final flop on
// posedge cpu_clk (2-FF), which is also what the board does at D11.
//
// Reset: power-on only (vid_rst_n), matching the board - D28 has no reset pin
// at all and D3:B's only reset is the 662 enable bit, so a warm reset leaves
// the detector free-running exactly like the rest of the video side. The 662
// mask resets to "masked", which holds `evnt` cleared until software unmasks.
//
// DELIBERATE SIMPLIFICATION: the board gates D28's clear with CLC
// (R0(1) = CLC, R0(2) = WTI), so the clear only bites during a CPU-clock high
// phase. Modelled here as a plain `wti` clear. WTI pulses 32 times per
// displayed line and each pulse is >= 1 CLKIN wide, so the only reachable
// difference is whether the LAST pulse of a line clears QA one CLKIN earlier
// or later - and QA cannot set until the SYNCO edge ~290 CLKIN later, so it is
// unobservable. Modelling the gate faithfully would drag cpu_clk into a
// video-domain module for no behavioural gain.
//
module bk_evnt (
    input  logic sys_clk,
    input  logic rst_n,      // power-on reset only (vid_rst_n)

    input  logic wti,        // 037 PIN_WTI   - video fetch strobe
    input  logic synco,      // 037 PIN_nVSYNC - composite sync (SYNCO, pin 28)
    input  logic irq_en,     // model_bk11 & ~reg662[14]  (async clear when 0)

    output logic evnt        // active-high request level -> ocbk_top
);

    // ---- D28 (K555IE5) /2 section ----------------------------------------
    logic qa, cka_d;
    wire  cka = ~(synco | qa);          // D6:C + the QA feedback

    // ---- D3:B (K555TM2) ---------------------------------------------------
    logic synco_d;

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            qa      <= 1'b0;
            cka_d   <= 1'b1;
            synco_d <= 1'b1;
            evnt    <= 1'b0;
        end else begin
            // D3:B first: `qa` on the right-hand side is the OLD value, which
            // is the board's propagation-delay race (see the header).
            if (!irq_en)                    evnt <= 1'b0;
            else if (!synco_d && synco)     evnt <= qa;

            // D28 QA: 74LS93 counts on CKA high->low; R0 clears it while WTI
            // pulses. Set-once per frame - the feedback pins CKA low at qa=1.
            if (wti)                        qa <= 1'b0;
            else if (cka_d && !cka)         qa <= ~qa;

            cka_d   <= cka;
            synco_d <= synco;
        end
    end

endmodule
