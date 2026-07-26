// va_037_sync - retimed 1801VP1-037 (video/arbiter) for the single-PLL ocbk clock
// tree (Phase 3).
//
// This is a NEAR-VERBATIM port of the reference model
// sim/ref037/va_037.v (vendored from ~/projects/other/fpga/k1801/037/rtl). The
// combinational logic is identical; only the clocking changes so the core runs in
// the 96.65 MHz sys_clk domain with fabric clock-enables (one-PLL discipline):
//
//   original                    ->  retimed
//   always @(posedge CLKIN)     ->  always_ff @(posedge clk) if (en_pos)
//   always @(negedge CLKIN)     ->  always_ff @(posedge clk) if (en_neg)
//   always @(posedge RESET) ..  ->  synchronous  if (RESET) ..  (RESET held > 1 CLKIN)
//   transparent latch @(*)      ->  clocked-transparent @(posedge clk) (updates every
//                                   sys_clk while the enable condition holds)
//
// CLKIN = sys_clk/16 (6.04 MHz); en_pos and en_neg are the two ÷16 strobes half a
// CLKIN period (8 sys_clk) apart, generated in ocbk_top from the same divider that
// yields the CPU clock (cpu = sys_clk/32 = CLKIN/2), preserving the CPU:037 phase.
//
// RPLY done-gate (Phase 3 interlock): the internal RPLY still follows the 037 grant
// (cycle-accurate), but the open-collector reply to the CPU is additionally gated by
// mem_ready - so a late SDRAM read EXTENDS RPLY rather than latching stale data. With
// mem_ready tied 1 the core is bit-identical to the reference (validated against
// sim/ref037/golden_037.txt); the arbiter drives mem_ready in integration.
//
// All original DRAM-strobe outputs (PIN_A/nCAS/nRAS/nWE) are retained so the retime
// can be checked signal-for-signal against the reference; the SDRAM-request
// translation consumes the video address (VA) and grant, not these pins.
//
// The bus PIN_nAD / PIN_nRPLY keep the reference's drive discipline; PIN_nRPLY is
// converted to open-collector at the parent (as the reference tb / qbus_sdram do).
module va_037_sync #(
    // ---- GRANT_SETUP: the request setup window at the PC==4 grant decision --
    // The reference model samples {SYNC, the strobes, A15} LIVE at the instant
    // it decides the grant. Real silicon has a setup requirement at that latch,
    // and a gate-level functional model cannot express one - so a request that
    // arrives inside the setup shadow is granted here and loses a whole 8-CLKIN
    // slot on the real chip. GRANT_SETUP is that window, in half-CLKIN phases.
    //
    // = 2 (one full CLKIN) is CALIBRATED, not guessed: with bk_rply it puts all
    // SEVEN real-BK-0011M tone legs inside +/-1 Hz of their measured readings
    // (sim/grantfit/README.md), where the uncalibrated model was -3.7 % on RAM
    // writes, -14.7 % on `MOV #imm,Rn` and -6.2 % on Babylona's per-scanline
    // block - the beam-raced palette skew. Per instruction it adds EXACTLY one
    // grant slot to the second read of a back-to-back pair and nothing to a
    // fetch 2.5 slots later, which is the pattern-dependence the tones showed.
    //
    // = 0 is BIT-IDENTICAL to the reference netlist (the expression below folds
    // back to the original `~(nSYNC | a15 | RPLY | (nDIN & nDOUT))` and the
    // shift register optimises away). sim/ref037 runs this core BOTH ways: at 0
    // against the unchanged netlist goldens - which is what still guards the
    // sys_clk retime - and at the shipped value against its own goldens.
    //
    // ⚠️ This is a DELIBERATE, DOCUMENTED DEVIATION from the vendored netlist,
    // taken because the netlist has been shown to reproduce OUR numbers rather
    // than silicon's (26.46/20.51 cyc against the real 31.7/21.4, with no SDRAM
    // in the loop). For this path the hardware tones are the authority. Do not
    // "fix" it back by regenerating a golden from a netlist run.
    parameter int GRANT_SETUP = 2
) (
    input  logic        clk,        // 96.65 MHz sys_clk
    input  logic        en_pos,     // ÷16 strobe, "posedge CLKIN" phase
    input  logic        en_neg,     // ÷16 strobe, "negedge CLKIN" phase (+8 sys_clk)
    input  logic        mem_ready,  // RPLY done-gate (1 = no-op / bit-identical)
    input  logic        ext_ram,    // BK-0011M window-1 banked RAM (a15 force);
                                    // 0 = bit-identical to the pre-Phase-7 decode

    input  logic        PIN_R,      // reset, active high
    input  logic        PIN_C,      // test clock select

    inout  wire  [15:0] PIN_nAD,    // address/data, inverted
    input  logic        PIN_nSYNC,
    input  logic        PIN_nDIN,
    input  logic        PIN_nDOUT,
    input  logic        PIN_nWTBT,
    output logic        PIN_nRPLY,

    output logic [6:0]  PIN_A,       // DRAM mux address (retained for equivalence)
    output logic [1:0]  PIN_nCAS,
    output logic        PIN_nRAS,
    output logic        PIN_nWE,

    output logic        PIN_nE,
    output logic        PIN_nBS,
    output logic        PIN_WTI,
    output logic        PIN_WTD,
    output logic        PIN_nVSYNC,

    // ---- taps for the Phase-3 SDRAM-request translation --------------------
    output logic        cpu_grant,   // RASEL rising for a CPU access (issue point)
    output logic [13:1] video_va,    // video fetch word address (VA counter)

    // ---- taps for the Phase-4 video pipeline (output-only, oracle-safe) ----
    output logic        vid_fetch,   // one sys_clk pulse per video word slot
    output logic        vid_pal_stb, // same slot, at the shift-register load
                                     // instant (fetch + 3 CLKIN) - when the
                                     // word actually reaches the screen
    output logic        vid_line_en, // beam row is displayed (WTI line-mask term)
    output logic        hgate,       // horizontal blanking gate
    output logic        vgate        // vertical blanking gate
);

   // -----------------------------------------------------------------------
   // State (names mirror va_037.v)
   // -----------------------------------------------------------------------
   logic        nWTBT;        // BYTE flag (WTBT at DOUT time)
   logic [15:0] A;            // Q-bus address latch
   logic [7:0]  RA;           // 177664 register: video base
   logic        M256;         // 1/4 screen mode

   logic        RWR, ROE;     // 177664 strobes
   wire         RESET = PIN_R;

   logic [2:0]  PC;           // pixel counter
   logic [13:1] VA;           // video address counter
   logic [7:0]  LC;           // line counter

   logic        ALOAD, TV51;
   logic        HGATE, VGATE;
   logic        PC90;
   logic        RASEL, AMUXSEL;
   logic        CAS;
   logic        CAS322;
   logic        FREEZ;

   logic        VTSYN;
   logic        SYNC2, SYNC5;

   logic        RPLY;
   logic        TRPLY;

   // -----------------------------------------------------------------------
   // Combinational bus / decode (identical to reference)
   // -----------------------------------------------------------------------
   // A15 as the 037 decodes RAM ownership. The reference gates on the raw
   // latched A[15] (owns 000000-077777 only) - a BK-0010 simplification. On a
   // real BK-0011M the 037 fronts ALL internal RAM: the banking network drives
   // its AD15 pin so its internal A15 = A15_true & ~(window-1-is-RAM). ext_ram
   // (from qbus_mem's mapper) reproduces that force, so a window-1 banked-RAM
   // access is arbitrated + RPLYed exactly like the low 32K. ext_ram is 0 in
   // BK-0010 mode (and for any A15=0 access), so a15_037 == A[15] there and the
   // core stays bit-identical to the reference (all ref037 goldens invariant).
   wire a15_037 = A[15] & ~ext_ram;

   // ---- the grant request, as the 037 latches it (see GRANT_SETUP) ---------
   // RPLY is deliberately NOT delayed with the rest: it is the handshake
   // interlock ("the previous access has not been taken yet"), not part of the
   // request, and delaying it would model something else entirely.
   wire        grant_raw = ~(PIN_nSYNC | a15_037 | (PIN_nDIN & PIN_nDOUT));
   logic [2:0] grant_sr;
   always_ff @(posedge clk)
      if (RESET)                grant_sr <= 3'b000;
      else if (en_pos | en_neg) grant_sr <= {grant_sr[1:0], grant_raw};
   // spelled out rather than indexed by the parameter - Quartus 11.0 is
   // happier with it and GRANT_SETUP == 0 must fold away completely
   wire grant_req = (GRANT_SETUP == 0) ? grant_raw   :
                    (GRANT_SETUP == 1) ? grant_sr[0] :
                    (GRANT_SETUP == 2) ? grant_sr[1] : grant_sr[2];

   // RPLY to the CPU is the reference term AND the done-gate (mem_ready).
   assign PIN_nRPLY      = ~(ROE | RWR | (RPLY & mem_ready));

   assign PIN_nAD[7:0]   = ~ROE ? 8'hZZ : ~RA[7:0];
   assign PIN_nAD[8]     = 1'bZ;
   assign PIN_nAD[9]     = ~ROE ? 1'bZ  : ~M256;
   assign PIN_nAD[14:10] = 5'hZZ;
   assign PIN_nAD[15]    = (~PIN_nDIN & ~PIN_nSYNC &
                           (A[15:1] == (16'o177716 >> 1))) ? 1'b0 : 1'bZ;

   assign PIN_nE  = PIN_nSYNC | PIN_nDIN | (A[15:7] == (16'o177600 >> 7));
   assign PIN_nBS = ~(A[15:2] == (16'o177660 >> 2));

   assign RWR     = ~PIN_nSYNC & ~PIN_nDOUT & (A[15:1] == (16'o177664 >> 1));
   assign ROE     = ~PIN_nSYNC & ~PIN_nDIN  & (A[15:1] == (16'o177664 >> 1));

   assign RPLY    = TRPLY & ~RASEL;

   assign TV51    = PIN_C ? 1'b0 : ~(&PC[2:0] & &VA[5:1]);
   assign ALOAD   = (FREEZ & ~LC[1]) | (RESET & RWR);
   assign FREEZ   = VGATE & (LC[5:2] == 4'b1010);

   // DRAM address mux + controls (retained for equivalence)
   assign PIN_A[6:0]  = RASEL ? (AMUXSEL ? ~A[7:1]  : ~A[14:8])
                              : (AMUXSEL ? ~VA[7:1] : {1'b0, ~VA[13:8]});
   assign PIN_nCAS[0] = ~(CAS & (~A[0] | ~PC[2] | nWTBT));
   assign PIN_nCAS[1] = ~(CAS & ( A[0] | ~PC[2] | nWTBT));
   assign PIN_nRAS    =  PC90 | (PC[2] & ~RASEL);
   assign PIN_nWE     = ~(RASEL & ~PIN_nDOUT);

   assign PIN_WTI = ~VGATE & ~HGATE & (M256 | (LC[6] & LC[7])) & PC90 & ~PC[2] & PC[1];
   assign PIN_WTD = RPLY & ~PIN_nDIN;

   assign CAS = (CAS322 & PC[1] & PC[2]) | (~VGATE & ~HGATE & PC[1] & ~PC[2]);

   assign SYNC2      = ~(VGATE & (LC[5:2] == 4'b1010) & ~(LC[0] & LC[1]));
   assign SYNC5      =  VTSYN | (SYNC2 & ~HGATE);
   assign PIN_nVSYNC = ~(SYNC2 ^ SYNC5);

   // Phase-3 taps
   logic RASEL_d;
   always_ff @(posedge clk) RASEL_d <= RASEL;
   assign cpu_grant = RASEL & ~RASEL_d & ~PIN_nSYNC & ~a15_037;  // CPU-access grant edge
   assign video_va  = VA[13:1];

   // Phase-4 taps: pure reads of existing state, no logic change.
   // vid_fetch pulses at PC==1 (VA[4:1] increments at PC==7, video CAS window is
   // PC==2..3), so VA is stable and the fetch is issued one CLKIN before the
   // 037 CASes the word itself.
   assign vid_fetch   = en_neg & ~HGATE & ~VGATE & (PC == 3'd1);
   assign vid_line_en = M256 | (LC[6] & LC[7]);   // same line term as PIN_WTI
   assign hgate       = HGATE;
   assign vgate       = VGATE;

   // Phase-9 tap: the instant the fetched word reaches the SCREEN, which is
   // where the palette must be sampled - not the fetch. On the real board the
   // video data path is DRAM -> К155ИР13 shift registers (D24/D25) -> КР556РТ4А
   // palette PROM -> CRT, with NO latch in between: the ИР13s take their
   // parallel data straight off the DRAM data pins (schematic nets S5-1..16)
   // and their mode pin S0 is PIN_WTI, so the word is loaded during the WTI
   // window and shifted out from there. Measured on this core and on the
   // reference netlist (one slot = 8 CLKIN): vid_fetch at +0, video CAS and WTI
   // rise at +1, WTI fall at +3. The load edge that counts is the LAST one
   // inside WTI - the DRAM data is only valid late in its CAS window, and any
   // earlier edge reloads the same word - so the word starts displaying at +3.
   // (Residual uncertainty is the +1..+3 span, i.e. <= 2 CLKIN = 4 dots, which
   // needs the D8/D10 dot-clock phase to pin down further.)
   // Delayed UNCONDITIONALLY, deliberately: re-qualifying on ~HGATE would drop
   // the last slot of every line, whose +3 lands after the gate edge.
   logic [2:0] palstb_sr;
   always_ff @(posedge clk)
      if (RESET)       palstb_sr <= 3'b000;
      else if (en_neg) palstb_sr <= {palstb_sr[1:0], vid_fetch};
   assign vid_pal_stb = palstb_sr[2] & en_neg;

   // -----------------------------------------------------------------------
   // Clocked-transparent latches (updated every sys_clk, gated by condition)
   // -----------------------------------------------------------------------
   always_ff @(posedge clk) if (PIN_nDOUT) nWTBT <= PIN_nWTBT;    // BYTE flag latch
   always_ff @(posedge clk) if (PIN_nSYNC) A     <= ~PIN_nAD;     // address latch
   // RA/M256 (177664) have no reset in the reference (loaded by the 177664 write);
   // give them a synchronous reset here so the core is deterministic at power-up
   // without an external init. RA=0 is only the video base (does not affect the RAM
   // RPLY/grant timing), so this stays bit-exact with the reference (validated).
   always_ff @(posedge clk)
      if (RESET)    RA   <= 8'h00;
      else if (RWR) RA   <= ~PIN_nAD[7:0];
   always_ff @(posedge clk)
      if (RESET)    M256 <= 1'b0;
      else if (RWR) M256 <= ~PIN_nAD[9];

   // TRPLY set/clear latch (reference: set on RASEL, clear when both strobes idle)
   always_ff @(posedge clk)
      if (RASEL)                        TRPLY <= 1'b1;
      else if (PIN_nDIN & PIN_nDOUT)    TRPLY <= 1'b0;

   // -----------------------------------------------------------------------
   // negedge-CLKIN blocks  ->  en_neg
   // -----------------------------------------------------------------------
   always_ff @(posedge clk) if (en_neg) if (~PC[0]) PC90 <= PC[1];

   always_ff @(posedge clk)
      if (RESET)         PC <= 3'b000;
      else if (en_neg)   PC <= PC + 3'b001;

   always_ff @(posedge clk)
      if (RESET)         VA[5:1] <= 5'b00000;
      else if (en_neg)
         if (&PC[2:0]) begin
            VA[4:1] <= VA[4:1] + 4'b0001;
            if (&VA[4:1] & ~HGATE) VA[5] <= ~VA[5];
         end

   always_ff @(posedge clk)
      if (en_neg) begin
         if (ALOAD)                    VA[13:6] <= RA[7:0];
         else if (~TV51 & ~FREEZ)      VA[13:6] <= VA[13:6] + 8'b00000001;
      end

   always_ff @(posedge clk)
      if (RESET) begin
         HGATE <= 1'b0;
         VGATE <= 1'b1;
      end else if (en_neg) begin
         if (&PC[2:0] & &VA[4:1] & (HGATE | VA[5]))
            HGATE <= ~HGATE;
         if (~TV51 & (LC[5:0] == 6'b000000) & (VGATE | (LC[7:6] == 2'b00)))
            VGATE <= ~VGATE;
      end

   always_ff @(posedge clk)
      if (RESET)         LC <= 8'b11111111;
      else if (en_neg)
         if (~TV51) begin
            LC[5:0] <= LC[5:0] - 6'b000001;
            if ((LC[5:0] == 6'b000000) & ~VGATE) LC[6] <= ~LC[6];
            if ( LC[6:0] == 7'b0000000)          LC[7] <= ~LC[7];
         end

   always_ff @(posedge clk) if (en_neg) CAS322 <= RASEL;

   always_ff @(posedge clk)
      if (RESET)         VTSYN <= 1'b0;
      else if (en_neg) begin
         if ((VA[3:1] == 3'b000) & (PC[1:0] == 2'b11)) VTSYN <= 1'b1;
         if ((VA[4:1] == 4'b0100) & (PC[2:0] == 3'b111)) VTSYN <= 1'b0;
      end

   // -----------------------------------------------------------------------
   // posedge-CLKIN blocks  ->  en_pos
   // -----------------------------------------------------------------------
   always_ff @(posedge clk) if (en_pos) AMUXSEL <= PC90;

   always_ff @(posedge clk)
      if (en_pos) begin
         if (PC90 & PC[1])
            RASEL <= 1'b0;
         else if (PC90 & ~PC[1] & PC[2])
            RASEL <= grant_req & ~RPLY;
      end

endmodule
