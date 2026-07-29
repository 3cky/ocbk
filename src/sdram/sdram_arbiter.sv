// sdram_arbiter - fixed-priority, single-word, non-preemptive arbiter that funnels
// several requestors onto the single-word sdram_ctrl command port.
//
// Everything on the BK SDRAM is single-word (the controller's command port is one
// word), so the arbiter never issues bursts: it picks the highest-priority pending
// requestor, runs that one access to completion (accept, and for reads until the
// data returns), then re-arbitrates. This bounds every requestor's worst-case wait
// to ONE in-flight word + refresh regardless of priority - the property the CPU's
// RPLY-window margin relies on once the SDRAM is contended (see CLAUDE.md's
// "SDRAM arbiter ports" bullet - there is NO fairness, so port 1 must stay paced).
//
// Priority = port index: port 0 is highest. Integration mapping:
//   [0] CPU RAM/ROM   (highest - protects cycle-accuracy; the 037 grant, not the
//                      arbiter, sets its timing). During boot the ROM-loader is
//                      MUXED onto port 0 externally (CPU is held in reset then, so
//                      no conflict) - that is the "boot-writer mux".
//   [1] video readout (hard real-time; tiny demand + on-chip line buffer)
//   [2] 037 video fetch
//   [3] framebuffer write
//
// Requestor contract (per port i):
//   - assert p_req[i] with p_we/p_addr/p_wdata/p_be held STABLE until p_gnt[i];
//   - p_gnt[i] pulses for one cycle when the command is accepted -> drop p_req[i]
//     (or it will be re-arbitrated);
//   - for reads, p_rvalid[i] pulses one cycle later with the word on p_rdata.
// Only one access is ever outstanding, so p_rvalid unambiguously belongs to the
// port that was last granted a read.
module sdram_arbiter #(
    parameter int NREQ      = 4,
    parameter int ADDR_BITS = 24,
    parameter int DQ_BITS   = 16
) (
    input  logic clk,
    input  logic rst_n,

    // ---- requestor ports (packed; field i = port i, index 0 = highest) ------
    input  logic [NREQ-1:0]             p_req,
    input  logic [NREQ-1:0]             p_we,
    input  logic [NREQ*ADDR_BITS-1:0]   p_addr,
    input  logic [NREQ*DQ_BITS-1:0]     p_wdata,
    input  logic [NREQ*2-1:0]           p_be,
    output logic [NREQ-1:0]             p_gnt,
    output logic [NREQ-1:0]             p_rvalid,
    output logic [DQ_BITS-1:0]          p_rdata,

    // ---- sdram_ctrl command port --------------------------------------------
    output logic                 cmd_req,
    output logic                 cmd_we,
    output logic [ADDR_BITS-1:0] cmd_addr,
    output logic [DQ_BITS-1:0]   cmd_wdata,
    output logic [1:0]           cmd_be,
    input  logic                 cmd_ready,
    input  logic                 rd_valid,
    input  logic [DQ_BITS-1:0]   rd_data
);

    localparam int SW = (NREQ > 1) ? $clog2(NREQ) : 1;

    typedef enum logic [1:0] { A_IDLE, A_ISSUE, A_RDWAIT } astate_t;
    astate_t        state;
    logic [SW-1:0]  cur;

    // A granted port stays ineligible until its req is seen low again, so a
    // requester that holds req one cycle past gnt is not double-issued (the
    // contract is: drop req on gnt, re-assert next cycle for a further access).
    logic [NREQ-1:0] served;

    // Fixed-priority select: lowest ELIGIBLE index (req & not-yet-cleared).
    wire  [NREQ-1:0] elig = p_req & ~served;
    logic [SW-1:0]   sel;
    logic            any;
    always_comb begin
        sel = '0;
        any = 1'b0;
        for (int i = 0; i < NREQ; i++)
            if (!any && elig[i]) begin
                sel = i[SW-1:0];
                any = 1'b1;
            end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= A_IDLE;
            cur       <= '0;
            cmd_req   <= 1'b0;
            cmd_we    <= 1'b0;
            cmd_addr  <= '0;
            cmd_wdata <= '0;
            cmd_be    <= 2'b11;
            p_gnt     <= '0;
            p_rvalid  <= '0;
            p_rdata   <= '0;
            served    <= '0;
        end else begin
            p_gnt    <= '0;         // default: single-cycle pulses
            p_rvalid <= '0;
            // Release the eligibility hold once a served port drops its req.
            for (int i = 0; i < NREQ; i++)
                if (!p_req[i]) served[i] <= 1'b0;
            case (state)
                A_IDLE: begin
                    cmd_req <= 1'b0;
                    if (any) begin
                        cur       <= sel;
                        cmd_we    <= p_we  [sel];
                        cmd_addr  <= p_addr [sel*ADDR_BITS +: ADDR_BITS];
                        cmd_wdata <= p_wdata[sel*DQ_BITS   +: DQ_BITS];
                        cmd_be    <= p_be   [sel*2         +: 2];
                        cmd_req   <= 1'b1;
                        state     <= A_ISSUE;
                    end
                end
                A_ISSUE: begin
                    if (cmd_ready) begin        // command accepted
                        cmd_req     <= 1'b0;
                        p_gnt[cur]  <= 1'b1;
                        served[cur] <= 1'b1;   // hold until this port drops req
                        if (cmd_we) state <= A_IDLE;
                        else        state <= A_RDWAIT;
                    end
                end
                A_RDWAIT: begin
                    if (rd_valid) begin
                        p_rdata       <= rd_data;
                        p_rvalid[cur] <= 1'b1;
                        state         <= A_IDLE;
                    end
                end
                default: state <= A_IDLE;
            endcase
        end
    end

endmodule
