//
// МПИ slot functional oracle: a real expansion module on the far side of
// qbus_slot, driven by the real CPU through the real bus front end.
// BK-0010 SoC stack, modelled on sim/romwr/romwr_tb.v:
//
//   vm1 CPU + va_037_sync (RAM RPLY / stealing) + the REAL qbus_mem
//   (mem_mapper in BK-0010 pass-through mode) + sdram_model + the synthetic
//   port-2 saturator for contention + the REAL qbus_slot + mpi_slave_model.
//
// The point of the oracle is that NOTHING here is a replica: the bridge under
// test is the shipped module, the reply re-timing is the shipped bk_rply, and
// the thing on the other end behaves like the board that will actually be
// plugged in. The program is mem/gen_slot_test.py.
//
// Pass/fail: 3 consecutive DIN fetches of the success park 001004 -> COSIM
// PASS; any fail-park 001012 hit or the watchdog -> COSIM FAIL. (Pinned park
// addresses, exactly like sim/bk11 and sim/romwr.)
//
// Legs, by plusarg:
//   (none)      module attached, everything exercised
//   +noreply    the module is mute: every slot access must qbto to trap 4, and
//               the machine must still run. This is the "nothing plugged in"
//               contract - the bridge must not invent a reply.
//   +dip8       a real module IS attached and answering, but DIP 8 also selects
//               the internal SMK512 emulation - the misconfiguration. qbus_slot
//               must stand down COMPLETELY (slot_live=0): no reply passed
//               through, no inward data, no deselect. Proves the two can never
//               both claim an address, which on the board would be silent.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module slot_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    localparam [15:0] ROMSTUBW = 16'o000137;   // ROM word 0 (JMP) - MUST match
    localparam [15:0] ROMSTUB1 = 16'o001000;   //   mem/gen_slot_test.py
    localparam [15:0] HOSTROM  = 16'o017171;   // the host BASIC word at 120000

    reg noreply, dip8;
    initial begin
        noreply = $test$plusargs("noreply");
        dip8    = $test$plusargs("dip8");
    end

    // ---- clocks: sys_clk + /16 037 enables + CPU clk (/32) -----------------
    reg       sys_clk;
    reg [4:0] divc;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 5'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);
    wire clk    = divc[4];

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;
    wire        rply037_rt_n;
    assign rply = (rply037_rt_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg dmgi, sp;   reg [1:0] pa;
    tri1        virq;
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- tb-side address latch (park monitor) -------------------------------
    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU ----------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(pa), .pin_sp_n(sp),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n(irq), .pin_virq_n(virq),
        .pin_ad_n(ad), .pin_dout_n(dout), .pin_din_n(din),
        .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
        .pin_dmr_n(dmr), .pin_sack_n(sack), .pin_dmgi_n(dmgi),
        .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel), .pin_bsy_n(bsy)
    );

    // ---- retimed 037 --------------------------------------------------------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .no_steal(1'b0),
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready),
        .ext_ram(1'b0),
        .PIN_R(~dclo), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate)
    );

    // ---- video fetch requester (arbiter port 2): contention ------------------
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)          fetch_req <= 1'b0;
        else if (fetch_gnt) fetch_req <= 1'b0;
        else                fetch_req <= 1'b1;
    end

    // ---- the REAL integration module, BK-0010 mode --------------------------
    wire init_done;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire [DW-1:0] v_rdata_nc;
    wire        vid_page_nc, vid_irq2m_nc;
    wire [3:0]  vid_pal_nc;
    wire        stop_block_nc;
    wire [7:0]  rom_dsl_vec;
    wire        map_rom3, map_rom4;

    qbus_mem u_ms (
        .turbo(1'b0),
        .cpu_clk  (~clk),
        .reset    (~dclo),
        .ide_rdata(16'h0000),
        .joy_word(16'o000000),
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(1'b0),           // BK-0010: mapper pass-through
        .smk_en   (dip8),            // +dip8: the internal SMK512 owns the bus
        .rom_dsl_vec(rom_dsl_vec),   // <- from the bridge under test
        .rom3     (map_rom3),
        .rom4     (map_rom4),
        .boot_active(1'b0),
        .bw_req   (1'b0),
        .bw_addr  ({AB{1'b0}}),
        .bw_wdata ({DW{1'b0}}),
        .bw_gnt   (),
        .sclk     (sys_clk),
        .srst_n   (srst_n),
        .init_done(init_done),
        .ad_n     (ad),
        .sync_n   (sync),
        .din_n    (din),
        .dout_n   (dout),
        .wtbt_n   (wtbt),
        .rply_n   (rply),
        .mem_ready(mem_ready),
        .ext_ram  (),
        .v1_req   (1'b0),
        .v1_addr  ({AB{1'b0}}),
        .v1_gnt   (),
        .v1_rvalid(),
        .v2_req   (fetch_req),
        .v2_addr  (fetch_addr),
        .v2_gnt   (fetch_gnt),
        .v2_rvalid(fetch_rvalid),
        .v3_req   (1'b0),
        .v3_addr  ({AB{1'b0}}),
        .v3_wdata ({DW{1'b0}}),
        .v3_gnt   (),
        .v_rdata  (v_rdata_nc),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
        .bus_addr (bus_addr),
        .fetch_stb(fetch_stb),
        .vid_page (vid_page_nc),
        .vid_irq2_mask(vid_irq2m_nc),
        .vid_pal  (vid_pal_nc),
        .stop_block(stop_block_nc)
    );

    sdram_model u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- THE BRIDGE UNDER TEST + the module on the far side -----------------
    tri1 [15:0] pSltAd;          // tri1 = the .qsf's WEAK_PULL_UP_RESISTOR
    wire        pSltSync_n, pSltDin_n, pSltDout_n, pSltWtbt_n;
    wire        pSltRply_n, pSltInit_n, pSltRom3_n, pSltRom4_n;
    wire        pSltMon10_n, pSltBas10_n, pSltMon11_n;

    // The .qsf gives every one of these pads a weak pull-up, which is what
    // makes an EMPTY connector read deasserted. tri1 is that pull-up.
    tri1        slt_rply = pSltRply_n;
    tri1        slt_m10  = pSltMon10_n;
    tri1        slt_b10  = pSltBas10_n;
    tri1        slt_m11  = pSltMon11_n;

    qbus_slot #(.SLOT_ENABLE(1'b1)) u_slot (
        .cpu_clk    (clk),
        .rst_n      (dclo),
        .ad_n       (ad),
        .sync_n     (sync),
        .din_n      (din),
        .dout_n     (dout),
        .wtbt_n     (wtbt),
        .init_n     (init),
        .rply_n     (rply),
        .model_bk11 (1'b0),
        .smk_en     (dip8),
        .rom3       (map_rom3),
        .rom4       (map_rom4),
        .rom_dsl_vec(rom_dsl_vec),
        .pSltAd     (pSltAd),
        .pSltSync_n (pSltSync_n),
        .pSltDin_n  (pSltDin_n),
        .pSltDout_n (pSltDout_n),
        .pSltWtbt_n (pSltWtbt_n),
        .pSltRply_n (slt_rply),
        .pSltInit_n (pSltInit_n),
        .pSltRom3_n (pSltRom3_n),
        .pSltRom4_n (pSltRom4_n),
        .pSltMon10_n(slt_m10),
        .pSltBas10_n(slt_b10),
        .pSltMon11_n(slt_m11)
    );

    mpi_slave_model u_module (
        .clk        (sys_clk),
        .rst_n      (dclo),
        .pSltAd     (pSltAd),
        .pSltSync_n (pSltSync_n),
        .pSltDin_n  (pSltDin_n),
        .pSltDout_n (pSltDout_n),
        .pSltWtbt_n (pSltWtbt_n),
        .pSltRply_n (slt_rply),
        .pSltInit_n (pSltInit_n),
        .pSltMon10_n(slt_m10),
        .pSltBas10_n(slt_b10),
        .pSltMon11_n(slt_m11),
        .no_reply   (noreply)        // +dip8 keeps the module LIVE: the
                                     // misconfiguration is what we are testing
    );

    // ---- the X monitor at the reply edge ------------------------------------
    // The standard guard in every SoC oracle here, and the single most valuable
    // check in this one: two drivers on ad_n resolve to X in Icarus, so a
    // direction bug in the bridge is loud instead of silent.
    always @(negedge rply) if (aclo === 1'b1) begin
        #1;
        if (!din && ^ad === 1'bx) begin
            $display("SLOT-X-ERROR: ad=%b addr=%06o t=%0t", ad, addr, $time);
            $display("COSIM FAIL");
            $finish;
        end
    end

    // ---- pin-level driver overlap, checked STRUCTURALLY ---------------------
    // The bridge and the module must never drive pSltAd at the same time. This
    // has to be a structural check on the two output enables, not an X monitor:
    // the overlap window is the module's data-hold after DIN rises, by which
    // point the CPU has already sampled, so the resulting X never reaches
    // anything the program can see and every behavioural leg passes. On the
    // board it is 16 lines of push-pull CMOS against a 5 V driver. This is the
    // "every sim still passes" failure class from doc/dev/gotchas.md, and the
    // only way to catch it in sim is to look at the enables directly.
    always @(posedge sys_clk) if (aclo === 1'b1) begin
        if (u_slot.g_on.slot_ad_oe && u_module.drive) begin
            $display("SLOT-ERROR: bridge and module both driving pSltAd, addr=%06o t=%0t",
                     addr, $time);
            $display("COSIM FAIL");
            $finish;
        end
    end

    // The mirror check: the bridge must only take data INWARD from a cycle the
    // module actually claimed. Structural for the same reason as above - the
    // pins are pulled up, and on this active-low wired-AND bus an extra driver
    // of all-ones is the identity element, so driving ad_n from an unclaimed
    // (floating) connector changes no value the program can see. It is still
    // wrong: on the board those pins are UNTERMINATED (the adapter has no
    // pull-ups - see doc/dev/mpi.md), so a glitch becomes silent corruption of
    // an INTERNAL read. The hold tail after DIN rises is legitimate and is why
    // this is qualified on din.
    always @(posedge sys_clk) if (aclo === 1'b1) begin
        if (u_slot.g_on.slot_rd && !din && !u_module.drive) begin
            $display("SLOT-ERROR: bridge drove ad_n from an unclaimed cycle, addr=%06o t=%0t",
                     addr, $time);
            $display("COSIM FAIL");
            $finish;
        end
    end

    // ---- the stand-down contract, checked structurally ----------------------
    // With DIP 8 on, the slot must contribute NOTHING - if it ever drives the
    // internal bus or a deselect bit, the two SMKs could both claim an address.
    always @(posedge sys_clk) if (dip8 && aclo === 1'b1) begin
        if (rom_dsl_vec !== 8'h00) begin
            $display("SLOT-ERROR: rom_dsl_vec=%b with DIP 8 on", rom_dsl_vec);
            $display("COSIM FAIL");
            $finish;
        end
        if (u_slot.g_on.slot_rd !== 1'b0) begin
            $display("SLOT-ERROR: slot drove ad_n with DIP 8 on");
            $display("COSIM FAIL");
            $finish;
        end
    end

    // ---- pass/fail: the pinned park loops (gen_slot_test.py) ----------------
    integer scnt = 0;
    always @(negedge din) begin
        if (~sync) begin
            if (addr == 16'o001004) begin
                scnt = scnt + 1;
                if (scnt == 3) begin
                    // The mute legs must NEVER reach the success park: every
                    // slot access traps, so the program cannot get there.
                    if (noreply || dip8) begin
                        $display("SLOT-ERROR: success park reached with no module");
                        $display("COSIM FAIL");
                    end else begin
                        $display("COSIM PASS");
                    end
                    $finish;
                end
            end else begin
                scnt = 0;
                if (addr == 16'o001012) begin
                    // The mute legs EXPECT the fail park: the first slot read
                    // traps to 4, whose default vector is the fail park. That
                    // is the machine still running, not a hang.
                    if (noreply || dip8) begin
                        $display("COSIM PASS");
                    end else begin
                        $display("SLOT-ERROR: fail park 001012 reached");
                        $display("COSIM FAIL");
                    end
                    $finish;
                end
            end
        end
    end

    // ---- SDRAM preload -------------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<18); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        $readmemh("slot_ram.hex", u_mem.mem, 0, 16383);
        u_mem.mem['h4000] = ROMSTUBW;   // BK 100000: JMP
        u_mem.mem['h4001] = ROMSTUB1;   // BK 100002: @#001000
        // The host's own BASIC word at 120000, so the deselect can be checked
        // in BOTH directions: module pattern with BAS10 on, this with it off.
        u_mem.mem['h5000] = HOSTROM;
    end

    // ---- reset (wait SDRAM init) + watchdog ---------------------------------
    initial begin
        pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111;
        dclo = 1'b0; aclo = 1'b0;

        wait (init_done);
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #20_000_000;
        $display("SLOT-ERROR: watchdog timeout (last addr %o)", addr);
        $display("COSIM FAIL");
        $finish;
    end

// D8:B for the 037's reply - the REAL module, never a replica. The SLOT's own
// re-timing flop is a second instance INSIDE qbus_slot, which is the whole
// structural point (see src/bus/bk_rply.sv and doc/dev/mpi.md).
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
