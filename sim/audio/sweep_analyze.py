#!/usr/bin/env python3
"""Analyse a recording of the audio_tone SWEEP build (acceptance item 2).

Firmware: the bringup-audio-sweep branch (bk_audio TONE_SWEEP=1). DIP 5 then
plays a 33-state cycle - index 0 SILENT (the sync marker), then 32 log-spaced
triangle tones from 100 Hz to 100 kHz, voice A only, fixed 8192 amplitude,
panned BOTH so one take measures both ladders. Dwell 2^26 sys_clk = 0.6944 s,
so a full cycle is 22.9 s; record at least two cycles.

What it produces:
  * the magnitude response of each channel vs frequency, normalised to the
    reference step nearest 1 kHz -> THE ANALOG RC CORNER (acceptance item 2);
  * the 2nd/3rd harmonic of each tone, which is what resolves the voice-A
    excess-3rd-harmonic anomaly the 2026-07-31 staircase recording turned up
    (see the analog-stage bullet in CLAUDE.md): a chain-response explanation
    predicts the 3rd harmonic tracks the RESPONSE curve at 3f, a nonlinearity
    explanation predicts it tracks the SIGNAL level instead;
  * the noise floor in the silent marker step. NOTE this is NOT acceptance
    item (3): that one is "DIP 5 OFF, machine idle", and this build has the
    tone running throughout. The marker is only 0.694 s and sits between the
    100 kHz step and the 100 Hz step, so boundary transients inflate it -
    treat it as indicative only.

Usage:  python3 sim/audio/sweep_analyze.py recording.wav
Needs numpy. Anything above the capture's Nyquist is reported as ALIASED and
excluded from the fit - a 44.1/48 kHz capture cannot see past ~20 kHz, so the
top of the table needs a 96/192 kHz interface.
"""
import sys, wave, math
import numpy as np

SYS_CLK = 96_647_715.0
DWELL = 2 ** 26 / SYS_CLK          # 0.694363 s
NSTEP = 33                          # index 0 silent + 32 tones
CYCLE = NSTEP * DWELL

# audio_tone.sv's table: index -> phase increment. Frequency = inc*SYS_CLK/2^32.
INC = [0, 4444, 5553, 6939, 8671, 10836, 13541, 16921, 21144, 26422, 33017,
       41258, 51557, 64426, 80507, 100602, 125713, 157092, 196304, 245304,
       306534, 383047, 478659, 598137, 747437, 934004, 1167140, 1458469,
       1822517, 2277433, 2845902, 3556265, 4443941]
FREQ = [i * SYS_CLK / 2 ** 32 for i in INC]
TRI_FUND = 8 / math.pi ** 2         # triangle fundamental / peak amplitude
IDEAL_DBFS = 20 * math.log10(TRI_FUND * 8192 / 32768)


def load(path):
    w = wave.open(path)
    if w.getsampwidth() != 2:
        sys.exit('need 16-bit PCM')
    n, fr, ch = w.getnframes(), w.getframerate(), w.getnchannels()
    d = np.frombuffer(w.readframes(n), dtype='<i2').astype(float)
    return (d[0::ch], d[1::ch] if ch > 1 else d[0::ch]), fr


def bin_amp(x, i0, N, f, fr):
    """Peak amplitude at f over x[i0:i0+N], Hann-windowed single-bin DFT."""
    if i0 < 0 or i0 + N > len(x):
        return 0.0
    seg = x[i0:i0 + N]
    w = np.hanning(N)
    k = np.arange(N)
    return 2 * abs(np.dot((seg - seg.mean()) * w, np.exp(-2j * np.pi * f * k / fr))) / w.sum()


def db(a):
    return 20 * math.log10(a / 32768) if a > 0 else float('-inf')


