# МПИ — the BK expansion bus and the cartridge-slot seam

The Магистральный параллельный интерфейс: the real BK-0011M expansion
connector, traced pin-by-pin from `doc/bk0011m.sch`, and what `src/bus/qbus_slot.sv`
must become to drive it. The internal Q-bus conventions this bridges onto are in
[bus-memory.md](bus-memory.md); the RPLY re-timing rule is in `src/bus/bk_rply.sv`.

**STATUS: NOTHING IS IMPLEMENTED.** `qbus_slot` is a stub held at
`SLOT_ENABLE=0` and instantiated in `ocbk_top` with **every physical port left
unconnected**, so it synthesises to nothing. The `.qsf` pin block is a comment,
truncated after two example lines. There is no oracle. This file is the traced
reference the implementation must be written against, not a description of
working code.

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

## Termination — this is ocbk's job now

Every wired-OR МПИ net is terminated **on the BK board**, not in the modules:

| group | value | part |
|---|---|---|
| AD0-15, SYNC, DIN, DOUT, WTBT, INIT, IAKI, VIRQ | **3.3 k** | `E1`/`E4`/`E5`/`E6` NR1-4-9M packs |
| bus RPLY (`S1-49`) | **3.3 k** | `E6.3` |
| internal RPLY (`S1-21`) | **5.1 k** | `R9` |
| DMR, SACK, DMGO, BSY | **2.2 k** | `R14`/`R15`/`R17`/`R27` |
| ~PRT, ~PRT1 | **22 k** | `E7`/`E8` |
| ~RESET (`S1-25`) | **43 k** + 10 µF | `R8`, `C5`/`C14` |

**ocbk is the host, so these pull-ups are ocbk's responsibility — and the
adapter board has none of them** except `R1` (1 k on `~BSY`, a line the host
*drives*, where it is least needed). The `.qsf`'s `WEAK_PULL_UP_RESISTOR` is a
~25 kΩ internal pull to **3.3 V**: roughly 8× weaker than the design intent and
to the wrong rail for the 3.3 k and 2.2 k groups. It is about right for the
22 k ~PRT pair only.

**Resolve this before any bring-up.** The board is already fabricated, so the
measurement to take first is the rise time and high level on `~RPLY` and the AD
lines with a module attached.

## What `qbus_slot` must gain

The stub's `SLOT_ENABLE=1` branch is a sketch. Known defects, all logic rather
than electrical:

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
- [gotchas.md](gotchas.md) — the `tri1` stuck-asserted rule that governs every
  new OR-merge here
