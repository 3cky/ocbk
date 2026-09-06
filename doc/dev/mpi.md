# МПИ — the BK expansion bus and the cartridge-slot seam

The Магистральный параллельный интерфейс: the real BK-0011M expansion
connector, traced pin-by-pin from `doc/bk0011m.sch`, and the
`src/bus/qbus_slot.sv` bridge that drives it. The internal Q-bus conventions this bridges onto are in
[bus-memory.md](bus-memory.md); the RPLY re-timing rule is in `src/bus/bk_rply.sv`.

**STATUS: the slave-only bridge is IMPLEMENTED and CONFIRMED ON HARDWARE
(2026-09-06).** A real **SMK512** boots both models to the disk OS — a BK-0010
including turbo, and a BK-0011M including the SMK modes that put RAM at
0140000. A real **МСТД** module boots the board into its FOCAL ROM at 120000
and its tests ROM at 160000 answers. `mstd11m` is back when the adapter is
unplugged. So the bridge, the RPLY path, the address window, the start-vector
merge, all four deselect wires, the exported E strobe, the P4O wired-AND and
the adapter-presence pin are all confirmed on real silicon.

It took five hardware iterations, and the four findings are each written up
below because none of them is visible from the RTL alone:

1. **The start vector** — the 0177716 reset read is the one bus cycle where a
   module supplies DATA and never replies, because the vm1 self-replies for its
   own 177700–177717 block. This is what made a BK-0010 boot.
   → [The start vector](#the-start-vector-a-module-that-drives-but-never-replies)
2. **МСТД is itself an МПИ card**, so a BK-0011M has no host ROM at
   160000–177577 to deselect and the window is conceded outright. This is what
   made a BK-0011M boot — the vector was arriving correctly all along and our
   `mstd11m` image was answering it.
   → [no host ROM at 160000](#on-a-bk-0011m-there-is-no-host-rom-at-160000-to-deselect)
3. **M11 takes BOS at 140000–157777**, not the 160000 window — a separate
   after-market wire for a separate takeover. This is what made the SMK modes
   with RAM at 0140000 work.
4. **P4O (XT3.A22)** is a wired-AND on the 177716 banking latch, which ocbk
   drove push-pull and never read: a pin fight *and* functional blindness.
   → [The BK-0011M takeover is P4O](#the-bk-0011m-takeover-is-p4o-not-a-deselect-wire)

**A BK-0011M takeover is therefore THREE mechanisms, not one** — M11 for BOS,
the absent МСТД card for 160000, and P4O for window 1 — and every attempt to
make one of them do another's job failed on the board.

The start-vector increment cost **+12 LE** and no pins (9,168 / 12,060, 76 %)
and needed **no STA chase**: sys_clk setup +0.122 → **+0.269 ns**, TNS 0. That
is the point of routing the merge through `io_word` as a data term rather than
as a driver — it stays off every enable cone.

**The deselect fix then made the STA point in the other direction, and it is
worth keeping.** Dropping the model gate *removed* 29 LE (9,168 → **9,139**) and
changed nothing outside `qbus_slot` — and the fit came back a real **VIOLATION,
−0.106 / TNS −0.572**, on `mem_mapper|rom6_en → cpu_sdram_dp|addr_o`, the
mapper's own worst cone, in a module the edit never touched. **A deletion can
cost you an STA chase exactly as an addition can**; the trigger is placement,
not logic. The cure was the file's own written idiom, applied at the launch
flop: the two BIOS-window flops became a per-segment vector (`rom_vec`), so the
translate mux indexes it like `seg_smk` right below instead of comparing
`smk_seg` against 6 and 7. **+0.135 ns, TNS 0, 0 LE net, and the `rom6_en` cone
left the report** — which is the test that matters, not the slack number.

`src/bus/qbus_slot.sv` is live (`SLOT_ENABLE=1`), 30 pins are assigned, and
`sim/slot` covers it with five legs and **19** mutations. What is
implemented is **data transfer, RPLY, the host-ROM deselect and the start
vector** — no interrupts, no DMA/arbitration, no IAK chain. A real SMK512 now runs on the board in both models, so the
merge gate this file used to carry is met; read the termination note below
before plugging anything in.

## The three connectors on a real BK-0011M

`doc/bk0011m.sch` has three external bus connectors. Only one is the МПИ:

| refDes | type | what it is |
|---|---|---|
| **XT3** | СНП-58-64 | **the МПИ** — the full bus, 38 signals + power |
| XT5 | СНП-58-64 | the **keyboard** connector (`S3-*` matrix nets). Carries **no bus signal** — only `~SBROS`, `~PRT`, `~PRT1` and power |
| XT8 | РС-24 | the internal **ROM-cartridge** socket: AD0-15, SYNC, the buffered DIN (`S1-18`), the **raw** RPLY (`S1-21`), and `D36` Q1/Q2/Q4 (the 177716 bank bits). No DOUT, no WTBT — read-only by construction |

XT5 and XT8 matter here only so they are not mistaken for the МПИ. **XT3 is the
one to model.**

### Pin numbering

The СНП-58-64 has two rows, A1-A32 and B1-B32. The KiCad symbol used by the
adapter board numbers pads 1-64: **pad 1-32 = B1-B32, pad p in 33-64 = A(65-p)**.
Get this backwards and the whole map mirrors.

## The bus is UNBUFFERED — the CPU pins go straight to the connector

`S1-1`…`S1-16` (AD0-15), `S1-17` (SYNC), `S1-20` (WTBT), `S1-34` (DOUT) and
`S1-35` (DIN) each list the `D14` (К1801ВМ1) pin and the `XT3` pin **on the same
net**. There is no transceiver, no series buffer and no direction control
anywhere on the bus. The only passive parts in the path are the termination
packs below and a lone `R66` 100 Ω on SYNC.

**This is why a 3.3 V FPGA can drive it, and the 1chipMSX proves the method.**
esemsx3 (`ocm-pld-dev/esemsx3/emsx_top_common.qsf:482-511`) drives all 50
cartridge-slot lines directly off FPGA pins with nothing but

```
set_instance_assignment -name CURRENT_STRENGTH_NEW 4MA   -to pSlt*
set_instance_assignment -name PCI_IO ON                  -to pSlt*
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON   -to pSlt*   # OC lines only
```

`PCI_IO ON` enables the **PCI clamp diode to VCCIO** — that is the 5 V tolerance
mechanism, the same treatment `ocbk_common.qsf` already gives the MSX joystick
pins. Outbound, 3.3 V LVTTL V<sub>OH</sub> at 4 mA clears TTL V<sub>IH</sub>
2.0 V with margin. Real 5 V MSX cartridges work on this board through exactly
this path.

**`pSltBdir_n` is NOT a transceiver direction control.** It is MSX cartridge pin
10, BUSDIR, a cartridge→host signal. `emsx_top.vhd:69` labels it *"Bus direction
(not used in master mode)"* and line 1541 is `pSltBdir_n <= 'Z';`. The stub's
header invents a role for it and must be corrected; on the adapter that pin
carries `~DA06`.

## The adapter board

`~/projects/kicad/ocbk_mpi` (gerbers 2026-08-09) is a **passive** MSX 2×25 edge
connector → СНП-58-64 wire-through. Whole BOM: 3× BSS138, 4× 1 k, 2 caps.

- **Q1/Q2/Q3 sit only on MON10 / MON11 / BAS10** — gate on the МПИ side, source
  to GND, drain to the FPGA side, 1 k gate pulldown: an inverting open-drain
  5 V→3.3 V *receiver*. Those three are **BK-0010-specific** (they disable the
  BK-0010's internal MONITOR and BASIC ROMs) and correspondingly have **no pin
  on XT3** — a BK-0011M does not have them.
- **R1** is a 1 k pull-up on `~BSY`.
- **Everything else — all 16 AD lines and every strobe — is bare wire.**

## XT3 pin map: connector → adapter → FPGA → internal net

Cross-validated two independent ways: the `IOxxx` annotations in the adapter
schematic, and the standard MSX cartridge pinout composed with esemsx3's
`set_location_assignment` list. Both agree on all 38 signals.

| XT3 | signal | FPGA | internal net | source / sink | dir | pull-up |
|---|---|---|---|---|---|---|
| A31 | ~DA00 | 126 | S1-1 | `D14` bidir | ↔ | 3.3 k |
| B31 | ~DA01 | 123 | S1-2 | | ↔ | 3.3 k |
| B29 | ~DA02 | 127 | S1-3 | | ↔ | 3.3 k |
| B30 | ~DA03 | 125 | S1-4 | | ↔ | 3.3 k |
| B28 | ~DA04 | 134 | S1-5 | | ↔ | 3.3 k |
| A28 | ~DA05 | 132 | S1-6 | | ↔ | 3.3 k |
| B27 | ~DA06 | 133 | S1-7 | | ↔ | 3.3 k |
| B32 | ~DA07 | 124 | S1-8 | | ↔ | 3.3 k |
| B26 | ~DA08 | 137 | S1-9 | | ↔ | 3.3 k |
| A27 | ~DA09 | 136 | S1-10 | | ↔ | 3.3 k |
| B25 | ~DA10 | 140 | S1-11 | | ↔ | 3.3 k |
| A26 | ~DA11 | 135 | S1-12 | | ↔ | 3.3 k |
| B24 | ~DA12 | 143 | S1-13 | | ↔ | 3.3 k |
| A25 | ~DA13 | 139 | S1-14 | | ↔ | 3.3 k |
| B23 | ~DA14 | 159 | S1-15 | | ↔ | 3.3 k |
| B7 | ~DA15 | 168 | S1-16 | | ↔ | 3.3 k |
| B22 | ~SYNC | 131 | S1-17 | CPU `D14.41` | → | 3.3 k + 100 Ω |
| A23 | ~DIN | 156 | S1-35 | CPU `D14.38` | → | 3.3 k |
| B21 | ~DOUT | 163 | S1-34 | CPU `D14.37` | → | 3.3 k |
| B11 | ~WTBT | 166 | S1-20 | CPU `D14.40` | → | 3.3 k |
| **B20** | ~RPLY | 128 | **S1-49** | OC wired-OR → D8:B | ← | 3.3 k |
| B19 | ~INIT | 138 | **~SBROS** | CPU `D14.34` INIT **in**, 014 `D4.19`, СБРОС keys | ↔ | 3.3 k |
| B4 | ~IAKI | 178 | S1-22 | CPU `D14.36` IAKO | → | 3.3 k |
| A24 | ~IAKO | 141 | S1-54 | **014** `D4.24` IAKO | → | — |
| B5 | ~VIRQ | 176 | S1-24 | 014 `D4.23` → D11 → CPU VIRQ | ↔ | 3.3 k |
| A5 | ~PRT | 170 | ~PRT | EVNT (OC) → D11 → CPU **IRQ2** | ↔ | 22 k |
| B15 | ~PRT1 | 169 | ~PRT1 | → D11 → CPU **IRQ3** (no internal driver) | ← | 22 k |
| B17 | ~SACK | 165 | S1-50 | CPU `D14.2` SACK **in** | ← | 2.2 k |
| B16 | ~DMR | 167 | S1-51 | → D11 → CPU DMR (no internal driver) | ← | 2.2 k |
| B14 | ~DMGO | 173 | S1-52 | CPU `D14.4` | → | 2.2 k |
| B13 | ~BSY | 177 | S1-53 | CPU `D14.28` | → | 2.2 k |
| A32 | ~ROM3 | 122 | S1-65 | `D36.10` Q4 | → | — |
| A22 | ~ROM4 | 161 | S1-66 | `D36.12` Q5 | → | — |
| A1 | ~RESET | **153** | S1-25 | RC power-on generator | ← | 43 k |
| A2/A3/B2/B3 | GND | — | GND | | | |
| A4/A12/B12 | +5 V | — | +5V | | | |

**The adapter's `~IRQ` label on B5 is misleading — the traced function is VIRQ.**
Likewise `~PRT`/`~PRT1` are IRQ2/IRQ3, not port bits; those names are historical.

### ~ROM3 / ~ROM4 are 0011M bank bits, not 0010 ROM-disables

`S1-65` and `S1-66` are `D36` (К555ТМ9) Q4 and Q5 — two bits of the **177716
memory-management latch** — fanned out to modules *and* to `D32` (ЛИ6) for
internal decode. `S1-65` also appears on XT8.23. Host→module. ocbk already holds
that state in `mem_mapper`.

### Brought out on XT3 but NOT wired on the adapter

| XT3 | net | driver | what it is |
|---|---|---|---|
| **A20** | S1-62 | `D39.9` Q (К155ТМ2) | **CLC — the 4 MHz CPU clock.** Also clocks `D11` and `D8:B` |
| **A21** | S1-29 | `D8.5` Q | **the 6 MHz 037 CLKIN** (→ `D19.33`, `D28`, `D10`) |
| A30 | S1-46 | `D19.37` E (037) | the 037's E output |
| A19 | S1-85 | `D27.11` ~Q1 (К555ТМ7) | not traced further |
| B9 | S1-64 | `D7.11` Y (К555ЛА3) | → `D9.3` C, `D12.1` CA (АП2), `D33.1` |
| B10 | S1-63 | `D7.8` Y (К555ЛА3) | → `D9.4` S, `D34.3`/`D34.9` (ЛН2) |

The adapter carries schematic annotations for this group — `CL (0011М)`,
`CLC4 (0011М)`, `~ВУ`, `~ЧТРНП`, `~ЗПРНП`, `~ВБ`, `~Е (0010-01)` — but leaves
every one of these pins unconnected. **Fine for a slave-only module; a module
that clocks off the bus will not run.**

XT3 has no A6-A11, A13-A18, A29, B1, B6, B8, B18 — including the A14/B1/B6
positions the BK-0010 uses for BAS10/MON10/MON11.

## RPLY: two nets, and where an external reply joins

This is the single most important structural fact for the RTL. There are **two**
RPLY nets, not one:

```
  037 ─┐
  014 ─┼─► S1-21 ──► D21.13 ┐                     (R9  5.1 k)
 ROMs ─┘   (raw)     К155ЛП9│
                     D21.12 ├─► S1-49 ──► D8.12 K ──► D8:B ──► CPU RPLY pin
           D34.2 (ЛН2, OC) ─┤    (bus)    D33.11 ──► J        (К531ТВ9,
           XT3.B20 ─────────┘   (E6 3.3 k)                     clk = CLC S1-62)
```

- `S1-21` — the **internal** wired-OR: 037 (`D19.34`), 014 (`D4.28`), both
  RE2A ROMs, `R9` 5.1 k. Also on **XT8.2**, so an internal ROM cartridge replies
  here.
- `S1-49` — the **bus** RPLY: `D21.12` (open-collector) wire-OR'd with `D34.2`
  (**К555ЛН2 = open-collector** inverter) **and XT3.B20**, `E6.3` 3.3 k.

So an МПИ module's RPLY joins **after** the internal merge but **before** the
D8:B re-timing flop. **`bk_rply.sv` describes D8:B correctly and the slot reply
must feed INTO it, not around it.** An external slave is fully asynchronous, so
it is the one reply source in the design that does not satisfy the 1801ВМ1
falling-edge pin-sync rule by construction — which is exactly what D8:B exists
to fix. Do not re-time the existing internal slaves a second time: `bk_rply.sv`'s
header explains why that would double-count constants calibrated with this flop
already inside them (`N_EXT`, `N_VREG`, `N_KBD`).

Note the schematic labels D8's type as `KD521A`; that is a schematic attribute
error — the part is a 16-pin dual JK (К531ТВ9), section A generating the 6 MHz
CLKIN and section B being the RPLY re-timing flop.

## D11 — the CPU async-input synchroniser

`D11` (К555ТМ9, hex D flip-flop) is clocked on pin 9 by **CLC** (`S1-62`). Every
one of its six outputs goes to a `D14` input pin. **This is the "1801VM1
pin-sync requirements" rule in silicon: every asynchronous CPU input is reclocked
on the CPU clock before it reaches the core.**

| D11 | D input | Q output → CPU |
|---|---|---|
| D1 | `D1.2` (К555ЛН1) ← `R1` 750 Ω + `VD1` — the **СТОП** key | Q1 → `D14.31` **IRQ1** |
| D2 | **~PRT** — `D21.8` (ЛП9, OC) ∨ **XT3.A5** | Q2 → `D14.32` **IRQ2** |
| D3 | **~PRT1** — **XT3.B15 only**, no internal driver | Q3 → `D14.33` **IRQ3** |
| D4 | `S1-24` — 014's IRQ `D4.23` ∨ **XT3.B5** | Q4 → `D14.35` **VIRQ** |
| D5 | `D2.15` (К561ПУ4) — the power-fail comparator | Q5 → `S1-57` → `D14.30` **ACLO** |
| D6 | `S1-51` — **XT3.B16 only**, no internal driver | Q6 → `D14.5` **DMR** |

`~PRT`'s internal source is the EVNT detector: `D3:B` (К555ТМ2) with
C = `S1-36` = the 037's **SYNCO** (`D19.28`) and D = `S1-37` = `D28.12` QA
(К555ИЕ5) — the D28+D3:B pair `src/peripheral/bk_evnt.sv` models. Its `~Q`
(`S1-86`) drives `D21.9`, and `D21.8` open-collectors the result onto ~PRT.

Consequences for the RTL:

- **IRQ3 is free and entirely module-owned.** ocbk ties `pin_irq_n[2]` to
  `1'b1`, which is correct for a bare machine — the slot is the only thing that
  will ever drive it. The cheapest possible first slot signal.
- **IRQ2 and VIRQ are shared**, so both need OR-merges: `bk_evnt` ∨ slot,
  `bk_kbd014` ∨ slot. Per the `tri1` gotcha these must OR the **active-high**
  asserts and invert at the top — never go back to tri-state Z.
- **DMR reaches the CPU only through D11.** A slot DMR is not a direct CPU pin
  connection.
- ocbk currently resyncs ad-hoc (`irq2_sr`, a 2-FF chain on `posedge cpu_clk`).
  Once the slot can drive four of these, one shared D11-equivalent flop bank on
  `cpu_clk` is the faithful structure.
- **`D14.3` DMGI and `D14.6` SP are tied to +5 V** on the real board, and
  `D14.26`/`D14.27` (RA0/RA1) likewise — so ocbk's `pin_dmgi_n(1'b1)`,
  `pin_sp_n(1'b1)` and `pin_pa_n(2'b11)` tie-offs are authentic, not
  simplifications.

## The host-ROM deselect: four lines, four different windows

**CONFIRMED ON HARDWARE 2026-08-30, the hard way.** Traced from
`doc/bk0010-01.sch` and `doc/smk512-scheme-v1.0.sch` after a real МСТД module
booted into FOCAL but died with a bus error on its tests ROM.

A BK-0010-01 has **four** KR1801RE2A mask ROMs, and each is silenced by a
different mechanism:

| ROM | part | window | CE | DIN |
|---|---|---|---|---|
| DS17 | 017 | 100000–117777 MONITOR | **GND** | S1-18 (normal) |
| DS18 | 106 | 120000–137777 BASIC | **XT3.A14** | S1-18 |
| DS20 | 107 | 140000–157777 BASIC | **XT3.A14** | S1-18 |
| DS19 | 108 | 160000–177577 BASIC | **GND** | **S1-46 = XT3.A29 = E via R60** |

Two things fall out, and both were wrong in the first implementation:

- **`BAS` (A14) covers 120000–157777 only** — segs 2–5. It is one CE shared by
  DS18 and DS20. Giving it segs 6,7 as well makes ocbk stand down over a window
  no module has claimed, and the CPU bus-times-out there.
- **The 160000 window has no CE at all.** It is silenced by taking away its READ
  STROBE: DS19's DIN comes from `XT3.A29`, which is the 037's **E** through the
  series resistor `R60`, so a module that holds A29 overrides R60 and wins.

`DS17`'s CE is hardwired to GND, so **MON10 and M11 are after-market wires**
the SMK512 installation adds. That is why they appear on no stock schematic —
neither the BK-0010-01's nor the BK-0011M's — and it is why they are real
rather than invented. **USER-AUTHORITATIVE, 2026-09-06:** M11 takes the
BK-0011M **BOS** at 140000–157777 so the module can put a RAM window there. It
is *not* the 160000 window — that one needs no wire at all (see below), and the
two are separate takeovers that do not substitute for each other.

The SMK512's own bus connector (`P5`) drives all four into its CPLD:

```
P5.B1  = MON10 -> U1.40      P5.A14 = BAS   -> U1.43
P5.B6  = M11   -> U1.41      P5.A29 = BAS2  -> U1.120
```

### The resulting map

| line | МПИ | FPGA | disables | segs | model |
|---|---|---|---|---|---|
| MON10 | B1 | 180 | MONITOR 100000–117777 | 0,1 | bk10 |
| BAS | A14 | 175 | BASIC 120000–**157777** | 2,3,4,5 | bk10 |
| **BAS2** | **A29** | **160** | BASIC 160000–177577 | 6,7 | bk10 |
| **M11** | **B6** | **174** | **BOS 140000–157777** | **4,5** | bk11 |

### On a BK-0011M there is no host ROM at 160000 to deselect

**USER-AUTHORITATIVE, 2026-09-06, and it is what fixed the BK-0011M no-boot.**
The МСТД ROM at 160000–177577 is **not on the BK-0011M motherboard**. It is
itself an МПИ card, so it is **mutually exclusive with an SMK512** — plug the
SMK512 in and the МСТД board comes out. The BK-0011M motherboard carries BOS at
140000–157777 and nothing above it.

Our blob carries `mstd11m.rom` there because МСТД is the stock fit, so the rule
is: **when the slot is live on a BK-0011M, the connector owns segments 6,7**,
whatever any deselect wire does. "Live" now includes the adapter actually being
fitted — see the presence pin below — so a BK-0011M with no adapter keeps its
`mstd11m` image rather than finding nothing at 160000. No wire is involved; the host simply has
nothing there. On a BK-0010 the same addresses *are* motherboard ROM (BASIC
bank 3, DS19), which is exactly what BAS2 takes away — hence the model gate.

```systemverilog
wire mstd_slot = slot_live & model_bk11;
...
    | (bas2      ? 8'b1100_0000 : 8'h00)   // bk10: DS19, via BAS2
    | (mstd_slot ? 8'b1100_0000 : 8'h00);  // bk11: the МСТД card is absent
```

This is the path the **start vector** needs. The merge delivers PC = 0166400,
which is in segment 6; without the concede `mem_mapper` served `MK_ROM` from
`mstd11m` and the CPU executed MSTD payload (`177736` at 0166400) instead of
the module's BIOS entry (`000766`, then `MOV #1000,SP`). That is the whole
BK-0011M hang — the vector was right and the destination was ours.

This is a **different** window from M11's. A BK-0011M takeover is therefore
three separate mechanisms, and all three are needed:

| what | how | window |
|---|---|---|
| BOS | **M11** (an after-market wire) | 140000–157777, segs 4,5 |
| the МСТД slot | nothing — the card is absent | 160000–177577, segs 6,7 |
| window 1 | the **P4O** wired-AND on XT3.A22 | 100000–137777 |

The BK-0010 half of M11's contract (it must move nothing there, since the wire
does not exist on that machine) is pinned by `gen_slot_test.py` sub-test 7d and
by mutation D8.

All four arrive **active low**: they are asserted by pulling the МПИ line to
**+5 V**, and the adapter inverts each through a BSS138. That inversion is not
cosmetic — a static 5 V into a PCI-clamped 3.3 V pad would conduct through the
clamp continuously, unlike the bus lines where 5 V is only transient.

### Adapter presence — slot pin 44

**USER-SUPPLIED, 2026-09-06.** The МПИ adapter ties **slot pin 44 (FPGA pin
179)** to GND. With no adapter the pad's own ~25 k pull-up holds it high, so
**low = fitted**, and it needs no wire of its own on the adapter beyond the
ground it already has.

`qbus_slot` folds it straight into `slot_live`, next to DIP 8:

```systemverilog
logic slot_live;
always_ff @(posedge cpu_clk or negedge rst_n)
    if (!rst_n) slot_live <= 1'b0;
    else        slot_live <= &pres_sr[2:1] & ~smk_en;
```

Two reasons it earns a pin rather than being assumed:

- Without the adapter the МПИ pins are a bare MSX cartridge edge. Sampling
  floating inputs and driving a cartridge bus is not something to do on a
  guess.
- The BK-0011M concede above hangs off `slot_live`. Without a presence term a
  bk11 user with DIP 8 off and no adapter would lose МСТД at 160000 — conceding
  a window to a module that is not there. That was the one real cost of the
  concede, and this removes it.

It is **registered**, not just synchronised. `slot_live` reaches output-enable
cones (`slot_ad_oe`, the `pSltInit_n` open drain), and the enable-cone rule says
a quasi-static term there gets its own flop rather than another level of logic.

### E, and why a module can be mute without it

`va_037_sync` already produces the strobe, byte-identically to the reference
netlist (`va_037_sync.sv:207`):

```systemverilog
assign PIN_nE = PIN_nSYNC | PIN_nDIN | (A[15:7] == (16'o177600 >> 7));
```

— a read cycle outside the I/O page, which is exactly what makes it safe as the
strobe for a window that abuts the I/O page at 177600. It was left unconnected
in `ocbk_top` until 2026-08-30.

**A module's top-window ROM reads the raw E on `XT3.A30`.** МСТД does exactly
that: its `D1` (RE2A-019, the tests ROM) takes its DIN from A30 while its `D2`
(RE2A-018, FOCAL) uses the normal `~DIN` on A23. So without E exported, the
tests ROM has no strobe, never drives data, never replies — a bus error, while
FOCAL works perfectly. That is the failure the board showed, and mutation
**S7** in `sim/slot` now pins it.

The SMK512 does **not** connect A30, so E matters for МСТД-class modules only.
It does connect A22 (`P4O` → U1.91), but as an input — on a real BK-0011M that
pin is driven push-pull by `D36`, so ocbk driving it is correct.

### Two adapter wires

Neither A29 nor A30 was on the fabricated adapter; **both have been added on the
board** (2026-09-05) and the МСТД tests ROM at 160000 now works. The pads:

| МПИ | X1 pad | → MSX pin | FPGA | direction | needed by |
|---|---|---|---|---|---|
| **A29** (BAS2) | 36 | P1.24 (A8) | **160** | in, **via a BSS138** like the other three | SMK512 **and** МСТД |
| **A30** (E) | 35 | P1.22 (A6) | **158** | out, direct — 3.3 V LVTTL clears 5 V TTL V<sub>IH</sub>, and `PIN_nE` is already the right polarity | МСТД-class modules |

A29 is the one that matters for the SMK512: without it a real SMK512 hits the
same wall at 160000 that МСТД did. With both wires in, the SMK's rom6 window
answers — `S166400` typed into MONITOR boots the disk OS — which is what
localised the remaining failure to the start vector alone.

## The start vector: a module that drives but never replies

**This is why a real SMK512 would not boot** (2026-09-05, found by reading the
vendored core after the board went to MONITOR instead of to the disk OS).

A BK starts by reading its start address from **0177716**. Two facts about that
cycle, both from `src/cpu/vm1_qbus.v`:

| line | what it says |
|---|---|
| `ad_oe = ... \| ~(sel_16 \| sel_14 \| ~sel_in)` | for a **read** of 177716 or 177714 the CPU **releases AD** — external hardware supplies the word |
| `pin_rply_out = (sel_in \| sel_out) & ...` | the CPU **self-replies** for that read, combinationally off `sel_in` |

So the start-vector read is the **one cycle on this bus where a slave supplies
DATA and no RPLY at all**. An SMK512's rom7 window covers the whole of
0170000–0177777 in its SYS reset mode, so it answers with its BIOS word at image
offset 07716 = **0166400**; that wire-ORs with the machine's own start constant
(0100000 on a BK-0010, 0140000 on a BK-0011M) and the CPU masks the result with
0177400 → **PC = 0166400**, inside the SMK BIOS. `qbus_mem` already performs
exactly this merge for the *internal* SMK emulation
(`rdata <= rd_romio | ram_rdata`).

The first bridge gated its inward path on `slot_rd`, i.e. on the module's
**re-timed reply** — which this cycle never sends. Even when a module does reply
at 177716, `slot_rd` is ~3 `cpu_clk` behind it (two sync flops + `bk_rply` + the
flag) while the CPU samples 1.5 `cpu_clk` after DIN. The CPU therefore got the
bare start constant: **PC = 0100000** → the host MONITOR (which the SMK leaves
in place in SYS mode, so it runs and the machine looks merely wrong); **PC =
0140000** on a BK-0011M → window-1 RAM, garbage, hang. Both symptoms exactly as
the board showed them.

### The merge is a VALUE, not a driver

`qbus_slot` exports **`mpi_word`** — the module's true-bus contribution — and
`qbus_mem` ORs it into the `!sel1_n` leg of `io_word`, beside `ide_rdata` and
`joy_word`. Driving `ad_n` from the bridge instead would put a second on-chip
driver on the internal bus for the one cycle `qbus_mem` is also driving it (the
single-driver rule this design keeps everywhere — and in sim it is an X, not a
wired-AND), and it would put connector pins on an **output-enable cone**, the
STA rule that has bitten seven times. As a data-mux term it changes no reply, no
`selected` and no `ad_oe`.

### Armed for ONE read

The split bus cannot tell *"the module released the pins"* from *"the module is
driving zeros"*. The pads carry the `.qsf`'s ~25 kΩ pull-up alone (the adapter
has none), so with ~60 pF the lines need ~1.5 µs to rise while the CPU samples
~330 ns after the bridge releases them: they are still near the level of the
**address** they last carried, and **a low pin is an asserted bit** on this
active-low net. For 0177716 that stale pattern merges as 0177716 and sends the
PC to 0177400. And the exposure is not hypothetical: the SMK drives 177716 only
while its rom7 window is up, and once the BIOS commits another mode nothing
drives it — while MONITOR polls that register constantly for the keyboard
(bit 6) and the tape (bit 5).

So the window opens for exactly **one** read — the start-vector fetch, where a
module sits in its reset mode and is driving by construction — and closes when
that read ends:

```systemverilog
wire  sel1_rd = ~sync_n & ~din_n & ~sel1_n & slot_live;
always_ff @(negedge cpu_clk or negedge rst_n)
    if (!rst_n) begin vec_arm <= 1'b1; sel1_rd_q <= 1'b0; end
    else begin
        sel1_rd_q <= sel1_rd;
        if (!dclo_n)                   vec_arm <= 1'b1;
        else if (sel1_rd_q & ~sel1_rd) vec_arm <= 1'b0;
    end
assign mpi_word = (vec_arm & sel1_rd) ? ~pSltAd : 16'h0000;
```

Three details are load-bearing:

- **`sel1_n` is the CPU's own register-select pin**, stable for the whole SYNC
  window (`sel_16` registers on `clk_p` while SYNC is idle), so the window is
  opened and closed by internal synchronous terms — no connector pin is ever an
  enable.
- **The arm is keyed to `dclo_n`, not `init_n`.** `dclo_n` is the reset that
  makes the vm1 run its start sequence, so the СБРОС button re-arms it; a
  `RESET` *instruction* pulses only nINIT and must **not** re-open the window
  over a MONITOR keyboard poll.
- **The arm is spent when the read ENDS**, not at its detection edge — the CPU
  samples 1.5 `cpu_clk` after DIN.

### What would make this unconditional

Fitting the 16 AD lines with the real board's **3.3 kΩ** pull-ups (`E1`/`E4`/`E5`
on a stock BK) puts the rise time at ~150 ns and removes the stale-address
hazard entirely. Then `mpi_word` could be a plain `~sel1_n & ~din_n` merge on
every nSEL read, which is what the unbuffered board does, and the arming
machinery could go. That is the remaining reason the AD termination in the next
section matters.

