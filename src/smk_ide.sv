// ============================================================================
//  smk_ide - the SMK512 IDE drive controller (Phase-8 IDE increment (a)).
//
//  BkEmu is the authoritative reference: SmkIdeController (bus packing at
//  0177740-0177756, ~ bit-inversion BOTH directions) over IdeController (the
//  ATA task-file engine); IdeControllerTest is the transcribed oracle
//  (sim/ide). One MASTER drive; the slave is permanently absent (reads
//  0xFFFF through the inversion, command writes ignored). No interrupts
//  (the SMK has none). CHS only: a command with the DHR LBA bit set is
//  ABORTed - a DOCUMENTED DEVIATION from BkEmu (which supports LBA),
//  per the settled decision that no BK/SMK software uses LBA; it fails
//  loudly instead of mis-addressing.
//
//  Commands: IDENTIFY (0xEC), READ (0x20/0x21), WRITE (0x30/0x31);
//  everything else takes BkEmu's own default - abortCommand: status 0x41
//  (DRDY|ERR), error 0x04 (ABRT). DRQ is the data handshake; wherever the
//  engine is waiting on the BACKEND (the fetch before/between read blocks,
//  the commit after a write block) status reads SR_BSY - a real drive's
//  busy phase that BkEmu cannot show because its model is instantaneous
//  (it flashes 0x50 instead). A polling host cannot tell the difference
//  (it waits for DRQ / for !BSY, as the unit tb does), and WITHOUT the
//  BSY phase a driver polling "!BSY after the last data word" would see
//  command-complete while the commit is still in flight - the reason this
//  deviation is REQUIRED, not cosmetic. End-of-command status is BkEmu's
//  0x50 exactly.
//
//  Bus seam: this module NEVER drives ad_n/rply_n. It exports ide_rdata
//  (registered, TRUE bus value = ~packed core value; 0 outside its decode)
//  which qbus_mem ORs into its reply-point merge latch - reproducing BkEmu
//  Computer.readMemory's memory|device OR - and qbus_mem's sel_ide decode
//  owns the RPLY both directions (see the N_IDE note in qbus_pkg).
//
//  Reset is DCLO-ONLY (the 5th deliberate nINIT exception, after the map/
//  662/spk/СТОП registers): BkEmu's SmkIdeController.init resets only on a
//  HARDWARE reset - the RESET instruction must not reset the drive under
//  the running driver. Software resets ride the SRST control-register bit.
//
//  Backing store = a raw AltPro-format image holding TRUE data (the same
//  bytes BkEmu attaches - the ~ inversion lives entirely at this bus
//  adapter). Geometry comes from the AltPro partition table in image
//  sector 7 (checksum seed 012701), parsed by the init FSM below exactly
//  as BkEmu setupAltProGeometry; on any violation the BkEmu raw-image
//  default applies (S=63, H=16, C=total/1008 capped 16383) and a ZERO
//  cylinder count is an attach FAILURE (BkEmu throws) - the drive stays
//  absent.
//
//  Backend sector port (the increment-(b) SD/SPI seam; a behavioral tb
//  disk model in (a)): request/ack/done handshake, 28-bit sector index,
//  a bank field + the 2-bank sector buffer making tier-1 prefetch overlap
//  a later drop-in (increment (a) runs strictly sequential). All on sclk -
//  the SD engine is sys_clk too, so there is no CDC on this seam.
// ============================================================================

