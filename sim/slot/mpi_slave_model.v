//
// mpi_slave_model - a behavioural МПИ expansion module, for sim/slot.
//
// Models the WIRE, not any particular chip: what a real slave-only expansion
// board (an SMK512) does on the bus, so qbus_slot's bridging can be checked
// against something that behaves like the thing it will meet on the board.
// Sits on the physical pSlt* pins, i.e. on the far side of the bridge, and is
// the only device in the oracle that ocbk does not own.
//
// Bus polarity: the МПИ is INVERTED, so a data word D appears on the pins as
// ~D and an asserted strobe is LOW. RPLY is open-drain here (0 or Z) exactly
// as a real module drives it - the pad pull-up in the .qsf is what makes an
// absent module read deasserted, and this model reproduces that by simply not
// driving.
//
// WHAT IT DECODES
//   REG_BASE .. REG_BASE+016   8 read/write registers.  REG_BASE+016 is a
//                              CONTROL register whose low bits drive the
//                              host-ROM deselect lines, which is how a real
//                              SMK512 takes the host ROM away: a CPU write to
//                              the module's own mode register changes a bus
//                              line as a side effect.
//   ROM_BASE .. +ROM_WORDS     a module ROM window on the NORMAL DIN strobe,
//                              answered only while BAS is asserted.
//   0177716 (vec_mode only)    THE START VECTOR. In its reset mode an SMK512's
//                              rom7 window covers 0170000-0177777 INCLUDING the
//                              register space, so it answers the CPU's start-
//                              vector read with its BIOS word at image offset
//                              07716 = 0166400. It DRIVES ONLY - it sends no
//                              RPLY, because the vm1 self-replies for its own
//                              177700-177717 block. That makes this the one
//                              cycle on the bus where a bridge gated on the
//                              module's reply sees nothing at all, which is why
//                              a real SMK512 booted an МПИ-equipped ocbk into
//                              MONITOR instead of into its BIOS.
//   ROM2_BASE .. +ROM_WORDS    a SECOND window on the E STROBE, answered only
//                              while BAS2 is asserted. This is the МСТД
//                              topology and it is the whole reason this model
//                              exists in this shape: on a BK-0010 the
//                              160000-177577 ROM is read-strobed by the 037's
//                              E, not by DIN (the host's own DS19 takes its DIN
//                              from XT3.A29 = E through R60), so a module's
//                              replacement ROM reads the raw E on XT3.A30. A
//                              bridge that does not export E leaves this window
//                              permanently mute - which is exactly what
//                              happened on the board.
//                              Both windows answer ONLY while their deselect is
//                              asserted: a module must not answer for a region
//                              the host still owns, or both drive. The second
//                              window takes BAS2 **or** M11 - the two lines name
//                              the same 160000-177577 window through different
//                              host-side mechanisms, and a module drives
//                              whichever its installation wired.
//
// THE RELEASE RULE IS THE POINT OF THIS FILE.  A DATIO(B) read-modify-write
// runs DIN then DOUT under ONE held SYNC, so a slave that returns to idle on
// SYNC-rise sits through the DOUT phase and silently drops the write (the
// CLAUDE.md RMW rule; found on real hardware once already - see
// doc/dev/gotchas.md). This model re-arms on STROBES-IDLE, and the oracle's
// RMW leg fails if the bridge does not preserve that window.
//
// Deliberate simplifications, none of which the bridge can tell apart from a
// real module: the reply latency is a fixed parameter rather than an access
// time; there is no DMA, no interrupt and no IAK participation (the bridge has
// none either yet); and the module never drives AD except in a read data
// phase it has claimed - the start vector included, which it claims by address
// alone because there is no reply to claim it with.
//
`timescale 1ns / 1ps

module mpi_slave_model #(
    parameter [15:0] REG_BASE  = 16'o177740,
    parameter [15:0] ROM_BASE  = 16'o120000,
    parameter [15:0] ROM2_BASE = 16'o160000,
    parameter int    ROM_WORDS = 16,       // decoded window, in words
    parameter int    LATENCY   = 4,        // clk edges from strobe to RPLY
    parameter [15:0] VEC_ADDR  = 16'o177716,
    parameter [15:0] VEC_WORD  = 16'o166400  // the real SMK512 BIOS[07716]
) (
    input  wire        clk,        // the model's own timebase (sys_clk)
    input  wire        rst_n,

    // ---- the МПИ pins, module side ---------------------------------------
    inout  wire [15:0] pSltAd,
    input  wire        pSltSync_n,
    input  wire        pSltDin_n,
    input  wire        pSltDout_n,
    input  wire        pSltWtbt_n,
    input  wire        pSltE_n,     // the 037's E: the second window's strobe
    output wire        pSltRply_n,
    input  wire        pSltInit_n,
    output wire        pSltMon10_n,
    output wire        pSltBas10_n,
    output wire        pSltBas2_n,
    output wire        pSltMon11_n,

    // ---- tb control -------------------------------------------------------
    input  wire        no_reply,   // 1 = the module is mute (the qbto leg)
    input  wire        vec_mode    // 1 = also answer the 177716 start vector
);

    // ---- storage ----------------------------------------------------------
    reg [15:0] regs [0:7];
    reg [15:0] ctrl;               // = regs[7], mirrored for readability

    integer i;

    // ---- address latch: SYNC's LEADING edge, as a real slave does ---------
    // If the bridge does not put the address on the pins before SYNC falls,
    // this latches rubbish and every leg fails - which is exactly the check
    // the previous qbus_slot would not have survived.
    reg [15:0] addr;
    reg        is_write_cycle;     // WTBT at SYNC time = a write is coming
    always @(negedge pSltSync_n) begin
        addr           = ~pSltAd;
        is_write_cycle = ~pSltWtbt_n;
    end

    wire sel_reg = !pSltSync_n && (addr[15:4] == REG_BASE[15:4]);
    wire sel_rom = !pSltSync_n && !no_reply
                   && (addr >= ROM_BASE)
                   && (addr <  ROM_BASE + 2*ROM_WORDS)
                   && ctrl[0];                  // BAS
    // The E-strobed window. Note the strobe: this one is read on E, NOT on DIN.
    wire sel_rom2 = !pSltSync_n && !no_reply
                   && (addr >= ROM2_BASE)
                   && (addr <  ROM2_BASE + 2*ROM_WORDS)
                   && ctrl[2];                  // BAS2 - the BK-0010 line for
                                                //   this window. NOT M11: that
                                                //   wire exists only on a
                                                //   BK-0011M, so on this stack
                                                //   asserting it must move
                                                //   nothing (sub-test 7d)
    wire sel_any = (sel_reg || sel_rom || sel_rom2) && !no_reply;

    // ---- read data --------------------------------------------------------
    // The ROM window returns an address-derived pattern, so a wrong address on
    // the pins shows up as wrong DATA rather than as no reply at all.
    // Distinct constants per window: addr[13:1] alone cannot tell 120000 from
    // 160000, so without this a read served by the WRONG window would still
    // look correct.
    wire [15:0] rd_word = sel_rom2 ? (16'o025252 ^ {3'b0, addr[13:1]})
                        : sel_rom  ? (16'o052525 ^ {3'b0, addr[13:1]})
                                   : regs[addr[3:1]];

    // ---- the start vector: DRIVE, no reply --------------------------------
    // Combinational off DIN, as a ROM output enable is: the CPU samples about
    // 1.5 cpu_clk after DIN on its OWN self-reply, so anything clocked out of
    // this model's LATENCY counter would arrive after the sample. No RPLY is
    // asserted for it - that is the whole point of this leg.
    wire vec_sel = vec_mode && !pSltSync_n && !pSltDin_n && (addr == VEC_ADDR);

    reg         drive;
    reg         reply;
    reg  [15:0] rd_hold;
    reg  [7:0]  cnt;

    assign pSltAd     = drive    ? ~rd_hold : 
                        vec_sel  ? ~VEC_WORD : 16'hZZZZ;
    // Every AD output enable this model has, for the tb's structural checks.
    wire   drive_any  = drive || vec_sel;
    assign pSltRply_n = reply ? 1'b0     : 1'bZ;   // open-drain, never high

    // ---- the deselect lines, active low on the МПИ ------------------------
    // Driven from the module's own control register: writing it is what makes
    // the host ROM go away, one bus cycle later.
    assign pSltMon10_n = ~ctrl[1];
    assign pSltBas10_n = ~ctrl[0];
    assign pSltBas2_n  = ~ctrl[2];
    // M11 has its OWN control bit, so the oracle can assert it WITHOUT BAS2.
    // On a real machine M11 is wired only on a BK-0011M and BAS2 only on a
    // BK-0010, while the adapter carries both in either case - so on this
    // BK-0010 stack an M11 assert must move nothing, and sub-test 7d checks
    // exactly that. Sharing a bit with BAS would make the check impossible.
    assign pSltMon11_n = ~ctrl[3];

    wire strobes_idle = pSltDin_n && pSltDout_n;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drive <= 1'b0;
            reply <= 1'b0;
            cnt   <= 8'd0;
            ctrl  <= 16'h0000;
            for (i = 0; i < 8; i = i + 1)
                regs[i] <= 16'o125252 + i[15:0];   // known preset, per-word
        end else begin
            // RE-ARM ON STROBES-IDLE, never on SYNC-rise. Inside a DATIO both
            // halves run under one SYNC, so this is what lets the write half
            // be seen at all.
            if (strobes_idle) begin
                drive <= 1'b0;
                reply <= 1'b0;
                cnt   <= 8'd0;
            end else if (!reply) begin
                if (cnt == LATENCY[7:0]) begin
                    if (sel_any && (sel_rom2 ? !pSltE_n : !pSltDin_n)) begin
                        rd_hold <= rd_word;
                        drive   <= 1'b1;
                        reply   <= 1'b1;
                    end else if (sel_reg && !pSltDout_n) begin
                        // WTBT is DUAL-PURPOSE: at DOUT time it is the BYTE
                        // flag, not the write flag it meant at SYNC. Sample it
                        // live, here, at the commit point.
                        if (!pSltWtbt_n) begin
                            if (addr[0]) regs[addr[3:1]][15:8] <= ~pSltAd[15:8];
                            else         regs[addr[3:1]][7:0]  <= ~pSltAd[7:0];
                            if (addr[3:1] == 3'd7)
                                ctrl <= addr[0]
                                      ? {~pSltAd[15:8], ctrl[7:0]}
                                      : {ctrl[15:8], ~pSltAd[7:0]};
                        end else begin
                            regs[addr[3:1]] <= ~pSltAd;
                            if (addr[3:1] == 3'd7) ctrl <= ~pSltAd;
                        end
                        reply <= 1'b1;
                    end
                end else begin
                    cnt <= cnt + 8'd1;
                end
            end
        end
    end

    // ---- protocol checks the module itself enforces -----------------------
    // A module that is driving AD while the bridge is also driving means the
    // direction logic is wrong; catch it here rather than as mysterious data.
    always @(posedge clk)
        if (rst_n && drive_any && !pSltDin_n && pSltSync_n)
            $display("SLOT-ERROR: module driving AD outside a SYNC at t=%0t", $time);

endmodule