## The BK-0011M takeover is P4O, not a deselect wire

**Traced 2026-09-05, after the model-blind experiment below failed on the
board.** The four ROM-lock wires are **physically per-model**:

| wired on | lines |
|---|---|
| BK-0010 | BAS (A14), BAS2 (A29), MON10 (B1) |
| **BK-0011M** | **M11 (B6), P4O (A22)** |

The adapter routes all of them from the MSX edge in **both** cases, so the FPGA
sees whatever the module drives on every line whichever model is selected —
which is exactly why `qbus_slot` gates them on `model_bk11`: **the gate emulates
which wires EXIST.** The module cannot help, because it does not know which host
it is in: in `~/projects/other/fpga/smk` (`smk64.vhd`, same family — its control
register is the "ab-used" floppy register of `doc/smk64.mac`) `bas` and `bas2`
are **tied asserted** with no model input anywhere, and `mon10`/`mon11` come from
`extended_reg`, `"0000000"` at reset.

**A model-blind version was tried and is wrong.** Honouring BAS/BAS2 on a
BK-0011M deselects 0120000–0177577 on a machine no module has claimed; on the
board it made the BK-0011M no-boot worse, not better. `sim/slot` sub-test **7d**
(M11 alone must move nothing on a BK-0010) and mutations **D4/D5/D8** now pin
the gate.

