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
//     RAM page used when no ROM code matched.
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
module mem_mapper #(
    parameter int ADDR_BITS = 24
) (
    // ---- map-register write snoop (sclk domain, DOUT-window sampled) -----
    input  logic        sclk,        // sys_clk
    input  logic        rst,         // active high = ~dclo_n (DCLO ONLY - no nINIT)
    input  logic        model_bk11,  // DIP 1 latched during DCLO hold (quasi-static)
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
    output logic [ADDR_BITS-1:0] phys    // physical SDRAM word address
);

    import qbus_pkg::*;

    // ---- mapping state (reset = config 0) ---------------------------------
    logic [2:0] win0_page;      // window 0 RAM page
    logic [2:0] win1_page;      // window 1 RAM page (when no ROM overlay)
    logic       win1_rom_en;    // window 1 shows a ROM overlay bank
    logic [1:0] win1_rom_bank;

    // A banking write is a word write to 177716 with bit 11 set. Idempotent
    // across the multi-sclk DOUT window (like the spk_bit capture): the data
    // lines are stable for the whole window, so re-capturing is harmless.
    assign bank_wr = model_bk11 && !sync_n && !dout_n && !sel1_n
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

    // ---- translate ---------------------------------------------------------
    // Physical addresses are pure concatenations onto the power-of-two-aligned
    // bases from qbus_pkg (no adders). Fed by the transparent SYNC address
    // latch, so it may glitch mid-address-phase exactly like the old inline
    // sel_ram - every consumer samples on a clock edge.
    always_comb begin
        if (!model_bk11) begin
            // BK-0010: bit-identical to the pre-Phase-7 inline decode.
            if (addr < RAM_TOP) begin
                kind = MK_RAM037;
                phys = ADDR_BITS'(addr[15:1]);
            end else if (addr < IO_BASE) begin
                kind = MK_ROM;
                phys = ADDR_BITS'(addr[15:1]);
            end else begin
                kind = MK_NONE;
                phys = '0;
            end
        end else begin
            case (addr[15:14])
                2'b00: begin        // 000000-037777: fixed RAM page 6
                    kind = MK_RAM037;
                    phys = ADDR_BITS'(BK11_RAM_BASE) | ADDR_BITS'({3'd6, addr[13:1]});
                end
                2'b01: begin        // 040000-077777: window 0 (always RAM)
                    kind = MK_RAM037;
                    phys = ADDR_BITS'(BK11_RAM_BASE) | ADDR_BITS'({win0_page, addr[13:1]});
                end
                2'b10: begin        // 100000-137777: window 1 (ROM overlay or RAM)
                    if (win1_rom_en) begin
                        kind = MK_ROM;
                        phys = ADDR_BITS'(BK11_WROM_BASE)
                             | ADDR_BITS'({win1_rom_bank, addr[13:1]});
                    end else begin
                        // Window-1 RAM: 037-owned (MK_RAM037), NOT a fixed reply.
                        // On real HW the 037 fronts this too (its AD15 is forced
                        // low by the banking network); qbus_mem derives ext_ram
                        // from (this MK_RAM037 access having A15=1) and feeds it
                        // to va_037_sync's a15_037. phys is the win1 RAM page.
                        kind = MK_RAM037;
                        phys = ADDR_BITS'(BK11_RAM_BASE)
                             | ADDR_BITS'({win1_page, addr[13:1]});
                    end
                end
                default: begin      // 140000-177777: fixed top ROM, then I/O
                    if (addr < IO_BASE) begin
                        kind = MK_ROM;
                        phys = ADDR_BITS'(BK11_TOPROM_BASE) | ADDR_BITS'(addr[13:1]);
                    end else begin
                        kind = MK_NONE;
                        phys = '0;
                    end
                end
            endcase
        end
    end

endmodule
