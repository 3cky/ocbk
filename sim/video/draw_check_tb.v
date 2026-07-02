//
// draw_check_tb - proves the ROM's hand-assembled PDP-11 picture-draw code
// produces EXACTLY mem/gen_mem.py render_image() (the definition every video
// cosim and gen_expected.py use).
//
// vm1 core + plain behavioural RAM/ROM with fast replies - no 037, no SDRAM:
// only the program's architectural effect matters here, not bus timing (that
// is covered by the ref037/video cosims). The CPU runs the FULL ram_test.hex
// (draw + RAM test); when it parks in the success loop the tb compares the
// whole video RAM (040000-077777) against img_exp.hex (Python-rendered).
//
// ~250K CPU cycles => minutes of Icarus wall-clock, so this is NOT part of
// `make sim`; run sim/video/run_draw_check.sh after changing mem/gen_mem.py.
//
`timescale 1ns / 1ps

module draw_check_tb;

    reg clk = 1'b0;
    always #100 clk = ~clk;                 // 5 MHz CPU clock (timing-agnostic)

    // ---- Q-bus ---------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    reg         dclo, aclo;
    wire        dmgo, bsy;  tri1 init, dmr, sack, iako;  wire [2:1] sel;

    // ---- memories --------------------------------------------------------
    reg [15:0] ram [0:16383];               // BK RAM 000000-077777 (words)
    reg [15:0] rom [0:255];                 // ROM image (100000..)
    reg [15:0] img_exp [0:8191];            // expected video RAM picture
    initial begin
        $readmemh("../mem/ram_test.hex", rom);
        $readmemh("video/img_exp.hex", img_exp);
    end

    // ---- decode at SYNC fall ---------------------------------------------
    reg [15:0] addr;
    reg        sel_ram, sel_rom, sel_io;
    always @(negedge sync) begin
        addr    = ~ad;
        sel_ram = (addr < 16'o100000);
        sel_rom = (addr >= 16'o100000) && (addr < 16'o140000);
        sel_io  = (addr >= 16'o177600);
    end
    always @(posedge sync) begin sel_ram=0; sel_rom=0; sel_io=0; end

    // ---- read / write replies (fast, 1 clk) --------------------------------
    reg [15:0] rdata;
    reg        roe = 1'b0, rp_n = 1'b1;
    assign ad   = roe  ? ~rdata : 16'hZZZZ;
    assign rply = rp_n ? 1'bZ   : 1'b0;

    always @(negedge din) if (~sync) begin
        if      (sel_ram) rdata = ram[addr[14:1]];
        else if (sel_rom) rdata = (addr[13:1] < 256) ? rom[addr[13:1]] : 16'd0;
        else if (sel_io)  rdata = (addr == 16'o177716) ? 16'o100000 : 16'd0;
        else              rdata = 16'd0;
        @(negedge clk); roe = 1'b1; rp_n = 1'b0;
    end
    always @(negedge dout) if (~sync) begin
        if (sel_ram) begin
            if (~wtbt) begin                       // byte write (WTBT at DOUT)
                if (addr[0]) ram[addr[14:1]][15:8] = ~ad[15:8];
                else         ram[addr[14:1]][7:0]  = ~ad[7:0];
            end else
                ram[addr[14:1]] = ~ad;
        end                                        // IO writes (177664): reply only
        @(negedge clk); rp_n = 1'b0;
    end
    always @(posedge din or posedge dout) begin
        @(negedge clk); rp_n = 1'b1; @(posedge clk); roe = 1'b0;
    end

    // ---- CPU ---------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(2'b11), .pin_sp_n(1'b1),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n(3'b111), .pin_virq_n(1'b1),
        .pin_ad_n(ad), .pin_dout_n(dout), .pin_din_n(din),
        .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
        .pin_dmr_n(dmr), .pin_sack_n(sack), .pin_dmgi_n(1'b1),
        .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel), .pin_bsy_n(bsy)
    );

    // ---- park detection + picture compare -----------------------------------
    integer succ = 0, i, miss;
    always @(negedge din) if (~sync) begin
        if (addr == 16'o100012) begin
            $display("COSIM FAIL: RAM test parked in the FAILURE loop");
            $finish;
        end
        if (addr == 16'o100004) succ = succ + 1;
        if (succ == 3) begin
            miss = 0;
            for (i = 0; i < 8192; i = i + 1)
                if (ram[16'o20000 + i] !== img_exp[i]) begin
                    if (miss < 10)
                        $display("FAIL: vram[%0o] = %06o expected %06o",
                                 i, ram[16'o20000 + i], img_exp[i]);
                    miss = miss + 1;
                end
            if (miss == 0) $display("COSIM PASS: drawn picture matches render_image()");
            else           $display("COSIM FAIL: %0d vram word mismatches", miss);
            $finish;
        end
    end

    // ---- reset + backstop -----------------------------------------------------
    initial begin
        dclo = 1'b0; aclo = 1'b0;
        repeat (16) @(negedge clk); dclo = 1'b1;
        repeat (8)  @(negedge clk); aclo = 1'b1;
        #400_000_000;                       // 400 ms backstop
        $display("COSIM FAIL: timeout (draw never reached the success park)");
        $finish;
    end

endmodule
