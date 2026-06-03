"""
B55 — replay the 192-stroke historical dataset through the current
BallPhysics.simulatePutt model to see where each putt would have ended
up under today's physics.

Reads every stroke replay JSON in:
  - data/raw/by-build/<build>/stroke-*.json   (192 strokes, builds 0.1.3 -> 0.2.2)
  - .tmp/b12-strokes / .tmp/b13-strokes       (92 strokes, pre-replay-store format)

For each stroke, extracts:
  - peakVelocity (from result.peakVelocity)
  - faceAngleRaw (from result.faceAngleRaw, radians)
  - speedCalibration = 1.0   (no per-user calibration yet)
  - stimpFeet = 10.0          (BallPhysics default)
  - cupPosition = (2.0, 0.0)  (2 m straight putt)

Runs Python port of BallPhysics.simulatePutt (semi-implicit Euler
with rolling friction). Emits a CSV + summary histogram so we can:
  1. Validate the physics didn't regress (sanity: ~3 m putts produce
     ~1.5-2.5 m roll distances)
  2. See the distribution of computed distances against what James
     felt was a "good putt" vs "too soft"
  3. Estimate how many strokes would have been .captured / .lipOut /
     .stopped given the historical face-angle + velocity distribution

Usage:
  py -3.12 tools/simulate_historical_strokes.py
Output: tools/output/historical-stroke-sim.csv + .md summary
"""

import json
import math
import csv
from pathlib import Path
from collections import Counter

PROJECT = Path(__file__).parent.parent
DATA_DIRS = [
    PROJECT / "data" / "raw" / "by-build",
    PROJECT / ".tmp" / "b12-strokes",
    PROJECT / ".tmp" / "b13-strokes",
]
OUT_DIR = PROJECT / "tools" / "output"
OUT_DIR.mkdir(parents=True, exist_ok=True)
CSV_PATH = OUT_DIR / "historical-stroke-sim.csv"
MD_PATH = OUT_DIR / "historical-stroke-sim.md"

# Match BallPhysics.swift constants exactly.
G = 9.81
LAUNCH_COEFFICIENT = 0.90
SKID_ENERGY_RETENTION = 0.95
STOP_VELOCITY = 0.05
CAPTURE_VELOCITY = 1.626
CUP_RADIUS = 0.054
MAX_STEPS = 10_000
DEFAULT_DT = 1.0 / 60.0

def rolling_friction(stimp_feet: float) -> float:
    clamped = max(4.0, min(14.0, stimp_feet))
    return 0.611 / clamped

