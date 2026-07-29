// qbus_sdram - Q-bus memory slave with BK RAM in SDRAM.
//
// RETIRED FROM THE BUILD. It is superseded by qbus_mem (+ va_037_sync +
// cpu_sdram_dp), which owns the shipped memory path, and it is deliberately
// absent from ocbk_common.qsf. It is kept in the tree only so its standalone
// cosim (sim/run_sdram_cosim.sh) still runs - that oracle verifies the
// word/byte SDRAM datapath and the deterministic RPLY against real values,
// which the timing goldens do not. Do not wire it into the top level.
//
// This slave keeps ROM and I/O on-chip and puts only the RAM region
// (000000-077777) in the board SDRAM; the cycle-faithful deterministic-RPLY
// front-end is the same shape qbus_mem inherited.
//
// Memory map (true polarity, octal):
//   RAM 000000-077777 : SDRAM, via the embedded sdram_ctrl (word/byte writes)
//   ROM 100000-177577 : on-chip block RAM, init from MEMFILE (word 0 = 100000)
//   I/O 177716        : system register -> 100000 (boot from ROM); else 0
//
// Two clock domains:
//   clk  = cpu_clk_n (~3 MHz inverted CPU clock). The wait-state FSM counts CPU
//          cycles here, so RPLY lands exactly N_RAM/N_ROM cycles after DIN/DOUT,
//          reproducing the bk10 reference timing (the headline goal).
//   sclk = sys_clk (96.65 MHz). The SDRAM controller and the request adapter run
//          here. The latency is hidden as long as a worst-case SDRAM access
//          (~16-20 sclk ~= 200 ns, incl. a refresh collision) finishes within the
//          RPLY window = (N_RAM-2) CPU clocks. At 3.02 MHz (sys_clk/32) that
//          window is ~660 ns (~3x margin). This standalone slave is only ever
//          run at that rate by its cosim; the shipped path (qbus_mem) handles
//          the faster rates with an explicit mem_ready done-gate instead of a
//          margin argument, so a late word extends RPLY rather than being
//          latched stale.
//
// CDC: a RAM access is launched the moment the FSM accepts the transaction, via a
// request *toggle* synchronised into the sclk domain (2-FF + edge detect). The
// adapter performs the access and latches read data into sdram_rdata. Because the
// access finishes long before the FSM's wait counter expires, the slow FSM samples
// sdram_rdata directly at RPLY time as a quasi-static value (stable by then). The
// request payload (addr/data/be) and sdram_rdata are held stable across the whole
// transaction; the SDC declares them false paths. (Nothing contends the SDRAM in
// this slave's cosim, so the ~3x margin holds by construction. The shipped
// qbus_mem path, which IS contended by the video clients, does not rely on that
// - see its mem_ready done-gate.)
//
// All Q-bus lines are inverted / active-low; ad_n carries ~data, rply_n is
// open-collector (driven 0 to reply, released Z otherwise).
module qbus_sdram #(
    parameter         MEMFILE     = "mem/ram_test.hex",   // ROM image (word 0 = 100000)
    parameter integer ROM_WORDS   = 256,                  // 100000.. backed on-chip
    parameter int     CLK_FREQ_HZ = 96_650_000,
    parameter int     ROW_BITS    = 13,
    parameter int     COL_BITS    = 9,
    parameter int     BA_BITS     = 2,
    parameter int     DQ_BITS     = 16,
    parameter int     CAS_LATENCY = 2,
    parameter int     ADDR_BITS   = BA_BITS + ROW_BITS + COL_BITS
) (
    // ---- slow domain (CPU clock) ----------------------------------------
    input  logic        clk,        // = pin_clk_n (inverted CPU clock)
    input  logic        reset,      // synchronous reset, active high (~dclo_n)

    // ---- SDRAM domain ---------------------------------------------------
    input  logic        sclk,       // = sys_clk (96.65 MHz)
    input  logic        srst_n,     // SDRAM-domain reset, active low (PLL locked)
    output logic        init_done,  // SDRAM initialisation complete

    // ---- Q-bus (inverted, active low) -----------------------------------
    inout  wire  [15:0] ad_n,
    input  logic        sync_n,
    input  logic        din_n,
    input  logic        dout_n,
    input  logic        wtbt_n,
    output wire         rply_n,

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

    // ---- bus-activity taps (true polarity) ------------------------------
    output wire  [15:0] bus_addr,   // last latched bus address
    output logic        fetch_stb   // 1-cycle pulse on each read transaction
);

    import qbus_pkg::*;

    localparam int unsigned ROM_AW = $clog2(ROM_WORDS);

    // -------------------------------------------------------------------------
    // On-chip ROM (synchronous block RAM, single source of truth via $readmemh).
    // Word 0 corresponds to BK address 100000.
    // -------------------------------------------------------------------------
    logic [15:0] rom [0:ROM_WORDS-1];
    initial $readmemh(MEMFILE, rom);

    // -------------------------------------------------------------------------
    // Address latch: transparent on the SYNC strobe (closes on its falling edge),
    // exactly as qbus_mem / real multiplexed-bus peripherals. SYNC is a slow,
    // logic-derived clock; the SDC declares and cuts it.
    // -------------------------------------------------------------------------
    // NB: WTBT is dual-purpose on the Q-bus - asserted at SYNC time it flags a
    // WRITE cycle (not a byte op), and asserted at DOUT time it flags a BYTE op.
    // So only the address is latched here; the byte indicator is sampled live at
    // the write point (see be_w below), never from this SYNC-phase WTBT.
    logic [15:0] addr;
    always_ff @(negedge sync_n) begin
        addr <= ~ad_n;
    end

    wire sel_ram = !sync_n && (addr <  RAM_TOP);
    wire sel_rom = !sync_n && (addr >= RAM_TOP) && (addr < IO_BASE);
    wire sel_io  = !sync_n && (addr >= IO_BASE);

    assign bus_addr = addr;

    // -------------------------------------------------------------------------
    // ROM / I/O read data (combinational over latched address)
    // -------------------------------------------------------------------------
    wire [15:0]        rom_off = addr - RAM_TOP;
    wire [ROM_AW-1:0]  rom_idx = rom_off[ROM_AW:1];
    wire               rom_hit = (rom_off[15:1] < ROM_WORDS);
    wire [15:0] rom_word = rom_hit ? rom[rom_idx] : 16'o000000;
    wire [15:0] io_word  = (addr == REG_SYS) ? SYS_START : 16'o000000;
    wire [15:0] rd_romio = sel_rom ? rom_word : io_word;

    // =========================================================================
    // SDRAM request adapter (sclk domain)
    // =========================================================================
    // Synchronise the slow-domain request toggle and edge-detect a new access.
    logic req_tog;                         // slow-domain: toggled per RAM access
    logic req_meta, req_s, req_s_d;        // sclk-domain synchroniser + edge delay
    always_ff @(posedge sclk or negedge srst_n) begin
        if (!srst_n) {req_meta, req_s, req_s_d} <= '0;
        else         {req_meta, req_s, req_s_d} <= {req_tog, req_meta, req_s};
    end
    wire req_edge = req_s ^ req_s_d;

    // Slow-domain request payload (held stable for the whole transaction; the SDC
    // false-paths these into the sclk domain).
    logic                  req_we;
    logic [ADDR_BITS-1:0]  req_waddr;
    logic [DQ_BITS-1:0]    req_wdata;
    logic [1:0]            req_be;

    // sdram_ctrl command port + captured read data.
    logic                  cmd_req, cmd_we;
    logic [ADDR_BITS-1:0]  cmd_addr;
    logic [DQ_BITS-1:0]    cmd_wdata;
    logic [1:0]            cmd_be;
    logic                  cmd_ready, rd_valid;
    logic [DQ_BITS-1:0]    rd_data;
    logic [DQ_BITS-1:0]    sdram_rdata;     // last read word (sampled by slow FSM)

    typedef enum logic [1:0] { A_IDLE, A_WR, A_RD_REQ, A_RD_WAIT } astate_t;
    astate_t astate;

    always_ff @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            astate      <= A_IDLE;
            cmd_req     <= 1'b0;
            cmd_we      <= 1'b0;
            cmd_addr    <= '0;
            cmd_wdata   <= '0;
            cmd_be      <= 2'b11;
            sdram_rdata <= '0;
        end else begin
            case (astate)
                A_IDLE: begin
                    cmd_req <= 1'b0;
                    if (req_edge) begin
                        cmd_we    <= req_we;
                        cmd_addr  <= req_waddr;
                        cmd_wdata <= req_wdata;
                        cmd_be    <= req_be;
                        cmd_req   <= 1'b1;
                        if (req_we) astate <= A_WR;
                        else        astate <= A_RD_REQ;
                    end
                end
                A_WR: begin
                    if (cmd_ready) begin    // write accepted
                        cmd_req <= 1'b0;
                        astate  <= A_IDLE;
                    end
                end
                A_RD_REQ: begin
                    if (cmd_ready) begin    // read accepted
                        cmd_req <= 1'b0;
                        astate  <= A_RD_WAIT;
                    end
                end
                A_RD_WAIT: begin
                    if (rd_valid) begin
                        sdram_rdata <= rd_data;
                        astate      <= A_IDLE;
                    end
                end
                default: astate <= A_IDLE;
            endcase
        end
    end

    // SDRAM data bus tri-state (open-drain on the physical DQ pins).
    wire [DQ_BITS-1:0] dq_out, dq_in;
    wire               dq_oe;
    assign s_dq  = dq_oe ? dq_out : {DQ_BITS{1'bz}};
    assign dq_in = s_dq;

    sdram_ctrl #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ), .ROW_BITS (ROW_BITS), .COL_BITS (COL_BITS),
        .BA_BITS (BA_BITS), .DQ_BITS (DQ_BITS), .CAS_LATENCY (CAS_LATENCY)
    ) u_ctrl (
        .clk (sclk), .rst_n (srst_n),
        .cmd_req (cmd_req), .cmd_we (cmd_we), .cmd_addr (cmd_addr),
        .cmd_wdata (cmd_wdata), .cmd_be (cmd_be), .cmd_ready (cmd_ready),
        .rd_valid (rd_valid), .rd_data (rd_data), .init_done (init_done),
        .s_cke (s_cke), .s_cs_n (s_cs_n), .s_ras_n (s_ras_n), .s_cas_n (s_cas_n),
        .s_we_n (s_we_n), .s_ba (s_ba), .s_addr (s_addr), .s_dqm (s_dqm),
        .dq_out (dq_out), .dq_oe (dq_oe), .dq_in (dq_in)
    );

    // =========================================================================
    // Wait-state FSM (slow domain; advances on pin_clk_n, as in qbus_mem)
    // =========================================================================
    typedef enum logic [1:0] { S_IDLE, S_WAIT, S_REPLY } state_t;
    state_t state;

    logic [2:0]  wcnt;
    logic        drive_data;
    logic        reply;
    logic [15:0] rdata;

    wire       selected = sel_ram | sel_rom | sel_io;
    wire       is_read  = !din_n;
    wire       is_write = !dout_n;
    // A load of N-2 lands the reply exactly N slave cycles after the strobe
    // (matching the reference model), with the read/write decision still sampled
    // while the CPU holds DIN/DOUT asserted.
    wire [2:0] wait_n   = sel_ram ? (N_RAM-2) : (N_ROM-2);

    // Byte-enable for the SDRAM write, decided at the write point: WTBT asserted
    // during DOUT => byte op (only the addressed byte); otherwise the whole word.
    // Read data is always the full word.
    wire       byte_op = ~wtbt_n;                         // valid during DOUT
    wire [1:0] be_w    = byte_op ? (addr[0] ? 2'b10 : 2'b01) : 2'b11;

    always_ff @(posedge clk) begin
        fetch_stb <= 1'b0;
        if (reset) begin
            state      <= S_IDLE;
            drive_data <= 1'b0;
            reply      <= 1'b0;
            wcnt       <= '0;
            req_tog    <= 1'b0;
            req_we     <= 1'b0;
            req_waddr  <= '0;
            req_wdata  <= '0;
            req_be     <= 2'b11;
        end else begin
            unique case (state)
                S_IDLE: begin
                    drive_data <= 1'b0;
                    reply      <= 1'b0;
                    if (!sync_n && selected && (is_read || is_write)) begin
                        wcnt <= wait_n[2:0];
                        // Launch the SDRAM *read* now (only the latched address is
                        // needed) so its data is back well before RPLY. Writes wait
                        // for the reply point, where the bus data is stable.
                        if (sel_ram && is_read) begin
                            req_we    <= 1'b0;
                            req_waddr <= ADDR_BITS'(addr[15:1]);
                            req_be    <= 2'b11;
                            req_tog   <= ~req_tog;
                        end
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (wcnt == 0) begin
                        reply <= 1'b1;                  // assert RPLY
                        if (is_read) begin
                            rdata      <= sel_ram ? sdram_rdata : rd_romio;
                            drive_data <= 1'b1;
                            fetch_stb  <= 1'b1;
                        end else if (is_write && sel_ram) begin
                            // Bus write data is stable now; capture and launch the
                            // SDRAM write. It completes long before the next access.
                            req_we    <= 1'b1;
                            req_waddr <= ADDR_BITS'(addr[15:1]);
                            req_wdata <= ~ad_n;
                            req_be    <= be_w;
                            req_tog   <= ~req_tog;
                        end
                        state <= S_REPLY;
                    end else begin
                        wcnt <= wcnt - 1'b1;
                    end
                end
                S_REPLY: begin
                    // Hold RPLY + data until the CPU drops the strobe, then release.
                    if (din_n && dout_n) begin
                        reply      <= 1'b0;
                        drive_data <= 1'b0;
                        state      <= S_IDLE;
                    end
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Q-bus drivers (inverted polarity; open-collector RPLY)
    // -------------------------------------------------------------------------
    assign ad_n   = drive_data ? ~rdata : 16'hZZZZ;
    assign rply_n = reply      ? 1'b0   : 1'bZ;

endmodule
