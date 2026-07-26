#!/usr/bin/env python3
"""Build a candidate variant of src/va_037_sync.sv for the sim/grantfit sweep.

The sim/evnt idiom: the candidates rewrite a COPY of the real RTL, so there is
no inline replica that can drift away from what the design actually does, and
every rewrite is ANCHORED - if the anchor text is gone the RTL moved and this
script fails loudly rather than silently producing the unpatched file.

    patch037.py --src ../../src/va_037_sync.sv --out mut.sv \
                [--setup K] [--gap G] [--trply neg|both]

--setup K   REQUEST SETUP WINDOW.  The grant request must have been present K
            half-CLKIN phases before the PC==4 decision, instead of being
            sampled live there.  Real silicon has a setup requirement at that
            latch; if the real chip effectively latches the request earlier
            than we do, a request arriving inside that shadow loses a whole
            8-CLKIN slot.  Unlike a minimum-GAP rule this is PHASE-sensitive,
            not DISTANCE-sensitive, which is the shape the hardware tones want:
            a second, closely-following access lands at a nearly fixed
            sub-phase (and would always miss), while the 3.85-slot SOB fetch
            lands elsewhere (and would not).  K=0 is the shipped behaviour.
            The RPLY interlock stays LIVE - only SYNC/the strobes/a15 are
            delayed, so this models setup on the request, not on the handshake.

--gap G     MINIMUM INTER-GRANT GAP of G slots (G=1 = shipped).  Already tried
            and REJECTED on hardware grounds (ROADMAP: it fits `MOV #imm` at
            G=3 and wrecks `SOB`); kept here as the baseline the sweep must
            re-reject, because a sweep that cannot reproduce a known-wrong
            answer is not measuring anything.

--trply     TRPLY CLEAR QUANTISATION.  Shipped, TRPLY clears the instant both
            strobes go idle, on any sys_clk.  RPLY (= TRPLY & ~RASEL) blocks
            the next grant, so if the real chip clears it only on a CLKIN edge
            the clear can slip past a PC==4 decision and cost the FOLLOWING
            access a whole slot - i.e. "a cycle's tail delays the next fetch",
            which is the shape of the RAM-write divergence.  `neg` = clear only
            at en_neg, `both` = at either strobe.

Every register added here is RESET - without that RASEL goes X and the sim
hangs (the experiment note in CLAUDE.md, learned the hard way).
"""
import os
import sys

# --- anchors: verbatim lines of src/va_037_sync.sv --------------------------
A_DECL = "   wire a15_037 = A[15] & ~ext_ram;"
A_RASEL = ("            RASEL <= ~(PIN_nSYNC | a15_037 | RPLY | "
           "(PIN_nDIN & PIN_nDOUT));")
A_TRPLY = "      else if (PIN_nDIN & PIN_nDOUT)    TRPLY <= 1'b0;"


def opt(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 >= len(sys.argv):
            sys.exit(f"{name} needs a value")
        return sys.argv[i + 1]
    return default


def replace_once(text, anchor, new, what):
    if text.count(anchor) != 1:
        sys.exit(f"patch037: anchor for {what} not found exactly once - "
                 f"va_037_sync.sv moved, fix this script\n  {anchor!r}")
    return text.replace(anchor, new)


def main():
    src = opt("--src", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "src", "va_037_sync.sv"))
    out = opt("--out")
    if out is None:
        sys.exit("--out is required")
    setup = int(opt("--setup", "0"))
    gap = int(opt("--gap", "1"))
    trply = opt("--trply", "off")
    if not 0 <= setup <= 3:
        sys.exit("--setup must be 0..3")
    if not 1 <= gap <= 7:
        sys.exit("--gap must be 1..7")
    if trply not in ("off", "neg", "both"):
        sys.exit("--trply must be off|neg|both")

    with open(src) as f:
        text = f.read()

    decls = []
    terms = []          # ANDed into the RASEL set expression

    if setup:
        decls.append(f"""
   // GRANTFIT --setup {setup}: the request must have been present {setup}
   // half-CLKIN phase(s) before the PC==4 decision (RPLY stays live below).
   wire gf_req_raw = ~(PIN_nSYNC | a15_037 | (PIN_nDIN & PIN_nDOUT));
   logic [2:0] gf_req_sr;
   always_ff @(posedge clk)
      if (RESET)                 gf_req_sr <= 3'b000;
      else if (en_pos | en_neg)  gf_req_sr <= {{gf_req_sr[1:0], gf_req_raw}};
   wire gf_setup_ok = gf_req_sr[{setup - 1}] & ~RPLY;
""")
        terms.append("gf_setup_ok")
    else:
        terms.append("~(PIN_nSYNC | a15_037 | RPLY | (PIN_nDIN & PIN_nDOUT))")

    if gap > 1:
        decls.append(f"""
   // GRANTFIT --gap {gap}: at least {gap} slots between granted slots.
   // gf_grant_seen is STICKY within a slot and gf_since counts slots since the
   // last granted one, saturating; 7 (the reset value) is "long ago".
   // The stickiness is load-bearing: RASEL is set at the en_pos of PC==4 and
   // cleared at the en_pos of PC==7, while the slot boundary is the en_neg
   // that takes PC 7->0 - so sampling RASEL *at* the boundary always sees 0
   // and the rule silently never fires (it did, in the first version of this
   // script, which is exactly why C4 has to reproduce a known-wrong answer).
   logic [2:0] gf_since;
   logic       gf_grant_seen;
   always_ff @(posedge clk)
      if (RESET) begin
         gf_since <= 3'd7;
         gf_grant_seen <= 1'b0;
      end else begin
         if (RASEL) gf_grant_seen <= 1'b1;
         if (en_neg && (PC == 3'd7)) begin
            gf_since <= gf_grant_seen ? 3'd0
                      : (gf_since == 3'd7 ? 3'd7 : gf_since + 3'd1);
            gf_grant_seen <= 1'b0;
         end
      end
   wire gf_gap_ok = (gf_since >= 3'd{gap - 1});
""")
        terms.append("gf_gap_ok")

    if decls:
        text = replace_once(text, A_DECL, A_DECL + "\n" + "".join(decls),
                            "the declaration insertion point")

    if len(terms) > 1 or setup:
        new_rasel = "            RASEL <= " + " & ".join(terms) + ";"
        text = replace_once(text, A_RASEL, new_rasel, "the RASEL set expression")

    if trply != "off":
        strobe = "en_neg" if trply == "neg" else "(en_neg | en_pos)"
        new_trply = (f"      else if ((PIN_nDIN & PIN_nDOUT) & {strobe})"
                     f"    TRPLY <= 1'b0;")
        text = replace_once(text, A_TRPLY, new_trply, "the TRPLY clear")

    with open(out, "w") as f:
        f.write(text)


if __name__ == "__main__":
    main()
