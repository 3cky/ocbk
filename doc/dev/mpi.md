# МПИ — the BK expansion bus and the cartridge-slot seam

The Магистральный параллельный интерфейс: the real BK-0011M expansion
connector, traced pin-by-pin from `doc/bk0011m.sch`, and the
`src/bus/qbus_slot.sv` bridge that drives it. The internal Q-bus conventions this bridges onto are in
[bus-memory.md](bus-memory.md); the RPLY re-timing rule is in `src/bus/bk_rply.sv`.

**STATUS: the slave-only bridge is IMPLEMENTED AND SIM-GREEN; HARDWARE NOT YET
CONFIRMED.** `src/bus/qbus_slot.sv` is live (`SLOT_ENABLE=1`), the 27 pins are
assigned, and `sim/slot` covers it with three legs and six mutations. What is
implemented is **data transfer, RPLY and the host-ROM deselect** — no
interrupts, no DMA/arbitration, no IAK chain. **Do not merge to `main` until a
real SMK512 runs on the board**, and read the termination note below before
plugging anything in.

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
- **The deselect lines are model-gated.** A real BK-0011M has no MON10/BAS10/
  MON11 pin at all (XT3 has no A14/B1/B6); the adapter routes them from the MSX
  edge regardless. Without the gate a module asserting BAS10 would knock out the
  BK-0011M top ROM, which no real machine can do.
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
- `sim/slot/README.md` — the oracle contract, the three legs and the six
  mutations, including the two checks that had to be structural
- [gotchas.md](gotchas.md) — the `tri1` stuck-asserted rule that governs every
  new OR-merge here
