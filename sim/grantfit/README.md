# sim/grantfit — the 037 grant-rule bench

The measurement half of the open Phase-9 item: **the 037-fronted DRAM path is
pattern-dependently faster than a real BK-0011M**, which is the beam-raced
palette skew. This directory does not change any RTL. It evaluates candidate
explanations against every tone measurement that exists, all at once.

Run `./run.sh` for the baseline, `./run.sh --sweep` for the candidates. Slow
(minutes), deliberately not in `make sim`.

## Why a bench and not a patch

Two arbiter rules had already been tried and rejected, and both times for the
same reason: the rule was judged on **one** leg and wrecked another. "No grant
in the slot immediately after a grant" changes nothing at all (the CPU never
asks that soon); "≥3 slots between grants" fits `MOV #imm` and wrecks `SOB`.

There are seven real-hardware measurements. Four must move, three must not.
Judging a candidate on fewer than all of them is how the last two rounds went
wrong.

## The legs

`real` = CPU cycles on the real machine = `4.000e6 / (2·f_real)`, at the real
BK-0011M's own 4.000 MHz clock (schematic-traced: 12 MHz quartz / 3). That
makes it directly comparable with the cycle counts the bench prints, with our
+0.67 % clock offset **excluded** — the offset is real, but it is a property of
the board's 21.47727 MHz crystal, not of the memory model, and no RTL change
can fix it.

> ⚠️ The docs contain a **second** normalisation. CLAUDE.md's `N_EXT` table
> converts the same tones at 4.0270 MHz, answering the different question "what
> would *our board* have to do to emit that tone" — which carries the clock
> offset inside it, and is where its "+0.8 % control leg" residual comes from.
> Same tones, different question. Do not mix them.

| leg | program | pattern | real | baseline | |
|---|---|---|---|---|---|
| A | `sndtest662` @2000 | 192 × write to 0177662 | 6734 | 6736 | +0.03 % — **must not move** |
| B | `sndtest662` @2006 | 192 × write to RAM | 6993 | 6736 | −3.68 % — the write divergence |
| C | `sndtestimm` @2000 | 192 × `MOV #imm,R1` in RAM | 6622 | 5648 | −14.71 % — the big one |
| D | `sndtestbaby` @2000 | 24 × the Babylona block | 6211 | 5824 | −6.23 % — the skew itself |
| E | `sndtestsmk` @2046 | 192 × `SOB` in RAM | 4184 | 4176 | −0.19 % |
| F | `sndtestsmk` @2000 | 192 × `SOB` in SMK RAM | 3328 | 3327 | −0.03 % — **must not move** |
| G | `sndtestimm2` @2000 | 192 × `MOV #imm` in SMK RAM | 3929 | 3927 | −0.05 % — **must not move** |
| H | `sndtestimm2` @2046 | leg C's loop, in place | — | 5648 | cross-check, must equal C |

Every `.mac` in `doc/` carries its own reading and reasoning; the images are
consumed **verbatim** by `mem/gen_tone_test.py`, so the bytes the bench runs
and the bytes the real machine ran cannot drift apart.

**A is the sharpest "must not move" leg**: same instruction rate and the same
fetch stream as B, differing only in where the write goes. Any rule that also
slows the plain fetch path breaks A immediately. **F and G are `MK_EXT`**
(`N_EXT = 1`, not 037-fronted, no arbitration, no slot quantisation) — a
candidate that moves them has reached outside the 037 and is wrong by
construction. **H is not a hardware leg**: it is C's loop at a different
address in a different program, so `C ≠ H` means the bench is measuring the
address rather than the access pattern.

