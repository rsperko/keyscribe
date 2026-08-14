#!/usr/bin/env python3
# Generates start-cue.wav, KeyScribe's "now listening" cue. Original first-party synthesis — no
# system or third-party audio is sampled — so the GPLv3 bundle ships only assets we can license.
# A short (~62 ms), front-loaded bell cue centered at 590 Hz with restrained inharmonic overtones.
# DURATION is latency, not taste: capture admission is gated on the file's length, so every millisecond
# of inaudible tail delays recording. The resonances are ~33 dB down by the time TAIL starts fading, so
# the file ends as soon as the strike has decayed rather than running the envelope to true silence.
# Re-run from Resources/ to regenerate: `python3 make-start-cue.py`.
import math
import struct
import wave

SAMPLE_RATE = 44_100
DURATION = 0.062
ATTACK = 0.0007
TAIL = 0.012
PEAK = 0.38
RESONANCES = (
    (590.0, 1.0, 0.013),
    (1627.0, 0.18, 0.009),
    (2444.0, 0.025, 0.0045),
)


def sample(t):
    attack = 0.5 * (1 - math.cos(math.pi * min(t / ATTACK, 1.0)))
    value = sum(
        amplitude * math.exp(-t / decay) * math.sin(2 * math.pi * frequency * t)
        for frequency, amplitude, decay in RESONANCES
    )
    value *= attack
    if t > DURATION - TAIL:
        value *= 0.5 * (1 + math.cos(math.pi * (t - (DURATION - TAIL)) / TAIL))
    return value


frame_count = int(SAMPLE_RATE * DURATION)
raw = [sample(i / SAMPLE_RATE) for i in range(frame_count)]
gain = PEAK / max(1e-9, max(abs(v) for v in raw))
frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * gain)) * 32_767)) for v in raw)

with wave.open("start-cue.wav", "w") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(SAMPLE_RATE)
    out.writeframes(frames)
