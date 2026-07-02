// qbus_mem_sdram - Strategy-A memory subsystem (Phase 3 SoC integration).
//
// Supersedes qbus_sdram for the integrated top. Under Strategy A the 037
// (va_037_sync) owns RAM RPLY and its cycle-stealing timing; this block provides:
//   * ROM 100000-137777 + I/O 177716 on-chip, with the fixed N_ROM reply (the 037
//     never sees these - they are outside its DRAM), driving rply_n itself; and
//   * the RAM 000000-077777 DATA path into the board SDRAM through sdram_arbiter +
//     cpu_sdram_dp, producing mem_ready for the 037's RPLY done-gate.
// RAM RPLY is NOT driven here (va_037_sync drives it, gated by mem_ready).
//
// The 037's own registers (177664 scroll) are owned by va_037_sync, so they are
// excluded from the I/O decode here to avoid a double reply.
//
// Domains: the ROM/IO wait-state FSM runs on cpu_clk (fixed N_ROM, as the validated
// qbus_sdram FSM); the datapath/arbiter/controller run on sclk (sys_clk). Bus
// strobes are synchronous to sclk (cpu_clk = sclk/32), so cpu_sdram_dp samples them
// directly. Spare arbiter ports (readout / video fetch / FB write) are tied off here
// for Phase 3 and exposed in Phase 4.
module qbus_mem_sdram #(
    parameter         MEMFILE     = "mem/ram_test.hex",
    parameter integer ROM_WORDS   = 256,
    parameter int     CLK_FREQ_HZ = 96_650_000,
    parameter int     ROW_BITS    = 13,
    parameter int     COL_BITS    = 9,
    parameter int     BA_BITS     = 2,
    parameter int     DQ_BITS     = 16,
    parameter int     CAS_LATENCY = 2,
    parameter int     ADDR_BITS   = BA_BITS + ROW_BITS + COL_BITS
) (
    // ---- slow domain (CPU clock) ----------------------------------------
    input  logic        cpu_clk,    // ROM/IO wait FSM clock (= pin_clk_n)
    input  logic        reset,      // active high (= ~dclo_n)

    // ---- SDRAM domain ---------------------------------------------------
    input  logic        sclk,       // sys_clk (96.65 MHz)
    input  logic        srst_n,     // SDRAM-domain reset (PLL locked), active low
    output logic        init_done,

    // ---- Q-bus (inverted, active low) -----------------------------------
    inout  wire  [15:0] ad_n,
    input  logic        sync_n,
    input  logic        din_n,
    input  logic        dout_n,
    input  logic        wtbt_n,
    output wire         rply_n,     // open-collector; ROM/IO only (RAM = va_037_sync)
    output logic        mem_ready,  // RAM SDRAM access complete -> 037 done-gate

    // ---- SDRAM device pins ----------------------------------------------
    output logic                s_cke,
    output logic                s_cs_n,
    output logic                s_ras_n,
    output logic                s_cas_n,
    output logic                s_we_n,
    output logic [BA_BITS-1:0]  s_ba,
    output logic [ROW_BITS-1:0] s_addr,
    output logic [1:0]          s_dqm,
    inout  wire  [DQ_BITS-1:0]  s_dq,

    // ---- bus-activity taps ----------------------------------------------
    output wire  [15:0] bus_addr,
    output logic        fetch_stb
);

    import qbus_pkg::*;
    localparam int unsigned ROM_AW = $clog2(ROM_WORDS);

    // ---- on-chip ROM ----------------------------------------------------
    logic [15:0] rom [0:ROM_WORDS-1];
    initial $readmemh(MEMFILE, rom);

    // ---- address latch (transparent on SYNC; slow logic clock, SDC-cut) --
    logic [15:0] addr;
    always_ff @(negedge sync_n) addr <= ~ad_n;
    assign bus_addr = addr;

    wire sel_ram = !sync_n && (addr <  RAM_TOP);
    wire sel_rom = !sync_n && (addr >= RAM_TOP) && (addr < IO_BASE);
    // I/O here excludes the 037's own scroll register (177664), owned by va_037_sync.
    wire sel_io  = !sync_n && (addr >= IO_BASE) && (addr != 16'o177664);

    // ---- ROM / I/O read data --------------------------------------------
    wire [15:0]        rom_off = addr - RAM_TOP;
    wire [ROM_AW-1:0]  rom_idx = rom_off[ROM_AW:1];
    wire               rom_hit = (rom_off[15:1] < ROM_WORDS);
    wire [15:0] rom_word = rom_hit ? rom[rom_idx] : 16'o000000;
    wire [15:0] io_word  = (addr == REG_SYS) ? SYS_START : 16'o000000;
    wire [15:0] rd_romio = sel_rom ? rom_word : io_word;

    // =====================================================================
    // RAM datapath: cpu_sdram_dp -> sdram_arbiter (port 0) -> sdram_ctrl
    // =====================================================================
    localparam int NREQ = 4;

    wire                dp_req, dp_we;
    wire [ADDR_BITS-1:0] dp_addr;
    wire [DQ_BITS-1:0]   dp_wdata;
    wire [1:0]           dp_be;
    wire                 dp_gnt, dp_rvalid;
    wire [DQ_BITS-1:0]   arb_rdata;
    wire [15:0]          ram_rdata;
    wire                 ram_rdata_oe;

    cpu_sdram_dp #(.ADDR_BITS(ADDR_BITS), .DQ_BITS(DQ_BITS)) u_dp (
        .clk(sclk), .rst_n(~reset),
        .sync_n(sync_n), .din_n(din_n), .dout_n(dout_n), .wtbt_n(wtbt_n),
        .sel_ram(sel_ram), .addr(addr), .ad_true(~ad_n),
        .rdata(ram_rdata), .rdata_oe(ram_rdata_oe), .mem_ready(mem_ready),
        .req(dp_req), .we(dp_we), .addr_o(dp_addr), .wdata_o(dp_wdata), .be_o(dp_be),
        .gnt(dp_gnt), .rvalid(dp_rvalid), .rdata_i(arb_rdata)
    );

    // Arbiter ports: [0] = CPU; [1] readout, [2] 037 fetch, [3] FB write (Phase 4).
    wire [NREQ-1:0]           p_req    = {3'b000, dp_req};
    wire [NREQ-1:0]           p_we     = {3'b000, dp_we};
    wire [NREQ*ADDR_BITS-1:0] p_addr   = { {(3*ADDR_BITS){1'b0}}, dp_addr };
    wire [NREQ*DQ_BITS-1:0]   p_wdata  = { {(3*DQ_BITS){1'b0}},   dp_wdata };
    wire [NREQ*2-1:0]         p_be     = { 6'b111111, dp_be };
    wire [NREQ-1:0]           p_gnt, p_rvalid;
    assign dp_gnt    = p_gnt[0];
    assign dp_rvalid = p_rvalid[0];

    wire                 cmd_req, cmd_we, cmd_ready, rd_valid;
    wire [ADDR_BITS-1:0] cmd_addr;
    wire [DQ_BITS-1:0]   cmd_wdata, rd_data;
    wire [1:0]           cmd_be;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(ADDR_BITS), .DQ_BITS(DQ_BITS)) u_arb (
        .clk(sclk), .rst_n(srst_n),
        .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be),
        .p_gnt(p_gnt), .p_rvalid(p_rvalid), .p_rdata(arb_rdata),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data)
    );

    wire [DQ_BITS-1:0] dq_out, dq_in;
    wire               dq_oe;
    assign s_dq  = dq_oe ? dq_out : {DQ_BITS{1'bz}};
    assign dq_in = s_dq;

    sdram_ctrl #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .BA_BITS(BA_BITS), .DQ_BITS(DQ_BITS), .CAS_LATENCY(CAS_LATENCY)
    ) u_ctrl (
        .clk(sclk), .rst_n(srst_n),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm),
        .dq_out(dq_out), .dq_oe(dq_oe), .dq_in(dq_in)
    );

    // =====================================================================
    // ROM / I/O wait-state FSM (cpu_clk domain; fixed N_ROM reply)
    // =====================================================================
    typedef enum logic [1:0] { S_IDLE, S_WAIT, S_REPLY } state_t;
    state_t state;

    logic [2:0]  wcnt;
    logic        drive_data, reply;
    logic [15:0] rdata;

    wire selected = sel_rom | sel_io;
    wire is_read  = !din_n;
    wire is_write = !dout_n;

    always_ff @(posedge cpu_clk) begin
        fetch_stb <= 1'b0;
        if (reset) begin
            state <= S_IDLE; drive_data <= 1'b0; reply <= 1'b0; wcnt <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    drive_data <= 1'b0;
                    reply      <= 1'b0;
                    if (!sync_n && selected && (is_read || is_write)) begin
                        wcnt  <= 3'(N_ROM-2);
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (wcnt == 0) begin
                        reply <= 1'b1;
                        if (is_read) begin
                            rdata      <= rd_romio;
                            drive_data <= 1'b1;
                            fetch_stb  <= 1'b1;
                        end
                        state <= S_REPLY;
                    end else
                        wcnt <= wcnt - 1'b1;
                end
                S_REPLY: begin
                    if (din_n && dout_n) begin
                        reply <= 1'b0; drive_data <= 1'b0; state <= S_IDLE;
                    end
                end
            endcase
        end
    end

    // ---- Q-bus drivers (inverted; open-collector rply) -------------------
    // ad_n carries ROM/IO read data (this FSM) or RAM read data (datapath).
    assign ad_n   = drive_data   ? ~rdata     : 16'hZZZZ;
    assign ad_n   = ram_rdata_oe ? ~ram_rdata : 16'hZZZZ;
    assign rply_n = reply        ? 1'b0       : 1'bZ;

endmodule