**Note what that clone RTL cannot tell you, and do not use it as an authority
on these four pins.** It has `bas`/`bas2` tied asserted and `mon11` from a
register that resets to zero — which cannot be the real SMK512's behaviour,
since the BK-0010 boot depends on BAS2 being asserted at reset and the BK-0011M
BOS takeover depends on M11. The per-model wiring, M11's window and the МСТД
card's absence all came from the user and from the board, and each of them
contradicted something this file had first inferred from `smk64.vhd`.

### What P4O actually does — `doc/bk0011m.sch`

```
XT3.A22 ── S1-66 ── D36.12 Q5  (К555ТМ9, the 177716 latch)
                 └─ D32.5  D   (К555ЛИ6, open-collector AND)

D32:  Y(6) = C(4) · D(5) = S1-65 · S1-66 = Q4 · Q5  ──► D10.2 (К155ЛА13, OC)
```

`Q4 · Q5` is the **"window 1 = internal RAM"** term — the one that open-collector
NANDs the 037's AD15 low so the 037 fronts window 1 (see
[bus-memory.md](bus-memory.md) and the traced AD15 note). And in the module,
`p4o` is declared **`out`**, driven through an Altera `opndrn` buffer from
`extended_reg(2)`, which is **0 at reset** — so a real SMK **pulls A22 low from
power-on**.

