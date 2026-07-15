// raminit_tb - unit oracle for src/ram_init.sv (the authentic DRAM power-on
// pattern filler). Drives ram_init with a served-mask-honoring grant model and
// checks, per fill pass:
//   * the address walk covers exactly the model's RAM range, contiguously
//     (bk10 0x0000..0x3FFF = 16384 words; bk11 0x20000..0x2FFFF = 65536 words);
//   * every written word matches BkEmu's pattern - (addr[0]==addr[N])?0xFFFF:0,
//     N=6 (К565РУ6, bk10) / N=7 (К565РУ5, bk11);
//   * the served-mask contract: w_req drops for >=1 cycle after each grant;
//   * the trigger: fill at power-on, NO re-fill on a same-model "warm reset",
//     re-fill on a model change;
//   * blank_pulse: silent on the first (power-on) fill, one pulse per re-fill.
// Breaking the RTL pattern compare, range, or trigger makes a check fire and
// the run drops the final COSIM PASS.
`timescale 1ns/1ps
module raminit_tb;

    localparam int AB = 24;

    logic          clk = 0;
    logic          rst_n;
    logic          model_bk11;
    logic          enable;
    logic          w_req, w_gnt;
    logic [AB-1:0] w_addr;
    logic [15:0]   w_wdata;
    logic          fill_active, fill_busy, blank_pulse;

    always #5 clk = ~clk;   // 100 MHz

    ram_init #(.ADDR_BITS(AB)) dut (
        .clk(clk), .rst_n(rst_n), .model_bk11(model_bk11), .enable(enable),
        .w_req(w_req), .w_addr(w_addr), .w_wdata(w_wdata), .w_gnt(w_gnt),
        .fill_active(fill_active), .fill_busy(fill_busy), .blank_pulse(blank_pulse)
    );

    // ---- grant model: at most one grant per 3 cycles, only while w_req -------
    // (models the arbiter's re-arb + SDRAM write latency; forces ram_init to
    // honor the served-mask gap between words).
    logic [1:0] cd;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_gnt <= 1'b0;
            cd    <= 2'd0;
        end else begin
            w_gnt <= 1'b0;
            if (cd != 0)          cd <= cd - 1'b1;
            else if (w_req)     begin w_gnt <= 1'b1; cd <= 2'd2; end
        end
    end

    // ---- checker ------------------------------------------------------------
    logic          fa_d, gnt_d;
    logic [AB-1:0] exp_addr;
    logic [31:0]   word_cnt;
    logic          cur_model;
    logic [31:0]   total_fills;
    logic          err;
    logic          pn;
    logic [15:0]   expw;
    logic [AB-1:0] exp_last;
    logic [31:0]   exp_cnt;

    initial begin
        err = 0; total_fills = 0; fa_d = 0; gnt_d = 0;
        exp_addr = 0; word_cnt = 0; cur_model = 0;
    end

    always @(posedge clk) begin
        fa_d  <= fill_active;
        gnt_d <= w_gnt;

        // served-mask: the cycle after a grant, w_req must be low
        if (gnt_d && w_req) begin
            $display("RAMINIT-ERROR: w_req not dropped for a cycle after grant");
            err <= 1'b1;
        end

        // fill start (rising edge of fill_active)
        if (fill_active && !fa_d) begin
            exp_addr  <= model_bk11 ? 24'h020000 : 24'h000000;
            word_cnt  <= 0;
            cur_model <= model_bk11;
            if (total_fills == 0) begin
                if (blank_pulse) begin
                    $display("RAMINIT-ERROR: blank_pulse on the first (power-on) fill");
                    err <= 1'b1;
                end
            end else begin
                if (!blank_pulse) begin
                    $display("RAMINIT-ERROR: no blank_pulse on a re-fill");
                    err <= 1'b1;
                end
            end
        end

        // capture each granted word
        if (w_gnt && fill_active) begin
            if (w_addr !== exp_addr) begin
                $display("RAMINIT-ERROR: addr %06h != expected %06h", w_addr, exp_addr);
                err <= 1'b1;
            end
            pn   = cur_model ? w_addr[7] : w_addr[6];
            expw = (w_addr[0] == pn) ? 16'hFFFF : 16'h0000;
            if (w_wdata !== expw) begin
                $display("RAMINIT-ERROR: wdata %04h != expected %04h @ %06h",
                         w_wdata, expw, w_addr);
                err <= 1'b1;
            end
            exp_addr <= exp_addr + 1'b1;
            word_cnt <= word_cnt + 1'b1;
        end

        // fill end (falling edge of fill_active)
        if (!fill_active && fa_d) begin
            exp_last = cur_model ? 24'h02FFFF : 24'h003FFF;
            exp_cnt  = cur_model ? 32'd65536  : 32'd16384;
            if (word_cnt !== exp_cnt) begin
                $display("RAMINIT-ERROR: fill count %0d != expected %0d", word_cnt, exp_cnt);
                err <= 1'b1;
            end
            if (exp_addr !== exp_last + 1'b1) begin
                $display("RAMINIT-ERROR: end addr %06h != %06h", exp_addr, exp_last + 1'b1);
                err <= 1'b1;
            end
            total_fills <= total_fills + 1'b1;
            $display("RAMINIT: fill #%0d done model=%b words=%0d", total_fills, cur_model, word_cnt);
        end
    end

    // ---- stimulus -----------------------------------------------------------
    task automatic wait_fill;   // wait for one fill pass to start and finish
        begin
            wait (fill_busy);
            @(negedge fill_busy);
            repeat (4) @(posedge clk);   // let the end-detect + count settle
        end
    endtask

    initial begin
        rst_n = 0; model_bk11 = 0; enable = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // (1) power-on fill, bk10 - no blank
        enable = 1;
        wait_fill;
        if (total_fills != 1) begin $display("RAMINIT-ERROR: power-on fill missing"); err = 1; end

        // (2) same-model "warm reset": model unchanged -> NO new fill
        repeat (200) @(posedge clk);
        if (fill_busy || fill_active) begin
            $display("RAMINIT-ERROR: unexpected fill on same-model reset"); err = 1;
        end
        if (total_fills != 1) begin $display("RAMINIT-ERROR: spurious re-fill"); err = 1; end

        // (3) model change -> bk11 re-fill (blank)
        model_bk11 = 1;
        wait_fill;
        if (total_fills != 2) begin $display("RAMINIT-ERROR: bk11 re-fill missing"); err = 1; end

        // (4) model change back -> bk10 re-fill (blank)
        model_bk11 = 0;
        wait_fill;
        if (total_fills != 3) begin $display("RAMINIT-ERROR: bk10 re-fill missing"); err = 1; end

        repeat (20) @(posedge clk);
        if (err) $display("COSIM FAIL");
        else     $display("COSIM PASS");
        $finish;
    end

    // safety timeout (two 65536-word fills at ~3 cyc/word + slack)
    initial begin
        #6_000_000;
        $display("RAMINIT-ERROR: timeout");
        $display("COSIM FAIL");
        $finish;
    end

endmodule
