// ============================================================================
//  sd_model - behavioral SPI-mode SD card for the sd_backend oracles
//  (Phase-8 IDE increment (b)).
//
//  Mode-0 SPI slave (commands captured on the SCK rising edge, response
//  bits presented on the falling edge, byte-aligned to the host's frame),
//  decoding exactly the command set the host uses: CMD0/8/55/ACMD41/58/
//  16/9/17/24/25 and the CMD18/CMD12 read-multiple pair, with R1/R3/R7
//  responses, data tokens, NCR gaps and a busy-byte phase after writes.
//  CMD18 streams sequential blocks on demand as the host keeps clocking
//  (rsec_str auto-advances); CMD12 (recognised even mid-block on MOSI)
//  stops the stream, replies R1 and a short busy. CMD25 write-multiple
//  accepts 0xFC-tokened blocks (wsec auto-advances, each capacity-checked)
//  until the 0xFD stop-tran token closes the stream. The 16-bit word array `card` mirrors
//  ide_disk_model's `disk` (the tb $readmemh's the SAME ide_image.hex;
//  on the wire the LOW byte of each word travels first - the raw-image
//  little-endian convention).
//
//  Model-as-checker: protocol violations (wrong CMD0/CMD8 CRC, a bare
//  CMD41 without CMD55, a data/CSD command before init completes, a
//  misaligned SDSC byte address, an out-of-capacity sector, a CMD16 with
//  a non-512 size, an unknown command) print "SD-ERROR: ..." and bump
//  `prot_errors`, which the tb folds into its verdict. Transcript
//  counters (dummy_clocks, cmd*_cnt, rd_cnt/wr_cnt, cmd16_sdhc) are
//  read hierarchically by the tb.
//
//  Personality: `sdhc` (v2 block-addressed card, CSDv2) vs the +sdsc
//  plusarg (v1 byte-addressed legacy card: CMD8 answers illegal-command,
//  CSDv1). `capacity` (in 512-byte sectors) is a tb-pokeable reg;
//  defaults: SDHC 1024 (CSDv2 granularity), SDSC 640 (the image size,
//  CSDv1-exact). An SDHC card that is sent ACMD41 WITHOUT the HCS bit
//  never leaves idle - the real-card behaviour, and what kills the
//  HCS-drop mutation naturally.
//
//  Error injection plusargs: +noinit (ACMD41 never ready), +rderr (reads
//  answer an error token instead of data), +wrrej (writes rejected with
//  the CRC-error data response 0x0D and NOT committed).
// ============================================================================
`timescale 1ns/1ps
module sd_model #(
    parameter MAX_SECTORS = 1024,
    parameter READY_AFTER = 2,      // ACMD41 iterations until ready
    parameter NCR_FILL    = 1,      // fill bytes before R1
    parameter NAC_FILL    = 2,      // fill bytes before a read/CSD token
    parameter BUSY_BYTES  = 4       // 0x00 busy bytes after a write
)(
    input  rst,                     // clears the protocol state, not the data
    input  ck,
    input  cs,                      // active low
    input  mosi,
    output miso
);
    reg [15:0] card [0:MAX_SECTORS*256-1];

    // personality / config (tb-pokeable)
    reg         sdhc;
    reg [31:0]  capacity;           // sectors
    reg         inj_noinit, inj_rderr, inj_wrrej;

    // transcript counters (tb-read)
    integer dummy_clocks;           // CS-high clocks before the first command
    integer cmd_total;
    integer cmd0_cnt, cmd8_cnt, cmd55_cnt, acmd41_cnt, cmd58_cnt;
    integer cmd16_cnt, cmd9_cnt, rd_cnt, wr_cnt;
    integer cmd18_cnt, cmd12_cnt;   // read-multiple + stop-transmission
    integer cmd25_cnt, wm_stop_cnt; // write-multiple + its 0xFD stop-tran tokens
    integer cmd16_sdhc;             // CMD16 seen on an SDHC card (must stay 0)
    integer prot_errors;

    // protocol state
    reg        idle_state;          // between CMD0 and ACMD41-ready
    reg        init_done;
    reg        app_pend;            // CMD55 seen, next command is ACMDxx
    integer    acmd_tries;
    reg        reading_multi;       // inside a CMD18 read-multiple stream
    reg [31:0] rsec_str;            // next sector the stream will deliver
    reg        writing_multi;       // inside a CMD25 write-multiple stream

    initial begin
        sdhc       = !$test$plusargs("sdsc");
        capacity   = $test$plusargs("sdsc") ? 640 : 1024;
        inj_noinit = $test$plusargs("noinit");
        inj_rderr  = $test$plusargs("rderr");
        inj_wrrej  = $test$plusargs("wrrej");
        dummy_clocks = 0; cmd_total = 0;
        cmd0_cnt = 0; cmd8_cnt = 0; cmd55_cnt = 0; acmd41_cnt = 0;
        cmd58_cnt = 0; cmd16_cnt = 0; cmd9_cnt = 0; rd_cnt = 0; wr_cnt = 0;
        cmd18_cnt = 0; cmd12_cnt = 0;
        cmd25_cnt = 0; wm_stop_cnt = 0;
        cmd16_sdhc = 0; prot_errors = 0;
        idle_state = 0; init_done = 0; app_pend = 0; acmd_tries = 0;
        reading_multi = 0; rsec_str = 0; writing_multi = 0;
    end

    task prot_err(input [8*64-1:0] msg);
        begin
            prot_errors = prot_errors + 1;
            $display("SD-ERROR: %0s (time %0t)", msg, $time);
        end
    endtask

    // ---- output byte queue --------------------------------------------------
    reg [7:0] oq [0:1055];          // token + 512 data + slack
    integer   oq_rd, oq_wr;

    task oq_push(input [7:0] b);
        begin
            oq[oq_wr] = b;
            oq_wr = oq_wr + 1;
        end
    endtask

    // ---- byte-level protocol FSM state -----------------------------------------
    localparam MS_IDLE = 0, MS_ARG = 1, MS_CRC = 2,
               MS_WTOK = 3, MS_WDATA = 4, MS_WCRC = 5,
               MS_WMTOK = 6, MS_WMDATA = 7, MS_WMCRC = 8;
    integer    mstate;
    reg [5:0]  cur_cmd;
    reg [31:0] arg;
    integer    argi;
    reg [7:0]  wbytes [0:511];
    integer    wcnt, wcrc_cnt, bi;
    reg [31:0] wsec;
    reg        wrej;

    // ---- bit engine -----------------------------------------------------------
    reg [7:0] in_sh;
    integer   in_bits;
    reg [7:0] out_byte;
    reg       miso_r;

    initial begin in_bits = 0; oq_rd = 0; oq_wr = 0; out_byte = 8'hFF;
                  miso_r = 1'b1; mstate = MS_IDLE; end

    assign miso = cs ? 1'b1 : miso_r;

    always @(posedge cs or posedge rst) begin
        in_bits = 0;
        if (rst) begin
            idle_state = 0; init_done = 0; app_pend = 0; acmd_tries = 0;
            mstate = MS_IDLE; oq_rd = 0; oq_wr = 0; miso_r = 1'b1;
            reading_multi = 0; rsec_str = 0; writing_multi = 0;
        end
    end

    // command byte assembly on the rising edge
    always @(posedge ck) begin
        if (cs) begin
            if (cmd_total == 0)
                dummy_clocks = dummy_clocks + 1;
        end else begin
            in_sh   = {in_sh[6:0], mosi};
            in_bits = in_bits + 1;
            if (in_bits == 8) begin
                in_bits = 0;
                got_byte(in_sh);
            end
        end
    end

    // response bits on the falling edge, byte-aligned to the host frame
    always @(negedge ck) begin
        if (!cs) begin
            if (in_bits == 0) begin
                // CMD18 read-multiple: when the queue drains and the host
                // keeps clocking, stream the next sequential block on demand.
                // The rsec_str<capacity guard suppresses the benign one-past
                // refill on the CMD12-close clock (the host reads no data
                // there); a genuine past-capacity access is caught elsewhere.
                if (oq_rd == oq_wr && reading_multi
                    && rsec_str < capacity && rsec_str < MAX_SECTORS) begin
                    oq_rd = 0; oq_wr = 0;
                    push_read_block(rsec_str);
                    rsec_str = rsec_str + 1;
                end
                if (oq_rd < oq_wr) begin
                    out_byte = oq[oq_rd];
                    oq_rd = oq_rd + 1;
                    if (oq_rd == oq_wr) begin oq_rd = 0; oq_wr = 0; end
                end else
                    out_byte = 8'hFF;
            end
            miso_r = out_byte[7 - in_bits];
        end
    end

    // ---- byte-level protocol FSM ---------------------------------------------
    task got_byte(input [7:0] b);
        begin
            case (mstate)
                MS_IDLE: begin
                    if (b[7:6] == 2'b01) begin
                        cur_cmd = b[5:0];
                        arg     = 0;
                        argi    = 0;
                        mstate  = MS_ARG;
                    end else if (b !== 8'hFF)
                        prot_err("non-FF garbage byte outside a command");
                end
                MS_ARG: begin
                    arg  = {arg[23:0], b};
                    argi = argi + 1;
                    if (argi == 4) mstate = MS_CRC;
                end
                MS_CRC: begin
                    mstate = MS_IDLE;       // exec may override (CMD24)
                    exec_cmd(b);
                end
                MS_WTOK: begin
                    if (b == 8'hFE) begin
                        wcnt   = 0;
                        mstate = MS_WDATA;
                    end else if (b !== 8'hFF)
                        prot_err("garbage while waiting for the write token");
                end
                MS_WDATA: begin
                    wbytes[wcnt] = b;
                    wcnt = wcnt + 1;
                    if (wcnt == 512) begin
                        wcrc_cnt = 0;
                        mstate   = MS_WCRC;
                    end
                end
                MS_WCRC: begin
                    wcrc_cnt = wcrc_cnt + 1;
                    if (wcrc_cnt == 2) begin
                        commit_write(1'b0);         // single block: no advance
                        mstate = MS_IDLE;
                    end
                end
                // ---- CMD25 write-multiple: 0xFC block(s) closed by a 0xFD ----
                MS_WMTOK: begin
                    if (b == 8'hFC) begin
                        wcnt   = 0;
                        mstate = MS_WMDATA;
                    end else if (b == 8'hFD) begin  // stop-tran: close the stream
                        writing_multi = 0;
                        wm_stop_cnt   = wm_stop_cnt + 1;
                        for (bi = 0; bi < BUSY_BYTES; bi = bi + 1)
                            oq_push(8'h00);         // busy, then FF (empty q)
                        mstate = MS_IDLE;
                    end else if (b !== 8'hFF)
                        prot_err("garbage / command during a write-multiple stream");
                end
                MS_WMDATA: begin
                    wbytes[wcnt] = b;
                    wcnt = wcnt + 1;
                    if (wcnt == 512) begin
                        wcrc_cnt = 0;
                        mstate   = MS_WMCRC;
                    end
                end
                MS_WMCRC: begin
                    wcrc_cnt = wcrc_cnt + 1;
                    if (wcrc_cnt == 2) begin
                        commit_write(1'b1);         // multi: advance wsec after
                        mstate = MS_WMTOK;          // back for the next block
                    end
                end
            endcase
        end
    endtask

    // fold a data-command address down to a sector index (with checks)
    task cmd_sector(input [31:0] a, output [31:0] s);
        begin
            if (sdhc)
                s = a;
            else begin
                if (a[8:0] != 9'd0)
                    prot_err("SDSC byte address not 512-aligned");
                s = a >> 9;
            end
        end
    endtask

    integer i, mult, csz;
    reg [127:0] csd_img;
    reg csd_found;

    task push_r1(input [7:0] v);
        begin
            for (i = 0; i < NCR_FILL; i = i + 1) oq_push(8'hFF);
            oq_push(v);
        end
    endtask

    task build_csd;
        begin
            csd_img = 128'h0;
            if (sdhc) begin
                if (capacity[9:0] != 0 || capacity < 1024)
                    prot_err("config: SDHC capacity not a 1024 multiple");
                csd_img[127:126] = 2'b01;
                csd_img[69:48]   = capacity / 1024 - 1;
            end else begin
                csd_img[127:126] = 2'b00;
                csd_img[83:80]   = 4'd9;            // READ_BL_LEN = 512
                csd_found = 0;
                for (mult = 7; mult >= 0; mult = mult - 1)
                    if (!csd_found
                        && (capacity % (1 << (mult + 2))) == 0
                        && (capacity >> (mult + 2)) >= 1
                        && (capacity >> (mult + 2)) <= 4096) begin
                        csz = (capacity >> (mult + 2)) - 1;
                        csd_img[73:62] = csz[11:0];
                        csd_img[49:47] = mult[2:0];
                        csd_found = 1;
                    end
                if (!csd_found)
                    prot_err("config: SDSC capacity not CSDv1-encodable");
            end
        end
    endtask

    // push one read data block (NAC fill, token, 512 bytes LOW-first, CRC)
    // or the error token under +rderr; capacity-checked per block so a
    // CMD18 stream running past the card is caught
    task push_read_block(input [31:0] sec);
        begin
            if (sec >= capacity || sec >= MAX_SECTORS)
                prot_err("read sector out of capacity");
            if (inj_rderr)
                oq_push(8'h09);                 // error token: range+error
            else begin
                for (i = 0; i < NAC_FILL; i = i + 1) oq_push(8'hFF);
                oq_push(8'hFE);
                for (i = 0; i < 256; i = i + 1) begin
                    oq_push(card[sec*256 + i][7:0]);   // LOW byte first
                    oq_push(card[sec*256 + i][15:8]);
                end
                oq_push(8'h55); oq_push(8'h55);
            end
        end
    endtask

    task exec_cmd(input [7:0] crcb);
        reg [31:0] sec;
        reg        was_app;
        begin
            cmd_total = cmd_total + 1;
            was_app   = app_pend;
            app_pend  = 0;
            // only CMD12 is legal while a read-multiple stream is open
            if (reading_multi && cur_cmd != 6'd12)
                prot_err("non-CMD12 command during a read-multiple stream");
            case (cur_cmd)
                6'd0: begin
                    cmd0_cnt = cmd0_cnt + 1;
                    if (arg != 0 || crcb !== 8'h95)
                        prot_err("CMD0 arg/CRC wrong (needs 0/0x95)");
                    idle_state = 1;
                    init_done  = 0;
                    acmd_tries = 0;
                    push_r1(8'h01);
                end
                6'd8: begin
                    cmd8_cnt = cmd8_cnt + 1;
                    if (arg != 32'h0000_01AA || crcb !== 8'h87)
                        prot_err("CMD8 arg/CRC wrong (needs 0x1AA/0x87)");
                    if (sdhc) begin                 // v2 card: R7 echo
                        push_r1(8'h01);
                        oq_push(8'h00); oq_push(8'h00);
                        oq_push(8'h01); oq_push(8'hAA);
                    end else
                        push_r1(8'h05);             // v1 card: illegal command
                end
                6'd55: begin
                    cmd55_cnt = cmd55_cnt + 1;
                    app_pend  = 1;
                    push_r1(idle_state ? 8'h01 : 8'h00);
                end
                6'd41: begin
                    if (!was_app) begin
                        prot_err("bare CMD41 without CMD55");
                        push_r1(8'h04);
                    end else begin
                        acmd41_cnt = acmd41_cnt + 1;
                        if (inj_noinit || (sdhc && !arg[30]))
                            push_r1(8'h01);         // never ready (no HCS!)
                        else begin
                            acmd_tries = acmd_tries + 1;
                            if (acmd_tries >= READY_AFTER) begin
                                idle_state = 0;
                                init_done  = 1;
                                push_r1(8'h00);
                            end else
                                push_r1(8'h01);
                        end
                    end
                end
                6'd58: begin
                    cmd58_cnt = cmd58_cnt + 1;
                    push_r1(idle_state ? 8'h01 : 8'h00);
                    oq_push({init_done, sdhc && init_done, 6'h00});
                    oq_push(8'hFF); oq_push(8'h80); oq_push(8'h00);
                end
                6'd16: begin
                    cmd16_cnt = cmd16_cnt + 1;
                    if (arg != 512)
                        prot_err("CMD16 size != 512");
                    if (sdhc)
                        cmd16_sdhc = cmd16_sdhc + 1;
                    push_r1(8'h00);
                end
                6'd9: begin
                    cmd9_cnt = cmd9_cnt + 1;
                    if (!init_done)
                        prot_err("CMD9 before init complete");
                    build_csd;
                    push_r1(8'h00);
                    for (i = 0; i < NAC_FILL; i = i + 1) oq_push(8'hFF);
                    oq_push(8'hFE);
                    for (i = 15; i >= 0; i = i - 1)
                        oq_push(csd_img[8*i +: 8]);
                    oq_push(8'h55); oq_push(8'h55); // CSD CRC (host ignores)
                end
                6'd17: begin
                    rd_cnt = rd_cnt + 1;
                    cmd_sector(arg, sec);
                    if (!init_done)
                        prot_err("CMD17 before init complete");
                    push_r1(8'h00);
                    push_read_block(sec);
                end
                6'd18: begin                        // read multiple block
                    cmd18_cnt = cmd18_cnt + 1;
                    cmd_sector(arg, sec);
                    if (!init_done)
                        prot_err("CMD18 before init complete");
                    push_r1(8'h00);
                    push_read_block(sec);           // first block now
                    reading_multi = 1;              // stream the rest on demand
                    rsec_str = sec + 1;
                end
                6'd12: begin                        // stop transmission
                    cmd12_cnt = cmd12_cnt + 1;
                    if (!reading_multi)
                        prot_err("CMD12 outside a read-multiple stream");
                    reading_multi = 0;
                    oq_rd = 0; oq_wr = 0;           // drop the streaming block
                    push_r1(8'h00);                 // stuff byte(s) + R1
                    for (i = 0; i < BUSY_BYTES; i = i + 1)
                        oq_push(8'h00);             // busy, then FF (empty q)
                end
                6'd24: begin
                    wr_cnt = wr_cnt + 1;
                    cmd_sector(arg, sec);
                    if (!init_done)
                        prot_err("CMD24 before init complete");
                    if (sec >= capacity || sec >= MAX_SECTORS)
                        prot_err("CMD24 sector out of capacity");
                    wsec = sec;
                    wrej = inj_wrrej;
                    push_r1(8'h00);
                    mstate = MS_WTOK;
                end
                6'd25: begin                        // write multiple block
                    cmd25_cnt = cmd25_cnt + 1;
                    cmd_sector(arg, sec);
                    if (!init_done)
                        prot_err("CMD25 before init complete");
                    if (sec >= capacity || sec >= MAX_SECTORS)
                        prot_err("CMD25 sector out of capacity");
                    wsec = sec;
                    wrej = inj_wrrej;
                    writing_multi = 1;              // 0xFC blocks until 0xFD
                    push_r1(8'h00);
                    mstate = MS_WMTOK;
                end
                default: begin
                    prot_err("unknown command");
                    push_r1(8'h04);
                end
            endcase
        end
    endtask

    // commit one write block: data-response token + busy. For the multi
    // (CMD25) path capacity-check the running sector and auto-advance wsec.
    task commit_write(input multi);
        begin
            if (multi && (wsec >= capacity || wsec >= MAX_SECTORS))
                prot_err("write-multiple sector out of capacity");
            if (wrej)
                oq_push(8'h0D);                     // CRC-error reject
            else begin
                for (i = 0; i < 256; i = i + 1)
                    card[wsec*256 + i] = {wbytes[2*i + 1], wbytes[2*i]};
                oq_push(8'h05);                     // accepted
            end
            for (i = 0; i < BUSY_BYTES; i = i + 1)
                oq_push(8'h00);                     // busy, then FF (empty q)
            if (multi)
                wsec = wsec + 1;
        end
    endtask

endmodule
