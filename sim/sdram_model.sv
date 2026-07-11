// sdram_model - small behavioural SDR SDRAM for the ocbk cosim (sim only).
//
// Vendored from ~/projects/other/fpga/ocb-test/sim/sdram_model.sv with byte-mask
// support added to match the ocbk sdram_ctrl (2-bit DQM): WRITE stores only the
// bytes whose DQM bit is low. Not a full datasheet model - just enough to drive
// the controller: ACTIVE latches the row per bank, WRITE stores at {bank,row,col}
// honouring DQM, READ drives that word back CAS_LATENCY cycles later; PRECHARGE,
// AUTO REFRESH, LOAD MODE and NOP are accepted and ignored.
//
// Storage is a flat array of MEM_WORDS entries indexed by the linear address
// {bank,row,col}; sized for the contiguous region the cosims touch - BK RAM,
// both Phase-4 framebuffers (FB1 ends at 0x01FFFF) and the Phase-7 BK-0011M
// banked space (8 RAM pages + 4 ROM banks + top ROM, 0x20000-0x39FBF) - not
// the full 32 MB device, keeping it Icarus-friendly.
`timescale 1ns / 1ps

module sdram_model #(
    parameter int ROW_BITS    = 13,
    parameter int COL_BITS    = 9,
    parameter int BA_BITS     = 2,
    parameter int DQ_BITS     = 16,
    parameter int CAS_LATENCY = 2,
    parameter int KEY_BITS    = BA_BITS + ROW_BITS + COL_BITS,
    parameter int MEM_WORDS   = 1 << 18
) (
    input  logic                clk,
    input  logic                cke,
    input  logic                cs_n,
    input  logic                ras_n,
    input  logic                cas_n,
    input  logic                we_n,
    input  logic [BA_BITS-1:0]  ba,
    input  logic [ROW_BITS-1:0] addr,
    input  logic [1:0]          dqm,        // {UDQM, LDQM}, 1 = mask (don't write)
    inout  wire  [DQ_BITS-1:0]  dq
);

    logic [DQ_BITS-1:0]  mem [0:MEM_WORDS-1];   // keyed by linear address
    logic [ROW_BITS-1:0] active_row [0:(1<<BA_BITS)-1];

    // Read-data delay line: a READ loads the tail, output reads the head.
    logic [DQ_BITS-1:0] rd_dat [0:CAS_LATENCY-1];
    logic               rd_vld [0:CAS_LATENCY-1];

    function automatic int key(input logic [BA_BITS-1:0] b);
        key = {b, active_row[b], addr[COL_BITS-1:0]};
    endfunction

    integer i;
    initial begin
        for (i = 0; i < CAS_LATENCY; i = i + 1) begin
            rd_vld[i] = 1'b0;
            rd_dat[i] = '0;
        end
    end

    always @(posedge clk) begin
        // shift the read delay line toward the head
        for (i = 0; i < CAS_LATENCY-1; i = i + 1) begin
            rd_vld[i] <= rd_vld[i+1];
            rd_dat[i] <= rd_dat[i+1];
        end
        rd_vld[CAS_LATENCY-1] <= 1'b0;

        if (cke && !cs_n) begin
            case ({ras_n, cas_n, we_n})
                3'b011: active_row[ba] <= addr;           // ACTIVE
                3'b100: begin                             // WRITE (byte-masked)
                    if (!dqm[0]) mem[key(ba)][7:0]   <= dq[7:0];
                    if (!dqm[1]) mem[key(ba)][15:8]  <= dq[15:8];
                end
                3'b101: begin                             // READ
                    rd_dat[CAS_LATENCY-1] <= mem[key(ba)];
                    rd_vld[CAS_LATENCY-1] <= 1'b1;
                end
                default: ;                                // PRE / REF / LMR / NOP
            endcase
        end
    end

    assign dq = rd_vld[0] ? rd_dat[0] : {DQ_BITS{1'bz}};

endmodule