The baseline column reproduces eight numbers that were all derived
independently before this bench existed (ROADMAP's beam-race table for A–D,
`sim/smktime/golden_std` for E, `qbus_pkg`'s ideal 3326 for F,
`doc/sndtestimm2.mac`'s ideal 3927 for G, and H ≡ C). If a future run does not,
suspect the bench before believing the result.

### The one tb artefact

Legs F and G run on the `sim/smktime` stack, whose port-2 video fetch is a
**saturator** — harsher than the shipped paced fetch — so a minority of
`MK_EXT` reads miss the `N_EXT = 1` fast reply and take the +1-cycle `S_WAIT`
path. The `EXTRD fast/slow` counter makes that exact, and the `ours` column is
corrected (`avg − slow/halves`). That is the same correction by which
`qbus_pkg` derives the ideal 3327 from `sim/smktime`'s measured 3362.

## Why leg B is the discriminator

A grant rule is **direction-blind**: it delays a second back-to-back access
whether that access is a read or a write. Yet the real machine pays **+5.08
cyc** on a read+read pair (leg C) and only **+1.35** on a read+write pair
(leg B). So either

* one rule produces both — the write's extra slot being absorbed by the vm1's
  fixed DATO window, and `sim/vregtime` **proved** such absorption exists (the
  whole `N_VREG` = 1..4 ladder is bit-identical, i.e. a write reply can slide
  ≥3 cycles for free) — or
* the mechanism is not a grant rule at all.

A candidate that closes C and D but leaves B flat has not explained the data.
This is the constraint the earlier rounds did not have.

## The candidates

| | what | where | netlist-legitimate? |
|---|---|---|---|
| C1 | the board's **D8:B** RPLY re-timing flop, on the 037's reply only | tb (`+d8b`) | **yes** — a board chip the 037 netlist does not contain |
| C2 | **request setup window** at the PC==4 grant decision, 0..3 half-CLKIN phases | `patch037.py --setup` | no |
| C3 | **TRPLY clear** quantised to a CLKIN edge | `patch037.py --trply` | no |
| C4 | **minimum inter-grant gap** 1..3 slots | `patch037.py --gap` | no — and already rejected; kept as a baseline the sweep must re-reject |

**C1 is the one thing we demonstrably do not model.** On a real BK-0011M the
wired-OR bus RPLY (S1-21) never reaches the CPU directly: D8:B (К531ТВ9 negedge
JK wired as a D-FF on the CLC net) re-times it onto the CPU's RPLY pin — which
is also exactly what CLAUDE.md's pin-sync rule demands. We already satisfy that
**everywhere except here**: `qbus_mem`'s wait FSM runs on `cpu_clk = pin_clk_n`,
so every fixed-`N` slave is D8:B-correct by construction, while
`va_037_sync`'s `PIN_nRPLY` is combinational in the `sys_clk`/CLKIN domain and
lands at whatever phase the divider happens to give. So C1 *completes an
existing convention* rather than deviating from anything — and it is re-timed
on the 037's contribution **only**, because re-timing `qbus_mem`'s as well
would double-count precisely the hardware-calibrated constants (`N_EXT`,
`N_VREG`, `N_KBD`).

C2/C3/C4 contradict the vendored netlist, which has already been shown to
reproduce *our* numbers rather than silicon's (26.46/20.51 vs the real
31.7/21.4, with no SDRAM in the loop). Adopting one means the twelve `ref037`
goldens are regenerated from a run that is no longer netlist-equivalent and
**the hardware tones become the authority for that path** — a decision taken
deliberately, recorded here, and not a licence to loosen any other golden's
provenance.

Candidates are built by `patch037.py` from a **copy** of `src/va_037_sync.sv`
(the `sim/evnt` idiom: anchored rewrites that fail loudly if the RTL moved,
never an inline replica that can drift). Every register it adds is reset —
without that `RASEL` goes X and the sim hangs.

## Results (2026-07-26)

Total absolute deviation from the seven hardware legs, in CPU cycles
(`./run.sh --sweep`):

| candidate | Σ\|Δ\| |
|---|---|
| baseline (shipped RTL) | 1631 |
| C1: D8:B alone | 1428 |
| C2: setup 1 alone | 1623 |
| C2: setup 2 alone | 1426 |
| C2: setup 3 alone | 195 |
| C2+C1: setup 1 + D8:B | 195 |
| **C2+C1: setup 2 + D8:B** | **33** |
| C2+C1: setup 3 + D8:B | 998 |
| C3: TRPLY clear → en_neg / either, ± D8:B | 1631 / 1428 (inert) |
| C4: gap 2 | 1631 (inert) |
| C4: gap 3 | 937 |

### The fit: request setup = 2 half-CLKIN phases + the D8:B flop

| leg | pattern | real | fit | Δ | ±1 Hz¹ |
|---|---|---|---|---|---|
| A | 192 × write 0177662 | 6734 | 6744 | +10 | ±22.7 |
| B | 192 × write to RAM | 6993 | 7008 | **+15** | ±24.5 |
| C | 192 × `MOV #imm,R1` in RAM | 6622 | 6624 | +2 | ±21.9 |
| D | 24 × Babylona block | 6211 | 6208 | −3 | ±19.3 |
| E | 192 × `SOB` in RAM | 4184 | 4184 | 0 | ±8.8 |
| F | 192 × `SOB` in SMK RAM | 3328 | 3327 | −1 | ±5.5 |
| G | 192 × `MOV #imm` in SMK RAM | 3929 | 3927 | −2 | ±7.7 |

