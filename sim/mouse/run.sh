#!/usr/bin/env bash
#
# Марсианка mouse oracle: src/peripheral/bk_mouse.sv, a USB HID mouse presented
# as the BK's УВК-01 "Марсианка" on 0177714.
#
# FIVE LEGS:
#   sticky   Each direction latches on movement and HOLDS until СБРОС - the four
#            walked independently, since the bit map is the error surface here
#            exactly as the U,D,L,R -> U,R,D,L remap is in sim/joystick. Includes
#            the sign conventions (HID +y is ВНИЗ) and that bits 4 and 7 and the
#            whole upper byte have no source.
#   reset    СБРОС is a LEVEL, not an edge: asserting clears, and KEEPS clearing
#            while held, so movement during the window is lost rather than
#            queued. Plus the polarity, which is the easy thing to get backwards:
#            the port inverts, so the program writing bit 3 = 0 - including
#            MONITOR's lone CLR @#177714 - is what asserts the reset.
#   step     The encoder-resolution divider: sub-STEP motion latches nothing, the
#            sub-step remainder is kept so two half-steps make a step, and a
#            large delta leaves NO backlog (see below).
#   buttons  КН1/КН2 are levels on bits 5 and 6 and are NOT cleared by СБРОС -
#            they are plain switches on the real device.
#   gate     Only an enumerated MOUSE contributes: typ 0/1/3 all give a zero
#            word, so a pad, a keyboard or an empty port leave the DE-9 joystick
#            word untouched.
#
# THE BUG THIS ORACLE ALREADY CAUGHT, since it is the interesting part of the
# design. The first version carried a multi-step accumulator backlog (clamped at
# 8 steps), reasoning that no motion should ever be lost. But a HID report
# carrying dx=40 describes motion that ALREADY happened - a real encoder emitted
# its ~5 transitions during it, and a binary sticky latch cannot tell five
# transitions from one. The backlog made a single flick keep re-latching for the
# next eight polls, which surfaced as a phantom DOWN appearing on an X-ONLY
# movement (residue left in the Y accumulator by an earlier diagonal). Only the
# sub-step remainder carries now, and the `step` leg pins both halves: the
# remainder IS kept, and a large delta leaves no phantom step behind it.
#
# WHAT NOTHING HERE TESTS, DELIBERATELY. The BUS side: mouse_word is OR-ed into
# joy_word at the TOP LEVEL, so qbus_mem is untouched by this feature and "the
# word reaches a 0177714 read" stays pinned where it already was - spk_capture_tb
# section 10 against the real qbus_mem, and the !sel2_n gate in sim/smk section 2.
# Device here, bus side there, the sim/covox and sim/joystick precedent.
#
# Nor does anything here pin WHICH write bit is СБРОС. The two УВК-01 schematic
# sheets give the connector pinout (pin 9 = СБРОС) but not the cable's mapping
# onto the BK port's output bits; bit 3 is GID's and the only evidence there is.
# It is the RST_BIT parameter so a board measurement can move it.
#
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt idiom -
#           no inline replica to drift) and requires the named leg to break.
#           13 mutations, K1-K13.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

DUT=../../src/peripheral/bk_mouse.sv
MODE="${1:-}"

build() {   # build <out> <bk_mouse.sv>
    iverilog -g2012 -o "$1" -s bk_mouse_tb "$2" bk_mouse_tb.v 2>&1 \
        | grep -v 'sorry:' || true
}

pass() { vvp -n "$1" "+leg=$2" | grep -q '^COSIM PASS$'; }

if [ "$MODE" != "--mutate" ]; then
    build "$SP/m.vvp" "$DUT"
    for leg in sticky reset step buttons gate; do
        echo "=== leg $leg ==="
        pass "$SP/m.vvp" "$leg" || { echo "mouse oracle: FAIL ($leg)"; exit 1; }
    done
    echo "mouse oracle: PASS"
    exit 0
fi

run_mut() {   # run_mut <name> <leg> <sed-expr>
    local name="$1" leg="$2" expr="$3"
    local mut="$SP/mut.sv"
    sed "$expr" "$DUT" > "$mut"
    if cmp -s "$mut" "$DUT"; then
        echo "  $name: SED DID NOT MATCH - fix the mutation"; return 1
    fi
    if ! build "$SP/mut.vvp" "$mut" >/dev/null 2>&1; then
        echo "  $name: killed (does not compile)"; return 0
    fi
    if pass "$SP/mut.vvp" "$leg"; then
        echo "  $name: SURVIVED on leg $leg - the leg does not pin this"; return 1
    fi
    echo "  $name: killed (leg $leg)"
}

echo "=== mutations ==="
fails=0
# --- direction decode and bit map ---
run_mut K1  sticky  's/if (!nx\[9\]) st_rt <= 1.b1;/if (nx[9]) st_rt <= 1'"'"'b1;/'   || fails=1
run_mut K2  sticky  's/if (!ny\[9\]) st_dn <= 1.b1;/if (ny[9]) st_dn <= 1'"'"'b1;/'   || fails=1
run_mut K3  sticky  's/mouse_word\[1\] = st_rt;/mouse_word[1] = st_dn;/'              || fails=1
run_mut K4  sticky  's/mouse_word\[3\] = st_lf;/mouse_word[3] = st_up;/'              || fails=1
# --- СБРОС: polarity and level-ness ---
run_mut K5  reset   's/wire rst_lvl = ~rst_sr\[1\];/wire rst_lvl = rst_sr[1];/'       || fails=1
run_mut K6  reset   's/^        if (rst_lvl) begin/        if (1'"'"'b0) begin/'       || fails=1
run_mut K7  reset   's/rst_sr <= {rst_sr\[0\], port_data\[RST_BIT\]};/rst_sr <= {rst_sr[0], port_data[RST_BIT+1]};/' || fails=1
# --- the step divider ---
run_mut K8  step    's/wire       x_step = (nx_mag >= STEP);/wire       x_step = (nx_mag >= 1);/' || fails=1
run_mut K9  step    's/wire signed \[9:0\] nx_next = x_step ? (nx\[9\] ? -nx_rem : nx_rem) : nx;/wire signed [9:0] nx_next = x_step ? (nx[9] ? -nx_rem : nx_rem) : 10'"'"'sd0;/' || fails=1
# --- the CDC ---
run_mut K10 sticky  's/^        if (hid_report) begin/        if (1'"'"'b1) begin/'    || fails=1
run_mut K11 step    's/wire step_ev  = tog_sr\[2\] \^ tog_sr\[1\];/wire step_ev  = tog_sr[2] \& tog_sr[1];/' || fails=1
# --- buttons and the typ gate ---
run_mut K12 buttons 's/            btn <= pl_btn;/            btn <= rst_lvl ? 8'"'"'h00 : pl_btn;/' || fails=1
run_mut K13 gate    's/wire        is_mouse = (hid_typ == 2.d2);/wire        is_mouse = (hid_typ == 2'"'"'d3);/' || fails=1

[ "$fails" = 0 ] && echo "mouse mutations: PASS" || { echo "mouse mutations: FAIL"; exit 1; }
