#!/usr/bin/env bash
#
# USB HID host oracle: the vendored low-speed USB host against a behavioural
# low-speed HID device (usb_ls_device.v).
#
# SIX LEGS:
#   kbd     A boot keyboard (class 3 / sub 1 / proto 1) enumerates end to end -
#           two bus resets, three descriptor reads, address 1, SET_CONFIGURATION -
#           classifies as typ=1, and its report fields decode. Also asserts that
#           EVERY CRC5 and CRC16 the host emitted was correct, which is an
#           end-to-end check on the vendored microcode ROM image (see below).
#   mouse   proto 2 -> typ=2; buttons decode; and the delta contract: dx/dy are
#           valid AT the report pulse and self-clear the cycle after it, while
#           mouse_btn is a level and does not.
#   pad     A non-boot HID interface -> typ=3, with the axis/button decode the
#           wrapper assumes. Kept even though no low-speed pad has been found on
#           hardware - the typ=3 branch is part of the vendored contract, and the
#           model presents its own descriptors. Its report also carries 0xff, so
#           this is the leg that exercises BIT STUFFING.
#   nak     The device NAKs every descriptor read three times and then NAKs the
#           interrupt endpoint: the host must retry (bnak) and still enumerate,
#           and a NAK must never be mistaken for a report.
#   unplug  Detach clears typ, and a DIFFERENT device replugged re-enumerates and
#           is re-classified.
#   slow    The kbd leg again at the REAL 12001-cycle "1 ms" tick instead of the
#           scaled 61. ~12 s, and it is the leg that proves the scaling in the
#           other five hides nothing about the timer itself.
#
# WHY THE CRC CHECKS EARN THEIR KEEP. The host computes no CRC and verifies none:
# every token and DATA0 it sends is a literal byte string with a pre-computed
# CRC5/CRC16 baked into the microcode ROM, and it ignores the device's CRC16
# entirely. So the model checking them is the only thing in the tree that can
# notice a corrupted or mis-copied mem/usb_hid_host_rom.hex. All three token
# CRC5s and all four DATA0 CRC16s in the image are verified.
#
# WHAT NOTHING HERE TESTS, DELIBERATELY. The pads themselves - the 33R series
# resistors, the board's 10k pull-downs, and the .qsf's DELIBERATE ABSENCE of a
# weak pull-up on these two pins - are hardware properties, not simulable ones
# (see doc/dev/peripherals.md). Nor is full-speed rejection tested: a full-speed
# device pulls up D+ instead of D-, so it is invisible rather than mishandled,
# and "the host ignores a line it never reads" asserts nothing.
#
# --mutate  rewrites one property of a COPY of the real RTL (the sim/evnt idiom -
#           no inline replica to drift) and requires the named leg to break.
#           14 mutations, U1-U14.
#
set -euo pipefail
cd "$(dirname "$0")"

SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

HOST=../../src/peripheral/usb_hid_host.v
ROM=../../src/peripheral/usb_hid_host_rom.v
MODE="${1:-}"

build() {   # build <out> <host.v> [extra iverilog args...]
    local out="$1" host="$2"; shift 2
    iverilog -g2012 "$@" -o "$out" -s usb_hid_host_tb \
        "$host" "$ROM" usb_ls_device.v usb_hid_host_tb.v
}

pass() { vvp -n "$1" "+leg=$2" | grep -q '^COSIM PASS$'; }

# ---- the five fast legs + the slow one ------------------------------------
if [ "$MODE" != "--mutate" ]; then
    build "$SP/usb.vvp" "$HOST"
    for leg in kbd mouse pad nak unplug; do
        echo "=== leg $leg ==="
        pass "$SP/usb.vvp" "$leg" || { echo "usb oracle: FAIL ($leg)"; exit 1; }
    done
    echo "=== leg slow (real 12001-cycle ms tick, ~12 s) ==="
    build "$SP/slow.vvp" "$HOST" -DMS_TICKS=12001
    pass "$SP/slow.vvp" kbd || { echo "usb oracle: FAIL (slow)"; exit 1; }
    echo "usb oracle: PASS"
    exit 0