¹ what one Hz of reading error is worth on that leg (`cycles/f`). **Every
residual is inside the resolution of the hardware measurement itself** — the
tones were read to ~1 Hz (the `N_EXT` calibration's own figure). Baseline for
comparison: −257, −974 and −387 cycles on B, C and D.

So the answer is yes: **one rule closes the whole set**, including the RAM-write
divergence, and it does so while leaving the three un-arbitrated legs where they
were.

### Leg B is what makes the fit unique

Three different candidates are **indistinguishable on the read legs** — setup 3
alone, setup 1 + D8:B, and setup 2 + D8:B all give C = 6624 and D = 6208, i.e.
+0.03 % and −0.05 %. They differ only on the write leg:

| candidate | B | C | D |
|---|---|---|---|
| setup 3 alone | 6816 (−2.53 %) | 6624 | 6208 |
| setup 1 + D8:B | 6816 (−2.53 %) | 6624 | 6208 |
| **setup 2 + D8:B** | **7008 (+0.21 %)** | 6624 | 6208 |

Without leg B all three look equally right and there is no way to choose — which
is exactly how the previous two rounds picked a rule that later turned out to be
wrong. This is the concrete payoff of measuring the write case rather than
patching it.

It also settles the direction-asymmetry question posed above: **one
direction-blind grant rule does produce both numbers** (+5.08 cyc on a read+read
pair, +1.35 on read+write). The write's extra slot is partly absorbed by the
vm1's fixed DATO window, exactly as `sim/vregtime`'s `N_VREG` ladder predicted;
no direction-sensitive mechanism is needed.

### The mechanism, from the per-fetch gap table

`./run.sh --cand "--setup 2" --d8b --verbose` prints the cost of each
instruction — and, where an instruction is two words, of each half separately.
On leg C that is decisive (steady-state values; `LOOP <addr>` is the gap from
that fetch to the next):

| | opcode → operand | operand → next opcode | instruction |
|---|---|---|---|
| baseline | 12 | 14 | 26 |
| fit | **18** | 14 | **32** |

**The change adds one whole grant slot to the second read of a back-to-back
pair, and nothing at all to the next instruction's fetch** — which sits ~2.5
slots later and is untouched at 14. One 037 slot is 8 CLKIN = 5.333 CPU cycles;
+6 is that slot, quantised onto the integer cycle grid. That is precisely the
hypothesis the tone programs pointed at, now visible per instruction rather
than inferred from a tone.

The `SOB` leg confirms the other half: its fetch gap goes 20..22 → 20..26, i.e.
the *minimum* does not move at all and only the tail lengthens, for +0.04 cyc
per iteration overall. A fetch stream that is 3.85 slots apart never lands in
the shadow.

Leg B shows the write case as a beat: the first three writes of each unrolled
block go 32 → 34/37/37 and the remaining five stay at 32, averaging
+1.42 cyc/write against the real machine's +1.35.

### What the two ingredients mean

* **D8:B** — the board flop we were not modelling, applied to the 037's reply
  only. Physically certain (schematic), and it is what the pin-sync rule
  requires anyway.
* **setup = 2 half-CLKIN phases** — the 037 latches its grant request one full
  CLKIN before the PC==4 decision, rather than sampling it live there as the
  vendored netlist does. The netlist is a functional model, not a timing one,
  so a setup requirement at that latch is not something it could express.

Neither ingredient does much alone (Σ\|Δ\| 1426–1623); only together do they
land. That is a real interaction, not two independent corrections: D8:B moves
when the CPU *sees* the reply, the setup window moves when the 037 *takes* the
request, and only one combination puts both edges where silicon puts them.

### Negative results (worth as much as the fit)

* **C3, TRPLY clear quantisation: completely inert.** Quantising the clear to
  `en_neg`, or to either strobe, reproduces the baseline to the cycle on all
  seven legs. The "a cycle's tail delays the next fetch" mechanism is not it.
* **C4, minimum inter-grant gap = 2 slots: completely inert**, reproducing
  ROADMAP's "no grant in the slot immediately after a grant changes *nothing*"
  exactly. The CPU never asks that soon.

### ⚠️ One discrepancy with the record, unresolved

ROADMAP states that "≥3 slots between grants" **fits `MOV #imm` (31.44 vs the
real 31.7) but wrecks `SOB` (26.0 vs 21.4)**. This bench's `--gap 3` **rejects
that rule too, but for a different reason**:

| leg | A | B | C | D | E | F | G |
|---|---|---|---|---|---|---|---|
| `--gap 3` Δ% | +0.25 | **+11.18** | +1.93 | +0.04 | +0.13 | −0.03 | −0.05 |

`SOB` (leg E) is *not* wrecked here — it moves +0.13 %. What the rule wrecks is
the **write** leg, by +11 %. Since the earlier experiment was a scratch copy of
`va_037_sync.sv` that is not in the tree, the two implementations cannot be
diffed and the discrepancy stands unexplained. Note also that the first version
of `--gap` in *this* script never fired at all (it sampled `RASEL` at a slot
boundary where it is always 0) — which is exactly why a control has to be
required to reproduce a known-wrong answer, and is worth remembering before
trusting any un-cross-checked arbiter experiment, including the earlier one.

Treat the "≥3 slots wrecks `SOB`" line in ROADMAP as **unconfirmed**; the
conclusion it supports (the rule is wrong) survives either way.

### The BK-0010 (/32) side, where there is no hardware tone at all

Measured with the same bench on a bk10 stack (`--bk10`, /32, CPU:CLKIN = 2
instead of 1.5):

| pattern | baseline | fit | |
|---|---|---|---|
| 192 × `SOB` in RAM | 3920 | 3928 | +0.20 % |
| 192 × `MOV #imm,R1` in RAM | 5168 | 5944 | **+15.0 %** |

Same mechanism (`opcode → operand` 11..14 → 14..15 = one slot, which at ratio 2
is 4 CPU cycles), but the consequence is much larger than on bk11 and **nothing
measures it**: there is no BK-0010 tone recording, and `sim/bk10/golden.txt` is
the CPU core alone with a fixed-`N` memory model and no 037, so it cannot
arbitrate this either. Adopting the fit would change the /32 path by 15 % on a
very common instruction shape on the strength of the BK-0011M fit alone.

It is at least a **falsifiable prediction**: a real BK-0010 running
`doc/sndtestimm.bin` should come out ~15 % slower than the current firmware
does. Getting that recording is the cheapest way to de-risk the follow-up.

### Status: SHIPPED AND CONFIRMED ON HARDWARE (2026-07-26)

**After `make flash`: the Babylona colour smearing is gone and PALTST's colour
ribbons are flat on the board.** Those two effects are why this investigation
existed — both are beam-raced, both have the per-scanline block cost as their
vertical scale, and both were the visible face of running that block 6.25 %
fast. The fit predicted them and they went away.

This bench is now the regression that keeps the calibration pinned.

The fit is implemented — `va_037_sync`'s `GRANT_SETUP = 2` and `src/bk_rply.sv`
— so a plain `./run.sh` prints the fit column above, and that is what must stay
true. `./run.sh --setup 0 --nod8b` reproduces every pre-fix number exactly, so
the change is cleanly reversible and the two configurations are exactly what
they claim to be.

`sim/ref037` keeps **two** golden sets rather than abandoning the netlist one:
`golden_037{,_rom}.txt` are still the netlist's, byte-identical, with
`va_037_sync @GRANT_SETUP=0` diffed against them — the retime guard did not
weaken, it moved to the stock setting — and `golden_037_hw{,_rom}.txt` are the
shipped machine's, generated from the same simplest stack, with all ten
integration legs reproducing them.

What is **still not** established:

* **the tones have not been re-measured on the board.** The visual acceptance
  (Babylona, PALTST) is qualitative; the quantitative check — replaying the
  seven `doc/sndtest*.wav` on the flashed board and comparing against the
  `real` column — is still available and still able to fail. Worth doing if a
  residual ever needs chasing; it is the same recipe as the `N_EXT`
  calibration.
* that `setup = 2` is *the* physical mechanism rather than a proxy for something
  else with the same phase signature;
* that the /32 BK-0010 path is right — it moves by 15 % on two-read
  instructions and nothing measures it (see above).

D is also not fully independent of A and C — Babylona's block is six of A's
instruction plus two of C's — so the genuinely independent constraints are
A, B, C, E, F, G.
