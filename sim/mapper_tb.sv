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
//
//  Phase 8 (SMK512, sections S1-S10): a second DIFFERENTIAL reference
//  instance (dut_ref, smk_en tied 0, identical stimulus) pins "SMK disabled
//  == bit-identical" over full-64K sweeps in every non-SMK configuration
//  (smk_en=0 both models, and smk_en=1 in bk10 - the SMK is BK-0011M-only);
//  the directed sections then walk the BkEmu SmkMemoryManager contract: the
//  177130 two-phase strobe protocol (low-nibble==6 arms, the FOLLOWING write
//  commits mode+page on the strobe falling edge), the byte-write lane
//  masking (BkEmu writeMemory: odd byte = value<<8, even byte = raw byte),
//  the 8-mode x 8-segment table incl. the SYS/ALL +4 rotation, the
//  {v0,v3,v2,v10} page-bit scatter, the SMK BIOS ROM windows (increment 2:
//  rom6 @160000 in SYS/STD10/STD11, rom7 @170000 in SYS spanning the WHOLE
//  segment incl. the register space - the 177716 boot overlay; one shared
//  2048-word image at SMK_BIOS_BASE), the per-mode seg-7 restricted extent
//  0177000-0177777 (ALL readable/smk_ro, HLT10/HLT11 writable/smk_wo,
//  others capped -> MK_NONE, boundary exact at 177000), 177130 read = BIOS
//  ROM under SYS (the refined invariant: the mapper never claims the WRITE
//  there), HLT10 seg-0 read-only (smk_ro), std-passthrough segs tracking
//  the live 177716 banking, mutual isolation of the two register files,
//  DCLO-only reset (-> SYS, both BIOS windows live, strobe disarmed), and
//  enable/model flips keeping register content.
//  MUTATION-TESTED: swapping the page scatter order, committing on the
//  arming edge, dropping the seg-7 cap, dropping the odd-byte lane mask
//  (the S5 junk-low-byte vector re-arms instead of committing), and
//  breaking a mode's segment mask all fail directed checks here.
//  Increment-2 mutations (each fails): dropping rom7 from SYS (S3/S6 BIOS
//  checks), swapping rom6/rom7 selection per mode (S6 STD10), swapping the
//  extent direction flags (S8 ALL vs HLT10), extent boundary off-by-one
//  (addr[11:9]==3'b110 - S8 boundary pairs), a wrong SMK_BIOS_BASE bit
//  (every check_bios phys).
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

    logic          smk_en = 1'b0;
    wire           smk_ro, smk_wo;

    integer errors = 0;

    mem_mapper #(.ADDR_BITS(AB)) dut (
        .sclk(sclk), .rst(rst), .model_bk11(model_bk11), .smk_en(smk_en),
        .sync_n(sync_n), .dout_n(dout_n), .wtbt_n(wtbt_n), .sel1_n(sel1_n),
        .ad_true(ad_true), .addr0(addr0), .bank_wr(bank_wr),
        .addr(addr), .kind(kind), .phys(phys), .smk_ro(smk_ro), .smk_wo(smk_wo)
    );

    // Differential reference: identical stimulus, smk_en hard-tied 0. Its
    // banking registers track the same 177716 writes, so in every non-SMK
    // configuration the primary DUT must match it bit-for-bit over all 64K.
    wire [1:0]    kind_ref;
    wire [AB-1:0] phys_ref;
    wire          bank_wr_ref, smk_ro_ref, smk_wo_ref;
    mem_mapper #(.ADDR_BITS(AB)) dut_ref (
        .sclk(sclk), .rst(rst), .model_bk11(model_bk11), .smk_en(1'b0),
        .sync_n(sync_n), .dout_n(dout_n), .wtbt_n(wtbt_n), .sel1_n(sel1_n),
        .ad_true(ad_true), .addr0(addr0), .bank_wr(bank_wr_ref),
        .addr(addr), .kind(kind_ref), .phys(phys_ref), .smk_ro(smk_ro_ref),
        .smk_wo(smk_wo_ref)
    );

    // ---- one 177716 DOUT window (the write shape qbus_mem's snoop sees) ----
    // byte_sig: WTBT asserted at DOUT time = byte op; odd: the 177717 byte.
    // exp_bank: expected bank_wr level inside the window.
    task map_write(input [15:0] value, input byte_sig, input odd,
                   input exp_bank, input [159:0] tag);
        begin
            // drive the real bus address too: the Phase-8 SMK snoop decodes
            // the latched address, so a stale 177130 here would false-fire it
            sel1_n = 1'b0; addr0 = odd; ad_true = value;
            addr = odd ? 16'o177717 : 16'o177716;
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
            addr = '0;
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
    // SMK RAM segment word address: abs seg = page*8 + rel, 2 Kwords each.
    function [AB-1:0] smk_seg(input [3:0] pg, input [2:0] rel, input [15:0] a);
        smk_seg = SMK_RAM_BASE | {pg, rel, a[11:1]};
    endfunction

    // ---- one 177130 DOUT window (no SEL pin - a plain addressed write) -----
    // The snoop keys on the latched bus address, so `addr` carries 177130/1
    // for the window. bank_wr must never fire (mutual isolation with the
    // 177716 banking snoop).
    task smk_write(input [15:0] value, input byte_sig, input odd,
                   input [159:0] tag);
        begin
            addr = odd ? 16'o177131 : 16'o177130;
            ad_true = value;
            #3 sync_n = 1'b0;
            #3 wtbt_n = byte_sig ? 1'b0 : 1'b1;
               dout_n = 1'b0;
            repeat (4) @(posedge sclk);
            #1;
            if (bank_wr !== 1'b0) begin
                $display("MAPPER-ERROR %0s: 177130 write raised bank_wr", tag);
                errors = errors + 1;
            end
            dout_n = 1'b1;
            #3 sync_n = 1'b1; wtbt_n = 1'b1;
            addr = '0; ad_true = '0;
            repeat (2) @(posedge sclk);
        end
    endtask

    // arm-then-commit convenience (both word writes, the BkEmu test's setMode)
    task smk_mode(input [15:0] value, input [159:0] tag);
        begin
            smk_write(16'o000006, 1'b0, 1'b0, tag);
            smk_write(value,      1'b0, 1'b0, tag);
        end
    endtask

    // check + both direction flags (only meaningful alongside MK_EXT)
    task check_extd(input [15:0] a, input [3:0] pg, input [2:0] rel,
                    input ro, input wo, input [159:0] tag);
        begin
            check(a, MK_EXT, smk_seg(pg, rel, a), tag);
            if (smk_ro !== ro || smk_wo !== wo) begin
                $display("MAPPER-ERROR %0s: addr=%o smk_ro exp=%b got=%b smk_wo exp=%b got=%b",
                         tag, a, ro, smk_ro, wo, smk_wo);
                errors = errors + 1;
            end
        end
    endtask

    // the common read+write case (wo = 0)
    task check_ext(input [15:0] a, input [3:0] pg, input [2:0] rel,
                   input ro, input [159:0] tag);
        check_extd(a, pg, rel, ro, 1'b0, tag);
    endtask

    // SMK BIOS ROM window: ONE 2048-word image at SMK_BIOS_BASE, both windows
    task check_bios(input [15:0] a, input [159:0] tag);
        begin
            check(a, MK_ROM, SMK_BIOS_BASE | a[11:1], tag);
            if (smk_ro !== 1'b0 || smk_wo !== 1'b0) begin
                $display("MAPPER-ERROR %0s: addr=%o bios flags ro=%b wo=%b",
                         tag, a, smk_ro, smk_wo);
                errors = errors + 1;
            end
        end
    endtask

    // ---- differential sweep: DUT must equal the smk_en=0 reference ---------
    task sweep_diff(input [159:0] tag);
        integer a;
        begin
            for (a = 0; a < 65536; a = a + 1) begin
                addr = a[15:0]; #1;
                if (kind !== kind_ref || phys !== phys_ref
                    || smk_ro !== 1'b0 || smk_wo !== 1'b0) begin
                    $display("MAPPER-ERROR %0s: addr=%o dut kind=%0d phys=%h ro=%b wo=%b ref kind=%0d phys=%h",
                             tag, a, kind, phys, smk_ro, smk_wo, kind_ref, phys_ref);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // one std-passthrough address: the SMK-mode DUT must equal the reference
    task check_std(input [15:0] a, input [159:0] tag);
        begin
            addr = a; #1;
            if (kind !== kind_ref || phys !== phys_ref
                || smk_ro !== 1'b0 || smk_wo !== 1'b0) begin
                $display("MAPPER-ERROR %0s: addr=%o dut kind=%0d phys=%h ro=%b wo=%b ref kind=%0d phys=%h",
                         tag, a, kind, phys, smk_ro, smk_wo, kind_ref, phys_ref);
                errors = errors + 1;
            end
        end
    endtask

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

        // ==================== Phase-8 SMK512 sections =======================
        // State on entry: bk11 mode, banking config 0, smk_en = 0.

        // ---- S0. smk_en=0 baseline: DUT == reference everywhere ------------
        sweep_diff("S0 bk11 diff smk-off");

        // ---- S1. disabled-time 177130 writes must not even snoop -----------
        smk_write(16'o000006, 1'b0, 1'b0, "S1 arm smk-off");
        smk_write(16'o000120, 1'b0, 1'b0, "S1 commit smk-off");
        sweep_diff("S1 bk11 diff after off-writes");
        sweep_bk10("S1 bk10 sweep after off-writes");
        model_bk11 = 1'b1; smk_en = 1'b1; #1;
        // layout must still be the SYS reset default, NOT the RAM10 above
        check(16'o100000, MK_NONE, '0, "S1 seg0 still SYS");
        check_ext(16'o120000, 4'd0, 3'd6, 1'b0, "S1 seg2 still SYS");

        // ---- S2. bk10 immunity with smk_en=1 (SMK is BK-0011M-only) --------
        model_bk11 = 1'b0; #1;
        sweep_diff("S2 bk10 diff smk-on");
        smk_write(16'o000006, 1'b0, 1'b0, "S2 arm bk10");
        smk_write(16'o000120, 1'b0, 1'b0, "S2 commit bk10");
        model_bk11 = 1'b1; #1;
        check(16'o100000, MK_NONE, '0, "S2 bk10 write no snoop");
        check_ext(16'o120000, 4'd0, 3'd6, 1'b0, "S2 seg2 still SYS");

        // ---- S3. SYS reset-default segment boundaries (page 0) -------------
        check(16'o100000, MK_NONE, '0, "S3 SYS seg0 lo");
        check(16'o117776, MK_NONE, '0, "S3 SYS seg1 hi");
        check_ext(16'o120000, 4'd0, 3'd6, 1'b0, "S3 SYS seg2 lo");
        check_ext(16'o137776, 4'd0, 3'd7, 1'b0, "S3 SYS seg3 hi");
        check_ext(16'o140000, 4'd0, 3'd0, 1'b0, "S3 SYS seg4 lo");
        check_ext(16'o157776, 4'd0, 3'd1, 1'b0, "S3 SYS seg5 hi");
        check_bios(16'o160000, "S3 SYS seg6 BIOS");
        check_bios(16'o167776, "S3 SYS seg6 BIOS hi");
        check_bios(16'o170000, "S3 SYS seg7 BIOS");
        // rom7 spans the whole segment incl. the register space - the boot
        // overlay (qbus_mem carves the reply policy; translation is uniform)
        check_bios(16'o177600, "S3 SYS io page BIOS overlay");
        check_bios(16'o177716, "S3 SYS 177716 boot word");
        check_bios(16'o177776, "S3 SYS io page top");
        check(16'o077776, MK_RAM037, ram_page(3'd0, 16'o077776), "S3 win0 untouched");
        check(16'o020000, MK_RAM037, ram_page(3'd6, 16'o020000), "S3 page6 untouched");

        // ---- S4. the two-phase strobe protocol ------------------------------
        smk_write(16'o000120, 1'b0, 1'b0, "S4 commit w/o arm");
        check(16'o100000, MK_NONE, '0, "S4 no commit w/o arm");
        smk_write(16'o000006, 1'b0, 1'b0, "S4 arm");
        // low nibble 6 with junk upper bits: RE-ARMS instead of committing
        smk_write(16'o170006, 1'b0, 1'b0, "S4 re-arm junk upper");
        check(16'o100000, MK_NONE, '0, "S4 re-arm did not commit");
        smk_write(16'o000120, 1'b0, 1'b0, "S4 commit RAM10");
        check_ext(16'o100000, 4'd0, 3'd0, 1'b0, "S4 RAM10 seg0");
        check_ext(16'o160000, 4'd0, 3'd6, 1'b0, "S4 RAM10 seg6");
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S4 RAM10 seg7 lo");
        check_ext(16'o176776, 4'd0, 3'd7, 1'b0, "S4 RAM10 seg7 top");
        check(16'o177000, MK_NONE, '0, "S4 seg7 cap lo");
        check(16'o177576, MK_NONE, '0, "S4 seg7 cap hi");

        // ---- S5. byte-write lane masking (BkEmu writeMemory dispatch) ------
        // even byte = the raw low byte; the high-lane junk must be masked
        smk_write(16'h4506, 1'b1, 1'b0, "S5 even-byte arm");
        smk_write(16'o000160, 1'b0, 1'b0, "S5 word commit SYS");
        check(16'o100000, MK_NONE, '0, "S5 even-byte arm worked");
        smk_write(16'o000006, 1'b0, 1'b0, "S5 arm2");
        smk_write(16'hFF50, 1'b1, 1'b0, "S5 even-byte commit"); // 0x50 = 0o120
        check_ext(16'o100000, 4'd0, 3'd0, 1'b0, "S5 even-byte commit RAM10");
        // odd byte = value << 8 (data bit 10 = high-lane bit 2); the junk low
        // lane carries nibble 6 - unmasked it would RE-ARM instead of commit
        smk_write(16'o000006, 1'b0, 1'b0, "S5 arm3");
        smk_write({8'o004, 8'h66}, 1'b1, 1'b1, "S5 odd-byte commit");
        check_ext(16'o140000, 4'd1, 3'd4, 1'b0, "S5 odd-byte HLT11 page1");
        check(16'o100000, MK_RAM037, ram_page(3'd0, 16'o100000), "S5 HLT11 seg0 std");

        // ---- S6. the 8-mode x 8-seg table, live banking loaded --------------
        map_write(16'o004000 | (3 << 12) | (5 << 8), 1'b0, 1'b0, 1'b1, "S6 banking");
        // SYS (0160): +4 rotation, seg0/1 deselected, seg6/7 BIOS
        smk_mode(16'o000160, "S6 SYS");
        check(16'o100000, MK_NONE, '0, "S6 SYS seg0");
        check(16'o110000, MK_NONE, '0, "S6 SYS seg1");
        check_ext(16'o120000, 4'd0, 3'd6, 1'b0, "S6 SYS seg2");
        check_ext(16'o130000, 4'd0, 3'd7, 1'b0, "S6 SYS seg3");
        check_ext(16'o140000, 4'd0, 3'd0, 1'b0, "S6 SYS seg4");
        check_ext(16'o150000, 4'd0, 3'd1, 1'b0, "S6 SYS seg5");
        check_bios(16'o160000, "S6 SYS seg6 BIOS");
        check_bios(16'o170000, "S6 SYS seg7 BIOS");
        // 177130 under SYS is BIOS ROM on the READ side (the refined
        // invariant: the mapper never claims the WRITE - MK_ROM is read-only)
        check_bios(16'o177130, "S6 SYS 177130 read = BIOS");
        // STD10 (060)
        smk_mode(16'o000060, "S6 STD10");
        check(16'o100000, MK_NONE, '0, "S6 STD10 seg0");
        check(16'o110000, MK_NONE, '0, "S6 STD10 seg1");
        check_ext(16'o120000, 4'd0, 3'd2, 1'b0, "S6 STD10 seg2");
        check_ext(16'o130000, 4'd0, 3'd3, 1'b0, "S6 STD10 seg3");
        check_ext(16'o140000, 4'd0, 3'd4, 1'b0, "S6 STD10 seg4");
        check_ext(16'o150000, 4'd0, 3'd5, 1'b0, "S6 STD10 seg5");
        check_bios(16'o160000, "S6 STD10 seg6 BIOS");
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S6 STD10 seg7");
        check(16'o177130, MK_NONE, '0, "S6 STD10 177130 capped");
        // RAM10 (0120): identity
        smk_mode(16'o000120, "S6 RAM10");
        check_ext(16'o100000, 4'd0, 3'd0, 1'b0, "S6 RAM10 seg0");
        check_ext(16'o130000, 4'd0, 3'd3, 1'b0, "S6 RAM10 seg3");
        check_ext(16'o160000, 4'd0, 3'd6, 1'b0, "S6 RAM10 seg6");
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S6 RAM10 seg7");
        // ALL (020): +4 rotation over all eight
        smk_mode(16'o000020, "S6 ALL");
        check_ext(16'o100000, 4'd0, 3'd4, 1'b0, "S6 ALL seg0");
        check_ext(16'o130000, 4'd0, 3'd7, 1'b0, "S6 ALL seg3");
        check_ext(16'o140000, 4'd0, 3'd0, 1'b0, "S6 ALL seg4");
        check_ext(16'o160000, 4'd0, 3'd2, 1'b0, "S6 ALL seg6");
        check_ext(16'o170000, 4'd0, 3'd3, 1'b0, "S6 ALL seg7");
        // ALL: the restricted extent is READABLE (read-only SMK RAM)
        check_extd(16'o177000, 4'd0, 3'd3, 1'b1, 1'b0, "S6 ALL extent readable");
        // STD11 (0140): seg0..5 = std (win1 page 5 + BOS top ROM), seg6 BIOS
        smk_mode(16'o000140, "S6 STD11");
        check(16'o100000, MK_RAM037, ram_page(3'd5, 16'o100000), "S6 STD11 seg0 std");
        check_std(16'o137776, "S6 STD11 seg3 std");
        check_std(16'o140000, "S6 STD11 seg4 std");
        check_std(16'o157776, "S6 STD11 seg5 std");
        check_bios(16'o160000, "S6 STD11 seg6 BIOS");
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S6 STD11 seg7");
        // RAM11 (040): seg0..3 std, seg4..7 SMK
        smk_mode(16'o000040, "S6 RAM11");
        check_std(16'o100000, "S6 RAM11 seg0 std");
        check_std(16'o137776, "S6 RAM11 seg3 std");
        check_ext(16'o140000, 4'd0, 3'd4, 1'b0, "S6 RAM11 seg4");
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S6 RAM11 seg7");
        // HLT10 (0100): identity, seg0 READ-ONLY, extent WRITE-ONLY
        smk_mode(16'o000100, "S6 HLT10");
        check_ext(16'o100000, 4'd0, 3'd0, 1'b1, "S6 HLT10 seg0 RO");
        check_ext(16'o107776, 4'd0, 3'd0, 1'b1, "S6 HLT10 seg0 RO hi");
        check_ext(16'o110000, 4'd0, 3'd1, 1'b0, "S6 HLT10 seg1 rw");
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S6 HLT10 seg7");
        check_extd(16'o177000, 4'd0, 3'd7, 1'b0, 1'b1, "S6 HLT10 extent WO");
        check_extd(16'o177674, 4'd0, 3'd7, 1'b0, 1'b1, "S6 HLT10 177674 catch");
        // HLT11 (0): seg0..3 std, seg4..7 SMK, extent WRITE-ONLY
        smk_mode(16'o000000, "S6 HLT11");
        check_std(16'o100000, "S6 HLT11 seg0 std");
        check_ext(16'o140000, 4'd0, 3'd4, 1'b0, "S6 HLT11 seg4");
        check_extd(16'o177676, 4'd0, 3'd7, 1'b0, 1'b1, "S6 HLT11 177676 catch");
        // STD11 + a window-1 ROM overlay / empty socket through the std path
        map_write(16'o004000 | 16'o001, 1'b0, 1'b0, 1'b1, "S6 overlay 001");
        smk_mode(16'o000140, "S6 STD11+overlay");
        check(16'o100000, MK_ROM, rom_bank(2'd0, 16'o100000), "S6 STD11 overlay");
        check_std(16'o120000, "S6 STD11 overlay diff");
        map_write(16'o004000 | 16'o010, 1'b0, 1'b0, 1'b1, "S6 overlay 010 empty");
        check(16'o100000, MK_NONE, '0, "S6 STD11 empty socket");
        // ...and banking writes must not have disturbed the SMK registers
        check_ext(16'o170000, 4'd0, 3'd7, 1'b0, "S6 banking kept SMK");
        map_write(16'o004000, 1'b0, 1'b0, 1'b1, "S6 banking reset");

        // ---- S7. page-bit scatter {v0, v3, v2, v10} -------------------------
        smk_mode(16'o002120, "S7 page1 v10");
        check_ext(16'o100000, 4'd1, 3'd0, 1'b0, "S7 page1 seg0");
        check_ext(16'o170000, 4'd1, 3'd7, 1'b0, "S7 page1 seg7");
        smk_mode(16'o000124, "S7 page2 v2");
        check_ext(16'o100000, 4'd2, 3'd0, 1'b0, "S7 page2 seg0");
        smk_mode(16'o000130, "S7 page4 v3");
        check_ext(16'o100000, 4'd4, 3'd0, 1'b0, "S7 page4 seg0");
        smk_mode(16'o000121, "S7 page8 v0");
        check_ext(16'o100000, 4'd8, 3'd0, 1'b0, "S7 page8 seg0");
        smk_mode(16'o002135, "S7 page15 all");
        check_ext(16'o100000, 4'd15, 3'd0, 1'b0, "S7 page15 seg0");
        check_ext(16'o176776, 4'd15, 3'd7, 1'b0, "S7 page15 seg7 top");

        // ---- S8. seg-7 extent boundary matrix (176776 | 177000) ------------
        // ALL: extent readable (ro), boundary exact, incl. the I/O page
        smk_mode(16'o000020, "S8 ALL");
        check_ext (16'o176776, 4'd0, 3'd3, 1'b0, "S8 ALL below boundary rw");
        check_extd(16'o177000, 4'd0, 3'd3, 1'b1, 1'b0, "S8 ALL extent lo");
        check_extd(16'o177576, 4'd0, 3'd3, 1'b1, 1'b0, "S8 ALL extent mem top");
        check_extd(16'o177716, 4'd0, 3'd3, 1'b1, 1'b0, "S8 ALL extent 177716");
        check_extd(16'o177776, 4'd0, 3'd3, 1'b1, 1'b0, "S8 ALL extent top");
        // HLT10: extent writable (wo), boundary exact
        smk_mode(16'o000100, "S8 HLT10");
        check_ext (16'o176776, 4'd0, 3'd7, 1'b0, "S8 HLT10 below boundary rw");
        check_extd(16'o177000, 4'd0, 3'd7, 1'b0, 1'b1, "S8 HLT10 extent lo");
        check_extd(16'o177676, 4'd0, 3'd7, 1'b0, 1'b1, "S8 HLT10 extent 177676");
        check_extd(16'o177776, 4'd0, 3'd7, 1'b0, 1'b1, "S8 HLT10 extent top");
        // STD10: extent neither -> the cap holds across the whole extent
        smk_mode(16'o000060, "S8 STD10");
        check_ext(16'o176776, 4'd0, 3'd7, 1'b0, "S8 STD10 below boundary rw");
        check(16'o177000, MK_NONE, '0, "S8 STD10 extent capped lo");
        check(16'o177776, MK_NONE, '0, "S8 STD10 extent capped top");

        // ---- S9. DCLO: -> SYS, page 0, strobe DISARMED ----------------------
        smk_write(16'o000006, 1'b0, 1'b0, "S9 arm before DCLO");
        @(negedge sclk) rst = 1'b1;
        repeat (2) @(posedge sclk);
        @(negedge sclk) rst = 1'b0;
        #1;
        smk_write(16'o000120, 1'b0, 1'b0, "S9 post-DCLO commit attempt");
        check(16'o100000, MK_NONE, '0, "S9 DCLO disarmed strobe");
        check_ext(16'o120000, 4'd0, 3'd6, 1'b0, "S9 DCLO -> SYS");

        // ---- S10. enable/model flips are decode-only (content kept) ---------
        smk_mode(16'o000124, "S10 RAM10 page2");
        check_ext(16'o100000, 4'd2, 3'd0, 1'b0, "S10 set");
        smk_en = 1'b0; #1;
        sweep_diff("S10 diff smk-off again");
        smk_en = 1'b1; #1;
        check_ext(16'o100000, 4'd2, 3'd0, 1'b0, "S10 dip flip kept");
        model_bk11 = 1'b0; #1;
        sweep_diff("S10 bk10 diff");
        model_bk11 = 1'b1; #1;
        check_ext(16'o100000, 4'd2, 3'd0, 1'b0, "S10 model flip kept");

        if (errors == 0) $display("COSIM PASS");
        else             $display("COSIM FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