module smk_ide (
    input  logic        sclk,        // sys_clk
    input  logic        reset,       // = ~dclo_n (DCLO-only; NOT nINIT)
    input  logic        enable,      // smk_en && model_bk11 (quasi-static)

    // ---- Q-bus taps (observe-only; never driven) --------------------------
    input  logic [15:0] ad_n,
    input  logic        sync_n,
    input  logic        din_n,
    input  logic        dout_n,
    input  logic        wtbt_n,

    // ---- read data -> qbus_mem's reply-point OR-merge ---------------------
    output logic [15:0] ide_rdata,

    // ---- drive-activity tap (ocbk_top stretches it onto a LED) ------------
    // High while a command is in flight (DRQ data phases + backend
    // fetch/commit + the LBA math) or the backend port is busy - incl. the
    // attach-time geometry read (an authentic power-on blink). Register
    // pokes alone do NOT light it (a real HDD LED shows drive activity).
    output logic        ide_act,

    // ---- backend sector port (increment-(b) seam) -------------------------
    output logic        bk_req,      // level; hold until bk_ack
    output logic        bk_wr,       // 0 = read sector into bank, 1 = commit
    output logic [27:0] bk_sector,
    output logic        bk_bank,
    input  logic        bk_ack,      // backend accepted the request
    input  logic        bk_done,     // 1-cycle pulse: transfer complete
    input  logic        bk_error,    // with bk_done; data ops IGNORE it
                                     // (BkEmu ignores drive.read/write rc)
    input  logic        bk_media_ok, // backing store present + initialised
    input  logic [27:0] bk_total,    // total image sectors (MAX_LBA source)
    // backend-side buffer port (valid while serving a bk_wr commit)
    input  logic [7:0]  bk_baddr,
    input  logic [15:0] bk_wdata,
    input  logic        bk_we,
    output logic [15:0] bk_rdata
);

    // ---- task-file / status constants (BkEmu IdeController) ---------------
    localparam logic [7:0] SR_ERR  = 8'h01, SR_DRQ = 8'h08, SR_DSC = 8'h10,
                           SR_DRDY = 8'h40, SR_BSY = 8'h80;
    localparam logic [7:0] ER_ABRT = 8'h04;
    localparam logic [7:0] DHR_FIXED = 8'hA0;   // every DHR write ORs this
    localparam logic [7:0] CMD_IDENTIFY = 8'hEC;
    // 0x20/0x21 and 0x30/0x31 differ only in retry semantics - identical here.

    // ---- address latch + decode (the qbus_mem pattern) --------------------
    logic [15:0] addr;
    always_ff @(negedge sync_n) addr <= ~ad_n;

    wire       blk  = enable && (addr[15:4] == 12'hFFE);  // 0177740-0177757
    wire [2:0] ridx = addr[3:1];   // 0=COMP_0 .. 7=DATA (see map below)
    //  0: 177740 COMP_0  rd {drive-addr, status}   wr@740 = COMMAND
    //  1: 177742 COMP_1  rd {alt-status, DHR}      wr@742 = DHR, @743 = control
    //  2: 177744 CYL_HI          5: 177752 SECTOR COUNT
    //  3: 177746 CYL_LO          6: 177754 ERROR (rd) / FEATURES (wr, unused)
    //  4: 177750 SECTOR NUMBER   7: 177756 DATA

    // ---- register file ----------------------------------------------------
    logic [7:0]  status, error, snum, cyl_lo, cyl_hi, dhr;
    logic [8:0]  scount;        // 9-bit: checkSectorCount's 0 => 256 is a
                                // READABLE 0x100 in BkEmu (int register)
    logic        slave_sel;     // DHR DRV bit = current interface
    logic        ctrl_srst;     // last control-register SRST bit (edge det.)
    logic        attached;      // master drive attached (geometry FSM result)
    wire         cur_present = !slave_sel && attached;

    // ---- geometry (AltPro parse result / fallback) ------------------------
    logic [13:0] g_cyls;
    logic [4:0]  g_heads;       // 1..16
    logic [7:0]  g_secs;        // 1..255
    logic [27:0] g_capacity;    // C*H*S (IDENTIFY words 57/58)

    // ---- transfer state ---------------------------------------------------
    logic        drq;           // mirrors status[3]; the data-phase gate
    logic        xfer_ident;    // drain source: identify_word vs buffer
    logic        xfer_wr;       // current command is a WRITE
    logic [8:0]  ptr;           // word pointer within the 256-word block
    logic [13:0] x_cyl;         // engine-side CHS walk (mirrors the visible
    logic [4:0]  x_head;        //   registers; advanced per BkEmu's inverse
    logic [8:0]  x_snum;        //   setCurrentSectorNumber for in-range CHS)

    // ---- sector buffer: 2 banks x 256 x 16 = 2 M4Ks -----------------------
    // The fb_linebuf "plainest RAM" shape: ONE write-always block, ONE
    // registered-read-always block, same width both ports. Write sources
    // (CPU data-fill vs backend fetch) and read users (CPU drain / backend
    // commit / geometry parse) are muxed OUTSIDE the RAM - they are FSM-
    // state-exclusive.
    logic [15:0] sbuf [0:511];
    logic [8:0]  sb_waddr, sb_raddr;
    logic [15:0] sb_wdata, sb_q;
    logic        sb_we;
    always_ff @(posedge sclk) begin
        if (sb_we) sbuf[sb_waddr] <= sb_wdata;
        sb_q <= sbuf[sb_raddr];
    end
    assign bk_rdata = sb_q;

    // ---- engine FSM -------------------------------------------------------
    typedef enum logic [3:0] {
        G_WAIT,                 // wait for backing-store media
        G_FETCH7, G_NLD0, G_NLD1, G_SUM, G_GEO, G_CDIV, G_CAP1,
        E_IDLE,
        E_LBA1,                 // start (cyl*H + head)*S + snum-1 on E_MUL
                                //   (no divider anywhere: the per-sector CHS
                                //   advance is increment+wrap, identical to
                                //   BkEmu's div/mod for in-range CHS -
                                //   out-of-range garbage diverges, doc'd)
        E_MUL,                  // the serial multiplier + mul_ret chaining
        E_FETCH,                // backend read -> bank
        E_DRAIN,                // DRQ high, CPU reads words (buffer/identify)
        E_FILL,                 // DRQ high, CPU writes words
        E_COMMIT                // backend commit <- bank
    } est_t;
    est_t st;

    logic [27:0] lba_a;         // G_CDIV scratch (the default-geometry divide)
    logic [8:0]  g_ptr;         // parse word pointer (bank-1 buffer index)
    logic [8:0]  g_end;         // parse stop index
    logic [16:0] g_sum;         // checksum accumulator (mod 2^16 at compare)
    logic [7:0]  g_nld;
    logic [1:0]  g_sub;         // registered-read pacing subphase

    // ---- serial shift-add multiplier (E_MUL) -------------------------------
    // Cyclone I has no DSP blocks and a single-cycle (cyl*H)*S at sys_clk
    // broke setup by ~2 ns; the engine has bus-scale time budgets, so both
    // LBA stages and the geometry capacity ride ONE 1-bit-per-cycle
    // multiplier (acc += a when b[0]; a<<=1; b>>=1; done when b==0), with
    // mul_ret chaining stage 2 / the completion actions.
    localparam logic [1:0] MRET_LBA1 = 2'd0, MRET_LBA2 = 2'd1,
                           MRET_CAP1 = 2'd2, MRET_CAP2 = 2'd3;
    logic [27:0] mul_a, mul_acc;
    logic [7:0]  mul_b;
    logic [1:0]  mul_ret;

    // parse buffer words are stored INVERTED in the image (readInt16Inv).
    // REGISTERED (not a wire off sb_q): the geometry FSM's compares and
    // register-enable cones otherwise start at the M4K array output and
    // broke sys_clk closure (-2.9 ns into lba_a); the g_sub pacing gives
    // the extra cycle for free (decision at g_sub==2, sb_q valid at ==1).
    logic [15:0] g_val;
    always_ff @(posedge sclk) g_val <= ~sb_q;

    // ---- bus write capture (DOUT window) + release-edge action ------------
    // Data/lanes are captured live during the DOUT window (WTBT is BYTE at
    // DOUT time - the dual-purpose gotcha); the register/dispatch ACTION
    // fires once, at window close, so command dispatch and data-pointer
    // advance are single events per bus cycle (DATIO-safe: the DIN and DOUT
    // phases of an RMW each get their own event).
    logic        w_pend;
    logic [15:0] w_inv;         // ~bus = BkEmu invValue (the core-side value)
    logic        w_a0, w_byte;
    logic [2:0]  w_idx;

    // DATA-read pointer advance at DIN release (read data must hold past DIN
    // per the vm1 rule - the pointer only moves once the strobe is gone).
    logic        r_pend;
    logic        din_q;

    // ---- read packing (TRUE core values; inverted at the output reg) ------
    wire [7:0] head_n = dhr[3:0];
    // drive-address register: 0x30 | active-low DS (master=DS1) | head<<2
    // (DAR_HS3 overlaps the 0x20 base bit - BkEmu-faithful OR)
    wire [7:0] dar = cur_present
                     ? (8'h30 | (slave_sel ? 8'h01 : 8'h02) | (head_n << 2))
                     : 8'h00;

    // IDENTIFY word map (BkEmu identify(); strings byte-swapped-within-word,
    // space-padded; serial pinned "S/N:002" - BkEmu's first attached drive).
    function automatic logic [15:0] identify_word(input logic [7:0] i);
        case (i)
            8'd0:  identify_word = 16'h0040;             // fixed drive
            8'd1:  identify_word = {2'b00, g_cyls};
            8'd3:  identify_word = {11'b0, g_heads};
            8'd4:  identify_word = 16'(g_secs * 16'd512); // 512*S (mod 2^16)
            8'd5:  identify_word = 16'd512;
            8'd6:  identify_word = {8'b0, g_secs};
            8'd10: identify_word = 16'h532F;             // "S/"
            8'd11: identify_word = 16'h4E3A;             // "N:"
            8'd12: identify_word = 16'h3030;             // "00"
            8'd13: identify_word = 16'h3220;             // "2 "
            8'd14, 8'd15, 8'd16, 8'd17, 8'd18, 8'd19:
                   identify_word = 16'h2020;             // serial pad
            8'd20: identify_word = 16'd3;
            8'd21: identify_word = 16'd512;
            8'd22: identify_word = 16'd4;
            8'd23: identify_word = 16'h7630;             // "v0"
            8'd24: identify_word = 16'h2E30;             // ".0"
            8'd25: identify_word = 16'h3120;             // "1 "
            8'd26: identify_word = 16'h2020;
            8'd27: identify_word = 16'h424B;             // "BK"
            8'd28: identify_word = 16'h454D;             // "EM"
            8'd29: identify_word = 16'h5520;             // "U "
            8'd30: identify_word = 16'h4844;             // "HD"
            8'd31: identify_word = 16'h4420;             // "D "
            8'd32, 8'd33, 8'd34, 8'd35, 8'd36, 8'd37, 8'd38, 8'd39,
            8'd40, 8'd41, 8'd42, 8'd43, 8'd44, 8'd45, 8'd46:
                   identify_word = 16'h2020;             // model pad
            8'd47: identify_word = 16'h8010;             // 0x8000|MAX_MULT
            8'd48: identify_word = 16'd1;
            8'd49: identify_word = 16'h0200;             // capabilities: LBA
            8'd51: identify_word = 16'h0200;
            8'd53: identify_word = 16'd1;                // field valid
            8'd54: identify_word = {2'b00, g_cyls};
            8'd55: identify_word = {11'b0, g_heads};
            8'd56: identify_word = {8'b0, g_secs};
            8'd57: identify_word = g_capacity[15:0];     // C*H*S
            8'd58: identify_word = {4'b0, g_capacity[27:16]};
            8'd60: identify_word = bk_total[15:0];       // MAX_LBA = image
            8'd61: identify_word = {4'b0, bk_total[27:16]};
            default: identify_word = 16'h0000;           // incl. 59 (no MULT)
        endcase
    endfunction

    wire [15:0] data_word = xfer_ident ? identify_word(ptr[7:0]) : sb_q;

    // control-register data: byte write to 177743 carries the byte on the
    // HIGH bus lanes (invValue >>> 8); a word-context write uses the low byte
    wire srst_new = w_byte ? w_inv[10] : w_inv[2];

    logic [15:0] rd_word;
    always_comb begin
        case (ridx)
            3'd0: rd_word = {dar, cur_present ? status : 8'h00};
            3'd1: rd_word = {cur_present ? status : 8'h00,   // alt-status
                             cur_present ? dhr    : 8'h00};
            3'd2: rd_word = cur_present ? {8'h00, cyl_hi} : 16'h0;
            3'd3: rd_word = cur_present ? {8'h00, cyl_lo} : 16'h0;
            3'd4: rd_word = cur_present ? {8'h00, snum}   : 16'h0;
            3'd5: rd_word = cur_present ? {7'h00, scount} : 16'h0;
            3'd6: rd_word = cur_present ? {8'h00, error}  : 16'h0;
            3'd7: rd_word = cur_present ? data_word       : 16'h0;
        endcase
    end
    // TRUE bus value (the wire-OR contribution): ~packed inside the decode,
    // all-zeros outside it (an absent drive is ~0 = 0xFFFF - the signature
    // the SMK BIOS keys on). Registered - stable long before qbus_mem's
    // reply-point merge latch samples it.
    always_ff @(posedge sclk)
        ide_rdata <= blk ? ~rd_word : 16'h0000;

    always_ff @(posedge sclk)
        ide_act <= drq || bk_req
                   || (st == E_LBA1) || (st == E_MUL) || (st == E_FETCH)
                   || (st == E_DRAIN) || (st == E_FILL) || (st == E_COMMIT)
                   || (st == G_FETCH7);

    // ---- buffer port muxing (FSM-state-exclusive users) -------------------
    wire fill_wr = w_pend && dout_n && blk && (w_idx == 3'd7)
                   && (st == E_FILL) && drq;
    always_comb begin
        // write port: backend fetch owns it in the FETCH states, the CPU
        // data-fill otherwise (E_FILL only)
        if (st == E_FETCH || st == G_FETCH7) begin
            sb_waddr = {bk_bank, bk_baddr};
            sb_wdata = bk_wdata;
            sb_we    = bk_we;
        end else begin
            sb_waddr = {bk_bank, ptr[7:0]};
            // stored = invValue (BkEmu writeNextDataWord stores the ~bus
            // word): the CPU writes ~D to store D - the image round-trips
            // TRUE data, the inversion pair living entirely on the bus side
            sb_wdata = w_inv;
            sb_we    = fill_wr;
        end
        // read port: geometry parse in the G states, backend commit during
        // E_COMMIT, the CPU drain pointer otherwise
        if (st == G_NLD0 || st == G_NLD1 || st == G_SUM || st == G_GEO)
            sb_raddr = {1'b1, g_ptr[7:0]};
        else if (st == E_COMMIT)
            sb_raddr = {bk_bank, bk_baddr};
        else
            sb_raddr = {bk_bank, ptr[7:0]};
    end

    // ---- the engine + register file (one sclk process) --------------------
    // Order inside the block: FSM first, then bus-write actions (software
    // events win the same-edge race, as they would against BkEmu's
    // sequential model), then the capture/edge bookkeeping.
    wire [8:0] eff_count = (scount == 9'd0) ? 9'd256 : scount;

    always_ff @(posedge sclk) begin
        if (reset) begin
            status <= SR_DRDY; error <= 8'h01;
            snum <= 8'h01; scount <= 9'h001; cyl_lo <= 8'h00; cyl_hi <= 8'h00;
            dhr <= DHR_FIXED; slave_sel <= 1'b0; ctrl_srst <= 1'b0;
            attached <= 1'b0; drq <= 1'b0; xfer_ident <= 1'b0; xfer_wr <= 1'b0;
            ptr <= '0; st <= G_WAIT; bk_req <= 1'b0; bk_wr <= 1'b0;
            bk_bank <= 1'b0; bk_sector <= '0;
            g_cyls <= '0; g_heads <= '0; g_secs <= '0; g_capacity <= '0;
            lba_a <= '0; g_ptr <= '0; g_end <= '0; g_sum <= '0; g_nld <= '0;
            mul_a <= '0; mul_acc <= '0; mul_b <= '0; mul_ret <= MRET_LBA1;
            g_sub <= '0; x_cyl <= '0; x_head <= '0; x_snum <= '0;
            w_pend <= 1'b0; r_pend <= 1'b0; din_q <= 1'b1;
            w_inv <= '0; w_a0 <= 1'b0; w_byte <= 1'b0; w_idx <= '0;
        end else begin
            // ---------------- engine FSM ----------------
            unique case (st)
                // ---- geometry init (BkEmu attachDrive + setupGeometry) ----
                G_WAIT: if (bk_media_ok) begin
                    if (bk_total > 28'd7) begin
                        bk_req <= 1'b1; bk_wr <= 1'b0; bk_bank <= 1'b1;
                        bk_sector <= 28'd7;
                        st <= G_FETCH7;
                    end else begin              // no sector 7 -> raw default
                        lba_a <= bk_total; g_cyls <= '0;
                        st <= G_CDIV;
                    end
                end
                G_FETCH7: begin
                    if (bk_ack) bk_req <= 1'b0;
                    if (bk_done) begin
                        if (bk_error) begin     // unreadable -> raw default
                            lba_a <= bk_total; g_cyls <= '0;
                            st <= G_CDIV;
                        end else begin
                            g_ptr <= 9'd252;    // byte 0770: numLD word
                            g_sub <= '0;
                            st <= G_NLD0;
                        end
                    end
                end
                G_NLD0: begin                   // registered-read pacing
                    g_sub <= g_sub + 1'b1;
                    if (g_sub == 2'd2) begin
                        g_sub <= '0;
                        if ((g_val[7:0]) > 8'd125) begin
                            lba_a <= bk_total; g_cyls <= '0;
                            st <= G_CDIV;       // invalid table -> default
                        end else begin
                            g_nld <= g_val[7:0];
                            // checksum word: byte 0770 - numLD*4 - 2
                            g_ptr <= 9'd252 - {g_val[6:0], 1'b0} - 9'd1;
                            g_end <= 9'd255;    // ... through byte 0776
                            g_sum <= '0;
                            st <= G_NLD1;
                        end
                    end
                end
                G_NLD1: begin                   // seed word
                    g_sub <= g_sub + 1'b1;
                    if (g_sub == 2'd2) begin
                        g_sub <= '0;
                        g_sum <= {1'b0, g_val};
                        g_ptr <= g_ptr + 1'b1;
                        st <= G_SUM;
                    end
                end
                G_SUM: begin                    // subtract cp+1 .. 255
                    g_sub <= g_sub + 1'b1;
                    if (g_sub == 2'd2) begin
                        g_sub <= '0;
                        g_sum <= g_sum - {1'b0, g_val};
                        if (g_ptr == g_end) begin
                            g_ptr <= 9'd253;    // S then H then C
                            st <= G_GEO;
                        end else
                            g_ptr <= g_ptr + 1'b1;
                    end
                end
                G_GEO: begin
                    g_sub <= g_sub + 1'b1;
                    if (g_sub == 2'd2) begin
                        g_sub <= '0;
                        if (g_sum[15:0] != 16'o012701) begin
                            lba_a <= bk_total; g_cyls <= '0;
                            st <= G_CDIV;       // checksum bad -> default
                        end else begin
                            unique case (g_ptr)
                                9'd253: begin   // S: 1..255
                                    if (g_val[15:0] == '0 || g_val[15:8] != '0)
                                        begin lba_a <= bk_total; g_cyls <= '0;
                                              st <= G_CDIV; end
                                    else begin g_secs <= g_val[7:0];
                                               g_ptr <= 9'd254; end
                                end
                                9'd254: begin   // H (low byte): 1..16
                                    if (g_val[7:0] == '0 || g_val[7:0] > 8'd16)
                                        begin lba_a <= bk_total; g_cyls <= '0;
                                              st <= G_CDIV; end
                                    else begin g_heads <= g_val[4:0];
                                               g_ptr <= 9'd255; end
                                end
                                default: begin  // C: 1..16383
                                    if (g_val[15:0] == '0
                                        || g_val[15:14] != '0)
                                        begin lba_a <= bk_total; g_cyls <= '0;
                                              st <= G_CDIV; end
                                    else begin g_cyls <= g_val[13:0];
                                               st <= G_CAP1; end
                                end
                            endcase
                        end
                    end
                end
                // raw-image default geometry: S=63, H=16, C=total/1008
                // (iterative subtract - a constant divider costs more fabric
                // than this one-time ~16k-cycle loop at init); C==0 => the
                // BkEmu attach throws => the drive stays ABSENT.
                G_CDIV: begin
                    g_secs <= 8'd63; g_heads <= 5'd16;
                    if (lba_a >= 28'd1008 && g_cyls != 14'd16383) begin
                        lba_a  <= lba_a - 28'd1008;
                        g_cyls <= g_cyls + 1'b1;
                    end else if (g_cyls == '0)
                        st <= E_IDLE;           // attach failed: absent
                    else
                        st <= G_CAP1;
                end
                G_CAP1: begin                   // capacity = (C*H)*S on E_MUL
                    mul_a   <= {14'b0, g_cyls};
                    mul_b   <= {3'b0, g_heads};
                    mul_acc <= '0;
                    mul_ret <= MRET_CAP1;
                    st <= E_MUL;
                end

                // ---- command engine ----
                E_IDLE: ;                       // dispatch happens below
                E_LBA1: begin                   // start cyl*H + head
                    mul_a   <= {14'b0, x_cyl};
                    mul_b   <= {3'b0, g_heads};
                    mul_acc <= {23'b0, x_head};
                    mul_ret <= MRET_LBA1;
                    st <= E_MUL;
                end
                E_MUL: begin
                    if (mul_b != 8'd0) begin
                        if (mul_b[0]) mul_acc <= mul_acc + mul_a;
                        mul_a <= mul_a << 1;
                        mul_b <= mul_b >> 1;
                    end else begin
                        unique case (mul_ret)
                            MRET_LBA1: begin    // acc = cyl*H+head; now *S
                                mul_a   <= mul_acc;
                                mul_b   <= g_secs;
                                mul_acc <= {19'b0, x_snum} - 28'd1;
                                mul_ret <= MRET_LBA2;
                            end
                            MRET_LBA2: begin    // acc = the sector index
                                bk_sector <= mul_acc;
                                bk_req  <= 1'b1;
                                bk_wr   <= xfer_wr;
                                if (xfer_wr) st <= E_COMMIT;
                                else         st <= E_FETCH;
                            end
                            MRET_CAP1: begin    // acc = C*H; now *S
                                mul_a   <= mul_acc;
                                mul_b   <= g_secs;
                                mul_acc <= '0;
                                mul_ret <= MRET_CAP2;
                            end
                            MRET_CAP2: begin    // acc = capacity: attach done
                                g_capacity <= mul_acc;
                                attached <= 1'b1;
                                st <= E_IDLE;
                            end
                        endcase
                    end
                end
                E_FETCH: begin
                    if (bk_ack) bk_req <= 1'b0;
                    if (bk_done) begin
                        // BkEmu readSector: DRQ up, CHS registers advance to
                        // the NEXT sector (visible mid-transfer), count--
                        status <= SR_DRDY | SR_DSC | SR_DRQ; drq <= 1'b1;
                        ptr <= '0;
                        scount <= scount - 1'b1;
                        // increment+wrap == BkEmu's div/mod for in-range CHS
                        if (x_snum >= {1'b0, g_secs}) begin
                            x_snum <= 9'd1; snum <= 8'd1;
                            if (x_head + 1'b1 >= g_heads) begin
                                x_head <= '0;
                                x_cyl <= x_cyl + 1'b1;
                                {cyl_hi, cyl_lo} <= x_cyl + 1'b1;
                                dhr[3:0] <= 4'h0;
                            end else begin
                                x_head <= x_head + 1'b1;
                                dhr[3:0] <= x_head[3:0] + 1'b1;
                            end
                        end else begin
                            x_snum <= x_snum + 1'b1;
                            snum <= x_snum[7:0] + 1'b1;
                        end
                        st <= E_DRAIN;
                    end
                end
                E_DRAIN: begin
                    // pointer moves in the DIN-release block below; chain here
                    if (ptr == 9'd256) begin
                        if (xfer_ident || scount == 9'd0) begin
                            status <= SR_DRDY | SR_DSC; drq <= 1'b0;
                            if (!xfer_ident) error <= 8'h00;
                            ptr <= '0;
                            st <= E_IDLE;       // stopTransfer
                        end else begin
                            status <= SR_BSY; drq <= 1'b0;  // fetching next
                            error <= 8'h00;     // readSector re-entry
                            st <= E_LBA1;
                        end
                    end
                end
                E_FILL: begin
                    if (ptr == 9'd256) begin    // full block -> writeSector
                        status <= SR_BSY; drq <= 1'b0;  // committing
                        ptr <= '0;
                        st <= E_LBA1;
                    end
                end
                E_COMMIT: begin
                    if (bk_ack) bk_req <= 1'b0;
                    if (bk_done) begin
                        // commit done: CHS advance + count--, then re-arm
                        // DRQ for the next block or finish
                        scount <= scount - 1'b1;
                        if (x_snum >= {1'b0, g_secs}) begin
                            x_snum <= 9'd1; snum <= 8'd1;
                            if (x_head + 1'b1 >= g_heads) begin
                                x_head <= '0;
                                x_cyl <= x_cyl + 1'b1;
                                {cyl_hi, cyl_lo} <= x_cyl + 1'b1;
                                dhr[3:0] <= 4'h0;
                            end else begin
                                x_head <= x_head + 1'b1;
                                dhr[3:0] <= x_head[3:0] + 1'b1;
                            end
                        end else begin
                            x_snum <= x_snum + 1'b1;
                            snum <= x_snum[7:0] + 1'b1;
                        end
                        if (scount == 9'd1) begin   // that was the last one
                            status <= SR_DRDY | SR_DSC; drq <= 1'b0;
                            st <= E_IDLE;
                        end else begin
                            status <= SR_DRDY | SR_DSC | SR_DRQ; drq <= 1'b1;
                            ptr <= '0;
                            st <= E_FILL;
                        end
                    end
                end
                default: st <= E_IDLE;
            endcase

            // ---------------- DATA-read pointer advance ----------------
            // (DIN release; only while a drain phase owns the data register)
            if (!sync_n && !din_n && blk && ridx == 3'd7 && drq
                && (st == E_DRAIN))
                r_pend <= 1'b1;
            if (r_pend && din_n) begin
                r_pend <= 1'b0;
                ptr <= ptr + 1'b1;
            end

            // ---------------- bus write capture + action ----------------
            if (!sync_n && !dout_n && blk) begin
                w_inv  <= ad_n;                 // ~(~ad_n) = the inverted value
                w_a0   <= addr[0];
                w_byte <= !wtbt_n;              // BYTE at DOUT time
                w_idx  <= ridx;
                w_pend <= 1'b1;
            end
            if (w_pend && dout_n) begin         // window closed: act once
                w_pend <= 1'b0;
                unique case (w_idx)
                    3'd0: if (!w_a0 && cur_present) begin
                        // COMMAND (exact 177740; byte 177741 is ignored)
                        if (w_inv[7:0] == CMD_IDENTIFY) begin
                            status <= SR_DRDY | SR_DSC | SR_DRQ; drq <= 1'b1;
                            xfer_ident <= 1'b1; xfer_wr <= 1'b0;
                            ptr <= '0;
                            bk_bank <= 1'b0;
                            st <= E_DRAIN;
                        end else if ((w_inv[7:0] == 8'h20 || w_inv[7:0] == 8'h21
                                      || w_inv[7:0] == 8'h30 || w_inv[7:0] == 8'h31)
                                     && !dhr[6]) begin
                            // READ/WRITE, CHS only (LBA bit -> abort below);
                            // bit 4 splits 0x30/31 (WRITE) from 0x20/21.
                            // READ: BSY while the first sector fetches
                            status <= SR_BSY; drq <= 1'b0;
                            xfer_ident <= 1'b0;
                            xfer_wr <= w_inv[4];
                            // WRITE clears error at handleCommand (782); READ
                            // in its first synchronous readSector (937) -
                            // the same dispatch edge here
                            error <= 8'h00;
                            if (scount == 9'd0) scount <= 9'd256;
                            x_cyl  <= {cyl_hi[5:0], cyl_lo};
                            x_head <= {1'b0, dhr[3:0]};
                            x_snum <= {1'b0, snum};
                            ptr <= '0;
                            // the whole command runs in bank 0: pinned HERE
                            // (a WRITE fills BEFORE E_LBA2 runs - the bank
                            // must not be geometry's stale bank 1)
                            bk_bank <= 1'b0;
                            if (w_inv[4]) begin // DRQ first for a WRITE
                                status <= SR_DRDY | SR_DSC | SR_DRQ;
                                drq <= 1'b1;
                                st <= E_FILL;
                            end else
                                st <= E_LBA1;
                        end else begin
                            // abortCommand (BkEmu default; incl. LBA-bit)
                            status <= SR_DRDY | SR_ERR; drq <= 1'b0;
                            error <= ER_ABRT;
                            st <= E_IDLE;
                        end
                    end
                    3'd1: begin
                        if (!w_a0) begin
                            // DHR (exact 177742): |0xA0, DRV selects
                            dhr <= w_inv[7:0] | DHR_FIXED;
                            slave_sel <= w_inv[4];
                        end else begin
                            // control register (byte 177743, high lanes)
                            if (attached) begin
                                if (srst_new && !ctrl_srst)
                                    status <= SR_BSY;       // reset asserted
                                else if (!srst_new && ctrl_srst) begin
                                    // reset released: full re-init
                                    status <= SR_DRDY; error <= 8'h01;
                                    snum <= 8'h01; scount <= 9'h001;
                                    cyl_lo <= 8'h00; cyl_hi <= 8'h00;
                                    dhr <= DHR_FIXED;
                                    drq <= 1'b0; ptr <= '0;
                                    xfer_ident <= 1'b0;
                                    bk_req <= 1'b0;   // abandon any in-flight
                                    st <= E_IDLE;
                                end
                            end
                            ctrl_srst <= srst_new;
                        end
                    end
                    3'd2: cyl_hi <= w_inv[7:0];
                    3'd3: cyl_lo <= w_inv[7:0];
                    3'd4: snum   <= w_inv[7:0];
                    3'd5: scount <= {1'b0, w_inv[7:0]};
                    3'd6: ;                     // FEATURES: stored nowhere
                                                // (BkEmu stores, never reads)
                    3'd7: if (drq && st == E_FILL && ptr != 9'd256)
                        ptr <= ptr + 1'b1;      // data word landed (sb_we
                                                // fired via fill_wr)
                endcase
            end
            din_q <= din_n;
        end
    end

endmodule
