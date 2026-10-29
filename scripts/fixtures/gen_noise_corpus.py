#!/usr/bin/env python3
"""Generates the F-04a noise corpus (specs/features/noise-suppression.md §11) under Fixtures/audio/noise/.

Every clip is synthetic, seeded and deterministic: 16 kHz mono signed 16-bit little-endian raw PCM (.pcm).
No recordings, no downloads. Re-run after changing a clip: `python3 scripts/fixtures/gen_noise_corpus.py`.
`--check` regenerates in memory and fails if a committed file differs.

Level calibration (nominal): 94 dB SPL = 16384 RMS (-6 dBFS), so 70 dB SPL road noise is RMS ~1035.
Clip layout is fixed and mirrored by NoiseCorpusTests.swift: a 1.5 s bed (gate warm-up), then the event.
Speech clips: road noise throughout, speech from SPEECH_START_FRAME for SPEECH_FRAMES (10 ms frames).
SNR is speech RMS over the whole speech span (pauses included) against the road noise RMS.
"""
import math
import random
import struct
import sys
from pathlib import Path

RATE = 16_000
FRAME = 160
OUT = Path(__file__).resolve().parents[2] / "Fixtures" / "audio" / "noise"
BED_RMS = 60.0          # quiet cabin, below the gate's RMS floor of 120
ROAD_RMS = 1035.0       # 70 dB SPL nominal
SPEECH_START_FRAME = 200
SPEECH_FRAMES = 140
NOISE_FACTOR = 2.2      # UplinkGateTuning.noiseFactor, used only for the self-check below


def secs(s):
    return int(round(s * RATE))


def white(rng, n, rms):
    return [rng.gauss(0.0, rms) for _ in range(n)]


def lowpass(x, alpha):
    y, acc = [], 0.0
    for v in x:
        acc += alpha * (v - acc)
        y.append(acc)
    return y


def scale_to_rms(x, rms):
    cur = math.sqrt(sum(v * v for v in x) / max(1, len(x))) or 1.0
    return [v * rms / cur for v in x]


def road(rng, n, rms):
    # Tyre/engine rumble: low-passed noise plus a slow 30 Hz engine component.
    x = lowpass(white(rng, n, 1.0), 0.08)
    x = [v + 0.02 * math.sin(2 * math.pi * 30 * i / RATE) for i, v in enumerate(x)]
    return scale_to_rms(x, rms)


def bed(rng, n):
    return scale_to_rms(lowpass(white(rng, n, 1.0), 0.3), BED_RMS)


def env(i, n, ramp):
    return min(1.0, i / ramp, (n - 1 - i) / ramp) if ramp > 0 else 1.0


def horn(rng, n):
    out = []
    for i in range(n):
        t = i / RATE
        on = t < 1.2
        s = math.copysign(1.0, math.sin(2 * math.pi * 420 * t)) + math.copysign(1.0, math.sin(2 * math.pi * 510 * t))
        out.append(4000 * s * env(i, secs(1.2), 80) if on else 0.0)
    return out


def indicator(rng, n):
    out = [0.0] * n
    for start in range(0, n, secs(0.4)):
        for k in range(secs(0.008)):
            if start + k < n:
                out[start + k] = 6000 * math.exp(-k / 20) * math.sin(2 * math.pi * 2500 * k / RATE)
    return out


def door_slam(rng, n):
    out = [0.0] * n
    thump = lowpass(white(rng, secs(0.35), 1.0), 0.05)
    peak = max(abs(v) for v in thump) or 1.0
    for k, v in enumerate(thump):
        out[secs(0.3) + k] = 14000 * v / peak * math.exp(-k / secs(0.07))
    return out


def dog(rng, n):
    out = [0.0] * n
    for b in range(3):
        start = secs(0.2 + b * 0.5)
        length = secs(0.15)
        for k in range(length):
            t = k / RATE
            f = 520 - 900 * t
            s = sum(math.sin(2 * math.pi * f * h * t) / h for h in range(1, 6)) + rng.gauss(0, 0.3)
            out[start + k] = 3500 * s * env(k, length, 40)
    return out


def wind(rng, n):
    x = lowpass(white(rng, n, 1.0), 0.03)
    x = scale_to_rms(x, 1.0)
    # Gusts: amplitude swells between 0.4 and 1.0 over ~0.8 s.
    return [v * 1500 * (0.7 + 0.3 * math.sin(2 * math.pi * 1.25 * i / RATE)) for i, v in enumerate(x)]


