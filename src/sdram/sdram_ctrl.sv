// sdram_ctrl - minimal single-word SDRAM controller.
//
// 1801VM1 does byte-granular writes (MOVB / the Q-bus WTBT byte path), so the user port
// gains a 2-bit cmd_be (byte-enable, 1 = write that byte) which drives the
// chip's UDQM/LDQM on the WRITE command. Reads always fetch the whole word.
//
// Closed-page policy: every access is ACTIVATE -> READ/WRITE with auto-precharge
// (A10=1), so banks are always left precharged and an AUTO REFRESH can be issued
// at any idle moment.
//
// All timing (power-up wait, tRP/tRCD/tRFC, refresh interval) is derived from
// CLK_FREQ_HZ, so the same RTL works unchanged at every clock preset. The derived
// cycle counts are ceil-rounded and used as *minimum* wait lengths; the FSM may
// wait a cycle or two longer, which is always timing-safe.
//
// Command interface (req/ready handshake): assert cmd_req with cmd_we/cmd_addr/
// cmd_wdata/cmd_be; the request is accepted on any cycle where cmd_ready is also
// high. For reads, rd_data/rd_valid pulse CAS_LATENCY+ cycles later.
module sdram_ctrl #(
    parameter int CLK_FREQ_HZ = 96_650_000,  // SDRAM clock (Hz); sets all timing
    parameter int ROW_BITS    = 13,
    parameter int COL_BITS    = 9,
    parameter int BA_BITS     = 2,
    parameter int DQ_BITS     = 16,
    parameter int CAS_LATENCY = 2,
    parameter int ADDR_BITS   = BA_BITS + ROW_BITS + COL_BITS
) (
    input  logic                 clk,
    input  logic                 rst_n,
    // User command port
    input  logic                 cmd_req,
    input  logic                 cmd_we,     // 1 = write, 0 = read
    input  logic [ADDR_BITS-1:0] cmd_addr,   // {bank, row, col}
    input  logic [DQ_BITS-1:0]   cmd_wdata,
    input  logic [1:0]           cmd_be,     // write byte-enable {high, low}, 1=write
    output logic                 cmd_ready,  // high when a request can be accepted
    output logic                 rd_valid,
    output logic [DQ_BITS-1:0]   rd_data,
    output logic                 init_done,
    // SDRAM device signals
    output logic                 s_cke,
    output logic                 s_cs_n,
    output logic                 s_ras_n,
    output logic                 s_cas_n,
    output logic                 s_we_n,
    output logic [BA_BITS-1:0]   s_ba,
    output logic [ROW_BITS-1:0]  s_addr,
    output logic [1:0]           s_dqm,      // {UDQM, LDQM}
    output logic [DQ_BITS-1:0]   dq_out,
    output logic                 dq_oe,      // 1 = drive dq_out onto the bus (writes)
    input  logic [DQ_BITS-1:0]   dq_in
);

    // --- Derived timing (cycles, ceil-rounded from CLK_FREQ_HZ) --------------
    // ns_to_cyc(ns) = ceil(ns * f / 1e9), evaluated in 64-bit to avoid overflow
    // (200 us * ~100 MHz needs more than 32 bits).
    function automatic int ns_to_cyc(input int ns);
        ns_to_cyc = int'((longint'(ns) * CLK_FREQ_HZ + 1_000_000_000 - 1)
                         / 1_000_000_000);
    endfunction

    localparam int INIT_CYC = ns_to_cyc(200_000);          // 200 us power-up wait
    localparam int TRP_CYC  = (ns_to_cyc(20) < 2) ? 2 : ns_to_cyc(20);   // precharge
    localparam int TRCD_CYC = (ns_to_cyc(20) < 2) ? 2 : ns_to_cyc(20);   // act->rw
    localparam int TRFC_CYC = (ns_to_cyc(70) < 4) ? 4 : ns_to_cyc(70);   // refresh
    localparam int TWR_CYC  = (ns_to_cyc(15) < 2) ? 2 : ns_to_cyc(15);   // write rec.
    localparam int TMRD_CYC = 3;                           // load-mode -> ready
    localparam int REFI_CYC = ns_to_cyc(7_800);            // avg refresh interval
    localparam int NUM_INIT_REF = 8;                       // refreshes during init
    localparam int RW_RD_WAIT = CAS_LATENCY + TRP_CYC + 1; // read access span
    localparam int RW_WR_WAIT = TWR_CYC + TRP_CYC;         // write access span

    // --- Command encoding {cs_n, ras_n, cas_n, we_n} ------------------------
    localparam logic [3:0] CMD_NOP   = 4'b0111;
    localparam logic [3:0] CMD_ACT   = 4'b0011;
    localparam logic [3:0] CMD_READ  = 4'b0101;
    localparam logic [3:0] CMD_WRITE = 4'b0100;
    localparam logic [3:0] CMD_PRE   = 4'b0010;
    localparam logic [3:0] CMD_REF   = 4'b0001;
    localparam logic [3:0] CMD_LMR   = 4'b0000;

    // A10 high = precharge-all (PRE) / auto-precharge (READ/WRITE)
    localparam logic [ROW_BITS-1:0] A10_HIGH = (ROW_BITS'(1) << 10);
    // Mode register: BL=1, sequential, CL=CAS_LATENCY, single-location writes (A9=1)
    localparam logic [ROW_BITS-1:0] MODE_REG =
        (ROW_BITS'(1) << 9) | (ROW_BITS'(CAS_LATENCY) << 4);

    // --- Latched request ----------------------------------------------------
    logic [COL_BITS-1:0] req_col;
    logic [ROW_BITS-1:0] req_row;
    logic [BA_BITS-1:0]  req_ba;
    logic                req_we;
    logic [DQ_BITS-1:0]  req_data;
    logic [1:0]          req_be;

    // --- FSM ----------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_INIT_WAIT, ST_PRE_ALL, ST_REF, ST_REF_WAIT, ST_LMR_WAIT,
        ST_IDLE, ST_ACT, ST_RW, ST_RW_WAIT
    } state_t;
    state_t state;

    localparam int WCW = $clog2(INIT_CYC+1);   // init_cnt width (covers 200 us wait)
    localparam int RFW = $clog2(REFI_CYC+1);   // refi_tmr width

    // Two wait counters, on purpose. The 200 us power-up wait needs 15 bits, but
    // its `== 0` compare feeds ONLY a state transition. Every OTHER wait is tiny
    // (<= TRFC), yet its `== 0` compare fans into the SDRAM output registers
    // (s_addr / s_dqm / dq_out / cmd - I/O regs placed out in the ring). Sharing
    // one 15-bit `wait_cnt == 0` for both put a 15-input comparator on those
    // output-setup paths - the sys_clk-critical, placement-marginal path called
    // out in ocbk.qsf. Splitting them makes the runtime compare ~3-bit while the
    // wide compare stays off every output. Cycle behaviour is bit-identical:
    // same load values, same decrements.
    localparam int RM0    = (TRP_CYC     > TRCD_CYC) ? TRP_CYC     : TRCD_CYC;
    localparam int RM1    = (TRFC_CYC    > TMRD_CYC) ? TRFC_CYC    : TMRD_CYC;
    localparam int RM2    = (RW_RD_WAIT  > RW_WR_WAIT)? RW_RD_WAIT : RW_WR_WAIT;
    localparam int RM01   = (RM0 > RM1) ? RM0 : RM1;
    localparam int RUN_MAX= (RM01 > RM2) ? RM01 : RM2;   // longest runtime wait
    localparam int WW     = $clog2(RUN_MAX+1);
    logic [WCW-1:0] init_cnt;    // ST_INIT_WAIT only (wide; gates a state only)
    logic [WW-1:0]  wait_cnt;    // all runtime waits (narrow; off the output regs)
    // ...and the SAME argument one step further. Narrowing the counter was not
    // enough: `wait_cnt == 0` still sat INSIDE the enable cone of s_addr / s_dqm
    // / dq_out, which are I/O-ring registers, so the compare paid the full
    // logic->ring routing delay and the cone stayed the design's setup-critical
    // one. wait_zero carries the same predicate in a FLOP, computed on the load
    // path (`== 1` before the decrement, a compile-time constant on every load),
    // so the output registers see one register output and nothing else.
    // Cycle behaviour is bit-identical BY CONSTRUCTION: every wait_cnt
    // assignment below has a mirrored wait_zero assignment, so the invariant
    // wait_zero == (wait_cnt == 0) holds on every clock. Keep them paired.
    logic           wait_zero;
    logic [3:0]     ref_cnt;     // init-refresh countdown
    logic           in_init;     // init vs runtime refresh
    logic [RFW-1:0] refi_tmr;    // refresh-interval countdown
    logic                          refresh_due;

    logic [3:0] cmd;
    assign {s_cs_n, s_ras_n, s_cas_n, s_we_n} = cmd;

    // Read-data capture pipeline: a READ at cycle T yields data CAS_LATENCY
    // cycles later. issue_read marks the READ cycle; data is latched when it
    // pops out of the shift register.
    logic                   issue_read;
    logic [CAS_LATENCY-1:0] rd_pipe;

    assign cmd_ready = (state == ST_IDLE) && init_done && !refresh_due;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_INIT_WAIT;
            cmd         <= CMD_NOP;
            s_cke       <= 1'b0;
            s_ba        <= '0;
            s_addr      <= '0;
            s_dqm       <= 2'b11;
            dq_out      <= '0;
            dq_oe       <= 1'b0;
            init_done   <= 1'b0;
            init_cnt    <= WCW'(INIT_CYC);
            wait_cnt    <= '0;
            wait_zero   <= 1'b1;
            ref_cnt     <= 4'(NUM_INIT_REF);
            in_init     <= 1'b1;
            refi_tmr    <= RFW'(REFI_CYC);
            refresh_due <= 1'b0;
            issue_read  <= 1'b0;
            rd_pipe     <= '0;
            rd_valid    <= 1'b0;
            rd_data     <= '0;
        end else begin
            // Defaults (overridden below as needed)
            cmd        <= CMD_NOP;
            s_cke      <= 1'b1;
            dq_oe      <= 1'b0;
            issue_read <= 1'b0;
            s_dqm      <= init_done ? 2'b00 : 2'b11;

            // Refresh-interval timer (free running once initialised)
            if (refi_tmr == 0) begin
                refi_tmr <= RFW'(REFI_CYC);
                if (init_done) refresh_due <= 1'b1;
            end else begin
                refi_tmr <= refi_tmr - 1'b1;
            end

            // Read-data pipeline
            rd_pipe <= {rd_pipe[CAS_LATENCY-2:0], issue_read};
            if (rd_pipe[CAS_LATENCY-1]) begin
                rd_data  <= dq_in;
                rd_valid <= 1'b1;
            end else begin
                rd_valid <= 1'b0;
            end

            case (state)
                // -- Power-up: wait, precharge all, refresh x8, load mode reg --
                ST_INIT_WAIT: begin
                    if (init_cnt == 0) state <= ST_PRE_ALL;
                    else               init_cnt <= init_cnt - 1'b1;
                end
                ST_PRE_ALL: begin
                    cmd      <= CMD_PRE;
                    s_addr   <= A10_HIGH;            // precharge all banks
                    wait_cnt <= WW'(TRP_CYC);
                    wait_zero <= (TRP_CYC == 0);
                    ref_cnt  <= 4'(NUM_INIT_REF);
                    in_init  <= 1'b1;
                    state    <= ST_REF_WAIT;         // tRP, then first refresh
                end
                ST_REF: begin
                    cmd      <= CMD_REF;
                    wait_cnt <= WW'(TRFC_CYC);
                    wait_zero <= (TRFC_CYC == 0);
                    state    <= ST_REF_WAIT;
                end
                ST_REF_WAIT: begin
                    if (wait_zero) begin
                        if (in_init) begin
                            if (ref_cnt == 0) begin
                                cmd      <= CMD_LMR;
                                s_ba     <= '0;
                                s_addr   <= MODE_REG;
                                wait_cnt <= WW'(TMRD_CYC);
                                wait_zero <= (TMRD_CYC == 0);
                                state    <= ST_LMR_WAIT;
                            end else begin
                                ref_cnt <= ref_cnt - 1'b1;
                                state   <= ST_REF;
                            end
                        end else begin
                            refresh_due <= 1'b0;
                            state       <= ST_IDLE;
                        end
                    end else begin
                        wait_cnt  <= wait_cnt - 1'b1;
                        wait_zero <= (wait_cnt == 1);
                    end
                end
                ST_LMR_WAIT: begin
                    if (wait_zero) begin
                        init_done <= 1'b1;
                        in_init   <= 1'b0;
                        state     <= ST_IDLE;
                    end else begin
                        wait_cnt  <= wait_cnt - 1'b1;
                        wait_zero <= (wait_cnt == 1);
                    end
                end

                // -- Ready: service refresh first, else accept one request -----
                ST_IDLE: begin
                    if (refresh_due) begin
                        in_init <= 1'b0;
                        state   <= ST_REF;
                    end else if (cmd_req) begin
                        req_col  <= cmd_addr[COL_BITS-1:0];
                        req_row  <= cmd_addr[COL_BITS+ROW_BITS-1:COL_BITS];
                        req_ba   <= cmd_addr[ADDR_BITS-1:COL_BITS+ROW_BITS];
                        req_we   <= cmd_we;
                        req_data <= cmd_wdata;
                        req_be   <= cmd_be;
                        state    <= ST_ACT;
                    end
                end
                ST_ACT: begin
                    cmd      <= CMD_ACT;
                    s_ba     <= req_ba;
                    s_addr   <= req_row;
                    wait_cnt <= WW'(TRCD_CYC);
                    wait_zero <= (TRCD_CYC == 0);
                    state    <= ST_RW;
                end
                ST_RW: begin
                    if (wait_zero) begin
                        // Column phase with auto-precharge (A10=1)
                        s_ba   <= req_ba;
                        s_addr <= ROW_BITS'(req_col) | A10_HIGH;
                        if (req_we) begin
                            cmd      <= CMD_WRITE;
                            dq_out   <= req_data;
                            dq_oe    <= 1'b1;
                            s_dqm    <= ~req_be;       // mask = inverse of byte-enable
                            wait_cnt <= WW'(RW_WR_WAIT);
                            wait_zero <= (RW_WR_WAIT == 0);
                        end else begin
                            cmd        <= CMD_READ;
                            issue_read <= 1'b1;
                            wait_cnt   <= WW'(RW_RD_WAIT);
                            wait_zero  <= (RW_RD_WAIT == 0);
                        end
                        state <= ST_RW_WAIT;
                    end else begin
                        wait_cnt  <= wait_cnt - 1'b1;
                        wait_zero <= (wait_cnt == 1);
                    end
                end
                ST_RW_WAIT: begin
                    if (wait_zero) state <= ST_IDLE;
                    else begin
                        wait_cnt  <= wait_cnt - 1'b1;
                        wait_zero <= (wait_cnt == 1);
                    end
                end
                default: state <= ST_INIT_WAIT;
            endcase
        end
    end

endmodule
