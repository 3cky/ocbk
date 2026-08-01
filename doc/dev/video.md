# Video — framebuffer, palette, 177662 and the frame interrupt

`src/video/` plus `src/peripheral/bk_evnt.sv`. The 037's video counters and the
grant rule that shares the SDRAM with the CPU are in
[bus-memory.md](bus-memory.md).

## Framebuffer conventions

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
  **The palette is sampled at the word's DISPLAY instant, not its fetch
  (Phase 9, 2026-07-26).** `palette_apply` runs on the FB *write* side, so the
  physical colour is baked in per fetched word — the granularity is right
  (16 dots; two 177662 writes are ≥ ~10 CPU cycles ≈ ≥ 30 dots apart, so word
  quantisation can never merge two), but the *instant* was wrong: `pal_idx`
  rode `vid_fetch`, which is 3 CLKIN before the word actually reaches the
  screen, pushing every raster palette boundary ~6 dots right. On the real
  board the chain is DRAM → **К155ИР13** shift registers (D24/D25) → КР556РТ4А
  palette PROM → CRT with **no latch in between**: the ИР13s take their
  parallel data straight off the DRAM data pins (nets S5-1..16) and their mode
  pin S0 *is* `PIN_WTI`, so the word starts displaying at the WTI load.
  Measured on the reference netlist and the retimed core (one slot = 8 CLKIN):
  `vid_fetch` +0, video CAS and WTI rise +1, **WTI fall +3** — the load edge
  that counts, since the DRAM data is only valid late in its CAS window and
  any earlier edge reloads the same word. Hence `va_037_sync`'s **`vid_pal_stb`**
  tap (`vid_fetch` delayed 3 `en_neg`, generated UNCONDITIONALLY — re-qualifying
  on `~HGATE` would drop the last slot of every line) and `fb_video`'s
  **`F_HOLD`** state, which holds the fetched word until its display-instant
  palette has been sampled. The fetch *address*/page stays on `vid_fetch`,
  deliberately: the page bit re-addresses the DRAM, so its instant is CAS
  (+1), not display. Residual uncertainty is the +1..+3 span (≤ 4 dots) — the
  D8/D10 dot-clock phase would be needed to pin it further.

## The 177662 video register

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
  DOUT-window capture next to `spk_bit`, write reply = fixed `N_VREG`.
  `bk_kbd014` is untouched. `ocbk_top` muxes `vram_base`/`pal_idx` on
  `model_bk11` (all sys_clk — no CDC).
  **`N_VREG` = 1 (Phase 9, 2026-07-26; was the `N_ROM` placeholder) — and the
  measurement that set it also proved the constant is UNOBSERVABLE.** The
  schematic says the board replies combinationally: D35 (the palette register,
  К555ТМ9) is clocked by net S1-78 = **D6:C** (К555ЛЕ4 NOR of the 037's BS
  D19.38, DOUT D19.40 and the latched address bit D27.9), and *that same net*
  drives **D34.1** (К555ЛН2, open-collector) whose output wire-ORs onto
  **S1-49** = the K input of **D8:B**, the flop that re-times RPLY onto the
  CPU's RPLY pin. It has to be that circuit — the bus RPLY net S1-21 has
  exactly four drivers (014, 037, the two RE2A ROMs), the 014 does **not**
  reply to a 662 write (`sim/ref014/README.md`) and the 037 decodes only
  177664. So N=1 is the faithful value (expressed by `qbus_mem`'s `vreg_fast`,
  the `ext_fast` mechanism reused, gated on `N_VREG == 1` so it folds away).
  **But `sim/vregtime`'s `--sweep` shows N = 1..4 give BIT-IDENTICAL cycle
  counts** on two instruction shapes, with the VREGWR probe confirming the FSM
  really took the other path: a DATO's RPLY in that range lands inside the
  vm1's fixed write cycle and never moves the next SYNC. This closes the
  placeholder permanently in BOTH directions — no fidelity risk, and **not** a
  candidate for beam-raced-palette timing artefacts (that was the hypothesis
  the oracle was built to test, and it falsified it).

## EVNT/IRQ2 frame interrupt

- **EVNT/IRQ2 frame interrupt (Phase 9 rework, BK-0011M):** the 50 Hz system
  timer. **The 037 has NO vertical-blanking output pin** — the real board
  synthesises IRQ2 externally, and `src/peripheral/bk_evnt.sv` is a gate-faithful replica
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
