//
// ROM-write-timeout functional oracle (Phase 7): a write to ROM gets NO bus
// reply -> the CPU's qbto timer -> trap 4 (authentic mask-ROM behaviour;
// BkEmu agrees). BK-0010 SoC stack, modelled on ref014_irq_soc_tb.v:
//
//   vm1 CPU + va_037_sync (RAM RPLY / stealing) + the REAL qbus_mem
//   (mem_mapper in BK-0010 pass-through mode) + sdram_model + the synthetic
//   port-2 saturator for contention.
//
// The mem/gen_romwr_test.py program (RAM-resident, booted via a ROM stub the
// initial block pokes at 100000) runs two sub-tests: the conditionless
// "write until trap 4" screen-clear (a counter-free CLR (R0)+ loop whose
// write at 100000 traps), and an INC @#100000 RMW whose write half must trap
// while its read half replies. Both land in vector-4 handlers; all data
// checks passing parks at the success loop.
//
// Pass/fail: 3 consecutive DIN fetches of the success park 001004 -> COSIM
// PASS; any fail-park 001012 hit or the watchdog -> COSIM FAIL. (Pinned park
// addresses, exactly like sim/bk11.)
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module romwr_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    localparam [15:0] ROMSTUBW = 16'o000137;   // ROM word 0 (JMP) - MUST match
    localparam [15:0] ROMSTUB1 = 16'o001000;   //   mem/gen_romwr_test.py

    // ---- clocks: sys_clk + /16 037 enables + CPU clk (/32), as ref014 SoC tb --
    reg       sys_clk;
    reg [4:0] divc;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 5'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);
    // +turbo (Phase 9): /16 = 6.04 MHz with the 037 out of the RAM path.  This
    // oracle is the sharpest test of the turbo `selected` change, because the
    // whole point of the program is that RAM and ROM must behave DIFFERENTLY
    // in the same FSM: the conditionless screen clear marches out of RAM (which
    // must now be replied to HERE) into ROM (which must still get no reply, so
    // the trap-4 that ends the clear still happens).  Get the term wrong and
    // either the clear never ends or it ends too early.
    reg turbo;
    initial turbo = $test$plusargs("turbo");
    wire clk    = turbo ? divc[3] : divc[4];

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;
    // D8:B - the board flop that re-times the 037's RPLY onto the CPU
    // clock's falling edge before it reaches the CPU pin.  The REAL
    // module, never a replica (the cpu_clkgen drift lesson).
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

    // ---- retimed 037 (owns RAM RPLY for A15=0, done-gate = mem_ready) -------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .no_steal(turbo),   // +turbo: the 037 stops owning RAM
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

    // ---- video fetch requester (arbiter port 2): worst-case streaming reads --
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

    qbus_mem u_ms (
        .turbo(turbo),      // +turbo: this FSM owns the RAM reply
        .cpu_clk  (~clk),
        .reset    (~dclo),
        .ide_rdata(16'h0000),  // no SMK IDE device in this tb
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(1'b0),           // BK-0010: mapper = bit-identical pass-through
        .smk_en(1'b0),               // no SMK512 (never floating: X would poison)
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

    // ---- pass/fail: the pinned park loops (gen_romwr_test.py) ----------------
    integer scnt = 0;
    always @(negedge din) begin
        if (~sync) begin
            if (addr == 16'o001004) begin
                scnt = scnt + 1;
                if (scnt == 3) begin
                    $display("COSIM PASS");
                    $finish;
                end
            end else begin
                scnt = 0;
                if (addr == 16'o001012) begin
                    $display("ROMWR-ERROR: fail park 001012 reached");
                    $display("COSIM FAIL");
                    $finish;
                end
            end
        end
    end

    // ---- SDRAM preload -------------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<18); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        // BK RAM 000000-077777 = the program + vectors
        $readmemh("romwr_ram.hex", u_mem.mem, 0, 16383);
        // ROM stub: bk10 boots via 177716 -> 100000; the first fetch lands at the
        // ROM region (SDRAM word 0x4000 = BK 100000). JMP @#001000 into the RAM
        // program. These two words are ALSO the write-timeout invariant: the
        // program's trapped writes to 100000 must never change them.
        u_mem.mem['h4000] = ROMSTUBW;   // BK 100000: JMP
        u_mem.mem['h4001] = ROMSTUB1;   // BK 100002: @#001000
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
        $display("ROMWR-ERROR: watchdog timeout (last addr %o)", addr);
        $display("COSIM FAIL");
        $finish;
    end


// D8:B, the board's RPLY re-timing flop (src/bus/bk_rply.sv) - the REAL module,
// never a replica (the cpu_clkgen drift lesson).  Placed at the end of the
// module so it cannot depend on where the reset regs are declared.
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