fi

# ---- mutations -------------------------------------------------------------
# Each entry: name | leg | sed expression applied to a copy of the host RTL.
run_mut() {   # run_mut <name> <leg> <sed-expr>
    local name="$1" leg="$2" expr="$3"
    local mut="$SP/mut.v"
    sed "$expr" "$HOST" > "$mut"
    if cmp -s "$mut" "$HOST"; then
        echo "  $name: SED DID NOT MATCH - fix the mutation"; return 1
    fi
    if ! build "$SP/mut.vvp" "$mut" 2>/dev/null; then
        echo "  $name: killed (does not compile)"; return 0
    fi
    if pass "$SP/mut.vvp" "$leg"; then
        echo "  $name: SURVIVED on leg $leg - the leg does not pin this"; return 1
    fi
    echo "  $name: killed (leg $leg)"
}

echo "=== mutations ==="
fails=0
# --- the classification tree ---
run_mut U1  kbd    's/if (regs\[4\] == 3)/if (regs[4] == 4)/'                  || fails=1
run_mut U2  kbd    's/if (regs\[5\] == 1)/if (regs[5] == 0)/'                  || fails=1
run_mut U3  kbd    's/typ <= regs\[6\] == 1 ? 1 : 2;/typ <= regs[6] == 1 ? 2 : 1;/' || fails=1
run_mut U4  kbd    's/save_delayed \&\& ~save \&\& save_r == 6/save_delayed \&\& ~save \&\& save_r == 5/' || fails=1
run_mut U5  unplug 's/if (~connected \& connected_r) typ <= 0;/if (1'"'"'b0) typ <= 0;/' || fails=1
run_mut U6  kbd    's/^                0: key_modifiers <= ukpdat;/                1: key_modifiers <= ukpdat;/' || fails=1
# --- the report plumbing ---
run_mut U7  mouse  's/mouse_dx <= 0; mouse_dy <= 0;/mouse_dx <= mouse_dx; mouse_dy <= mouse_dy;/' || fails=1
run_mut U8  kbd    's/2: key1 <= ukpdat;/2: key1 <= ~ukpdat;/'                 || fails=1
run_mut U9  pad    's/if (ukpdat\[7:6\]==2'"'"'b00) {game_l, game_r} <= 2'"'"'b10;/if (ukpdat[7:6]==2'"'"'b00) {game_l, game_r} <= 2'"'"'b01;/' || fails=1
run_mut U10 pad    's/5: if (valid) begin/6: if (valid) begin/'                || fails=1
# --- the ukp bit engine ---
run_mut U11 kbd    's/if(bitadr==24) ukprdy <= 1;/if(bitadr==32) ukprdy <= 1;/' || fails=1
# U12 targets the strobe's BYTE ALIGNMENT, not its phase inside the byte. The
# phase is genuinely unobservable: ukpdat is latched at bitadr%8==0 and holds
# until the next multiple of 8, so a strobe anywhere in 001..111 captures the
# same byte and 3'b100 -> 3'b101 is an equivalent implementation, not a defect
# (it survived, correctly). Moving the strobe ONTO the latch cycle is a defect:
# the wrapper then samples ukpdat the same edge it changes and takes the
# PREVIOUS byte, shifting every field by one.
run_mut U12 kbd    's/(bitadr\[2:0\] == 3'"'"'b100) \& (timing == 2)/(bitadr[2:0] == 3'"'"'b000) \& (timing == 2)/' || fails=1
run_mut U13 nak    's/if (bitadr == 8) nak <= dmi;/if (bitadr == 8) nak <= ~dmi;/' || fails=1
run_mut U14 pad    's/if(nrzrxct!=6)/if(nrzrxct!=7)/'                          || fails=1

[ "$fails" = 0 ] && echo "usb mutations: PASS" || { echo "usb mutations: FAIL"; exit 1; }
