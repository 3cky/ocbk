// ============================================================================
//  sd_backend - SPI-mode SD card host serving the smk_ide backend sector
//  port.
//
//  The card in the board's megasd slot (esemsx3 pin roles: DAT3 = CS,
//  CMD = MOSI, DAT0 = MISO) holds a raw AltPro HDD image dd'd at card
//  LBA 0; bk_total reports the FULL card capacity from the CSD (the AltPro
//  partition table in image sector 7 defines the logical disks, exactly as
//  when BkEmu attaches the same image file).
//
//  Init ladder (SPI clock /256 = 377 kHz <= the 400 kHz identification
//  limit): >=74 dummy clocks CS-high, a recovery preamble (0xFD stop-tran
//  + CMD12 + a bus flush - a warm reset resets US but not the card, which
//  may still be streaming an open CMD18/CMD25; see S_PRE_TOK), CMD0
//  (CRC 0x95), CMD8 0x1AA
//  (CRC 0x87; a valid R7 echo = a v2 card, illegal-command = v1/SDSC),
//  ACMD41 loop (HCS when v2) until ready, CMD58 (OCR CCS -> SDHC block
//  addressing vs SDSC byte addressing), CMD16(512) for SDSC only, CMD9
//  (CSD -> capacity in 512-byte sectors, capped to 28 bits). Then
//  bk_media_ok rises and the SPI clock switches to /8 = 12.08 MHz (the
//  proven epcs_boot rate, well under the 25 MHz SPI-mode limit). Any
//  init failure/timeout parks in S_DEAD: bk_media_ok stays 0 and the
//  drive reports absent - the same tie-off as having no backend at all;
//  dbg_fail then carries WHERE it died (a TEMPORARY bring-up aid on the
//  board LEDs): 1 CMD0 exhausted, 2 CMD8 answered neither a valid R7 echo
//  nor illegal-command, 3 CMD55 rejected, 4 ACMD41 never ready as v2,
//  5 ACMD41 never ready as v1 (i.e. CMD8's response was MISREAD and an
//  SDHC card got ACMD41 without HCS, which never readies), 6 CMD58,
//  7 CMD16, 8 CMD9, 9 CSD data token, 10 unusable CSD version, 15 unknown.
//  No MMC (CMD1) fallback; no card-detect pin exists, so re-init is a
//  reset away (reset = DCLO-only, the same deliberate nINIT exception
//  as smk_ide: power-on AND warm reset = "insert card, press reset").
//
//  Data ops: CMD17 single-block read (0xFE token -> 512 bytes assembled
//  as 256 little-endian words into the engine's sector-buffer bank via
//  bk_baddr/bk_wdata/bk_we - first byte of a pair is the LOW byte, the
//  raw-image/BkEmu convention) and CMD24 single-block write (buffer words
//  fetched with the registered-bk_rdata settle, 0xFE start token,
//  data-response check, busy-wait). CRC policy is the SPI-mode default:
//  real CRCs only on CMD0/CMD8, dummy CRC16 on writes, read CRC ignored.
//  Errors complete as bk_done+bk_error (the engine ignores it for data ops
//  - BkEmu ignores drive.read/write rc - and honors it only for the
//  attach-time sector-7 geometry read); bk_media_ok never drops mid-run.
//
//  SINGLE-BLOCK ONLY, deliberately. Multi-block (CMD18/CMD25) coalescing
//  buys about 2% here and is not worth its failure mode: it saves the
//  ~10-byte command frame per sector (~7 us against a 342 us block at the
//  /8 data clock), but the BK drains 256 words through the task file at
//  4.03 MHz (~500-750 us per sector), so the DRAIN is the bottleneck and
//  smk_ide's tier-1 prefetch already hides the whole fetch behind it. The
//  hazard is that an open stream shares MISO with the response path, so a
//  stream left open across idle time survives a warm reset (DCLO resets
//  US, not the card) and the machine cannot find its disk until a second
//  reset press. If this is ever revisited: close the stream when the
//  OPERATION ends - ao486's rtl/soc/driver_sd/card_read.v issues CMD12 on
//  the last sector of every read - never lazily on the next non-contiguous
//  request.
//
//  All on sys_clk like the engine - no CDC on the seam. The SPI byte
//  engine follows epcs_boot: mode 0, MSB first, MOSI advances at the SCK
//  fall, MISO sampled late in the SCK-high phase. Pads are registered
//  outputs (the pad-OE rule does not apply - nothing here is tri-state).
//  Byte-state convention: a state asserts x_go/x_tx only in its NON-done
//  cycles, so a state change never launches the next byte with the old
//  state's x_tx (the engine also refuses to start in an x_done cycle);
//  each byte therefore costs a couple of idle sys_clk - noise at /8.
// ============================================================================