def simulate_putt(peak_velocity: float, face_angle_raw: float,
                   speed_calibration: float = 1.0,
                   stimp_feet: float = 10.0,
                   cup_x: float = 2.0,
                   cup_y: float = 0.0,
                   dt: float = DEFAULT_DT) -> dict:
    """Python port of BallPhysics.simulatePutt — flat-green pure-roll.

    Returns dict with end_x, end_y, total_time, outcome, total_distance.
    """
    if not all(math.isfinite(v) for v in [peak_velocity, face_angle_raw,
                                            speed_calibration, stimp_feet]):
        return {"outcome": "rejected", "end_x": 0.0, "end_y": 0.0,
                "total_time": 0.0, "total_distance": 0.0}
    if peak_velocity < 0:
        return {"outcome": "rejected", "end_x": 0.0, "end_y": 0.0,
                "total_time": 0.0, "total_distance": 0.0}

    v0_mag = (peak_velocity * speed_calibration * LAUNCH_COEFFICIENT
              * math.sqrt(SKID_ENERGY_RETENTION))

    if v0_mag < STOP_VELOCITY:
        return {"outcome": "stopped", "end_x": 0.0, "end_y": 0.0,
                "total_time": 0.0, "total_distance": 0.0}

    psi0 = -face_angle_raw
    vx = v0_mag * math.cos(psi0)
    vy = v0_mag * math.sin(psi0)
    px = 0.0
    py = 0.0

    mu = rolling_friction(stimp_feet)
    friction_decel = mu * G

    t = 0.0
    outcome = "stopped"
    lip_out_seen = False
    total_distance = 0.0

    for step in range(MAX_STEPS):
        speed = math.sqrt(vx * vx + vy * vy)
        if speed < STOP_VELOCITY:
            outcome = "lipOut" if lip_out_seen else "stopped"
            break
        fx = -friction_decel * (vx / speed)
        fy = -friction_decel * (vy / speed)
        nvx = vx + fx * dt
        nvy = vy + fy * dt
        nspeed = math.sqrt(nvx * nvx + nvy * nvy)
        if (nvx * vx + nvy * vy) < 0 or nspeed < STOP_VELOCITY:
            nvx = 0.0
            nvy = 0.0
        npx = px + nvx * dt
        npy = py + nvy * dt

        # Cup intersection — closest-point-on-segment approach.
        dx = npx - px
        dy = npy - py
        seg_len_sq = dx * dx + dy * dy
        if seg_len_sq > 1e-12:
            t_proj = ((cup_x - px) * dx + (cup_y - py) * dy) / seg_len_sq
            t_proj = max(0.0, min(1.0, t_proj))
            closest_x = px + t_proj * dx
            closest_y = py + t_proj * dy
            d_cup = math.sqrt((closest_x - cup_x) ** 2
                              + (closest_y - cup_y) ** 2)
            if d_cup <= CUP_RADIUS:
                entry_speed = (1.0 - t_proj) * speed + t_proj * nspeed
                if entry_speed <= CAPTURE_VELOCITY:
                    total_distance += math.sqrt((cup_x - px) ** 2 + (cup_y - py) ** 2)
                    return {"outcome": "captured",
                             "end_x": cup_x, "end_y": cup_y,
                             "total_time": t + dt * t_proj,
                             "total_distance": total_distance}
                else:
                    # Lip out: ball kicks radially out at 0.6 * v_entry.
                    lip_out_seen = True
                    # For simplicity skip the kick simulation; just mark
                    # as lipOut + continue. Tail behaviour is the same
                    # as a slow miss past the cup.
        step_dist = math.sqrt(dx * dx + dy * dy)
        total_distance += step_dist
        px, py = npx, npy
        vx, vy = nvx, nvy
        t += dt

    return {"outcome": outcome, "end_x": px, "end_y": py,
            "total_time": t, "total_distance": total_distance}

def load_strokes() -> list:
    """Walk all data dirs, load every stroke replay JSON, normalise the
    shape. Returns list of dicts with build, file, peak_velocity,
    face_angle_raw, user_judgment, snapped_to_square."""
    strokes = []
    for root in DATA_DIRS:
        if not root.exists():
            continue
        for jf in sorted(root.rglob("stroke-*.json")):
            try:
                d = json.loads(jf.read_text())
            except Exception:
                continue
            result = d.get("result", {})
            peak_velocity = result.get("peakVelocity")
            face_angle_raw = result.get("faceAngleRaw")
            if peak_velocity is None or face_angle_raw is None:
                continue
            # Build identifier from directory structure.
            try:
                rel = jf.relative_to(PROJECT)
                build = rel.parts[2] if rel.parts[0] == "data" else rel.parts[1]
            except Exception:
                build = "unknown"
            strokes.append({
                "build": build,
                "file": str(jf.name),
                "peak_velocity": float(peak_velocity),
                "face_angle_raw": float(face_angle_raw),
                "snapped_to_square": result.get("snappedToSquare", False),
                "confidence": result.get("confidence", 1.0),
                "user_judgment": d.get("userImpactJudgment"),
                "batch_id": d.get("batchId"),
            })
    return strokes

