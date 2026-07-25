# CLAUDE.md

Guidance for working in this repo. Keep it current as the project grows.

## What this is

`ocbk` runs the Soviet **Elektronika BK-0010 / BK-0011M** (PDP-11-class) as
alternative firmware on the 1chipMSX / OneChipBook board (Altera Cyclone I
**EP1C12Q240C8**, Quartus II 11.0). The headline goal is **cycle-accurate** CPU
behaviour.

**Read [ROADMAP.md](ROADMAP.md) first** — it is the authoritative implementation
plan: the source building blocks, the validated platform constraints, the settled
clock tree, and the phase-by-phase milestones. Every change should map to a phase
there; update ROADMAP.md when scope or status changes. **Phases 1 (CPU bring-up),
2 (BK RAM in SDRAM), 3 (037 arbiter), 4 (video pipeline), 5 (SoC boot: full
BK-0010.01 ROM in SDRAM + EPCS loader), 6 (keyboard/audio/tape: PS/2 →
1801ВП1-014 equivalent, VIRQ/IAK + СТОП) and 7 (BK-0011M mode: /24 CPU clock,
177716 banking mapper, 177662 video register, 50 Hz EVNT/IRQ2, СТОП-block,
two-pass EPCS loader with the 0011M ROM set, authentic DRAM power-on pattern)
are done — both models boot and run on hardware**; see README.md for the
current result. **Phase 8 (SMK512) is DONE — CONCLUDED 2026-07-23, all
increments confirmed on hardware in BOTH models: DIP 8 boots the SMK BIOS and
loads an OS from a raw AltPro image on an SD card.** Increment 1 (the 512 KB
segmented RAM extension on **DIP 8**) and increment 2 (the
SMK BIOS ROM + the SYS register-space boot overlay — **DIP-8-ON boots the
SMK BIOS, confirmed on hardware 2026-07-17: it shows its banner**) are done;
**IDE increment (a) — the drive engine (`src/smk_ide.sv`: task file, ATA
engine, AltPro geometry parse, tb-backed sector port) plus the 177130/132
КНГМД register stub — is done, CONFIRMED ON HARDWARE 2026-07-18**: with no
drive the BIOS boots, times out its HDD and FDD probes cleanly and exits
to its command line exactly like a real driveless SMK (the stub fixed a
crash-restart at the FDD boot attempt). **Increment (b) — the SD/SPI
backend (`src/sd_backend.sv`) — is done, CONFIRMED ON HARDWARE
2026-07-18: the BIOS detects the SD-backed drive and BOOTS AN OS from
the HDD image** (a raw AltPro image dd'd at card LBA 0, megasd slot
PIN_61–66); pLed[7] is the drive-access LED (see the SMK512 bullet).
**Tier-1 READ prefetch is done, CONFIRMED ON HARDWARE 2026-07-19**
(fetch sector N+1 while the CPU drains N — the 2-bank buffer split with
an E_FLUSH mid-command interlock; `src/smk_ide.sv` + the `sim/ide`
oracles; the board boots and multi-sector loads run faster).
**Tier-2 SD multi-block (CMD18/CMD25) was implemented, confirmed on
hardware, then REVERTED 2026-07-23** — it bought ~2% of the SD-side time
on a path the tier-1 prefetch already hides behind the CPU drain, and
cost a real fault (streams were closed lazily, so one stayed open across
idle time, a warm reset left the card streaming, and the machine needed
a SECOND reset press to find its disk). The backend is single-block
CMD17/CMD24 again; the warm-reset recovery preamble and the whole-ladder
init retry stay as hardening. See the `sd_backend` bullet.
**The long-standing pseudo-static `model_bk11 → mapper` timing cone is
FIXED, CONFIRMED ON HARDWARE 2026-07-22** by re-registering
`model_bk11` inside `mem_mapper`
for the `bank_wr` term (see the mapper bullet): sys_clk went
−0.230 → **+0.420 ns, TNS 0, zero negative paths**, and the worst path
is now an ordinary `sd_backend` register-to-register path.
**bk10+SMK (BkEmu `BK_0010_SMK512`) is DONE, CONFIRMED ON HARDWARE
2026-07-23: DIP 1 OFF + DIP 8 ON boots the SMK BIOS and loads an OS from
the SD-backed image on a BK-0010 too**. DIP 8
works in BOTH models now (the SMK is an МПИ expansion board — only the
per-mode monitor-ROM deselect, `mon_en`, is model-dependent; see the
SMK512 bullet); fit 6,938 LE, sys_clk +0.430 ns / TNS 0.
Remaining open items, all deferred to Phase 9 and none blocking: the
SMK-RAM `ram_init` pattern, `N_*` recalibration, SD data CRC16 / MMC
cards, and BK-0011M cycle-accuracy vs a reference (reference-tb-first).
**Phase 9 (fidelity & polish) STARTED — increment 1 (the authentic
EVNT/IRQ2 assertion instant, `src/bk_evnt.sv`) is DONE IN SIM
2026-07-23, hardware acceptance pending**: the 037 has no
vertical-blanking pin, so the real 0011M's D28+D3:B missing-pulse
detector off WTI/SYNCO replaces the Phase-7 "nIRQ2 = vgate" model, which
was MiSTer's and fired **452 CLKIN (~1.18 scanlines, ~301 cpu_clk) early
every frame** — displacing every beam-raced multicolor/gigascreen
effect. See the EVNT/IRQ2 bullet and `sim/evnt/README.md`.
**Phase-9 increment 2 — the SMK512 memory access time (`N_EXT`) is
CALIBRATED against real hardware, DONE & CONFIRMED ON HARDWARE
2026-07-26**: a tone-frequency measurement (`doc/sndtestsmk.mac`, run on a
real BK-0011M + SMK512 and on the board) put the Phase-8 placeholder
`N_EXT = 4` **14.5 % slow**, with a standard-RAM control leg right to
+0.8 % — so the whole error was in that one constant. `N_EXT` is now **1**
(an async external SRAM board replies inside the strobe cycle, the
`N_KBD = 1` case), which needed an N=1 reply path in `qbus_mem` and an
early SYNC-time read issue in `cpu_sdram_dp`. **The board went 514 Hz →
602 Hz against the real machine's 601 — +0.17 %**; fit 6,953 LE, sys_clk
+0.190 ns / TNS 0 (after two structural STA fixes in modules the change
never touched — see the `N_EXT` bullet).
See the `N_EXT` bullet and `sim/smktime/run.sh`.

## Build & test

```
make sim       # Icarus regressions: bk10 cycle-count oracle + slave cosim
make           # Quartus: map -> fit -> sta -> asm -> POF (parked in fw/)
make flash     # program EPCS4 over USB-Blaster (Active Serial; JTAG TDO not wired)
make clean     # remove build intermediates
```

`make sim` needs Icarus Verilog; the FPGA build needs Quartus II 11.0 at
`/opt/altera/11.0/quartus` (override `QUARTUS_HOME=`). Run individual Quartus
stages directly when iterating, e.g. `quartus_map ocbk.qpf`, `quartus_sta ocbk.qpf`.

## Verification discipline (do not skip)

