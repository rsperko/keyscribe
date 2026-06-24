#!/usr/bin/env python3
# Generates start-cue.wav, KeyScribe's "now listening" cue. Original first-party synthesis — no
# system or third-party audio is sampled — so the GPLv3 bundle ships only assets we can license.
# A short (~110 ms) rising two-tone blip with a fast attack and exponential decay. Re-run from
# Resources/ to regenerate: `python3 make-start-cue.py`.
import math
import struct
import wave

SAMPLE_RATE = 44_100
DURATION = 0.11
ATTACK = 0.004
DECAY_TAU = 0.028
TAIL = 0.012
PEAK = 0.45


def envelope(t):
    if t < ATTACK:
        return t / ATTACK
    return math.exp(-(t - ATTACK) / DECAY_TAU)


def sample(t):
    freq = 1180 + 220 * (t / DURATION)
    tone = math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * 2 * freq * t)
    value = tone * envelope(t) * PEAK
    if t > DURATION - TAIL:
        value *= (DURATION - t) / TAIL
    return max(-1.0, min(1.0, value))


frame_count = int(SAMPLE_RATE * DURATION)
frames = b"".join(
    struct.pack("<h", int(sample(i / SAMPLE_RATE) * 32_767)) for i in range(frame_count)
)

with wave.open("start-cue.wav", "w") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(SAMPLE_RATE)
    out.writeframes(frames)
