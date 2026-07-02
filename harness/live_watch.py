"""Live session watcher — polls the Google Drive drop folder, ingests new
stroke files (loose JSON or export zips), runs them through the real
compiled pipeline (plab in Docker), and regenerates the dashboard's
data.json. Run from the PuttingLab repo root:

    python harness/live_watch.py [--target-ft 8] [--cup-m 2.44]

Serve the dashboard separately:
    python -m http.server 8787 --directory harness/dashboard
"""
import argparse
import csv
import io
import json
import re
import shutil
import subprocess
import time
import zipfile
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DRIVE = Path(r"G:\Shared drives\3D Printing Express\Yell\New Swings")
LIVE = REPO / "data" / "raw" / "by-build" / "live-2026-07-02"
DASH = REPO / "harness" / "dashboard"
STATE = DASH / "watch_state.json"

DOCKER = [
    "docker", "run", "--rm",
    "-v", str(REPO) + ":/src", "-w", "/src", "swift:6.1",
]


def plab(*args):
    out = subprocess.run(DOCKER + [".build/debug/plab", *args],
                         capture_output=True, text=True, timeout=300)
    return out.stdout


def load_state():
    if STATE.exists():
        return json.loads(STATE.read_text())
    return {"processed": [], "cal_factor": None, "session_start": time.time()}


def save_state(s):
    STATE.write_text(json.dumps(s, indent=1))


def ingest_new(state):
    """Copy new stroke JSONs (and unzip export zips) into LIVE. Returns count."""
    LIVE.mkdir(parents=True, exist_ok=True)
    new = 0
    if not DRIVE.exists():
        return 0
    for f in sorted(DRIVE.iterdir()):
        if f.name in state["processed"]:
            continue
        if f.stat().st_mtime < state["session_start"] - 60:
            state["processed"].append(f.name)  # pre-session artefact, skip
            continue
        try:
            if f.suffix.lower() == ".json" and f.name.startswith("stroke-"):
                shutil.copy2(f, LIVE / f.name)
                new += 1
            elif f.suffix.lower() == ".zip":
                with zipfile.ZipFile(f) as z:
                    for n in z.namelist():
                        base = Path(n).name
                        if base.startswith("stroke-") and base.endswith(".json") \
                                and not (LIVE / base).exists():
                            (LIVE / base).write_bytes(z.read(n))
                            new += 1
            state["processed"].append(f.name)
        except Exception as e:  # transient Drive sync locks — retry next tick
            print(f"[watch] retry {f.name}: {e}")
    return new


def compute_cal_factor(state, target_ft):
    cal_files = sorted(LIVE.glob("stroke-cal*.json"))
    if len(cal_files) < 3:
        return state.get("cal_factor")
    out = plab("calfactor", *[f"data/raw/by-build/live-2026-07-02/{f.name}" for f in cal_files],
               "--target-ft", str(target_ft))
    try:
        j = json.loads(out.strip().splitlines()[-1])
        if "factor" in j:
            state["cal_factor"] = j["factor"]
            print(f"[watch] TRUE cal factor from {j['strokes']} strokes "
                  f"(mean peak {j['mean_peak']:.4f}): {j['factor']:.3f}")
    except (json.JSONDecodeError, IndexError):
        print("[watch] calfactor parse failed:", out[-200:])
    return state.get("cal_factor")


TIME_RE = re.compile(r"stroke-(?:[A-Za-z0-9]+-\d+-)?(.+?)\.json$")


def regenerate(cal_factor, cup_m):
    args = ["replay", "data/raw/by-build/live-2026-07-02"]
    if cal_factor:
        args += ["--cal", str(cal_factor), "--cup", str(cup_m)]
    out = plab(*args)
    rows = []
    reader = csv.DictReader(io.StringIO(out))
    for r in reader:
        name = r.get("file", "")
        m = TIME_RE.match(name)
        stamp = m.group(1).replace("T", " ").split(".")[0] if m else ""
        batch = ""
        parts = name.split("-")
        if len(parts) > 2 and not parts[1][0].isdigit():
            batch = parts[1] + "-" + parts[2]
        rows.append({
            "file": name,
            "time": stamp[-8:].replace("-", ":"),
            "batch": batch,
            "judgment": r.get("judgment", "-"),
            "peak": r.get("replayed_peak", ""),
            "face_deg": r.get("replayed_face_deg_HEADPIPELINE", ""),
            "snapped": r.get("replayed_snap", ""),
            "conf": r.get("replayed_conf", ""),
            "sim_outcome": r.get("sim_outcome", ""),
            "sim_roll": r.get("sim_roll_m", ""),
            "sim_lateral": r.get("sim_lateral", ""),
        })
    rows.sort(key=lambda x: x["file"])
    now = datetime.now()
    (DASH / "data.json").write_text(json.dumps({
        "rows": rows,
        "cal_factor": cal_factor,
        "cup_m": cup_m,
        "updated": now.strftime("%H:%M:%S"),
        "updated_epoch": now.timestamp(),
    }, indent=1))
    print(f"[watch] dashboard updated: {len(rows)} strokes, factor={cal_factor}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-ft", type=float, default=8.0)
    ap.add_argument("--cup-m", type=float, default=2.44)
    ap.add_argument("--interval", type=float, default=10.0)
    args = ap.parse_args()

    state = load_state()
    print(f"[watch] session start {datetime.fromtimestamp(state['session_start'])}, "
          f"watching {DRIVE}")
    regenerate(state.get("cal_factor"), args.cup_m)
    while True:
        try:
            new = ingest_new(state)
            if new:
                print(f"[watch] {new} new stroke file(s)")
                cal = compute_cal_factor(state, args.target_ft)
                regenerate(cal, args.cup_m)
                save_state(state)
            else:
                save_state(state)
        except Exception as e:
            print("[watch] tick error:", e)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
