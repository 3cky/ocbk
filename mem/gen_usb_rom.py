#!/usr/bin/env python3
"""UKP microcode assembler for the USB HID host ROM.

Vendored from nand2mario/usb_hid_host (src/firmware/asukp.py, itself a port of
hi631's asukp.perl) and adapted to this tree:

  * paths come from argv instead of a hard-coded ukp.s / shutil.move dance, so
    the Makefile can express the dependency normally;
  * only the .hex is written - usb_hid_host_rom.v is the vendored RTL and is not
    regenerated here (it carries local hook H1, the ROMFILE parameter). Its
    memory depth must equal the nibble count printed at the end of a run.

The instruction encoding is upstream's and is the contract with ukp inside
src/peripheral/usb_hid_host.v: 4-bit opcodes, ldi/out4/outb carrying an
immediate as two nibbles (low first), branches carrying a 4-nibble-aligned
target as two nibbles and jmp as three, and every label aligned to a 4-nibble
boundary because that alignment is what the branch encoding assumes.

Verified against upstream: assembling upstream's unmodified ukp.s with this
script reproduces the previously vendored mem/usb_hid_host_rom.hex byte for
byte, so the local microcode hooks are the only difference in the image.
"""

import sys

instructions = {
    "nop": 0,     "ldi": 1,   "start": 2, "out4": 3,
    "out0": 4,    "hiz": 5,   "outb": 6,  "ret": 7,
    "bz": 8,      "bc": 9,    "bnak": 10, "djnz": 11,
    "toggle": 12, "save": 12, "in": 13,   "wait": 14, "jmp": 15,
}

# Opcodes carrying operand nibbles: 3 nibbles total, except jmp's 4.
WITH_OPERANDS = (1, 3, 6, 8, 9, 10, 11, 12)


def imm(token):
    return int(token, 16) if token.startswith("0x") else int(token)


def parse(path):
    """Yield (label, opcode, tokens) per meaningful line."""
    with open(path) as f:
        for line in f:
            line = line.split(";")[0].strip()
            if not line:
                continue
            if ":" in line:
                yield line.split(":")[0].strip(), None, None
                continue
            tokens = line.split()
            if tokens[0] not in instructions:
                sys.exit(f"syntax error: {line}")
            yield None, instructions[tokens[0]], tokens


def size_of(code):
    return 4 if code == 15 else (3 if code in WITH_OPERANDS else 1)


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <ukp.s> <rom.hex>")
    src, dst = sys.argv[1], sys.argv[2]

    # Pass 1: label addresses. A label aligns the PC up to a 4-nibble boundary.
    labels, pc = {}, 0
    for label, code, _ in parse(src):
        if label is not None:
            if label in labels:
                sys.exit(f"{label}: already defined")
            pc = (pc + 3) & ~3
            labels[label] = pc
        else:
            pc += size_of(code)

    # Pass 2: emit. The padding a label's alignment implies is real ROM content
    # (zeroes = nop), so it is written out here rather than only counted above.
    rom, pc = [], 0
    for label, code, tokens in parse(src):
        if label is not None:
            while pc % 4:
                rom.append(0)
                pc += 1
            continue
        rom.append(code)
        if code == 12:                              # toggle / save r b
            if tokens[0] == "toggle":
                rom += [15, 15]
            else:
                if len(tokens) != 3:
                    sys.exit(f"malformed: {' '.join(tokens)}")
                rom += [int(tokens[1]), int(tokens[2])]
        elif code in (1, 3, 6):                     # ldi / out4 / outb imm
            value = imm(tokens[1])
            rom += [value & 0xF, (value >> 4) & 0xF]
        elif code in (8, 9, 10, 11, 15):            # branches and jmp
            if tokens[1] not in labels:
                sys.exit(f"{tokens[1]}: undefined label")
            addr = labels[tokens[1]] >> 2
            rom += [addr & 0xF, (addr >> 4) & 0xF]
            if code == 15:
                rom.append((addr >> 8) & 0xF)
        pc += size_of(code)

    with open(dst, "w") as f:
        for nibble in rom:
            f.write(f"{nibble:01x}\n")

    # The depth src/peripheral/usb_hid_host_rom.v must declare, and the M4K
    # ceiling: one M4K is 4096 bits = 1024 nibbles.
    print(f"{dst}: {len(rom)} nibbles ({len(rom) * 100 // 1024} % of one M4K)")
    if len(rom) > 1024:
        sys.exit("microcode exceeds one M4K")


if __name__ == "__main__":
    main()