Pulling A22 low forces `Q5 = 0`, which does two things at once:

1. `Q4 · Q5` goes false → the 037 stops fronting window 1 → the host releases
   0100000–0137777;
2. `Q5` is the *inverted* bit 4 of 0177716, so `Q5 = 0` means **bit 4 set = code
   020 = window-1 ROM bank 3** — one of the **unpopulated sockets**
   (`WIN1_ROM_PRESENT = 4'b0011`), which `mem_mapper` already resolves to
   `MK_NONE`, no reply. The module answers there instead.

That is the BK-0011M takeover: a **wired-AND on one pin**, the same open-drain-
over-a-totem-pole trick as the RPLY and AD merges (`D36` is a К555ТМ9 totem
pole; the module's open drain wins).

### How ocbk implements it

Until 2026-09-06 `ocbk_top` drove `pSltRom4_n` **push-pull and output-only**, so
a module asserting `p4` fought the pad *and* ocbk never saw the bank forced.
That is why a real SMK512 never booted a BK-0011M. The pin is now a wired-AND:

```systemverilog
// qbus_slot: open-drain out, read back in
assign pSltRom4_n = rom4 ? 1'b0 : 1'bZ;             // pull low, else release
wire r4_forced = &r4_sr[2:1] & ~rom4 & slot_live & model_bk11;
```

```systemverilog
// mem_mapper, window 1 (0100000-0137777), ranked FIRST
if (rom4_force) begin kind_std = MK_NONE; phys_std = '0; end
else if (win1_rom_en && WIN1_ROM_PRESENT[win1_rom_bank]) ...
```

Four things are load-bearing:

- **Open-drain, not push-pull.** ocbk pulls low when its own Q5 is low and
  releases otherwise; the pad's `WEAK_PULL_UP_RESISTOR` (added to PIN_161 with
  this) supplies the high, and a module pulling low wins — the same wired-AND
  the board gets from the module's open drain against D36's totem pole. A22 is
  quasi-static, so ~25 kΩ is ample here, unlike on AD.