module sd_backend #(
    // SPI clock dividers, log2(sys_clk cycles per SCK period)
    parameter int DIV_SLOW_L2 = 8,      // init: /256 = 377 kHz (<= 400 kHz)
    parameter int DIV_FAST_L2 = 3,      // data: /8 = 12.08 MHz
    // retry/timeout budgets (sim overrides shrink them)
    parameter int SETTLE_CLKS  = 131072,   // ~1.4 ms post-reset settle
    parameter int INIT_TRIES   = 8,        // whole-ladder attempts before
                                           //   declaring the media absent
    parameter int ACMD41_TRIES = 4096,     // CMD55+CMD41 iterations (~1.4 s)
    parameter int TOK_POLLS    = 200000,   // read-token byte polls (~130 ms at /8)
    parameter int BUSY_POLLS   = 400000,   // write-busy byte polls (~260 ms at /8)
    // recovery preamble (see S_PRE_TOK), all in SPI bytes at the /256 init
    // clock (~21.2 us per byte):
    parameter int PRE_BUSY_BYTES = 12000,  // post-0xFD program-busy poll,
                                           //   ~255 ms = the SD write timeout
    parameter int PRE_FLUSH      = 1100,   // FIXED post-CMD12 drain: a whole
                                           //   block + token + CRC + R1 + busy
    parameter int PRE_IDLE       = 1024,   // then wait for the bus to go quiet
    parameter int PRE_FF_RUN     = 8       // consecutive 0xFF = bus is quiet
) (
    input  logic        clk,         // sys_clk
    input  logic        rst_n,       // = dclo_n (DCLO-only; NOT nINIT)
    input  logic        enable,      // = smk_en, DIP 8 (quasi-static)

    // ---- SPI pads (megasd slot) -------------------------------------------
    output logic        sd_ck,
    output logic        sd_cs,       // active low (card DAT3)
    output logic        sd_mosi,     // card CMD
    input  logic        sd_miso,     // card DAT0

    // ---- smk_ide backend sector port ---------------------------------------
    input  logic        bk_req,      // level; held until bk_ack
    input  logic        bk_wr,       // 0 = read sector into bank, 1 = commit
    input  logic [27:0] bk_sector,
    input  logic        bk_bank,     // engine-owned buffer routing; unused here
    output logic        bk_ack,
    output logic        bk_done,     // 1-cycle pulse
    output logic        bk_error,    // with bk_done
    output logic        bk_media_ok,
    output logic [27:0] bk_total,    // card capacity in 512-byte sectors
    output logic [7:0]  bk_baddr,
    output logic [15:0] bk_wdata,
    output logic        bk_we,
    input  logic [15:0] bk_rdata,    // registered read - one settle cycle

    // ---- board-LED diagnostics (TEMPORARY, see ocbk_top's pLed comment) ----
    output logic [3:0]  dbg_fail,        // 0 = fine; else WHERE init died
                                         //   (see the S_DEAD codes below)
    output logic        dbg_flush_cap,   // sticky: a flush ran out of budget
                                         //   (the card would not go quiet)
    output logic        dbg_retried      // sticky: >=1 CMD0 attempt failed
);

    // ---- byte-level SPI engine (mode 0, MSB first) --------------------------
    // The FSM holds x_go with x_tx set; the engine starts one cycle later
    // (never in an x_done cycle), shifts 8 bits and pulses x_done with x_rx
    // complete.
    localparam logic [8:0] DIVMAX_S  = (1 << DIV_SLOW_L2) - 1;
    localparam logic [8:0] DIVMAX_F  = (1 << DIV_FAST_L2) - 1;
    localparam logic [8:0] DIVHALF_S = 1 << (DIV_SLOW_L2 - 1);
    localparam logic [8:0] DIVHALF_F = 1 << (DIV_FAST_L2 - 1);

    logic       fast;                // 0 = init clock, 1 = data clock
    wire  [8:0] div_max  = fast ? DIVMAX_F  : DIVMAX_S;
    wire  [8:0] div_half = fast ? DIVHALF_F : DIVHALF_S;

    // `enable` is smk_en (DIP 8, both models) - latched in ocbk_top
    // during the DCLO hold, so quasi-static, but high-fanout and therefore
    // long-routed: feeding it straight into the S_SETTLE arm put
    // model_bk11 -> st.A_WCMD_R on the critical path. One local flop, the
    // model_bk11_q/smk_en_q treatment. Latency is irrelevant - enable only
    // changes while DCLO is held and this whole module is in reset.
    // Reset value 1, NOT 0: S_SETTLE parks in S_DISABLED - a DEAD-END state -
    // the moment it sees !enable_q, and it is evaluated on the very first
    // cycle out of reset. Resetting this flop to 0 therefore disabled the
    // backend permanently on every reset even with a card present (found by
    // the -DSD_STACK leg: reads went to zeros after a mid-run media cycle).
    // Starting at 1 costs nothing - S_SETTLE re-evaluates every cycle of the
    // ~1.4 ms settle, so a genuinely disabled backend still parks on cycle 2,
    // before any SPI traffic (S_SETTLE never asserts x_go).
    logic       enable_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) enable_q <= 1'b1;
        else        enable_q <= enable;

    logic       x_go;                // level request from the FSM
    logic [7:0] x_tx;
    logic       x_run;
    logic       x_done;              // 1-cycle pulse, x_rx valid with it
    logic [7:0] x_rx;
    // "the byte just received was 0xFF (idle bus)", precomputed in the byte
    // engine and registered WITH x_rx. Every idle/busy poll in the FSM keys
    // on this one bit instead of comparing x_rx itself: the equality was in
    // the `st` next-state cone, and the recovery preamble's two extra
    // compares pushed that cone to a -0.664 ns setup violation (the same
    // structural trap as the wait_cnt decrement - fix it in the datapath,
    // never with an SDC exception).
    logic       x_ff;
    logic [7:0] x_sh;
    logic [2:0] x_bit;
    logic [8:0] divc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_run   <= 1'b0;
            x_done  <= 1'b0;
            x_ff    <= 1'b0;
            sd_ck   <= 1'b0;
            sd_mosi <= 1'b1;
            divc    <= '0;
            x_bit   <= '0;
        end else begin
            x_done <= 1'b0;
            if (!x_run) begin
                sd_ck <= 1'b0;
                if (x_go && !x_done) begin
                    x_run   <= 1'b1;
                    x_sh    <= x_tx;
                    sd_mosi <= x_tx[7];     // first bit at low-phase start
                    x_bit   <= '0;
                    divc    <= '0;
                end
            end else begin
                divc <= divc + 1'b1;
                if (divc == div_half - 1)
                    sd_ck <= 1'b1;          // rising edge mid-bit
                if (divc == div_max) begin  // end of the high phase
                    sd_ck <= 1'b0;
                    x_rx  <= {x_rx[6:0], sd_miso};  // sample late-high
                    x_ff  <= (x_rx[6:0] == 7'h7F) && sd_miso;
                    divc  <= '0;
                    if (x_bit == 3'd7) begin
                        x_run  <= 1'b0;
                        x_done <= 1'b1;
                    end else begin
                        x_bit   <= x_bit + 1'b1;
                        sd_mosi <= x_sh[6]; // next bit at the fall
                        x_sh    <= {x_sh[6:0], 1'b0};
                    end
                end
            end
        end
    end

    // ---- main FSM ------------------------------------------------------------
    typedef enum logic [5:0] {
        S_DISABLED, S_SETTLE, S_DUMMY,
        S_PRE_TOK, S_PRE_BUSY, S_PRE_FLUSH, S_PRE_IDLE, S_PRE_END,
        S_CMD0, S_CMD0_R, S_CMD8, S_CMD8_R,
        S_CMD55, S_CMD55_R, S_CMD41, S_CMD41_R,
        S_CMD58, S_CMD58_R, S_CMD16, S_CMD16_R,
        S_CMD9, S_CMD9_R, S_CSD_TOK, S_CSD_DATA, S_CSD_END,
        S_DEAD, S_RETRY,
        // shared command-frame subroutine (returns to ret_st)
        F_LEAD, F_SEND, F_R1, F_EXT,
        // serving loop
        A_IDLE, A_DISPATCH,
        A_RCMD_R, A_RTOK, A_RDATA, A_RCRC,
        A_WCMD_R, A_WGAP, A_WTOKEN, A_WFETCH, A_WWAIT, A_WSAMP,
        A_WLO, A_WHI, A_WCRC, A_WRESP, A_WBUSY,
        A_TAIL, A_FIN
    } st_t;
    st_t st, ret_st;

    // command-frame subroutine interface
    logic [5:0]  cmd_op;
    logic [31:0] cmd_arg;
    logic [7:0]  cmd_crc;
    logic        want_ext;           // collect 4 extra response bytes (R3/R7)
    logic [2:0]  fcnt;               // frame byte 0..5
    logic [3:0]  poll_cnt;           // R1 NCR polls (8 bytes)
    logic [1:0]  ecnt;
    logic [7:0]  r1;                 // 0xFF = no response
    logic [31:0] ext;

    // frame byte mux
    logic [7:0] fbyte;
    always_comb begin
        case (fcnt)
            3'd0:    fbyte = {2'b01, cmd_op};
            3'd1:    fbyte = cmd_arg[31:24];
            3'd2:    fbyte = cmd_arg[23:16];
            3'd3:    fbyte = cmd_arg[15:8];
            3'd4:    fbyte = cmd_arg[7:0];
            default: fbyte = cmd_crc;
        endcase
    end

    // init bookkeeping
    logic         v2;                // CMD8 answered -> v2 card
    logic         sdhc;              // OCR CCS -> block addressing
    logic [3:0]   init_try;
    // shared settle/ACMD41/token/busy budget. 20 bits holds the largest
    // default (BUSY_POLLS=400000 < 2^19) with margin; keep it narrow - at the
    // full 32-bit width the decrement ripple lands on the sys_clk critical
    // path (-0.646 ns) once enough states load it. Narrowing is
    // behaviour-identical since every assigned budget fits.
    logic [19:0]  wait_cnt;
    // registered "wait_cnt is zero". Keep the test on this flag: the 20-bit
    // zero-compare placed directly in the `st` next-state cone lands there in
    // a dozen states at once and, with the recovery preamble's extra states,
    // becomes the design's worst path (-0.689 ns). The flag moves the compare
    // off the state machine's critical path and into the counter's own
    // (flop-to-flop) one - the x_ff treatment on the timeout side. Every
    // load site must set it, every decrement must look one ahead; loads clear it
    // unconditionally, so every budget parameter must stay NON-ZERO (a
    // zero override would read as "not expired" for one wrap).
    logic         wait_z;
    // recovery-preamble budgets: a private counter, deliberately NOT another
    // load site on wait_cnt (that decrement has been the sys_clk critical path
    // before - see the CMD18 narrowing note above)
    // Byte budgets for the recovery preamble AND the CS-high dummy-clock
    // windows around it (S_DUMMY moved off wait_cnt onto this counter).
    // Deliberately not a wait_cnt load site; pre_z is the registered zero
    // test, for the same `st`-cone reason as wait_z.
    logic [13:0]  pre_cnt;
    logic         pre_z;
    logic [2:0]   ff_run;            // consecutive idle (0xFF) bytes seen
    logic [4:0]   ccnt;              // CSD byte count
    logic [127:0] csd;

    // CSD capacity decode (stable by S_CSD_END)
    wire  [1:0]  csd_ver  = csd[127:126];
    wire  [21:0] csd_c22  = csd[69:48];              // v2 C_SIZE
    wire  [3:0]  csd_blen = csd[83:80];              // v1 READ_BL_LEN
    wire  [11:0] csd_csz  = csd[73:62];              // v1 C_SIZE
    wire  [2:0]  csd_mult = csd[49:47];              // v1 C_SIZE_MULT
    // v1 sectors = (C_SIZE+1) << (MULT+2+BLEN-9); BLEN>=9 checked in the FSM,
    // max 4096<<15 = 2^27 always fits 28 bits
    wire  [4:0]  v1_sh    = {2'b00, csd_mult} + 5'd2
                            + {1'b0, csd_blen} - 5'd9;
    wire  [27:0] v1_total = ({16'd0, csd_csz} + 28'd1) << v1_sh;

    // serving bookkeeping
    logic        r_wr;
    logic [27:0] r_sector;
    logic        err;
    logic [7:0]  widx;               // word index within the sector
    // "widx is on the last word", registered with the increment. The 8-bit
    // compare was in the `st` next-state cone (widx[7] -> st.A_RDATA was the
    // worst sys_clk path once the FSM grew); this is the x_ff/wait_z/pre_z
    // treatment again - wide compares belong in a flop, not at the decision.
    logic        widx_last;
    logic        have_lo;            // read: low byte collected / CRC toggler
    logic [7:0]  lo_byte;
    logic [15:0] wword;              // write: latched buffer word

    // A_DISPATCH decisions, precomputed at the A_IDLE capture edge. The port
    // contract holds bk_req and the fields until bk_ack, so sampling these
    // one cycle early is exactly equivalent to comparing r_sector in
    // A_DISPATCH - but it keeps a 28-bit comparator chain out of the `st`
    // next-state cone, which the recovery-preamble states had pushed into a
    // (marginal) setup violation. Same lesson as x_ff/wait_z: precompute
    // wide compares into a flop, never re-derive them at the decision point.
    logic        d_oob;              // past the card capacity

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_SETTLE;
            ret_st      <= S_DEAD;
            x_go        <= 1'b0;
            x_tx        <= 8'hFF;
            sd_cs       <= 1'b1;
            fast        <= 1'b0;
            bk_ack      <= 1'b0;
            bk_done     <= 1'b0;
            bk_error    <= 1'b0;
            bk_media_ok <= 1'b0;
            bk_total    <= '0;
            bk_baddr    <= '0;
            bk_wdata    <= '0;
            bk_we       <= 1'b0;
            v2          <= 1'b0;
            sdhc        <= 1'b0;
            init_try    <= '0;
            widx_last   <= 1'b0;
            wait_cnt    <= SETTLE_CLKS;
            wait_z      <= 1'b0;
            pre_cnt       <= '0;
            pre_z         <= 1'b0;
            ff_run        <= '0;
            dbg_fail      <= 4'd0;
            dbg_flush_cap <= 1'b0;
            dbg_retried   <= 1'b0;
            err         <= 1'b0;
            d_oob         <= 1'b0;
        end else begin
            // pulse/level defaults; byte states re-assert x_go in their
            // non-done cycles (see the header convention)
            x_go     <= 1'b0;
            bk_ack   <= 1'b0;
            bk_done  <= 1'b0;
            bk_error <= 1'b0;
            bk_we    <= 1'b0;

            case (st)
                // ---- power-up ----------------------------------------------
                S_SETTLE: begin
                    if (!enable_q)
                        st <= S_DISABLED;
                    else if (wait_z) begin
                        pre_cnt <= 14'd10;      // 80 dummy clocks, CS high
                        pre_z   <= 1'b0;
                        st      <= S_DUMMY;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                        wait_z   <= (wait_cnt == 20'd1);
                    end
                end

                S_DUMMY: begin                  // >= 74 clocks, CS+MOSI high
                    if (x_done) begin
                        if (pre_cnt <= 14'd1)
                            st <= S_PRE_TOK;
                        else
                            pre_cnt <= pre_cnt - 1'b1;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // ---- warm-reset recovery preamble --------------------------
                // DCLO resets US but NOT the card, so a warm reset can land
                // mid-transfer and leave the card holding the rest of a block.
                // It then answers the init ladder with image data: CMD0's R1
                // poll latches a data byte with the MSB clear as R1, and one
                // stray byte later in the ladder is worse still (S_CMD8_R
                // reads any byte with bit 2 set as "v1 card", after which an
                // SDHC card gets ACMD41 without HCS and never readies).
                // So always, before CMD0: send 0xFD (stop-tran; inert unless
                // something left a write-multiple open - its MSB is set, so it
                // is never a command start), wait out any program-busy window,
                // send CMD12 (closes a read-multiple; a harmless
                // illegal-command otherwise), then flush the bus. Nothing in
                // THIS design opens a multi-block stream any more (see the
                // header), so the 0xFD/CMD12 pair is pure insurance - against
                // a card left streaming by other firmware, and against our own
                // mid-block reset case. ~25 bytes at 377 kHz on a clean card.
                S_PRE_TOK: begin
                    sd_cs <= 1'b0;
                    if (x_done) begin
                        pre_cnt <= PRE_BUSY_BYTES[13:0];
                        pre_z   <= 1'b0;
                        st      <= S_PRE_BUSY;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFD;
                    end
                end
                // The 0xFD close of a write-multiple starts a program cycle
                // the card may legitimately hold for ~250 ms, so this budget
                // is time-sized (PRE_BUSY_BYTES at 377 kHz), not block-sized.
                S_PRE_BUSY: begin
                    if (x_done) begin
                        if (x_ff || pre_z) begin
                            cmd_op   <= 6'd12;
                            cmd_arg  <= 32'h0000_0000;
                            cmd_crc  <= 8'h01;
                            want_ext <= 1'b0;
                            ret_st   <= S_PRE_FLUSH;
                            pre_cnt  <= PRE_FLUSH[13:0];
                            pre_z    <= 1'b0;
                            ff_run   <= '0;
                            st       <= F_LEAD;
                        end else begin
                            pre_cnt <= pre_cnt - 1'b1;
                            pre_z   <= (pre_cnt == 14'd1);
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                // FIXED-length flush, NO early exit. The residue being flushed
                // is image data, and on a BK disk that data is full of 0xFF
                // runs (the IDE layer inverts, so BK zero-filled regions are
                // stored as 0xFF on the card) - an "exit once the bus looks
                // idle" flush therefore stops INSIDE the residue and leaves
                // the rest to poison CMD0 or the attach-time geometry read.
                // PRE_FLUSH covers a whole block + token + CRC + R1 + busy.
                S_PRE_FLUSH: begin
                    if (x_done) begin
                        if (pre_z) begin
                            pre_cnt <= PRE_IDLE[13:0];
                            pre_z   <= 1'b0;
                            st      <= S_PRE_IDLE;
                        end else begin
                            pre_cnt <= pre_cnt - 1'b1;
                            pre_z   <= (pre_cnt == 14'd1);
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                // ...and only THEN require the bus to actually look idle, so
                // a card still talking is not mistaken for a quiet one.
                // Running out of budget here is the "card would not go quiet"
                // signal - latched in dbg_flush_cap for the board LEDs.
                S_PRE_IDLE: begin
                    if (x_done) begin
                        if (x_ff)
                            ff_run <= ff_run + 1'b1;
                        else
                            ff_run <= '0;
                        if ((x_ff && ff_run == PRE_FF_RUN - 1) || pre_z) begin
                            if (pre_z && !(x_ff && ff_run == PRE_FF_RUN - 1))
                                dbg_flush_cap <= 1'b1;
                            pre_cnt <= 14'd10;  // 80 CS-high clocks, see below
                            pre_z   <= 1'b0;
                            st      <= S_PRE_END;
                        end else begin
                            pre_cnt <= pre_cnt - 1'b1;
                            pre_z   <= (pre_cnt == 14'd1);
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                S_PRE_END: begin
                    // The spec wants >=74 CS-high clocks IMMEDIATELY before
                    // CMD0, and the preamble just spent a while with CS low,
                    // so re-open that window (80 clocks at 377 kHz = 0.2 ms)
                    // rather than leaving S_DUMMY's separated from CMD0.
                    sd_cs <= 1'b1;
                    if (x_done) begin
                        if (pre_cnt <= 1)
                            st <= S_CMD0;
                        else
                            pre_cnt <= pre_cnt - 1'b1;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // ---- init ladder -------------------------------------------
                S_CMD0: begin
                    sd_cs    <= 1'b0;           // CS stays low for the session
                    cmd_op   <= 6'd0;
                    cmd_arg  <= 32'h0000_0000;
                    cmd_crc  <= 8'h95;
                    want_ext <= 1'b0;
                    ret_st   <= S_CMD0_R;
                    st       <= F_LEAD;
                end
                S_CMD0_R: begin
                    if (r1 == 8'h01)
                        st <= S_CMD8;
                    else begin
                        dbg_fail <= 4'd1;
                        st       <= S_RETRY;
                    end
                end

                S_CMD8: begin
                    cmd_op   <= 6'd8;
                    cmd_arg  <= 32'h0000_01AA;  // 3.3 V range + check pattern
                    cmd_crc  <= 8'h87;
                    want_ext <= 1'b1;
                    ret_st   <= S_CMD8_R;
                    st       <= F_LEAD;
                end
                S_CMD8_R: begin
                    wait_cnt <= ACMD41_TRIES;
                    wait_z   <= 1'b0;
                    if (r1 == 8'h01 && ext[11:0] == 12'h1AA) begin
                        v2 <= 1'b1;
                        st <= S_CMD55;
                    end else if (r1 != 8'hFF && r1[2]) begin
                        v2 <= 1'b0;             // illegal command: v1 card
                        st <= S_CMD55;
                    end else begin
                        dbg_fail <= 4'd2;
                        st       <= S_RETRY;
                    end
                end

                S_CMD55: begin
                    cmd_op   <= 6'd55;
                    cmd_arg  <= 32'h0000_0000;
                    cmd_crc  <= 8'h01;
                    want_ext <= 1'b0;
                    ret_st   <= S_CMD55_R;
                    st       <= F_LEAD;
                end
                S_CMD55_R: begin
                    if (r1 == 8'h00 || r1 == 8'h01)
                        st <= S_CMD41;
                    else begin
                        dbg_fail <= 4'd3;
                        st       <= S_RETRY;
                    end
                end
                S_CMD41: begin
                    cmd_op   <= 6'd41;
                    cmd_arg  <= v2 ? 32'h4000_0000 : 32'h0000_0000;  // HCS
                    cmd_crc  <= 8'h01;
                    want_ext <= 1'b0;
                    ret_st   <= S_CMD41_R;
                    st       <= F_LEAD;
                end
                S_CMD41_R: begin
                    if (r1 == 8'h00)
                        st <= S_CMD58;
                    else if (r1 == 8'h01 && !wait_z) begin
                        wait_cnt <= wait_cnt - 1'b1;
                        wait_z   <= (wait_cnt == 20'd1);
                        st       <= S_CMD55;
                    end else begin
                        dbg_fail <= v2 ? 4'd4 : 4'd5;
                        st       <= S_RETRY;
                    end
                end

                S_CMD58: begin
                    cmd_op   <= 6'd58;
                    cmd_arg  <= 32'h0000_0000;
                    cmd_crc  <= 8'h01;
                    want_ext <= 1'b1;
                    ret_st   <= S_CMD58_R;
                    st       <= F_LEAD;
                end
                S_CMD58_R: begin
                    if (r1 == 8'h00) begin
                        sdhc <= v2 && ext[30];  // CCS valid only on v2 cards
                        if (v2 && ext[30])
                            st <= S_CMD9;
                        else
                            st <= S_CMD16;
                    end else begin
                        dbg_fail <= 4'd6;
                        st       <= S_RETRY;
                    end
                end

                S_CMD16: begin                  // byte-addressed cards only
                    cmd_op   <= 6'd16;
                    cmd_arg  <= 32'd512;
                    cmd_crc  <= 8'h01;
                    want_ext <= 1'b0;
                    ret_st   <= S_CMD16_R;
                    st       <= F_LEAD;
                end
                S_CMD16_R: begin
                    if (r1 == 8'h00)
                        st <= S_CMD9;
                    else begin
                        dbg_fail <= 4'd7;
                        st       <= S_RETRY;
                    end
                end

                S_CMD9: begin
                    cmd_op   <= 6'd9;
                    cmd_arg  <= 32'h0000_0000;
                    cmd_crc  <= 8'h01;
                    want_ext <= 1'b0;
                    ret_st   <= S_CMD9_R;
                    st       <= F_LEAD;
                end
                S_CMD9_R: begin
                    wait_cnt <= TOK_POLLS;
                    wait_z   <= 1'b0;
                    if (r1 == 8'h00)
                        st <= S_CSD_TOK;
                    else begin
                        dbg_fail <= 4'd8;
                        st       <= S_RETRY;
                    end
                end
                S_CSD_TOK: begin
                    if (x_done) begin
                        if (x_rx == 8'hFE) begin
                            ccnt <= '0;
                            st   <= S_CSD_DATA;
                        end else if (!x_ff || wait_z) begin
                            dbg_fail <= 4'd9;
                            st       <= S_RETRY;
                        end
                        else begin
                            wait_cnt <= wait_cnt - 1'b1;
                            wait_z   <= (wait_cnt == 20'd1);
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                S_CSD_DATA: begin               // 16 CSD bytes + 2 CRC bytes
                    if (x_done) begin
                        if (ccnt < 16)
                            csd <= {csd[119:0], x_rx};
                        ccnt <= ccnt + 1'b1;
                        if (ccnt == 5'd17)
                            st <= S_CSD_END;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                S_CSD_END: begin
                    if (csd_ver == 2'b01) begin
                        // v2: (C_SIZE+1)*1024 sectors, saturate at 28 bits
                        if (csd_c22 >= 22'd262143)
                            bk_total <= 28'hFFFFFFF;
                        else
                            bk_total <= {csd_c22[17:0] + 18'd1, 10'b0};
                        bk_media_ok <= 1'b1;
                        fast        <= 1'b1;
                        st          <= A_IDLE;
                    end else if (csd_ver == 2'b00 && csd_blen >= 4'd9) begin
                        bk_total    <= v1_total;
                        bk_media_ok <= 1'b1;
                        fast        <= 1'b1;
                        st          <= A_IDLE;
                    end else begin
                        dbg_fail <= 4'd10;
                        st       <= S_RETRY;
                    end
                end

                // ---- shared command frame ----------------------------------
                F_LEAD: begin                   // one 0xFF lead byte (Ncs)
                    if (x_done) begin
                        fcnt <= '0;
                        st   <= F_SEND;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                F_SEND: begin                   // 6 frame bytes
                    if (x_done) begin
                        fcnt <= fcnt + 1'b1;
                        if (fcnt == 3'd5) begin
                            poll_cnt <= 4'd8;
                            st       <= F_R1;
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= fbyte;
                    end
                end
                F_R1: begin                     // poll up to 8 bytes for R1
                    if (x_done) begin
                        if (!x_rx[7]) begin
                            r1 <= x_rx;
                            if (want_ext) begin
                                ecnt <= '0;
                                st   <= F_EXT;
                            end else
                                st <= ret_st;
                        end else if (poll_cnt == 4'd1) begin
                            r1 <= 8'hFF;        // no response
                            st <= ret_st;
                        end else
                            poll_cnt <= poll_cnt - 1'b1;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                F_EXT: begin                    // 4 extra bytes (R3/R7)
                    if (x_done) begin
                        ext  <= {ext[23:0], x_rx};
                        ecnt <= ecnt + 1'b1;
                        if (ecnt == 2'd3)
                            st <= ret_st;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // ---- serving loop ------------------------------------------
                // Single-block only (CMD17/CMD24) - deliberately; see the
                // module header for why multi-block is not worth it here.
                A_IDLE: begin
                    if (bk_req) begin
                        bk_ack   <= 1'b1;
                        r_wr     <= bk_wr;
                        r_sector <= bk_sector;
                        // wide compare precomputed at the capture edge: the
                        // port holds its fields until bk_ack, so this is
                        // equivalent to comparing r_sector in A_DISPATCH but
                        // keeps a 28-bit comparator out of the `st` cone
                        d_oob    <= (bk_sector >= bk_total);
                        st       <= A_DISPATCH;
                    end
                end
                A_DISPATCH: begin
                    err <= 1'b0;
                    if (d_oob) begin
                        err <= 1'b1;            // oob: complete, no SPI traffic
                        st  <= A_FIN;
                    end else begin
                        cmd_op   <= r_wr ? 6'd24 : 6'd17;
                        // SDHC: block address; SDSC: byte address (sector*512)
                        cmd_arg  <= sdhc ? {4'b0000, r_sector}
                                         : {r_sector[22:0], 9'b0};
                        cmd_crc  <= 8'h01;
                        want_ext <= 1'b0;
                        if (r_wr)
                            ret_st <= A_WCMD_R;
                        else
                            ret_st <= A_RCMD_R;
                        st       <= F_LEAD;
                    end
                end

                // read: CMD17 -> token -> 512 bytes -> 2 CRC bytes
                A_RCMD_R: begin
                    wait_cnt <= TOK_POLLS;
                    wait_z   <= 1'b0;
                    if (r1 == 8'h00) begin
                        st <= A_RTOK;
                    end else begin
                        err <= 1'b1;
                        st  <= A_TAIL;
                    end
                end
                A_RTOK: begin
                    if (x_done) begin
                        if (x_rx == 8'hFE) begin
                            widx      <= '0;
                            widx_last <= 1'b0;
                            have_lo <= 1'b0;
                            st      <= A_RDATA;
                        end else if (!x_ff || wait_z) begin
                            err <= 1'b1;        // error token / timeout
                            st  <= A_TAIL;
                        end else begin
                            wait_cnt <= wait_cnt - 1'b1;
                            wait_z   <= (wait_cnt == 20'd1);
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                A_RDATA: begin
                    if (x_done) begin
                        if (!have_lo) begin
                            lo_byte <= x_rx;    // first byte = LOW byte
                            have_lo <= 1'b1;
                        end else begin
                            bk_baddr <= widx;
                            bk_wdata <= {x_rx, lo_byte};
                            bk_we    <= 1'b1;
                            have_lo  <= 1'b0;
                            widx      <= widx + 1'b1;
                            widx_last <= (widx == 8'd254);
                            if (widx_last)
                                st <= A_RCRC;
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                A_RCRC: begin                   // discard the 2 CRC bytes
                    if (x_done) begin
                        have_lo <= ~have_lo;
                        if (have_lo)
                            st <= A_TAIL;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // write: CMD24 -> gap -> token -> 512 bytes -> CRC -> resp
                A_WCMD_R: begin
                    if (r1 == 8'h00) begin
                        st <= A_WGAP;
                    end else begin
                        err <= 1'b1;
                        st  <= A_TAIL;
                    end
                end
                A_WGAP: begin                   // one gap byte before the token
                    if (x_done)
                        st <= A_WTOKEN;
                    else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                A_WTOKEN: begin
                    if (x_done) begin
                        widx      <= '0;
                        widx_last <= 1'b0;
                        st   <= A_WFETCH;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFE;          // single-block start token
                    end
                end
                // registered-bk_rdata fetch: address, settle, sample
                A_WFETCH: begin
                    bk_baddr <= widx;
                    st       <= A_WWAIT;
                end
                A_WWAIT: st <= A_WSAMP;
                A_WSAMP: begin
                    wword <= bk_rdata;
                    st    <= A_WLO;
                end
                A_WLO: begin
                    if (x_done)
                        st <= A_WHI;
                    else begin
                        x_go <= 1'b1;
                        x_tx <= wword[7:0];     // LOW byte first (LE image)
                    end
                end
                A_WHI: begin
                    if (x_done) begin
                        widx      <= widx + 1'b1;
                        widx_last <= (widx == 8'd254);
                        if (widx_last) begin
                            have_lo <= 1'b0;
                            st      <= A_WCRC;
                        end else
                            st <= A_WFETCH;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= wword[15:8];
                    end
                end
                A_WCRC: begin                   // 2 dummy CRC bytes
                    if (x_done) begin
                        have_lo <= ~have_lo;
                        if (have_lo)
                            st <= A_WRESP;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                A_WRESP: begin                  // data response: xxx00101 = ok
                    if (x_done) begin
                        wait_cnt <= BUSY_POLLS;
                        wait_z   <= 1'b0;
                        if (x_rx[4:0] != 5'b00101)
                            err <= 1'b1;
                        st <= A_WBUSY;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                A_WBUSY: begin                  // card holds DO low while busy
                    if (x_done) begin
                        if (x_ff || wait_z) begin
                            if (wait_z && !x_ff)
                                err <= 1'b1;        // busy timeout
                            st <= A_TAIL;
                        end else begin
                            wait_cnt <= wait_cnt - 1'b1;
                            wait_z   <= (wait_cnt == 20'd1);
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // one trailing byte, then the completion pulse
                A_TAIL: begin
                    if (x_done)
                        st <= A_FIN;
                    else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end
                A_FIN: begin
                    bk_done  <= 1'b1;
                    bk_error <= err;
                    st       <= A_IDLE;
                end

                // ---- parking states ----------------------------------------
                // Whole-ladder retry arbiter. EVERY init-stage failure lands
                // here, not just CMD0's: after a warm reset the bus can still
                // carry residue, and one stray byte anywhere in the ladder is
                // fatal in a way that looks nothing like a CMD0 failure -
                // S_CMD8_R in particular reads any byte with bit 2 set as
                // "illegal command = a v1 card", after which an SDHC card is
                // sent ACMD41 WITHOUT HCS and never leaves idle. Re-running
                // the whole recovery is what a second reset press does on the
                // board, and it is the only cure that does not depend on
                // guessing which byte got corrupted. v2/sdhc are cleared so
                // each attempt re-types the card from scratch.
                S_RETRY: begin
                    if (init_try != INIT_TRIES - 1) begin
                        init_try    <= init_try + 1'b1;
                        dbg_retried <= 1'b1;
                        wait_cnt    <= SETTLE_CLKS;
                        wait_z      <= 1'b0;
                        v2          <= 1'b0;
                        sdhc        <= 1'b0;
                        // S_CMD0 left CS LOW ("for the session"), but S_DUMMY
                        // is a CS-HIGH window by definition - raise it here or
                        // the retry's dummy clocks are not dummy clocks
                        sd_cs       <= 1'b1;
                        st          <= S_SETTLE;
                    end else
                        st <= S_DEAD;
                end

                S_DEAD: begin                   // media absent until next DCLO
                    sd_cs <= 1'b1;
                end
                S_DISABLED: ;

                default: begin dbg_fail <= 4'd15; st <= S_RETRY; end
            endcase
        end
    end

endmodule
