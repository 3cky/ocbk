// qbus_mem - the memory subsystem: the ROM/IO reply FSM plus the CPU RAM
// datapath into the board SDRAM.
//
// The 037 (va_037_sync) owns RAM RPLY and its cycle-stealing timing; this block
// provides:
//   * ROM 100000-177577 + I/O decode, with the fixed N_ROM reply (the 037
//     never sees these - they are outside its DRAM), driving rply_n itself; and
//   * the RAM 000000-077777 DATA path into the board SDRAM through sdram_arbiter +
//     cpu_sdram_dp, producing mem_ready for the 037's RPLY done-gate.
// RAM RPLY is NOT driven here (va_037_sync drives it, gated by mem_ready) -
// except in turbo mode, where the 037 stops arbitrating and this FSM takes the
// RAM reply over at the fixed N_TURBO count (sel_turbo).
//
// ROM source: ROM reads are served from SDRAM through the same
// cpu_sdram_dp port-0 path as RAM (linear map: ROM word at SDRAM word
// addr[15:1] = 0x4000-0x7F7F). The reply keeps the fixed N_ROM count but is
// done-gated on mem_ready - a late SDRAM word EXTENDS RPLY (mirroring the 037's
// RAM gate) instead of latching stale data. ROM is not 037-arbitrated (real BK
// mask ROM is not cycle-stolen). ROM WRITES get NO reply: a write is not
// `selected` below, so the FSM never replies and the CPU's qbto timer traps
// through vector 4 - authentic mask/overlay ROM, and the "write until trap 4"
// fast-screen-clear idiom depends on it (oracle: sim/romwr). There is no
// on-chip ROM fallback: a failed EPCS boot holds the CPU in reset (see
// ocbk_top), so ROM is always the loaded SDRAM image.
//
// The I/O decode here comes from the CPU's own nSEL1/nSEL2 register-select
// pins (as on the real BK board): only the two registers the 1801ВМ1 delegates
// externally - 177716 (system, nSEL1) and 177714 (parallel port, nSEL2) - are
// served; EVERYTHING else is left undecoded and bus-times-out (qbto -> trap 4),
// which is authentic BkEmu behaviour. This needs no carve-outs: the 037 scroll
// (177664), the keyboard block (177660-663) and the CPU-internal block
// (177700-717, which the 1801ВМ1 decodes/replies/data-drives itself) never
// assert a SEL pin, so there is never a double reply or an AD fight. I/O
// served here:
//   177716 = SYS_START | bit-2 write-flag (set on write, cleared after read;
//            INIT-keyed, as every BK peripheral register) | bit-6 = any-key-
//            down from the keyboard translator, ACTIVE LOW (1 = no key held);
//   177714 = reply, read 0; writes are CAPTURED (see the port_wr seam below)
//            and consumed by the sound devices - bk_turbosound and bk_covox -
//            which are ocbk_top siblings, not part of this module. The read
//            side is still unmodelled: both devices are write-only.
// nSEL covers BOTH bytes of its register (the CPU decodes addr[3:1]), so odd-
// byte accesses (177715/177717) are served with the full register word too.
// Exception: in BK-0011M mode a WRITE to 177662 (video page/palette
// register, MiSTer video.sv reference) gets a positive decode + fixed-N_VREG
// reply here; reads there stay with the 014 keyboard chip in both models.
//
// Domains: the ROM/IO wait-state FSM runs on cpu_clk (fixed N_ROM); the
// datapath/arbiter/controller run on sclk (sys_clk). Bus strobes are
// synchronous to sclk - cpu_clk is a divider of it (/32, /24 or /16 by model
// and turbo), same tree and deterministic phase - so cpu_sdram_dp samples them
// directly. The video clients (readout / 037 fetch / FB write, all sclk
// domain) pass through to arbiter ports 1/2/3 via the v1_*/v2_*/v3_* ports.
module qbus_mem #(
    parameter int     CLK_FREQ_HZ = 96_650_000,
    parameter int     ROW_BITS    = 13,
    parameter int     COL_BITS    = 9,
    parameter int     BA_BITS     = 2,
    parameter int     DQ_BITS     = 16,
    parameter int     CAS_LATENCY = 2,
    parameter int     ADDR_BITS   = BA_BITS + ROW_BITS + COL_BITS
) (
    // ---- slow domain (CPU clock) ----------------------------------------
    input  logic        cpu_clk,    // ROM/IO wait FSM clock (= pin_clk_n)
    input  logic        reset,      // active high (= ~dclo_n)
    input  logic        init_n,     // Q-bus nINIT: peripheral-register reset
    input  logic        kbd_down,   // any-key-held level -> 177716 bit 6 (inverted)
    input  logic        tape_in,    // CMT comparator level -> 177716 bit 5
    input  logic        sel1_n,     // CPU nSEL1: 177716/17 register select
    input  logic        sel2_n,     // CPU nSEL2: 177714/15 register select
    input  logic        model_bk11, // DIP-1 model select, latched during DCLO
                                    // hold (quasi-static): 1 = BK-0011M banking
    input  logic        smk_en,     // DIP-8 SMK512 enable, latched during DCLO
                                    // hold (quasi-static); BOTH models (the SMK
                                    // is an МПИ expansion board - see mem_mapper)
    input  logic        turbo,      // PS/2 F12 turbo mode (quasi-static, applied
                                    // by ocbk_top only on a bus-idle edge): the
                                    // 037 has stopped owning RAM (its no_steal),
                                    // so this FSM replies for MK_RAM037 too, at
                                    // the fixed N_TURBO count. See qbus_pkg.

    // ---- SMK512 IDE read data ---------------------------------------------
    // smk_ide's registered TRUE-bus-value word: ~packed register data inside
    // its 0177740-0177757 decode, 0 outside it. OR-ed into the reply-point
    // merge latch below (gated on sel_ide, so a tie-to-0 in non-SMK tbs is
    // behaviour-identical). The device itself never drives ad_n/rply_n.
    input  logic [15:0] ide_rdata,

    // ---- SDRAM domain ---------------------------------------------------
    input  logic        sclk,       // sys_clk (96.65 MHz)
    input  logic        srst_n,     // SDRAM-domain reset (PLL locked), active low
    output logic        init_done,

    // ---- Q-bus (inverted, active low) -----------------------------------
    inout  wire  [15:0] ad_n,
    input  logic        sync_n,
    input  logic        din_n,
    input  logic        dout_n,
    input  logic        wtbt_n,
    output wire         rply_n,     // open-collector; ROM/IO only (RAM = va_037_sync)
    output logic        mem_ready,  // RAM SDRAM access complete -> 037 done-gate
    output wire         ext_ram,    // this cycle is BK-0011M window-1 banked RAM
                                    // (A15=1 RAM037) -> va_037_sync forces A15 low
                                    // so the 037 fronts it (a15_037); 0 in bk10

    // ---- boot-writer mux onto arbiter port 0 (sclk domain) ----------------
    // While boot_active the EPCS loader owns port 0 (the CPU is still in DCLO,
    // so cpu_sdram_dp is guaranteed idle) - the external mux reserved in
    // sdram_arbiter.sv; the arbiter itself is unchanged.
    input  logic                 boot_active,
    input  logic                 bw_req,
    input  logic [ADDR_BITS-1:0] bw_addr,
    input  logic [DQ_BITS-1:0]   bw_wdata,
    output logic                 bw_gnt,

    // ---- video clients (sclk domain; arbiter ports 1/2/3) ----------------
    input  logic                 v1_req,     // [1] panel readout (read-only)
    input  logic [ADDR_BITS-1:0] v1_addr,
    output logic                 v1_gnt,
    output logic                 v1_rvalid,
    input  logic                 v2_req,     // [2] 037 video fetch (read-only)
    input  logic [ADDR_BITS-1:0] v2_addr,
    output logic                 v2_gnt,
    output logic                 v2_rvalid,
    input  logic                 v3_req,     // [3] FB word write
    input  logic [ADDR_BITS-1:0] v3_addr,
    input  logic [DQ_BITS-1:0]   v3_wdata,
    output logic                 v3_gnt,
    output logic [DQ_BITS-1:0]   v_rdata,    // shared arbiter read data

    // ---- SDRAM device pins ----------------------------------------------
    output logic                s_cke,
    output logic                s_cs_n,
    output logic                s_ras_n,
    output logic                s_cas_n,
    output logic                s_we_n,
    output logic [BA_BITS-1:0]  s_ba,
    output logic [ROW_BITS-1:0] s_addr,
    output logic [1:0]          s_dqm,
    inout  wire  [DQ_BITS-1:0]  s_dq,

    // ---- bus-activity taps ----------------------------------------------
    output wire  [15:0] bus_addr,
    output logic        fetch_stb,

    // ---- BK speaker: bit 6 of the last 177716 write (software-owned) ------
    output logic        spk_bit,
    // ---- tape motor: bit 7 of the last 177716 write (1 = motor STOPPED) ---
    output logic        mot_bit,

    // ---- 177714 (nSEL2) parallel-port write capture (sclk domain) ---------
    // The seam the BK sound expansions hang off: Covox, 2x YM2149 and
    // Menestrel all decode this one address and differ only in how they read
    // the data. src/audio/bk_turbosound.sv is the first consumer. Never
    // runtime-reset (see the capture block below).
    output logic        port_wr,       // 1 sclk per bus write to 177714/15
    output logic [15:0] port_data,     // BK-true value, byte lanes merged
    output logic        port_word,     // 1 = word write, 0 = byte write
    output logic [1:0]  port_be,       // which byte lane(s) this write carried

    // ---- BK-0011M 177662 video register taps (sclk domain) ----------------
    output logic        vid_page,      // bit 15: displayed screen (0 = RAM page 1, 1 = page 7)
    output logic        vid_irq2_mask, // bit 14: frame-IRQ2 mask (1 = masked)
    output logic [3:0]  vid_pal,       // bits 11:8: palette index

    // ---- BK-0011M СТОП-enable: 177716 write bit 12 (1 = blocked) ----------
    output logic        stop_block
);

    import qbus_pkg::*;

    // ---- address latch (transparent on SYNC; slow logic clock, SDC-cut) --
    logic [15:0] addr;
    always_ff @(negedge sync_n) addr <= ~ad_n;
    assign bus_addr = addr;

    // ---- memory mapper: (addr, map registers) -> (kind, phys) --------------
    // In BK-0010 mode the translate is bit-identical to the old inline decode
    // (RAM/ROM at phys = addr[15:1]); in BK-0011M mode it implements the
    // Bk11MemoryManager banking (see mem_mapper.sv). bank_wr flags a 177716
    // word write with bit 11 set - the banking/peripheral mutual exclusion.
    logic [1:0]           mkind;
    logic [ADDR_BITS-1:0] mphys;
    logic                 bank_wr;
    logic                 m_smk_ro, m_smk_wo;
    // smk_en re-registered locally - the model_bk11_q treatment, same reasons
    // (see the CLAUDE.md "a quasi-static signal with big fanout still costs
    // real setup time" gotcha). DIP 8 is latched in ocbk_top during the DCLO
    // hold and fans out across the mapper translate, the fdd/ide decodes and
    // the top-level muxes, so the fitter routes it far; that route landing in
    // the mapper's translate put smk_en -> cpu_sdram_dp|addr_o/wdata_o at
    // -0.171..-0.314 ns across builds. This flop is the ONLY consumer of the
    // raw port inside qbus_mem, so the long route now ends at one flop and
    // everything downstream is fed from a register the fitter places nearby.
    // The 1-cycle latency cannot matter: smk_en only changes during a DCLO
    // hold, CPU parked, mapper in reset, thousands of sclk before release.
    // Registered HERE and NOT inside mem_mapper on purpose: run_mapper.sh
    // flips smk_en and compares the decode COMBINATIONALLY (#1, no clock
    // edge) against its reference instance, and it drives the mapper's port
    // directly - so the mapper keeps its combinational contract untouched.
    logic smk_en_q;
    always_ff @(posedge sclk or posedge reset)
        if (reset) smk_en_q <= 1'b0;
        else       smk_en_q <= smk_en;

    // turbo gets the same treatment for the same reason: it is quasi-static
    // (ocbk_top only moves it on a bus-idle sclk edge) but fans out across the
    // clock divider, the 037 and this module, so the fitter routes it far - and
    // here it lands in the `selected` / wcnt / done-gate cones, all of which
    // feed the reply. Registering it locally turns that route into a plain
    // flop-to-flop path. The reset arm is only for X-freedom at power-up: turbo
    // itself SURVIVES a warm reset (it is a user setting, like screen_mode),
    // and this flop re-follows it one sclk after the release - thousands of
    // sclk before the CPU leaves DCLO, so the transient is unobservable.
    logic turbo_q;
    always_ff @(posedge sclk or posedge reset)
        if (reset) turbo_q <= 1'b0;
        else       turbo_q <= turbo;

    mem_mapper #(.ADDR_BITS(ADDR_BITS)) u_map (
        .sclk(sclk), .rst(reset), .model_bk11(model_bk11), .smk_en(smk_en_q),
        .sync_n(sync_n), .dout_n(dout_n), .wtbt_n(wtbt_n), .sel1_n(sel1_n),
        .ad_true(~ad_n), .addr0(addr[0]), .bank_wr(bank_wr),
        .addr(addr), .kind(mkind), .phys(mphys), .smk_ro(m_smk_ro),
        .smk_wo(m_smk_wo)
    );

    wire sel_ram = !sync_n && (mkind == MK_RAM037);
    wire sel_rom = !sync_n && (mkind == MK_ROM);
    // BK-0011M window-1 banked RAM is a normal MK_RAM037 access (037-owned RPLY,
    // done-gated on mem_ready, riding the cpu_sdram_dp port-0 path exactly like
    // the low 32K - the real 037 fronts all internal RAM). The only A15=1
    // MK_RAM037 access is window 1 (page6/win0 are A15=0; top ROM is MK_ROM;
    // bk10 RAM037 is always A15=0), so this flags it for va_037_sync's a15_037
    // force. 0 in BK-0010 mode -> a15_037 == A[15], goldens invariant.
    assign ext_ram = sel_ram && addr[15];
    // SMK512 external RAM (MK_EXT): FSM-owned fixed N_EXT reply, read
    // AND write - an external controller's RAM is NOT 037-fronted/cycle-stolen.
    // Deliberately NOT in ext_ram: a15_037 stays high, so the 037 treats the
    // access like ROM/IO and never grants or replies (the FSM is uncontested).
    // m_smk_ro (HLT10 seg 0 / the ALL-mode seg-7 extent) withholds the write
    // reply -> qbto -> trap 4; m_smk_wo (the HLT-mode write-only extent)
    // withholds the READ reply the same way.
    wire sel_ext = !sync_n && (mkind == MK_EXT);

    // ---- the SMK I/O-page overlay policy ------------------------------------
    // In SYS mode the rom7 BIOS window / in the extent modes the seg-7 SMK RAM
    // reach INTO the I/O page 177600-177777 (the mapper translates uniformly;
    // BkEmu covers the whole segment). The real bus wire-ORs the SMK's data
    // with whatever register also replies (BkEmu Computer.readMemory ORs
    // memory and device reads) - the FSM below reproduces that by latching
    // io_word | ram_rdata and driving the merged word itself (u_dp fetches
    // via rd_noe but never drives - single on-chip driver, no pad fight).
    // TWO CARVE-OUTS (documented deviations from the uniform overlay):
    //  * 177700-177717 (cpu_blk): the vm1 decodes this block itself
    //    (sel177x), self-replies AND drives read data for 177700-177712 -
    //    an external reply/drive is a guaranteed ad_n fight (see the
    //    177700-13 note in the I/O decode above). Never replied or
    //    driven; the boot-critical
    //    177716/177714 reads are NOT affected - they ride the existing
    //    sel_io (nSEL) reply whose data simply gains the merge term.
    //    Extent WRITES here are posted to SMK RAM silently (u_dp write leg,
    //    bus-passive - the vm1 self-replies; BkEmu broadcast-write).
    //  * 177660-177667 READS (kbd_blk): bk_kbd014 (177660-663) and the 037
    //    (177664 scroll) reply and push-pull-drive their own read data - a
    //    second driver is a pad fight, and this FSM never sees their data to
    //    merge it (the smk64 replica carves the same read hole). Extent
    //    writes ARE claimed (no data fight; the OC RPLY double-assert with
    //    the kbd's own 177660 write reply is benign wire-AND).
    wire ovl_zone  = (addr >= IO_BASE);
    wire cpu_blk   = (addr[15:4] == 12'hFFC);         // 177700-177717
    wire kbd_blk   = (addr[15:3] == 13'h1FF6);        // 177660-177667
    wire ovl_rd_ok = !ovl_zone || (!cpu_blk && !kbd_blk);
    wire ovl_wr_ok = !ovl_zone || !cpu_blk;
    // ---- I/O decode: the CPU's own nSEL1/nSEL2 register-select pins --------
    // The only I/O the CPU delegates to us is its nSEL pair: nSEL1 = 177716/17
    // (system register), nSEL2 = 177714/15 (programmable parallel port -
    // Covox/joystick/AY). The 1801ВМ1 decodes them itself during the address
    // phase (sel_16/sel_14 register on clk_p while SYNC is idle, so they are
    // stable strictly before our negedge-SYNC addr latch and frozen for the
    // whole SYNC window) and withholds its own AD drive for exactly these
    // reads (ad_oe), leaving the read data to us - the same wiring as the
    // real BK board, where nSEL1 gates the discrete 177716 logic. Gating with
    // !sync_n below makes the timing identical to the old SYNC-latched
    // address compare (goldens unchanged). The vendored vm1.v drives the pins
    // push-pull via a marked local hook (a lone Z-idle OC driver feeding
    // on-chip logic degenerates to stuck-asserted on Cyclone I - the virq_n
    // trap); keep that hook on upstream re-syncs.
    //   nSEL1 (177716, either byte): io_word = SYS_START | write-flag | kbd
    //                                          | tape-in (bit 5).
    //   nSEL2 (177714, either byte): reply, read 0, writes ignored.
    // Everything ELSE is UNDECODED: no reply -> the CPU's qbto timer expires
    // (56..63 clocks) -> trap 4. That is authentic BkEmu behaviour (it times
    // out on ALL undecoded addresses, not just the system page) and subsumes
    // every old carve-out for free: 177664 (037), 177660-663 (keyboard) and the
    // whole 177700-717 CPU-internal block never assert a SEL pin, so we
    // never fight them; and the СТОП path (nothing decodes 177674/76 -> the
    // IRQ1/HALT-entry PC/PSW write there times out -> trap 4 with the BASIC ROM)
    // is now just a consequence of not decoding it, not a special exclusion. The
    // previous exclude-list "reply 0 to the whole page minus holes" was
    // inauthentic - it handed MONITOR phantom device responses on its presence
    // probes. SMK512 note: its registers (177130/177132, AY, ...) live
    // OUTSIDE this page, INSIDE the ROM window - they get their own positive
    // decode carved out of sel_rom there, not here (no SEL pin involved).
    wire sel_io  = !sync_n && (!sel1_n || !sel2_n);

    // ---- 177662: BK-0011M video page/palette register ---------------------
    // The ONE positive decode besides the nSEL pair: on a BK-0011M a WRITE to
    // 177662/3 must be replied to (the wait FSM below serves it, fixed N_VREG)
    // and captured (the sclk block next to spk_bit). Write-only: reads stay
    // with the 014 keyboard data register, so this select never starts the
    // FSM for DIN. In BK-0010 mode the decode is dead and a 662 write keeps
    // bus-timing-out -> trap 4, exactly as before (bk10 goldens unchanged).
    wire sel_vreg = model_bk11 && !sync_n
                    && (addr[15:1] == 15'(16'o177662 >> 1));

    // ---- 177130/177132: the SMK's КНГМД (FDD controller) register block ----
    // (the layout register 177130 is the FDD control register the
    // SMK "ab-uses" - mem_mapper snoops its writes independently of this
    // decode.) The SMK board carries a REAL floppy controller, so BOTH
    // registers reply BOTH directions REGARDLESS of the memory layout -
    // BkEmu's SMK configuration always attaches FloppyController, and its
    // no-selected-drive/no-disk control read returns 0 (FloppyController.
    // readControlRegister). This stub reproduces exactly that: reads reply
    // with a 0 contribution (under SYS the rom7 BIOS word still merges in -
    // BkEmu ORs memory and device reads; in the HLT modes the write-only
    // extent still posts writes to SMK RAM through u_dp), writes reply and
    // are otherwise ignored (177130's are layout-snooped by the mapper).
    // WITHOUT this reply the real BIOS's FDD boot attempt (after a failed
    // HDD boot) trapped through vector 4 on its status polls and crash-
    // restarted the machine - found on hardware 2026-07-18; a real SMK
    // never bus-errors there. The increment-2 "reads trap 4 outside SYS"
    // behaviour was OUR simplification, not BkEmu's. Fixed reply count =
    // N_SMKREG (placeholder family). A HLT-mode commit write still posts
    // to SMK RAM on the PRE-commit translate (BkEmu's memory-then-device
    // write order), so a mode write can never re-map its own in-flight
    // cycle. With the SMK absent the decode is dead and 177130 stays plain
    // ROM: reads return the MSTD word, writes trap (sim/romwr).
    // Model-independent - gated on smk_en alone (the SMK is an МПИ expansion
    // board; BkEmu attaches FloppyController in BOTH SMK configs).
    wire sel_fdd = smk_en_q && !sync_n
                   && (addr[15:2] == 14'(16'o177130 >> 2));

    // ---- 177740-177757: SMK512 IDE task file ------------------------------
    // The smk_ide sibling module owns the registers (it snoops the bus
    // itself); THIS decode owns the RPLY, both directions, and merges the
    // device's read word at the reply point - reproducing BkEmu
    // Computer.readMemory/writeMemory, where the device read ORs with
    // whatever the memory layout returns (under SYS that is rom7 BIOS
    // bytes - the BIOS probes from a mode where the range is MK_NONE) and
    // a write is broadcast to device AND memory (the HLT-mode extent write
    // still posts to SMK RAM through u_dp; this decode just adds the
    // reply). The block sits outside cpu_blk/kbd_blk, so the carve-outs
    // are not involved. Reply = fixed N_IDE (N_ROM family per the I/O-page
    // rule; placeholder - see qbus_pkg).
    // Model-independent like sel_fdd above (BkEmu attaches SmkIdeController
    // in BK_0010_SMK512 and BK_0011M_SMK512 alike).
    wire sel_ide = smk_en_q && !sync_n
                   && (addr[15:4] == 12'hFFE);

    // ROM reads are always served from SDRAM through cpu_sdram_dp (port 0).
    wire sel_romx = sel_rom;

    // ---- ROM / I/O read data --------------------------------------------
    logic sel1_wflag;   // 177716 bit 2: set on write, cleared after read
    // BK speaker output = bit 6 of the value last written to 177716. A plain
    // software-owned latch: NOT cleared by nINIT / the RESET instruction
    // (matches BkEmu, which never re-inits the speaker level). Power-on value
    // only; software owns it thereafter. Captured directly in the DOUT window
    // on sys_clk below - the ROM/IO wait FSM can't see the write (see there).
    // mot_bit (bit 7, tape motor relay) has the identical contract.
    initial spk_bit = 1'b0;
    initial mot_bit = 1'b0;

    // 177714 parallel-port capture state. Same never-runtime-reset contract as
    // spk_bit/mot_bit above (a real Covox is a passive DAC on the port latch
    // with no reset pin) - power-on values only. port_seen is the
    // one-strobe-per-write qualifier; see the capture block below.
    logic port_seen;
    initial port_seen = 1'b0;
    initial port_wr   = 1'b0;
    initial port_word = 1'b0;
    initial port_be   = 2'b00;
    initial port_data = 16'o000000;

    // nSEL1 selects the register for BOTH its bytes, so a byte read of 177717
    // gets the full word too (the CPU extracts the byte; BkEmu semantics) -
    // and its driven-low bit 15 agrees with the 037's start-vector AD15 assist
    // instead of fighting it.
    wire [15:0] io_word  =
        !sel1_n ? ((model_bk11 ? SYS_START11 : SYS_START)
                             | (sel1_wflag ? 16'o000004 : 16'o0)
                             | (kbd_down   ? 16'o0 : 16'o000100)
                             | (tape_in    ? 16'o000040 : 16'o0)) :
        16'o000000;
    // ROM read data rides the SDRAM datapath (u_dp drives ad_n); this FSM only
    // latches/drives I/O read data.
    wire [15:0] rd_romio = io_word;

    // =====================================================================
    // RAM datapath: cpu_sdram_dp -> sdram_arbiter (port 0) -> sdram_ctrl
    // =====================================================================
    localparam int NREQ = 4;

    wire                dp_req, dp_we;
    wire [ADDR_BITS-1:0] dp_addr;
    wire [DQ_BITS-1:0]   dp_wdata;
    wire [1:0]           dp_be;
    wire                 dp_gnt, dp_rvalid;
    wire [DQ_BITS-1:0]   arb_rdata;
    wire [15:0]          ram_rdata;
    wire                 ram_rdata_oe;

    // MK_EXT rides this same datapath: read+write segments through the RAM
    // feed (byte lanes / DATIO already correct there), the read-only cases
    // (HLT10 seg 0 / ALL extent) through the ROM-read feed - their writes are
    // then structurally never issued to the SDRAM (cpu_sdram_dp's is_write
    // needs sel_ram/sel_ramw), matching BkEmu's not-written semantics - and
    // the HLT write-only extent through sel_ramw, the mirror leg whose reads
    // are structurally never fetched. rd_noe marks I/O-page overlay reads:
    // u_dp fetches the word but the wait FSM below drives the OR-merged data
    // (see the carve-out block above). Note the extent write posts even in
    // cpu_blk (bus-passive broadcast; only the REPLY is carved out there).
    // The MK_EXT mem-region read leg is the ONE access whose fixed
    // reply (N_EXT = 1, the calibrated SMK512 access time - see qbus_pkg) is
    // shorter than the SDRAM latency, so its read must start at SYNC instead of
    // at DIN or the done-gate would extend it. Scoped to exactly that leg:
    // MK_RAM037 and MK_ROM keep issuing at DIN, so no existing timing golden
    // can move. Constant-folds away when N_EXT >= 2.
    // NOTE (Icarus): a package parameter must NOT make its first appearance
    // inside a port-connection expression - Icarus then creates an implicit
    // NET of that name, which silently shadows the parameter (as X) for the
    // whole rest of the module. Hence this named wire rather than the
    // expression inline at .fast_rd() below.
    wire dp_fast_rd = (N_EXT == 1) & sel_ext & ~ovl_zone & ~m_smk_wo;

    cpu_sdram_dp #(.ADDR_BITS(ADDR_BITS), .DQ_BITS(DQ_BITS)) u_dp (
        .clk(sclk), .rst_n(~reset),
        .sync_n(sync_n), .din_n(din_n), .dout_n(dout_n), .wtbt_n(wtbt_n),
        .sel_ram(sel_ram | (sel_ext & ~m_smk_ro & ~m_smk_wo)),
        .sel_romr(sel_romx | (sel_ext & m_smk_ro)),
        .sel_ramw(sel_ext & m_smk_wo),
        .fast_rd(dp_fast_rd),
        .rd_noe((sel_romx | sel_ext) & ovl_zone),
        .addr(addr), .phys(mphys), .ad_true(~ad_n),
        .rdata(ram_rdata), .rdata_oe(ram_rdata_oe), .mem_ready(mem_ready),
        .req(dp_req), .we(dp_we), .addr_o(dp_addr), .wdata_o(dp_wdata), .be_o(dp_be),
        .gnt(dp_gnt), .rvalid(dp_rvalid), .rdata_i(arb_rdata)
    );

    // Boot-writer mux: during boot the EPCS loader is port 0 (word writes only).
    wire                 p0_req   = boot_active ? bw_req   : dp_req;
    wire                 p0_we    = boot_active ? 1'b1     : dp_we;
    wire [ADDR_BITS-1:0] p0_addr  = boot_active ? bw_addr  : dp_addr;
    wire [DQ_BITS-1:0]   p0_wdata = boot_active ? bw_wdata : dp_wdata;
    wire [1:0]           p0_be    = boot_active ? 2'b11    : dp_be;

    // Arbiter ports: [0] = CPU (highest); [1] readout, [2] 037 fetch, [3] FB write.
    wire [NREQ-1:0]           p_req    = {v3_req,  v2_req,  v1_req,  p0_req};
    wire [NREQ-1:0]           p_we     = {1'b1,    1'b0,    1'b0,    p0_we};
    wire [NREQ*ADDR_BITS-1:0] p_addr   = {v3_addr, v2_addr, v1_addr, p0_addr};
    wire [NREQ*DQ_BITS-1:0]   p_wdata  = {v3_wdata, {(2*DQ_BITS){1'b0}}, p0_wdata};
    wire [NREQ*2-1:0]         p_be     = { 6'b111111, p0_be };
    wire [NREQ-1:0]           p_gnt, p_rvalid;
    assign dp_gnt    = p_gnt[0] & ~boot_active;
    assign bw_gnt    = p_gnt[0] &  boot_active;
    assign dp_rvalid = p_rvalid[0];
    assign v1_gnt    = p_gnt[1];
    assign v1_rvalid = p_rvalid[1];
    assign v2_gnt    = p_gnt[2];
    assign v2_rvalid = p_rvalid[2];
    assign v3_gnt    = p_gnt[3];
    assign v_rdata   = arb_rdata;

    wire                 cmd_req, cmd_we, cmd_ready, rd_valid;
    wire [ADDR_BITS-1:0] cmd_addr;
    wire [DQ_BITS-1:0]   cmd_wdata, rd_data;
    wire [1:0]           cmd_be;

    sdram_arbiter #(.NREQ(NREQ), .ADDR_BITS(ADDR_BITS), .DQ_BITS(DQ_BITS)) u_arb (
        .clk(sclk), .rst_n(srst_n),
        .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_wdata(p_wdata), .p_be(p_be),
        .p_gnt(p_gnt), .p_rvalid(p_rvalid), .p_rdata(arb_rdata),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data)
    );

    wire [DQ_BITS-1:0] dq_out, dq_in;
    wire               dq_oe;
    assign s_dq  = dq_oe ? dq_out : {DQ_BITS{1'bz}};
    assign dq_in = s_dq;

    sdram_ctrl #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .BA_BITS(BA_BITS), .DQ_BITS(DQ_BITS), .CAS_LATENCY(CAS_LATENCY)
    ) u_ctrl (
        .clk(sclk), .rst_n(srst_n),
        .cmd_req(cmd_req), .cmd_we(cmd_we), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rd_valid(rd_valid), .rd_data(rd_data), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm),
        .dq_out(dq_out), .dq_oe(dq_oe), .dq_in(dq_in)
    );

    // =====================================================================
    // ROM / I/O wait-state FSM (cpu_clk domain; fixed N_ROM reply)
    // =====================================================================
    typedef enum logic [1:0] { S_IDLE, S_WAIT, S_REPLY } state_t;
    state_t state;

    logic [2:0]  wcnt;
    logic        drive_data, reply;
    logic [15:0] rdata;
    logic        dbg_romgate;   // diagnostic: an external-ROM read RPLY was extended
                                // past the fixed N_ROM count (sim observability only)
    logic        dbg_turbowait; // diagnostic: a TURBO RAM reply was extended by the
                                // done-gate. Expected and routine (N_TURBO is
                                // deliberately shorter than an SDRAM access) -
                                // observability only, never a failure condition.

    wire is_read  = !din_n;
    wire is_write = !dout_n;
    // ---- turbo: MK_RAM037 replied here instead of by the 037 ---------------
    // Mutually exclusive with every other select by construction (sel_ram is a
    // mem-region kind; sel_rom/sel_ext/sel_io/sel_ide/sel_fdd are other kinds
    // or the I/O page), so it is a plain OR term in `selected` and needs no
    // ranking. (Declared BEFORE its uses - Icarus requires it.)
    wire sel_turbo = turbo_q && sel_ram;

    // ALL the SDRAM-backed MEM-region legs while turbo is on: RAM (claimed
    // above), ROM, and SMK512 RAM (MK_EXT). They share the one property that
    // matters here - the reply point is a fixed count and the word comes from
    // the SDRAM, whose access is 12..22 sclk end to end against 16 sclk per CPU
    // cycle at 6.04 MHz. So in turbo they all take N_TURBO and they all EXPECT
    // the done-gate to hold them sometimes, which is why a hold here is
    // dbg_turbowait and not dbg_romgate.
    //
    // Treating them alike is not tidiness, it is required. Their authentic
    // counts were calibrated against a 3-4 MHz machine, and two of them cannot
    // survive the halved cycle: N_EXT = 1 relies on cpu_sdram_dp's early
    // SYNC-time fetch beating the reply point, and at /16 the head start is
    // gone - sim/smktime's turbo SMK-RAM leg trips the gate on the very first
    // fetch. N_ROM = 2 is the same arithmetic one cycle further out. Since
    // turbo is ahistorical anyway, the honest thing is one uniform count
    // instead of three fidelity constants used outside their calibration.
    //
    // The I/O page is excluded (ovl_zone): those reads keep the N_ROM count for
    // the 037 start-vector-assist reason spelled out at the wcnt load below,
    // and 177716 is boot-critical.
    wire turbo_mem = turbo_q && !ovl_zone && (sel_ram || sel_romx || sel_ext);

    // ROM contributes READS only: a write to ROM is not selected, so it gets no
    // RPLY -> the CPU's qbto timer expires (56..63 clocks) -> trap 4. This is
    // authentic mask/overlay-ROM behaviour (real ROMs never assert RPLY on a
    // write) and is what the "write until trap 4" fast screen-clear idiom relies
    // on. BkEmu agrees: a write to ReadOnlyMemory returns not-written, so the CPU
    // raises BUS_ERROR -> vector 4 (Cpu.java writeMemory/processPendingInterrupts).
    // sel_io still carries I/O reads AND writes (177714/177716 reply+ignore is
    // unchanged); the ROM read path, done-gate and sel_vreg write are untouched.
    // SMK RAM (sel_ext) contributes reads AND writes - EXCEPT a write
    // to a read-only case (m_smk_ro: HLT10 seg 0 / ALL extent) and a read of
    // the write-only extent (m_smk_wo), which fall out un-replied and trap by
    // the exact ROM-write mechanism (incl. the DATIO write half - see the
    // S_REPLY exit note). The ovl_* carve-outs (see their block) keep the
    // overlay/extent replies out of the vm1-internal and kbd-owned addresses.
    wire selected = (sel_rom & is_read & ovl_rd_ok) | sel_io
                  | (sel_ext & ((is_read  & ~m_smk_wo & ovl_rd_ok)
                               |(is_write & ~m_smk_ro & ovl_wr_ok)))
                  | sel_ide     // IDE task file: reads AND writes replied
                                // (BkEmu device semantics; the ROM/extent
                                // coexistence keeps its own terms above)
                  | sel_fdd     // КНГМД stub: ditto (a real SMK's floppy
                                // controller always replies there)
                  | sel_turbo;  // TURBO: the 037 has stopped owning RAM, so
                                // this FSM replies for MK_RAM037 - both
                                // directions, at N_TURBO, done-gated below.

    // ---- the N=1 (calibrated SMK512 RAM) fast reply ------------------------
    // N_EXT = 1 means "RPLY follows the strobe inside the cycle" - the N_KBD=1
    // convention, and what an async external SRAM board actually does (the
    // hardware calibration is in qbus_pkg / sim/smktime). The wait FSM's wcnt
    // cannot express it (it counts N-2 edges), so the reply is issued at the
    // detection edge itself, and the wcnt load below is clamped to >= 2 so it
    // stays legal on the fallback path.
    //   * READ  - u_dp started the fetch back at SYNC (fast_rd), so mem_ready
    //             is already up. Requiring it here keeps the done-gate as a
    //             visible safety net: if it is ever low we fall into S_WAIT and
    //             raise dbg_romgate, which sim/smktime fails on.
    //   * WRITE - a posted write; the data was captured off the bus one sclk
    //             after DOUT and u_dp is single-threaded, so the next cycle's
    //             fetch cannot overtake it. Replying at once is what the real
    //             board does (and mem_ready cannot be up yet by construction).
    // sel_ext && !ovl_zone is uniquely the mem-region MK_EXT leg: sel_io /
    // sel_ide / sel_vreg all live in ovl_zone, and where sel_fdd coexists
    // (0177130-133 inside an SMK-covered segment 7) its read contribution is
    // 0 and drive_data is 0 either way - so none of the reply-point I/O
    // machinery applies and u_dp drives the read data, exactly as in S_WAIT.
    // (The clamp is spelled inline at the wcnt load rather than as a named
    //  localparam - Quartus 11.0 and Icarus both refuse a module-level
    //  constant expression derived from an imported package parameter.)
    // !turbo_mem: in turbo this leg takes N_TURBO instead (see turbo_mem), and
    // the N=1 reply could not be honoured there anyway - it depends on
    // cpu_sdram_dp's early fetch beating the reply point, and at /16 the head
    // start is gone. Excluding it here is what keeps the two mechanisms from
    // disagreeing about which cycle the reply lands on.
    wire ext_fast = (N_EXT == 1) && sel_ext && !ovl_zone && !turbo_mem
                  && ((is_read  && !m_smk_wo && mem_ready)
                   || (is_write && !m_smk_ro));

    // The same mechanism for the 177662 video register. N_VREG = 1 is
    // schematic-derived: the 0011M wire-ORs RPLY straight off the write strobe
    // that clocks the register (D6:C -> D34 -> S1-49 -> D8:B; see qbus_pkg), so
    // it is the fastest reply on the board, and the placeholder N_ROM count was
    // one CPU cycle per palette write - the beam-raced-effect skew.
    // Write-only by construction (sel_vreg is a write decode), so this is the
    // WRITE case above verbatim: a posted write whose value was captured off
    // the bus in the DOUT window one sclk after DOUT (the vid_* block below),
    // nothing to fetch (drive_data / fetch_stb stay 0) and no done-gate to
    // wait for. It can coexist with an SMK extent write at 177662 (ovl_zone),
    // where ext_fast is excluded and u_dp posts to SMK RAM on the same
    // single-threaded write port - same argument, same safety.
    wire vreg_fast = (N_VREG == 1) && sel_vreg && is_write;

    always_ff @(posedge cpu_clk) begin
        fetch_stb <= 1'b0;
        if (reset) begin
            state <= S_IDLE; drive_data <= 1'b0; reply <= 1'b0; wcnt <= '0;
            dbg_romgate <= 1'b0; dbg_turbowait <= 1'b0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    drive_data <= 1'b0;
                    reply      <= 1'b0;
                    if (!sync_n && ((selected && (is_read || is_write))
                                    || (sel_vreg && is_write))) begin
                        // 177716 bit-2 write-flag: set at THIS detection edge,
                        // not the reply point - the vm1 self-replies every
                        // write in the 177700-177717 block, so the DOUT window
                        // closes before our reply point (the S_WAIT stand-down
                        // below) and detection is the only edge where this FSM
                        // observes the write. Any write sets it, word or byte
                        // (nSEL1 covers 177717 too) - BkEmu
                        // Sel1RegisterSystemBits semantics.
                        if (is_write && !sel1_n)
                            sel1_wflag <= 1'b1;
                        // The 177662/177130 writes and SMK RAM (MK_EXT) get
                        // their own fixed counts - see qbus_pkg (N_VREG and
                        // N_EXT are hardware-calibrated; N_SMKREG is still an
                        // uncalibrated placeholder). The 3-bit wcnt caps any
                        // N at 9.
                        // MK_EXT takes N_EXT only in the MEM region: an
                        // I/O-page extent access uses the N_ROM (I/O-family)
                        // count, because at 177716 the 037's start-vector
                        // assist asserts RPLY EARLY (wire-AND) and the vm1's
                        // data-sample point then sits a fixed distance after
                        // that assert - the N_EXT count landed the merged
                        // word AFTER the sample (found in sim: the ALL-mode
                        // 177716 read returned only the AD15 bit).
                        // sel_fdd ranks BELOW the mem-region extent term:
                        // in the HLT/ALL modes an extent-covered 177130-133
                        // access keeps its N_EXT count (the FDD stub only
                        // claims what nothing else replies to)
                        // TURBO ranks FIRST among the mem-region legs: it
                        // replaces the authentic counts of all three
                        // SDRAM-backed ones (RAM037's 037 grant, ROM's N_ROM,
                        // MK_EXT's N_EXT) with the single N_TURBO - see
                        // turbo_mem for why that is required and not merely
                        // tidy. It cannot shadow the I/O-page or device legs:
                        // turbo_mem excludes ovl_zone, and sel_vreg/sel_ide/
                        // sel_fdd are not mem-region kinds.
                        wcnt  <= turbo_mem  ? 3'((N_TURBO < 2 ? 2 : N_TURBO) - 2)
                               : sel_vreg   ? 3'((N_VREG < 2 ? 2 : N_VREG) - 2)
                               : sel_ide    ? 3'(N_IDE-2)
                               : (sel_ext && !ovl_zone)
                                            ? 3'((N_EXT < 2 ? 2 : N_EXT) - 2)
                               : sel_fdd    ? 3'(N_SMKREG-2)
                               : 3'(N_ROM-2);
                        // N=1: reply at THIS detection edge (the N_KBD=1
                        // convention - an async slave whose RPLY follows the
                        // strobe inside the cycle). Two N=1 legs: mem-region
                        // MK_EXT, the calibrated SMK512 RAM, and the 177662
                        // write (vreg_fast). MK_EXT reads are driven by u_dp
                        // (drive_data stays 0) and sel_ext && !ovl_zone can
                        // never be 177716, so none of the reply-point I/O
                        // machinery applies; mem_ready is up because u_dp
                        // issued the read at SYNC (fast_rd); if it somehow is
                        // not, fall through to S_WAIT with wcnt=0 and let the
                        // done-gate there extend the reply AND raise
                        // dbg_romgate - the safety net stays, and stays
                        // observable (sim/smktime fails on it). The 177662 leg
                        // is a pure posted write: nothing to fetch, nothing to
                        // gate (fetch_stb below is is_read = 0 there).
                        if (ext_fast || vreg_fast) begin
                            reply     <= 1'b1;
                            fetch_stb <= is_read;
                            state     <= S_REPLY;
                        end else
                            state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (!is_read && !is_write) begin
                        // The strobes released before our reply point: the
                        // CPU's internal self-reply completed the cycle (a
                        // write into the 177700-177717 block, e.g. the HALT
                        // entry's 177716 update - the vm1 self-replies there
                        // faster than N_ROM). Stand down instead of firing
                        // RPLY into the idle bus, which would perturb the
                        // next cycle (caught by the interrupt-latency
                        // golden; no oracle wrote 177716 before it).
                        state <= S_IDLE;
                    end else if (wcnt == 0) begin
                        // What did u_dp actually ISSUE for this cycle? Only
                        // those legs may done-gate or merge: a direction the
                        // mapper flags off (an smk_wo read / smk_ro write)
                        // never issues, and gating on raw sel_ext there would
                        // hold RPLY forever when sel_io coexists in the I/O
                        // page (e.g. a HLT-mode 177716 read: SEL1 replies,
                        // the write-only extent fetches nothing).
                        if (((sel_romx || (sel_ext && !m_smk_wo)) && is_read
                             || (sel_ext && !m_smk_ro && is_write)
                             || sel_turbo)             // turbo RAM, both directions
                            && !mem_ready) begin
                            // done-gate: the SDRAM word is late - hold RPLY
                            // (extends the cycle) instead of replying over stale
                            // data / an unposted write. Covers ROM reads, SMK
                            // RAM (MK_EXT) BOTH directions, and - in turbo - the
                            // RAM this FSM has taken over from the 037.
                            //
                            // WHICH diagnostic depends on whether the hold was
                            // EXPECTED. At the authentic rates it never should
                            // be: dbg_romgate is the alarm, and sim/smktime
                            // fails a run on it. In turbo the fixed count is
                            // deliberately shorter than an SDRAM access
                            // (N_TURBO's window vs 12..22 sclk), so a hold is
                            // part of the design - "reply as soon as the word
                            // is there" - and routing it to dbg_romgate would
                            // destroy that flag's meaning everywhere. It goes to
                            // dbg_turbowait instead: observable, never fatal.
                            if (turbo_mem) dbg_turbowait <= 1'b1;
                            else           dbg_romgate   <= 1'b1;
                        end else begin
                            reply <= 1'b1;
                            if (is_read) begin
                                // I/O-page overlay/extent reads: the OR-merge
                                // (io_word | the fetched SDRAM word) - the
                                // open-collector wire-OR BkEmu models by OR-ing
                                // memory and device reads. THE boot read: at
                                // 177716 under SYS this returns BIOS[0o7716] |
                                // SEL1 = 166400-based -> the start PC. Mem-
                                // region ROM/SMK reads stay u_dp-driven. The
                                // merge term is the issued-read condition
                                // (never a stale rd_hold from a wo extent).
                                rdata      <= rd_romio
                                            | (((sel_romx | (sel_ext & ~m_smk_wo))
                                                & ovl_zone)
                                               ? ram_rdata : 16'h0000)
                                            | (sel_ide ? ide_rdata : 16'h0000);
                                // SDRAM ROM/SMK/turbo-RAM data: u_dp drives (it
                                // fetched the word and owns the pad through
                                // rdata_oe); I/O incl. the merged overlay
                                // reads: this FSM. sel_turbo is a mem-region
                                // kind, so ovl_zone is 0 there and the term is
                                // unconditional - a turbo RAM read is driven
                                // exactly as it is today under the 037.
                                drive_data <= !((sel_romx || sel_ext || sel_turbo)
                                                && !ovl_zone);
                                fetch_stb  <= 1'b1;
                            end
                            // 177716 write-flag: cleared after read (rdata
                            // latched above still sees the old value; the SET
                            // side lives at the S_IDLE detection edge - writes
                            // never reach this reply point). Byte reads of
                            // 177717 clear it too (BkEmu clears on any read).
                            if (is_read && !sel1_n)
                                sel1_wflag <= 1'b0;
                            state <= S_REPLY;
                        end
                    end else
                        wcnt <= wcnt - 1'b1;
                end
                S_REPLY: begin
                    // Release RPLY once both strobes are idle. This also makes a
                    // DATIO(B) RMW to ROM time out on its write half WITHOUT any
                    // special handling: the vm1 will not assert DOUT until the
                    // read reply's ack has cleared (dout_start &= ~rply_ack[2],
                    // vm1_qbus.v), and it can't clear until we drop RPLY here - so
                    // a DATIO always has a both-strobes-idle gap in which this exit
                    // fires. The write half then re-enters as a fresh access; a
                    // ROM write is not `selected`, gets no reply, and qbto's ->
                    // trap 4. (Proven by the sim/romwr RMW leg + its mutation
                    // test.) I/O 177714 RMW writes still reply via sel_io.
                    if (din_n && dout_n) begin
                        reply <= 1'b0; drive_data <= 1'b0; state <= S_IDLE;
                    end
                end
            endcase
        end
        // Peripheral-register INIT semantics (real-BK reset wiring rule): the
        // 177716 write-flag resets on the nINIT line - asserted through the
        // CPU's own reset AND pulsed by the RESET instruction - never on DCLO.
        // Placed after the FSM case so INIT wins over the reply-point update.
        if (!init_n) sel1_wflag <= 1'b0;
    end

    // ---- BK speaker / tape-motor capture (177716 bits 6/7) ---------------
    // The vm1 self-replies for the whole 177700-177717 block (sel177x, its own
    // pin_rply_out), so a 177716 write completes on the CPU's fast internal
    // reply and the ROM/IO wait FSM above stands down before its reply point
    // (it observes the write only at its S_IDLE detection edge, where the
    // 177716 write-flag is set). Capture the write data straight off the bus
    // during the DOUT window on the fast sys_clk instead, independent of any
    // reply. nSEL1 with addr[0]==0 => word or low-byte write, so the true
    // bit 6 (~ad_n[6]) is always the intended data bit (a 177717 high-byte
    // write must NOT touch it). Never runtime-reset (software-owned latch;
    // survives nINIT and warm reset). Bit 6 only = the BkEmu Speaker contract
    // for a BK-0010 (MiSTer's extra spk_out bits are its tape-monitor mixing,
    // not register semantics). BK-0011M CONTRACT: a WORD write with
    // bit 11 SET is a memory-BANKING write and must NOT update the speaker or
    // motor (BkEmu Speaker.BK0011M_ENABLE_BIT; MiSTer agrees) - that is the
    // !bank_wr gate below (mem_mapper's mutual-exclusion flag). Byte writes
    // can never carry bit 11, so they are ALWAYS peripheral writes; and in
    // BK-0010 mode bank_wr is forced low, so a bk10 word write with bit 11
    // set still captures - pinned by spk_capture_tb's 0o177677 and 0o004100
    // cases. Note sel1_wflag (bit 2) is deliberately still set by banking
    // writes: BkEmu's Sel1RegisterSystemBits flags ANY write to the register.
    // mot_bit = bit 7, the tape motor relay: 1 = STOPPED, 0 = running (MONITOR
    // source d6.mac: KPUSK=020 starts, KSTOP=220 stops; boot init and keyclick
    // both hold bit 7 = 1, so the motor runs ONLY inside tape operations -
    // that's what lets ~mot_bit double as the CMT-jack mode enable in the top).
    always_ff @(posedge sclk) begin
        if (!sync_n && !dout_n && !sel1_n && !addr[0] && !bank_wr) begin
            spk_bit <= ~ad_n[6];
            mot_bit <= ~ad_n[7];
        end
    end

    // ---- 177714 (nSEL2) parallel-port write capture -----------------------
    // The programmable parallel port. ALL THREE BK sound expansions decode this
    // ONE address (BkEmu REG_SEL2 = 0177714) and are told apart only by the
    // data pattern - Covox by the high byte, the AY by word-vs-byte, Menestrel
    // by its pin field - so the bus side is shared and belongs here, in one
    // real module, rather than replicated in each device.
    //
    // Same shape as the spk_bit capture above and for the same reason: the vm1
    // self-replies for the whole 177700-177717 block, so the wait FSM stands
    // down before its reply point and never observes the write. Sample the DOUT
    // window on sclk, independent of any reply. This block is a PURE OBSERVER -
    // 177714 already gets its reply from sel_io (the nSEL2 leg), and nothing
    // here feeds `selected`, `wcnt`, the reply, io_word, rd_romio, ad_oe or
    // mem_ready. That is what makes it timing-inert against every golden.
    //
    // WTBT IS DUAL-PURPOSE: "write cycle" at SYNC time, "BYTE op" at DOUT time.
    // port_word needs the DOUT-time meaning, so wtbt_n is sampled LIVE at the
    // write point and NEVER from the SYNC latch (the qbus_sdram lesson). The
    // cycle-count oracles cannot see write data, so a SYNC-latched version
    // would slip through sim silently unless the tb spells both WTBT profiles -
    // spk_capture_tb does, and that is the discriminating case.
    //
    // ONE STROBE PER BUS WRITE. The DOUT window is many sclk long, and unlike
    // the idempotent spk level latch these devices are EDGE sensitive (the AY
    // distinguishes a register select from a data write; Menestrel edge-detects
    // its own nWR across successive writes). port_seen qualifies the first sclk
    // of the window and clears when DOUT releases.
    //
    // POLARITY: port_data holds the BK-TRUE value the program wrote (~ad_n),
    // like spk_bit. BkEmu's device models each do their own `v = ~value` for
    // the physical port inversion - that belongs to the DEVICE, so keeping it
    // out of here lets those models transcribe 1:1 and keeps waveforms legible.
    //
    // NEVER RUNTIME-RESET - the spk/mot class, not a new nINIT exception. A real
    // Covox is a passive resistor DAC hanging off the port latch with no reset
    // pin at all. Device-internal state (the PSG registers, the TurboSound
    // chip-select latch, the Covox mute one-shots) keys to init_n inside the
    // DEVICE, per the standard BK peripheral-reset rule - see bk_turbosound.sv
    // and bk_covox.sv, which both do exactly that. bk_covox depends on this
    // latch NOT being reset in the other direction too: it is what makes the
    // power-on value (0, i.e. an inverted 0xFF = full scale) real, and the
    // reason that device carries an idle one-shot at all.
    //
    // No bank_wr gate is needed (bank_wr requires !sel1_n, so it can never
    // assert on a 177714 write) and no smk_en gate either (under SMK SYS a
    // 177714 write also broadcast-posts to SMK RAM; the device seeing it too is
    // BkEmu's memory-then-device order).
    //
    // The READ side is deliberately NOT merged here: both shipped devices are
    // write-only (bk_covox never reads; bk_turbosound leaves the core's DO
    // unconnected), while a read merge
    // would reach into the reply/OE cone that this write capture carefully
    // avoids. If a device ever needs it, follow the ide_rdata pattern exactly.
    wire port_dout = !sync_n && !dout_n && !sel2_n;
    always_ff @(posedge sclk) begin
        port_wr <= 1'b0;
        if (!port_dout) port_seen <= 1'b0;
        else if (!port_seen) begin
            port_seen <= 1'b1;
            port_wr   <= 1'b1;
            port_word <= wtbt_n;                              // LIVE at DOUT
            port_be   <= wtbt_n ? 2'b11 : (addr[0] ? 2'b10 : 2'b01);
            if (wtbt_n)       port_data       <= ~ad_n;        // word
            else if (addr[0]) port_data[15:8] <= ~ad_n[7:0];   // 177715: value<<8
            else              port_data[7:0]  <= ~ad_n[7:0];   // 177714
        end
    end

    // ---- BK-0011M 177662 video register capture --------------------------
    // MiSTer rtl/video.sv is the reference (BkEmu simplifies this register).
    // High byte only - the low byte is never stored: bit 15 = displayed
    // screen (0 = RAM page 1, 1 = page 7), bit 14 = frame-IRQ2 mask (active
    // high; irq_en = ~bit14 - consumed by the 50 Hz EVNT/IRQ2 frame-
    // interrupt gate in ocbk_top), bits 11:8 = palette index. Captured in
    // the DOUT window on sclk like spk_bit above, idempotent across the
    // window; ANY write, word or byte, latches the high lanes (MiSTer
    // semantics; only word writes are oracle-pinned - byte-write fidelity
    // is an open question). Takes
    // effect immediately, no per-line latch (BkEmu's per-scanline latch is
    // an emulator artifact). Reset is DCLO-ONLY - the same deliberate nINIT
    // exception as the mapper's map registers: the RESET instruction must
    // not blank the screen page under the running code. Defaults = MiSTer
    // def_reg662 0o047400: page 0, IRQ2 masked, palette 15.
    always_ff @(posedge sclk) begin
        if (reset) begin
            vid_page      <= 1'b0;
            vid_irq2_mask <= 1'b1;
            vid_pal       <= 4'hF;
        end else if (model_bk11 && !sync_n && !dout_n
                     && addr[15:1] == 15'(16'o177662 >> 1)) begin
            vid_page      <= ~ad_n[15];
            vid_irq2_mask <= ~ad_n[14];
            vid_pal       <= ~ad_n[11:8];
        end
    end

    // ---- BK-0011M СТОП-enable capture -------------------------------------
    // 177716 write bit 12: 1 = СТОП (nIRQ1) blocked, 0 = enabled. MiSTer
    // BK0011M.sv is the model (key_stop_block <= dout[12] on a sysreg write
    // with ~dout[11] & wtbt[1]); BkEmu agrees except its even-byte-write
    // implicit re-enable, an emulator artifact rejected here. The lane rule
    // matches the real board, which latches 177716 write data in registers
    // clocked by separate WR1/WR2 byte-lane strobes: only a write that
    // strobes the HIGH byte (word write, wtbt_n released, or the 177717 odd
    // byte, data on AD15:8) can touch bit 12; the bit-11 banking exclusion
    // is applied on the lane MiSTer-literally, so it covers odd-byte writes
    // too (can't reuse bank_wr - that flag is word-only). bk11-only: in
    // BK-0010 mode the latch never captures and holds 0, so the ocbk_top
    // gate is transparent (bk10 goldens untouched). Reset is DCLO-ONLY, to
    // 0 = enabled - the same deliberate nINIT exception as the map/662
    // registers: the RESET instruction must not re-enable СТОП under
    // software that blocked it. Consumer: ocbk_top 2-FF syncs this level
    // onto cpu_clk and gates the СТОП one-shot launch.
    always_ff @(posedge sclk) begin
        if (reset)
            stop_block <= 1'b0;
        else if (model_bk11 && !sync_n && !dout_n && !sel1_n
                 && ad_n[11] /* true bit 11 clear: not banking */
                 && (addr[0] || wtbt_n) /* high byte lane written */)
            stop_block <= ~ad_n[12];
    end

    // ---- Q-bus drivers (inverted; open-collector rply) -------------------
    // ad_n carries ROM/IO read data (this FSM) or RAM read data (datapath).
    assign ad_n   = drive_data   ? ~rdata     : 16'hZZZZ;
    assign ad_n   = ram_rdata_oe ? ~ram_rdata : 16'hZZZZ;
    assign rply_n = reply        ? 1'b0       : 1'bZ;

endmodule
