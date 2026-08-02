//
// Phase-9 177662 WRITE-TIME oracle: the calibration of N_VREG, and the
// regression that keeps it calibrated.
//
//   vm1 CPU + va_037_sync + the REAL qbus_mem (BK-0011M mode, smk_en=0 - a
//   stock BK-0011M) + cpu_sdram_dp + arbiter + ctrl + behavioural sdram_model
//   + the port-2 video-fetch saturator for contention.  The sim/smktime stack
//   with the SMK turned off; this tb only measures.
//
// WHY N_VREG NEEDS A MEASUREMENT OF ITS OWN
// -----------------------------------------
// It is the reply count for a 177662 (video page / palette) write, i.e. it is
// paid ONCE PER PALETTE WRITE.  Inside a beam-raced multicolor loop that error
// INTEGRATES: at ~8-16 writes on a 256-CPU-cycle scanline, one cycle per write
// is a 3-6 % per-line stretch, which is a progressive SKEW down the screen and
// not a static offset.  Every other timing such a loop touches was already
// calibrated (N_RAM + the 037 steal on hardware; 177716 = the vm1 internal
// reply; EVNT/IRQ2 = sim/evnt vs the reference netlist).
//
// The program is test/sndtest662.bin (mem/gen_vreg_test.py): 192 writes per
// tone half-period, so one unit of N moves the tone ~4.5 %.
//
//   default   the 192 writes go to 177662  -> N_VREG, the constant under test
//   +ramleg   the SAME loop, R0 pointing at a scratch word in the memory it
//             is already resident in -> MK_RAM037, N_RAM=4 + the 037 steal.
//             CONTROL leg: that path is hardware-calibrated to +0.04 %, so it
//             validates the clock rate, the access-count model and the
//             assembler, and isolates any remaining error to N_VREG.
//
// Boot is the stock BK-0011M one: the vm1's 177716 start-vector read returns
// SYS_START11 = 0140000, the fixed top ROM, where vreg_top.hex plants a
// stage-0 JMP to the leg's entry point (the sim/bk11 idiom).
//
// Output (the golden):
//   LOOP <addr> n=<count> min=<cycles> max=<cycles>
//        the gap from each unrolled `MOV R1,(R0)` fetch to the next one, i.e.
//        THE COST OF ONE WRITE, directly.  This is the sharp number; the tone
//        below is what a real machine can be compared on.
//   HALF <i> cycles=<n>              each measured tone half-period
//   VREGWR fast=.. slow=..           how many 177662 writes got the N=1 reply
//                                    at the detection edge vs took the S_WAIT
//                                    path.  At N_VREG=1 slow must be 0.
//   RESULT halves=.. cycles=.. avg=.. freq=..
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module vreg_time_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // The REAL hardware CPU clock (21.47727 MHz x9/2 = 96.6477 MHz sys_clk,
    // /24 in BK-0011M mode, /32 in BK-0010 mode), used ONLY to convert measured
    // cycles into Hz so the number is directly comparable with the tone
    // measured on the board.  The tb's own sys_clk is a round 100 MHz -
    // deliberately not used here.
    localparam real SYS_HZ = 96647715.0;

    // ---- leg select --------------------------------------------------------
    // +ramleg selects the control entry point; which entry the program uses is
    // baked into vreg_top.hex by mem/gen_vreg_test.py --ramleg, so this flag
    // only has to agree with it (checked below via the first write target).
    reg ramleg;
    integer nhalf, nsettle;
    real    CPU_HZ;
    initial begin
        ramleg = $test$plusargs("ramleg");
        CPU_HZ = SYS_HZ / 24.0;                 // BK-0011M rate
        if (!$value$plusargs("halves=%d",  nhalf))   nhalf   = 4;
        if (!$value$plusargs("settle=%d",  nsettle)) nsettle = 2;
    end

    // The loop body (mem/gen_vreg_test.py): SND at 0o2040 opens the tone
    // half-period, the 8 unrolled `MOV R1,(R0)` writes start at LOOP = 0o2050,
    // and the enclosing fetch window ends at the `BR SND` at 0o2072.  Both legs
    // run the same resident code, so these are leg-independent (SCRATCH, the control
    // leg's target, is at 0o2074 - written, never fetched).
    localparam [15:0] LOOP_LO  = 16'o002050;
    localparam [15:0] FETCH_LO = 16'o002040;
    localparam [15:0] FETCH_HI = 16'o002072;
    localparam [15:0] FAIL_PARK = 16'o001012;   // = mem/gen_vreg_test.py

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
    localparam [3:0] cdiv_max = 4'd11;            // /24 = BK-0011M
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
        .no_steal(1'b0),   // turbo off: authentic 037 arbitration
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
        .turbo(1'b0),      // turbo off: RAM RPLY stays the 037's
        .cpu_clk  (~clk),            // as ocbk_top: FSM on the inverted CPU clock
        .reset    (~dclo),
        .ide_rdata(16'h0000),
        .joy_word(16'o000000), // no joysticks here; never leave it
                               // floating - an X poisons rdata
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(1'b1),
        .smk_en   (1'b0),   // stock BK-0011M
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
        .irq_en(~vid_irq2m), .evnt(irq2_lvl)
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
    integer vreg_fast_n, vreg_slow_n;  // the 177662 write reply path (below)
    initial begin
        measuring = 1'b0; spk_n = 0; last_nclk = 0; half_i = 0; tot_cycles = 0;
        vreg_fast_n = 0; vreg_slow_n = 0;
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
            $display("VREGTIME-ERROR: %0s (addr %06o, t=%0t)", why, addr, $time);
            $display("VREGTIME FAIL");
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
            $display("VREGWR fast=%0d slow=%0d", vreg_fast_n, vreg_slow_n);
            $display("RESULT halves=%0d cycles=%0d avg=%0.1f freq=%0.1f Hz",
                     nhalf, tot_cycles, avg, freq);
            $display("VREGTIME PASS");
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

    // ---- the 177662 write reply path --------------------------------------
    // At N_VREG = 1 every one of these writes must be replied at the DETECTION
    // edge (qbus_mem's `vreg_fast`).  Counting the two outcomes turns "the fast
    // path is wired up" into a pinned number instead of an invisible one: if
    // vreg_fast were ever excluded, slow would jump to 192 per half-period and
    // every gap in the LOOP table would grow by exactly one cycle.
    always @(posedge u_ms.cpu_clk)
        if (measuring && u_ms.state == 0 && !u_ms.sync_n
            && u_ms.sel_vreg && u_ms.is_write) begin
            if (u_ms.vreg_fast) vreg_fast_n = vreg_fast_n + 1;
            else                vreg_slow_n = vreg_slow_n + 1;
        end

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
        // the residence image: BK-0011M physical RAM page 6, which is what the
        // DCLO-default window-0 map puts at 000000-037777
        $readmemh("vreg_ram.hex", u_mem.mem, 'h2C000, 'h2DFFF);
        // the stage-0 stub in the fixed top ROM at BK 140000 = the start
        // vector the vm1 reads from 177716 on a BK-0011M (SYS_START11)
        $readmemh("vreg_top.hex", u_mem.mem, 'h38000, 'h3803F);
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
        $display("VREGTIME-ERROR: watchdog timeout (last addr %o, halves %0d)",
                 addr, half_i);
        $display("VREGTIME FAIL");
        $finish;
    end


// D8:B, the board's RPLY re-timing flop (src/bus/bk_rply.sv) - the REAL module,
// never a replica (the cpu_clkgen drift lesson).  Placed at the end of the
// module so it cannot depend on where the reset regs are declared.
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo_cold),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
