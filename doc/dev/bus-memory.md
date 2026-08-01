# The CPU, the Q-bus, memory and the 037

`src/cpu/` (vendored vm1), `src/bus/` and `src/sdram/`: bus conventions, where
RAM and ROM live, the one translation seam, the 037's grant rule, and the
arbiter. SMK512 layers on top of the mapper and has its own file,
[smk512.md](smk512.md).

## The vm1 core and the Q-bus

- The `vm1` (1801ВМ1) core is **vendored** under `src/cpu/` from
  `~/projects/other/fpga/cpu11/vm1/hdl/syn`. Don't edit it casually; re-sync from
  upstream if needed, but **keep the marked local hook in `vm1.v`**: `pin_sel_n`
  is push-pull there (upstream is open-collector) because `qbus_mem` consumes
  nSEL1/nSEL2 for the 177716/177714 decode and a lone Z-idle OC driver is the
  Cyclone-I stuck-asserted trap (see the virq_n gotcha). Core config is via
  global Verilog macros (see below).
  **`vm1_tve.v` (the 177712 ВЕ timer) is deliberately left upstream-stock —
  a TRIED AND REJECTED hook, do not re-apply it.** Its /128 prescaler
  (`tve_pre`/`tve_div`) is **free-running**: a CSR write reloads `tve_count`
  but not the phase, so the first tick lands 0–127 cpu_clk later depending on
  a phase dating back to power-on. BkEmu does the opposite (`Timer.java`:
  `(cpuTime - settingsChangeTime)/128`, with `updateSettingsChangeTime()` on a
  control write ⇒ phase re-zeroed to the write instant), and since beam-raced
  palette effects restart this timer from each 50 Hz EVNT and count down to a
  scanline, re-zeroing looked like the fix — a PALTST15-style sim harness
  measured it moving the palette-switch train ~3400 sys_clk, out of deep
  active video onto the H-blank edge. **On hardware it made only a MINOR
  difference to the actual artefacts, so it was stashed.** The sim
  prediction did not transfer (that harness had SDRAM contention stripped).
  A comment in the file records this so it does not get re-applied a third
  time.
- The Q-bus is **inverted / active-low / open-collector**, carried as shared
  tri-state nets at the `cpu_test` level (no SystemVerilog `interface` — neither
  Quartus 11.0 nor Icarus handle tri-state interface members reliably). Every
  participant (core, `qbus_sdram`, `qbus_slot`) drives `x ? 1'b0 : 1'bZ` /
  `ad_n = ena ? ~out : 1'bZ`.

## Memory: on-chip RAM, SDRAM and ROM-in-SDRAM

- On-chip RAM is tight (~239 Kbit). BK RAM (000000–077777) lives in the board
  **SDRAM** via the 037-fronted arbiter path (`qbus_mem`; the Phase-2
  `qbus_sdram` is retired from the build but kept for its cosim). The vendored
  `src/sdram/sdram_ctrl.sv` (from `ocb-test`) gained a 2-bit `cmd_be` byte mask for
  the BK's byte writes — re-sync from upstream but keep that hook.
  `src/video/vga_timing.sv` is likewise vendored verbatim from `ocb-test`.
