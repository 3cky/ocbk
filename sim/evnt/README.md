# sim/evnt — the BK-0011M EVNT/IRQ2 detector contract (Phase 9)

`src/bk_evnt.sv` is a gate-faithful replica of the real BK-0011M's **external**
frame-interrupt detector. This directory is its oracle.

## Why the module exists

The 1801ВП1-037 has **no vertical-blanking output pin**. Through Phase 7 we
modelled nIRQ2 as the 037's internal `vgate` level — which is MiSTer's model
(`BK0011M_MiSTer/rtl/video.sv`: `irq` set at `vc==256`, cleared at `vc==0`).
The real machine synthesises IRQ2 on the motherboard instead, and the two do
not agree.

Schematic trace (`doc/bk0011m.sch`, verified pin-by-pin):

| part | role |
|---|---|
| **D28** К555ИЕ5 (74LS93), ÷2 section | `CKA = ~(SYNCO \| QA)` via D6:C (К555ЛЕ4 3-input NOR, QA fed back into two inputs); async clear `R0(1)&R0(2) = CLC & WTI`; `QA → D3.12` |
| **D3:B** К555ТМ2 (74LS74) | `C = SYNCO` (037 pin 28), `D = QA`, `R = D35.5` (active low); `~Q →` D21 (К155ЛП9, OC, 22k pull-up E7.2) `→ ~PRT →` D11.4 (К555ТМ9, on CLC) `→` the CPU's IRQ2 pin |
| **D35.5** (Q2) | the 662 IRQ-enable bit: `D35.D2 ← S1-70 ← D31.8` (К555ЛЛ1 OR, other input GND) `← S1-15 = AD14`, the *inverted* bus line, so `Q2 = ~reg662[14]`. `D35.MR ←` ACLO |

WTI pulses once per fetched video word (32 per displayed line) and is silent on
every non-displayed line, so it pins QA at 0 through the displayed area. When
WTI stops, the next SYNCO edge toggles QA to 1 — and the QA feedback then holds
CKA low, so **QA is set-once** until WTI resumes. D3:B re-samples QA on every
SYNCO rising edge.

## The pinned contract

Measured against the vendored reference netlist `sim/ref037/va_037.v`, stable
on every frame (CLKIN = 6.02 MHz, line = 384 CLKIN, frame = 320 lines):

| | value |
|---|---|
| assert (full screen) | `VGATE rise + 452 CLKIN` |
| deassert (full screen) | `VGATE fall + 452 CLKIN` |
| in µs / lines / cpu_clk | ~75 µs, ~1.18 scanlines, ~301 cpu_clk at the /24 rate |
| assert (1/4 screen) | `VGATE rise − 49604 CLKIN`, i.e. **during active video** |

So the pre-Phase-9 model fired **452 CLKIN too early, every frame** — a fixed
displacement of every beam-raced multicolor/gigascreen effect.

Three properties are load-bearing and each is mutation-covered:

1. **The propagation race.** The QA toggle and the D3:B clock are the *same*
   SYNCO edge. On the board, propagation delay makes D3:B capture the **old**
   QA, which is why the request appears a whole line after QA sets. The RTL
   reproduces it through non-blocking assignment ordering. Sampling the new
   value shortens the delay by a full scanline (MUT1).
2. **`irq_en` is an async CLEAR, not a combinational gate.** Un-masking
   mid-blanking therefore does **not** retro-fire instantly — the flop leaves
   reset and only sets at the next SYNCO edge. Both our old model and MiSTer
   retro-fire immediately (MUT4).
3. **QA is set-once** (the CKA feedback), so extra SYNCO edges cannot re-toggle
   it inside a blanking window (MUT5).

## Running it

```
sim/evnt/run.sh            # leg A (reference netlist) + leg B (va_037_sync)
sim/evnt/run.sh --mutate   # + the five mutations, each must break the diff
sim/evnt/run.sh --regen    # regenerate golden_evnt.txt (REFERENCE netlist only)
```

**Golden rule (the `sim/ref014` shape):** `golden_evnt.txt` is generated from
the **reference netlist** run only. The retimed `src/va_037_sync.sv` must then
reproduce it line-for-line — it currently does, byte-identically. Never
regenerate the golden from a `va_037_sync` run, and never regenerate it to
"fix" a detector change.

## Deliberate simplification

The board gates D28's clear with CLC (`R0(1) = CLC`, `R0(2) = WTI`), so the
clear only bites during a CPU-clock high phase; `bk_evnt` models a plain `wti`
clear. WTI pulses 32× per displayed line and each pulse is ≥1 CLKIN wide, so
the only reachable difference is whether the *last* pulse of a line clears QA
one CLKIN earlier or later — and QA cannot set until the SYNCO edge ~290 CLKIN
later, so it is unobservable. Modelling the gate faithfully would drag
`cpu_clk` into a video-domain module for no behavioural gain.

## Related coverage

`sim/bk11/run.sh` section 12 exercises the detector on the full SoC. The
452-CLKIN blanking-entry offset is **not** observable there (that program's
only nIRQ2 assertion is the one triggered by its own mid-blanking unmask), so
the SoC guard pins the property that *is* visible: the unmask must not
retro-fire within 512 sys_clk. That guard is teeth-tested — restoring the old
`~mask & vgate` wiring makes it fail at 34 sys_clk.
