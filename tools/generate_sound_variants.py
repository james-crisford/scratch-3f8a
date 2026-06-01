"""Generate a palette of putter-click sound variants for James to audition.

Six distinct timbres covering the realistic ball-on-putter design space:

  variant_01_bright_metallic.wav   — high-pitched titanium putter feel
  variant_02_default_b16.wav       — what's currently in the app (baseline)
  variant_03_soft_balata.wav       — softer, mellower, vintage-feel
  variant_04_strong_impact.wav     — exaggerated transient, "thwack"
  variant_05_low_wood.wav          — wooden-mallet feel (like a hickory putter)
  variant_06_glassy_ping.wav       — sharp glassy ring (very modern blade putter)

Each is 30-60 ms, mono, 44.1 kHz, 16-bit PCM, deterministic (seeded RNG).
Pick whichever sounds right and we'll bundle it as
PuttingLab/Resources/Sounds/putter_click.wav.
"""

import math
import random
import struct
import wave
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / ".tmp" / "sound_variants"
OUT_DIR.mkdir(parents=True, exist_ok=True)

SAMPLE_RATE = 44100


@dataclass
class Variant:
    name: str
    total_s: float
    transient_s: float
    transient_decay_tau: float
    transient_amp: float
    attack_s: float
    fundamental_hz: float
    # (multiplier_of_fundamental, amplitude, decay_tau_s)
    harmonics: list


VARIANTS = [
    Variant(
        name="01_bright_metallic",
        total_s=0.045,
        transient_s=0.0025,
        transient_decay_tau=0.0007,
        transient_amp=0.50,
        attack_s=0.0008,
        fundamental_hz=3600.0,
        harmonics=[
            (1.0, 0.55, 0.014),
            (2.07, 0.30, 0.010),
            (3.13, 0.18, 0.006),
            (4.25, 0.09, 0.003),
            (5.30, 0.04, 0.002),
        ],
    ),
    Variant(
        name="02_default_b16",
        total_s=0.040,
        transient_s=0.003,
        transient_decay_tau=0.0008,
        transient_amp=0.45,
        attack_s=0.0010,
        fundamental_hz=2500.0,
        harmonics=[
            (1.0, 0.55, 0.018),
            (2.05, 0.22, 0.011),
            (3.10, 0.12, 0.007),
            (4.20, 0.06, 0.004),
        ],
    ),
    Variant(
        name="03_soft_balata",
        total_s=0.055,
        transient_s=0.004,
        transient_decay_tau=0.0014,
        transient_amp=0.25,
        attack_s=0.0020,
        fundamental_hz=1800.0,
        harmonics=[
            (1.0, 0.50, 0.028),
            (1.98, 0.28, 0.020),
            (2.95, 0.14, 0.014),
            (4.10, 0.06, 0.008),
        ],
    ),
    Variant(
        name="04_strong_impact",
        total_s=0.035,
        transient_s=0.0035,
        transient_decay_tau=0.0010,
        transient_amp=0.75,
        attack_s=0.0008,
        fundamental_hz=2100.0,
        harmonics=[
            (1.0, 0.45, 0.012),
            (2.04, 0.30, 0.009),
            (3.11, 0.18, 0.005),
            (4.18, 0.08, 0.003),
        ],
    ),
    Variant(
        name="05_low_wood",
        total_s=0.060,
        transient_s=0.0035,
        transient_decay_tau=0.0012,
        transient_amp=0.40,
        attack_s=0.0018,
        fundamental_hz=950.0,
        harmonics=[
            (1.0, 0.55, 0.032),
            (1.93, 0.28, 0.024),
            (2.87, 0.15, 0.015),
            (3.81, 0.06, 0.010),
        ],
    ),
    Variant(
        name="06_glassy_ping",
        total_s=0.050,
        transient_s=0.0020,
        transient_decay_tau=0.0006,
        transient_amp=0.35,
        attack_s=0.0006,
        fundamental_hz=4200.0,
        harmonics=[
            (1.0, 0.45, 0.022),
            (2.10, 0.35, 0.014),
            (3.18, 0.20, 0.008),
            (4.30, 0.10, 0.005),
            (5.50, 0.05, 0.003),
        ],
    ),
]


def render(v: Variant) -> tuple[Path, float]:
    """Render a Variant to a WAV and return (path, peak_amp_db)."""
    random.seed(0xCAFE)
    n_samples = int(SAMPLE_RATE * v.total_s)
    samples = []
    peak = 0.0
    for i in range(n_samples):
        t = i / SAMPLE_RATE
        # Transient
        if t < v.transient_s * 3:
            env_t = math.exp(-t / v.transient_decay_tau)
            noise = random.random() * 2 - 1
            transient = v.transient_amp * env_t * noise
        else:
            transient = 0.0
        # Resonant harmonics
        if t < v.attack_s:
            env_a = t / v.attack_s
        else:
            env_a = 1.0
        resonance = 0.0
        for mult, amp, tau in v.harmonics:
            decay_t = max(0.0, t - v.attack_s)
            env_d = math.exp(-decay_t / tau)
            resonance += amp * env_a * env_d * math.sin(2 * math.pi * v.fundamental_hz * mult * t)
        raw = transient + resonance
        if abs(raw) > peak: peak = abs(raw)
        # Soft clip
        if raw > 1.0: raw = 1.0
        elif raw < -1.0: raw = -1.0
        samples.append(int(raw * 32767))

    out = OUT_DIR / f"variant_{v.name}.wav"
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))
    peak_db = 20 * math.log10(max(peak, 1e-9))
    return out, peak_db


print(f"Rendering {len(VARIANTS)} variants to {OUT_DIR.relative_to(ROOT)}/")
for v in VARIANTS:
    path, peak_db = render(v)
    size_kb = path.stat().st_size / 1024
    print(f"  {v.name:<24}  {v.total_s*1000:>4.0f} ms  f0={v.fundamental_hz:>5.0f} Hz  "
          f"transient={v.transient_amp:.2f}  peak={peak_db:+.1f} dB  {size_kb:.1f} KB")