Cycle accuracy is the whole point. All `make sim` oracles must stay green:
- `sim/bk10/run.sh` — the upstream timing testbench vs `sim/bk10/golden.txt`
  (the CPU core's per-instruction cycle counts). Independent of the SDRAM work.
- `sim/ref037/run.sh` — **twelve diffs**, vs `golden_037.txt` (with-display timing,
  program in RAM) and `golden_037_rom.txt` (Phase-5: same program words executed
  *from the ROM region* — ROM is never 037-cycle-stolen, so its self-loop is
  **flat at 13 cycles**; the RAM loop beats 17,15,16,16): the reference netlist,
  the retimed `va_037_sync`, the SoC integration (now instantiating the *real*
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
  the behavioral `src/bk_kbd014.sv` must reproduce it line-for-line (netlist
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
  Screen radial toggle (screen_mode), Scroll Lock now emitting no event
  (CMT tape mode moved to DIP 4), parity-error and stale-prefix recovery.
- `sim/run_audio.sh` — Phase-6 audio + tape unit oracles: `bk_audio_tb`
  (push-pull DAC pattern, mid-scale reset, activity one-shot, and the CMT-mode
  right-channel comparator network incl. the `cmt_in_pad` → `tape_lvl`
  feedback) and `spk_capture_tb` (directed Q-bus cycles into the real
  `qbus_mem`: bit-6/bit-7 DOUT-window captures, 177716 DATI reads — start
  vector / write-flag / kbd / tape bit 5 — and nINIT keeping the
  software-owned spk/mot latches).
- `sim/run_clkgen.sh` — the Phase-7 `cpu_clkgen` unit oracle: BK-0010 (/32)
  mode **bit-identical** to a replica of the pre-Phase-7 `divc[4]` tap
  (enables included), the /24 BK-0011M rate exact, and a retarget sweep (no
  half-period outside 12..16 sys_clk). The SoC tbs replicate the divider
  locally, so this is the only sim coverage of the real chain.
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
  OR-merge (177714 pure-BIOS, 177776 BIOS-only, 177716 masked-merged) with
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
- `sim/ide/run.sh` — the Phase-8 **SMK512 IDE unit oracle**: `src/smk_ide.sv`
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
  `src/sd_backend.sv` (the SPI-mode SD host serving the backend sector
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
- `sim/bk11/run.sh` — the Phase-7 BK-0011M SoC **functional** oracle
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
- `sim/romwr/run.sh` — the ROM-write-timeout functional oracle (BK-0010 SoC
  stack, data-checking, `COSIM PASS` at the pinned success park like `sim/bk11`).
  Proves a write to ROM gets NO reply → qbto → trap 4: the **conditionless
  "write until trap 4" screen-clear** (a counter-free `CLR (R0)+` marching into
  100000 — only the trap ends it; RAM cleared, ROM word unchanged) and an
  **INC @#100000 RMW** whose write half must trap while its read half replies.
  Both are **mutation-tested** (reverting the `selected` change hangs the clear;
  the RMW leg also proved the S_REPLY refinement unnecessary — the DATIO gap
  already drops the read reply). The gen program is `mem/gen_romwr_test.py`.
- `sim/evnt/run.sh` — the Phase-9 **EVNT/IRQ2 detector oracle** and the
  authority on `src/bk_evnt.sv` (the authentic D28+D3:B missing-pulse pair off
  the 037's WTI/SYNCO pins). Contract = the `sim/ref014` shape: the vendored
  **reference** netlist `sim/ref037/va_037.v` generates `golden_evnt.txt`, and
  the retimed `src/va_037_sync.sv` must reproduce it line-for-line (it does,
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
  regression that keeps it calibrated. Runs `doc/sndtestsmk.bin` **verbatim**
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
  the real BIOS boot, same pass conditions. **`+smk10`** (bk10+SMK) boots
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

## Architecture & conventions

- The `vm1` (1801ВМ1) core is **vendored** under `src/cpu/` from
  `~/projects/other/fpga/cpu11/vm1/hdl/syn`. Don't edit it casually; re-sync from
  upstream if needed, but **keep the marked local hook in `vm1.v`**: `pin_sel_n`
  is push-pull there (upstream is open-collector) because `qbus_mem` consumes
  nSEL1/nSEL2 for the 177716/177714 decode and a lone Z-idle OC driver is the
  Cyclone-I stuck-asserted trap (see the virq_n gotcha). Core config is via
  global Verilog macros (see below).
- The Q-bus is **inverted / active-low / open-collector**, carried as shared
  tri-state nets at the `cpu_test` level (no SystemVerilog `interface` — neither
  Quartus 11.0 nor Icarus handle tri-state interface members reliably). Every
  participant (core, `qbus_sdram`, `qbus_slot`) drives `x ? 1'b0 : 1'bZ` /
  `ad_n = ena ? ~out : 1'bZ`.
- Clocking: **one PLL only** (board constraint — the PIN_28 crystal feeds a single
  PLL). New clocks must be a ÷N of the ×9 VCO or a fabric clock-enable; the SDRAM
  chip clock (`pMemClk`) is the PLL's `extclk0` at the same 96.65 MHz as the
  internal `clk0`/`sys_clk` (phase-matched, like esemsx3's c1/e0). The PLL and
  resets live in `src/ocbk_top.sv`; the fabric divider chain (dot/037-CLKIN
  enables + the CPU clock) is `src/cpu_clkgen.sv` (Phase 7): a toggle divider
  giving **/32 = 3.02 MHz (BK-0010) or /24 = 4.03 MHz (BK-0011M)**, selected by
  `model_bk11` = **DIP 1** (ON = 0011M), latched in `ocbk_top` while DCLO is
  held — power-on AND warm reset, so the reset button switches the model — and
  frozen while the CPU runs. `sim/run_clkgen.sh` pins /32 mode bit-identical
  to the pre-Phase-7 `divc[4]` tap (the SoC tbs replicate the divider locally,
  so that oracle is the divider's only sim coverage). In /32 mode CPU edges
  coincide with the 037 `en_pos`/`en_neg` strobes (CPU=CLKIN/2, the reference
  phase); in /24 they walk a deterministic 48-sys_clk pattern — 0011M
  cycle-accuracy vs a reference is a later Phase-7 item.
- **Soft reset (Phase 5.5):** the board's reset button (`pSltRst_n`, PIN_153 =
  the slot RESET net, external pull-up) re-enters the `ocbk_top` reset
  sequencer via `warm_rst_req` (pressed = hold, release + ~22 ms tail = the
  8/12 DCLO→ACLO release). CPU-side DCLO-keyed state re-inits; `srst_n`, SDRAM
  init, `epcs_boot` and memory contents are untouched — BK hardware-reset
  semantics (memory survives). **The video side (037 `PIN_R` + `fb_video`) is
  power-on-reset ONLY (`vid_rst_n`)** — a real BK's display ignores CPU
  DCLO/ACLO, so the picture stays up across a warm reset; never re-key those
  resets to `dclo_n`. **Reset wiring rule (real BK): DCLO/ACLO go to the CPU
  ONLY; all BK peripherals are reset by the CPU's nINIT Q-bus line** (`vm1`
  drives `pin_init_n` open-collector: asserted during its own reset AND pulsed
  by the RESET instruction). Every Phase-6+ peripheral must key its reset to
  `init_n`, not `dclo_n` — the RESET instruction must reset it too (done for
  the 177716 write-flag and the `bk_kbd014` registers). **Exception: the
  translator-side ЗАГЛ/СТР caps trigger and РУС/ЛАТ shadow are clocked off
  ACLO** (BK schematic: a 74LS74 with D=GND, C=ACLO), so `kbd_ps2bk` resets
  them to the power-on default (ЗАГЛ / ЛАТ) on **`aclo_n`** — power-on AND the
  reset button, both of which pulse ACLO, matching the MONITOR's own re-init
  (this keeps them in sync across a warm reset — no post-reset case desync).
  They are NOT reset by the RESET instruction (that pulses nINIT only, never
  ACLO), so `aclo_n` is exactly right: in `ocbk_top` it is driven only by
  power-on and `warm_rst_req`. In the warm-reset oracle tbs the release is aligned to
  the next vblank start (the free-running 037 makes post-reset timing raster-
  phase-dependent — authentic; the vblank alignment is what keeps the replayed
  golden window steal-free and diffable). The Phase-6 keyboard reset chord ORs
  into `warm_rst_req`. "DIP n" = physical switch n = `pDip[n-1]`; **DIP 1 =
  model select** (OFF = BK-0010, ON = BK-0011M; Phase 7 — latched during any
  DCLO hold, see the clocking bullet; it used to be screen_mode, which moved
  onto the PS/2 **Print Screen** key: each press toggles colour-256 ↔
  mono-512; the `kbd_ps2bk` `key_scrmode` radial output → the `smode_sr` 2-FF
  sync; power-on-only, so it survives a warm reset like the real
  monitor-cable switch and the video pipeline). **DIP 8 = SMK512 enable**
  (Phase 8; ON = present, **BOTH models** — the SMK is an МПИ expansion
  board, so every SMK term is gated on `smk_en` alone), latched in the SAME
  DCLO-hold block as DIP 1, so model and SMK config switch together on a
  warm reset. **DIP-8-ON boots the SMK BIOS in either model** (the SYS rom7
  register-space overlay redirects the 177716 start vector to 166400 — see
  the SMK512 bullet; the SYS reset layout deselects BOS / covers the BASIC
  region, so it is the BIOS or nothing) and the BIOS **auto-detects the
  model itself** by writing 177662 with vector 4 planted: replied on a
  bk11, bus-timeout → trap 4 → `MODE_STD10` on a bk10. DIP 8 OFF + reset
  returns a stock machine of whichever model DIP 1 selects. **DIP 4 = CMT
  tape-in mode (CONFIRMED ON HARDWARE 2026-07-25)** (ON = the right sound jack `pDac_SR` is the cassette port;
  `~pDip[3]` read LIVE — a 2-FF sys_clk sync, NOT DCLO-latched, since CMT
  never touches the CPU — so flipping it needs no reset; `pLed[6]` = mode
  tap; was the PS/2 Scroll Lock key through Phase 8, see the tape bullet).
  **DIP 2 is unused** — it
  forced the on-chip test ROM, removed 2026-07-10 (ROM is always the loaded
  SDRAM image).
- **Authentic DRAM power-on pattern (`src/ram_init.sv`):** the board SDRAM has
  no defined power-on state, so before this the BK startup screen showed FPGA
  garbage / stale content (worst on a model-switch warm reset, where DIP 1
  reinterprets the previous model's screen). `ram_init` fills the selected
  model's RAM region with the К565РУ6 (bk10) / К565РУ5 (bk11) power-on pattern
  that the **bkemu-QT** emulator reproduces (`CMotherBoard[_11M]::InitMemoryValues`
  in `devemu/Board.cpp` / `Board_11M.cpp`). Each word is all-ones/all-zeros per
  a per-model rule, expressed on the physical word address (bases are 0x2000-word
  aligned and both rules use only bits < 13, so the emulator's linear word index
  reduces to `w_addr`): **bk10** `word = w_addr[0] ^ w_addr[6] ^ (w_addr[5:0]==0 &
  w_addr!=0)` (alternating 0/FFFF whose phase flips at each 64-word boundary — the
  C loop's `uint8_t flag==192` extra inversion; index 0 is 0); **bk11** `word =
  w_addr[3] ^ w_addr[6]` (8-word blocks with a 16-word double-block every 64
  words). Both closed forms were verified bit-for-bit against transcriptions of
  the C loops over the full fill ranges; the `sim/raminit` tb re-derives them via
  an **independent literal transcription** of the loops. It
  **fills at power-on and re-fills on a warm reset ONLY when the model changed**
  (model_bk11 only changes during a DCLO hold, so a re-fill always lands with
  the CPU parked); a **same-model warm reset preserves RAM** (BK reset
  semantics — never re-fill it). It shares arbiter port 0 with `epcs_boot`
  through a top-level 2:1 mux (`mem_bw_*` / OR-ed `boot_active`) — they never
  overlap (the fill starts after `boot_done`), so **`qbus_mem` is unchanged**
  and no module-level oracle sees it. `fill_busy` (2-FF into cpu_clk as
  `fb_sync`) is ORed into the reset sequencer hold so the CPU never starts on
  half-filled RAM. On a re-fill (`blank_pulse`, gated on the fill being a
  re-fill i.e. `ram_valid` already 1) it clears `fb_video`'s `fb_front_valid`,
  reusing the existing power-on black-out so the display goes black → reveals
  the fresh pattern → firmware clears it (the first power-on fill needs no pulse
  — video is still in reset then). Oracle: `sim/raminit/run.sh` +
  `sim/run_boot_check.sh` (real MONITOR/BOS cold-boot on the pattern; the
  replica preloads it). **DCLO/model-change-only** — like the map/662/spk
  registers, it is deliberately NOT reset by nINIT (a RESET instruction must
  not re-pattern RAM under the running program).
- **Keyboard (Phase 6):** `ps2_rx` → `kbd_ps2bk` (translator, all on
  `cpu_clk`) → `bk_kbd014` (the 1801ВП1-014 bus equivalent at 177660–177663,
  decode = the 037's `PIN_nBS`, netlist-contract-validated — see
  `sim/ref014/README.md` for the full pinned contract). Key facts:
  - **the 014 readme's "nEC1 = РУС/ЛАТ" label is imprecise for the BK**: the
    schematic wires nEC1 to the trigger flipped by the ЗАГЛ/СТР keys (caps),
    while РУС/ЛАТ are ordinary matrix keys emitting 016/017 — mapped here as
    CapsLock = the ЗАГЛ/СТР trigger, LCtrl = РУС, Home = ЛАТ, Insert = СУ
    (held), either Shift = НР, either Alt = АР2, **Delete = СТОП**,
    **Print Screen = screen_mode toggle** (a radial control output like
    СТОП, never a matrix code, power-on-only — see the screen_mode note;
    Scroll Lock is now unused — CMT tape mode moved to **DIP 4**, see the
    tape note);
  - case algebra per BkEmu (`latin ^ (caps | shift)` on letters, СУ = `&037`
    on 01xx codes); the **silicon auto-274 code group**
    {0,1,2,4,5,6,7,011,013,021} vectors to 0274 without АР2 (measured over
    the netlist matrix scan — MiSTer's arrow flags were wrong);
  - **СТОП is trap-to-4 on a BK-0010 with BASIC** (per the schematic/user):
    nothing decodes 177674/177676, the HALT entry's PC/PSW stores bus-timeout
    (`qbto`, 56..63 clocks) and the CPU traps through RAM vector 4 — the
    160002 word is never used as a vector. `qbus_mem`'s I/O decode is the
    CPU's own nSEL1/nSEL2 pins (177716/177714 only — the registers whose read
    data `ad_oe` delegates externally; everything else in the I/O page,
    177674/76 included, is undecoded and bus-times-out, exactly as a real BK);
    never "helpfully" reply there. СТОП itself is a fixed 64-cpu_clk one-shot
    on nIRQ1. **Phase 7 (BK-0011M): 177716 write bit 12 = СТОП-block**
    (1 = blocked, write-only, `stop_block` in `qbus_mem` gating the one-shot
    launch in `ocbk_top`) — MiSTer's lane rule, matching the real board's
    WR1/WR2 byte-strobe registers: only a write that strobes the HIGH byte
    (word, or the 177717 odd byte) with the bit-11 lane clear touches it;
    low-byte writes never do (BkEmu's implicit re-enable there is a rejected
    emulator artifact). bk11-only (bk10 has no latch), **DCLO-only reset**
    (the map/662 exception: RESET must not re-enable СТОП). Pinned by
    `spk_capture_tb` + `sim/bk11` section 13; that oracle also documents
    that the aborted HALT entry pushes a mid-instruction PC — the trap-4
    frame is NOT RTI-able (real СТОП handlers never return);
  - `N_KBD`/`N_IAK` = 1 (the async chip replies within the strobe cycle) and
    the 177660 **write** reply is combinational (`wr_fast`) — both pinned by
    `golden_kbd.txt`; vm1 slaves must hold read data past DIN release (the
    IAK vector capture relies on it — bus-charge physics on the real board).
- **Tape (Phase 6):** the esemsx3 **CMT-jack scheme** — `pDac_SR` (right sound
  channel, now `inout`) doubles as the cassette port while CMT mode is on:
  **DIP 4 selects it** (`~pDip[3]`, ON = CMT; read LIVE through a 2-FF
  sys_clk sync in `ocbk_top` — `cmt_sr` — so flipping the switch changes the
  mode with no reset, since CMT never touches the CPU; `pLed[6]` = mode tap.
  Through Phase 8 this was the **PS/2 Scroll Lock** key → a `key_cmt` radial
  toggle, the esemsx3 convention). **Do NOT
  gate CMT on the 177716 motor bit** — that was tried first (authentic:
  MONITOR d6.mac `KPUSK=020`/`KSTOP=220`, bit 7 = 1 = stopped, held 1 outside
  tape ops) but **real BK software writes bit 7 = 0 outside tape operations
  and wrongly killed the right audio channel** (hardware finding 2026-07-10).
  `mot_bit` is still captured next to `spk_bit` in `qbus_mem` (same
  DOUT-window sys_clk capture, same software-owned NOT-nINIT-reset contract,
  oracle-pinned) but left unconnected in the top. In CMT mode `bk_audio`
  drives `pDac_SR` as `[5]`=input(Z) `[4]`=Z `[3:2]`={lvl,~lvl} (Schmitt
  feedback through the ladder resistors) `[1]`=0 `[0]`=spk level (BK tape-out
  IS bit 6); the sampled level feeds **177716 read bit 5** (`tape_in`,
  2-FF onto `cpu_clk_n`). The MONITOR read loop is duration-based and
  self-calibrating, so a WAV played into the jack is a valid tape source.
  These pad OEs are the ONE intentional tri-state besides the bus nets — the
  map-report guard grep must not flag them (they drive pins, not internal
  logic). The **original MONITOR asm sources** live at
  `~/projects/other/bk/vak-opensource/bk/bk-0010-sources/` (d6.mac = tape) —
  ground truth for MONITOR behaviour alongside BkEmu. Tape-out fidelity note:
  a real BK mixes write bits 6+5 into a 3-level record waveform; bit 6 alone
  is shipped (dominant component).
- Cartridge-slot Q-bus is a **forward seam**: `src/qbus_slot.sv`, default
  `SLOT_ENABLE=0` (drives nothing, slot pins stay reserved-tristated). The full
  slot pin map lives commented in `ocbk_common.qsf`. Real BK hardware needs an
  external 5V↔3.3V level-shifter (Cyclone I is not 5V-tolerant).
- On-chip RAM is tight (~239 Kbit). BK RAM (000000–077777) lives in the board
  **SDRAM** via the 037-fronted arbiter path (`qbus_mem`; the Phase-2
  `qbus_sdram` is retired from the build but kept for its cosim). The vendored
  `src/sdram_ctrl.sv` (from `ocb-test`) gained a 2-bit `cmd_be` byte mask for
  the BK's byte writes — re-sync from upstream but keep that hook.
  `src/vga_timing.sv` is likewise vendored verbatim from `ocb-test`.
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
  `src/epcs_boot.sv` copies the blob from EPCS offset 0x40000 through the
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
- **Memory mapper (Phase 7):** `src/mem_mapper.sv` is the one translation seam
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
- **SMK512 (Phase 8; DIP 8): 512 KB segmented RAM (increment 1) + BIOS ROM
  and boot (increment 2):** layered into `mem_mapper` exactly at the
  window-ownership hook, as a second translate stage over the bk11 decode
  (`smk_en=0` ⇒ wire-through — every existing golden invariant). **BkEmu
  `SmkMemoryManager.java` (+ its unit test) is the authoritative reference**
  — it beat MiSTer on every divergence (reset default = **SYS** not STD11;
  strobe arming compares the low NIBBLE; byte writes lane-masked per
  `Computer.writeMemory`: odd byte = value<<8). Contract: register
  **0177130** (the floppy control register, "ab-used"), inside the ROM
  window so its reply is a positive decode carved from `sel_rom` in
  qbus_mem (since the IDE increment: `sel_fdd`, the КНГМД-stub block
  177130/177132 replying BOTH directions at the fixed `N_SMKREG`
  placeholder — see the FDD-stub note below) — NOT an nSEL; two-phase strobe (`(value & 017) == 06` arms, the FOLLOWING write
  commits mode `v[6:4]` + 32 KB page `{v0,v3,v2,v10}`); 8 modes × 8 4 KB
  segments (seg = `addr[14:12]`, rel = seg ^ 4 in SYS/ALL) per the BkEmu
  table incl. the BOS/second-window deselects → MK_NONE. SMK RAM = **`MK_EXT`**:
  FSM-owned fixed `N_EXT` reply read AND write (external-controller RAM is
  NOT 037-fronted — `ext_ram` stays MK_RAM037-only so `a15_037` stays high
  and the 037 never grants), done-gated both ways, riding the same
  cpu_sdram_dp port-0 path at `SMK_RAM_BASE = 0x40000` (256 Kwords,
  concatenation-only). HLT10 seg 0 = read-only via the mapper's `smk_ro`:
  the write is not `selected` (the exact ROM-write rule → trap 4) and its
  u_dp feed is `sel_romr`, so it is structurally never issued to SDRAM.
  **Increment 2 — the BIOS ROM and boot:** ONE 4 KB image
  (`mem/roms/smk512_v205.rom`, appended to the bk11 blob → SDRAM
  `SMK_BIOS_BASE = 0x3A000`) backs BOTH windows — **rom6** @160000
  (SYS/STD10/STD11) and **rom7** @170000 (SYS only); MK_ROM (reads via
  u_dp at the fixed `N_ROM`, writes → trap 4). **The boot hack** (what makes
  DIP-8-ON boot): in SYS rom7 covers the FULL 0170000–0177777 *including
  the register space*, so the vm1's initial-start 177716 read returns
  `bios[0o7716] | SEL1` = 166400-based (the open-collector wire-OR; BkEmu
  ORs memory and device reads) → PC = 166400, inside rom6. qbus_mem
  reproduces the merge by latching `io_word | ram_rdata` at the reply point
  and driving it itself; u_dp still fetches but its pad drive is suppressed
  by the issue-time `rd_noe`/`was_drive` flop (the pad-OE rule — never a
  live translate term in an OE cone). TWO carve-outs (documented
  deviations): **177700–177717** (vm1-internal: never replied/driven; the
  boot-critical 177716/14 merge rides the existing nSEL `sel_io` reply;
  extent writes still POST to SMK RAM silently — BkEmu broadcast-write) and
  **177660–177667 READS** (kbd/037 push-pull-drive their own data; the
  smk64 replica carves the same hole; extent writes stay claimed). Seg-7
  restricted extent 0177000–0177777 per mode: ALL = readable (`smk_ro`),
  HLT10/HLT11 = writable (`smk_wo`, the write-only mirror riding a new u_dp
  `sel_ramw` write-only leg — the 177674/76 HALT-debugger catch: СТОП's
  HALT-entry stores land in SMK RAM and the HALT vector comes from 160002/4
  = SMK RAM seg 6), others capped → MK_NONE. All the per-mode window/extent
  flags are decode-at-commit registers next to `seg_*` (the STA rule). The
  **177130/177132 КНГМД (FDD-controller) stub** (IDE-increment hardware
  fix): the SMK board carries a REAL floppy controller, so both registers
  reply BOTH directions REGARDLESS of layout — BkEmu's SMK config always
  attaches FloppyController, whose no-drive control read is 0. qbus_mem's
  `sel_fdd` reproduces that (reads reply 0-merged — under SYS the rom7
  BIOS word still ORs in; the mapper stays the layout-write snooper, never
  the reply owner; in HLT modes the extent u_dp write leg still posts to
  SMK RAM on the pre-commit translate = BkEmu's memory-then-device order,
  so a mode write can't re-map its own cycle). The increment-2 "reads
  trap 4 outside SYS" was OUR simplification, not BkEmu's — the real
  BIOS's FDD boot attempt (which follows a failed HDD boot) trapped on
  its status polls and CRASH-RESTARTED the machine (hardware 2026-07-18).
  SMK-off keeps 177130 plain ROM (sim/romwr contract).
  TIMING: I/O-page MK_EXT accesses take the `N_ROM` count, NOT `N_EXT` —
  the 037's start-vector assist replies EARLY at 177716 (wire-AND) and the
  vm1's data-sample point sits a fixed distance after that assert; the
  `N_EXT` count landed the merged word too late (found in sim). The FSM
  done-gate keys on the legs u_dp actually ISSUES (an smk_wo read / smk_ro
  write never issues — gating on raw `sel_ext` would hold RPLY forever
  where `sel_io` coexists). **IDE increment (a) — the drive engine
  (`src/smk_ide.sv`), done in sim:** the SMK IDE task file at word
  addresses **0177740–0177756** (BkEmu `SmkIdeController` over
  `IdeController` is the contract; `IdeControllerTest` the transcribed
  oracle) — ALL data bit-inverted **both** directions at the bus adapter
  (~; the backing store holds TRUE data = a **raw AltPro image**, the
  same bytes BkEmu attaches), the composite registers 177740 (read
  {drive-addr, status}, write-at-exact-740 = COMMAND, byte 741 ignored)
  and 177742 (read {alt-status, DHR |0xA0}, write-at-exact-742 = DHR,
  byte 743 = the control register / SRST), ONE master drive (the absent
  slave reads bus 0xFFFF), **CHS only** (the DHR LBA bit ⇒ ABRT — a
  documented deviation, BkEmu supports LBA), commands **IDENTIFY /
  READ 0x20-21 / WRITE 0x30-31**, everything else BkEmu's own ABRT
  default (0x41/0x04). Geometry parses **in hardware from image sector 7**
  (the AltPro partition table: inverted words, checksum seed 012701,
  records growing down from byte 0770; fallback = BkEmu raw defaults
  S=63 H=16 C=total/1008, C==0 ⇒ attach fails ⇒ absent). Status shows
  **SR_BSY while the backend works** (fetch gaps / write commits) — a
  required deviation from BkEmu's instantaneous model (a !BSY poll after
  the last data word must not see command-complete mid-commit); end
  status is BkEmu's 0x50 exactly. The device is an `ocbk_top` **sibling**
  (all sclk, snoops the bus, never drives it): qbus_mem's `sel_ide`
  decode owns the RPLY both directions (fixed `N_IDE` = N_ROM-family
  placeholder) and ORs the registered `ide_rdata` into its reply-point
  merge — BkEmu `Computer.readMemory`'s memory|device OR (under SYS the
  rom7 BIOS bytes merge in; extent-mode writes still broadcast to SMK
  RAM). Reset is **DCLO-only — the 5th deliberate nINIT exception**
  (BkEmu resets the IDE on hardware reset only; software resets ride
  SRST). The 2-bank 512×16 sector buffer (2 M4Ks) + the backend sector
  port (req/ack/done, 28-bit LBA, bank field, all sclk) are the SD/SPI
  seam AND the tier-1 prefetch ping-pong. **Tier-1 READ prefetch
  (CONFIRMED ON HARDWARE 2026-07-19):** `bank_drain` (CPU-facing: drain /
  E_FILL / E_COMMIT) and
  `bank_fetch` (backend-fill) split the buffer; at each READ sector's
  drain-start (E_FETCH's bk_done for sector 0, the E_DRAIN bank swap for
  the rest) the engine issues `bk_sector+1` (a linear +1 index, so no
  `cur_lba` register) into the idle bank when `scount` says the chain
  continues — the inter-sector BSY gap collapses to ~0 when the CPU is the
  slower drainer, else E_DRAIN parks BSY until the prefetch's `pf_ready`.
  A global ack/done handshake tracks the outstanding op in `bk_out`
  (`bk_busy = bk_req||bk_ack||bk_out`); a mid-command new COMMAND/SRST
  routes to **E_FLUSH**, which waits `!bk_busy` before re-pinning both
  banks (so a stale prefetch stream can't corrupt the new command's bank —
  the WRITE case defers its DRQ past the flush). **Last-read/written CHS
  view:** the visible task-file registers point at the sector CURRENTLY in
  transfer — set to sector 0 at dispatch and held, then advanced only at
  each later sector's drain-start (the E_DRAIN swap for READ, E_COMMIT for
  WRITE), never one-ahead and never at a prefetch's own bk_done — so a
  COUNT=N run ends with them on the last sector handled (BkEmu-faithful
  after the 2026-07-21 fix, CONFIRMED ON HARDWARE — the old code left them
  one past it; no cross-command auto-advance, so consecutive single-sector
  READs must set CHS explicitly). WRITE and SD multi-block stay strictly
  sequential. **pLed[7] = drive-access LED**:
  `ide_act` (command/backend in flight — DRQ phases, backend ops, the
  attach-time geometry read; register pokes alone don't light it)
  stretched to ~87 ms in `ocbk_top` and **blinked at ~11.5 Hz** while lit
  (a second `ocbk_top` counter, `ide_blink`, held at 0 while the LED is
  dark so every burst starts in the ON half: an isolated op is one clean
  ~43 ms flash — the stretch window is exactly one blink period — while
  continuous access, which re-arms the stretch every few µs, blinks
  instead of sitting solid). **Increment (b) — the SD/SPI
  backend (`src/sd_backend.sv`) — DONE, CONFIRMED ON HARDWARE
  2026-07-18: the BIOS boots an OS from the SD-backed HDD image.** The
  card in the megasd slot (PIN_61–66, esemsx3 SPI-mode pin roles:
  DAT3 = CS — push-pull per the virq_n lone-Z rule — CMD = MOSI,
  DAT0 = MISO, DAT1/DAT2 pad-only Z with QSF weak pull-ups, the
  pDac_SR class of intentional pad tri-state) holds the raw AltPro
  image dd'd at card LBA 0 (`gen_ide_image.py` also emits the dd-able
  `ide_image.bin`); `bk_total` = the FULL card capacity from the CSD.
  Init ladder: >=74 CS-high dummy clocks, the **warm-reset recovery
  preamble** (see the next bullet), then CMD0/CMD8/ACMD41(HCS)/CMD58/
  (CMD16)/CMD9 at /256 =
  377 kHz, then /8 = 12.08 MHz data (the epcs_boot shifter idiom:
  mode 0, MSB first, launch at the fall, sample late-high); SDSC
  byte- AND SDHC/SDXC block addressing, both CSD capacity formulas;
  CMD17/CMD24 single-block; SPI-default CRC policy (real CRCs only on
  CMD0/CMD8); CMD17/CMD24 single-block only. All sys_clk — no CDC on the
  seam; reset DCLO-only like the engine (card re-init at power-on AND
  warm reset = "insert card, press reset" — the slot has NO card-detect
  pin).
  **TIER-2 MULTI-BLOCK (CMD18/CMD25) WAS REVERTED 2026-07-23** after
  being implemented and hardware-confirmed (2026-07-21/22). It coalesced
  a contiguous run into one streamed transfer, saving the ~10-byte
  command frame per sector — ~7 µs against a 342 µs block at the /8 data
  clock, i.e. **~2%**. That 2% is invisible: the BK drains 256 words
  through the task file at 4.03 MHz (~500–750 µs per sector), so the
  DRAIN is the bottleneck and the tier-1 prefetch already hides the whole
  fetch behind it. Against that it cost a real fault — streams were
  closed LAZILY (only when the next op turned out non-contiguous), so one
  stayed open across idle time, a warm reset left the card streaming
  (DCLO resets us, not the card), and the BIOS could not find the drive
  until a SECOND reset press. Chasing that cost a recovery preamble, a
  whole-ladder retry, an idle-close timer, four structural timing fixes
  and ~150 LE. **If it is ever revisited: close the stream when the
  OPERATION ends** — ao486's `rtl/soc/driver_sd/card_read.v` issues CMD12
  on the last sector of every read, so a stream never outlives the
  transfer — not lazily. (That driver is native 4-bit SD, where responses
  ride a separate CMD line and streaming data cannot corrupt them; SPI
  shares MISO between data and responses, which is why this whole failure
  class exists here and not there.)
  **WARM-RESET RECOVERY PREAMBLE + WHOLE-LADDER RETRY (kept from the
  tier-2 episode):** DCLO resets US but NOT the card, so a warm reset can
  land mid-transfer and leave the card holding the rest of a block. It
  then answers the init ladder with image data, and ONE stray byte
  anywhere in the ladder is fatal — `S_CMD0_R` mis-reads R1, and worse,
  `S_CMD8_R` reads any byte with bit 2 set as "illegal command = a v1
  card", after which an SDHC card gets ACMD41 WITHOUT HCS and by spec
  never leaves idle. Cure, before CMD0: send **0xFD** (stop-tran; inert
  unless something left a write-multiple open — MSB set, so never a
  command start), wait out any program-busy window (`PRE_BUSY_BYTES`,
  time-sized at ~255 ms = the SD write timeout), send **CMD12** (closes a
  read-multiple; a harmless illegal-command otherwise), then **flush a
  FIXED `PRE_FLUSH`=1100 bytes** — a whole block + token + CRC + R1 +
  busy — before waiting for the bus to look idle (`PRE_IDLE`/
  `PRE_FF_RUN`). The fixed drain is load-bearing: the residue is image
  data, and on a BK disk that data is full of 0xFF runs (the IDE layer
  inverts, so BK zero-filled regions are stored as 0xFF), so an
  "exit once the bus looks idle" flush stops INSIDE the residue. Then
  ≥74 CS-high clocks again, immediately before CMD0. States `S_PRE_*`,
  with a private `pre_cnt`/`pre_z` deliberately NOT another `wait_cnt`
  load site. **`S_RETRY`**: EVERY init-stage failure (not just CMD0's)
  re-runs the whole recovery, up to `INIT_TRIES`=8, clearing `v2`/`sdhc`
  so each attempt re-types the card — the automatic equivalent of the
  second reset press, and the only cure that does not depend on guessing
  which byte got corrupted. `dbg_fail` carries WHERE init died (1 CMD0 …
  5 ACMD41-stalled-as-v1 … 10 CSD), available for LED bring-up.
  Oracle: `sim/ide/run_sd.sh` leg 4 + the `+cmd0busy`/`+cmd8junk`
  injections, mutations 10–14; the model gained two real-card tolerances
  (an inert 0xFD and a CMD12 with no stream open, counted apart).
  Enable-gated, so a
  stock machine never clocks the card. A failed/absent-card init parks
  media-absent = exactly the old increment-(a) tie-off; data-op errors
  complete done+error (the engine ignores them — the BkEmu rc rule;
  only the attach-time geometry read honors `bk_error`). BYTE-FSM RULE
  (a design-review catch — the bug would have shifted every command
  frame): a state asserts the byte engine's `x_go`/`x_tx` only in
  NON-`x_done` cycles, so a state change never launches the next byte
  with the old state's data. **STA — the `st` next-state cone is this
  module's chronic critical path** (2026-07-23): every wide compare
  tested at a state decision lands in it, and the FSM is big. Cures, all
  the same shape — precompute into a flop, never re-derive at the
  decision point, and NEVER reach for an SDC exception: `x_ff` ("the byte
  received was 0xFF", computed in the byte engine), `wait_z` (the 20-bit
  timeout zero-test), `pre_z`, `widx_last` (the 8-bit last-word test),
  and `d_oob` (the 28-bit capacity compare, precomputed at the A_IDLE
  capture edge — legal because the port holds its fields until bk_ack).
  Two quasi-static signals needed the `model_bk11_q` treatment as well:
  `smk_en_q` in **qbus_mem** (registered in the PARENT, not in
  mem_mapper, because `run_mapper.sh` flips smk_en and compares the
  decode combinationally with `#1`) and `enable_q` here. **`enable_q`
  must reset to 1**, not 0: `S_SETTLE` parks in the DEAD-END `S_DISABLED`
  the moment it sees `!enable_q`, and it is evaluated on the first cycle
  out of reset — resetting that flop to 0 disabled the backend on every
  reset even with a card present (caught by the `-DSD_STACK` leg).
  Post-fix sys_clk +0.572 ns / TNS 0. **The same shape bit `smk_ide` in
  Phase 9 (2026-07-25):** `scount`'s next-state cone carried the 9-bit
  `ptr == 9'd256` block-complete compare, and when the `N_EXT` work
  re-placed the fitter (+19 LE) that cone went **+0.481 → −0.414 ns** —
  a module the change never touched, which is exactly how placement-
  fragile this design is at 58 % LE. Cure in the same idiom: `ptr` only
  ever holds 0..256 (the E_DRAIN advance runs only with drq and reloads
  at 256; the E_FILL advance is guarded by `ptr != 256`), so the test is
  the single bit `ptr[8]` — `wire ptr_full = ptr[8]`, nine inputs out of
  the cone.
  **BK-0010 + SMK (BkEmu `BK_0010_SMK512`) — DONE, CONFIRMED ON HARDWARE
  2026-07-23 (the BIOS boots and loads an OS on a BK-0010):** the SMK is an МПИ
  expansion board and `SmkMemoryManager` is ONE class shared by both
  configurations, so every SMK term (`smk_reg_wr`, `smk_act`, `sel_fdd`,
  `sel_ide`, the `smk_ide`/`sd_backend` enables) is gated on `smk_en`
  ALONE. The only model-dependent part of the layout logic is WHICH
  standard memory a mode deselects: on bk11 the BOS ROM + the second
  banked window (the `seg_std` vector), on bk10 the **monitor ROM** —
  the new commit-decoded `mon_en` flag (`selectBk10MonitorRom`; set in
  SYS/STD10/STD11/RAM11), consumed through
  `std_vec = model_bk11 ? seg_std : (mon_en ? 8'b0000_0011 : 0)`. So on a
  bk10 a "standard" segment is covered ONLY for segs 0,1 (0100000–0117777
  = the monitor ROM) and only while `mon_en`; **the machine's own BASIC
  region 0120000–0177577 is MK_NONE wherever the SMK does not cover it**
  (STD11 segs 2–5, RAM11/HLT11 segs 2,3) — BkEmu's bk10 SMK config has no
  BASIC ROMs at all, and on real hardware the SMK drives those addresses
  in every other mode. HLT11 is the ONE mode where `mon_en` is observable
  (segs 0–3 all dead). Everything else is shared, so a model flip finds
  the same layout. The BIOS **auto-detects the model** (doc/smk64.mac
  `START`): with vector 4 planted it writes 0177662 — replied on a bk11
  (qbus_mem's model-gated `sel_vreg`), un-decoded on a bk10 where under
  SYS it is a rom7 ROM write → trap 4 → the `MODE_STD10` commit ("для
  10"). HLT10, the SMK HALT-debugger mode (СТОП's HALT-entry stores
  caught by the write-only 177674/76 extent, vector from 160002/4 = SMK
  RAM seg 6) is what that machine is for. No blob change: `epcs_boot`
  loads both blobs unconditionally, so the BIOS is resident at
  `SMK_BIOS_BASE` whatever DIP 1 says.
  **Still deferred:** the SMK-RAM
  `ram_init` pattern, real data CRC16, MMC cards, and
  `N_SMKREG`/`N_IDE` recalibration (`N_EXT` is done — see the next bullet).
  Oracles: `sim/run_mapper.sh` + `sim/smk/run.sh` (**both legs** — bk11
  and `+bk10`) + `sim/ide/run.sh`
  (BOTH passes — disk model AND the `-DSD_STACK` real SPI stack) +
  `sim/ide/run_soc.sh` + `sim/ide/run_sd.sh` (see the sim list) +
  `sim/run_boot_check.sh +smk` / `+smk +sdspi` / `+smk10` +
  `sim/smktime/run.sh`.
- **SMK512 access time `N_EXT` = 1 (Phase 9, CALIBRATED against real hardware
  and CONFIRMED ON HARDWARE 2026-07-26; was the Phase-8 placeholder
  `N_RAM` = 4):** measured with a
  tone-frequency program (`doc/sndtestsmk.mac` — 192 `SOB` iterations around a
  177716 speaker toggle, so one half-period is 197 fetches from the resident
  memory and nothing else), run on a **real BK-0011M + SMK512** and on the
  board, with the SAME loop run from ordinary RAM as a control:

  |                       | loop in SMK RAM | loop in ordinary RAM (control) |
  |-----------------------|-----------------|--------------------------------|
  | real                  | 601 Hz (3351 cyc) | 478 Hz (4212 cyc) |
  | board, `N_EXT` = 4    | 514 Hz (3918 cyc) | 482 Hz (4177 cyc) |
  | **board, `N_EXT` = 1**| **602 Hz  (+0.17 %)** | 482 Hz (+0.84 %) |
  | `sim/smktime`, `N_EXT` = 1 | 599 Hz (3362 cyc) | 482 Hz (4176 cyc) |

  The control leg landing at +0.8 % is what makes this a measurement of
  `N_EXT` and not of the clock rate, the access count or the CPU core — all
  three are thereby validated, and the entire −14.5 % sat in that one
  constant. One unit of N is exactly one CPU cycle (independently: `BR` costs
  16 cycles at `N_RAM=4` in `sim/bk10/golden.txt` and 13 at `N_ROM=2` in
  `golden_037_rom.txt`), and the gap was 567 cycles / 197 accesses = 2.88 —
  i.e. the real board replies **within the strobe cycle**, like any async
  external SRAM board, the same reason `N_KBD = 1`.
  **The hardware result also identifies what the residual is**, and it is NOT
  the uniform global bias it looked like from the sim alone: SMK RAM came out
  at +0.17 % while ordinary RAM stayed at +0.84 %, so a clock/core error can
  be at most ~0.17 % and the other ~0.67 % belongs to **the 037
  cycle-stealing model alone** — 36 cycles short over 197 accesses, i.e. we
  steal ~0.18 cycles per access too FEW (1.31 vs the real ~1.49). That is the
  next thing this method can calibrate, and `sim/smktime`'s control leg is
  already the instrument. (The board reading HIGHER than the sim's 599 is
  expected and was predicted: the tb's port-2 model saturates the arbiter
  while the shipped video fetch is paced — see the residual note below.)
  Two mechanisms make N=1 expressible, **both gated on `N_EXT == 1` so they
  constant-fold away if it is ever raised**:
  * **`qbus_mem`'s `ext_fast`** — the wait FSM counts `N-2` edges and cannot
    express N=1, so the reply is issued at the *detection edge itself*. Only
    the mem-region `MK_EXT` leg (`sel_ext && !ovl_zone`) takes it; the I/O-page
    extent keeps `N_ROM` for the start-vector-assist reason above. Reads
    require `mem_ready`; **writes do not** — a posted write whose data was
    captured one sclk after DOUT, and u_dp is single-threaded so the next
    cycle's fetch cannot overtake it.
  * **`cpu_sdram_dp`'s `fast_rd`** — at N=1 the reply lands *before* a
    DIN-issued read could have finished, so the MK_EXT read starts at **SYNC**
    instead. **Rule: a fixed reply shorter than the SDRAM latency requires the
    fetch to start at the address phase, not at the strobe.** Three things it
    needs, each a bug that was actually hit: WTBT must be **latched** one sclk
    into the SYNC (`wtbt_hold`) because its address-phase meaning is only on
    the wire for ~120 ns — sampling it live makes every write look like a read,
    fire an early fetch and get **dropped**; `early_pend` must suspend
    `D_DONE`'s strobes-idle exit until DIN arrives, or the fetch completes and
    `mem_ready` falls again during the address phase; and `pre_done` keeps it
    to one issue per SYNC so a DATIO's write half still goes out normally.
    Sampled at `sync_sr[1]` (2 sclk), **not** [0]: that arc is `qbus_sync`,
    false-pathed in the SDC, so STA checks none of it — one sclk earlier is
    worth 601.7 Hz vs 598.9 and halves the margin on a path no tool is
    watching (the SEED-3 lesson).

  Residual: the early read gets ~22 sclk of head start and the SDRAM needs ~8,
  but the arbiter grant costs 4..14 more, so a minority of reads miss by one
  edge and take the ordinary S_WAIT path (+1 cycle, no `dbg_romgate`) — that
  is the 3362 vs the ideal 3327, and `sim/smktime`'s `EXTRD fast/slow` pins it.
  The shipped design's port 2 is paced rather than saturating like the tb, so
  the board should read slightly faster than the sim. Knock-on: the speed-up
  makes СТОП re-enter once inside its fixed 64-cpu_clk one-shot (the HALT entry
  now fits), which `sim/smk` §12 was pinning too tightly — see the note there.
  **Two STA knock-ons, both in modules this change never touched** — worth
  internalising, because it is what "placement-fragile at 58 % LE" means in
  practice: +19 LE re-placed the fitter and took sys_clk +0.481 → −0.414 via
  `smk_ide`'s `scount` cone, then → −0.023 via the mapper↔bus-pad loop. Both
  fixed structurally in the established idioms (`ptr_full = ptr[8]`;
  `rdata_oe = oe_arm && !din_n`), never an SDC exception. Final: **+0.190 ns,
  TNS 0, 6,953 LE**. Rule of thumb: after any increment here, budget for an
  STA chase somewhere else in the design.
  Oracle: **`sim/smktime/run.sh`** (three legs — the third is bk10+SMK).
- **Framebuffer conventions** (mirrored by `fb_video_tb`/`gen_expected.py`
  alike): FB = 512 slots/line × 4-bit colour nibble × 256 lines, 128
  words/line, slot `s` of a word at bits `[4s+3:4s]`, LSB-first in beam order;
  FB0 = SDRAM word `0x010000`, FB1 = `0x018000`, double-buffered (writer swaps
  at the vgate frame edge, reader latches `fb_front` at its vblank line-0
  request). **Since Phase 7 the FB nibble IS the BK-0011M physical colour
  {R1, B, G, R0}** (2-bit red, 1-bit blue/green — the machine's whole colour
  space is 16 colours): `palette_apply` looks up the 16-palette ROM
  (transcribed **verbatim** from MiSTer `BK0011M_MiSTer/rtl/video.sv` — note
  its bit-swapped nibble select `{p[0],p[1]}`); palette 0 = {0,4,2,9} =
  black/blue/green/red is the bk10 palette (bk10 ties `pal_idx` to 0);
  `vga_out` decodes the nibble combinationally, red levels 0/0x23/0x30/0x3F
  (the BkEmu 0x8E/0xC0 weights — also the CRT colour-tweak hook). bk10 RGB
  at the DAC is bit-identical to the old fixed CLUT. FB *destination* comes
  from beam counters, fetch *address* from `video_va` (else scroll breaks);
  the fetch *base* is `fb_video`'s live `vram_base` input (bk10: fixed
  `24'h002000`; bk11: the 177662-selected page). Scroll: row r fetches vram
  line `(RA − 0o330 + r) & 0xFF` (netlist-proven). `screen_mode`
  (mono-512 / colour-256) is toggled by the PS/2 Print Screen key (power-on
  default = colour-256), touches only `palette_apply` (mono ignores the
  palette, as real hardware).
- **177662 video register (Phase 7, BK-0011M):** **MiSTer `rtl/video.sv` is
  the reference** (BkEmu simplifies it). Write-only (662 reads belong to the
  014 keyboard data register in BOTH models) and bk11-only (a bk10 662 write
  keeps bus-timing-out → trap 4); high byte only: bit 15 = displayed screen
  (0 = RAM page 1 = `BK11_VPAGE0`, 1 = page 7 = `BK11_VPAGE1`), bit 14 =
  frame-IRQ2 mask (active high; irq_en = ~bit14, consumer = the EVNT/IRQ2
  bullet below), bits 11:8 = palette. Immediate effect (no per-line latch —
  BkEmu's per-scanline latch is an emulator artifact); **DCLO-only reset**
  (same deliberate nINIT exception as the map registers), defaults = MiSTer
  `def_reg662` 0o047400 (page 0, IRQ2 masked, palette 15). Implemented in
  `qbus_mem`: the ONE positive decode besides the nSEL pair — sclk
  DOUT-window capture next to `spk_bit`, write reply = fixed `N_VREG`
  (placeholder; recalibrate reference-tb-first with 0011M cycle accuracy).
  `bk_kbd014` is untouched. `ocbk_top` muxes `vram_base`/`pal_idx` on
  `model_bk11` (all sys_clk — no CDC).
- **EVNT/IRQ2 frame interrupt (Phase 9 rework, BK-0011M):** the 50 Hz system
  timer. **The 037 has NO vertical-blanking output pin** — the real board
  synthesises IRQ2 externally, and `src/bk_evnt.sv` is a gate-faithful replica
  of that detector (**schematic-traced pin-by-pin in `doc/bk0011m.sch`; see
  `sim/evnt/README.md` for the full trace and contract**): **D28** (К555ИЕ5,
  ÷2 section) with `CKA = ~(SYNCO | QA)` (D6:C, QA fed back) and its async
  clear `R0(1)&R0(2) = CLC & WTI`, feeding **D3:B** (К555ТМ2) clocked by
  **SYNCO** (037 pin 28) with `R` = the 662 enable bit (D35.5 = `~reg662[14]`,
  ACLO-reset), `~Q` → D21 (ЛП9, OC) → the **~PRT** net → D11.4 (К555ТМ9 on
  CLC) → the CPU's IRQ2 pin. WTI pulses once per fetched video word and is
  silent on non-displayed lines, so it pins QA at 0 through the displayed
  area; when WTI stops the next SYNCO edge sets QA (**set-once** — the
  feedback then holds CKA low) and D3:B publishes it one SYNCO edge later.
  **Measured against the reference netlist: assert = VGATE rise + 452 CLKIN,
  deassert = VGATE fall + 452 CLKIN** (~75 µs, ~1.18 scanlines, ~301 cpu_clk
  at the /24 rate), stable every frame. **This REPLACED the Phase-7
  "nIRQ2 = vgate" model, which was MiSTer's (`rtl/video.sv`: set at
  `vc==256`, cleared at `vc==0`) and fired 452 CLKIN too early every frame** —
  a fixed displacement of every beam-raced multicolor/gigascreen effect, which
  is what motivated the rework. Three load-bearing properties, each
  mutation-covered: (1) **the propagation race** — the QA toggle and the D3:B
  clock are the SAME SYNCO edge, and the board's delay makes D3:B capture the
  **old** QA (reproduced by non-blocking assignment ordering; sampling the new
  value loses a whole scanline); (2) **`irq_en` is an async CLEAR, not a
  combinational gate** — so un-masking mid-blanking does **not** retro-fire
  instantly (both our old model and MiSTer do), it waits for the next SYNCO
  edge; (3) **QA is set-once**. In **1/4-screen mode** (177664 bit 9 clear)
  WTI stops after the 64th displayed line, so the request authentically
  asserts **during active video**, ~129 lines before blanking — the old vgate
  model could not express this at all, and `mem/gen_bk11_test.py` §12 now
  writes 177664 = 0o001330 (full screen, as real BOS does) for that reason.
  bk_evnt is all sys_clk (the 037 outputs move on the /16 en_pos/en_neg
  strobes, so edge detection is exact — no CDC), **power-on reset only**
  (`vid_rst_n`; on the board D28 has no reset pin and D3:B's only reset is the
  662 enable bit), then 2-FF onto **posedge cpu_clk** in `ocbk_top` — the
  pin-sync rule, and authentic (D11 does the same on CLC). The vm1's internal
  arm/fire edge detector (arm while deasserted, fire on assert) makes it
  exactly one vector-0100 interrupt per frame; the DCLO default mask=1 keeps
  it silent until software unmasks. **BK-0010 has no IRQ2 source at all**
  (BkEmu attaches `SystemTimer` only for 0011M; MiSTer gates
  `irq_en = ~bk0010 & ...`) — `model_bk11` holds the whole detector cleared,
  never wire one in bk10 mode. Oracles: **`sim/evnt/run.sh`** (the authority —
  reference-netlist golden + the retimed va_037_sync reproducing it
  byte-identically, mutation-tested ×5) plus the `sim/bk11` section-12 leg,
  whose tb guard pins the no-retro-fire-on-unmask semantic (teeth-tested: the
  old wiring fails it at 34 sys_clk). The three SoC tbs (`sim/bk11`,
  `sim/smk`, `sim/boot_check_tb.v`) **instantiate `bk_evnt` rather than
  replicating it** — the `cpu_clkgen` replica-drift lesson.
- **SDRAM arbiter ports** (fixed priority, 0 highest): 0=CPU, 1=panel readout,
  2=037 video fetch, 3=FB write. There is **no fairness** — the readout MUST stay
  paced (`fb_readout` PACE ≥24 sys_clk/word); an unpaced port-1 burst starves
  ports 2/3 for a whole line. Client contract: hold req+fields until the 1-cycle
  gnt, then drop req for ≥1 cycle (`served` mask).

## Gotchas (learned the hard way)

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
  posedge D) re-times IRQ1–3/VIRQ *plus ACLO and DMR*. Modelling D8:B in our
  RPLY path is a deferred fidelity item: it quantizes assert AND release to
  falling edges, shifting cycle counts (ROM/IO by a full cycle — N_ROM would
  need recalibration), so it must go reference-tb-first with golden
  regeneration from the reference run, per the verification discipline.
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
- **CDC for SDRAM:** the wait-state FSM (`cpu_clk`) launches an SDRAM access via a
  request-*toggle* into the `sys_clk` adapter; read data is sampled back at the
  fixed RPLY point. This is safe while a worst-case access (~200 ns, incl. a
  refresh collision) finishes inside the RPLY window = (N_RAM-2) CPU clocks — ~3x
  margin at 3.02 MHz, ~1.6x at 6 MHz turbo, breaking only above ~10 MHz CPU clock
  (NOT "one CPU cycle" — the window is ~2 cycles). There is currently **no
  interlock**: a margin violation would latch stale data rather than extend RPLY,
  so re-validate at the 4/6 MHz rates (Phase 7) or add a done-gate first.
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

## Temp files

Use the session scratchpad for throwaway scripts/sims, never the repo root.