- **Ranked FIRST**, above the latch. The open drain overrides D36's *output*, so
  it beats whatever the host last wrote to 177716 — including a **populated**
  bank. Ranking it below the latch is mutation M2 in `sim/mapper_tb.sv`.
- **One term covers both effects.** `MK_NONE` gives no reply (so the module
  answers) *and* no `MK_RAM037` (so `qbus_mem`'s `ext_ram` stays low and
  `va_037_sync` never fronts the window) — which is exactly what losing `Q4·Q5`
  does on the board.
- **`~rom4` in the force term.** "A module is forcing it", not "the line is
  low": when ocbk drives it low itself, the mapper already knows from its own
  state, and a second path into the banking cone would be redundant.

Model-gated in `qbus_slot` (A22 is a BK-0011M wire) and bus-idle latched there,
then re-registered on `sclk` in `qbus_mem` — the `rom_dsl_vec` idiom, for the
same reason: a module moves it as a side effect of a write to its own register,
so it is not quasi-static and must not change under the wait FSM mid-cycle.

Cost: **+19 LE** (9,144 → 9,163), no new pin (PIN_161 was already assigned;
it is now `bidir`), and sys_clk setup **+0.202 → +0.394 ns, TNS 0** — no STA
chase, despite landing in the banking cone. `sim/mapper_tb.sv` **section 10**
pins it in BK-0011M mode with two verified mutations. **CONFIRMED ON HARDWARE
2026-09-06.**

