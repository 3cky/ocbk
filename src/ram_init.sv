// ram_init - authentic DRAM power-on pattern filler (Phase 7 UX).
//
// Fills the selected model's BK RAM region in the board SDRAM with the
// К565РУ6 (BK-0010) / К565РУ5 (BK-0011M) power-on garbage pattern that the
// bkemu-QT emulator reproduces (CMotherBoard[_11M]::InitMemoryValues, in
// devemu/Board.cpp / Board_11M.cpp). Each 16-bit word is all-ones or all-zeros
// per the per-model rule below, where idx is the emulator's linear word index.
// Every RAM page/bank base is 0x2000-word aligned (low 13 bits zero) and both
// rules use only bits < 13, so idx reduces to the physical word address w_addr:
//
//   BK-0010 (Board.cpp): val=~val every word plus an extra inversion every 64
//     words (the uint8_t flag==192 event) -> alternating 0/FFFF whose phase
//     flips at each 64-word boundary (idx 0 is 0; the flip makes idx 64,65
//     both 0). Closed form: word = idx[0] ^ idx[6] ^ (idx[5:0]==0 & idx!=0).
//   BK-0011M (Board_11M.cpp): 8-word blocks of 0/FFFF with one skipped flip
//     every 8th boundary -> a 16-word double block every 64 words. Closed
//     form: word = idx[3] ^ idx[6].
//
// The result is the real BK startup screen - a structured garbage pattern that
// MONITOR/BOS then clears - instead of undefined FPGA SDRAM noise.
//
// Phase 8 adds a SECOND fill segment: the SMK512's 512 KB (256 Kwords at
// SMK_RAM_BASE), zero-filled rather than patterned. bkemu-QT has no SMK512
// board, so there is no authoritative power-on pattern for it (its Board_EXT32
// / Board_*_FDD only continue the HOST machine's own linear rule across their
// extension arrays - no help for a third-party МПИ board with unknown DRAM);
// all-zeros is a defined state, and it is what every SMK oracle already assumes.
// Seg 1 is model-independent, so only power-on or a DIP-8 0->1 transition fills
// it - a model change never does, and a same-configuration warm reset preserves
// it (the SMK BIOS's RAM-BIOS copy must survive a reset, smk64.mac MOD$S).
//
// Runs while the CPU is held in DCLO and the EPCS loader is done (enable), so
// arbiter port 0 is otherwise idle; the top level muxes this and epcs_boot onto
// the shared port-0 boot-writer port (bw_*), so qbus_mem is unchanged. Follows
// the same served-mask contract as every port-0 writer: assert w_req with the
// payload stable until w_gnt, then drop w_req for one cycle (the req/gap toggle
// below) before the next word - sdram_arbiter holds a granted port ineligible
// until it sees w_req low again.
//
// Trigger: fill at power-on (ram_valid=0) and re-fill on a warm reset ONLY when
// the model changed (model_bk11 != model_seen). model_bk11 only ever changes
// while DCLO is held (ocbk_top's latch), so a re-fill always lands inside a
// reset hold with the CPU parked. A same-model warm reset leaves RAM untouched
// (BK reset semantics). Segment 1 has its own sticky smk_valid: it fills when
// smk_en is set and the region has never been filled since power-on. Both flags
// are keyed to rst_n = srst_n = power-on only, so they survive warm resets; a
// DIP-8 off->reset->on round trip therefore does NOT re-zero, because the
// content really did survive. fill_busy holds the CPU past the warm-reset tail
// until the fill finishes; blank_pulse (a MAIN-RAM re-fill only, i.e. ram_valid
// already 1) clears fb_video's fb_front_valid so the display blacks out then
// reveals the fresh pattern - the first power-on fill needs no pulse (the
// existing power-on black-out already hides it) and an SMK-only fill never
// needs one (SMK RAM is never displayed).
module ram_init #(
    parameter int ADDR_BITS = 24
) (
    input  logic                 clk,        // sys_clk
    input  logic                 rst_n,      // srst_n (power-on only)
    input  logic                 model_bk11, // DIP-1 model select (DCLO-stable)
    input  logic                 smk_en,     // DIP-8 SMK512 enable (DCLO-stable)
    input  logic                 enable,     // boot done & port 0 free (CPU held)

    // ---- SDRAM write port (top-level 2:1 mux with epcs_boot onto port 0) ----
    output logic                 w_req,
    output logic [ADDR_BITS-1:0] w_addr,
    output logic [15:0]          w_wdata,
    input  logic                 w_gnt,

    // ---- status ------------------------------------------------------------
    output logic                 fill_active, // owns the port-0 mux while high
    output logic                 fill_busy,   // hold the CPU until this drops
    output logic                 blank_pulse  // 1-cyc: re-fill -> clear fb valid
);

    // Per-model fill range (word addresses); bases are 0x2000-word aligned.
    //   bk10: 0x00000..0x03FFF (16384 words, incl. fixed video page 0x2000)
    //   bk11: 0x20000..0x2FFFF (65536 words, incl. video pages 0x22000/0x2E000)
    localparam logic [23:0] BASE10 = 24'h000000, LAST10 = 24'h003FFF;
    localparam logic [23:0] BASE11 = 24'h020000, LAST11 = 24'h02FFFF;

    // Segment 1: the SMK512's 256 Kwords. Must track qbus_pkg::SMK_RAM_BASE -
    // this module is deliberately compiled standalone by sim/raminit/run.sh
    // (no package import), the same convention as mem_mapper's
    // WIN1_ROM_PRESENT tracking the boot-blob zero-fill.
    localparam logic [23:0] BASESMK = 24'h040000, LASTSMK = 24'h07FFFF;

    wire [ADDR_BITS-1:0] base = model_bk11 ? BASE11 : BASE10;
    wire [ADDR_BITS-1:0] last = model_bk11 ? LAST11 : LAST10;

    logic ram_valid;    // 0 at power-on -> the first main fill; then stays 1
    logic smk_valid;    // 0 at power-on -> the first SMK fill; then stays 1
    logic model_seen;   // the model whose pattern currently occupies RAM
    logic filling;      // a fill pass is in progress
    logic issuing;      // 1 = w_req asserted this word, 0 = the one-cycle gap
    logic seg;          // 0 = machine RAM, 1 = SMK RAM
    logic seg_next;     // pending seg 0 -> seg 1 hand-over (taken in the gap)

    wire need_main = !ram_valid || (model_bk11 != model_seen);
    wire need_smk  = smk_en && !smk_valid;
    assign fill_busy   = need_main || need_smk || filling;
    assign fill_active = filling;

    wire [ADDR_BITS-1:0] cur_last = seg ? LASTSMK : last;

    // The next word's address/segment, i.e. what this cycle loads into w_addr.
    wire [ADDR_BITS-1:0] start_addr = need_main ? base : BASESMK;
    wire                 start_seg  = !need_main;
    wire [ADDR_BITS-1:0] gap_addr   = seg_next ? BASESMK : (w_addr + 1'b1);
    wire                 gap_seg    = seg_next | seg;

    // Pattern word: combinational from the (stable-while-req) write address.
    // bk10 (Board.cpp InitMemoryValues): idx[0]^idx[6] with a phase flip at each
    //   64-word boundary (the uint8_t flag==192 extra inversion); idx 0 = 0.
    //   The & (|w_addr) term (== idx!=0) suppresses the flip at idx 0 only.
    // bk11 (Board_11M.cpp InitMemoryValues): idx[3]^idx[6].
    // idx == w_addr (0x2000-aligned bases, bits used < 13).
    // Seg 1 (SMK RAM) is zero-filled - see the header - and that is folded into
    // the single pattern BIT rather than muxed onto the 16-bit word on purpose:
    // w_wdata feeds the port-0 boot-writer mux and from there cpu_sdram_dp's
    // write-data mux, whose select side (the mapper's commit-decoded flags) is
    // a chronic sys_clk critical path. Keeping w_wdata a pure replication of
    // one net leaves that mux's 16 data inputs driven directly, as they were
    // before the SMK segment existed; a 16-bit 2:1 mux here put a LUT on every
    // one of them and cost ~0.34 ns of sys_clk slack (measured).
    wire valb10 = w_addr[0] ^ w_addr[6] ^ ((w_addr[5:0] == '0) & (|w_addr));
    wire valb11 = w_addr[3] ^ w_addr[6];
    wire valb   = ~seg & (model_bk11 ? valb11 : valb10);
    assign w_wdata = {16{valb}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_valid   <= 1'b0;
            smk_valid   <= 1'b0;
            model_seen  <= 1'b0;
            filling     <= 1'b0;
            issuing     <= 1'b0;
            seg         <= 1'b0;
            seg_next    <= 1'b0;
            w_req       <= 1'b0;
            w_addr      <= '0;
            blank_pulse <= 1'b0;
        end else begin
            blank_pulse <= 1'b0;            // default: single-cycle pulse
            if (w_gnt) w_req <= 1'b0;       // served-mask contract

            if (!filling) begin
                // One pass covers every needed segment, machine RAM first.
                if (enable && (need_main || need_smk)) begin
                    filling     <= 1'b1;
                    issuing     <= 1'b1;
                    seg         <= start_seg;
                    seg_next    <= 1'b0;
                    w_addr      <= start_addr;
                    w_req       <= 1'b1;
                    // main re-fill (model change) -> blank; SMK never displays
                    blank_pulse <= need_main & ram_valid;
                end
            end else if (issuing) begin
                if (w_gnt) begin
                    issuing <= 1'b0;              // enter the one-cycle gap
                    if (w_addr == cur_last) begin // last word of this segment
                        if (!seg) begin
                            model_seen <= model_bk11;
                            ram_valid  <= 1'b1;
                            if (need_smk) seg_next <= 1'b1;  // hand over to seg 1
                            else          filling  <= 1'b0;
                        end else begin
                            smk_valid <= 1'b1;
                            filling   <= 1'b0;
                        end
                    end
                end
            end else begin                     // gap cycle: advance and re-issue
                seg      <= gap_seg;           // seg_next = the seg 0 -> 1 hand-over
                seg_next <= 1'b0;
                w_addr   <= gap_addr;
                w_req    <= 1'b1;
                issuing  <= 1'b1;
            end
        end
    end

endmodule
