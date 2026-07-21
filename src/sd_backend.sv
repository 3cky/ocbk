// ============================================================================
//  sd_backend - SPI-mode SD card host serving the smk_ide backend sector
//  port (Phase-8 IDE increment (b)).
//
//  The card in the board's megasd slot (esemsx3 pin roles: DAT3 = CS,
//  CMD = MOSI, DAT0 = MISO) holds a raw AltPro HDD image dd'd at card
//  LBA 0; bk_total reports the FULL card capacity from the CSD (the AltPro
//  partition table in image sector 7 defines the logical disks, exactly as
//  when BkEmu attaches the same image file).
//
//  Init ladder (SPI clock /256 = 377 kHz <= the 400 kHz identification
//  limit): >=74 dummy clocks CS-high, CMD0 (CRC 0x95), CMD8 0x1AA
//  (CRC 0x87; a valid R7 echo = a v2 card, illegal-command = v1/SDSC),
//  ACMD41 loop (HCS when v2) until ready, CMD58 (OCR CCS -> SDHC block
//  addressing vs SDSC byte addressing), CMD16(512) for SDSC only, CMD9
//  (CSD -> capacity in 512-byte sectors, capped to 28 bits). Then
//  bk_media_ok rises and the SPI clock switches to /8 = 12.08 MHz (the
//  proven epcs_boot rate, well under the 25 MHz SPI-mode limit). Any
//  init failure/timeout parks in S_DEAD: bk_media_ok stays 0 and the
//  drive reports absent - exactly the increment-(a) tie-off behaviour.
//  No MMC (CMD1) fallback; no card-detect pin exists, so re-init is a
//  reset away (reset = DCLO-only, the same deliberate nINIT exception
//  as smk_ide: power-on AND warm reset = "insert card, press reset").
//
//  Data ops: CMD17 single-block read (0xFE token -> 512 bytes assembled
//  as 256 little-endian words into the engine's sector-buffer bank via
//  bk_baddr/bk_wdata/bk_we - first byte of a pair is the LOW byte, the
//  raw-image/BkEmu convention). A run of contiguous reads (the engine
//  issues one bk_req per sector at N, N+1, N+2 ...) is coalesced into a
//  single CMD18 read-multiple stream: the second contiguous read opens
//  CMD18, further contiguous reads skip the command frame and just poll
//  the next data token, and CMD12 (STOP_TRANSMISSION) closes the stream
//  before any non-contiguous op or on a mid-stream error. Isolated reads
//  stay CMD17. CMD24 single-block write (buffer words
//  fetched with the registered-bk_rdata settle, data-response check,
//  busy-wait). CRC policy is the SPI-mode default: real CRCs only on
//  CMD0/CMD8, dummy CRC16 on writes, read CRC ignored. Errors complete
//  as bk_done+bk_error (the engine ignores it for data ops - BkEmu
//  ignores drive.read/write rc - and honors it only for the attach-time
//  sector-7 geometry read); bk_media_ok never drops mid-run.
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
    parameter int CMD0_TRIES   = 8,        // CMD0 attempts before giving up
    parameter int ACMD41_TRIES = 4096,     // CMD55+CMD41 iterations (~1.4 s)
    parameter int TOK_POLLS    = 200000,   // read-token byte polls (~130 ms at /8)
    parameter int BUSY_POLLS   = 400000    // write-busy byte polls (~260 ms at /8)
) (
    input  logic        clk,         // sys_clk
    input  logic        rst_n,       // = dclo_n (DCLO-only; NOT nINIT)
    input  logic        enable,      // smk_en && model_bk11 (quasi-static)

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
    input  logic [15:0] bk_rdata     // registered read - one settle cycle
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

    logic       x_go;                // level request from the FSM
    logic [7:0] x_tx;
    logic       x_run;
    logic       x_done;              // 1-cycle pulse, x_rx valid with it
    logic [7:0] x_rx;
    logic [7:0] x_sh;
    logic [2:0] x_bit;
    logic [8:0] divc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_run   <= 1'b0;
            x_done  <= 1'b0;
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
        S_CMD0, S_CMD0_R, S_CMD8, S_CMD8_R,
        S_CMD55, S_CMD55_R, S_CMD41, S_CMD41_R,
        S_CMD58, S_CMD58_R, S_CMD16, S_CMD16_R,
        S_CMD9, S_CMD9_R, S_CSD_TOK, S_CSD_DATA, S_CSD_END,
        S_DEAD,
        // shared command-frame subroutine (returns to ret_st)
        F_LEAD, F_SEND, F_R1, F_EXT,
        // serving loop
        A_IDLE, A_DISPATCH,
        A_RCMD_R, A_RTOK, A_RDATA, A_RCRC,
        A_STOP_R, A_STOP_BUSY,
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
    logic [3:0]   cmd0_try;
    // shared settle/ACMD41/token/busy budget. 20 bits holds the largest
    // default (BUSY_POLLS=400000 < 2^19) with margin; the full 32-bit width
    // made the decrement ripple the sys_clk critical path (a -0.646 ns setup
    // violation once the CMD18 states added load sites) - narrowing is
    // behaviour-identical since every assigned budget fits.
    logic [19:0]  wait_cnt;
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
    logic        have_lo;            // read: low byte collected / CRC toggler
    logic [7:0]  lo_byte;
    logic [15:0] wword;              // write: latched buffer word

    // CMD18 read-multiple stream tracking (READ only; writes stay CMD24)
    logic        stream_active;      // a CMD18 read stream is open (needs CMD12)
    logic [27:0] stream_next;        // next LBA the open stream will deliver
    logic [27:0] last_lba;           // previous completed op's sector
    logic        last_read;          // previous completed op was a good read
    st_t         stop_ret;           // where the CMD12 close returns afterward

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
            cmd0_try    <= '0;
            wait_cnt    <= SETTLE_CLKS;
            err         <= 1'b0;
            stream_active <= 1'b0;
            stream_next   <= '0;
            last_lba      <= '0;
            last_read     <= 1'b0;
            stop_ret      <= A_FIN;
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
                    if (!enable)
                        st <= S_DISABLED;
                    else if (wait_cnt == 0) begin
                        wait_cnt <= 80;         // dummy clocks, CS high
                        st       <= S_DUMMY;
                    end else
                        wait_cnt <= wait_cnt - 1'b1;
                end

                S_DUMMY: begin                  // >= 74 clocks, CS+MOSI high
                    if (x_done) begin
                        if (wait_cnt <= 8) begin
                            cmd0_try <= '0;
                            st       <= S_CMD0;
                        end else
                            wait_cnt <= wait_cnt - 8;
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
                    else if (cmd0_try != CMD0_TRIES - 1) begin
                        cmd0_try <= cmd0_try + 1'b1;
                        st       <= S_CMD0;
                    end else
                        st <= S_DEAD;
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
                    if (r1 == 8'h01 && ext[11:0] == 12'h1AA) begin
                        v2 <= 1'b1;
                        st <= S_CMD55;
                    end else if (r1 != 8'hFF && r1[2]) begin
                        v2 <= 1'b0;             // illegal command: v1 card
                        st <= S_CMD55;
                    end else
                        st <= S_DEAD;
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
                    else
                        st <= S_DEAD;
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
                    else if (r1 == 8'h01 && wait_cnt != 0) begin
                        wait_cnt <= wait_cnt - 1'b1;
                        st       <= S_CMD55;
                    end else
                        st <= S_DEAD;
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
                    end else
                        st <= S_DEAD;
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
                    else
                        st <= S_DEAD;
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
                    if (r1 == 8'h00)
                        st <= S_CSD_TOK;
                    else
                        st <= S_DEAD;
                end
                S_CSD_TOK: begin
                    if (x_done) begin
                        if (x_rx == 8'hFE) begin
                            ccnt <= '0;
                            st   <= S_CSD_DATA;
                        end else if (x_rx != 8'hFF || wait_cnt == 0)
                            st <= S_DEAD;
                        else
                            wait_cnt <= wait_cnt - 1'b1;
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
                    end else
                        st <= S_DEAD;
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
                A_IDLE: begin
                    if (bk_req) begin
                        bk_ack   <= 1'b1;
                        r_wr     <= bk_wr;
                        r_sector <= bk_sector;
                        st       <= A_DISPATCH;
                    end
                end
                A_DISPATCH: begin
                    err <= 1'b0;
                    if (stream_active && !r_wr && r_sector == stream_next) begin
                        // continuation of the open CMD18 stream: the card is
                        // already delivering block after block - no command
                        // frame, just poll the next data token
                        wait_cnt <= TOK_POLLS;
                        st       <= A_RTOK;
                    end else if (stream_active) begin
                        // non-continuation while a stream is open (write / LBA
                        // gap / oob / geometry): close it with CMD12, then
                        // re-dispatch this same request as a fresh op
                        cmd_op   <= 6'd12;
                        cmd_arg  <= 32'h0000_0000;
                        cmd_crc  <= 8'h01;
                        want_ext <= 1'b0;
                        ret_st   <= A_STOP_R;
                        stop_ret <= A_DISPATCH;
                        st       <= F_LEAD;
                    end else if (r_sector >= bk_total) begin
                        err <= 1'b1;            // oob: complete, no SPI traffic
                        st  <= A_FIN;
                    end else begin
                        // second contiguous read opens a CMD18 read-multiple
                        // stream (sectors 3..N then skip the command frame);
                        // isolated reads stay CMD17, writes stay CMD24
                        if (!r_wr && last_read && r_sector == last_lba + 28'd1)
                            cmd_op <= 6'd18;
                        else
                            cmd_op <= r_wr ? 6'd24 : 6'd17;
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

                // read: CMD17/CMD18 -> token -> 512 bytes -> 2 CRC bytes.
                // For CMD18 the card streams blocks until CMD12; a
                // continuation op re-enters at A_RTOK, skipping A_RCMD_R.
                A_RCMD_R: begin
                    wait_cnt <= TOK_POLLS;
                    if (r1 == 8'h00) begin
                        // CMD18 accepted -> the card is now read-multiple
                        // streaming (needs a CMD12 to stop)
                        if (cmd_op == 6'd18)
                            stream_active <= 1'b1;
                        st <= A_RTOK;
                    end else begin
                        err <= 1'b1;
                        st  <= A_TAIL;
                    end
                end
                A_RTOK: begin
                    if (x_done) begin
                        if (x_rx == 8'hFE) begin
                            widx    <= '0;
                            have_lo <= 1'b0;
                            st      <= A_RDATA;
                        end else if (x_rx != 8'hFF || wait_cnt == 0) begin
                            err <= 1'b1;        // error token / timeout
                            if (stream_active) begin
                                // abandon the stream cleanly: CMD12, then finish
                                cmd_op   <= 6'd12;
                                cmd_arg  <= 32'h0000_0000;
                                cmd_crc  <= 8'h01;
                                want_ext <= 1'b0;
                                ret_st   <= A_STOP_R;
                                stop_ret <= A_FIN;
                                st       <= F_LEAD;
                            end else
                                st <= A_TAIL;
                        end else
                            wait_cnt <= wait_cnt - 1'b1;
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
                            widx     <= widx + 1'b1;
                            if (widx == 8'd255)
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
                        if (have_lo) begin
                            // block complete: advance the stream's expected LBA
                            // and skip the A_TAIL byte - the card streams the
                            // next block's data token back-to-back (possibly
                            // with zero NAC gap), which A_TAIL would consume
                            if (stream_active) begin
                                stream_next <= r_sector + 28'd1;
                                st <= A_FIN;
                            end else
                                st <= A_TAIL;
                        end
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // CMD12 close: F_R1 already skipped the stuffing byte and
                // captured R1; drain the busy window, then return
                A_STOP_R: begin
                    wait_cnt <= BUSY_POLLS;
                    st       <= A_STOP_BUSY;
                end
                A_STOP_BUSY: begin
                    if (x_done) begin
                        if (x_rx == 8'hFF || wait_cnt == 0) begin
                            stream_active <= 1'b0;
                            st            <= stop_ret;
                        end else
                            wait_cnt <= wait_cnt - 1'b1;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFF;
                    end
                end

                // write: CMD24 -> gap -> token -> 512 bytes -> CRC -> resp
                A_WCMD_R: begin
                    if (r1 == 8'h00)
                        st <= A_WGAP;
                    else begin
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
                        widx <= '0;
                        st   <= A_WFETCH;
                    end else begin
                        x_go <= 1'b1;
                        x_tx <= 8'hFE;
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
                        widx <= widx + 1'b1;
                        if (widx == 8'd255) begin
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
                        if (x_rx == 8'hFF)
                            st <= A_TAIL;
                        else if (wait_cnt == 0) begin
                            err <= 1'b1;
                            st  <= A_TAIL;
                        end else
                            wait_cnt <= wait_cnt - 1'b1;
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
                    // remember this op so the next contiguous read can escalate
                    // to CMD18 (a failed op breaks the run)
                    last_lba  <= r_sector;
                    last_read <= (!r_wr) && (!err);
                    st        <= A_IDLE;
                end

                // ---- parking states ----------------------------------------
                S_DEAD: begin                   // media absent until next DCLO
                    sd_cs <= 1'b1;
                end
                S_DISABLED: ;

                default: st <= S_DEAD;
            endcase
        end
    end

endmodule
