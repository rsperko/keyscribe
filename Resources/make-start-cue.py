#!/usr/bin/env python3
# Generates start-cue.wav, KeyScribe's "now listening" cue. Original first-party synthesis — no
# system or third-party audio is sampled — so the GPLv3 bundle ships only assets we can license.
# A short (~95 ms) low percussive "woodblock": a 420 Hz tone with one inharmonic partial and a very
# fast decay, normalized to a fixed peak. Kept brief so gating capture on it costs little.
# Re-run from Resources/ to regenerate: `python3 make-start-cue.py`.
import math
import struct
import wave

SAMPLE_RATE = 44_100
DURATION = 0.095
ATTACK = 0.005
DECAY_TAU = 0.018
TAIL = 0.012
PEAK = 0.5
FREQ = 420.0
PARTIALS = ((1.0, 1.0), (2.76, 0.25))


def sample(t):
    if t < ATTACK:
        env = 0.5 * (1 - math.cos(math.pi * t / ATTACK))
    else:
        env = math.exp(-(t - ATTACK) / DECAY_TAU)
    tone = sum(amp * math.sin(2 * math.pi * FREQ * mult * t) for mult, amp in PARTIALS)
    value = env * tone
    if t > DURATION - TAIL:
        value *= (DURATION - t) / TAIL
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