- **ROM-in-SDRAM (Phase 5):** the full BK-0010.01 ROM (`mem/roms/`, committed;
  canonical source = the BkEmu project, also the reference for BK register
  semantics) is 262 Kbit > the device's 239 Kbit, so ROM reads ride the CPU
  datapath (arbiter port 0, linear `addr[15:1]` map → SDRAM words 0x4000–0x7F7F),
  keeping the fixed `N_ROM=2` reply, **done-gated** on
  `mem_ready` (ROM is NOT 037-arbitrated — mask ROM is never cycle-stolen; the
  flat ROM self-loop in `golden_037_rom.txt` pins that). **ROM writes get NO
  reply → the CPU's qbto timer → trap 4** (authentic mask/overlay ROM: real BK
  ROMs never RPLY on a write, and the "write until trap 4" fast-screen-clear
  idiom relies on it; BkEmu agrees — `ReadOnlyMemory.write` → not-written →
  BUS_ERROR → vector 4). In `qbus_mem` this is just `selected = (sel_rom &
  is_read) | sel_io` — a ROM write is not selected, so the ROM/IO wait FSM never
  replies. A DATIO(B) RMW to ROM times out on its write half too, with NO special
  handling: the vm1 gates `dout_start` on the read reply's ack having cleared
  (`~rply_ack[2]`), so a DATIO always has a both-strobes-idle gap where the
  S_REPLY exit drops the read reply before the write half re-enters as a fresh
  (un-selected) access. Applies to the fixed top ROM AND BK-0011M window-1 ROM
  overlays alike. Oracle: `sim/romwr/run.sh` (both DATO and RMW legs, mutation-
  tested); `sim/bk11` §6 asserts the overlay-write trap. Boot:
  `src/sdram/epcs_boot.sv` copies the blob from EPCS offset 0x40000 through the
  boot-writer mux onto port 0 during reset-hold (DCLO held until `boot_done`).
  **Phase 7: two-pass loader.** After the bk10 blob (pass 0, → words 0x4000+),
  the same FSM re-runs for the **bk11 ROM set** — flash 0x48000 → SDRAM words
  0x30000–0x39FFF (the mapper's window-ROM banks + fixed top ROM; a per-pass
  flash/base/cap mux + an inter-pass nCS-high `B_GAP`, ~77 ms total). BOTH
  blobs load **unconditionally** regardless of DIP-1: `epcs_boot` runs once
  per power-on but the model latch re-samples at every warm reset, so both
  images must always be resident. `boot_ok` = every pass header-valid +
  checksum-good; a failure holds the CPU in reset (no fallback). SYS_START
  is **model-muxed**: 177716 reads reply 0o100000 in bk10, `SYS_START11 =
  0o140000` (BOS) in bk11 (`qbus_pkg`/`qbus_mem`; BkEmu `Computer.java:267`
  — bit 15 still agrees with the 037 AD15 assist, bit 14 is qbus_mem-only).
  ROM is **always** the loaded SDRAM image — the on-chip 256-word test-ROM
  fallback and its **DIP2** force were removed (2026-07-10) to free resources.
  A failed EPCS boot (`boot_ok=0`) now **holds the CPU in reset** (the reset
  sequencer gates on `bo_sync`); it does not fall back. The ref037 SoC oracles'
  default-mode bootstrap JMP therefore lives in the SDRAM ROM region (word
  0x4000 → RAM program) instead of an on-chip stub — timing-identical (same
  fixed `N_ROM`), `golden_037.txt` unchanged.

## The memory mapper

- **Memory mapper (Phase 7):** `src/bus/mem_mapper.sv` is the one translation seam
  in `qbus_mem`: *(CPU address, map registers) → (region kind `MK_*`, physical
  SDRAM word)*; the kind encodes the RPLY owner AND writability (see
  `qbus_pkg`). BK-0010 mode is a **bit-identical pass-through** of the old
  inline decode (that's what keeps every timing golden the regression
  anchor). BK-0011M banking = BkEmu `Bk11MemoryManager`: 177716 **word**
  writes with bit 11 (a byte write can never bank — no bit 11; the 177717
  odd byte is never banking), ROM field `& 0o033` decoded only as the exact
  single-bit codes (others fall through to RAM — a replicated BkEmu quirk),
  register write-only on read. The mapper owns the map registers (bus-write
  snoop) and exposes `bank_wr`, which gates the spk/mot capture (banking and
  peripheral writes are mutually exclusive; banking still sets the bit-2
  write-flag). **Map reset is DCLO-only — a deliberate exception to the
  nINIT peripheral-reset rule** (like the software-owned `spk_bit`): the
  RESET instruction must not swap the page under the running code (BkEmu
  semantics; checked by the bk11 SoC oracle). **`model_bk11` is
  re-registered locally (`model_bk11_q`) for the `bank_wr` term (fix
  CONFIRMED ON HARDWARE 2026-07-22):** it is quasi-static but high-fanout, and the route from
  its `ocbk_top` DCLO latch into the `bank_wr` AND tree feeding
  `win0_page`'s next-state LUT was the design's worst sys_clk path for
  three builds running (+0.077 → −0.039 at the CHS fix → −0.230 at
  CMD25). One local flop turns that long route into a plain flop-to-flop
  path: sys_clk −0.230 → **+0.420 ns, TNS 0, zero negative paths**,
  −2 LE, and the worst path moved back into `sd_backend`. The 1-cycle
  latency is invisible — `model_bk11` changes ONLY during a DCLO hold
  (CPU parked, map registers in reset, thousands of sclk before
  release). Deliberately **NOT** used by the combinational translate:
  that cone is already met, and `sim/run_mapper.sh` compares the decode
  combinationally right after a model flip. bk10 stays bit-identical
  (`model_bk11_q` ≡ 0 → `bank_wr` ≡ 0; all twelve ref037 goldens
  byte-identical). **Window-1 banked RAM is a
  normal `MK_RAM037` access — 037-owned RPLY, cycle-stolen, done-gated on
  `mem_ready`, riding the `cpu_sdram_dp` port-0 path** (`phys` from the mapper
  = the win1 RAM page; `addr` kept for byte lanes), identical to the low 32K.
  This matches the real hardware: **the 037 fronts ALL internal RAM, window 1
  included** — schematic-confirmed 2026-07-13 (`doc/bk0011m.sch`): the 037
  (D19) is the *sole* DRAM controller (all 16 565РУ5 RAS/CAS from it; the RAM
  reply is its own RPLY), and its AD15 pin is NOT the CPU A15 wire — it is
  driven by a banking OC-NAND (D10) so that, **accounting for the active-low
  Q-bus** (physical AD15 = 1 across 000000–077777), its internal A15 =
  `A15_true & ~(window-1-is-RAM)` = true A15 **forced low for window-1 RAM**.
  The vendored `va_037` gates ownership on the raw latched `A[15]`
  (va_037_sync.sv:238/:144) — a BK-0010 simplification (upper 32K is always
  ROM/IO there) — so we reproduce the hardware force: `qbus_mem` exports
  `ext_ram` (= a window-1 `MK_RAM037` access, i.e. `sel_ram && addr[15]`; 0 in
  bk10) and `va_037_sync` uses `a15_037 = A[15] & ~ext_ram` in the RASEL /
  cpu_grant terms. bk10 stays bit-identical (`ext_ram`≡0 → `a15_037`≡`A[15]`,
  all ref037 goldens invariant). Leave the AD15 start-vector assist
  (va_037_sync.sv:109) alone — it drives only the 177716 DIN read.

