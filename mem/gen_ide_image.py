#!/usr/bin/env python3
"""Generate the synthetic raw-AltPro HDD image for the Phase-8 IDE oracles.

The SMK512 IDE engine (src/smk_ide.sv) parses drive geometry from the AltPro
partition table in image sector 7 exactly as BkEmu does
(IdeController.IdeDriveImage.setupAltProGeometry): word values are stored
BIT-INVERTED in the image (readInt16Inv = ~le16), the logical-disk records
grow DOWN from byte offset 0770, and a word-sum checksum (seed 012701) sits
just below them:

  byte 0770 : number of logical disks (low byte; reject > 125)
  byte 0772 : sectors per track  S (1..255)
  byte 0774 : heads              H (low byte, 1..16)
  byte 0776 : cylinders          C (1..16383)
  bytes 0770-numLD*4 .. 0767 : LD records (2 words each)
  byte 0770-numLD*4-2 : checksum word, chosen so that
      cksum - sum(words at cp+2 .. 0776 inclusive) == 012701   (mod 2^16)
  (sums/subtractions over the TRUE - post-inversion - word values)

Everything OUTSIDE the table (all data sectors, the rest of sector 7) is
TRUE data - the raw AltPro convention: the ~ bus inversion lives in the SMK
bus adapter, the backing store holds what BkEmu's image files hold, so the
same image attaches to BkEmu for cross-validation.

Outputs (word-per-line hex, $readmemh):
  ide_image.hex       : the full image, TOTAL_SECTORS*256 words; sector s
                        word w = pattern(s, w) except sector 7 = the table
  ide_image.bin       : the same image as raw little-endian bytes - the
                        dd-able form for the increment-(b) SD card
                        (dd if=ide_image.bin of=/dev/sdX) and BkEmu attach
  ide_sector7_bad.hex : 256 words - sector 7 with the checksum broken (the
                        C word bit-flipped, checksum NOT recomputed). The
                        unit tb overlays it for the fallback-geometry leg
                        (with a bk_total large enough that the BkEmu raw
                        default C = total/1008 stays non-zero; a zero C is
                        an attach FAILURE in BkEmu -> drive absent, and the
                        engine mirrors that).

Geometry mirrors IdeControllerTest's TestIdeDrive (10 cyl, 4 heads, 16
sectors = 640 sectors) so the transcribed test scenario walks every sector.
"""
import sys

SECTOR_WORDS = 256
CYLS, HEADS, SECTORS = 10, 4, 16
TOTAL_SECTORS = CYLS * HEADS * SECTORS          # 640

NUM_LD = 2
# LD record content is opaque to the engine (only the checksum covers it);
# plausible start/length pairs until the real BIOS tells us more (step 6).
LD_RECORDS = [(0o000020, 0o000400), (0o000420, 0o000700)]

CKSUM_SEED = 0o12701

PAT_C = 0o776 >> 1      # word indices inside sector 7
PAT_H = 0o774 >> 1
PAT_S = 0o772 >> 1
PAT_NLD = 0o770 >> 1


def pattern(s, w):
    """Deterministic per-sector data pattern (true data)."""
    return (s * 293 + w * 7 + 0x1234) & 0xFFFF


def inv(v):
    return ~v & 0xFFFF


def build_sector7():
    """The AltPro partition-table sector, stored (inverted) values."""
    true7 = [0] * SECTOR_WORDS          # true-value scratch
    true7[PAT_NLD] = NUM_LD
    true7[PAT_S] = SECTORS
    true7[PAT_H] = HEADS
    true7[PAT_C] = CYLS
    rec_base = PAT_NLD - 2 * NUM_LD     # records grow down, 2 words each
    for i, (a, b) in enumerate(LD_RECORDS):
        true7[rec_base + 2 * i] = a
        true7[rec_base + 2 * i + 1] = b
    cp = rec_base - 1                   # checksum word index
    body = sum(true7[cp + 1:PAT_C + 1]) & 0xFFFF
    true7[cp] = (CKSUM_SEED + body) & 0xFFFF
    # table area stored inverted; untouched words stay true zeros
    sec = [0] * SECTOR_WORDS
    for i in range(SECTOR_WORDS):
        sec[i] = inv(true7[i]) if cp <= i <= PAT_C else true7[i]
    return sec, cp


def parse_check(sec):
    """Literal transcription of setupAltProGeometry over the stored words.

    Returns (S, H, C) or None - the generator's independent self-check."""
    def rd_inv(byte_off):
        return inv(sec[byte_off >> 1])
    num_ld = rd_inv(0o770) & 0xFF
    if num_ld > 125:
        return None
    pos = 0o770 - num_ld * 4 - 2
    cksum = rd_inv(pos)
    while True:                          # the Java do/while
        pos += 2
        cksum -= rd_inv(pos)
        if not pos < 0o776:
            break
    if cksum & 0xFFFF != CKSUM_SEED:
        return None
    s = rd_inv(0o772)
    h = rd_inv(0o774) & 0xFF
    c = rd_inv(0o776)
    if not (0 < s <= 255 and 0 < h <= 16 and 0 < c <= 16383):
        return None
    return (s, h, c)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    sec7, cp = build_sector7()
    assert parse_check(sec7) == (SECTORS, HEADS, CYLS), "self-check failed"

    bad7 = list(sec7)
    bad7[PAT_C] ^= 0x0010               # break C; checksum left stale
    assert parse_check(bad7) is None, "bad variant unexpectedly parses"

    img = []
    for s in range(TOTAL_SECTORS):
        if s == 7:
            img.extend(sec7)
        else:
            img.extend(pattern(s, w) for w in range(SECTOR_WORDS))

    with open(f"{outdir}/ide_image.hex", "w") as f:
        for w in img:
            f.write(f"{w:04x}\n")
    with open(f"{outdir}/ide_image.bin", "wb") as f:
        f.write(b"".join(bytes((w & 0xFF, w >> 8)) for w in img))
    with open(f"{outdir}/ide_sector7_bad.hex", "w") as f:
        for w in bad7:
            f.write(f"{w:04x}\n")
    print(f"wrote {outdir}/ide_image.hex ({TOTAL_SECTORS} sectors, "
          f"C/H/S {CYLS}/{HEADS}/{SECTORS}, checksum word at byte "
          f"{oct(cp * 2)}) + ide_sector7_bad.hex")


if __name__ == "__main__":
    main()
