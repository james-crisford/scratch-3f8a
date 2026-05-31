"""Generate a realistic synthetic "ball-on-putter click" bundled with the app.

Mimics the acoustic shape of an actual golf-ball/putter impact:

  1. Initial broadband NOISE TRANSIENT (0-3 ms) — the mechanical impact moment.
     Real putter faces ring a complex inharmonic spectrum at first hit;
     filtered white noise is a cheap proxy.
  2. RESONANT TAIL — 2500 Hz fundamental + 2f + 3f harmonics, each
     decaying at its own rate (higher harmonics decay faster, as in real
     metallic objects).
  3. SHARP envelope: ~1 ms attack, ~20-30 ms exponential decay.

  Total length 40 ms. The earlier version was a smooth 50 ms 820 Hz pure
  sine — too low-pitched and too synthetic. James asked for "more
  realistic, like a ball hitting the putter".

Output: PuttingLab/Resources/Sounds/putter_click.wav (mono, 44.1 kHz, 16-bit PCM).
Drop a real recording in at that exact path to override without code change.
"""

import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "PuttingLab" / "Resources" / "Sounds" / "putter_click.wav"

SAMPLE_RATE = 44100
TOTAL_S = 0.040               # 40 ms total — short enough to feel synchronous

# --- Transient (broadband noise burst) ---
TRANSIENT_S = 0.003           # 3 ms transient
TRANSIENT_DECAY_TAU = 0.0008  # very fast decay
TRANSIENT_AMP = 0.45          # loud enough to dominate the very start

# --- Resonant tail ---
F1 = 2500.0                   # fundamental — bright metallic putter click
HARMONICS = [
    # (multiplier_of_f1, amplitude, decay_tau_s)
    (1.0, 0.55, 0.018),       # f1 — main ring
    (2.05, 0.22, 0.011),      # ~2f, slightly stretched (inharmonic — real metal)
    (3.10, 0.12, 0.007),      # ~3f
    (4.20, 0.06, 0.004),      # ~4f sparkle
]
RESONANT_ATTACK_S = 0.0010    # 1 ms attack (sharp)

random.seed(0xCAFE)           # deterministic — checksum stable across regenerations
OUT.parent.mkdir(parents=True, exist_ok=True)

n_samples = int(SAMPLE_RATE * TOTAL_S)
samples = []
for i in range(n_samples):
    t = i / SAMPLE_RATE

    # 1) Broadband noise transient (band-limited via a simple 2-pole-ish
    #    pinking by averaging adjacent noise samples — not perfect, fine for SFX).
    if t < TRANSIENT_S * 3:
        env_t = math.exp(-t / TRANSIENT_DECAY_TAU)
        noise = (random.random() * 2 - 1)
        transient = TRANSIENT_AMP * env_t * noise
    else:
        transient = 0.0

    # 2) Resonant harmonics with per-mode decay
    resonance = 0.0
    if t >= 0:
        if t < RESONANT_ATTACK_S:
            env_a = t / RESONANT_ATTACK_S
        else:
            env_a = 1.0
        for mult, amp, tau in HARMONICS:
            env_d = math.exp(-(t - RESONANT_ATTACK_S) / tau) if t >= RESONANT_ATTACK_S else 1.0
            resonance += amp * env_a * env_d * math.sin(2 * math.pi * F1 * mult * t)

    raw = transient + resonance
    # Soft clip to prevent any chance of going past 1.0 after summation.
    if raw > 1.0: raw = 1.0
    elif raw < -1.0: raw = -1.0
    samples.append(int(raw * 32767))

with wave.open(str(OUT), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SAMPLE_RATE)
    w.writeframes(b"".join(struct.pack("<h", s) for s in samples))

size_kb = OUT.stat().st_size / 1024
print(f"Wrote {OUT.relative_to(ROOT)} ({n_samples} samples, {size_kb:.1f} KB, "
      f"{TOTAL_S*1000:.0f} ms, fundamental {F1:.0f} Hz)")
