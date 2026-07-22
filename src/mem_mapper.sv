// mem_mapper - the qbus_mem memory-mapper sub-module (Phase 7, BK-0011M banking).
//
// One config-driven translation seam: (CPU address, mapping registers) ->
// (physical SDRAM word, region kind). The region kind encodes both the RPLY
// owner and writability (see qbus_pkg MK_*). In BK-0010 mode (model_bk11=0)
// the translate is BIT-IDENTICAL to the pre-Phase-7 inline decode in qbus_mem
// (RAM < 100000 -> MK_RAM037, ROM 100000-177577 -> MK_ROM, else MK_NONE, all
// at phys = addr[15:1]) and none of the mapping state participates - every
// existing timing golden stays the regression anchor.
//
// BK-0011M semantics (canonical reference: BkEmu Bk11MemoryManager.java):
//   000000-037777  fixed RAM page 6            (037-owned, MK_RAM037)
//   040000-077777  window 0: RAM page 0-7      (037-owned, MK_RAM037)
//   100000-137777  window 1: RAM page 0-7 (MK_RAM037 - 037-owned RPLY, same as
//                  the low 32K: on real HW the 037 fronts ALL internal RAM, its
//                  AD15 forced low by the banking network for a window-1 RAM
//                  access; qbus_mem exports ext_ram so va_037_sync forces A15
//                  low - see the a15_037 note there) OR one of 4 ROM overlay
//                  banks (MK_ROM)
//   140000-177577  fixed top ROM               (MK_ROM)
//   177600-177777  I/O page - undecoded here   (MK_NONE; the SEL-pin registers
//                  are decoded in qbus_mem, orthogonal to the mapper)
//
// The mapping register is the 177716 write side, bit 11 = ENABLE:
//   * a WORD write with bit 11 set is a BANKING write: bits 14:12 = window-0
//     RAM page; the ROM field is (value & 0o033), decoded ONLY as the exact
//     single-bit codes 001/002/010/020 -> ROM bank 0/1/2/3 into window 1; ANY
//     other 033 combination falls through to RAM (a BkEmu quirk - e.g. 003 or
//     033 select no ROM - replicated deliberately); bits 10:8 = the window-1
//     RAM page used when no ROM code matched. Banks 0/1 (001/002) are BASIC;
//     banks 2/3 (010/020) are the UNPOPULATED sockets of a stock BK-0011M -
//     selecting one maps window 1 to a MK_NONE (no reply -> trap 4) region, not
//     RAM: an empty socket has no chip, so BOS's reverse ROM probe times out and
//     skips it (see WIN1_ROM_PRESENT below).
//   * the register is WRITE-ONLY: reads of 177716 return the system bits
//     (qbus_mem's io_word), never the map.
//   * banking writes must NOT update spk_bit/mot_bit and peripheral writes
//     (bit 11 clear) must NOT touch the map - the bank_wr output is the
//     mutual-exclusion gate qbus_mem uses.
//   * byte-write contract (pinned by the mapper oracle + spk_capture_tb):
//     banking requires a WORD write - wtbt_n released (=1) at DOUT time and
//     addr[0]=0. A low-byte write cannot carry bit 11; a 177717 high-byte
//     write is NOT a banking write (its data bit 3 is not an ENABLE).
//
// Reset: DCLO ONLY - there is deliberately NO nINIT port. BkEmu semantics: a
// hardware reset re-inits the map to config 0 (window 0 -> page 0, window 1 ->
// RAM page 0), but the RESET instruction (which pulses nINIT) PRESERVES it - a
// RESET executed from a banked window must not swap the page under the running
// code. This is a documented exception to the "peripherals reset on nINIT"
// rule, like the software-owned spk_bit latch (checked behaviourally by the
// bk11 SoC oracle's RESET-instruction case).
//
// Clock-domain note: the map register lives on sclk (sys_clk), its consumers
// are the cpu_clk wait FSM and the sclk datapath. Safe by construction: the
// register only changes during a 177716 DOUT window - a cycle that decodes as
// I/O, never as memory - and cpu_clk is the same divided clock tree, so the
// new map is stable long before the next SYNC address latch.
//
// Phase-8 hook: window ownership is a selectable source - the SMK512 (or any
// other expansion mapper) layers in HERE as an alternative page/bank source,
// not as another decode strewn through qbus_mem.
//
// Phase 8 (SMK512, increment 1): the 512 KB segmented RAM extension layers in
// exactly at that hook, as a second translate stage over the bk11 decode.
// Canonical reference: BkEmu SmkMemoryManager.java (+ its unit test) - MiSTer
// rtl/memory.sv was cross-checked and loses every dispute (reset default,
// strobe arming width). Contract:
//   * control register = 177130 (the floppy control register the SMK
//     "ab-uses"; no floppy is modelled - reads stay un-replied -> trap 4).
//     TWO-PHASE STROBE: every write recomputes strobe = (value & 017) == 06;
//     a layout commit fires on the strobe FALLING edge - the write FOLLOWING
//     an arming write, carrying the new mode+page in its own value. Byte
//     writes are lane-masked as BkEmu's Computer.writeMemory dispatches them
//     (odd byte = value << 8, even byte = the raw byte; unverified against
//     real hardware - the GAL may latch both lanes).
//   * committed word: mode = v[6:4]; page = {v[0], v[3], v[2], v[10]}
//     (v0 = MSB; 16 pages x 32 KB). The 100000-177777 space is 8 x 4 KB
//     segments (seg = addr[14:12]); a mapped segment shows SMK RAM absolute
//     segment page*8 + rel where rel = seg, +4-rotated (seg ^ 4) in SYS/ALL.
//   * per-mode segment sources: see the table at the mode case below.
//     MK_EXT = SMK RAM (FSM-owned fixed N_EXT reply in qbus_mem - an external
//     controller's RAM is NOT 037-fronted/cycle-stolen); smk_ro flags HLT10's
//     read-only seg 0 AND the ALL-mode extent (write -> no reply -> trap 4,
//     the MK_ROM write rule); smk_wo flags the HLT-mode write-only extent
//     (read -> no reply -> trap 4, the mirror).
//   * SMK BIOS ROM (increment 2): ONE 4 KB image (mem/roms/smk512_v205.rom,
//     at SDRAM SMK_BIOS_BASE via the bk11 blob) backs BOTH selectable
//     windows - rom6 @ 160000 (selected in SYS, STD10, STD11) and rom7
//     @ 170000 (SYS only). MK_ROM: reads ride the SDRAM path, writes are not
//     selected -> trap 4 (BkEmu ReadOnlyMemory -> BUS_ERROR). THE BOOT HACK
//     (what makes DIP-8-ON boot): in SYS the rom7 window covers the FULL
//     0170000-0177777 INCLUDING the register space, so the vm1's initial
//     start read of 177716 returns the BIOS word at image offset 0o7716
//     (= 0o166400), OR-merged with SEL1 on the open-collector bus; the CPU
//     masks with 0o177400 -> PC = 166400, inside rom6. (qbus_mem owns the
//     I/O-page reply policy and carve-outs; this module just translates.)
//   * seg-7 restricted extent 0177000-0177777 (past BkEmu
//     MEMORY_SEGMENT_7_NON_RESTRICTED_SIZE), per mode: ALL = readable only
//     (smk_ro), HLT10/HLT11 = writable only (smk_wo - what catches the vm1
//     HALT entry's 177674/76 PC/PSW stores, the SMK HALT-debugger mechanism:
//     the HALT vector {PC,PSW} is then fetched from 160002/4 = SMK RAM seg 6
//     in HLT10); every other mode = neither -> MK_NONE (the cap).
//   * reset = DCLO ONLY to mode SYS / page 0 / strobe disarmed (BkEmu init()
//     re-inits on hardwareReset only - the map/662/spk nINIT-exception family).
//   * bk10 + SMK is NOT wired: every SMK term here and in qbus_mem is gated
//     smk_en && model_bk11, so DIP8 + BK-0010 is a no-op. BkEmu's
//     BK_0010_SMK512 config (monitor-ROM deselect) is a later item.
// The refined 177130 invariant (pinned by the oracles): the mapper never
// claims the WRITE reply at 177130 - the qbus_mem positive write decode is
// the sole write owner. In SYS its translation is MK_ROM (read-only kind;
// reads return BIOS data), in HLT modes MK_EXT write-only whose u_dp write
// leg issues on the PRE-commit translate (= BkEmu's memory-then-device write
// order), so a mode write can never re-map its own in-flight cycle. With SMK
// off it stays plain MK_ROM: a write keeps bus-timing-out (sim/romwr).
module mem_mapper #(
    parameter int ADDR_BITS = 24
) (
    // ---- map-register write snoop (sclk domain, DOUT-window sampled) -----
    input  logic        sclk,        // sys_clk
    input  logic        rst,         // active high = ~dclo_n (DCLO ONLY - no nINIT)
    input  logic        model_bk11,  // DIP 1 latched during DCLO hold (quasi-static)
    input  logic        smk_en,      // DIP 8 latched during DCLO hold (quasi-static):
                                     // SMK512 present (BK-0011M only this increment)
    input  logic        sync_n,
    input  logic        dout_n,
    input  logic        wtbt_n,      // at DOUT time: 0 = byte op (dual-purpose WTBT)
    input  logic        sel1_n,      // CPU nSEL1 = 177716/17 select
    input  logic [15:0] ad_true,     // current bus data (true = ~ad_n)
    input  logic        addr0,       // latched addr[0] (1 = the 177717 odd byte)
    output logic        bank_wr,     // this DOUT window is a banking write
                                     // (combinational; qbus_mem's spk/mot gate)

    // ---- combinational translate ------------------------------------------
    input  logic [15:0]          addr,   // latched bus address (true polarity)
    output logic [1:0]           kind,   // MK_* region kind (owner + writability)
    output logic [ADDR_BITS-1:0] phys,   // physical SDRAM word address
    output logic                 smk_ro, // with kind==MK_EXT: read-only (HLT10
                                         // seg 0 / ALL extent) - qbus_mem
                                         // withholds the write reply -> trap 4
    output logic                 smk_wo  // with kind==MK_EXT: write-only (HLT
                                         // extent) - qbus_mem withholds the
                                         // read reply -> trap 4
);

    import qbus_pkg::*;

    // ---- mapping state (reset = config 0) ---------------------------------
    logic [2:0] win0_page;      // window 0 RAM page
    logic [2:0] win1_page;      // window 1 RAM page (when no ROM overlay)
    logic       win1_rom_en;    // window 1 shows a ROM overlay bank
    logic [1:0] win1_rom_bank;

    // Which window-1 ROM overlay banks are POPULATED. Stock BK-0011M leaves the
    // two extra sockets (banks 2,3 = codes 010/020) physically EMPTY; the blob
    // zero-fills them (mem/gen_boot_blob.py). An access to an unpopulated socket
    // must get NO reply -> qbto -> trap 4 (authentic empty socket: no chip
    // drives the bus), so BOS's reverse 4->1 ROM probe skips it instead of
    // reading 000000 = HALT and boot-looping. Keep in sync with the blob.
    localparam logic [3:0] WIN1_ROM_PRESENT = 4'b0011; // banks 0,1 (BASIC) present

    // model_bk11 is quasi-static (latched only during a DCLO hold, frozen
    // while the CPU runs) but has large fanout across the whole design, so
    // the route from its ocbk_top latch into the bank_wr AND tree was the
    // design's worst sys_clk path for several builds running (-0.039 ns at
    // the CHS fix, -0.230 ns at CMD25, into win0_page). Re-register it here:
    // the long route becomes a plain flop-to-flop path and the bank_wr tree
    // is fed from a flop the fitter can place next to the map registers.
    // The 1-cycle latency is invisible - model_bk11 only ever changes while
    // DCLO is held (CPU parked, map registers in reset, thousands of sclk
    // before release), so it is stable for millions of cycles before any
    // banking write. Deliberately NOT used by the combinational translate
    // below (that cone is already met and its oracles compare decode
    // combinationally right after a model flip).
    logic model_bk11_q;
    always_ff @(posedge sclk)
        model_bk11_q <= model_bk11;

    // A banking write is a word write to 177716 with bit 11 set. Idempotent
    // across the multi-sclk DOUT window (like the spk_bit capture): the data
    // lines are stable for the whole window, so re-capturing is harmless.
    assign bank_wr = model_bk11_q && !sync_n && !dout_n && !sel1_n
                     && !addr0 && wtbt_n && ad_true[11];

    always_ff @(posedge sclk) begin
        if (rst) begin
            win0_page     <= 3'd0;
            win1_page     <= 3'd0;
            win1_rom_en   <= 1'b0;
            win1_rom_bank <= 2'd0;
        end else if (bank_wr) begin
            win0_page <= ad_true[14:12];
            win1_page <= ad_true[10:8];
            // ROM field: value & 0o033, exact single-bit codes only; every
            // other combination (003, 011, 030, 033, ...) selects NO ROM and
            // window 1 falls through to RAM - the BkEmu quirk, replicated.
            case (ad_true & 16'o033)
                16'o001: begin win1_rom_en <= 1'b1; win1_rom_bank <= 2'd0; end
                16'o002: begin win1_rom_en <= 1'b1; win1_rom_bank <= 2'd1; end
                16'o010: begin win1_rom_en <= 1'b1; win1_rom_bank <= 2'd2; end
                16'o020: begin win1_rom_en <= 1'b1; win1_rom_bank <= 2'd3; end
                default: win1_rom_en <= 1'b0;
            endcase
        end
    end

    // ---- Phase-8 SMK512 layout register (177130 write snoop) ---------------
    // The mode is stored PRE-DECODED as the per-segment source vectors (the
    // case table below runs on the commit edge, not in the translate cone):
    // decode-at-commit and decode-at-use are behaviourally identical - the
    // registers only change on the committing sclk edge either way - but the
    // translate's smk contribution shrinks to a 1-LUT vector index, keeping
    // the 8-way mode case OFF the sys_clk critical path (the translate feeds
    // the datapath output enables, whose cone loops through the bus pads back
    // into this module's register data pins - a functionally false path, DIN
    // and DOUT are mutually exclusive, but one the STA must see met).
    logic [3:0] smk_page;    // 32 KB page, {v0, v3, v2, v10}
    logic       smk_strobe;  // the two-phase arm flag
    logic [7:0] seg_smk;     // seg -> SMK RAM (abs seg = smk_page*8 + rel)
    logic [7:0] seg_std;     // seg -> standard bk11 decode passthrough
    logic       seg_rot;     // rel = seg ^ 4 (the SYS/ALL +4 rotation)
    logic       seg0_ro;     // seg 0 is read-only (HLT10)
    logic       rom6_en;     // seg 6 = SMK BIOS ROM window (SYS/STD10/STD11)
    logic       rom7_en;     // seg 7 = SMK BIOS ROM window incl. the register
                             // space - the boot overlay (SYS only)
    logic       ext7_r;      // seg-7 restricted extent readable (ALL)
    logic       ext7_w;      // seg-7 restricted extent writable (HLT10/HLT11)

    // A plain addressed write - no SEL pin (177130 is inside the ROM window;
    // qbus_mem carves the matching write reply out of sel_rom). Same
    // DOUT-window sampling as the banking snoop above.
    wire smk_reg_wr = smk_en && model_bk11 && !sync_n && !dout_n
                      && (addr[15:1] == 15'(16'o177130 >> 1));
    // BkEmu Computer.writeMemory lane dispatch: an odd-byte write arrives as
    // value << 8, an even-byte write as the raw byte, a word write whole. The
    // mask is load-bearing: an unmasked odd-byte write whose LOW lane happens
    // to carry x6 would re-arm instead of committing (pinned by the oracle's
    // junk-lane vector). Unverified against real hardware (the board GAL may
    // latch both lanes) - BkEmu is decreed authoritative.
    wire [15:0] smk_eff = wtbt_n  ? ad_true
                        : addr[0] ? {ad_true[15:8], 8'h00}
                                  : {8'h00, ad_true[7:0]};
    wire smk_eff_arm = (smk_eff[3:0] == 4'b0110);

    // Idempotent across the multi-sclk DOUT window: a committing write's first
    // edge commits AND lowers smk_strobe, so the window's later edges see the
    // arm already down and re-commit nothing; an arming write just re-arms.
    //
    // The mode case is a literal transcription of BkEmu
    // SmkMemoryManager.setupMemoryLayout as vectors/flags over the 8 segments
    // of 100000-177777: seg_smk (SMK RAM), seg_std (standard bk11 decode),
    // rom6_en/rom7_en (the BIOS windows), ext7_r/ext7_w (the seg-7 extent);
    // NEITHER seg_smk NOR seg_std NOR a rom window = MK_NONE (a deselected
    // window). Reset = MODE_SYS (BkEmu initMemoryLayout).
    always_ff @(posedge sclk) begin
        if (rst) begin
            smk_page   <= 4'd0;
            smk_strobe <= 1'b0;
            seg_smk    <= 8'b0011_1100;   // MODE_SYS
            seg_std    <= 8'b0000_0000;
            seg_rot    <= 1'b1;
            seg0_ro    <= 1'b0;
            rom6_en    <= 1'b1;           // MODE_SYS: both BIOS windows on -
            rom7_en    <= 1'b1;           // the 177716 boot overlay is live
            ext7_r     <= 1'b0;
            ext7_w     <= 1'b0;
        end else if (smk_reg_wr) begin
            smk_strobe <= smk_eff_arm;
            if (smk_strobe && !smk_eff_arm) begin
                smk_page <= {smk_eff[0], smk_eff[3], smk_eff[2], smk_eff[10]};
                seg0_ro  <= 1'b0;
                rom6_en  <= 1'b0;
                rom7_en  <= 1'b0;
                ext7_r   <= 1'b0;
                ext7_w   <= 1'b0;
                unique case (smk_eff[6:4])
                    // SYS: seg2..5 = P+6,7,0,1; seg6/7 = BIOS ROM (rom7 = the
                    // register-space boot overlay); win1 + BOS deselected ->
                    // seg0,1 NONE
                    3'd7:    begin seg_smk <= 8'b0011_1100; seg_std <= 8'b0000_0000; seg_rot <= 1'b1;
                                   rom6_en <= 1'b1; rom7_en <= 1'b1; end
                    // STD10: seg2..5 = P+2..5, seg7 = P+7 (extent neither);
                    // seg6 = BIOS ROM; seg0,1 NONE
                    3'd3:    begin seg_smk <= 8'b1011_1100; seg_std <= 8'b0000_0000; seg_rot <= 1'b0;
                                   rom6_en <= 1'b1; end
                    // RAM10: all eight segments = P+0..7 (extent neither)
                    3'd5:    begin seg_smk <= 8'b1111_1111; seg_std <= 8'b0000_0000; seg_rot <= 1'b0; end
                    // ALL: all eight, rotated (seg0..3 = P+4..7, seg4..7 =
                    // P+0..3); extent READABLE
                    3'd1:    begin seg_smk <= 8'b1111_1111; seg_std <= 8'b0000_0000; seg_rot <= 1'b1;
                                   ext7_r  <= 1'b1; end
                    // STD11: seg0..5 standard (window-1 banking + BOS),
                    // seg6 = BIOS ROM, seg7 = P+7 (extent neither)
                    3'd6:    begin seg_smk <= 8'b1000_0000; seg_std <= 8'b0011_1111; seg_rot <= 1'b0;
                                   rom6_en <= 1'b1; end
                    // RAM11: seg0..3 standard window 1, seg4..7 = P+4..7
                    3'd2:    begin seg_smk <= 8'b1111_0000; seg_std <= 8'b0000_1111; seg_rot <= 1'b0; end
                    // HLT10: all eight = P+0..7, seg0 READ-ONLY, extent WRITABLE
                    3'd4:    begin seg_smk <= 8'b1111_1111; seg_std <= 8'b0000_0000; seg_rot <= 1'b0;
                                   seg0_ro <= 1'b1; ext7_w <= 1'b1; end
                    // HLT11: seg0..3 standard window 1, seg4..7 = P+4..7,
                    // extent WRITABLE
                    default: begin seg_smk <= 8'b1111_0000; seg_std <= 8'b0000_1111; seg_rot <= 1'b0;
                                   ext7_w  <= 1'b1; end
                endcase
            end
        end
    end

    // ---- translate stage 1: the standard (pre-SMK) decode ------------------
    // Physical addresses are pure concatenations onto the power-of-two-aligned
    // bases from qbus_pkg (no adders). Fed by the transparent SYNC address
    // latch, so it may glitch mid-address-phase exactly like the old inline
    // sel_ram - every consumer samples on a clock edge.
    // This block is the pre-Phase-8 translate VERBATIM (only its outputs are
    // renamed kind_std/phys_std): with smk_en=0 the overlay stage below is a
    // wire-through, keeping bk10 AND plain-bk11 bit-identical - every existing
    // timing golden stays the regression anchor.
    logic [1:0]           kind_std;
    logic [ADDR_BITS-1:0] phys_std;
    always_comb begin
        if (!model_bk11) begin
            // BK-0010: bit-identical to the pre-Phase-7 inline decode.
            if (addr < RAM_TOP) begin
                kind_std = MK_RAM037;
                phys_std = ADDR_BITS'(addr[15:1]);
            end else if (addr < IO_BASE) begin
                kind_std = MK_ROM;
                phys_std = ADDR_BITS'(addr[15:1]);
            end else begin
                kind_std = MK_NONE;
                phys_std = '0;
            end
        end else begin
            case (addr[15:14])
                2'b00: begin        // 000000-037777: fixed RAM page 6
                    kind_std = MK_RAM037;
                    phys_std = ADDR_BITS'(BK11_RAM_BASE) | ADDR_BITS'({3'd6, addr[13:1]});
                end
                2'b01: begin        // 040000-077777: window 0 (always RAM)
                    kind_std = MK_RAM037;
                    phys_std = ADDR_BITS'(BK11_RAM_BASE) | ADDR_BITS'({win0_page, addr[13:1]});
                end
                2'b10: begin        // 100000-137777: window 1 (ROM overlay or RAM)
                    if (win1_rom_en && WIN1_ROM_PRESENT[win1_rom_bank]) begin
                        kind_std = MK_ROM;
                        phys_std = ADDR_BITS'(BK11_WROM_BASE)
                             | ADDR_BITS'({win1_rom_bank, addr[13:1]});
                    end else if (win1_rom_en) begin
                        // Unpopulated ROM socket (stock BK-0011M banks 2,3): no
                        // chip drives the bus -> MK_NONE -> no reply -> qbto ->
                        // trap 4. NOT the 033-quirk RAM fallthrough (that keeps
                        // win1_rom_en=0 and shows RAM); this is a selected but
                        // empty overlay code.
                        kind_std = MK_NONE;
                        phys_std = '0;
                    end else begin
                        // Window-1 RAM: 037-owned (MK_RAM037), NOT a fixed reply.
                        // On real HW the 037 fronts this too (its AD15 is forced
                        // low by the banking network); qbus_mem derives ext_ram
                        // from (this MK_RAM037 access having A15=1) and feeds it
                        // to va_037_sync's a15_037. phys is the win1 RAM page.
                        kind_std = MK_RAM037;
                        phys_std = ADDR_BITS'(BK11_RAM_BASE)
                             | ADDR_BITS'({win1_page, addr[13:1]});
                    end
                end
                default: begin      // 140000-177777: fixed top ROM, then I/O
                    if (addr < IO_BASE) begin
                        kind_std = MK_ROM;
                        phys_std = ADDR_BITS'(BK11_TOPROM_BASE) | ADDR_BITS'(addr[13:1]);
                    end else begin
                        kind_std = MK_NONE;
                        phys_std = '0;
                    end
                end
            endcase
        end
    end

    // ---- translate stage 2: the SMK512 segment overlay ----------------------
    // The per-mode segment sources live pre-decoded in the seg_* registers
    // (see the commit block above), so the smk contribution here is a 1-LUT
    // vector index + the priority mux - deliberately shallow, see the
    // critical-path note at the register declarations.
    wire [2:0] smk_seg = addr[14:12];
    wire [2:0] smk_rel = seg_rot ? (smk_seg ^ 3'b100) : smk_seg;
    // The overlay now covers ALL of 100000-177777 including the I/O page (the
    // rom7 boot overlay / the seg-7 extent both reach into it); qbus_mem owns
    // the I/O-page reply policy and carve-outs, this is translation only.
    // Every mode has rom7_en or seg_smk[7] set, so the I/O page is always
    // overlay-owned when SMK is on; its non-covered cases (the capped extent)
    // resolve to MK_NONE, exactly what kind_std says there.
    wire smk_act  = smk_en && model_bk11 && addr[15];
    // Seg-7 restricted extent: segment offsets >= 0o7000 bytes (words >=
    // 03400) = 177000-177777, per-mode readable/writable (see the header).
    wire seg_ext  = (smk_seg == 3'b111) && (addr[11:9] == 3'b111);

    always_comb begin
        smk_ro = 1'b0;
        smk_wo = 1'b0;
        if (smk_act && ((smk_seg == 3'd6 && rom6_en)
                     || (smk_seg == 3'd7 && rom7_en))) begin
            // SMK BIOS ROM: ONE 2048-word image, BOTH windows (rom7 spans the
            // whole segment incl. the register space - the boot overlay).
            kind = MK_ROM;
            phys = ADDR_BITS'(SMK_BIOS_BASE) | ADDR_BITS'(addr[11:1]);
        end else if (smk_act && seg_smk[smk_seg]) begin
            if (seg_ext && !ext7_r && !ext7_w) begin
                kind = MK_NONE;     // the cap: extent neither readable nor
                phys = '0;          // writable in this mode
            end else begin
                kind = MK_EXT;
                phys = ADDR_BITS'(SMK_RAM_BASE)
                     | ADDR_BITS'({smk_page, smk_rel, addr[11:1]});
                // HLT10 seg 0 / the ALL-mode read-only extent
                smk_ro = (seg0_ro && (smk_seg == 3'd0)) || (seg_ext && !ext7_w);
                // the HLT-mode write-only extent
                smk_wo = seg_ext && !ext7_r;
            end
        end else if (smk_act && !seg_std[smk_seg] && (addr < IO_BASE)) begin
            kind = MK_NONE;     // deselected window (SYS/STD10 segs 0,1)
            phys = '0;
        end else begin
            kind = kind_std;    // SMK off, bk10, or a std segment / I/O page
            phys = phys_std;
        end
    end

endmodule
