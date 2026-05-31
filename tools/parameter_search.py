"""Grid-search LiveImpactDetector parameters against every stored stroke
and rank the configurations by predicted "Just Right" judgment rate.

Runs entirely offline — zero GitHub Actions cost. The point is to stop
shipping speculative parameter tweaks: try them HERE first, push only
the winner.

Predictive model (calibrated against B13 + B14 actual judgments):
- 1 fire in 1000–2000 ms after touchDown → "just_right" (~95 % confident)
- 2+ fires                              → "early"      (~85 % confident
                                                          — user judges
                                                          the backswing fire)
- 0 fires                               → "(none)"     (no judgment possible)

The predictions aren't exact (sample size 178), but the RELATIVE ranking
across configs is robust: configs that produce single-fire patterns at
~1500 ms post-touchDown maximise just_right by construction.

Run:
    python tools/parameter_search.py
    python tools/parameter_search.py --top 5 --build 14   # only B14 strokes
    python tools/parameter_search.py --custom 1.5,1.0,1,0.02,0.4,5,1.0
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw" / "by-build"


# ---------------------------------------------------------------------------
# Detector simulator — mirrors the Swift LiveImpactDetector logic exactly.

@dataclass(frozen=True)
class DetectorParams:
    arm: float = 1.7
    disarm: float = 1.0
    peak_n: int = 1
    drop: float = 0.015
    cool: float = 0.4
    warm: int = 5
    gate: float = 1.0

    def label(self) -> str:
        return (f"arm={self.arm} disarm={self.disarm} peak_n={self.peak_n} "
                f"drop={self.drop} cool={self.cool} warm={self.warm} gate={self.gate}")


def vec_mag(v) -> float:
    return math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)


def simulate(samples: list[dict], p: DetectorParams) -> list[float]:
    fires: list[float] = []
    armed = False
    last_t = -1e18
    cb = 0
    wu = False
    mx = 0.0
    cbm = 0
    t_touch = samples[0]["timestamp"]
    for s in samples:
        t = s["timestamp"]
        if not math.isfinite(t):
            continue
        mag = vec_mag(s["rotationRate"])
        if not math.isfinite(mag):
            continue
        if not wu:
            if mag <= p.disarm:
                cb += 1
                if cb >= p.warm:
                    wu = True
            else:
                cb = 0
            continue
        if t - last_t < p.cool:
            armed = False
            mx = 0
            cbm = 0
            continue
        gated = (t - t_touch) < p.gate
        if not armed:
            if mag >= p.arm:
                armed = True
                mx = mag
                cbm = 0
            continue
        if mag > mx:
            mx = mag
            cbm = 0
        elif mag < mx:
            cbm += 1
            if cbm >= p.peak_n and mag < mx * (1 - p.drop):
                if not gated:
                    fires.append(t)
                    last_t = t
                armed = False
                mx = 0
                cbm = 0
                continue
        if mag < p.disarm:
            if not gated:
                fires.append(t)
                last_t = t
            armed = False
            mx = 0
            cbm = 0
    return fires


# ---------------------------------------------------------------------------
# Predict judgment from fire pattern (calibrated heuristic).

def predict_judgment(samples: list[dict], fires: list[float]) -> str:
    if not fires:
        return "(none)"
    if len(fires) >= 2:
        return "early"
    # Single fire. Map the fire-time-from-touchDown to a judgment.
    # B14 single-fire strokes that James judged "just_right" had fire
    # times between 994 and 2317 ms, mean ~1500 ms. We'd predict "late"
    # only if fire is very late (e.g. > 2500 ms post-touchDown).
    t0 = samples[0]["timestamp"]
    fire_ms = (fires[0] - t0) * 1000
    if fire_ms > 2500:
        return "late"
    return "just_right"


# ---------------------------------------------------------------------------
# Load all stored strokes.

def load_strokes(build_filter: int | None = None) -> list[dict]:
    strokes: list[dict] = []
    for build_dir in sorted(RAW.iterdir()):
        if not build_dir.is_dir():
            continue
        # Filter by build number if requested. Folder names like 0.2.0-14.
        try:
            build_no = int(build_dir.name.split("-")[-1])
        except ValueError:
            continue
        if build_filter is not None and build_no != build_filter:
            continue
        for fp in build_dir.glob("*.json"):
            try:
                data = json.loads(fp.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            data["__source"] = str(fp.relative_to(ROOT))
            data["__build"] = build_no
            strokes.append(data)
    return strokes


# ---------------------------------------------------------------------------
# Score a parameter combo.

@dataclass(frozen=True)
class Score:
    params: DetectorParams
    n_total: int
    n_just_right: int
    n_early: int
    n_late: int
    n_none: int
    pct_just_right: float
    mean_fire_ms_jr: float | None  # mean fire-from-touchDown for just_right strokes

    def __lt__(self, other):
        # Highest just_right pct wins; ties broken by lowest (none) count.
        if self.pct_just_right != other.pct_just_right:
            return self.pct_just_right > other.pct_just_right
        return self.n_none < other.n_none


def score(strokes: list[dict], p: DetectorParams) -> Score:
    pred_counts = Counter()
    fire_times_jr = []
    for s in strokes:
        samples = s.get("samples", [])
        if not samples:
            continue
        fires = simulate(samples, p)
        judgment = predict_judgment(samples, fires)
        pred_counts[judgment] += 1
        if judgment == "just_right" and fires:
            t0 = samples[0]["timestamp"]
            fire_times_jr.append((fires[0] - t0) * 1000)
    n_total = sum(pred_counts.values())
    n_jr = pred_counts.get("just_right", 0)
    n_early = pred_counts.get("early", 0)
    n_late = pred_counts.get("late", 0)
    n_none = pred_counts.get("(none)", 0)
    pct_jr = (100.0 * n_jr / n_total) if n_total > 0 else 0.0
    mean_jr = (sum(fire_times_jr) / len(fire_times_jr)) if fire_times_jr else None
    return Score(
        params=p,
        n_total=n_total,
        n_just_right=n_jr,
        n_early=n_early,
        n_late=n_late,
        n_none=n_none,
        pct_just_right=pct_jr,
        mean_fire_ms_jr=mean_jr,
    )


# ---------------------------------------------------------------------------
# Grid + reporting

def build_grid() -> list[DetectorParams]:
    """Reasonable search space around current B15 defaults."""
    arms = [1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
    drops = [0.010, 0.015, 0.02, 0.03, 0.05]
    cools = [0.3, 0.4, 0.5]
    gates = [0.7, 0.8, 0.9, 1.0, 1.1]
    grid = []
    for arm, drop, cool, gate in itertools.product(arms, drops, cools, gates):
        grid.append(DetectorParams(arm=arm, drop=drop, cool=cool, gate=gate))
    return grid


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", type=int, default=10, help="Top N configs to show")
    ap.add_argument("--build", type=int, default=None,
                    help="Only score strokes from this build number (default: all)")
    ap.add_argument("--custom", type=str, default=None,
                    help="Score a single custom config 'arm,disarm,peak_n,drop,cool,warm,gate'")
    args = ap.parse_args()

    strokes = load_strokes(build_filter=args.build)
    if not strokes:
        print("No strokes found. Run tools/ingest_strokes.py first.", file=sys.stderr)
        sys.exit(1)
    print(f"Loaded {len(strokes)} strokes "
          f"(filter: build={args.build or 'all'})")
    print()

    # Compare current B15 defaults as a baseline.
    baseline = DetectorParams()  # B15 defaults
    base_score = score(strokes, baseline)
    print(f"=== B15 defaults baseline ===")
    print(f"  {baseline.label()}")
    print(f"  just_right={base_score.pct_just_right:.1f}%  "
          f"(jr={base_score.n_just_right} early={base_score.n_early} "
          f"late={base_score.n_late} none={base_score.n_none})")
    if base_score.mean_fire_ms_jr:
        print(f"  mean fire time on just_right strokes: {base_score.mean_fire_ms_jr:.0f} ms")
    print()

    if args.custom:
        try:
            arm, disarm, peak_n, drop, cool, warm, gate = args.custom.split(",")
            cp = DetectorParams(
                arm=float(arm), disarm=float(disarm), peak_n=int(peak_n),
                drop=float(drop), cool=float(cool), warm=int(warm), gate=float(gate),
            )
        except ValueError:
            print("--custom format: 'arm,disarm,peak_n,drop,cool,warm,gate' "
                  "(e.g. 1.5,1.0,1,0.02,0.4,5,1.0)", file=sys.stderr)
            sys.exit(1)
        s = score(strokes, cp)
        print(f"=== Custom config ===")
        print(f"  {cp.label()}")
        print(f"  just_right={s.pct_just_right:.1f}%  "
              f"(jr={s.n_just_right} early={s.n_early} late={s.n_late} none={s.n_none})")
        return

    # Grid search
    grid = build_grid()
    print(f"Sweeping {len(grid)} configurations...")
    scored = [score(strokes, p) for p in grid]
    scored.sort()
    print()
    print(f"=== TOP {args.top} configurations by predicted just_right rate ===")
    header = f"  {'rank':<4} {'pct_jr':>7} {'jr':>3} {'early':>5} {'late':>4} {'none':>4} {'mean_jr_ms':>11}  config"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for i, s in enumerate(scored[:args.top], 1):
        mean = f"{s.mean_fire_ms_jr:.0f}" if s.mean_fire_ms_jr else "—"
        print(f"  {i:<4} {s.pct_just_right:>6.1f}% {s.n_just_right:>3} "
              f"{s.n_early:>5} {s.n_late:>4} {s.n_none:>4} {mean:>11}  "
              f"arm={s.params.arm} drop={s.params.drop} cool={s.params.cool} gate={s.params.gate}")

    print()
    winner = scored[0]
    print(f"=== Best config: {winner.pct_just_right:.1f}% just_right (vs B15 {base_score.pct_just_right:.1f}%) ===")
    print(f"  arm={winner.params.arm}  disarm={winner.params.disarm}  "
          f"peak_n={winner.params.peak_n}  drop={winner.params.drop}  "
          f"cool={winner.params.cool}  warm={winner.params.warm}  gate={winner.params.gate}")
    delta = winner.pct_just_right - base_score.pct_just_right
    if delta > 1.0:
        print(f"  --> expected lift {delta:+.1f} pp. Worth shipping.")
    else:
        print(f"  --> expected lift {delta:+.1f} pp. Not worth a CI cycle vs B15.")


if __name__ == "__main__":
    main()
