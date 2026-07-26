// bk_rply - the board's D8:B RPLY re-timing flop (Phase 9).
//
// On a real BK the CPU NEVER sees the raw wired-OR bus RPLY. Traced pin-by-pin
// in doc/bk0011m.sch: the bus RPLY net S1-21 goes through D21 (ЛП9, OC) to
// D8:B - a К531ТВ9 negedge JK wired as a plain D-FF (J = ~K via D33:E) clocked
// by CLC, the CPU clock - and its Q̄ drives R28 into the CPU's RPLY pin 39.
// Only the CPU's own internal self-reply bypasses it. That is also exactly
// what the 1801ВМ1 pin-sync rule demands: nRPLY must change on the CPU clock's
// FALLING edge, so it is stable well before the core samples it at the rising
// one (vm1_qbus's rply_ack, no synchroniser flops).
//
// WHY ONLY THE 037'S REPLY GOES THROUGH HERE
// ------------------------------------------
// Everything else in this design already satisfies the rule by construction:
// qbus_mem's wait FSM runs on cpu_clk = pin_clk_n, so every fixed-N slave
// (ROM, I/O, the 014, MK_EXT, 177662, the SMK registers, the IDE task file)
// already launches its reply on the falling edge. Re-timing those a second
// time would DOUBLE-COUNT - and it would double-count precisely the constants
// that were calibrated against real hardware with this flop's contribution
// already inside them (N_EXT and N_VREG = 1, N_KBD = 1). va_037_sync is the
// one exception: its PIN_nRPLY is combinational in the sys_clk/CLKIN domain
// and lands at whatever phase the divider happens to give - "1-2 sys_clk after
// a CPU edge, deterministic, same divider chain", i.e. compliant by accident
// rather than by construction, and at the /24 rate not compliant at all.
//
// So this module does not add a deviation; it completes a convention.
//
// CALIBRATION: this is one of the TWO ingredients of the Phase-9 037 grant-rule
// fit (sim/grantfit/README.md). On its own it is worth little (it closes none
// of the seven hardware tone legs); together with va_037_sync's GRANT_SETUP it
// puts all seven inside +/-1 Hz of the real BK-0011M readings. Neither works
// without the other: this moves when the CPU SEES the reply, GRANT_SETUP moves
// when the 037 TAKES the request.
//
// RESET: the real D8:B has no reset pin at all. Cyclone I flops need a defined
// power-up state, so it is keyed to the same power-on reset as the 037 itself
// (vid_rst_n in ocbk_top) and comes up DEASSERTED - never to dclo_n, which
// would make a warm reset drop a reply the 037 is still holding.
module bk_rply (
    input  logic cpu_clk,      // the CPU clock (same polarity as pin_clk_p)
    input  logic rst_n,        // power-on reset, active low (037's own)
    input  logic rply_037_n,   // va_037_sync PIN_nRPLY, active low
    output logic rply_n        // re-timed, active low; the caller wire-ANDs it
);

    logic q;                   // true-polarity "the 037 is replying"

    always_ff @(negedge cpu_clk or negedge rst_n)
        if (!rst_n) q <= 1'b0;
        else        q <= ~rply_037_n;

    assign rply_n = ~q;

endmodule