## Termination — mostly ocbk's job, but the board helps on the net that matters

Every wired-OR МПИ net is terminated **on the BK board**, not in the modules:

| group | value | part |
|---|---|---|
| AD0-15, SYNC, DIN, DOUT, WTBT, INIT, IAKI, VIRQ | **3.3 k** | `E1`/`E4`/`E5`/`E6` NR1-4-9M packs |
| bus RPLY (`S1-49`) | **3.3 k** | `E6.3` |
| internal RPLY (`S1-21`) | **5.1 k** | `R9` |
| DMR, SACK, DMGO, BSY | **2.2 k** | `R14`/`R15`/`R17`/`R27` |
| ~PRT, ~PRT1 | **22 k** | `E7`/`E8` |
| ~RESET (`S1-25`) | **43 k** + 10 µF | `R8`, `C5`/`C14` |

ocbk is the host now, so these are ocbk's responsibility — and the adapter
board has none of them. **But the OneChipBook itself pulls three of the slot
pads to 3V3 with 1 kΩ**, and because those are the pads the 1chipMSX needed for
its own open-collector signals, two of the three land exactly where the МПИ
wants them:

| FPGA pin | why the board pulls it up (MSX) | adapter carries | verdict |
|---|---|---|---|
| **128** | WAIT, open collector | **~RPLY** | **ideal.** The single most critical net on the bus, terminated harder than the real BK's own 3.3 k. Rise time on RPLY is no longer a bring-up worry |
| **138** | RSV16 | **~INIT** | **ideal.** ~INIT is open-drain here — we pull low or let go — which is exactly what a pull-up is for |
| **131** | INT, open collector | **~SYNC** | **mismatch.** ~SYNC is a push-pull *output*, so the pad sinks 3.3 mA of pull-up current on every assert — most of a 4 mA budget. It gets **8 mA** in the `.qsf` for that reason. The adapter is fabricated and the МПИ↔MSX mapping is fixed in copper, so the signal cannot be moved to a quieter pad |

