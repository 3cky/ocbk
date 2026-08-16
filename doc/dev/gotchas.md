# Gotchas (learned the hard way)


- **Quartus II 11.0 SystemVerilog is limited.** No `import pkg::*;` in a module
  header (put it in the body). It won't propagate `` `define `` across separately
  listed Verilog files, so the core's config selectors are set as global
  `VERILOG_MACRO` in `ocbk_common.qsf` (mirroring `src/cpu/vm1_config.v`, which the
  sim flow includes directly; the macros are `ifndef`-guarded to stay idempotent).
- **A wildcard-imported package parameter must never make its FIRST appearance
  inside a port-connection expression** (Icarus, cost half an hour in Phase 9).
  Written as `.fast_rd((N_EXT == 1) & sel_ext & ...)`, Icarus does not resolve
  `N_EXT` there — port connections are where implicit nets get created, so it
  silently declares a 1-bit **net** of that name, which then **shadows the
  parameter as X for the whole rest of the module**. Everything downstream
  (`(N_EXT == 1)`, `3'(N_EXT-2)`) evaluates to X, with no warning: the symptom
  was a wait FSM whose `wcnt` was X and which therefore never replied. Assign
  the expression to a named `wire` first and connect that. The same import also
  refuses a module-level `localparam` derived from a package parameter ("a
  reference to a net or variable ... is not allowed in a constant expression")
  — spell such expressions inline where they are used.
- **`vm1_simlib.v` is sim-only** (dual-write-port behavioural RAM → "multiple
  constant drivers" in Quartus). The FF register-file path
  (`CONFIG_VM1_CORE_REG_USES_RAM=0`) leaves that RAM unused, so the Quartus build
  uses the tied-off stub `src/cpu/vm1_vcram_syn.v` instead.
- **Open-collector RPLY combinational loop** — Quartus flags a benign 4–6-node
  loop where the CPU's internal-register reply and the slave wire-AND onto RPLY.
  Cosim-validated; clean fix (explicit wired-AND via `vm1_qbus`'s split
  `rply_in`/`rply_out`) deferred to peripheral work (Phase 6).
- **Mapper-to-bus-pad false timing loops** (Phase 8, learned the hard way):
  any COMBINATIONAL path from the mem_mapper translate (`kind`) into an `ad_n`
  output enable closes a loop through the on-chip wired-bus resolution network
  back into the mapper's own register-write snoops (`ad_true` data/enable
  pins). Functionally false — DIN and DOUT are mutually exclusive — but STA
  must see it met, and it broke sys_clk closure at −1.322 ns when the SMK512
  mode decode landed in that cone. **No SDC exception** (the SEED-3 rule: an
  exception is a fitter input); fixed structurally instead: the SMK mode
  table is pre-decoded at COMMIT time into `seg_*` registers (decode-at-commit
  ≡ decode-at-use — the regs change on the same sclk edge), and
  `cpu_sdram_dp.rdata_oe` gates on an issue-time `was_read` flag instead of
  the live `sel_ram||sel_romr` (behaviour-identical: the selects are
  SYNC-framed and stable by D_DONE; ref037's goldens pin the cycle identity).
  Rule: keep translate outputs out of pad-OE cones — register the selection
  at issue, never re-check it live at the drive point. **Phase 9 had to take
  that one level further** (2026-07-25): the loop came back as the worst
  sys_clk path (−0.023 ns) once the `N_EXT` work re-placed the fitter, so
  `rdata_oe` no longer decodes the FSM state either — the whole
  `(state == D_DONE && was_read && was_drive)` term is precomputed into the
  `oe_arm` flop at the transitions into/out of D_DONE (identical by
  construction: D_DONE is entered from D_RD_WAIT with was_read=1, from
  D_WR_REQ with was_read=0, and left only to D_IDLE), leaving
  `rdata_oe = oe_arm && !din_n`. Same rule, one level shorter.
  **Phase 11 found the rule applies to REGISTER-ENABLE cones too, not just
  pad-OE cones** (2026-07-31): the TurboSound increment's +1,183 LE re-placed
  the fitter and took the same cone to **−0.271 ns**, this time via
  `mem_mapper|rom6_en → cpu_sdram_dp|wdata_o[*]` — because `wdata_o`'s 16-bit
  load was gated on `is_write`, i.e. on `sel_ram|sel_ramw`, i.e. on the whole
  mapper decode. Cure: load `wdata_o` on **any DOUT while the FSM is idle**
  and let the FSM alone decide whether a request is issued. Behaviour-identical
  (`wdata_o` is read only while `req & we`, and `req` rises only on a
  transition out of D_IDLE), **−0.271 → +0.528 ns, −1 LE**. Generalised rule:
  **a translate output may decide WHAT to do, but must not be in the cone that
  decides whether a wide register LOADS** — register the decision or widen the
  enable to something structurally free.
  **Phase 12 hit the SAME rule a third time, in NEW code, across a module
  boundary** (2026-08-01): `bk_covox`'s mute-hold counter took its reload
  enable from `bk_turbosound`'s `ts_snd`, which was a combinational
  `(|lsum)|(|rsum)` — an OR-reduce of two 11-bit ADDER outputs — routed across
  the chip into the enable of 26 flops. **−0.639 ns, TNS −12.003**, the worst
  first-build number this design has produced. Cure, again structural and
  again free: make `ts_snd` a FLOP, fed by the same predicate taken one stage
  earlier off the PSG channel outputs. The fold is non-negative and monotone,
  so the predicate is identical, and the source registers load on the same
  edge — so the one-cycle LEAD the arbitration depends on is preserved exactly
  (`bk_turbosound_tb` checks it every cycle; mutation D14 is the late
  variant). **−0.639 → +0.102 ns, TNS 0.** The lesson to carry: **this applies
  to a signal you EXPORT, not just to one you consume** — a one-bit output
  looks free at the source and lands in someone else's enable cone.
- **A quasi-static signal with big fanout still costs real setup time**
  (Phase 8, fixed 2026-07-22). `model_bk11` (DIP 1, latched during a DCLO
  hold, frozen while the CPU runs) fans out across the mapper, clkgen,
  qbus_mem and the top-level video muxes, so the fitter routes it far;
  landing that route in the `bank_wr` AND tree that feeds `win0_page`'s
  next-state LUT made it the design's worst sys_clk path for three builds
  (+0.077 → −0.039 → −0.230). "It's pseudo-static so the violation is
  false" is TRUE but not a fix — it just re-litigates the same STA
  judgement call on every increment, drifting further negative as the
  design grows. **Cure: re-register the signal locally in the consuming
  module** (one flop; the long route becomes a plain flop-to-flop path and
  the logic downstream is fed from a flop the fitter places nearby). This
  is the same structural-not-SDC philosophy as the `wait_cnt` narrowing and
  the sdram_ctrl counter split — **never reach for an SDC exception**, which
  is a fitter input and has broken the SEED-3 boot before. Safe only where
  a 1-cycle latency provably cannot matter: verify the signal changes only
  while the consumer is in reset / the CPU is parked, and keep the raw
  signal on any cone whose oracle compares combinationally after a flip.
- **A COMPARE inside the enable cone of an I/O-ring register pays the full
  logic→ring route** (the joysticks, fixed 2026-08-02) — and the cone it bit is
  the dangerous one. +23 LE / +12 pins re-placed the fitter and took sys_clk
  setup **+0.471 → −0.121, TNS −0.361** on
  `sdram_ctrl|wait_cnt[1:0] → s_addr[6:4]`: the *same* cone as the Phase-7
  no-boot regression, where a setup violation corrupts the SDRAM ROM write and
  the board simply does not start — with `boot_ok` still green, because that is
  a flash checksum and not an SDRAM readback. **Narrowing the counter in Phase 7
  was necessary but not sufficient.** Even a 3-bit `wait_cnt == 0` was still
  *inside* the enable cone of `s_addr` / `s_dqm` / `dq_out`, which are I/O-ring
  registers placed far from the logic, so the compare paid the whole route.
  **Cure: move the predicate into its own flop.** `wait_zero` mirrors
  `wait_cnt == 0` but is computed on the **load** path — `(wait_cnt == 1)`
  before each decrement, a compile-time constant on every load — so the output
  registers see one register output and no logic at all. Cycle-identical **by
  construction**: every `wait_cnt` assignment has a mirrored `wait_zero`
  assignment, and the pairing is the invariant to preserve when editing that
  FSM. Result **+0.254, TNS 0**, and the critical path left `sdram_ctrl`
  entirely (`va_037_sync|A[13] → mem_mapper|ext7_w`, zero skew). Proof of
  cycle-identity: the 14 `ref037` golden legs byte-identical, `qbus_sdram`
  cosim latencies unchanged, and `sim/smktime` / `sim/vregtime` returning the
  *same measured numbers to the cycle* (21167 / 856.1 Hz, 28032 / 287.3 Hz).
  **CONFIRMED ON HARDWARE 2026-08-02** — the board boots and runs a game, which
  is the check this cone actually needs: last time it failed, STA was clean and
  the machine simply did not start.
  **The general rule: an `== 0` on a counter is cheap; an `== 0` in the enable
  cone of a pad register is not.**
- **The enable-cone rule bit a FIFTH time, and this one needed no pad at all**
  (`sdram_arbiter`, fixed 2026-08-06). Retuning `bk_mouse`'s `STEP_SHIFT` 3 → 2
  — a parameter in a leaf peripheral, +15 LE — took sys_clk setup
  **+0.146 → −0.015** on `fb_video|f_req → sdram_arbiter|cmd_wdata[0]`, a cone
  neither module is part of. The arbiter loaded its whole command payload
  (`cmd_addr` + `cmd_wdata` + `cmd_be` + `cmd_we` + `cur`, 42 flops) under
  `state == A_IDLE && any`, and `any = |(p_req & ~served)` includes port 3 =
  `fb_video`'s `f_req`. So a request line from the far side of the die sat in
  the clock-enable of 42 registers: 5 logic levels, **8.365 of the 10.382 ns
  pure interconnect**, LEs strung across X22..X29 / Y20..Y23. Note this cone
  reaches no pad — the earlier three cases all ended at an I/O-ring or exported
  register, and that is not the load-bearing part of the rule. **Cure: drop the
  `any` term from the payload load only.** The command registers are don't-care
  unless `cmd_req` goes with them, and `cmd_req <= any` still carries it, so
  enabling the payload on `state == A_IDLE` alone is behaviour-identical (`cur`
  and `cmd_we` are read only after the A_ISSUE transition, which only happens
  with `any`) and leaves the enable local to the arbiter. **−0.015 → +0.405 ns,
  −5 LE, TNS 0**, and `f_req` disappears from the timing report entirely.
  Cycle-identity: `make sim` green including `run_sdram_arbiter` and
  `run_sdram_cosim`. **The lesson to carry: the trigger and the fix live in
  different modules.** The peripheral parameter was not the bug — it was the
  +15 LE that exposed a latent enable cone, exactly as the "budget for an STA
  chase somewhere else" rule predicts. Chase the cone STA names, not the
  module you just edited.
- **…and a SIXTH time on the very next build, back on the pad cone**
  (`sdram_ctrl|ref_cnt`, fixed 2026-08-06). Reverting `STEP_SHIFT` to 3 while
  KEEPING the arbiter fix landed at **−0.011 ns, TNS −0.016** on
  `sdram_ctrl|ref_cnt[0] → s_addr[5]` — the Phase-7 no-boot cone for the third
  time, now via the *other* counter. `ref_cnt == 0` decides whether ST_REF_WAIT
  loads `s_addr <= MODE_REG`, so the compare sat in the pad register's
  `outclkena` and paid the whole logic→ring hop: **4.953 ns of the 9.580 in ONE
  route**, LC_X31_Y16 → IOC_X6_Y27. Cure: `ref_zero`, the exact `wait_zero`
  idiom applied to `ref_cnt` — mirrored on all three assignment sites (reset,
  ST_PRE_ALL, the decrement), `== 1` before the decrement and a compile-time
  constant on the two loads. **−0.011 → +0.118 ns, TNS 0, +4 LE**, and `s_addr`
  fell to +2.860. Cycle-identity is free here beyond the usual argument:
  `ref_cnt` is read only while `in_init`, so nothing after `init_done` can see
  it. **Two lessons.** First: **fixing one cone re-rolls the dice on every
  other** — the arbiter fix measured +0.405 at `STEP_SHIFT=2` and −0.011 at 3,
  from the same source tree. A single build's slack is a sample, not a
  property; at 75 % LE, judge a structural fix by whether the *cone* left the
  report, not by the headline number. Second: **when a counter compare shows up
  in a pad enable, grep the module for its SIBLINGS before rebuilding.**
  `wait_cnt` was fixed in Phase 7 and again for the joysticks, and `ref_cnt`
  sat one screen away in the same file with the same defect, waiting for a
  placement roll. `init_cnt` and `refi_tmr` are the remaining `== 0` compares
  in `sdram_ctrl`; both currently gate a state only, never a pad register — if
  either ever reaches `s_addr` / `s_dqm` / `dq_out`, it gets the same flop.
- **A SOURCE-LEVEL RE-ASSOCIATION WILL NOT MOVE A CRITICAL PATH — measured, and
  it cost a build (2026-08-16).** `audio_ns6`'s cone
  (`mixer|mix_l → ns6|errp`) went to **−0.072 ns, TNS −0.586** after an
  unrelated **+22 LE** elsewhere (the USB CRC16) re-placed the fitter. The
  natural cure looked like rewriting the shaper's 17-bit `accr = s_in + errp`
  as the two adds it really is — a 10-bit low half and a 7-bit high half joined
  by one carry, exact because `errp` is only 10 bits, and verified identical
  over the entire input space before being written.
  **It produced a BIT-IDENTICAL fit**: same 9,170 LE, same −0.072, same TNS,
  same cone. Quartus re-associates that arithmetic itself, so how an adder is
  *written* is not a fitter input at all. Same shape as the Phase-7 `epcs_boot`
  reset-value tweak that was a sim-proven no-op.
  **The rule: only a change to the REGISTER BOUNDARIES moves a critical path.**
  Re-writing combinational expressions, re-ordering operands or splitting an
  operator are invisible downstream of synthesis. The fix that worked was a real
  pipeline register between the mixer and the shapers, which also took the
  second 17-bit add (the CMT mono fold) out of the chain — two 17-bit adds and a
  compare in one sys_clk was the actual depth. → audio
  **Corollary when reviewing a proposed STA fix: ask which flop moved.** If the
  answer is "none", expect nothing — and never accept a slack improvement alone
  as evidence, because at this placement fragility an unrelated edit moves slack
  by half a nanosecond on its own.
- **A SINGLE-driver open-collector `tri1` net degenerates to stuck-ASSERTED in
  Quartus** (Cyclone I has no internal tri-state/pull-up). This bit the Phase-6
  keyboard on hardware: `bk_kbd014` was the *only* nVIRQ source, driving
  `virq_ff ? 1'b0 : 1'bZ` onto a `tri1` net. Quartus "Converted tri-state buffer
  ... `virq_n` feeding internal logic into a wire" and tied the idle Z to **0**
  (permanently asserted — `virq_ff` then "lost all its fanouts"), so the CPU saw
  a stuck VIRQ and hung the instant MONITOR unmasked (deterministic, no keypress;
  `pin_virq_n=1'b1` or masking cured it). **Every sim passes** — sim honours the
  `tri1` pull-up. Fix: a lone OC source must be **push-pull** (`assign virq_n =
  ~virq_ff;`, net a plain `wire`). The multi-driver bus nets (`ad_n`, `rply_n`)
  are fine — Quartus infers the wired-AND from the several Z-idle drivers (an
  OR-gate in the reports). **Rule: never leave a single Z-idle tri-state driving
  internal logic; if a second nVIRQ source is added (cartridge slot), OR the
  active-high asserts and invert at the top — do NOT go back to tri-state Z.**
  Guard: `grep 'Converted tri-state buffer' ocbk.map.rpt` should list only the
  genuinely multi-driven bus nets, never a peripheral's lone request line.
- **Pin-sync edges (1801ВМ1 doc): nIRQ1–3/nVIRQ must be asserted synchronous
  to the CPU clock rising edge, nRPLY to the falling edge.** The core samples
  all of them at `posedge pin_clk_p` with **no synchronizer flops**
  (`vm1_qbus.v` `rply_ack[1]`, `rq[]`, `irq2`/`irq3` edge detectors). RPLY
  already complies: `qbus_mem`'s wait FSM runs on `cpu_clk_n`
  (falling-edge launch); `va_037_sync` transitions land 1–2 sys_clk after a
  CPU edge (~300 ns setup, deterministic — same divider chain). Any Phase-6+
  interrupt source must put its final flop on `posedge cpu_clk` (2-FF resync
  first if it originates in `sys_clk`/`pix_clk`, e.g. EVNT from vsync) — an
  async assertion is a metastability *and* cycle-determinism hazard. Note the
  SDC false-paths all `sys_clk`↔`cpu_clk` paths, so these margins are safe by
  construction, not STA-checked — re-check at Phase-7 turbo rates.
  **Hardware confirmation** (`doc/bk0011m-sch.pdf`, sheet 1): the real board
  implements both rules as external chips on the CLC (CPU clock) net — D8:B
  (К531ТВ9 negedge JK, J=K̄ via D33:E = a pure D-FF) reclocks the wired-OR bus
  nRPLY onto the CPU's RPLY pin (Q̄→R28→pin 39; the CPU never sees raw bus
  RPLY, only its own internal self-reply bypasses it), and D11 (К555ТМ9 hex
  posedge D) re-times IRQ1–3/VIRQ *plus ACLO and DMR*.
  **D8:B IS NOW MODELLED — `src/bus/bk_rply.sv`, Phase 9 (2026-07-26)**, and it is
  half of the 037 grant-rule fit (see the beam-race bullet). The long-deferred
  worry that it "shifts ROM/IO by a full cycle and N_ROM would need
  recalibration" is resolved by scoping: it re-times **only the 037's reply**,
  because `qbus_mem`'s FSM already runs on `cpu_clk_n` and is therefore
  D8:B-correct by construction — every fixed-`N` slave already launches on the
  falling edge, and re-timing them again would double-count precisely the
  constants calibrated against hardware WITH this flop's contribution inside
  them (`N_EXT`, `N_VREG`, `N_KBD` = 1). So `N_ROM` did not move and no
  fixed-`N` constant needed recalibration. The 037 was the one path where the
  rule held only by accident of the divider phase — and at the /24 rate, not
  at all.
- **177700–177713 is CPU-internal** (with `pin_pa=00`): `vm1_qbus` decodes the
  block itself (`sel177x`), self-replies for all of 177700–177717 AND drives read
  data for 177700–177712 (CSR/error/`vm1_tve` timer). Nothing external may reply
  or drive there — the pre-Phase-5 `sel_io` did, a guaranteed `ad_n` fight the
  moment MONITOR touches the internal timer (no synthetic oracle program ever
  read those addresses, so only the real-ROM smoke cosim would catch it).
  177714/177716 stay externally served (the CPU's `ad_oe` excludes them). I/O
  stub semantics (177716 bit-2 write-flag, 177660 cold `0o100`) follow **BkEmu**
  (`~/projects/studio/BkEmu`) — the canonical BK behaviour reference.
- The `qbus_sdram` address latch is **transparent on the SYNC strobe** (as real bus
  hardware), so SYNC is a slow logic-derived clock; `ocbk_constrains.sdc` declares
  and cuts it. SDC node names use Quartus `entity:inst|...` form — verify with a
  `quartus_sta -t` script (`get_registers` / `get_pins`) before trusting a pattern.
- **WTBT is dual-purpose** on the Q-bus: at SYNC time it flags a *write* cycle, at
  DOUT time it flags a *byte* op. `qbus_sdram` samples the byte indicator live at
  the write point — do **not** reuse the SYNC-latched value for byte masking (that
  corrupts word writes; the cycle-count oracles never check write data, so it slips
  through sim silently — only the SDRAM cosim verifies values).
- **DATIO(B) read-modify-write cycles run DIN then DOUT under ONE SYNC** (INC/BIS/
  XOR/... on memory). A bus slave FSM must return to idle on *strobes-idle*, never
  on SYNC-rise — waiting for SYNC sits through the DOUT phase and silently drops
  the write (found on hardware: the test picture's XOR diagonal vanished while MOV
  bars worked; `cpu_sdram_dp` had exactly this bug). The oracle test programs
  originally contained *no* memory-RMW instruction, so nothing in sim caught it —
  the ref037 program + `golden_037.txt` and the gen_mem RAM test now include an
  RMW block with a value self-check (a wrong result parks at a distinct fail PC,
  which breaks the golden diff). Keep RMW coverage in any future bus-path oracle.
- **CDC for SDRAM — the "no interlock" worry is CLOSED; this bullet described
  the retired `qbus_sdram`, not the shipped path.** It used to say the wait FSM
  launched an access through a request-*toggle* into the `sys_clk` adapter and
  that a margin violation would latch stale data rather than extend RPLY, so
  the 4/6 MHz rates needed re-validating or a done-gate. Both halves are now
  wrong. **There is no such toggle** in the shipped design: `qbus_sdram` is out
  of the build (not in `ocbk_common.qsf`), and `qbus_mem`/`cpu_sdram_dp` share
  `sclk` with the strobes — `cpu_clk` is a *divider* of `sys_clk`, same tree,
  deterministic phase, not an asynchronous domain. **And the done-gate exists**
  on every leg: `mem_ready` gates the 037's RPLY for MK_RAM037
  (`va_037_sync`'s `PIN_nRPLY`) and `qbus_mem`'s own reply point for ROM,
  MK_EXT and turbo RAM. A late word therefore EXTENDS the cycle; it can never
  be latched stale. What actually changes as the clock rises is only how OFTEN
  the gate fires — which is why turbo routes its (expected) holds to
  `dbg_turbowait` and keeps `dbg_romgate` as the alarm. Turbo mode is the
  re-validation that bullet asked for, and the answer was that only `N_EXT` = 1
  needed retiring at /16 (see the turbo bullet). Note the old "~1.6x at 6 MHz"
  figure was pessimistic anyway: it used `(N-2)` CPU clocks and ignored the
  DIN→detection half-period; the real window is `7 + 16(N-1)` sys_clk.
  `ocbk_constrains.sdc` false-paths both directions
  of the `cpu_clk`↔`sys_clk` crossing. Reset is gated on SDRAM `init_done` (CPU held
  in reset until the controller's ~200 µs init completes).
- **sys_clk↔pix_clk are same-VCO *related* clocks** (96.65/64.43, 3:2): without
  the SDC `set_false_path` pair TimeQuest times the ~5.17 ns transfer and fails
  closure spuriously. All real crossings are a toggle+2-FF handshake (line
  request; payload stable ~21 µs around the toggle), the ping-pong `fb_linebuf`
  (a bank is never written while displayed — the triple-ahead scheduling
  guarantees it), or 2-FF-synced quasi-statics (`fb_front_valid`, `screen_mode`).
- **`fb_linebuf` must stay the plainest dual-clock RAM** (one write-always, one
  registered-read-always, same width both ports) — that's what Quartus 11 infers
  a single M4K from and Icarus simulates; mixed widths or dcfifo break one or the
  other. Check the fit report stays at exactly 1 M4K / 4096 bits.
- `mem/ram_test.hex` is **generated** by `mem/gen_mem.py` (the single source of
  truth for the ROM program — a small label-resolving PDP-11 assembler — AND the
  test picture via `render_image()`, imported by `sim/video/gen_expected.py`;
  word 0 = BK address 100000) and is gitignored — `make` regenerates it. The
  success/failure park loops are pinned at **100004/100012** (hardcoded in
  `ocbk_top.sv` and `qbus_sdram_tb.sv`) — they must never move; new code goes
  after the `start` label. After changing the draw code or picture, run
  `sim/video/run_draw_check.sh`.
- `mem/boot_blob{,11}.{bin,hex}` + `boot_blob{,11}_flash.hex` are **generated**
  by `mem/gen_boot_blob.py` from the committed `mem/roms/*.rom` (gitignored,
  `make` regenerates). **Two blobs** (Phase 7): the bk10 set at EPCS flash
  0x40000 and the bk11 set (`basic11m_0`/`basic11m_1`+`ext11m`/zero-filled
  empty banks/`bos11m`/`mstd11m`+**`smk512_v205` — the Phase-8 SMK BIOS,
  43008 words total, → SDRAM 0x3A000**; layout in the script header) at
  0x48000 — both appended to the POF as `ocbk.cof` `hex_block` pages
  (`quartus_cpf` accepts multiple blocks; the map file lists both). The
  script asserts the load-bearing SMK boot word (`bios[0o7716]` = 0o166400). **EPCS bit-order
  (hardware-verified, subtle):** the COF Intel HEX carries **true bytes**.
  `quartus_cpf` bit-reverses `hex_block` bytes into the POF/RPD — but the RPD
  is in **RBF/LSB-first bit order, not physical-flash order** (its Page_0
  equals the `.rbf` verbatim) — and `quartus_pgm -m AS` reverses **again**
  onto the chip, so the two cancel and an MSB-first SPI READ returns the HEX
  bytes verbatim. Do NOT pre-reverse (that was tried; on the board the loader
  read rev(blob) and fell back). `make blob-check` verifies the RPD pages =
  rev(blob) at BOTH 0x40000 and 0x48000.