## The 037 grant rule and the beam-raced palette skew

- **Beam-raced palette skew: QUANTIFIED, LOCALISED AND FIXED (2026-07-26).**
  Demos like Babylona (`~/projects/other/bk/Babylona/`) paint
  one unrolled block per scanline with no resync, so the block cost IS the
  vertical scale of the effect. **The real block is 256.1 CPU cycles = exactly
  one scanline; ocbk ran it in 240 — 6.25 % fast, ~32 dots/line. That was the
  slant.** The tone-program family in `test/` (`sndtest662`, `sndtestbaby`,
  `sndtestimm`, `sndtestimm2` — `.mac` is the source of truth, `.bin` tracked,
  `.wav` regenerable by pdpy11; same technique as `sndtestsmk`) measured it
  against a real BK-0011M. **This is the A–D baseline table `sim/grantfit`
  cites** — four numbers derived independently before that bench existed, which
  is what validates it (its legs E/F/G are `sim/smktime/golden_std`, `qbus_pkg`'s
  ideal 3326 and `test/sndtestimm2.mac`'s 3927):

  | | program | real | ocbk (pre-fix) | per unit |
  |---|---|---|---|---|
  | A | 192 × write 0177662 | 297 Hz = 6734 cyc | 6734 | **match** |
  | B | 192 × write to RAM | 286 Hz = 6993 | 6734 | −1.35 cyc/write |
  | C | 24 × Babylona block | 322 Hz = 6211 | 5824 | **−16.1 cyc/block** |
  | D | 192 × `MOV #imm,Rn` | 302 Hz = 6622 | 5648 | **−5.08 cyc/instr** |

  **Every leg that MATCHES contains only ONE-read
  instructions; every leg that DIVERGES does TWO reads back to back**
  (`MOV #imm,Rn` = −5.08 cyc/instr). That is why every earlier calibration
  missed it — `N_EXT` included, they all used 192 × `SOB`.
  **The CPU core and `N_EXT` are RIGHT:** `test/sndtestimm2.mac` runs the same
  loop from SMK RAM (`MK_EXT` — not 037-fronted, no arbitration, no slot
  quantisation) — real 509 Hz = 3929 cyc vs our ideal 3927 (the sim's 4055
  carries the `EXTRD slow` tb-saturation inflation), **0.05 %**.
  **So the whole error is in the 037-fronted DRAM path and is
  PATTERN-DEPENDENT:** per DRAM access the real machine costs 4.37 cycles more
  than SMK RAM when accesses are ~3.85 slots apart, but **6.60** when they come
  in back-to-back pairs; ours is flat at ~4.2 either way.
  **DO NOT re-investigate these — all ruled out by measurement:** `N_VREG`
  (above); the clock tree (the real CLKIN:CPU ratio is 1.5, exactly ours); the
  ВЕ-timer prescaler (hardware-rejected, see the `vm1_tve` note); the **/24
  CPU-clock phase and the 1/3 duty cycle** (12 combinations, all flat at
  26.455/26.457); the board's **D8:B RPLY re-timing flop** (+0.32 cyc only);
  and our 037 retime itself — the **reference netlist** at the exact BK-0011M
  ratio gives 26.46/20.51 against `va_037_sync`'s 26.43/20.52, i.e. *our*
  numbers, not the real machine's, with no SDRAM in the loop.
  **MiSTer cannot arbitrate this — it IS the same design:** same cpu11 vm1
  core, same divider ratios/phases (`ce_6mp/n` = clk_sys/16, `cpu_div` 24/32
  half at 12), and a gate-for-gate identical VP1-037 contention block (RASEL
  set at PC==4 / clear at PC==7, `ack = TRPLY & ~RASEL`, legacy RAM acked only
  by the 037, no fixed `N_RAM`). Its only relevant differences make it
  *faster*, not slower (no `mem_ready` done-gate; combinational ROM/extension
  ack — so it is **not** a ROM timing reference). Untested prediction:
  Babylona should slant on MiSTer too.
  **FIXED — CONFIRMED ON HARDWARE 2026-07-26: the Babylona colour smearing is
  GONE and PALTST's colour ribbons are FLAT on the board.** That is the
  acceptance test for this whole line of work: both artefacts are beam-raced
  effects whose vertical scale IS the per-scanline block cost, and both were
  the visible face of the −6.25 % block. The parametric
  study found a candidate fitting ALL SEVEN hardware tone legs and **it is now
  shipped RTL**: a **request setup window of 2 half-CLKIN phases at the PC==4
  grant decision** (`va_037_sync`'s `GRANT_SETUP` parameter) **+ the board's
  D8:B RPLY re-timing flop on the 037's reply** (`src/bus/bk_rply.sv`). Every
  residual lands inside ±1 Hz of tone-reading error (Σ|Δ| = 33 cycles over
  seven legs); per instruction it adds **exactly one grant slot to the second
  read of a back-to-back pair** and nothing to a fetch 2.5 slots later.
  Neither ingredient works alone. `sim/grantfit/run.sh` is the regression
  (bench + README); `--setup 0 --nod8b` reproduces every pre-fix number
  exactly, so the change is cleanly reversible.
  **The write leg (192 × write to RAM) is what makes it unique** — three
  candidates are identical on every read leg and differ only there, which is
  how the earlier rounds picked wrong; it also proves one direction-blind rule
  produces BOTH the +5.08 read-pair and +1.35 read-write costs (the write's
  slot is absorbed by the vm1's DATO window, per `sim/vregtime`'s N_VREG
  ladder). **Inert / rejected:** TRPLY-clear quantisation (completely inert);
  minimum-gap 2 (inert, as recorded); minimum-gap 3 IS rejected but by the
  write leg (+11 %), **not** by wrecking `SOB` (+0.13 %) as the pre-bench
  record claimed — that scratch RTL is gone, so treat the "wrecks SOB" claim as
  unconfirmed. The conclusion it supported (the rule is wrong) survives either
  way.
  ⚠️ It moves the /32 bk10 path too — **+0.20 % on `SOB` but +15.0 % on
  `MOV #imm`, and NOTHING measures that** (no BK-0010 tone; `sim/bk10`'s golden
  is the core alone, no 037). **Falsifiable prediction: a real BK-0010 running
  `test/sndtestimm.bin` should now match us and be ~15 % slower than the
  pre-2026-07-26 firmware.** Collect that recording if a BK-0010 is ever
  available — it is the one leg of this calibration with no measurement behind
  it. **Oracle consequence: `sim/ref037` now keeps TWO golden sets** — see its
  bullet above and `sim/ref037/run.sh`'s header.
  (Experiment note: an `inh`/`gnt_inh` register added to a scratch copy of
  `va_037_sync` MUST be reset — without it RASEL goes X and the sim hangs.)

## SDRAM arbiter ports

- **SDRAM arbiter ports** (fixed priority, 0 highest): 0=CPU, 1=panel readout,
  2=037 video fetch, 3=FB write. There is **no fairness** — the readout MUST stay
  paced (`fb_readout` PACE ≥24 sys_clk/word); an unpaced port-1 burst starves
  ports 2/3 for a whole line. Client contract: hold req+fields until the 1-cycle
  gnt, then drop req for ≥1 cycle (`served` mask).

