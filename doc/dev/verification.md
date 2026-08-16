# Verification discipline (do not skip)

The oracle catalogue: what each `sim/` run pins, and the rules for regenerating
goldens. Longer per-oracle contracts live in `sim/*/README.md`.


Cycle accuracy is the whole point. All `make sim` oracles must stay green:
- `sim/bk10/run.sh` — the upstream timing testbench vs `sim/bk10/golden.txt`
  (the CPU core's per-instruction cycle counts). Independent of the SDRAM work.
- `sim/ref037/run.sh` — **fourteen diffs against TWO golden sets** (Phase 9;
  it was twelve against one). The shipped 037 now carries a deliberate,
  hardware-calibrated deviation from the vendored netlist (the `GRANT_SETUP`
  window + `bk_rply`, see the beam-race bullet), so one pair can no longer
  serve both — and the split is explicit rather than papered over:
  **`golden_037{,_rom}.txt` are the NETLIST's**, generated ONLY from a
  reference run, and `va_037_sync` is still diffed against them **at
  `GRANT_SETUP=0`** — that is what still guards the sys_clk retime, and it
  proves the parameter folds away exactly. **`golden_037_hw{,_rom}.txt` are
  the SHIPPED machine's**, generated from the same simplest stack
  (`ref037_sync_tb`, behavioural DRAM) at the shipped setting via
  `run.sh --regen-hw`, and every integration leg reproduces them — the same
  structure the single pair had, with silicon rather than the netlist as the
  authority. **Never "fix" a `_hw` diff by regenerating from a netlist run.**
  The `_hw` delta is +4 cycles (one /32 slot) on 037-arbitrated fetches only;
  the ROM self-loop stays flat, which is the invariant that matters.
  What the legs cover, vs `golden_037*.txt` (with-display timing,
  program in RAM) and `golden_037*_rom.txt` (Phase-5: same program words executed
  *from the ROM region* — ROM is never 037-cycle-stolen, so its self-loop is
  **flat**; the RAM loop beats): the reference netlist,
  the retimed `va_037_sync` (both settings), the SoC integration (instantiating the *real*
  `qbus_mem`) with a synthetic port-2 saturator, the `+bootload` run (the
  EPCS loader populates SDRAM through the boot-writer mux, then golden must
  still match), **`ref037_soc_video_tb`** — real video pipeline on all 4
  arbiter ports, golden window exact, then 64 display lines with the loop
  invariant intact (RAM beat pattern / ROM flat-13), plus `FETCH-ROMGATE` /
  `FETCH-P0LAT` watchdogs — and three **`+warmreset` replays** (Phase-5.5 soft
  reset: DCLO/ACLO re-pulsed mid-run, mid-display-line in the video tb) where
  BOTH passes are diffed against the *same unchanged golden*: a warm reset must
  be cycle-identical to a cold boot — **never regenerate a golden for a
  warm-reset change**. Error prints carry a `FETCH-` prefix so run.sh's
  `/^FETCH/`-only reduce filter lets them break the diff — keep that convention
  (the reduce's loop-sample counter re-arms on any non-loop line; that is what
  gives each warm-reset pass its own 4 self-loop samples).
- `sim/ref014/run.sh` — the Phase-6 keyboard oracles, **four legs**. Contract:
  the vendored `vp_014.v` **gate netlist** (+ `lib_1801.v`) runs the shared
  transaction-granular scenario (`ref014_scenario.v`) → `golden_014.txt`, and
  the behavioral `src/peripheral/bk_kbd014.sv` must reproduce it line-for-line (netlist
  wins all disputes; the pinned contract — press-while-ready queuing with
  key-held re-delivery, retro-fire on unmask, no АР2 flag in 662 bit 7, 662
  writes bus-timeout, INIT keeps the code register — is in
  `sim/ref014/README.md`). Interrupt latency: the `mem/gen_kbd_test.py`
  program (VIRQ 060/0274 ISRs, masked press, nIRQ1 pulse → **trap 4**, the
  authentic СТОП path) runs on the netlist reference stack →
  `golden_kbd.txt`, and the SoC stack (va_037_sync + qbus_mem + SDRAM
  model + bk_kbd014) must match the same golden — this diff calibrated
  `N_KBD`/`N_IAK` (=1) and the write fast path. **Goldens regenerate only
  from netlist runs.**
- `sim/run_ps2.sh` — the PS/2 front end (`ps2_rx` + `kbd_ps2bk`) against a
  hand-written expected event list: BkEmu case algebra over ЛАТ/РУС ×
  ЗАГЛ/СТР × НР, СУ masking, АР2 + the silicon auto-274 code group,
  typematic suppression, multi-key `key_down`, СТОП strobes, the Print
  Screen radial toggle (screen_mode), the **F12 radial toggle (turbo, §12d:
  one toggle per press, typematic suppressed, never a matrix event, never in
  the held-key list, and an E0-prefixed 07 must NOT be F12)**, Scroll Lock now
  emitting no event (CMT tape mode moved to DIP 4), parity-error and
  stale-prefix recovery.
- `sim/run_audio.sh` — the Phase-10 audio oracles, **four legs, mutation-tested
  ×32** (23 at Phase 10; Phase 11 added A1/A2 — the TurboSound slot-pack
  orientation and the SPK_LVL multiple-of-1024 rule; Phase 12 added A3/A4/A5 —
  the Covox slot-pack orientation, its mute enable and its 5/8 slot gain; the
  joysticks added Q6–Q9 on the 177714 READ merge);
  `sim/audio/README.md` carries the pinned contract and the written
  justification for the resolution claim (the `sim/evnt/README.md` precedent).
  **Leg 3 `audio_ns6_tb` is the one that matters**: it proves the DC **identity**
  `1024·Σcode − M·(32·1024+s) == errp₀ − errp_M ∈ [−1023,1023]` — not a
  tolerance, it telescopes out of the loop and holds for every M, so the mean
  emitted code tracks the input to <1/1000 of a ladder step where plain
  truncation is off by up to 512 units *per sample*. Its sharpest leg (L4b)
  reconstructs **a signal of amplitude 512 = HALF ONE LADDER STEP** to 10/1024
  of a code, which a 6-bit truncating path renders as silence or a 1-bit
  square; plus exact silence, the clamp (an overload must not WRAP), and tick
  discipline. **Leg 4 `audio_mixer_tb`**: gain against an independently written
  floor reference, pan, runtime enable, saturation never wrapping, the
  **`NSRC=1` pass-through invariant** (the `smk_en=0`/`turbo=0` differential
  idiom — what guarantees the speaker-only shipped path is unperturbed), the
  planned `NSRC=10` shape, and — since Phase 11 — the **TurboSound pan pair**
  (slots 3/4 hard-panned opposite ways, the shipped map's only such pair;
  getting it backwards would silently swap the stereo image on the board) plus
  the **shipped worst case 22950 + 8192 = 31142 passing through UNSATURATED**,
  i.e. the gain budget written down as an assertion — and, since Phase 12, the
  **Covox pair at 5/8** (`dut3` is now NSRC=7) with its own worst case
  20480 + 8192 = 28671. The third combination, TurboSound AND Covox at once,
  is deliberately NOT tested because it cannot occur: `bk_covox` mutes on
  `ts_snd`. That is stated in the file so nobody "fixes" a future saturation
  by raising `FS_SAT`. **Leg 1 `bk_audio_tb`** is the regression guard for
  the two hardware-confirmed behaviours — the speaker's STATIC rail codes and
  the whole CMT jack (oe split, comparator network, anti-echo, raw tape-out) —
  plus true stereo, the CMT mono fold, the staircase, and — since Phase 12 —
  the **Covox pan orientation, its 5/8 gain and its mute enable**, all three
  pinned by the same static-fixed-point trick as the TurboSound pan (the
  Covox at +16384 against the speaker's low rail must read code 34 exactly;
  8/8 would read 40). **Leg 2
  `spk_capture_tb`** keeps the 177716 bit-6/7 captures and gains the **177714
  (nSEL2) port-write capture**, whose load-bearing case is the WTBT
  discriminator (see the audio bullet), and — since the joysticks — **section
  10, the 177714 READ merge** (`Q6`–`Q9`): the word on the bus, 177715 getting
  the full word, 177716 staying clean, and the DATIO(B) leg where the read half
  returns the sticks while the write half still strobes the seam exactly once.
  See the `sim/joystick` bullet for why the `!sel2_n` gate is pinned in
  `sim/smk` instead.
- `sim/ts/run.sh` — the Phase-11 **TurboSound** oracles, two legs,
  mutation-tested x16; `sim/ts/README.md` carries the pinned contract.
  **Leg 1 `ym2149_equiv_tb` is the authority and the reason this increment is
  safe**: the vendored reference `sim/ts/ym2149_ref.sv` (upstream MiSTer) and
  the shipped `src/audio/ym2149.sv` are elaborated side by side, driven with
  identical stimulus and diffed on `CHANNEL_A/B/C`, `ACTIVE` and `DO` **every
  clock** — because the shipped copy had to retype a 64-entry volume table,
  unroll a loop and hoist eight registers for Quartus 11.0, and nothing else
  in this tree can see any of that. **The reference wins every dispute and is
  never regenerated from the shipped copy** (the `sim/ref014` rule). `CE` runs
  at **/7**, coprime with the core's own /8 and /16, so a mis-gated enable
  cannot hide; anti-vacuity is checked (two silent cores compare equal
  forever); and during authoring the leg was run against **all 64 single-bit
  volume-table mutations — all 64 killed**. Two lessons are recorded in
  `sim/ts/README.md`: the upper 32 table entries are reachable ONLY through
  the envelope, so a `MODE=1` window too short for `env_vol` to sweep leaves
  most of the AY8910 half untested (a mutation survived exactly that way);
  and the core simulates as **all-X forever** without power-up initialisers,
  because `poly17`'s re-seed term is `!poly17`. **Leg 2 `bk_turbosound_tb`**
  is the device contract on the 177714 seam — the BkEmu protocol (word =
  address, byte = data, inverted, the odd lane's 0xFF, the 4-bit latch mask),
  the 0xFF/0xFE chip select, the ACB fold and its headroom bound, `nINIT`, and
  the /56 PSG clock enable, and (Phase 12) **`ts_snd`, the Covox arbitration
  hook**, which must be high exactly when the sample the fold is ABOUT to
  present is non-zero — it is sampled one edge and compared against
  `ts_l`/`ts_r` the next, because that one-cycle LEAD is the property that
  stops the Covox and the PSGs both reaching the mixer's stage 0 — all checked
  with tone and noise DISABLED, which
  makes each channel emit its volume as DC so the register file reads out
  directly on `CHANNEL_x` with no waiting. One property is deliberately NOT
  mutation-covered and the header says so out loud: see the TurboSound bullet.
- `sim/covox/run.sh` — the Phase-12 **Covox** oracle, **one leg,
  mutation-tested x19**; `sim/covox/README.md` carries the pinned contract.
  One leg on purpose, the `sim/ts` precedent: the SEAM itself — one strobe per
  bus write, BK-true polarity, the odd lane leaving the other half stale — is
  pinned independently by `spk_capture_tb` against the real `qbus_mem`
  (`Q1`–`Q5`), so `bk_covox_tb` models it in its write tasks and tests the
  DEVICE against it. **Its sharpest section is the first one**: `qbus_mem`'s
  177714 latch has no reset, so at power-on it reads 0, which INVERTS to
  b = 255 = +32767 — the leg asserts both that the sample really is at full
  scale AND that `cx_en` is low, because without the idle one-shot the board
  would sit on a full-scale DC on both ladders from power-on. Also pinned: the
  byte map at nine points, the **per-lane hold** (the one deliberate
  divergence from BkEmu — a zero-fill build reads +32767 on the other channel
  and this is what catches it), the mono fold, DIP 5 being LIVE, the PSG mute
  surviving a pulse train, the idle one-shot retriggering, and `nINIT`
  clearing the device but NOT the latch. **Section 10 is the other sharp one,
  and it is a hardware-found regression**: MONITOR's `MIDMBK` ends with a lone
  `CLR @#177714`, which is a single write of the one value that inverts to full
  positive scale on both lanes, so a build that arms on *any* write clicks
  several times per boot. The section walks that sequence — one `CLR`, then
  two, then a constant-code burst — and **X19 is the pre-fix predicate restored
  verbatim**, which must die there. **A known limit, stated in the runner
  header rather than quietly dropped:** 2²² and 2²⁶ `sys_clk` are not
  simulable, so a second instance pins the shipped parameter DEFAULTS while a
  scaled instance pins the BEHAVIOUR — a mutation of either dies, of both
  together would not.
- `sim/joystick/run.sh` — the **joystick** oracle, **one leg,
  mutation-tested x15**; `sim/joystick/README.md` carries the pinned contract.
  Same division of labour as `sim/covox` and `sim/ts` — device here, bus side
  elsewhere. **Its sharpest section is the first one**: `bk_joystick` has no
  reset by design, so the only thing making 0177714 read 0 before the first
  clock edge is the sync chain's declaration-time initial values, and section 1
  checks that BEFORE any edge — it is what the ten `joy_word` tie-offs in the
  SoC testbenches rest on. Also pinned: the MSX active-low → BkEmu active-high
  inversion, a **per-control walk of all twelve inputs** onto their BK bits (the
  MSX direction nibble is U,D,L,R and the BK's is U,R,D,L, so a pass-through is
  wrong in a way that still "works" for UP), the two ports landing in their own
  bytes, START/SELECT having no DE-9 source, and the synchroniser being
  **exactly two deep** in both directions.
  **The bus side is split across two oracles, deliberately.** `spk_capture_tb`
  section 10 (`Q6`–`Q9`) pins the merge against the real `qbus_mem`: the word
  reaching the bus, 0177715 getting the full word, 0177716 staying clean, and
  the **DATIO(B)** leg where the read half returns the sticks while the write
  half still produces exactly one Covox/AY strobe under one SYNC. It cannot pin
  the **`!sel2_n` gate**, because every address that could show a leak also
  takes the mem-region ROM leg, whose reply is done-gated on an SDRAM fetch that
  leg 2 has no model for. `sim/smk` owns the gate instead: its section 2 reads
  0177714 (= BIOS | joystick), 0177776 (= BIOS **alone**) and 0177716 (nSEL1
  wins) against a non-zero `joy_word` on a full SoC with real SDRAM, and both
  mutations — merge dropped, gate dropped — are recorded in its runner header
  as verified by hand.
- `sim/usb/run.sh` — the **USB HID host** oracle, **ten legs plus two skew
  builds, mutation-tested x20 plus one ROM-image mutation**; `sim/usb/README.md` carries
  the pinned contract. The vendored low-speed host runs at its real 12.081 MHz
  rate against `usb_ls_device.v`, a behavioural low-speed HID device (line
  states, NRZI, bit stuffing, CRC5/CRC16, the SETUP/IN/DATA/handshake script).
  Legs: `kbd`, `mouse`, `setproto`, `stallproto`, `pad`, `pad_real`, `stuffdup`,
  `dupstrobe`, `nak`, `unplug`, `skew` (±1.5 %) and `slow`. `pad_real` also
  carries the **shoulder-trigger** frames (byte 6 `0x01`/`0x02`, hook H9) and
  drives `0x33` to pin that they and START/SELECT share the byte without
  disturbing each other.
  **`dupstrobe` is the leg that caught the board bug**, and it did so by
  injecting the EFFECT (one spurious byte strobe) rather than modelling a cause —
  three candidate causes were tested here and all three were wrong. Every other
  leg feeds the host a well-behaved strobe, which is why a genuinely broken
  wrapper passed the whole suite, and the board, three times.
  **`pad_real` is built from a real capture** — every frame is a verbatim
  `usbhid-dump` line from the reference gamepad (`081f:e401`), taken before any
  consumer RTL was written. The wrapper has no report-descriptor parser and its
  gamepad table is explicitly a guess, so this is what turns the guess into a
  tested contract; `U16` in particular (the byte-3/4 threshold) is killable only
  by frames a synthetic leg would never send.
  **`setproto` is the one that came from a board run, and it is the model for
  how a field bug should land here.** Three mice misbehaved three different ways
  because the host left them in *report* protocol while the wrapper decodes
  boot-protocol offsets; the leg sends a Report-ID-prefixed report until
  `SET_PROTOCOL` arrives, and on the pre-fix image it reproduces the exact
  symptom (`mouse_btn` = the ID, `dx` = the button byte). `stallproto` guards the
  fix's own hazard: `nak` cannot tell a STALL from a NAK, so the status stage is
  unrolled rather than looped, and `n_reset` staying at 2 asserts that no
  watchdog re-enumeration happened.
  **Mutation `F1` is the only one in the tree that reaches a ROM image** — it
  rewrites `mem/usb_hid_host_rom.s` and reassembles. Worth copying wherever a
  generated image carries behaviour: no rewrite of any line of Verilog could
  have expressed this defect, so the RTL mutations were all green while the
  firmware was wrong.
  **Its sharpest property is one the design cannot check anywhere else.** The
  host computes no CRC and verifies none — every token and DATA0 it sends is a
  literal byte string with a pre-computed CRC in the 668×4 microcode ROM, and it
  ignores the device's CRC16 entirely. The model therefore checks *the host's*
  CRCs, which makes this the only thing in the tree that can notice a corrupted
  or mis-assembled `mem/usb_hid_host_rom.hex`. Every packet the host actually
  emits is checked on the wire — three token CRC5s (addr0/ep0, addr1/ep0,
  addr1/ep1) and four DATA0 CRC16s (GET_DESCRIPTOR config, SET_ADDRESS,
  SET_CONFIGURATION, SET_PROTOCOL); the fifth DATA0 literal in the image,
  GET_DESCRIPTOR(device), sits behind a commented-out call and was matched by
  independent computation instead. Both CRCs need a bit-reversal against the
  register value, because USB sends a CRC MSB-first — established by computing
  every literal independently, so the reversal is the wire convention and not a
  fudge factor.
  **Two contracts for the consumers came out of building it.** `mouse_dx/dy` are
  valid only **at** the report pulse — the wrapper zeroes them the cycle after —
  so the Марсианка adapter must accumulate at the strobe, while `mouse_btn` is a
  level and does not clear; both directions are pinned, and mutation `U7`
  guards it. And `MS_TICKS` (hook H6, the "1 ms" tick lifted to a parameter so
  the legs do not each cost 250 ms of simulated time) **must be odd**: the tick
  is one clock wide but `ukp` evaluates an instruction every *second* clock, so
  an even value phase-locks and a `wait` sits through hundreds of ticks —
  upstream's 12001 is odd for exactly this reason. The `slow` leg runs at that
  real value so the scaling in the other five is never taken on trust.
  **What it deliberately does not pin** is in its README: the pads (hardware,
  checked by increment 0's LED diagnostic on the board), full-speed rejection (a
  full-speed device pulls up D+ and is invisible rather than mishandled, so
  there is nothing to assert), the single-flop pad sample, and the `ukpstb`
  phase *within* a byte — that last one is genuinely unobservable, the same
  shape of finding as `N_VREG`, so `U12` targets the byte alignment instead.
- `sim/mouse/run.sh` — the **Марсианка mouse** oracle, **five legs,
  mutation-tested x13**; `sim/mouse/README.md` carries the pinned contract. The
  one oracle in the tree whose reference is a **schematic** rather than an
  emulator: BkEmu has no mouse and GID's implementation is disavowed by its own
  documentation, so the УВК-01 sheets decide. It asserts the OPPOSITE of GID on
  two points — nothing arms a read (the NAND outputs are unconditional), and
  СБРОС is a **level** that holds the latches cleared rather than an edge.
  Legs: `sticky`, `reset`, `step`, `buttons`, `gate`.
  **It has already earned its keep.** The first version of the step divider
  carried a multi-step accumulator backlog; because a binary sticky latch cannot
  tell five encoder transitions from one, that made a single flick keep
  re-latching for eight polls and it surfaced as a **phantom DOWN on an X-only
  movement**. The `step` leg now pins both halves — the sub-step remainder IS
  kept, and a large delta leaves NO backlog. The same pass found the `~rst_lvl`
  guard on the latch sets to be dead code (the trailing level clear is a later
  assignment and always wins, exactly as the ТМ2's async R beats its clock).
  **The bus side is deliberately elsewhere**: `mouse_word` is OR-ed into
  `joy_word` at the TOP level, so `qbus_mem` is untouched by the feature and its
  goldens stay byte-identical; the read path stays pinned by `spk_capture_tb`
  section 10 and `sim/smk` section 2. Also not pinned here, and said so in the
  README: which write bit is СБРОС (the sheets give connector pin 9, not the
  cable's mapping onto port output bits — `RST_BIT`), and the *feel* of `STEP`,
  which is a hardware calibration rather than a contract.
- `sim/gamepad/run.sh` — the **USB gamepad** oracle, **one leg,
  mutation-tested x22**; `sim/gamepad/README.md` carries the pinned contract.
  `bk_gamepad` is the USB twin of `bk_joystick` — a pure level translator whose
  word is OR-ed into `joy_word` at the TOP level, so `qbus_mem` is untouched and
  every golden stays byte-identical. The leg walks all ten host outputs onto
  their BK bits (the remap is the error surface: the host says `l/r/u/d`, the BK
  word is `U,R,D,L`), pins the button folding (X and the R shoulder trigger onto
  A, Y and the L trigger onto B), and checks the upper byte
  on EVERY edge — player 2 must be unreachable by any input combination, not
  just the ones a section drives.
  **Two of its properties are load-bearing and each came from a surviving
  mutation**: every input starts HELD at t=0 (the state a board powers up into
  after a pad was used and unplugged, since the host never clears `game_*`) and
  `clk` takes its first edge BEFORE `usb_clk` (the two dividers have no defined
  start order, so the BK side can sample before the USB side has run). With the
  inputs released instead, a wrongly-armed flop leaks a zero payload and looks
  correct.
  **The typ exclusion is pinned from both ends**: section 2 here requires
  `typ` 0/1/2 to contribute nothing to `pad_word`, and `sim/mouse`'s `gate` leg
  requires `typ` 3 to contribute nothing to `mouse_word`. The report DECODE is
  not this oracle's job — `sim/usb`'s `pad`/`pad_real` legs own it.
  **It has already earned its keep — from the board, not from review.** With
  nothing pressed, BK bit 6 flickered at random on hardware and not on a PC.
  Two causes: the payload was *sampled* rather than latched at the report pulse
  (`game_*` are levels only BETWEEN reports — the wrapper rewrites them byte by
  byte over ~43 µs), and, because this host checks **no CRC**, a single frame
  corrupted on the wire was decoded as a real report. The decode surfaces that
  as phantom BUTTONS first, since a direction needs an exact byte value while a
  button is an unvalidated single-bit pick — on the reference pad a one-bit-early
  slip fires `game_y` alone, which is exactly BK bit 6. Sections 7b and 7c are
  the regressions, `G7` (filter removed) and `G10` (sampled not latched) the
  mutations. 7c injects an **arbitrary** bad frame rather than modelling the
  corruption, so it holds whatever the cause turns out to be, and it also
  requires a genuine repeated change to still land.
- `sim/run_clkgen.sh` — the Phase-7 `cpu_clkgen` unit oracle: BK-0010 (/32)
  mode **bit-identical** to a replica of the pre-Phase-7 `divc[4]` tap
  (enables included), the /24 BK-0011M rate exact, and a retarget sweep (no
  half-period outside **8..16** sys_clk). The SoC tbs replicate the divider
  locally, so this is the only sim coverage of the real chain. **Leg D is the
  Phase-9 turbo rate** (/16 = 6.04 MHz): the steady half-period exact, turbo
  OVERRIDING the model select both ways, and — because turbo is a LIVE control
  unlike the DCLO-latched model — turbo flips at every count phase plus
  turbo×model cross-flips. `dut0` has turbo tied 0 at the port, so leg A's
  BK-0010 bit-identity is preserved by construction.
- `sim/run_mapper.sh` — the Phase-7 `mem_mapper` unit oracle: BK-0010 mode
  swept over **all 64K addresses** against the pre-Phase-7 inline decode
  (before AND after banking writes — bk10 decode must be map-content-
  independent), plus the full BK-0011M banking contract (window pages, the
  four ROM overlay codes, the & 0o033-quirk fall-through, word-write-only
  banking, `bank_wr` mutual exclusion, DCLO-only re-init, model_bk11 flips
  keeping register content). **Phase 8 (SMK512):** a differential smk_en=0
  reference instance pins every non-SMK configuration bit-identical over
  full-64K sweeps (smk_en=0 both models, disabled-time 177130 writes never
  snooping) and the SMK-live low 32K (000000-077777) identical in BOTH
  models, plus the directed BkEmu
  `SmkMemoryManager` contract: the 177130 two-phase strobe (arm/commit
  edges, re-arm-not-commit, byte-lane masking incl. the junk-low-lane
  vector), the 8-mode × 8-seg table with the SYS/ALL +4 rotation, the
  `{v0,v3,v2,v10}` page scatter, HLT10 seg-0 `smk_ro`, std segs tracking
  live banking, register-file mutual isolation, DCLO-only reset (armed
  strobe cleared), enable/model flips keeping content. **Increment 2 (BIOS
  ROM):** the rom6/rom7 BIOS windows (SYS/STD10/STD11 vs SYS-only; ONE
  shared 2048-word image at `SMK_BIOS_BASE`, rom7 spanning the whole
  segment incl. the register space — the 177716 boot overlay, 177130
  included on the READ side under SYS), and the per-mode seg-7 restricted
  extent 0177000–0177777 (ALL readable/`smk_ro`, HLT10/HLT11
  writable/`smk_wo`, others capped → MK_NONE, boundary exact at 177000).
  **Mutation-tested ×10** (increment 1: scatter swap, arm-edge commit, cap
  drop, lane-mask drop, mode-mask break; increment 2: rom7 drop, rom6/rom7
  selection swap, extent direction swap, extent boundary off-by-one, wrong
  BIOS base bit — all fail). **bk10+SMK (S2 + S11):** the whole 8-mode x
  8-segment table walked from BK-0010 — the monitor ROM at segs 0,1 in
  SYS/STD10/STD11/RAM11 (`mon_en`), the ex-BASIC region MK_NONE wherever
  the SMK does not cover it, HLT11 the one mode where `mon_en` shows (segs
  0-3 dead), HLT10's seg-0 `smk_ro` + the 177674/76 write-only extent, the
  page scatter and rotation shared with bk11 across a model flip, and
  DIP-8-off returning the plain bk10 pass-through (**+5 mutations**: drop
  `mon_en`, widen `std_vec` in bk10, force segs 0/1 to MK_NONE, restore the
  `model_bk11` gate on `smk_act` / on `smk_reg_wr` — all fail).
- `sim/smk/run.sh` — the Phase-8 SMK512 SoC **functional** oracle
  (data-checking, sim/bk11 conventions: pinned parks 001004/001012, vector
  4 → fail, `COSIM PASS`): the `mem/gen_smk_test.py` program **boots
  through the REAL SMK mechanism** — the tb preloads a synthetic BIOS image
  (`smk_bios.hex`) at `SMK_BIOS_BASE` and NOTHING in SMK RAM; the SYS rom7
  register-space overlay makes the initial-start 177716 read return
  `bios[0o7716] | SEL1` → PC 166400 in the rom6 window — and walks the
  whole contract on the real SoC stack (smk_en=1, /24 rate, port-2
  contention, a **1<<19-word sdram_model**): the 177130 write reply +
  no-commit-without-arm, the BIOS windows (one image both windows, writes →
  trap 4, 177130/177132 reads replied everywhere — the КНГМД stub: BIOS
  word merged under SYS, 0 elsewhere), the I/O-page
  OR-merge — **also the joystick oracle's gate leg**: with a non-zero
  `joy_word` tied on, 177714 must read BIOS **|** the joystick word, 177776
  BIOS **alone** (that is the `!sel2_n` gate on `io_word`) and 177716
  masked-merged from the nSEL1 arm — with
  the kbd (177660 → trap 4) and vm1-internal (177712 self-served, X-monitor
  tripwire) carve-outs, SYS/RAM10 fill/verify with cross-mode aliasing, the
  ALL +4 rotation over all 8 segs, pages 2 and 8 end-to-end, **executing
  FROM SMK RAM and switching the mode under the running code** (the routine
  is program-copied into seg 2 — no tb preload), RMW in SMK RAM, HLT10
  seg-0 read-only (write AND RMW-write-half → trap 4, value intact), the
  per-mode extents (HLT10 writes replied incl. 177674/76 + reads trap; ALL
  reads the HLT-written words back via the seg-3 mem aliases + writes trap;
  STD10 capped), a COMMITTED SYS re-selecting both windows, STD11 std
  passthrough (win-1 banking + overlay + top ROM + a masked 177662 write +
  160000 = BIOS shadowing MSTD), the RESET instruction preserving the
  layout, the **authentic СТОП/HALT-entry leg** (HLT10: the program plants
  the HALT vector in SMK RAM seg 6, the tb pulses key_stop, the vm1's
  PSW/PC stores land in the writable extent, the handler verifies the
  stored PC via the ALL alias), then a **tb DCLO replay**: the second boot
  re-runs the real boot mechanism and re-verifies SYS + BIOS windows
  restored + SMK RAM content survived + the 662 taps back at defaults.
  **A SECOND LEG (`--bk10` / `+bk10`) re-runs the whole contract on a
  BK-0010 stack** (model_bk11=0, /32 rate, the program resident in the
  machine's own RAM at SDRAM 0x0000, SYS_START = 0100000): the monitor ROM
  at segs 0,1 (read + write-traps) in SYS/STD10/STD11/RAM11, the ex-BASIC
  region dead in STD11/RAM11 (a tb marker at SDRAM 0x5000 must never show),
  HLT11's `mon_en` kill, RAM11's mixed layout, and the BIOS's own
  MODEL-DETECT mechanism (a SYS 177662 write must trap on a bk10 — the tb
  additionally requires the 662 taps still at their DCLO defaults at the
  park).
  **Mutation-tested ×8 at the SoC level** (see the run.sh header — incl.
  the increment-1 documented masked mutation, now KILLED by the reworked
  issued-legs done-gate).
- `sim/ide/run.sh` — the Phase-8 **SMK512 IDE unit oracle**: `src/peripheral/smk_ide.sv`
  (the task-file register block + ATA engine + AltPro geometry parse)
  driven with Q-bus-shaped transactions against the behavioral
  `ide_disk_model` loaded with `mem/gen_ide_image.py`'s synthetic AltPro
  image (C/H/S 10/4/16 = 640 sectors, valid sector-7 partition table +
  checksum). Transcribes **BkEmu `IdeControllerTest`** + the
  `SmkIdeController` bus packing: the reset snapshot through the ~
  inversion (plus one raw-inversion pin so a dropped inversion can't
  cancel out), SRST assert/release, the absent slave (bus 0xFFFF, command
  writes ignored), the 740/742 exact-byte-address lane rules (COMMAND only
  at 177740; control register only via byte 177743), DHR |0xA0 forcing,
  IDENTIFY with the full word map + the per-word 0x58-during/0x50-after
  status contract, single-sector READ of **every** sector with an
  explicit per-sector CHS (the wrap boundaries data- and register-checked;
  **last-read semantics** — a command leaves the registers on the sector
  it just transferred, so there is NO cross-command auto-advance, and a
  repeat READ with unchanged CHS re-reads the same sector — the leg-5
  regression), multi-sector chains
  (COUNT=0 ⇒ 256), WRITEs verified against the model's backing store + a
  read-back round trip, ABRT for unsupported opcodes AND the LBA bit (the
  documented CHS-only deviation), data hold across the DIN window, and
  the geometry legs (valid parse; broken checksum ⇒ raw defaults 63/16;
  default C = total/1008 == 0 ⇒ attach fails, drive absent). **Tier-1
  prefetch legs (6b/6c/6d):** 6b a COUNT=4 chain data-exact with a
  mid-drain SNUM read pinning the visible CHS at the CURRENT sector in
  transfer (never advanced early at a prefetch's own bk_done), no BSY window at the boundary (disk pass), and
  exactly one backend op per sector (`ack_cnt`); 6c (disk pass) a slowed
  backend so the drain outruns the prefetch → a real BSY window then the
  swap DRQ; 6d the E_FLUSH mid-command interlock — a fresh COMMAND, an
  SRST, and a WRITE each dispatched while a prefetch is in flight, all
  recovering data-exact (the WRITE's backing-store check catches fill
  words dropped into a backend-owned port). An `overlap_seen` spy asserts
  the overlap actually occurred. **Mutation-tested ×14** (see the run.sh
  header — inversion drop, packing swap, lane rule, E_DRAIN swap-branch
  removed, CHS off-by-one, 1-based snum drop, checksum bound/seed, 0xA0
  drop; + prefetch 10–14: bank-invert drop, unconditional swap, flush
  removed, CHS-at-prefetch-done, scount-guard drop — all fail).
- `sim/ide/run_soc.sh` — the Phase-8 **IDE SoC functional oracle**
  (sim/smk conventions: real boot mechanism, /24 rate, port-2 contention,
  parks 001004/001012, `COSIM PASS`): the `mem/gen_ide_test.py` program
  drives the task file through the real qbus_mem reply machinery — the
  SYS rom7|device OR-merge at 177752 (both contributions visible in one
  exact compare), IDENTIFY/READ/WRITE end-to-end with the **BSY commit
  phase**, ABRT + LBA + SRST recovery, the **HLT10 write-only-extent
  broadcast** (a task-file write lands in SMK RAM AND the device; the
  read back rides the sel_ide-only reply), the ALL-mode seg-3 alias
  readback + extent|device merged read, and the absent slave.
  **Mutation-tested ×3 at the SoC level** (run_soc.sh header: qbus_mem
  merge-term drop, write-claim drop, command lane swap — all fail).
- `sim/ide/run_sd.sh` — the increment-(b) **SD backend unit oracle**:
  `src/peripheral/sd_backend.sv` (the SPI-mode SD host serving the backend sector
  port) against the protocol-checking `sd_model.v` card (CRCs, CMD55
  pairing, SDSC 512-alignment, init ordering — card protocol errors
  fail the run) loaded with the same AltPro image. Legs: the exact
  init transcript (>=74 dummy clocks, CMD0/CMD8/ACMD41-with-HCS/CMD58/
  CMD16-iff-SDSC/CMD9) for BOTH personalities (SDHC/CSDv2 and +sdsc
  v1/CSDv1 — both capacity formulas land exact in bk_total), reads
  data-exact incl. past-image sectors, oob completing with ZERO SPI
  traffic, write/store-check/readback, and the +noinit/+rderr/+wrrej
  injection legs — at the REAL dividers (/256 init, /8 data). **Leg 4 is
  the warm-reset recovery leg:** `rst_n` is pulsed with the CARD LEFT
  UNTOUCHED (what DCLO does on the board), landing MID-single-block-read,
  so the card still holds ~half a block that the preamble must flush
  before CMD0 — and that sector deliberately opens with a long 0xFF run
  (what a BK disk really looks like on the card, since the IDE layer
  inverts), which is the case a flush that stops when the bus merely
  LOOKS idle gets wrong. The leg also asserts `dbg_retried == 0`: ONE
  recovery pass must suffice, so the automatic retry cannot hide a weak
  recovery. Two injection runs cover the retry itself — **`+cmd0busy`**
  (the card answers no CMD0 for 25 ms; only a host that re-runs its
  WHOLE recovery between attempts outlasts it) and **`+cmd8junk`** (an
  SDHC card whose first CMD8 answers illegal-command: a host that only
  retries CMD0 types it v1, sends ACMD41 without HCS and stalls forever
  — the mechanism that made the board need two reset presses).
  **Mutation-tested ×14** (run_sd.sh header:
  SDSC ×512, CMD8 CRC, HCS, capacity off-by-one both formulas, LE byte
  swap, commit settle, R1 poll, oob guard, dummy clocks; + the recovery:
  preamble removed, flush removed, flush exits early, recovery not
  re-run, CMD0-only retry — all fail). The preamble's 0xFD/CMD12 pair is
  deliberately NOT mutation-covered, and the header says so out loud:
  since the revert nothing in this design can open a multi-block stream,
  so no leg can kill their removal — they are insurance against a card
  left streaming by other firmware. `sim/ide/run.sh`
  additionally re-runs the ENTIRE smk_ide_tb leg set with `-DSD_STACK`
  (`sd_harness` swaps the disk model for the real sd_backend+sd_model
  stack; sim-speed /2 dividers there — the ratios are run_sd.sh's job;
  +sdsc because CSDv1 encodes the tb totals 640/2016 exactly) — the
  decisive engine+backend integration pass. It earns that name: it is
  what caught the `enable_q` reset-value bug (an enable registered for
  timing reset to 0, so S_SETTLE's first evaluation parked the backend
  in the DEAD-END `S_DISABLED` state on every reset, card present or
  not) after run_sd.sh alone had been run and passed.
- `sim/bk11/run.sh` — the Phase-7 BK-0011M SoC **functional** oracle, **three
  legs since Phase 9** (authentic /24, `+turbo`, `+turboflip`): the whole
  contract below must pass unchanged in turbo — only the timing may move, so a
  failure there means the reply-owner switch is wrong, not slow — and
  `+turboflip` bangs on F12 THROUGHOUT the run, which is the only leg that can
  kill a mutation of `turbo_ctl`'s bus-idle qualification (an unqualified swap
  drops a reply mid-cycle → qbto → trap 4 → the vector-4 fail park). Note §12's
  no-retro-fire guard now counts **SYNCO rising edges** since the unmask rather
  than sys_clk: "the next SYNCO edge" is the actual contract and how far away
  it is depends on the raster phase the program reaches the unmask at, so the
  old 512-sys_clk threshold was only ever a proxy for one CPU rate (a turbo leg
  lands a perfectly legal edge at ~502). Teeth-tested: the combinational-gate
  mutation still fails it at 34 sys_clk / 0 edges.
  (data-checking, NOT a timing golden — ref037 keeps the timing-reference
  meaning): the `mem/gen_bk11_test.py` program (pinned parks: success
  **001004**, fail **001012**; vector 4 → fail) boots from the EXT window on
  the real SoC stack at the /24 CPU rate under port-2 contention and walks
  the whole Bk11MemoryManager contract: fill/verify all 8 pages through both
  windows, page-6 aliasing both directions, **RMW in EXT** (the one bus path
  with no bk10 coverage — the CLAUDE.md RMW rule), ROM overlays +
  write-ignore, the 033 quirk, fixed top ROM, **RESET-instruction preserves
  the map**, the write-only map register, the **177662 video register**
  (word writes replied + RESET-preserved — the tb checks the `vid_*` taps
  against the DCLO defaults and the final write — and the read side proven
  un-replied via an in-program vector-4 detour), and the **EVNT/IRQ2 frame
  interrupt** (section 12: the 662 bit-14 mask gates the already-asserted
  vgate level, then one vector-0100 fire per blanking window + a double-fire
  grace check; two tb assertion guards pin every nIRQ2 assert inside the
  vgate window AND never-while-masked — the program alone can't catch a
  broken gate: the vm1 arm/fire detector never sees a deassert then, so the
  first fire just slides to the second frame and all CPU-side checks pass),
  and the **СТОП-enable bit** (section 13: the tb pulses `key_stop` on a
  magic scratch write into the ocbk_top replica — gated 64-clk nIRQ1
  one-shot; enabled СТОП takes the authentic HALT-entry-timeout → trap-4
  path even at PSW prio 7, blocked must not fire in a bounded window,
  word/odd-byte writes reach the latch, even-byte/banking writes don't,
  RESET preserves it; the trap-4 frame is NOT RTI-able — the aborted HALT
  entry pushes a mid-instruction PC — so the handler continues via R0).
- `sim/romwr/run.sh` — the ROM-write-timeout functional oracle, **two legs
  since Phase 9** (authentic /32 and `+turbo`); the turbo leg is the sharpest
  test of the turbo `selected` change, because the program's whole point is
  that RAM and ROM must behave DIFFERENTLY in the same FSM — the conditionless
  clear marches out of RAM (which qbus_mem must now reply to) into ROM (which
  must still get no reply), so a wrong term either hangs the clear or ends it
  early. (BK-0010 SoC
  stack, data-checking, `COSIM PASS` at the pinned success park like `sim/bk11`).
  Proves a write to ROM gets NO reply → qbto → trap 4: the **conditionless
  "write until trap 4" screen-clear** (a counter-free `CLR (R0)+` marching into
  100000 — only the trap ends it; RAM cleared, ROM word unchanged) and an
  **INC @#100000 RMW** whose write half must trap while its read half replies.
  Both are **mutation-tested** (reverting the `selected` change hangs the clear;
  the RMW leg also proved the S_REPLY refinement unnecessary — the DATIO gap
  already drops the read reply). The gen program is `mem/gen_romwr_test.py`.
- `sim/evnt/run.sh` — the Phase-9 **EVNT/IRQ2 detector oracle** and the
  authority on `src/peripheral/bk_evnt.sv` (the authentic D28+D3:B missing-pulse pair off
  the 037's WTI/SYNCO pins). Contract = the `sim/ref014` shape: the vendored
  **reference** netlist `sim/ref037/va_037.v` generates `golden_evnt.txt`, and
  the retimed `src/bus/va_037_sync.sv` must reproduce it line-for-line (it does,
  byte-identically). Three legs in one transcript — **L1** full screen
  (assert = VGATE rise + **452 CLKIN**, deassert = VGATE fall + 452 CLKIN,
  every frame), **L2** 1/4 screen (WTI stops after 64 displayed lines, so the
  request fires **during active video**, ~129 lines early), **L3** mask
  semantics (masking clears at once; **unmasking must NOT retro-fire** — it
  waits for the next SYNCO edge). **Mutation-tested ×5** (`--mutate`: the
  old-qa propagation race, the WTI clear, the D3:B clock edge, irq_en as a
  combinational gate, the QA feedback — all fail). Mutations rewrite a *copy*
  of the real RTL via sed, so there is no inline replica to drift. See
  `sim/evnt/README.md`. **Never regenerate the golden from a va_037_sync run.**
- `sim/smktime/run.sh` — **slow (~1 min), not in `make sim`**: the Phase-9
  **SMK512 memory-access-time oracle**, i.e. the calibration of `N_EXT` and the
  regression that keeps it calibrated. Runs `test/sndtestsmk.bin` **verbatim**
  (the exact bytes measured on a real BK-0011M + SMK512) on the sim/smk SoC
  stack and reports the emitted tone: one half-period = 197 instruction
  fetches, all from the memory the loop is resident in, nothing else touching
  memory, so the frequency is a direct high-gain readout of that memory's
  access time — one unit of N moves it ~6 %. **Two legs, one image, two entry
  points** (byte-identical loop code, so the only variable is which memory runs
  it): the loop copied to 0140000 = **SMK RAM** (`MK_EXT`), and the CONTROL leg
  entered at START so the same loop runs in place in **ordinary RAM**
  (`MK_RAM037`, N_RAM=4 + the 037 steal — already calibrated, so it validates
  the clock rate and the access-count model and isolates any error to `N_EXT`).
  Goldens pin the per-instruction gap table (`LOOP addr n min max`), each
  half-period and the `EXTRD fast/slow` fallback rate; `dbg_romgate` must never
  fire. `--sweep` reproduces the N_EXT = 1..4 ladder from the RTL by
  sed-patching a *copy* of `qbus_pkg.sv` (the `sim/evnt` idiom). Run it
  whenever `N_EXT`, the `qbus_mem` reply FSM or the `cpu_sdram_dp` issue path
  changes. **Mutation-tested ×5** (see the run.sh header).
  **Two Phase-9 TURBO legs** (`+turbo`) make this the speed MEASUREMENT for
  turbo mode as well — there is no real machine to compare against, so they are
  a regression on the speed-up, not a calibration. The ordinary-RAM leg is the
  one that matters (its loop is `MK_RAM037`, so it reads out both halves of the
  feature at once): **4184 → 3527.8 cycles, 481.2 → 856.1 Hz, 1.78x**, and the
  per-instruction `LOOP` spread — which IS the 037 steal beat, a fetch landing
  at different phases of the 8-CLKIN grant slot — collapses from min=20/max=26
  to min=18/max=19, every other instruction in the loop going exactly flat. The
  residual 1 is not arbitration but the done-gate, routine by design at
  `N_TURBO` = 2. A turbo golden showing a spread of ~6 again would mean
  `no_steal` is not reaching the arbiter. **The SMK-RAM turbo leg is what found
  that `N_EXT` = 1 cannot survive /16** — it tripped `dbg_romgate` on its first
  fetch — which is why `turbo_mem` covers MK_EXT too.
- `sim/vregtime/run.sh` — **slow (~1 min), not in `make sim`**: the Phase-9
  **177662 write-time oracle**, same shape as `sim/smktime` on a stock
  BK-0011M stack (smk_en=0, /24, port-2 contention, boot via the top-ROM
  stage-0 stub). `test/sndtest662.bin` (`mem/gen_vreg_test.py`, the same bytes
  a real machine would run) puts **192 writes in each tone half-period** — 8
  unrolled `MOV R1,(R0)` × 24 SOB iterations — with two entry points and a
  byte-identical loop whose only difference is R0: the writes go to **177662**
  or to a **scratch word in RAM** (`MK_RAM037`, the hardware-calibrated
  control). The `LOOP addr n min max` table is the sharp output — eight
  identical instructions, so min/max there *is* the cost of one write.
  **It was built to test the hypothesis that `N_VREG` caused the beam-raced
  palette skew, and it FALSIFIED it**: `--sweep` gives bit-identical cycle
  counts for N = 1..4 (see the `N_VREG` note in the 177662 bullet). What the
  golden pins is therefore the fetch path + 037 steal (the control leg's
  min ≠ max is that beat) plus the `VREGWR fast/slow` line, which is the one
  thing that moves when the reply FSM changes. `--regen` regenerates.
- `sim/grantfit/run.sh` — **slow (~30 min for `--sweep`), not in `make sim`, and
  NOT an oracle — a measurement bench.** The Phase-9 037 **grant-rule** study:
  it runs every tracked tone image (`test/sndtest*.bin`, consumed verbatim via
  `mem/gen_tone_test.py`) on the real SoC stack and tabulates it against the
  real-BK-0011M readings — **four legs that must MOVE and three that must
  NOT**, because both earlier arbiter experiments were judged on one leg and
  wrecked another. `tone_tb.v` is the sim/vregtime stack with sim/smktime's
  SMK option folded in (`+smk`, `+bk10`, `+image/+entry/+loop_lo/+fetch_*`);
  `patch037.py` builds candidates by ANCHORED rewrites of a **copy** of
  `src/bus/va_037_sync.sv` (the sim/evnt idiom — it fails loudly if the RTL moved,
  and every register it adds is reset or RASEL goes X and the sim hangs). The
  D8:B candidate is a tb plusarg, not a patch: it is a BOARD chip the 037
  netlist does not contain. **`real` is normalised at 4.000 MHz** — see the
  warning in its header about the second normalisation in this file. The
  baseline reproduces eight independently-derived numbers; if it ever stops,
  suspect the bench before believing the result. See the beam-race bullet for
  what it found.
- `sim/raminit/run.sh` — the Phase-7 `ram_init` unit oracle (the authentic
  DRAM power-on pattern filler): drives ram_init through a served-mask-honoring
  grant model and checks, per fill pass, the exact per-model word pattern
  (bkemu-QT `InitMemoryValues`: bk10 `idx[0]^idx[6]` with a 64-word phase flip,
  bk11 `idx[3]^idx[6]`; the tb is an independent literal transcription of the C
  loops), the contiguous address
  walk over the model's RAM range (bk10 0x0000–0x3FFF / bk11 0x20000–0x2FFFF),
  the served-mask ≥1-cycle req gap, the trigger (power-on fill, NO re-fill on a
  same-model reset, re-fill on a model change), and `blank_pulse` (silent on the
  first fill, one pulse per re-fill). **Mutation-tested** (wrong pattern bit /
  no gap both break it). The SoC-integration side is covered by
  `sim/run_boot_check.sh` (real MONITOR/BOS cold-booting on the pattern) — the
  replica preloads the pattern rather than running ram_init through the
  boot-writer port (that datapath is `run_epcs_boot`'s).
- `sim/run_epcs_boot.sh` — the EPCS loader unit cosim (flash model →
  `epcs_boot` → arbiter port 0 → SDRAM), **three legs**: the clean run loads
  BOTH blobs (Phase-5 bk10 at flash 0x40000 → SDRAM words 0x4000+, Phase-7
  bk11 at 0x48000 → 0x30000+) and word-exact-verifies both regions;
  `+corrupt` (first blob) and `+corrupt2` (second) each must end
  `boot_ok=0` — `+corrupt2` also re-checks the bk10 region is intact
  (two-pass independence).
- `sim/run_sdram_cosim.sh` — the Phase-2 `qbus_sdram` slave (word/byte datapath +
  deterministic RPLY). Runs the `--core-only` ROM (no picture draw — hours slow).
- `sim/run_video.sh` — palette unit tb (slot/bit conventions + all 16
  BK-0011M palettes against an independently hand-transcribed expected
  table — a swizzle bug in the RTL cannot cancel out); `fb_video_tb` (FB
  words vs a tap-driven expected model, mid-frame scroll, M256, and the
  Phase-7 frame D: fetch from the page-7 `vram_base` with palette 11);
  `vga_out_tb` (timing geometry + pixel-exact readout, physical-colour
  decode); `video_pipe_tb` (full chain, every active pixel at the DAC vs a
  Python-rendered frame of the **shipped** picture).
- `sim/video/run_draw_check.sh` — **slow (~10 min), not in `make sim`**: proves
  the ROM's hand-assembled PDP-11 draw code writes exactly `render_image()`.
  Run it whenever `mem/gen_mem.py`'s program or picture changes.
- `sim/run_boot_check.sh` — **slow (~7 min), not in `make sim`**: cold-boots the
  real MONITOR ROM on the full SoC; checks no bus-contention X and that the
  screen clear starts; dumps `sim/boot_trace.txt` (bus R/W trace) for manual
  diffing against a BkEmu-side trace when debugging boot problems. With
  `+warmreset` (~14 min) it also re-pulses DCLO/ACLO mid-screen-clear and
  requires a second 177716 start-vector read + a second screen-clear burst —
  run it when touching reset/DCLO plumbing. **`+bk11`** (Phase 7) instead
  cold-boots the real BK-0011M BOS (model_bk11=1, /24 CPU clock, the bk11
  blob preloaded at SDRAM 0x30000+, the 177662→fb-base/palette + EVNT/IRQ2
  ocbk_top mux replica): the first 177716 read must reply the 140000 start
  vector, then BOS activity = a 177662 write + the screen-clear burst, no X
  (`+warmreset` is bk10-only). `VID_TARGET`/the 60 ms bound are noted
  tunables if BOS's real startup profile needs them. **`+smk`** (Phase 8)
  cold-boots the real SMK512 BIOS: the +bk11 stack with smk_en=1 and the
  43008-word blob (BIOS at SDRAM 0x3A000) — since the IDE increment plus
  the **live `smk_ide`** fronted by the behavioral disk model loaded with
  `gen_ide_image.py`'s AltPro image; requires the merged 166400 start
  vector (the SYS rom7 register-space overlay | SEL1; the raw word also
  carries the idle-kbd 0o100 bit — the PC masks with 177400), ≥200 DIN
  fetches from the rom6 window (the BIOS EXECUTING from ROM), and the
  BIOS's own **banner** (its 177662 write + the video-RAM burst — after
  its ~150 ms SOB startup delay, hence the 400 ms +smk time bound), no X
  with the sel_ide decode active. The BIOS's DRIVE probe is deliberately
  NOT required: smk64.mac (doc/) routes every boot path through INIT →
  EMT 0 = the full BOS re-init incl. the multi-second БК memory test
  before ZAGHDD/BOOT0 touch the task file — out of sim reach (the tb's
  `+fastdelay`/`+idetrace` debug aids exist for exploring that flow); the
  drive contract is `sim/ide`'s, and the real BIOS reading a real image
  was the increment-(b) hardware milestone — **achieved 2026-07-18**.
  **`+smk +sdspi`** swaps the disk model for the real
  `sd_backend`+`sd_model` SPI stack (a runtime mux in the tb): attach +
  the AltPro geometry parse ride the full card-init + SPI path under
  the real BIOS boot, same pass conditions. **`+turbo`** (Phase 9) composes
  with every other leg and runs it at /16 = 6.04 MHz with the 037 out of the
  RAM path: this is the only oracle that executes REAL MONITOR/BOS/BIOS code,
  so it is the one that answers "does a real ROM still boot when qbus_mem owns
  the RAM reply", which no synthetic program can. **`+smk10`** (bk10+SMK) boots
  the SAME real BIOS on a BK-0010 stack: model_bk11=0, the /32 rate, the
  bk10 ROM blob plus the bk11 blob for the BIOS image at 0x3A000 (both
  are flash-resident on hardware whatever DIP 1 says); pass conditions as
  `+smk` MINUS the 177662 write — on a BK-0010 that write must NOT reply,
  it is the BIOS's own model detect — and a 550 ms bound (the startup SOB
  delay at the slower clock). `+smk10 +sdspi` works too.

Any change touching the core, the Q-bus, memory, video, or clocking must keep all
of it passing. When tuning bus/RPLY timing, trace the **reference** waveform first
(instrument `cpu11/vm1/.../sim/bk10/bk10_tb.v`) — that is ground truth. Note the
golden checks *timing*, not write data — only the SDRAM/video cosims verify values.

