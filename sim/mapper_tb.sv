// ============================================================================
//  mapper_tb - unit oracle for src/mem_mapper.sv (Phase 7, BK-0011M banking).
//
//  Two halves, matching the module's contract:
//    * translate: BK-0010 mode is swept over ALL 64K addresses against the
//      pre-Phase-7 inline formulas (and re-swept after banking writes - bk10
//      decode must be map-content-independent); BK-0011M mode is checked
//      region by region (fixed page 6, window 0 pages, window 1 RAM/ROM,
//      fixed top ROM, undecoded I/O page), including every region boundary.
//    * map register: DOUT-window banking writes (word+bit-11 only), the
//      033-quirk ROM-code fall-through, the byte-write contract, bit-11=0
//      no-ops, DCLO re-init, and model_bk11 flips leaving the content alone.
//  nINIT-preserve is structural (the module has no nINIT port); the
//  behavioural RESET-instruction check lives in the bk11 SoC oracle.
// ============================================================================
`timescale 1ns/1ps
module mapper_tb;

    import qbus_pkg::*;

    localparam int AB = 24;

    logic sclk = 0;  always #5 sclk = ~sclk;   // ~100 MHz stand-in for sys_clk

    logic        rst        = 1'b1;
    logic        model_bk11 = 1'b0;
    logic        sync_n = 1'b1, dout_n = 1'b1, wtbt_n = 1'b1, sel1_n = 1'b1;
    logic [15:0] ad_true = '0;
    logic        addr0   = 1'b0;
    wire         bank_wr;

    logic [15:0]   addr = '0;
    wire  [1:0]    kind;
    wire  [AB-1:0] phys;

    integer errors = 0;

    mem_mapper #(.ADDR_BITS(AB)) dut (
        .sclk(sclk), .rst(rst), .model_bk11(model_bk11),
        .sync_n(sync_n), .dout_n(dout_n), .wtbt_n(wtbt_n), .sel1_n(sel1_n),
        .ad_true(ad_true), .addr0(addr0), .bank_wr(bank_wr),
        .addr(addr), .kind(kind), .phys(phys)
    );

    // ---- one 177716 DOUT window (the write shape qbus_mem's snoop sees) ----
    // byte_sig: WTBT asserted at DOUT time = byte op; odd: the 177717 byte.
    // exp_bank: expected bank_wr level inside the window.
    task map_write(input [15:0] value, input byte_sig, input odd,
                   input exp_bank, input [159:0] tag);
        begin
            sel1_n = 1'b0; addr0 = odd; ad_true = value;
            #3 sync_n = 1'b0;
            #3 wtbt_n = byte_sig ? 1'b0 : 1'b1;   // word write releases WTBT at DOUT
               dout_n = 1'b0;
            repeat (4) @(posedge sclk);
            #1;
            if (bank_wr !== exp_bank) begin
                $display("MAPPER-ERROR %0s: bank_wr exp=%b got=%b",
                         tag, exp_bank, bank_wr);
                errors = errors + 1;
            end
            dout_n = 1'b1;
            #3 sync_n = 1'b1; sel1_n = 1'b1; wtbt_n = 1'b1; addr0 = 1'b0;
            repeat (2) @(posedge sclk);
        end
    endtask

    task check(input [15:0] a, input [1:0] ek, input [AB-1:0] ep,
               input [159:0] tag);
        begin
            addr = a; #1;
            if (kind !== ek || phys !== ep) begin
                $display("MAPPER-ERROR %0s: addr=%o exp kind=%0d phys=%h got kind=%0d phys=%h",
                         tag, a, ek, ep, kind, phys);
                errors = errors + 1;
            end
        end
    endtask

    // ---- bk10 pass-through: every address vs the old inline formulas -------
    task sweep_bk10(input [159:0] tag);
        integer a;
        reg [1:0]    ek;
        reg [AB-1:0] ep;
        begin
            model_bk11 = 1'b0; #1;
            for (a = 0; a < 65536; a = a + 1) begin
                if (a < 'o100000)      begin ek = MK_RAM037; ep = a >> 1; end
                else if (a < 'o177600) begin ek = MK_ROM;    ep = a >> 1; end
                else                   begin ek = MK_NONE;   ep = '0;     end
                check(a[15:0], ek, ep, tag);
            end
        end
    endtask

    // window physical bases (word addresses)
    function [AB-1:0] ram_page(input [2:0] p, input [15:0] a);
        ram_page = BK11_RAM_BASE | {p, a[13:1]};
    endfunction
    function [AB-1:0] rom_bank(input [1:0] b, input [15:0] a);
        rom_bank = BK11_WROM_BASE | {b, a[13:1]};
    endfunction

    integer p;
    initial begin
        repeat (4) @(posedge sclk);
        @(negedge sclk) rst = 1'b0;
        repeat (2) @(posedge sclk);

        // ---- 1a. bk10 pass-through sweep, virgin map -----------------------
        sweep_bk10("bk10 sweep (reset map)");

        // ---- 2. bk11 reset default = config 0 ------------------------------
        model_bk11 = 1'b1; #1;
        check(16'o000000, MK_RAM037, ram_page(3'd6, 16'o000000), "cfg0 page6 lo");
        check(16'o037776, MK_RAM037, ram_page(3'd6, 16'o037776), "cfg0 page6 hi");
        check(16'o040000, MK_RAM037, ram_page(3'd0, 16'o040000), "cfg0 win0 lo");
        check(16'o077776, MK_RAM037, ram_page(3'd0, 16'o077776), "cfg0 win0 hi");
        check(16'o100000, MK_RAM037,    ram_page(3'd0, 16'o100000), "cfg0 win1 lo");
        check(16'o137776, MK_RAM037,    ram_page(3'd0, 16'o137776), "cfg0 win1 hi");
        check(16'o140000, MK_ROM,    BK11_TOPROM_BASE,           "cfg0 toprom lo");
        check(16'o177576, MK_ROM,    BK11_TOPROM_BASE | 24'h1FBF, "cfg0 toprom hi");
        check(16'o177600, MK_NONE,   '0,                         "cfg0 io lo");
        check(16'o177777, MK_NONE,   '0,                         "cfg0 io hi");

        // ---- 3. window-0 pages 0..7 ----------------------------------------
        for (p = 0; p < 8; p = p + 1) begin
            map_write(16'o004000 | (p[2:0] << 12), 1'b0, 1'b0, 1'b1, "win0 page write");
            check(16'o040000, MK_RAM037, ram_page(p[2:0], 16'o040000), "win0 page lo");
            check(16'o077776, MK_RAM037, ram_page(p[2:0], 16'o077776), "win0 page hi");
            // fixed page-6 region and window 1 unaffected by the win0 field
            check(16'o020000, MK_RAM037, ram_page(3'd6, 16'o020000), "page6 fixed");
            check(16'o100000, MK_RAM037,    ram_page(3'd0, 16'o100000), "win1 fixed");
        end

        // ---- 4. window-1 RAM pages 0..7 -> MK_RAM037 ---------------------------
        for (p = 0; p < 8; p = p + 1) begin
            map_write(16'o004000 | (p[2:0] << 8), 1'b0, 1'b0, 1'b1, "win1 page write");
            check(16'o100000, MK_RAM037, ram_page(p[2:0], 16'o100000), "win1 page lo");
            check(16'o137776, MK_RAM037, ram_page(p[2:0], 16'o137776), "win1 page hi");
        end

        // ---- 5. the four ROM codes (combined with a win0 field) -------------
        // Banks 0/1 (001/002) = BASIC, populated -> MK_ROM. Banks 2/3 (010/020)
        // = the stock BK-0011M UNPOPULATED sockets -> MK_NONE (no reply -> trap
        // 4), NOT the 033-quirk RAM fallthrough (win1_rom_en is still set here).
        map_write(16'o004000 | 16'o001 | (3 << 12), 1'b0, 1'b0, 1'b1, "rom code 001");
        check(16'o100000, MK_ROM, rom_bank(2'd0, 16'o100000), "rom bank 0");
        check(16'o137776, MK_ROM, rom_bank(2'd0, 16'o137776), "rom bank 0 hi");
        check(16'o040000, MK_RAM037, ram_page(3'd3, 16'o040000), "win0 combined");
        map_write(16'o004000 | 16'o002, 1'b0, 1'b0, 1'b1, "rom code 002");
        check(16'o100000, MK_ROM, rom_bank(2'd1, 16'o100000), "rom bank 1");
        map_write(16'o004000 | 16'o010, 1'b0, 1'b0, 1'b1, "rom code 010");
        check(16'o100000, MK_NONE, '0, "rom bank 2 empty -> trap");
        map_write(16'o004000 | 16'o020, 1'b0, 1'b0, 1'b1, "rom code 020");
        check(16'o100000, MK_NONE, '0, "rom bank 3 empty -> trap");

        // ---- 6. 033-quirk: non-single-bit codes fall through to RAM ---------
        map_write(16'o004000 | 16'o003 | (2 << 8), 1'b0, 1'b0, 1'b1, "quirk 003");
        check(16'o100000, MK_RAM037, ram_page(3'd2, 16'o100000), "quirk 003 -> RAM");
        map_write(16'o004000 | 16'o011, 1'b0, 1'b0, 1'b1, "quirk 011");
        check(16'o100000, MK_RAM037, ram_page(3'd0, 16'o100000), "quirk 011 -> RAM");
        map_write(16'o004000 | 16'o030, 1'b0, 1'b0, 1'b1, "quirk 030");
        check(16'o100000, MK_RAM037, ram_page(3'd0, 16'o100000), "quirk 030 -> RAM");
        map_write(16'o004000 | 16'o033, 1'b0, 1'b0, 1'b1, "quirk 033");
        check(16'o100000, MK_RAM037, ram_page(3'd0, 16'o100000), "quirk 033 -> RAM");
        map_write(16'o004000 | 16'o012, 1'b0, 1'b0, 1'b1, "quirk 012");
        check(16'o100000, MK_RAM037, ram_page(3'd0, 16'o100000), "quirk 012 -> RAM");
        map_write(16'o004000 | 16'o021, 1'b0, 1'b0, 1'b1, "quirk 021");
        check(16'o100000, MK_RAM037, ram_page(3'd0, 16'o100000), "quirk 021 -> RAM");
        // 0o005: bit 2 is OUTSIDE the 033 mask, so it masks to 001 = bank 0
        map_write(16'o004000 | 16'o005, 1'b0, 1'b0, 1'b1, "quirk 005");
        check(16'o100000, MK_ROM, rom_bank(2'd0, 16'o100000), "quirk 005 -> bank 0");

        // ---- 7. bit-11=0 write: map untouched, bank_wr low -------------------
        map_write(16'o000100 | (5 << 12) | (5 << 8), 1'b0, 1'b0, 1'b0, "bit11=0 write");
        check(16'o100000, MK_ROM, rom_bank(2'd0, 16'o100000), "bit11=0 keeps rom");
        check(16'o040000, MK_RAM037, ram_page(3'd0, 16'o040000), "bit11=0 keeps win0");

        // ---- 8. byte-write contract: no banking ------------------------------
        map_write(16'o004000 | (7 << 12), 1'b1, 1'b0, 1'b0, "byte write low");
        check(16'o040000, MK_RAM037, ram_page(3'd0, 16'o040000), "byte write ignored");
        map_write(16'o004000 | (7 << 12), 1'b1, 1'b1, 1'b0, "byte write 177717");
        check(16'o040000, MK_RAM037, ram_page(3'd0, 16'o040000), "177717 byte ignored");
        map_write(16'o004000 | (7 << 12), 1'b0, 1'b1, 1'b0, "odd word write");
        check(16'o040000, MK_RAM037, ram_page(3'd0, 16'o040000), "odd addr ignored");

        // ---- 10. model_bk11 flip: decode only, register content intact -------
        map_write(16'o004000 | 16'o002 | (4 << 12) | (5 << 8), 1'b0, 1'b0, 1'b1,
                  "pre-flip map");
        // ---- 1b. bk10 re-sweep with a loaded map (content-independent) -------
        sweep_bk10("bk10 sweep (loaded map)");
        model_bk11 = 1'b1; #1;
        check(16'o040000, MK_RAM037, ram_page(3'd4, 16'o040000), "flip keeps win0");
        check(16'o100000, MK_ROM,    rom_bank(2'd1, 16'o100000), "flip keeps rom");
        // a bk10-mode 177716 write with bit 11 must NOT bank (model gate)...
        model_bk11 = 1'b0; #1;
        map_write(16'o004000 | (1 << 12), 1'b0, 1'b0, 1'b0, "bk10 bit-11 write");
        model_bk11 = 1'b1; #1;
        check(16'o040000, MK_RAM037, ram_page(3'd4, 16'o040000), "bk10 write ignored");

        // ---- 9. DCLO re-init -> config 0 --------------------------------------
        @(negedge sclk) rst = 1'b1;
        repeat (2) @(posedge sclk);
        @(negedge sclk) rst = 1'b0;
        #1;
        check(16'o040000, MK_RAM037, ram_page(3'd0, 16'o040000), "dclo win0=0");
        check(16'o100000, MK_RAM037,    ram_page(3'd0, 16'o100000), "dclo rom off");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
