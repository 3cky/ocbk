//
// Phase 6 interrupt-latency SoC equivalence: the same gen_kbd_test.py
// program as ref014_irq_ref_tb.v, but on the integrated SoC stack -
//
//   vm1 CPU + va_037_sync (RAM RPLY / stealing / nBS) + qbus_mem
//   (ROM-in-SDRAM) + sdram_model + behavioral bk_kbd014
//   + the synthetic port-2 saturator (as ref037_soc_tb)
//
// Must reproduce golden_kbd.txt (generated ONLY by the netlist reference
// run) line for line. This diff is what calibrates N_KBD / N_IAK in
// qbus_pkg and the key-injection alignment below.
//
// Key events go through bk_kbd014's translator-side interface (make strobe
// + code/ar2 + key_down level) instead of the reference run's matrix + RC
// debounce; P_DLY re-creates the reference run's ARM-write-to-VIRQ latency
// in whole CPU clocks (both sides put their final VIRQ flop on posedge
// cpu_clk, so whole-cycle alignment is all that is needed).
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5
`define TEST_LO     16'o001000
`define TEST_HI     16'o002000

module ref014_irq_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // calibrated against golden_kbd.txt (the netlist reference run):
    localparam int P_DLY      = 23;  // ARM SYNC fall -> key_stb, CPU clocks
    localparam int STOP_PULSE = 64;  // nIRQ1 one-shot width (= ocbk_top's)

    // ---- clocks: sys_clk + ÷16 enables + CPU clk (÷32), as ref037_soc_tb ----
    reg       sys_clk;
    reg [4:0] divc;
    integer   nclk;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 5'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc[3:0] == 4'd15);
    wire en_neg = (divc[3:0] == 4'd7);
    wire clk    = divc[4];
    always @(posedge clk) nclk = nclk + 1;

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg dmgi, sp;   reg [1:0] pa;
    tri1        virq;
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- address decode (tb-side, for the window/ARM watcher only) -----------
    reg [15:0] addr;
    reg        sel_ram;
    always @(negedge sync) begin
        addr    = ~ad;
        sel_ram = (addr < 16'o100000);
    end
    always @(posedge sync) sel_ram = 1'b0;

    // ---- CPU ------------------------------------------------------------------
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

    // ---- retimed 037 (RAM RPLY + stealing + the nBS keyboard select) ----------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready), .ext_ram(1'b0),
        .PIN_R(~dclo), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate)
    );

    // ---- keyboard controller (the behavioral DUT) ------------------------------
    reg        key_stb;
    reg [6:0]  key_code;
    reg        key_ar2;
    reg        key_down;

    bk_kbd014 u_kbd (
        .clk_fsm(~clk), .clk_p(clk), .init_n(init),
        .ad_n(ad), .sync_n(sync), .din_n(din), .dout_n(dout),
        .cs_n(va_nbs), .iako_n(iako), .rply_n(rply), .virq_n(virq),
        .key_stb(key_stb), .key_code(key_code),
        .key_ar2(key_ar2), .key_down(key_down)
    );

    // ---- synthetic port-2 saturator (as ref037_soc_tb) -------------------------
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)          fetch_req <= 1'b0;
        else if (fetch_gnt) fetch_req <= 1'b0;
        else                fetch_req <= 1'b1;
    end

    // ---- the REAL integration module + SDRAM model -----------------------------
    wire init_done;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire [DW-1:0] v_rdata_nc;

    qbus_mem u_ms (
        .cpu_clk  (~clk),
        .reset    (~dclo),
        .init_n   (init),
        .kbd_down (key_down),
        .tape_in  (1'b0),            // no tape signal in this oracle
        .sel1_n   (sel[1]),          // CPU nSEL1/nSEL2 register selects
        .sel2_n   (sel[2]),
        .model_bk11(1'b0),           // BK-0010 mode: mapper = bit-identical pass-through
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
        .fetch_stb(fetch_stb)
    );

    sdram_model u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- timing measurement (window + park-loop exit, FETCH-TIMEOUT watchdog) --
    integer    prev_nclk;   reg [15:0] prev_addr;   reg have_baseline;
    integer    nloops;

    always @(negedge din) begin
        if (~sync && sel_ram && addr >= `TEST_LO && addr < `TEST_HI) begin
            if (have_baseline)
                $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
            prev_nclk = nclk; prev_addr = addr; have_baseline = 1'b1;
            if (addr == 16'o001004) begin
                nloops = nloops + 1;
                if (nloops == 6)
                    $finish;
            end
        end
    end

    // ---- ARM mailbox watcher + key-event injection ------------------------------
    // Codes must match the netlist matrix positions in ref014_irq_ref_tb.v.
    // The ARM anchor fires at the SYNC fall of the mailbox write (vm1-launched,
    // lands on the identical CPU cycle in both runs - see ref014_irq_ref_tb.v).
    event      ev_arm, ev_rd662;

    always @(negedge sync) begin
        if (~ad == 16'o000776)
            -> ev_arm;
    end

    always @(negedge rply) begin
        if (~din && (addr[15:2] == (16'o177660 >> 2)) && addr[1])
            -> ev_rd662;
    end

    task press (input [6:0] code, input ar2);
    begin
        repeat (P_DLY) @(posedge clk);
        key_code = code;
        key_ar2  = ar2;
        key_down = 1'b1;
        key_stb  = 1'b1;
        @(posedge clk);
        key_stb  = 1'b0;
    end
    endtask

    task release_key;
    begin
        repeat (6) @(posedge clk);
        key_down = 1'b0;
    end
    endtask

    initial begin
        key_stb = 0; key_code = 0; key_ar2 = 0; key_down = 0;

        @(ev_arm);                      // phase 1: plain key -> 060
        press(7'o141, 1'b0);
        @(ev_rd662);
        release_key;

        @(ev_arm);                      // phase 2: АР2 key -> 0274
        press(7'o146, 1'b1);
        @(ev_rd662);
        release_key;

        @(ev_arm);                      // phase 3: masked press
        press(7'o143, 1'b0);
        @(ev_rd662);                    // the program's own 662 read
        release_key;

        @(ev_arm);                      // phase 4: СТОП -> nIRQ1 fixed pulse
        @(posedge clk);
        irq[1] = 1'b0;
        repeat (STOP_PULSE) @(posedge clk);
        irq[1] = 1'b1;
    end

    // ---- program preload + reset (wait SDRAM init) + watchdog -------------------
    integer ii;
    initial begin
        nclk = 0; prev_nclk = 0; have_baseline = 1'b0; nloops = 0;
        pa = 2'b11; sp = 1'b1; dmgi = 1'b1; irq = 3'b111;
        dclo = 1'b0; aclo = 1'b0;

        for (ii = 0; ii < (1<<18); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        $readmemh("kbd_ram.hex", u_mem.mem, 0, 16383);          // BK RAM
        $readmemh("kbd_rom.hex", u_mem.mem, 'h4000, 'h7F7F);    // ROM region

        wait (init_done);
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #12_000_000;
        $display("FETCH-TIMEOUT: park loop never reached");
        $finish;
    end

endmodule
