//
// Phase 3 SoC-integration cosim: the Strategy-A RAM path end to end.
//
//   vm1 CPU  +  va_037_sync (owns RAM RPLY, done-gate)  +  cpu_sdram_dp
//            +  sdram_arbiter  +  sdram_ctrl  +  behavioural sdram_model
//
// The bk10 test program runs FROM SDRAM (preloaded into the model), RAM RPLY comes
// from the 037 grant gated by the datapath's mem_ready, and the 037 video fetch
// streams worst-case back-to-back reads on arbiter port 2 to contend with the CPU
// (port 0). If the integration is correct the per-instruction cycle counts still
// match sim/ref037/golden_037.txt - i.e. the SDRAM + arbiter + done-gate reproduce
// the reference timing (the interlock never perturbs it at 3 MHz), AND the program
// executes correctly out of SDRAM (it reaches the self-loop).
//
// ROM (100000-137777) + I/O (177716) stay behavioural on-chip here (fixed N_ROM),
// exactly as in ref037_sync_tb; only the RAM path changed.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5
`define N_ROM       2
`define TEST_LO 16'o001000
`define TEST_HI 16'o002000

module ref037_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // ---- clocks: sys_clk + ÷16 enables (on CPU edges) + CPU clk (÷32) --------
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
    reg  [15:0] rom_data, io_data;
    reg         rom_oe, io_oe;
    assign ad = rom_oe ? ~rom_data : 16'hZZZZ;
    assign ad = io_oe  ? ~io_data  : 16'hZZZZ;

    tri1        sync, din, dout, wtbt, rply;
    reg         rply_ext_n;                      // ROM/IO reply (open-collector)
    assign rply = rply_ext_n ? 1'bZ : 1'b0;
    wire        rply037_n;                        // 037 reply (RAM) -> open-collector
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    // SDRAM-domain reset: released early (a few sys_clk), independent of the CPU
    // reset dclo which waits on init_done (mirrors ocbk_top's srst_n vs dclo).
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- address decode -----------------------------------------------------
    reg [15:0] addr;
    reg        sel_ram, sel_rom, sel_io;
    always @(negedge sync) begin
        addr    = ~ad;
        sel_ram = (addr < 16'o100000);
        sel_rom = (addr >= 16'o100000) && (addr < 16'o140000);
        sel_io  = (addr >= 16'o177600);
    end
    always @(posedge sync) begin sel_ram=0; sel_rom=0; sel_io=0; end

    // ---- ROM / I/O (behavioural, on-chip, fixed N_ROM) ----------------------
    reg [15:0] rom [0:8191];
    always @(negedge din) begin
        if (~sync) begin
            if (sel_rom) begin
                rom_data = rom[addr[13:1]];
                repeat (`N_ROM) @(negedge clk);
                rom_oe = 1'b1; rply_ext_n = 1'b0;
            end else if (sel_io) begin
                io_data = (addr == 16'o177716) ? 16'o100000 : 16'o000000;
                repeat (`N_ROM) @(negedge clk);
                io_oe = 1'b1; rply_ext_n = 1'b0;
            end
        end
    end
    always @(posedge din or posedge dout) begin
        @(negedge clk); rply_ext_n = 1'b1; @(posedge clk); rom_oe=0; io_oe=0;
    end

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

    // ---- retimed 037 (owns RAM RPLY, done-gate = dp.mem_ready) ---------------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    va_037_sync pr037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready),
        .PIN_R(~dclo), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va)
    );

    // ---- CPU SDRAM datapath (arbiter port 0) --------------------------------
    wire                dp_req, dp_we;
    wire [AB-1:0]       dp_addr;
    wire [DW-1:0]       dp_wdata;
    wire [1:0]          dp_be;
    wire                dp_gnt, dp_rvalid;
    wire [DW-1:0]       arb_rdata;
    wire [15:0]         dp_rdata;
    wire                dp_rdata_oe;
    assign ad = dp_rdata_oe ? ~dp_rdata : 16'hZZZZ;

    cpu_sdram_dp #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_dp (
        .clk(sys_clk), .rst_n(dclo),
        .sync_n(sync), .din_n(din), .dout_n(dout), .wtbt_n(wtbt),
        .sel_ram(sel_ram), .addr(addr), .ad_true(~ad),
        .rdata(dp_rdata), .rdata_oe(dp_rdata_oe), .mem_ready(mem_ready),
        .req(dp_req), .we(dp_we), .addr_o(dp_addr), .wdata_o(dp_wdata), .be_o(dp_be),
        .gnt(dp_gnt), .rvalid(dp_rvalid), .rdata_i(arb_rdata)
    );

    // ---- video fetch requester (arbiter port 2): worst-case streaming reads --
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};   // some RAM word; data dropped
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)              fetch_req <= 1'b0;
        else if (fetch_gnt)     fetch_req <= 1'b0;   // drop on grant (served contract)
        else                    fetch_req <= 1'b1;   // otherwise keep requesting
    end

    // ---- arbiter (port0 = CPU, port2 = fetch; ports 1,3 idle) ---------------
    localparam int NREQ = 4;
    wire [NREQ-1:0] p_req    = {1'b0, fetch_req, 1'b0, dp_req};
    wire [NREQ-1:0] p_we     = {1'b0, 1'b0,      1'b0, dp_we};
    wire [NREQ*AB-1:0] p_addr  = {{AB{1'b0}}, fetch_addr, {AB{1'b0}}, dp_addr};
    wire [NREQ*DW-1:0] p_wdata = {{DW{1'b0}}, {DW{1'b0}}, {DW{1'b0}}, dp_wdata};
    wire [NREQ*2-1:0]  p_be    = {2'b11, 2'b11, 2'b11, dp_be};
    wire [NREQ-1:0] p_gnt, p_rvalid;

    assign dp_gnt       = p_gnt[0];     assign dp_rvalid    = p_rvalid[0];
    assign fetch_gnt    = p_gnt[2];     assign fetch_rvalid = p_rvalid[2];

    wire                cmd_req, cmd_we, cmd_ready, rd_valid;
    wire [AB-1:0]       cmd_addr;
    wire [DW-1:0]       cmd_wdata, rd_data;
    wire [1:0]          cmd_be;
    wire                init_done;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(AB), .DQ_BITS(DW)) u_arb (
        .clk(sys_clk), .rst_n(srst_n),
        .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be),
        .p_gnt(p_gnt), .p_rvalid(p_rvalid), .p_rdata(arb_rdata),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data)
    );

    // ---- SDRAM controller + model -------------------------------------------
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] dq_out, dq_in;  wire dq_oe;
    wire [DW-1:0] s_dq;
    assign s_dq = dq_oe ? dq_out : 'z;
    assign dq_in = s_dq;

    sdram_ctrl #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_ctrl (
        .clk(sys_clk), .rst_n(srst_n),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm),
        .dq_out(dq_out), .dq_oe(dq_oe), .dq_in(dq_in)
    );
    sdram_model u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- timing measurement -------------------------------------------------
    integer    prev_nclk;   reg [15:0] prev_addr;   reg have_baseline;
    integer    loop_n = 0;
    always @(negedge din) begin
        if (~sync && sel_ram && addr >= `TEST_LO && addr < `TEST_HI) begin
            if (have_baseline)
                $display("FETCH %06o cycles=%0d", prev_addr, nclk - prev_nclk);
            if (prev_addr == 16'o001076) loop_n = loop_n + 1;
            if (loop_n == 6) $finish;       // enough self-loop samples captured
            prev_nclk = nclk; prev_addr = addr; have_baseline = 1'b1;
        end
    end

    // ---- program: ROM bootstrap + preload SDRAM with the RAM test program ----
    integer ii;
    initial begin
        for (ii = 0; ii < 8192;  ii = ii + 1) rom[ii] = 16'o000000;
        rom[0] = 16'o000137; rom[1] = 16'o001000;
        for (ii = 0; ii < 16384; ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        u_mem.mem[16'h100] = 16'o012700; u_mem.mem[16'h101] = 16'o002000;
        u_mem.mem[16'h102] = 16'o012701; u_mem.mem[16'h103] = 16'o002000;
        u_mem.mem[16'h104] = 16'o012710; u_mem.mem[16'h105] = 16'o012345;
        u_mem.mem[16'h106] = 16'o010002;
        u_mem.mem[16'h107] = 16'o011002;
        u_mem.mem[16'h108] = 16'o012002;
        u_mem.mem[16'h109] = 16'o012700; u_mem.mem[16'h10A] = 16'o002000;
        u_mem.mem[16'h10B] = 16'o014002;
        u_mem.mem[16'h10C] = 16'o012700; u_mem.mem[16'h10D] = 16'o002000;
        u_mem.mem[16'h10E] = 16'o016002; u_mem.mem[16'h10F] = 16'o000000;
        u_mem.mem[16'h110] = 16'o010011;
        u_mem.mem[16'h111] = 16'o012711; u_mem.mem[16'h112] = 16'o012345;
        u_mem.mem[16'h113] = 16'o010021;
        u_mem.mem[16'h114] = 16'o012701; u_mem.mem[16'h115] = 16'o002000;
        u_mem.mem[16'h116] = 16'o010041;
        u_mem.mem[16'h117] = 16'o012701; u_mem.mem[16'h118] = 16'o002000;
        u_mem.mem[16'h119] = 16'o010061; u_mem.mem[16'h11A] = 16'o000000;
        u_mem.mem[16'h11B] = 16'o005002;
        u_mem.mem[16'h11C] = 16'o000400;
        u_mem.mem[16'h11D] = 16'o012702; u_mem.mem[16'h11E] = 16'o001234;
        u_mem.mem[16'h11F] = 16'o000777;
        u_mem.mem[16'h200] = 16'o012345;
    end

    // ---- reset (wait SDRAM init) + 037 register init + sim limit ------------
    initial begin
        nclk=0; prev_nclk=0; have_baseline=1'b0;
        rom_oe=0; io_oe=0; rply_ext_n=1'b1;
        rom_data=0; io_data=0;
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0;


        wait (init_done); @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #2_000_000;
        $finish;
    end

endmodule
