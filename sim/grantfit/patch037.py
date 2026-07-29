#!/usr/bin/env python3
"""Build a candidate variant of src/va_037_sync.sv for the sim/grantfit sweep.

The sim/evnt idiom: the candidates rewrite a COPY of the real RTL, so there is
no inline replica that can drift away from what the design actually does, and
every rewrite is ANCHORED - if the anchor text is gone the RTL moved and this
script fails loudly rather than silently producing the unpatched file.

    patch037.py --src ../../src/va_037_sync.sv --out mut.sv \
                [--gap G] [--trply neg|both]

NOTE: --setup is GONE.  The request setup window WON the fit and is now shipped
RTL - `va_037_sync`'s GRANT_SETUP parameter - so sweeping it is a `-P` override
(`iverilog -Ptone_tb.GRANT_SETUP=0`), not a source rewrite.  run.sh does that.
Likewise D8:B is now src/bk_rply.sv, instantiated for real, with `+nod8b` as
the bypass.  What is left here are the candidates that did NOT win, kept so the
sweep can keep re-rejecting them.

--gap G     MINIMUM INTER-GRANT GAP of G slots (G=1 = shipped).  Already tried
            and REJECTED on hardware grounds (the pre-bench record has it
            fitting `MOV #imm` at G=3 and wrecking `SOB`; this bench rejects it
            on the write leg instead - see README's discrepancy note); kept
            here as the baseline the sweep must re-reject, because a sweep that
            cannot reproduce a known-wrong answer is not measuring anything.

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
A_RASEL = "            RASEL <= grant_req & ~RPLY;"
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
    if "--setup" in sys.argv:
        sys.exit("--setup is gone: the setup window is shipped RTL now "
                 "(va_037_sync's GRANT_SETUP parameter). Use "
                 "`iverilog -Ptone_tb.GRANT_SETUP=K`, which is what "
                 "run.sh --setup does.")
    gap = int(opt("--gap", "1"))
    trply = opt("--trply", "off")
    if not 1 <= gap <= 7:
        sys.exit("--gap must be 1..7")
    if trply not in ("off", "neg", "both"):
        sys.exit("--trply must be off|neg|both")

    with open(src) as f:
        text = f.read()

    decls = []
    terms = ["grant_req & ~RPLY"]   # the shipped expression, extended below

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

    if len(terms) > 1:
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
