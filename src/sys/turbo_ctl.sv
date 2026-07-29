// turbo_ctl - the turbo-mode enable, qualified onto an idle Q-bus.
//
// Turbo (PS/2 F12) does two things at once: it retargets the CPU divider to
// /16 = 6.04 MHz, and it moves the RAM RPLY OWNER from the 037 (which stops
// arbitrating - va_037_sync's no_steal) to qbus_mem's wait FSM (which starts
// replying at the fixed N_TURBO count). The clock half is harmless at any
// instant: cpu_clkgen's `>=` wrap makes a retarget stretch or shrink the
// current half-period, never a runt.
//
// THE OWNER HALF IS NOT. If the level moved in the middle of a bus cycle, one
// access could be started under one owner and finish under the other - and the
// bad direction is silent: the 037 declines the grant, qbus_mem has already
// passed its detection edge, NOBODY replies, and the CPU's qbto timer turns it
// into a spurious trap 4 under whatever program is running. That is exactly the
// case a user hitting F12 during a game would hit, and no fixed-N oracle would
// ever see it.
//
// So the effective level only moves on an edge where the bus is IDLE - SYNC,
// DIN and DOUT all released. There is no cycle in flight at such an edge, so
// the swap is atomic as far as the bus is concerned. SYNC framing covers the
// DATIO(B) read-modify-write gap too: SYNC stays asserted across both halves,
// so a RMW can never be split between owners. Idle is required for two
// consecutive sclk edges (bus_idle_q) because these are resolved wired-AND
// nets - a one-cycle glitch as drivers hand over must not look like idle.
//
// Reset: power-on (PLL lock) only. Turbo is a USER SETTING and survives a warm
// reset, exactly like screen_mode - kbd_ps2bk holds the toggle through ACLO for
// the same reason. Never key this to dclo_n.
module turbo_ctl (
    input  logic sclk,       // 96.65 MHz sys_clk
    input  logic rst_n,      // power-on reset (PLL locked), active low

    input  logic key_turbo,  // kbd_ps2bk's F12 toggle level (cpu_clk domain)

    input  logic sync_n,     // Q-bus strobes, active low (idle = all high)
    input  logic din_n,
    input  logic dout_n,

    output logic turbo       // sclk, bus-idle-qualified -> clkgen / 037 / qbus_mem
);

    // key_turbo is a quasi-static level in the cpu_clk domain: 2-FF resync,
    // the smode_sr / cmt_sr idiom.
    logic [1:0] key_sr;
    logic       bus_idle_q;

    always_ff @(posedge sclk or negedge rst_n) begin
        if (!rst_n) begin
            key_sr     <= 2'b00;
            bus_idle_q <= 1'b0;
            turbo      <= 1'b0;
        end else begin
            key_sr     <= {key_sr[0], key_turbo};
            bus_idle_q <= sync_n & din_n & dout_n;
            if (bus_idle_q && sync_n && din_n && dout_n)
                turbo <= key_sr[1];
        end
    end

endmodule