def music(rng, n):
    chords = [(220.0, 277.18, 329.63), (196.0, 246.94, 293.66), (174.61, 220.0, 261.63), (196.0, 246.94, 293.66)]
    out = []
    step = secs(0.5)
    for i in range(n):
        c = chords[(i // step) % len(chords)]
        k = i % step
        t = i / RATE
        s = sum(math.sin(2 * math.pi * f * t) + 0.3 * math.sin(4 * math.pi * f * t) for f in c)
        out.append(1100 * s * math.exp(-k / secs(0.6)))
    return out


def keyboard(rng, n):
    out = [0.0] * n
    pos = secs(0.05)
    while pos < n - secs(0.02):
        for k in range(secs(0.012)):
            out[pos + k] = rng.gauss(0, 5000) * math.exp(-k / 30)
        pos += secs(rng.uniform(0.08, 0.22))
    return out


def speech(rng, n):
    """Four voiced syllables (300 ms on, 120 ms pause), gliding f0 and two formant-weighted harmonic sets."""
    out = [0.0] * n
    syl, gap = secs(0.30), secs(0.12)
    pos = 0
    for idx in range(4):
        f0 = [180, 165, 150, 140][idx]
        formant = [700, 500, 600, 400][idx]
        for k in range(min(syl, n - pos)):
            t = k / RATE
            f = f0 * (1 - 0.15 * t)
            s = 0.0
            for h in range(1, 25):
                fh = f * h
                w = math.exp(-((fh - formant) / 350) ** 2) + 0.5 * math.exp(-((fh - 1800) / 500) ** 2) + 0.05
                s += w * math.sin(2 * math.pi * fh * t)
            out[pos + k] = s * env(k, syl, secs(0.015))
        pos += syl + gap
    return out


def mix(*parts):
    n = max(len(p) for p in parts)
    return [sum(p[i] if i < len(p) else 0.0 for p in parts) for i in range(n)]


def pad(x, before, total):
    return [0.0] * before + x + [0.0] * (total - before - len(x))


def nonspeech_clip(rng, event, event_len=secs(2.5)):
    lead = secs(1.5)
    total = lead + event_len
    return mix(bed(rng, total), pad(event(rng, event_len), lead, total))


def speech_clip(rng, snr_db):
    total = secs(5.0)
    noise = road(rng, total, ROAD_RMS)
    voice = speech(rng, SPEECH_FRAMES * FRAME)
    target = ROAD_RMS * 10 ** (snr_db / 20)
    voice = scale_to_rms(voice, target)
    clip = mix(noise, pad(voice, SPEECH_START_FRAME * FRAME, total))
    # Self-check: the first syllable must clear the F-04 energy threshold on every frame of its 200 ms onset,
    # or the scripted classifier tests would be testing the energy gate instead of F-04a.
    def frame_rms(f):
        seg = clip[f * FRAME:(f + 1) * FRAME]
        return math.sqrt(sum(v * v for v in seg) / FRAME)
    warm = sum(frame_rms(f) for f in range(150)) / 150
    onset = [frame_rms(f) for f in range(SPEECH_START_FRAME + 2, SPEECH_START_FRAME + 28)]
    # Known gap (STATUS.md, T-013d): at 5 dB the raw mix peaks at ~1.8x the bed, under the 2.2x energy rule, so
    # the F-04 onset never fires on unprocessed PCM. Only the 10 dB clip is required to clear it.
    if snr_db >= 10:
        assert min(onset) > warm * NOISE_FACTOR * 1.05, (snr_db, min(onset), warm)
    return clip


CLIPS = {
    "horn": lambda r: nonspeech_clip(r, horn),
    "indicator": lambda r: nonspeech_clip(r, indicator),
    "door_slam": lambda r: nonspeech_clip(r, door_slam),
    "dog": lambda r: nonspeech_clip(r, dog),
    "wind": lambda r: nonspeech_clip(r, wind),
    "road_70db": lambda r: nonspeech_clip(r, lambda rr, n: road(rr, n, ROAD_RMS)),
    "music": lambda r: nonspeech_clip(r, music),
    "keyboard": lambda r: nonspeech_clip(r, keyboard),
    "speech_road_snr10": lambda r: speech_clip(r, 10),
    "speech_road_snr5": lambda r: speech_clip(r, 5),
}


def render(name):
    rng = random.Random(f"F-04a:{name}")
    samples = CLIPS[name](rng)
    return b"".join(struct.pack("<h", max(-32768, min(32767, int(round(v))))) for v in samples)


def main():
    check = "--check" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    bad = []
    for name in CLIPS:
        data = render(name)
        path = OUT / f"{name}.pcm"
        if check:
            if not path.exists() or path.read_bytes() != data:
                bad.append(name)
        else:
            path.write_bytes(data)
            print(f"{path.name}: {len(data) // 2 / RATE:.2f} s")
    if bad:
        print("stale fixtures:", ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
