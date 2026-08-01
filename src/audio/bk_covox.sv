// ============================================================================
//  bk_covox - the BK Covox: an 8-bit DAC on the 0177714 parallel port
// ----------------------------------------------------------------------------
//  The second device to hang off the Phase-10 177714 capture seam. Like
//  bk_turbosound it snoops what qbus_mem captured, never touches the bus, and
//  presents ONE STEREO PAIR to bk_audio's mixer slots - so qbus_mem is
//  unchanged by this feature and no timing golden moves.
//
//  A real Covox is a passive resistor DAC wired straight to the port latch.
//  That single sentence explains almost everything below: there is no register
//  file, no protocol and no state of its own to reset - the LATCH is the
//  device, and this module is the byte -> sample map plus the arbitration that
//  a real board does not need because a real board does not have an AY sharing
//  the connector.
//
//  BkEmu's Covox.java IS THE CONTRACT:
//
//      int l = ~value & 0xff;
//      int r = (~value >> 8) & 0xff;
//      if (!isStereoMode) r = l;
//      toPcmSampleValue(b) = ((b + Byte.MIN_VALUE) << 8) | b
//
//    * LOW byte = LEFT, HIGH byte = RIGHT, of the SAME word. One address, two
//      lanes - not two addresses.
//
//    * The port is physically inverted, so the device does its own `~`, the
//      same division of labour as bk_turbosound (qbus_mem hands over the
//      BK-TRUE value the program wrote). Consequence a test program has to
//      know: the code a program writes for SILENCE is 0177, not 0200.
//
//    * The byte map is EXACTLY LINEAR - ((b-128)<<8)|b == 257*b - 32768 - and
//      257*b is just {b,b}, so subtracting 32768 is a single inverted bit and
//      the whole map is WIRING:
//
//          sample = $signed({~b[7], b[6:0], b})
//          b=0 -> -32768      b=128 -> +128      b=255 -> +32767
//
//      Full BkEmu scale on purpose: audio_mixer's +/-32767 domain exists so
//      "the AY volume table, the Covox byte map and the Menestrel counter
//      levels transcribe 1:1 out of BkEmu with no rescaling to get wrong"
//      (audio_mixer.sv). The HEADROOM is therefore not applied here - it is
//      one compile-time SLOT_GAIN nibble in bk_audio (5/8, see its slot map).
//
//  PER-LANE HOLD, NOT BkEmu'S ZERO-FILL - a deliberate divergence. On a byte
//  write BkEmu passes the other lane as 0, so its model reads the OTHER
//  channel as 0xFF, i.e. full scale. That is an artifact of its
//  writeMemory(value << 8) signature, not of the hardware: 177714 is a
//  byte-lane-strobed latch and holds the lane that was not written, which is
//  exactly what qbus_mem does. Same call, and the same reasoning, as the
//  177716 stop_block lane rule - the real WR1/WR2 byte strobes win over a
//  BkEmu lane artifact.
//
//  THAT IS ALSO WHY port_word / port_be ARE NOT PORTS HERE. Because the latch
//  holds, the Covox output is a PURE FUNCTION of port_data: an even-byte write
//  moves the left lane and leaves the right, an odd-byte write does the
//  mirror, a word write moves both - all of it already expressed by the latch
//  contents. Word-vs-byte is the AY's discriminator (bk_turbosound), not ours.
//  port_wr is taken for one reason only: the idle one-shot below.
//
//  STEREO / MONO IS DIP 5, NOT AN AUTODETECT - the second deliberate
//  divergence. BkEmu latches stereo when a word write's inverted high byte is
//  neither 0x00 nor 0xFF and decays back to mono after 3 s of no such write.
//  Both halves exist because a BkEmu device OBJECT outlives the program that
//  programmed it - the identical argument that made us drop the TurboSound
//  dead-man timeout. Here it is a switch: stereo always, DIP 5 ON = mono
//  (r = l, BkEmu's own fold). `mono` is live, so it takes effect without a
//  write and without a reset.
//    Consequence, accepted and documented rather than fixed in RTL: a
//    mono-only program writes the low lane only, so with DIP 5 OFF the right
//    channel carries whatever the high lane holds - at power-on that is 0,
//    which inverts to 0xFF. That is what DIP 5 is FOR, and README says so.
//
//  THE MUTE, i.e. the whole reason this module has any state at all. Covox and
//  TurboSound decode the SAME address, so with both present each renders the
//  other's traffic as garbage. The PSGs win:
//
//      cx_en = live & ~psg_hold
//
//    * `live` - a ~43 ms one-shot retriggered by every 177714 write. This is
//      what stops the never-reset latch from parking a DC on the ladders: at
//      power-on port_data is 0, which inverts to b = 255 = FULL POSITIVE
//      SCALE, and a finished program leaves its last sample behind. With the
//      slot disabled the mixer contributes EXACTLY zero, so audio_ns6 stays on
//      its exact-zero fixed point and silence keeps producing no pin activity
//      - the property the -85.8 dBFS hardware noise-floor measurement and the
//      CMT anti-echo argument both rest on.
//
//    * `psg_hold` - a ~0.7 s retriggerable hold on psg_act, which ocbk_top
//      drives from bk_turbosound's ts_snd ("the PSGs are emitting a non-zero
//      sample", taken before the x15 stage so it LEADS ts_l/ts_r by one
//      cycle). The hold is load-bearing, not hysteresis for its own sake: a
//      PSG square wave is zero for half of every period and goes silent for
//      every rest, and without it the Covox would unmute for a few ms onto
//      whatever AY register data the latch happens to hold - a loud click per
//      note.
//
//    WHY ts_snd AND NOT ts_act (the R7 channel-enable bits, pLed[4]): ts_act
//    is both insufficient and harmful. A YM2149 channel with tone AND noise
//    disabled passes its volume register through as DC (ym2149.sv) - that is
//    how AY "digi" playback works - so ts_act = 0 does NOT imply silence, and
//    the enable bits alone would not close bk_audio's headroom proof. In the
//    other direction, a player that exits leaving channels enabled at volume 0
//    would keep the Covox muted until the next reset. ts_snd is exactly the
//    necessary and sufficient condition; ts_act is not used here at all.
//
//    KNOWN, BOUNDED ARTIFACT - accepted, not engineered around. An AY
//    program's SETUP phase writes registers before any channel sounds, so for
//    that window ts_snd is low and the Covox renders those register writes as
//    samples: a faint click of order 100 us at the start of a TurboSound
//    program. It is bounded by how long a setup takes, it cannot recur while
//    music plays, and every alternative discriminator collides with stereo
//    Covox - which uses word writes exactly as the AY register latch does. If
//    it ever proves audible on the board the escape hatch is MiSTer's (a hard
//    user-selected mode), never a heuristic.
//
//  ONE GATE, NOT TWO. cx_l/cx_r keep carrying the sample while muted; the
//  mixer's runtime slot enable is the single mute mechanism. Zeroing here as
//  well would be logic no mutation could kill - the bk_turbosound lc1/rc1
//  precedent. cx_en is deliberately COMBINATIONAL off the two counters: a
//  registered version would arrive one cycle after ts_l goes non-zero and let
//  both sources reach the mixer's stage 0 together.
//
//  RESET is `~init_n` (2-FF synced) ORed with the power-on reset - the
//  standard BK peripheral rule, so a RESET instruction silences the Covox. It
//  does NOT clear the 177714 latch: that is qbus_mem's never-runtime-reset
//  state, because a real Covox is a passive DAC with no reset pin.
// ============================================================================
module bk_covox #(
    // Idle one-shot: 2^IDLE_BITS sys_clk = 43.4 ms at 96.65 MHz. Long enough
    // that no sample-playback loop can fall through it, short enough that a
    // finished program's leftover DC is gone before anyone notices it.
    parameter int IDLE_BITS = 22,
    // PSG mute hold: 2^PSG_BITS sys_clk = 694 ms. Must comfortably exceed the
    // longest rest a tune can contain; see the header.
    parameter int PSG_BITS  = 26
) (
    input  logic               sys_clk,
    input  logic               rst_n,       // power-on reset (active low)
    input  logic               init_n,      // Q-bus nINIT (CPU domain, async)

    // ---- the 177714 seam (qbus_mem, sclk = sys_clk: no CDC) ---------------
    input  logic               port_wr,     // 1 sclk per 177714/15 bus write
    input  logic [15:0]        port_data,   // the latch, BK-true, lanes held

    // ---- configuration and arbitration ------------------------------------
    input  logic               mono,        // DIP 5 (live), 1 = right := left
    input  logic               psg_act,     // bk_turbosound ts_snd

    // ---- to bk_audio's mixer slots ----------------------------------------
    output logic signed [15:0] cx_l,        // -32768 .. +32767, BkEmu scale
    output logic signed [15:0] cx_r,
    output logic               cx_en        // 0 = muted (the slot is zeroed)
);

    // ---- reset -------------------------------------------------------------
    // nINIT comes from the CPU domain (vm1 drives it open-collector), so 2 FF.
    logic init_meta, init_sync;
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            init_meta <= 1'b1;
            init_sync <= 1'b1;
        end else begin
            init_meta <= init_n;
            init_sync <= init_meta;
        end
    end

    wire reset = ~rst_n | ~init_sync;

    // ---- the byte lanes ----------------------------------------------------
    wire [7:0] lb = ~port_data[7:0];
    wire [7:0] rb = mono ? lb : ~port_data[15:8];

    // 257*b - 32768. 257*b is {b,b}, so the -32768 is one inverted bit and the
    // whole BkEmu map costs no logic at all - see the header. Written inline
    // rather than as a function: Quartus 11.0's SystemVerilog support is the
    // constraint this tree keeps hitting, and there is nothing to share.
    wire signed [15:0] samp_l = $signed({~lb[7], lb[6:0], lb});
    wire signed [15:0] samp_r = $signed({~rb[7], rb[6:0], rb});

    always_ff @(posedge sys_clk) begin
        if (reset) begin
            cx_l <= 16'sd0;
            cx_r <= 16'sd0;
        end else begin
            cx_l <= samp_l;
            cx_r <= samp_r;
        end
    end

    // ---- the idle one-shot -------------------------------------------------
    // Any 177714 write reloads it; the same shape as bk_audio's spk activity
    // one-shot. Reloading unconditionally (not only from the idle state) is
    // what makes it RETRIGGERABLE, which is the whole point.
    logic [IDLE_BITS-1:0] idle_cnt;
    always_ff @(posedge sys_clk) begin
        if (reset)              idle_cnt <= {IDLE_BITS{1'b0}};
        else if (port_wr)       idle_cnt <= {IDLE_BITS{1'b1}};
        else if (idle_cnt != 0) idle_cnt <= idle_cnt - 1'b1;
    end

    // ---- the PSG mute hold -------------------------------------------------
    logic [PSG_BITS-1:0] psg_cnt;
    always_ff @(posedge sys_clk) begin
        if (reset)             psg_cnt <= {PSG_BITS{1'b0}};
        else if (psg_act)      psg_cnt <= {PSG_BITS{1'b1}};
        else if (psg_cnt != 0) psg_cnt <= psg_cnt - 1'b1;
    end

    assign cx_en = (idle_cnt != 0) & (psg_cnt == 0);

endmodule
