// qbus_mem_sdram - Strategy-A memory subsystem (Phase 3 SoC integration).
//
// Supersedes qbus_sdram for the integrated top. Under Strategy A the 037
// (va_037_sync) owns RAM RPLY and its cycle-stealing timing; this block provides:
//   * ROM 100000-177577 + I/O on-chip decode, with the fixed N_ROM reply (the 037
//     never sees these - they are outside its DRAM), driving rply_n itself; and
//   * the RAM 000000-077777 DATA path into the board SDRAM through sdram_arbiter +
//     cpu_sdram_dp, producing mem_ready for the 037's RPLY done-gate.
// RAM RPLY is NOT driven here (va_037_sync drives it, gated by mem_ready).
//
// Phase 5 ROM source (rom_ext_en):
//   0 = the on-chip ROM_WORDS image (the boot-fallback / DIP-selected test ROM);
//   1 = ROM reads are served from SDRAM through the same cpu_sdram_dp port-0 path
//       as RAM (linear map: ROM word at SDRAM word addr[15:1] = 0x4000-0x7F7F).
//       The reply keeps the fixed N_ROM count but is done-gated on mem_ready -
//       a late SDRAM word EXTENDS RPLY (mirroring the 037's RAM gate) instead of
//       latching stale data. ROM is not 037-arbitrated (real BK mask ROM is not
//       cycle-stolen); ROM writes are replied to and ignored in both modes (a
//       real BK would bus-timeout -> trap 4; fidelity deferred to Phase 9).
//
// The 037's own registers (177664 scroll) are owned by va_037_sync, the
// keyboard block 177660-177663 by bk_kbd014 (Phase 6, behind the 037's nBS
// decode), and the CPU-internal block 177700-177713 (CSR/error/timer) is
// decoded, replied and data-driven by the 1801ВМ1 itself - all are excluded
// from the I/O decode here to avoid a double reply / bus contention. I/O
// stubs served here:
//   177716 = SYS_START | bit-2 write-flag (set on write, cleared after read;
//            INIT-keyed, as every BK peripheral register) | bit-6 = any-key-
//            down from the keyboard translator, ACTIVE LOW (1 = no key held);
//   all other decoded I/O reads return 0 (BkEmu register semantics).
//
// Domains: the ROM/IO wait-state FSM runs on cpu_clk (fixed N_ROM, as the validated
// qbus_sdram FSM); the datapath/arbiter/controller run on sclk (sys_clk). Bus
// strobes are synchronous to sclk (cpu_clk = sclk/32), so cpu_sdram_dp samples them
// directly. The Phase-4 video clients (readout / 037 fetch / FB write, all sclk
// domain) pass through to arbiter ports 1/2/3 via the v1_*/v2_*/v3_* ports.
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
    input  logic        init_n,     // Q-bus nINIT: peripheral-register reset
    input  logic        kbd_down,   // any-key-held level -> 177716 bit 6 (inverted)
    input  logic        rom_ext_en, // 1 = serve ROM reads from SDRAM (quasi-static)

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

    // ---- boot-writer mux onto arbiter port 0 (sclk domain) ----------------
    // While boot_active the EPCS loader owns port 0 (the CPU is still in DCLO,
    // so cpu_sdram_dp is guaranteed idle) - the external mux reserved in
    // sdram_arbiter.sv; the arbiter itself is unchanged.
    input  logic                 boot_active,
    input  logic                 bw_req,
    input  logic [ADDR_BITS-1:0] bw_addr,
    input  logic [DQ_BITS-1:0]   bw_wdata,
    output logic                 bw_gnt,

    // ---- Phase-4 video clients (sclk domain; arbiter ports 1/2/3) --------
    input  logic                 v1_req,     // [1] panel readout (read-only)
    input  logic [ADDR_BITS-1:0] v1_addr,
    output logic                 v1_gnt,
    output logic                 v1_rvalid,
    input  logic                 v2_req,     // [2] 037 video fetch (read-only)
    input  logic [ADDR_BITS-1:0] v2_addr,
    output logic                 v2_gnt,
    output logic                 v2_rvalid,
    input  logic                 v3_req,     // [3] FB word write
    input  logic [ADDR_BITS-1:0] v3_addr,
    input  logic [DQ_BITS-1:0]   v3_wdata,
    output logic                 v3_gnt,
    output logic [DQ_BITS-1:0]   v_rdata,    // shared arbiter read data

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
    // I/O here excludes the 037's own scroll register (177664, owned by
    // va_037_sync), the keyboard block 177660-177663 (owned by bk_kbd014
    // behind the 037's nBS window - same [15:2] compare) and the CPU-internal
    // block 177700-177713 (the 1801ВМ1 replies and drives data for those
    // itself - an external reply/drive there is a bus fight; MONITOR touches
    // the internal timer constantly).
    wire sel_io  = !sync_n && (addr >= IO_BASE) && (addr != 16'o177664)
                           && (addr[15:2] != (16'o177660 >> 2))
                           && !((addr >= CPUREG_LO) && (addr <= CPUREG_HI));

    // ROM source select: external (SDRAM via cpu_sdram_dp) vs on-chip image.
    wire sel_romx = sel_rom && rom_ext_en;      // SDRAM-backed ROM access

    // ---- ROM / I/O read data --------------------------------------------
    logic sel1_wflag;   // 177716 bit 2: set on write, cleared after read

    wire [15:0]        rom_off = addr - RAM_TOP;
    wire [ROM_AW-1:0]  rom_idx = rom_off[ROM_AW:1];
    wire               rom_hit = (rom_off[15:1] < ROM_WORDS);
    wire [15:0] rom_word = rom_hit ? rom[rom_idx] : 16'o000000;
    wire [15:0] io_word  =
        (addr == REG_SYS) ? (SYS_START | (sel1_wflag ? 16'o000004 : 16'o0)
                                       | (kbd_down   ? 16'o0 : 16'o000100)) :
        16'o000000;
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
        .sel_ram(sel_ram), .sel_romr(sel_romx), .addr(addr), .ad_true(~ad_n),
        .rdata(ram_rdata), .rdata_oe(ram_rdata_oe), .mem_ready(mem_ready),
        .req(dp_req), .we(dp_we), .addr_o(dp_addr), .wdata_o(dp_wdata), .be_o(dp_be),
        .gnt(dp_gnt), .rvalid(dp_rvalid), .rdata_i(arb_rdata)
    );

    // Boot-writer mux: during boot the EPCS loader is port 0 (word writes only).
    wire                 p0_req   = boot_active ? bw_req   : dp_req;
    wire                 p0_we    = boot_active ? 1'b1     : dp_we;
    wire [ADDR_BITS-1:0] p0_addr  = boot_active ? bw_addr  : dp_addr;
    wire [DQ_BITS-1:0]   p0_wdata = boot_active ? bw_wdata : dp_wdata;
    wire [1:0]           p0_be    = boot_active ? 2'b11    : dp_be;

    // Arbiter ports: [0] = CPU (highest); [1] readout, [2] 037 fetch, [3] FB write.
    wire [NREQ-1:0]           p_req    = {v3_req,  v2_req,  v1_req,  p0_req};
    wire [NREQ-1:0]           p_we     = {1'b1,    1'b0,    1'b0,    p0_we};
    wire [NREQ*ADDR_BITS-1:0] p_addr   = {v3_addr, v2_addr, v1_addr, p0_addr};
    wire [NREQ*DQ_BITS-1:0]   p_wdata  = {v3_wdata, {(2*DQ_BITS){1'b0}}, p0_wdata};
    wire [NREQ*2-1:0]         p_be     = { 6'b111111, p0_be };
    wire [NREQ-1:0]           p_gnt, p_rvalid;
    assign dp_gnt    = p_gnt[0] & ~boot_active;
    assign bw_gnt    = p_gnt[0] &  boot_active;
    assign dp_rvalid = p_rvalid[0];
    assign v1_gnt    = p_gnt[1];
    assign v1_rvalid = p_rvalid[1];
    assign v2_gnt    = p_gnt[2];
    assign v2_rvalid = p_rvalid[2];
    assign v3_gnt    = p_gnt[3];
    assign v_rdata   = arb_rdata;

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
    logic        dbg_romgate;   // diagnostic: an external-ROM read RPLY was extended
                                // past the fixed N_ROM count (sim observability only)

    wire selected = sel_rom | sel_io;
    wire is_read  = !din_n;
    wire is_write = !dout_n;

    always_ff @(posedge cpu_clk) begin
        fetch_stb <= 1'b0;
        if (reset) begin
            state <= S_IDLE; drive_data <= 1'b0; reply <= 1'b0; wcnt <= '0;
            dbg_romgate <= 1'b0;
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
                        if (sel_romx && is_read && !mem_ready) begin
                            // done-gate: the SDRAM ROM word is late - hold RPLY
                            // (extends the cycle) instead of replying over stale
                            // data. Should never happen at BK clock rates; the
                            // ROM-region golden diff catches it if it does.
                            dbg_romgate <= 1'b1;
                        end else begin
                            reply <= 1'b1;
                            if (is_read) begin
                                rdata      <= rd_romio;
                                drive_data <= !sel_romx;   // SDRAM ROM data: u_dp drives
                                fetch_stb  <= 1'b1;
                            end
                            // I/O register side effects at the reply point (BkEmu
                            // semantics; rdata latched above still sees the old flag)
                            if (sel_io && addr == REG_SYS)
                                sel1_wflag <= is_write;    // set on write, clear on read
                            state <= S_REPLY;
                        end
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
        // Peripheral-register INIT semantics (real-BK reset wiring rule): the
        // 177716 write-flag resets on the nINIT line - asserted through the
        // CPU's own reset AND pulsed by the RESET instruction - never on DCLO.
        // Placed after the FSM case so INIT wins over the reply-point update.
        if (!init_n) sel1_wflag <= 1'b0;
    end

    // ---- Q-bus drivers (inverted; open-collector rply) -------------------
    // ad_n carries ROM/IO read data (this FSM) or RAM read data (datapath).
    assign ad_n   = drive_data   ? ~rdata     : 16'hZZZZ;
    assign ad_n   = ram_rdata_oe ? ~ram_rdata : 16'hZZZZ;
    assign rply_n = reply        ? 1'b0       : 1'bZ;

endmodule
