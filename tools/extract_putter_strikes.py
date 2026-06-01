"""Auto-detect putter-strike moments in a recorded WAV and extract short
clips around each. Yields one clip per strike, normalised + trimmed to
~150 ms around the impact transient.

Strategy:
  1. Read the WAV (any sample rate, mono or stereo).
  2. Compute a short-window RMS envelope (5 ms window).
  3. Find peaks at least N seconds apart that exceed a threshold.
  4. For each peak, extract `pre_ms` before + `post_ms` after, mono-mix,
     resample to 44.1 kHz mono 16-bit, peak-normalise to -0.5 dBFS, save.

Use:
  python tools/extract_putter_strikes.py SOURCE_WAV OUT_PREFIX
"""

from __future__ import annotations

import math
import struct
import sys
import wave
from array import array
from pathlib import Path


def load_wav(path: Path) -> tuple[list[float], int]:
    """Return (mono samples in [-1,1], sample_rate)."""
    with wave.open(str(path), "rb") as w:
        nchan = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        a = array("h"); a.frombytes(raw)
    elif sw == 4:
        a = array("i"); a.frombytes(raw)
    else:
        raise SystemExit(f"unsupported sample width {sw}")
    scale = 1.0 / (1 << (8 * sw - 1))
    samples = [v * scale for v in a]
    if nchan == 2:
        # Average stereo to mono
        samples = [(samples[i] + samples[i+1]) * 0.5 for i in range(0, len(samples), 2)]
    return samples, sr


def rms_envelope(samples: list[float], sr: int, window_ms: float = 5.0) -> list[float]:
    w = max(1, int(sr * window_ms / 1000))
    out = [0.0] * (len(samples) - w + 1)
    sq_sum = sum(s * s for s in samples[:w])
    out[0] = math.sqrt(sq_sum / w)
    for i in range(1, len(out)):
        sq_sum += samples[i + w - 1] ** 2 - samples[i - 1] ** 2
        out[i] = math.sqrt(max(0.0, sq_sum) / w)
    return out


def find_peaks(env: list[float], sr: int,
               min_gap_s: float = 0.6,
               rel_threshold: float = 0.45,
               max_peaks: int = 6) -> list[int]:
    if not env:
        return []
    peak_amp = max(env)
    thresh = peak_amp * rel_threshold
    gap = int(min_gap_s * sr / (len(env) / max(1, len(env))))  # samples in env
    # env was computed sliding-1, so 1 env sample = 1 audio sample
    gap = int(min_gap_s * sr)
    picks: list[int] = []
    i = 0
    while i < len(env):
        if env[i] >= thresh:
            # Find local max within +/- gap
            lo = max(0, i - gap // 4)
            hi = min(len(env), i + gap // 4)
            local_max_idx = max(range(lo, hi), key=lambda k: env[k])
            if not picks or local_max_idx - picks[-1] >= gap:
                picks.append(local_max_idx)
            i = local_max_idx + gap
        else:
            i += 1
    picks.sort(key=lambda p: -env[p])
    return picks[:max_peaks]


def extract_clip(samples: list[float], sr: int, center_idx: int,
                  pre_ms: float = 15.0, post_ms: float = 130.0) -> list[float]:
    pre = int(sr * pre_ms / 1000)
    post = int(sr * post_ms / 1000)
    lo = max(0, center_idx - pre)
    hi = min(len(samples), center_idx + post)
    clip = samples[lo:hi]
    # Peak-normalise to -0.5 dBFS
    peak = max(abs(s) for s in clip) if clip else 0.0
    if peak > 0:
        target = 10 ** (-0.5 / 20)
        scale = target / peak
        clip = [s * scale for s in clip]
    return clip


def resample_44100(samples: list[float], src_sr: int) -> list[float]:
    if src_sr == 44100:
        return samples
    ratio = 44100 / src_sr
    new_len = int(len(samples) * ratio)
    out = [0.0] * new_len
    for i in range(new_len):
        src = i / ratio
        a = int(src)
        b = min(a + 1, len(samples) - 1)
        f = src - a
        out[i] = samples[a] * (1 - f) + samples[b] * f
    return out


def save_wav(path: Path, samples: list[float], sr: int = 44100):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(s * 32767)))) for s in samples))


def main(src: Path, prefix: Path):
    samples, sr = load_wav(src)
    print(f"loaded {src.name}: {len(samples)} samples @ {sr} Hz ({len(samples)/sr:.1f}s)")
    env = rms_envelope(samples, sr)
    peaks = find_peaks(env, sr, min_gap_s=0.7, rel_threshold=0.55, max_peaks=4)
    print(f"  found {len(peaks)} peak candidates")
    for n, p in enumerate(peaks, 1):
        t = p / sr
        clip = extract_clip(samples, sr, p)
        clip = resample_44100(clip, sr)
        out = prefix.with_name(f"{prefix.stem}_strike{n:02d}.wav")
        save_wav(out, clip)
        print(f"  strike {n}: t={t:.2f}s  -> {out.name} ({len(clip)/44100*1000:.0f} ms)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: extract_putter_strikes.py SOURCE.wav OUT_PREFIX (e.g. variant_real_ping)")
        sys.exit(1)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
