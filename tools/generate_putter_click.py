"""Generate a short percussive "putter click" sound bundled with the app.

50 ms damped sinusoid around 800 Hz — short, sharp, like wood on a
golf ball. James can replace `PuttingLab/Resources/Sounds/putter_click.wav`
with a real recording later without any code change; the loader at
PracticeSessionViewModel just reads `putter_click.wav` from the bundle.

Output: PuttingLab/Resources/Sounds/putter_click.wav (mono, 44.1 kHz, 16-bit PCM)
Size: ~4.5 KB.
"""

import math
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "PuttingLab" / "Resources" / "Sounds" / "putter_click.wav"

SAMPLE_RATE = 44100
DURATION_S = 0.050        # 50 ms — short percussive click
FREQ_HZ = 820             # wooden tap range
DECAY_TAU_S = 0.012       # exponential decay constant (sharp drop)
ATTACK_S = 0.0015         # 1.5 ms attack (very sharp)

OUT.parent.mkdir(parents=True, exist_ok=True)

n_samples = int(SAMPLE_RATE * DURATION_S)
samples = []
for i in range(n_samples):
    t = i / SAMPLE_RATE
    # Attack envelope: short linear ramp from 0 to 1 over ATTACK_S.
    if t < ATTACK_S:
        env_attack = t / ATTACK_S
    else:
        env_attack = 1.0
    # Decay envelope: exponential. Steep => percussive.
    env_decay = math.exp(-(t - ATTACK_S) / DECAY_TAU_S) if t >= ATTACK_S else 1.0
    # Carrier: pure sine at FREQ_HZ. Real putter clicks have inharmonic
    # content but a damped sinusoid is the simplest acceptable proxy.
    carrier = math.sin(2 * math.pi * FREQ_HZ * t)
    # Combine. Scale to 80 % of full scale so it sits above background
    # but doesn't clip.
    amp = 0.80 * env_attack * env_decay * carrier
    samples.append(int(max(-1.0, min(1.0, amp)) * 32767))

with wave.open(str(OUT), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)              # 16-bit PCM
    w.setframerate(SAMPLE_RATE)
    w.writeframes(b"".join(struct.pack("<h", s) for s in samples))

size_kb = OUT.stat().st_size / 1024
print(f"Wrote {OUT.relative_to(ROOT)} ({n_samples} samples, {size_kb:.1f} KB)")