**What is still unterminated: the 16 AD lines and the remaining strobes**, which
have only the pads' internal ~25 kΩ to 3.3 V — about 8× weaker than the design
intent and to the wrong rail. That is now the whole of the open electrical
question, and it is a much smaller one than it looked: AD is driven push-pull
from one end or the other for the whole of every cycle, and the only moment
nobody drives it is the turnaround, which no one samples. **Measure rise time
and high level on the AD lines with a module attached before bring-up**;
`qbus_slot`'s `SLOT_ENABLE` and `RPLY_FILT` are the escape hatches, and
`RPLY_FILT` can now go to 0 with more confidence than when it was written.

## What the implementation does, and what the old stub got wrong

The rewritten `qbus_slot` is the slave-only bridge. Two equations carry it:

```
slot_ad_oe = din_n & ~slot_rd & slot_live   // the bridge drives the PINS
ad_n       = slot_rd ? pSltAd : Z           // the bridge drives ad_n INWARD
```

- **Outward** is gated on `din_n` so the pins are released for the whole of any
  read, and on `~slot_rd` so they stay released through the module's data-hold
  after DIN rises. Re-enabling the drivers the instant DIN releases puts 16
  lines of push-pull CMOS against a module that is still driving — a fight on
  every read, and **not observable behaviourally** (the CPU has already
  sampled), which is why `sim/slot` checks the two output enables structurally.
