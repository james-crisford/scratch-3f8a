#!/usr/bin/env python3
"""Offline visualiser for PuttingLab StrokeReplay JSON files.

Reads a single .json (one stroke) or a directory (batch) and renders three
stacked timelines per stroke:
  1. Rotation magnitude (rad/s)
  2. UserAcceleration magnitude (m/s²)
  3. Yaw drift from the locked baseline (rad)

Vertical guides mark windowStart, windowEnd, and result.timestamp. Squared
+ snapReason annotation if the stroke snapped.

Usage:
    python replay_viz.py path/to/stroke-2026-05-30T10-15-22.json
    python replay_viz.py path/to/StrokeReplays/                     # batch dir
    python replay_viz.py path/to/StrokeReplays/ --batch-out plots/  # save instead of show

Cribbed from references/CoreMotion-Data-Logger/Visualization/exampleVisualizer.py
adapted for our JSON schema.

Requires: matplotlib, numpy. Install: pip install matplotlib numpy
"""
import argparse
import json
import math
import sys
from pathlib import Path

try:
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("ERROR: needs matplotlib + numpy.  pip install matplotlib numpy", file=sys.stderr)
    sys.exit(1)


def _load(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _yaw_from_quat(q: list) -> float:
    """Extract yaw (rotation about Z) from a quaternion [ix, iy, iz, r]."""
    ix, iy, iz, r = q
    # yaw = atan2(2*(r*iz + ix*iy), 1 - 2*(iy² + iz²))
    return math.atan2(2.0 * (r * iz + ix * iy), 1.0 - 2.0 * (iy * iy + iz * iz))


def _magnitude(v: list) -> float:
    return math.sqrt(sum(x * x for x in v))


def render(replay: dict, source: str) -> plt.Figure:
    samples = replay["samples"]
    if not samples:
        raise ValueError(f"{source}: no samples in replay")

    t0 = samples[0]["timestamp"]
    ts = np.array([s["timestamp"] - t0 for s in samples])
    rot_mag = np.array([_magnitude(s["rotationRate"]) for s in samples])
    acc_mag = np.array([_magnitude(s["userAcceleration"]) for s in samples])
    yaw_baseline = replay["lock"]["yawTargetCompass"]
    yaws = np.array([_yaw_from_quat(s["attitude"]) for s in samples])
    yaw_drift = yaws - yaw_baseline

    fig, axes = plt.subplots(3, 1, figsize=(10, 8), sharex=True)
    fig.suptitle(f"{source}\n{replay.get('deviceModel', '?')} · {replay.get('appVersion', '?')}", fontsize=10)

    axes[0].plot(ts, rot_mag, color="#1f77b4")
    axes[0].set_ylabel("rotation magnitude\n(rad/s)")
    axes[0].grid(True, alpha=0.3)

    axes[1].plot(ts, acc_mag, color="#ff7f0e")
    axes[1].set_ylabel("userAcceleration\nmagnitude (m/s²)")
    axes[1].grid(True, alpha=0.3)

    axes[2].plot(ts, yaw_drift, color="#2ca02c")
    axes[2].set_ylabel("yaw drift from\nlock baseline (rad)")
    axes[2].set_xlabel("time since first sample (s)")
    axes[2].grid(True, alpha=0.3)
    axes[2].axhline(0.0, color="grey", linewidth=0.5, alpha=0.5)

    window_start = replay["windowStart"] - t0
    window_end = replay["windowEnd"] - t0
    for ax in axes:
        ax.axvline(window_start, color="blue", linestyle="--", alpha=0.5, label="stroke window")
        ax.axvline(window_end, color="blue", linestyle="--", alpha=0.5)

    result = replay.get("result")
    if result:
        impact_t = result["timestamp"] - t0
        for ax in axes:
            ax.axvline(impact_t, color="red", linestyle="-", alpha=0.7, linewidth=2, label="impact")
        face_deg = math.degrees(result["faceAngleRaw"])
        snap_label = ""
        if result.get("snappedToSquare"):
            snap_label = f" (snap: {result.get('snapReason', '?')})"
        axes[0].set_title(
            f"face {face_deg:+.2f}° | peak {result['peakVelocity']:.2f} m/s "
            f"| conf {result['confidence']:.2f}{snap_label}",
            fontsize=9,
        )

    axes[0].legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    return fig


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", help="JSON file or directory of JSON files")
    p.add_argument(
        "--batch-out",
        help="If set, save each stroke's plot as PNG to this directory instead of showing",
    )
    args = p.parse_args()

    root = Path(args.path)
    if not root.exists():
        print(f"ERROR: {root} not found", file=sys.stderr)
        return 1

    files = [root] if root.is_file() else sorted(root.glob("*.json"))
    if not files:
        print(f"WARNING: no .json files in {root}", file=sys.stderr)
        return 0

    out_dir = Path(args.batch_out) if args.batch_out else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    for f in files:
        try:
            replay = _load(f)
            fig = render(replay, f.name)
            if out_dir:
                target = out_dir / (f.stem + ".png")
                fig.savefig(target, dpi=120, bbox_inches="tight")
                plt.close(fig)
                print(f"saved {target}")
            else:
                plt.show()
        except Exception as e:
            print(f"ERROR rendering {f.name}: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
