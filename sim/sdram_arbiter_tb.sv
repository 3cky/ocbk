// sdram_arbiter_tb - unit cosim for src/sdram_arbiter.sv against src/sdram_ctrl.sv
// and the behavioural sdram_model. Checks:
//   * datapath: word + byte writes read back correctly through the arbiter;
//   * read-return routing: p_rvalid/p_rdata land on the port that was granted;
//   * fixed priority: on simultaneous requests the lower index issues first;
//   * non-preemptive progress: a low-priority requestor is eventually served.
`timescale 1ns / 1ps

module sdram_arbiter_tb;

    localparam int NREQ = 4;
    localparam int AB   = 24;      // BA(2)+ROW(13)+COL(9)
    localparam int DW   = 16;

    logic clk = 0;
    always #5 clk = ~clk;          // 100 MHz-ish
    logic rst_n;

    // ---- per-port driver regs (packed into the DUT below) -------------------
    logic [NREQ-1:0] req, we;
    logic [AB-1:0]   addr  [0:NREQ-1];
    logic [DW-1:0]   wdata [0:NREQ-1];
    logic [1:0]      be    [0:NREQ-1];
    logic [NREQ-1:0] gnt, rvalid;
    logic [DW-1:0]   rdata;

    logic [NREQ*AB-1:0] addr_p;
    logic [NREQ*DW-1:0] wdata_p;
    logic [NREQ*2-1:0]  be_p;
    genvar g;
    generate for (g = 0; g < NREQ; g++) begin : pack
        assign addr_p [g*AB +: AB] = addr[g];
        assign wdata_p[g*DW +: DW] = wdata[g];
        assign be_p   [g*2  +: 2 ] = be[g];
    end endgenerate

    // ---- SDRAM controller + behavioural model -------------------------------
    logic                 cmd_req, cmd_we, cmd_ready, rd_valid;
    logic [AB-1:0]        cmd_addr;
    logic [DW-1:0]        cmd_wdata, rd_data;
    logic [1:0]           cmd_be;
    logic                 init_done;

    logic s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    logic [1:0]  s_ba, s_dqm;
    logic [12:0] s_addr;
    logic [DW-1:0] dq_out, dq_in;
    logic          dq_oe;
    wire  [DW-1:0] s_dq;
    assign s_dq  = dq_oe ? dq_out : 'z;
    assign dq_in = s_dq;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(AB), .DQ_BITS(DW)) dut (
        .clk(clk), .rst_n(rst_n),
        .p_req(req), .p_we(we), .p_addr(addr_p), .p_wdata(wdata_p), .p_be(be_p),
        .p_gnt(gnt), .p_rvalid(rvalid), .p_rdata(rdata),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data)
    );

    sdram_ctrl #(.ADDR_BITS(AB), .DQ_BITS(DW)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm),
        .dq_out(dq_out), .dq_oe(dq_oe), .dq_in(dq_in)
    );

    sdram_model u_mem (
        .clk(clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- scoreboard ---------------------------------------------------------
    integer errors = 0;
    task check(input [255:0] name, input [DW-1:0] got, input [DW-1:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %04h exp %04h", name, got, exp);
            errors = errors + 1;
        end else
            $display("ok   %0s: %04h", name, got);
    endtask

    // Single-port blocking write/read (used for directed sequences).
    task port_write(input int p, input [AB-1:0] a, input [DW-1:0] d, input [1:0] b);
        begin
            @(posedge clk);
            addr[p] = a; wdata[p] = d; be[p] = b; we[p] = 1'b1; req[p] = 1'b1;
            @(posedge clk); while (!gnt[p]) @(posedge clk);
            req[p] = 1'b0; we[p] = 1'b0;
        end
    endtask

    task port_read(input int p, input [AB-1:0] a, output [DW-1:0] d);
        begin
            @(posedge clk);
            addr[p] = a; be[p] = 2'b11; we[p] = 1'b0; req[p] = 1'b1;
            @(posedge clk); while (!gnt[p]) @(posedge clk);
            req[p] = 1'b0;
            while (!rvalid[p]) @(posedge clk);
            d = rdata;
        end
    endtask

    // Priority observation: record the order gnt pulses fire.
    integer gnt_seq [0:7];
    integer gnt_n;
    always @(posedge clk) begin
        for (int i = 0; i < NREQ; i++)
            if (gnt[i] && gnt_n < 8) begin gnt_seq[gnt_n] = i; gnt_n = gnt_n + 1; end
    end

    logic [DW-1:0] d1, d3, dr;

    initial begin
        req = '0; we = '0; gnt_n = 0;
        for (int i = 0; i < NREQ; i++) begin addr[i]=0; wdata[i]=0; be[i]=2'b11; end
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        wait (init_done); @(posedge clk);

        // 1) word writes on a low-priority port, read back on another port
        port_write(3, 24'h000100, 16'hCAFE, 2'b11);
        port_write(3, 24'h000101, 16'hBEEF, 2'b11);
        port_read (1, 24'h000100, dr); check("word A", dr, 16'hCAFE);
        port_read (1, 24'h000101, dr); check("word B", dr, 16'hBEEF);

        // 2) byte write (high byte only: be=10) over CAFE -> AAFE
        port_write(0, 24'h000100, 16'hAABB, 2'b10);
        port_read (2, 24'h000100, dr); check("byte hi", dr, 16'hAAFE);
        // low byte only (be=01) -> AA11
        port_write(0, 24'h000100, 16'h3311, 2'b01);
        port_read (2, 24'h000100, dr); check("byte lo", dr, 16'hAA11);

        // 3) fixed priority: ports 1 and 3 request simultaneously; 1 must issue first
        gnt_n = 0;
        @(posedge clk);
        addr[1]=24'h000101; be[1]=2'b11; we[1]=0; req[1]=1'b1;   // read BEEF
        addr[3]=24'h000100; be[3]=2'b11; we[3]=0; req[3]=1'b1;   // read AA11
        // release each once granted; capture both read results
        fork
            begin while (!gnt[1]) @(posedge clk); req[1]=0;
                  while (!rvalid[1]) @(posedge clk); d1=rdata; end
            begin while (!gnt[3]) @(posedge clk); req[3]=0;
                  while (!rvalid[3]) @(posedge clk); d3=rdata; end
        join
        check("prio rd P1", d1, 16'hBEEF);
        check("prio rd P3", d3, 16'hAA11);
        if (gnt_seq[0] !== 1) begin
            $display("FAIL priority: gnt order %0d,%0d (expected P1 before P3)",
                     gnt_seq[0], gnt_seq[1]); errors = errors + 1;
        end else
            $display("ok   priority: P1 (gnt_seq[0]=%0d) served before P3", gnt_seq[0]);

        if (errors == 0) $display("COSIM PASS"); else $display("COSIM FAIL (%0d)", errors);
        $finish;
    end

    initial begin #500_000; $display("COSIM FAIL (timeout)"); $finish; end

endmodule