- **Inward** is gated on `slot_rd`, a flag set only from the **re-timed** reply.
  Gating on the raw pin buys nothing — the CPU samples 1.5 `cpu_clk` after the
  re-timed reply — and costs an unsynchronised, unterminated pin acting as a
  combinational output-enable on the shared internal `ad_n`. On this active-low
  wired-AND bus an extra driver of all-ones is the identity element, so the
  damage from a glitch is *silent* corruption of an internal read.
- **The address window needed no invention.** `vm1_qbus` drives `ad_oe` two
  `cpu_clk` before it drops SYNC and holds one after, so the bridge only has to
  mirror the window the CPU already produces. The old stub's
  `drive_ad = sync_n ? 1'b0 : din_n` released AD until *after* SYNC had fallen,
  leaving a real slave no setup at all — mutation **S2**.
- **`slot_live = ~smk_en`.** The internal SMK512 emulation and a real module
  claim the same addresses, so tying the slot to DIP 8 being off costs nothing,
  needs no new switch, and makes the shipped default provably byte-identical.
- **The deselect lands on `qbus_mem`'s `sel_rom`, not in `mem_mapper`.** One
  term covers the whole cycle (`selected`, the done-gate, `sel_romr`'s fetch
  enable into `cpu_sdram_dp`, the overlay merge and `turbo_mem` all derive from
  it), and it keeps the added logic off the mapper's `kind`/`phys` cone, which
  feeds one of the two worst setup paths in the design. It is an 8-bit
  per-segment mask indexed by `addr[14:12]`, **frozen while the bus is idle** —
  a module changes its deselect lines as a side effect of a CPU write to its own
  mode register, so unlike the DIP latches this is not quasi-static and would
  otherwise move under the FSM mid-cycle.
- **The deselect lines are model-gated, and that is right** — the wires are
  physically per-model (BAS/BAS2/MON10 on a BK-0010, M11/P4O on a BK-0011M)
  while the adapter carries all of them in both cases, so the gate emulates which
  wires exist. A model-blind version was tried on hardware and is wrong; see
  [the section below](#the-bk-0011m-takeover-is-p4o-not-a-deselect-wire).
- **`bsy_n` is deliberately NOT used**, though it is the natural source for a
  bus-ownership gate and XT3.B13 wants it anyway. `vm1.v:62` drives it
  `? 1'b0 : 1'bZ` onto a plain `wire` in `ocbk_top` with zero fanout — consuming
  it would need a push-pull hook in the vendored CPU (the `pin_sel_n` precedent)
  or it comes up **stuck asserted**, the `virq_n` trap, with every sim passing.
  Not worth a vendored-file change in a slave-only increment; it is the first
  item for phase 2. Note `pin_wtbt_n` and `pin_iako_n` are already on that
  warning list and are harmless because they are `tri1` nets — the trap is
  specific to plain `wire`.

### Still missing (phase 2)

The stub's old defect list, with what remains:

1. **Address setup is lost.** `drive_ad = sync_n ? 1'b0 : din_n` releases AD
   whenever SYNC is deasserted, so AD reaches the slot only *after* SYNC has
   fallen. An МПИ slave latches the address on SYNC's leading edge and would get
   zero setup.
2. **No reclock on the inbound reply** — see the RPLY section. The slot needs its
   own `bk_rply` instance; the internal slaves must not get a second one.
3. **No card-present gate.** `rply_n = pSltWait_n ? 1'bZ : 1'b0` injects a
   spurious reply onto the shared net whenever the pin floats.
4. **`pSltBdir_n` is misdescribed** and must stop being driven as a direction
   control.
5. **No DMR/SACK/DMGI/DMGO arbitration** — `pin_dmgi_n` is hard-tied `1'b1` and
   `dmgo_n` is unconsumed, so a DMA-capable module has no path.
6. **No VIRQ/IAKO chain.** `bk_kbd014` has no IAKO output, which XT3.A24 needs.
7. **PIN_153 collision.** XT3's `~RESET` lands on the pin `ocbk_top` already uses
   for `pSltRst_n`, the reset button, declared `input logic`. Sharing it as an
   input is right; driving INIT/RESET outward would need it to become `inout`.

The daisy-chain signals (IAKI/IAKO/DMR/DMGO/SACK) are all wired in copper on the
adapter — they are missing only in RTL.

## The IAK chain is a fan, not a serial chain

`S1-22` = the CPU's IAKO goes to the 014 (`D4.25`) **and** to XT3.B4 in
parallel. `S1-54` = the 014's own IAKO goes **only** to XT3.A24. So the connector
gets two grant taps at different chain depths, and a faithful ocbk must expose
both.

## References

- `doc/bk0011m.sch` (PCAD; query with the `pcad` MCP) — the authority here
- `~/projects/kicad/ocbk_mpi` — the adapter board; `kicad-cli sch export netlist`
  gives the pin↔net table
- `ocm-pld-dev/esemsx3/emsx_top_common.qsf` + `src/emsx_top.vhd` — the
  direct-drive / `PCI_IO` precedent and the BUSDIR correction
- `src/bus/bk_rply.sv` — why D8:B exists and what must not be re-timed twice
- `sim/slot/README.md` — the oracle contract, the four legs and the ten
  mutations, including the checks that had to be structural
- [gotchas.md](gotchas.md) — the `tri1` stuck-asserted rule that governs every
  new OR-merge here