def main():
    strokes = load_strokes()
    print(f"Loaded {len(strokes)} stroke replays")

    rows = []
    outcomes = Counter()
    distances = []
    velocities = []
    face_angles_deg = []

    # Derive per-user speedCalibration factor from the data itself.
    # CalibrationModel uses: factor = required_fps / (mean_peak_velocity * mpsToFps)
    # where required_fps targets a 10ft putt at Stimp 10.
    # For Stimp 10, 3.048m (10ft) target: v0 needed = sqrt(2 * mu*g * 3.048)
    # = sqrt(2 * 0.0611 * 9.81 * 3.048) = ~1.91 m/s
    # peak_velocity * factor * 0.9 * sqrt(0.95) = 1.91
    # -> factor = 1.91 / (peak_velocity * 0.873)
    mean_peak = sum(s["peak_velocity"] for s in strokes) / len(strokes)
    derived_factor = 1.91 / (mean_peak * LAUNCH_COEFFICIENT
                              * math.sqrt(SKID_ENERGY_RETENTION))
    print(f"Derived speedCalibration factor: {derived_factor:.2f}x "
           f"(mean peak velocity {mean_peak:.3f} m/s -> target v0 1.91 m/s for 3m putt)")
    print()

    for s in strokes:
        sim = simulate_putt(
            peak_velocity=s["peak_velocity"],
            face_angle_raw=s["face_angle_raw"],
            speed_calibration=derived_factor,
        )
        outcomes[sim["outcome"]] += 1
        distances.append(sim["total_distance"])
        velocities.append(s["peak_velocity"])
        face_angles_deg.append(math.degrees(s["face_angle_raw"]))
        rows.append({
            "build": s["build"],
            "file": s["file"],
            "peak_velocity_mps": round(s["peak_velocity"], 4),
            "face_angle_deg": round(math.degrees(s["face_angle_raw"]), 2),
            "snapped": s["snapped_to_square"],
            "confidence": round(float(s["confidence"]), 3),
            "user_judgment": s["user_judgment"],
            "computed_distance_m": round(sim["total_distance"], 3),
            "outcome": sim["outcome"],
            "end_x_m": round(sim["end_x"], 3),
            "end_y_m": round(sim["end_y"], 3),
            "total_time_s": round(sim["total_time"], 3),
        })

    # Write CSV.
    if rows:
        with open(CSV_PATH, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=rows[0].keys())
            w.writeheader()
            w.writerows(rows)

    # Summary stats.
    def stats(name, vs):
        if not vs:
            return f"{name}: n=0"
        vs_sorted = sorted(vs)
        n = len(vs_sorted)
        mean = sum(vs_sorted) / n
        median = vs_sorted[n // 2]
        p10 = vs_sorted[int(n * 0.10)]
        p90 = vs_sorted[int(n * 0.90)]
        return (f"{name}: n={n}, min={vs_sorted[0]:.3f}, "
                f"p10={p10:.3f}, median={median:.3f}, mean={mean:.3f}, "
                f"p90={p90:.3f}, max={vs_sorted[-1]:.3f}")

    # Distance buckets (m).
    dist_buckets = Counter()
    for d in distances:
        if d < 0.5: dist_buckets["<0.5m"] += 1
        elif d < 1.0: dist_buckets["0.5-1.0m"] += 1
        elif d < 2.0: dist_buckets["1.0-2.0m"] += 1
        elif d < 3.0: dist_buckets["2.0-3.0m"] += 1
        elif d < 5.0: dist_buckets["3.0-5.0m"] += 1
        else: dist_buckets["5.0m+"] += 1

    # Per-build summaries.
    per_build = {}
    for r in rows:
        b = r["build"]
        per_build.setdefault(b, []).append(r["computed_distance_m"])

    # Mario Kart bucket × outcome cross-tab.
    # Buckets per MarioKartAssist:
    #   |angle| < 6   -> Square
    #   6  <= |angle| < 12 -> Slight pull (-) / Slight push (+)
    #   12 <= |angle| < 20 -> Pull (-) / Push (+)
    #   |angle| >= 20      -> Miss
    def bucket_for(face_deg: float) -> str:
        a = abs(face_deg)
        sign = "push" if face_deg > 0 else "pull"
        if a < 6:    return "Square"
        if a < 12:   return f"Slight {sign}"
        if a < 20:   return sign.capitalize()
        return "Miss"
    bucket_outcomes = {}  # bucket -> Counter of outcomes
    bucket_lat_offset = {}  # bucket -> list of lateral offsets at cup
    for r in rows:
        b = bucket_for(r["face_angle_deg"])
        bucket_outcomes.setdefault(b, Counter())[r["outcome"]] += 1
        bucket_lat_offset.setdefault(b, []).append(r["end_y_m"])
    # Cup radius from BallPhysics = 0.054m (5.4cm), ball radius ~0.021m,
    # so effective capture half-width ~0.075m. Lateral offset at cup
    # distance d=2m: y = 2 * sin(face_angle).

    summary = []
    summary.append(f"# Historical stroke simulation — B55 BallPhysics replay\n")
    summary.append(f"**Replayed {len(rows)} strokes** from `data/raw/by-build/` + `.tmp/b1[23]-strokes/` "
                    f"through `BallPhysics.simulatePutt` with the v0.2.2-era defaults "
                    f"(stimpFeet=10, cupPosition=(2,0), speedCalibration=1.0).\n")
    summary.append(f"## Outcomes\n")
    for k, v in outcomes.most_common():
        pct = v / len(rows) * 100 if rows else 0
        summary.append(f"- **{k}**: {v} ({pct:.1f}%)")
    summary.append("")
    summary.append(f"## Distance distribution\n")
    for k in ["<0.5m", "0.5-1.0m", "1.0-2.0m", "2.0-3.0m", "3.0-5.0m", "5.0m+"]:
        v = dist_buckets.get(k, 0)
        pct = v / len(rows) * 100 if rows else 0
        summary.append(f"- {k}: {v} ({pct:.1f}%)")
    summary.append("")
    summary.append(f"## Statistics\n")
    summary.append(f"- {stats('Peak velocity (m/s)', velocities)}")
    summary.append(f"- {stats('Face angle (deg)', face_angles_deg)}")
    summary.append(f"- {stats('Computed distance (m)', distances)}")
    summary.append("")
    summary.append(f"## Face-angle bucket x outcome (push/pull strokes should miss)\n")
    summary.append(f"| Bucket | n | captured | lipOut | stopped | median lat. offset |")
    summary.append(f"|---|---|---|---|---|---|")
    bucket_order = ["Square", "Slight pull", "Slight push", "Pull", "Push", "Miss"]
    for b in bucket_order:
        if b not in bucket_outcomes: continue
        outcomes_b = bucket_outcomes[b]
        n = sum(outcomes_b.values())
        cap = outcomes_b.get("captured", 0)
        lip = outcomes_b.get("lipOut", 0)
        stop = outcomes_b.get("stopped", 0)
        ys = sorted(bucket_lat_offset[b])
        med_y = ys[len(ys) // 2] if ys else 0.0
        summary.append(f"| {b} | {n} | {cap} | {lip} | {stop} | {med_y:+.3f}m |")
    summary.append("")
    summary.append(f"**Cup radius = 0.054m. Captures should only come from |face| < ~2deg "
                    f"(at 2m cup distance, lateral offset = 2 * sin(face_angle)). "
                    f"Bucket 'Square' covers up to 6deg so most Squares should miss too.**\n")

    summary.append(f"## Per-build distance stats\n")
    summary.append(f"| Build | n | min | p10 | median | p90 | max |")
    summary.append(f"|---|---|---|---|---|---|---|")
    for b, ds in sorted(per_build.items()):
        ds_sorted = sorted(ds)
        n = len(ds_sorted)
        if n == 0: continue
        summary.append(f"| {b} | {n} | {ds_sorted[0]:.2f} | "
                        f"{ds_sorted[int(n*0.10)]:.2f} | "
                        f"{ds_sorted[n//2]:.2f} | "
                        f"{ds_sorted[int(n*0.90)]:.2f} | "
                        f"{ds_sorted[-1]:.2f} |")

    md = "\n".join(summary)
    MD_PATH.write_text(md, encoding="utf-8")
    print(md)
    print(f"\n-> CSV: {CSV_PATH}")
    print(f"-> Summary: {MD_PATH}")

if __name__ == "__main__":
    main()
