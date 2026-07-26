//
// Phase-9 SMK512 memory-ACCESS-TIME oracle (a timing measurement, calibrated
// against the real BK-0011M + SMK512 - see sim/smktime/run.sh for the numbers).
//
//   vm1 CPU + va_037_sync + the REAL qbus_mem (mem_mapper with smk_en=1 in
//   BK-0011M mode + the MK_EXT FSM legs + cpu_sdram_dp + arbiter + ctrl) +
//   behavioural sdram_model (DEEPENED to 1<<19 words - SMK RAM lives at
//   0x40000-0x7FFFF) + the port-2 video-fetch saturator for contention.
//   The same stack sim/smk/smk_soc_tb.v uses; this tb only measures.
//
// The program is doc/sndtestsmk.bin VERBATIM (see mem/gen_snd_test.py): a
// 192-iteration SOB delay loop toggling the 177716 speaker bit, so the emitted
// tone frequency is a direct readout of the access time of whatever memory the
// loop is resident in.  One half-period = one SND..BR pass = 197 instruction
// fetches, all from that memory.
//
//   default   the loop runs from SMK RAM (MK_EXT)      -> calibrates N_EXT
//   +stdram   the same loop runs in ordinary RAM       -> control leg, the
//             (037-fronted, cycle-stolen)                 already-calibrated
//                                                         N_RAM=4 + 037 steal
//   +bk10     the SMK leg on a BK-0010 stack (model_bk11=0, /32 CPU rate, the
//             program resident in the machine's own RAM) - the SMK is an МПИ
//             expansion board and DIP 8 works in both models, so bk10+SMK is a
//             shipped configuration whose memory timing nothing else measures.
//             It is also where the early issue's `early_pend` interlock earns
//             its keep: at /32 the SYNC->DIN gap is long enough that the
//             prefetched word can arrive BEFORE DIN does.
//
// Boot rides the REAL SMK mechanism (SYS rom7 register-space overlay -> the
// merged 177716 read -> PC 166400 in the rom6 window -> the stage-0 JMP).
//
// Output (the golden):
//   LOOP <addr> n=<count> min=<cycles> max=<cycles>
//        the gap from each loop-body fetch to the next one, i.e. the
//        per-instruction cost.  On the control leg the 037 steal makes
//        min != max (the authentic beat).
//   HALF <i> cycles=<n>          each measured tone half-period
//   EXTRD fast=.. slow=.. early=..  how many MK_EXT reads got the N=1 reply at
//                                the detection edge vs took the +1-cycle S_WAIT
//                                fallback; `early` = SYNC-time issues made
//   RESULT halves=.. cycles=.. avg=.. freq=..
//
// A `dbg_romgate` probe fails the run if qbus_mem ever had to hold an RPLY for
// MORE than that one extra edge: that is the early read not working at all,
// and the fixed count silently becoming "whenever the SDRAM got there".
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module smk_time_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // The REAL hardware CPU clock (21.47727 MHz x9/2 = 96.6477 MHz sys_clk,
    // /24 in BK-0011M mode, /32 in BK-0010 mode), used ONLY to convert measured
    // cycles into Hz so the number is directly comparable with the tone
    // measured on the board.  The tb's own sys_clk is a round 100 MHz -
    // deliberately not used here.
    localparam real SYS_HZ = 96647715.0;

    // ---- leg select --------------------------------------------------------
    reg stdram, bk10;
    integer nhalf, nsettle;
    real    CPU_HZ;
    initial begin
        stdram = $test$plusargs("stdram");
        bk10   = $test$plusargs("bk10");
        CPU_HZ = SYS_HZ / (bk10 ? 32.0 : 24.0);
        if (!$value$plusargs("halves=%d",  nhalf))   nhalf   = 4;
        if (!$value$plusargs("settle=%d",  nsettle)) nsettle = 2;
    end

    // Loop-body base: SND (the first instruction of the tone half-period) and
    // the enclosing fetch window.  --stdram runs the loop in place at START
    // (0o2046); the default runs the copy at 0140000.
    wire [15:0] LOOP_LO  = stdram ? 16'o002062 : 16'o140014;
    wire [15:0] FETCH_LO = stdram ? 16'o002046 : 16'o140000;
    wire [15:0] FETCH_HI = stdram ? 16'o002076 : 16'o140026;
    localparam [15:0] FAIL_PARK = 16'o001012;   // = mem/gen_snd_test.py

    // ---- clocks: sys_clk + /16 037 enables + /24 CPU clock (cpu_clkgen
    //      replica in BK-0011M mode: toggle every 12 sys_clk) ---------------
    reg       sys_clk;
    reg [3:0] divc;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 4'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc == 4'd15);
    wire en_neg = (divc == 4'd7);

    reg [3:0] cdiv;
    reg       cpu_clk_r;
    initial begin cdiv = 4'd0; cpu_clk_r = 1'b0; end
    wire [3:0] cdiv_max = bk10 ? 4'd15 : 4'd11;   // /32 bk10, /24 bk11
    always @(posedge sys_clk) begin
        if (cdiv >= cdiv_max) begin cdiv <= 4'd0; cpu_clk_r <= ~cpu_clk_r; end
        else                  cdiv <= cdiv + 1'b1;
    end
    wire clk = cpu_clk_r;

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;                        // 037 reply (RAM) -> open-collector
    // D8:B - the board flop that re-times the 037's RPLY onto the CPU
    // clock's falling edge before it reaches the CPU pin.  The REAL
    // module, never a replica (the cpu_clkgen drift lesson).
    wire        rply037_rt_n;
    assign rply = (rply037_rt_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;   // power-on-only video-side reset (037)
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        n_irq2;    // EVNT/IRQ2 (bk_evnt, masked throughout)
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- tb-side address latch ----------------------------------------------
    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU ----------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(pa), .pin_sp_n(sp),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n({irq[3], n_irq2, 1'b1}), .pin_virq_n(virq),
        .pin_ad_n(ad), .pin_dout_n(dout), .pin_din_n(din),
        .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
        .pin_dmr_n(dmr), .pin_sack_n(sack), .pin_dmgi_n(dmgi),
        .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel), .pin_bsy_n(bsy)
    );

    // ---- retimed 037 (owns RAM RPLY for A15=0, done-gate = mem_ready) -------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        mem_ext_ram;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready),
        .ext_ram(mem_ext_ram),
        .PIN_R(~dclo_cold), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate)
    );

    // ---- video fetch requester (arbiter port 2): worst-case streaming reads --
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)              fetch_req <= 1'b0;
        else if (fetch_gnt)     fetch_req <= 1'b0;
        else                    fetch_req <= 1'b1;
    end

    // ---- the REAL integration module: BK-0011M mode + SMK512 -----------------
    wire init_done;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire [DW-1:0] v_rdata_nc;
    wire        vid_page, vid_irq2m;
    wire [3:0]  vid_pal;
    wire        stop_block;

    qbus_mem u_ms (
        .cpu_clk  (~clk),            // as ocbk_top: FSM on the inverted CPU clock
        .reset    (~dclo),
        .ide_rdata(16'h0000),
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(~bk10),
        .smk_en   (1'b1),
        .boot_active(1'b0),
        .bw_req   (1'b0),
        .bw_addr  ({AB{1'b0}}),
        .bw_wdata ({DW{1'b0}}),
        .bw_gnt   (),
        .sclk     (sys_clk),
        .srst_n   (srst_n),
        .init_done(init_done),
        .ad_n     (ad),
        .sync_n   (sync),
        .din_n    (din),
        .dout_n   (dout),
        .wtbt_n   (wtbt),
        .rply_n   (rply),
        .mem_ready(mem_ready),
        .ext_ram  (mem_ext_ram),
        .v1_req   (1'b0),
        .v1_addr  ({AB{1'b0}}),
        .v1_gnt   (),
        .v1_rvalid(),
        .v2_req   (fetch_req),
        .v2_addr  (fetch_addr),
        .v2_gnt   (fetch_gnt),
        .v2_rvalid(fetch_rvalid),
        .v3_req   (1'b0),
        .v3_addr  ({AB{1'b0}}),
        .v3_wdata ({DW{1'b0}}),
        .v3_gnt   (),
        .v_rdata  (v_rdata_nc),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
        .bus_addr (bus_addr),
        .fetch_stb(fetch_stb),
        .vid_page (vid_page),
        .vid_irq2_mask(vid_irq2m),
        .vid_pal  (vid_pal),
        .stop_block(stop_block)
    );

    sdram_model #(.MEM_WORDS(1<<19)) u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- EVNT/IRQ2: the real detector, masked throughout (no ISR here) ------
    wire      irq2_lvl;
    reg [1:0] irq2_sr;
    initial   irq2_sr = 2'b00;
    bk_evnt evnt (
        .sys_clk(sys_clk), .rst_n(dclo_cold),
        .wti(va_wti), .synco(va_vsync),
        .irq_en(~bk10 & ~vid_irq2m), .evnt(irq2_lvl)
    );
    always @(posedge clk) irq2_sr <= {irq2_sr[0], irq2_lvl};
    assign n_irq2 = ~irq2_sr[1];

    // =====================================================================
    // Measurement
    // =====================================================================
    integer nclk;
    initial nclk = 0;
    always @(posedge clk) nclk = nclk + 1;

    reg     measuring;
    integer spk_n;                      // 177716 writes seen
    integer last_nclk;
    integer half_i;
    integer tot_cycles;
    integer ext_fast_n, ext_slow_n;    // the N=1 one-edge fallback rate (below)
    integer early_n;                   // early issues made, whole run (below)
    initial begin
        measuring = 1'b0; spk_n = 0; last_nclk = 0; half_i = 0; tot_cycles = 0;
        ext_fast_n = 0; ext_slow_n = 0; early_n = 0;
    end

    // ---- per-fetch gap table (index = (addr - LOOP_LO) >> 1, 0..7) ---------
    integer gcnt [0:7];
    integer gmin [0:7];
    integer gmax [0:7];
    integer gi;
    initial for (gi = 0; gi < 8; gi = gi + 1) begin
        gcnt[gi] = 0; gmin[gi] = 1000000; gmax[gi] = 0;
    end

    integer prev_nclk;
    reg [15:0] prev_addr;
    reg        have_prev;
    integer    gap, idx;
    initial begin prev_nclk = 0; prev_addr = 16'o0; have_prev = 1'b0; end

    task fail(input [255:0] why);
        begin
            $display("SMKTIME-ERROR: %0s (addr %06o, t=%0t)", why, addr, $time);
            $display("SMKTIME FAIL");
            $finish;
        end
    endtask

    always @(negedge din) begin
        if (~sync) begin
            if (addr == FAIL_PARK) fail("fail park reached (a bus timeout trapped)");
            if (measuring) begin
                if (addr < FETCH_LO || addr > FETCH_HI)
                    fail("fetch outside the loop body");
                if (have_prev && prev_addr >= LOOP_LO
                              && (prev_addr - LOOP_LO) < 16) begin
                    idx  = (prev_addr - LOOP_LO) >> 1;
                    gap  = nclk - prev_nclk;
                    gcnt[idx] = gcnt[idx] + 1;
                    if (gap < gmin[idx]) gmin[idx] = gap;
                    if (gap > gmax[idx]) gmax[idx] = gap;
                end
            end
            prev_addr = addr;
            prev_nclk = nclk;
            have_prev = 1'b1;
        end
    end

    // ---- the tone: one 177716 write per SND pass ---------------------------
    // (the vm1 self-replies for the 177700-177717 block, so this write costs
    // nothing on the qbus_mem side - it is purely the half-period marker)
    always @(negedge dout) begin
        if (~sync && addr == 16'o177716) begin
            spk_n = spk_n + 1;
            if (spk_n == nsettle) begin
                measuring = 1'b1;               // skip boot + the loop set-up
            end else if (spk_n > nsettle) begin
                half_i     = half_i + 1;
                gap        = nclk - last_nclk;
                tot_cycles = tot_cycles + gap;
                $display("HALF %0d cycles=%0d", half_i, gap);
                if (half_i == nhalf) report;
            end
            last_nclk = nclk;
        end
    end

    task report;
        real avg, freq;
        begin
            for (gi = 0; gi < 8; gi = gi + 1)
                if (gcnt[gi] != 0)
                    $display("LOOP %06o n=%0d min=%0d max=%0d",
                             16'(LOOP_LO + 2*gi), gcnt[gi], gmin[gi], gmax[gi]);
            avg  = tot_cycles / (nhalf * 1.0);
            freq = CPU_HZ / (2.0 * avg);
            $display("EXTRD fast=%0d slow=%0d early=%0d",
                     ext_fast_n, ext_slow_n, early_n);
            $display("RESULT halves=%0d cycles=%0d avg=%0.1f freq=%0.1f Hz",
                     nhalf, tot_cycles, avg, freq);
            $display("SMKTIME PASS");
            $finish;
        end
    endtask

    // ---- the done-gate probe: an RPLY held for MORE than one extra edge
    //      waiting for the SDRAM word.  At N_EXT = 1 this must never happen -
    //      it would mean the early (SYNC-time) read issue is not working at
    //      all, and the "fixed count" would have become "whenever the SDRAM
    //      got there".
    always @(posedge u_ms.dbg_romgate)
        fail("dbg_romgate: an RPLY was extended waiting for the SDRAM word");

    // ---- the ONE-edge fallback rate ----------------------------------------
    // At N_EXT = 1 the reply is issued at the detection edge itself, which
    // needs mem_ready already up.  The early read gets ~22 sys_clk of head
    // start and the SDRAM needs ~8, but the arbiter grant costs another 4..14
    // under this tb's WORST-CASE port-2 saturator - so a minority of reads
    // miss by one edge and take the ordinary S_WAIT path (+1 CPU cycle, no
    // dbg_romgate).  Counting them makes that jitter a pinned number rather
    // than an invisible one: it is the difference between the ideal 3327
    // cycles and the measured half-period.  A real machine's port 2 is paced,
    // not saturating, so the board should land a little FASTER than this.
    always @(posedge u_ms.cpu_clk)
        if (measuring && u_ms.state == 0 && !u_ms.sync_n && u_ms.selected
            && u_ms.sel_ext && !u_ms.ovl_zone && u_ms.is_read) begin
            if (u_ms.ext_fast) ext_fast_n = ext_fast_n + 1;
            else               ext_slow_n = ext_slow_n + 1;
        end

    // ---- early issues actually made, over the WHOLE run --------------------
    // One per MK_EXT mem-region READ cycle and NOT ONE MORE.  This is what
    // pins `wtbt_hold`: WTBT's address-phase meaning is on the wire for only
    // ~120 ns, so sampling it live lets every SMK-RAM WRITE cycle fire a
    // spurious early read once WTBT goes away.  The tone loop itself contains
    // no SMK-RAM write - its only write is the I/O-page 177716 - so this has
    // to count from reset, where the program's 12-word copy up into SMK RAM
    // supplies them.
    always @(posedge sys_clk)
        if (u_ms.u_dp.early_rd && u_ms.u_dp.state == 0) early_n = early_n + 1;

    // ---- X monitor at the reply edges (sim/smk shape) ----------------------
    always @(negedge rply) if (aclo === 1'b1) begin
        #1;
        if (!din && ^ad === 1'bx) fail("bus drive fight (ad=X)");
        if (rply === 1'bx)        fail("rply=X");
    end

    // ---- SDRAM preload -----------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<19); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        // the residence image: BK-0011M physical RAM page 6 (000000-037777)
        // or, under +bk10, the whole BK-0010 RAM (000000-077777, SDRAM 0x0000)
        if (bk10) $readmemh("snd_low10.hex", u_mem.mem, 'h00000, 'h03FFF);
        else      $readmemh("snd_page6.hex", u_mem.mem, 'h2C000, 'h2DFFF);
        // the synthetic SMK BIOS at SMK_BIOS_BASE - where the EPCS loader puts
        // the real one.  SMK RAM itself gets NO preload: the default leg's
        // program copies its own loop up there.
        $readmemh("snd_bios.hex", u_mem.mem, 'h3A000, 'h3A7FF);
    end

    // ---- reset (wait SDRAM init) + watchdog --------------------------------
    initial begin
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0; dclo_cold=1'b0;

        wait (init_done);
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1; dclo_cold = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #400_000_000;
        $display("SMKTIME-ERROR: watchdog timeout (last addr %o, halves %0d)",
                 addr, half_i);
        $display("SMKTIME FAIL");
        $finish;
    end


// D8:B, the board's RPLY re-timing flop (src/bk_rply.sv) - the REAL module,
// never a replica (the cpu_clkgen drift lesson).  Placed at the end of the
// module so it cannot depend on where the reset regs are declared.
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo_cold),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