def find_phase(ch, fr):
    """Align to the sweep by MATCHING THE TONES, not by finding the silence.

    Minimum-energy marker detection does not work here and the failure is
    silent: the top of the table is attenuated by the very analog rolloff this
    recording exists to measure, so the quiet stretch is the marker PLUS
    however many top steps the board filters away (~4.2 s on the first take,
    against a 0.694 s marker). Anything keyed off "quietest window" therefore
    lands several dwells out and every subsequent measurement is taken at the
    wrong frequency, reading as noise.

    Instead: score a candidate t0 by how much energy sits in the EXPECTED bin
    of several mid-table steps, which are loud on any plausible chain, and take
    the best. Coarse grid then a fine refine.
    """
    probe = [5, 8, 11, 14, 17, 20]          # 244 Hz .. 6.9 kHz
    # The window must span nearly the WHOLE dwell, not a comfortable middle
    # slice. With a short centred window the score is FLAT for any offset that
    # still leaves it inside the step - a plateau, so the argmax lands anywhere
    # in it (measured: 0.3 dwell late, which then contaminated the silent-marker
    # step with the neighbouring tone). Spanning the dwell makes a misalignment
    # pull the adjacent step's frequency into the window and drop the in-bin
    # amplitude, giving a sharp maximum at the true boundary.
    NW = int(0.90 * DWELL * fr)

    def score(t0):
        s = 0.0
        for idx in probe:
            t = t0 + idx * DWELL + 0.05 * DWELL
            while t + NW / fr < len(ch) / fr:
                i0 = int(t * fr)
                if i0 >= 0:
                    s += bin_amp(ch, i0, NW, FREQ[idx], fr)
                    break
                t += CYCLE
        return s

    coarse = max((score(t0), t0) for t0 in np.arange(0, CYCLE, 0.05))
    lo, hi = coarse[1] - 0.05, coarse[1] + 0.05
    fine = max((score(t0), t0) for t0 in np.arange(lo, hi, 0.005))
    return fine[1] % CYCLE


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    (L, R), fr = load(sys.argv[1])
    n = len(L)
    print('%s: %.2f s at %d Hz, %.2f sweep cycles'
          % (sys.argv[1], n / fr, fr, n / fr / CYCLE))

    t0 = find_phase(L + R, fr)
    print('silent marker starts at t0 = %.3f s (+ k*%.3f s)\n' % (t0, CYCLE))

    guard = 0.20
    NW = int((1 - 2 * guard) * DWELL * fr)
    nyq = fr / 2.0

    rows = []
    for idx in range(NSTEP):
        wins = []
        k = idx
        while t0 + k * DWELL < n / fr:
            i0 = int((t0 + k * DWELL + guard * DWELL) * fr)
            if i0 + NW <= n:
                wins.append(i0)
            k += NSTEP
        if not wins:
            continue
        f = FREQ[idx]
        if idx == 0:
            rms = np.mean([math.sqrt(float(np.mean(L[i:i + NW] ** 2))) for i in wins])
            rmsr = np.mean([math.sqrt(float(np.mean(R[i:i + NW] ** 2))) for i in wins])
            print('index 0 (SILENT MARKER): L %.1f dBFS rms, R %.1f dBFS rms  '
                  '(indicative only - NOT item 3, which needs a DIP-5-off take)\n'
                  % (db(rms), db(rmsr)))
            continue
        al = np.mean([bin_amp(L, i, NW, f, fr) for i in wins])
        ar = np.mean([bin_amp(R, i, NW, f, fr) for i in wins])
        h = {}
        for m in (2, 3):
            if m * f < nyq * 0.98:
                h[m] = np.mean([bin_amp(L, i, NW, m * f, fr) for i in wins])
        rows.append((idx, f, al, ar, h, f < nyq * 0.98))

    # normalise to the step nearest 1 kHz
    ref = min((r for r in rows if r[5]), key=lambda r: abs(math.log(r[1] / 1000.0)))
    print('response normalised to %.1f Hz (L %.2f dBFS; ideal open-loop %.2f)\n'
          % (ref[1], db(ref[2]), IDEAL_DBFS))
    print('  idx      f Hz |    L dB    R dB  (rel) |   2nd     3rd  (rel to fund)')
    for idx, f, al, ar, h, ok in rows:
        if not ok:
            print('  %3d %9.1f |  ---- ALIASED (above this capture\'s Nyquist) ----' % (idx, f))
            continue
        s2 = '%7.2f' % (db(h[2]) - db(al)) if 2 in h else '      -'
        s3 = '%7.2f' % (db(h[3]) - db(al)) if 3 in h else '      -'
        print('  %3d %9.1f | %7.2f %7.2f        | %s %s'
              % (idx, f, db(al) - db(ref[2]), db(ar) - db(ref[3]), s2, s3))
    print('\nan ideal triangle has 3rd = -19.08 dB and NO 2nd harmonic;')
    print('sim/audio/README.md records the digital path reproducing that exactly.')


if __name__ == '__main__':
    main()
