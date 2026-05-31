"""Walk data/raw/by-build/* and ingest every StrokeReplay JSON into
data/strokes.db (SQLite analytical index).

Idempotent: skips files already in DB by `file_path`. Adds session_id and
computes a session-scoped calibration baseline so we can show
`face_angle_cal_deg = raw - cal_mean(same session)`.

Run after every new export. No arguments needed; the script discovers
the data layout from `data/raw/by-build/<version>/<file>.json`.

Schema includes `stroke_class` ('putting' / 'full_length' / 'chip' /
'pitch') from day one so future full-swing data slots in cleanly. For
now the iPhone-only PuttingLab app only emits 'putting' strokes.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import sqlite3
import sys
from pathlib import Path
from typing import Iterator

# ---------------------------------------------------------------------------
# Paths

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw" / "by-build"
DB_PATH = ROOT / "data" / "strokes.db"

# ---------------------------------------------------------------------------
# Schema

SCHEMA = """
CREATE TABLE IF NOT EXISTS strokes (
    file_path           TEXT PRIMARY KEY,
    captured_at         TEXT NOT NULL,
    captured_date       TEXT NOT NULL,         -- YYYY-MM-DD (for grouping)
    app_version         TEXT,                  -- "0.1.9 (13)"
    build_number        INTEGER,
    short_version       TEXT,                  -- "0.1.9"
    device_model        TEXT,
    session_id          TEXT NOT NULL,         -- date + device — for cal scoping
    stroke_class        TEXT NOT NULL DEFAULT 'putting',  -- putting/full_length/chip/pitch
    batch_id            TEXT,
    batch_stroke_idx    INTEGER,
    batch_type          TEXT,
    judgment            TEXT,                  -- just_right / early / late / NULL
    snapped             INTEGER NOT NULL,
    snap_reason         TEXT,
    peak_velocity       REAL,
    face_angle_raw_rad  REAL,
    face_angle_raw_deg  REAL,
    confidence          REAL,
    n_samples           INTEGER,
    duration_ms         REAL,
    rotation_max        REAL,                  -- max |omega| over stroke
    accel_max           REAL,                  -- max |userAcceleration|
    impact_t_ms         REAL,                  -- algo impact ms from window start
    -- raw-window bookkeeping
    window_start_ts     REAL,
    window_end_ts       REAL,
    ingested_at         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_build_batch ON strokes(build_number, batch_id);
CREATE INDEX IF NOT EXISTS idx_session ON strokes(session_id);
CREATE INDEX IF NOT EXISTS idx_judgment ON strokes(judgment);
CREATE INDEX IF NOT EXISTS idx_stroke_class ON strokes(stroke_class);

CREATE VIEW IF NOT EXISTS v_session_cal_baseline AS
    SELECT session_id,
           AVG(face_angle_raw_deg) AS cal_mean_deg,
           COUNT(*)                AS n_cal
    FROM strokes
    WHERE batch_id = 'cal' AND snapped = 0 AND stroke_class = 'putting'
    GROUP BY session_id;

-- Convenience view: every stroke with face_angle_cal_deg back-computed
-- against its session's cal baseline. Falls back to raw if the session
-- has no cal strokes recorded yet.
CREATE VIEW IF NOT EXISTS v_strokes AS
    SELECT s.*,
           COALESCE(s.face_angle_raw_deg - b.cal_mean_deg,
                    s.face_angle_raw_deg) AS face_angle_cal_deg,
           b.cal_mean_deg                  AS session_cal_mean_deg,
           b.n_cal                         AS session_n_cal
    FROM strokes s
    LEFT JOIN v_session_cal_baseline b USING (session_id);
"""

# ---------------------------------------------------------------------------
# JSON parsing helpers

def vec_mag(v) -> float:
    """Tolerant magnitude for a 3-element list or {x,y,z} dict."""
    if v is None:
        return float("nan")
    if isinstance(v, dict):
        return math.sqrt(v["x"] ** 2 + v["y"] ** 2 + v["z"] ** 2)
    return math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)


def parse_iso8601(s: str) -> dt.datetime | None:
    if not s:
        return None
    try:
        # Strip trailing Z if present, parse as UTC
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return dt.datetime.fromisoformat(s)
    except ValueError:
        return None


def extract_features(j: dict) -> dict:
    """Pull everything we want to index from a single StrokeReplay JSON."""
    samples = j.get("samples", []) or []
    result = j.get("result") or {}
    app_version = j.get("appVersion") or ""
    captured_at_iso = j.get("capturedAt") or ""
    captured_at = parse_iso8601(captured_at_iso)

    build_no = None
    short_v = None
    if app_version:
        # Format: "0.1.9 (13)"
        try:
            short_v = app_version.split(" ")[0]
            build_no = int(app_version.split("(")[1].rstrip(")"))
        except (IndexError, ValueError):
            pass

    rot_max = 0.0
    accel_max = 0.0
    for s in samples:
        rm = vec_mag(s.get("rotationRate"))
        am = vec_mag(s.get("userAcceleration"))
        if rm == rm and rm > rot_max: rot_max = rm
        if am == am and am > accel_max: accel_max = am

    duration_ms = None
    if len(samples) >= 2 and samples[0].get("timestamp") is not None and samples[-1].get("timestamp") is not None:
        duration_ms = (samples[-1]["timestamp"] - samples[0]["timestamp"]) * 1000

    impact_t_ms = None
    if result.get("timestamp") is not None and samples and samples[0].get("timestamp") is not None:
        impact_t_ms = (result["timestamp"] - samples[0]["timestamp"]) * 1000

    face_raw_rad = result.get("faceAngleRaw")
    face_raw_deg = math.degrees(face_raw_rad) if face_raw_rad is not None else None

    return {
        "captured_at": captured_at_iso,
        "captured_date": captured_at.date().isoformat() if captured_at else "",
        "app_version": app_version,
        "build_number": build_no,
        "short_version": short_v,
        "device_model": j.get("deviceModel") or "",
        "stroke_class": "putting",  # iPhone-only PuttingLab app emits only putting strokes
        "batch_id": j.get("batchId"),
        "batch_stroke_idx": j.get("batchStrokeIndex"),
        "batch_type": j.get("batchStrokeType"),
        "judgment": j.get("userImpactJudgment"),
        "snapped": 1 if result.get("snappedToSquare") else 0,
        "snap_reason": result.get("snapReason"),
        "peak_velocity": result.get("peakVelocity"),
        "face_angle_raw_rad": face_raw_rad,
        "face_angle_raw_deg": face_raw_deg,
        "confidence": result.get("confidence"),
        "n_samples": len(samples),
        "duration_ms": duration_ms,
        "rotation_max": rot_max if rot_max else None,
        "accel_max": accel_max if accel_max else None,
        "impact_t_ms": impact_t_ms,
        "window_start_ts": j.get("windowStart"),
        "window_end_ts": j.get("windowEnd"),
    }


def session_id_for(features: dict) -> str:
    """Group strokes into a session for cal-baseline scoping.

    A session = same captured_date + same device + same build. If James does
    two distinct calibration batches on the same day (e.g. after the lunch
    break and a re-install), they share a session_id — which is the common
    case and what we want for calibration.
    """
    return f"{features['captured_date']}::{features['device_model']}::{features['build_number']}"


# ---------------------------------------------------------------------------
# Ingestion

def iter_raw_files() -> Iterator[Path]:
    for build_dir in sorted(RAW.iterdir()):
        if not build_dir.is_dir():
            continue
        for jf in sorted(build_dir.glob("*.json")):
            yield jf


def ingest(conn: sqlite3.Connection, force: bool = False) -> tuple[int, int]:
    """Returns (n_inserted, n_skipped)."""
    cur = conn.cursor()
    cur.executescript(SCHEMA)
    inserted = 0
    skipped = 0
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")

    for fp in iter_raw_files():
        rel = str(fp.relative_to(ROOT))
        if not force:
            cur.execute("SELECT 1 FROM strokes WHERE file_path = ?", (rel,))
            if cur.fetchone():
                skipped += 1
                continue
        try:
            j = json.loads(fp.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"[skip] {rel}: bad JSON — {e}", file=sys.stderr)
            continue

        feats = extract_features(j)
        sid = session_id_for(feats)

        cur.execute(
            """INSERT OR REPLACE INTO strokes (
                file_path, captured_at, captured_date, app_version, build_number,
                short_version, device_model, session_id, stroke_class,
                batch_id, batch_stroke_idx, batch_type, judgment,
                snapped, snap_reason, peak_velocity,
                face_angle_raw_rad, face_angle_raw_deg, confidence,
                n_samples, duration_ms, rotation_max, accel_max, impact_t_ms,
                window_start_ts, window_end_ts, ingested_at
            ) VALUES (?,?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?,?, ?,?,?, ?,?,?,?,?, ?,?,?)""",
            (
                rel, feats["captured_at"], feats["captured_date"],
                feats["app_version"], feats["build_number"], feats["short_version"],
                feats["device_model"], sid, feats["stroke_class"],
                feats["batch_id"], feats["batch_stroke_idx"], feats["batch_type"],
                feats["judgment"],
                feats["snapped"], feats["snap_reason"], feats["peak_velocity"],
                feats["face_angle_raw_rad"], feats["face_angle_raw_deg"], feats["confidence"],
                feats["n_samples"], feats["duration_ms"],
                feats["rotation_max"], feats["accel_max"], feats["impact_t_ms"],
                feats["window_start_ts"], feats["window_end_ts"], now,
            ),
        )
        inserted += 1

    conn.commit()
    return inserted, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true",
                        help="Re-ingest every file even if already in DB.")
    parser.add_argument("--summary", action="store_true",
                        help="After ingestion, print a one-screen summary.")
    args = parser.parse_args()

    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        inserted, skipped = ingest(conn, force=args.force)
        print(f"[ingest] inserted={inserted}  skipped(already in DB)={skipped}")
        print(f"[ingest] DB: {DB_PATH}")

        if args.summary or inserted > 0:
            print()
            print("=== Summary by build ===")
            for row in conn.execute(
                """SELECT short_version || ' (' || build_number || ')' AS v,
                          COUNT(*) AS n,
                          SUM(snapped) AS n_snapped,
                          ROUND(AVG(peak_velocity), 3) AS avg_peak,
                          ROUND(AVG(face_angle_raw_deg), 2) AS avg_face_raw_deg
                   FROM strokes
                   GROUP BY build_number ORDER BY build_number"""
            ):
                print(f"  {row[0]:<12}  n={row[1]:>3}  snapped={row[2]}  "
                      f"avg_peak={row[3]:>5} m/s  avg_face_raw={row[4]:>+7}°")

            print()
            print("=== Judgment distribution ===")
            for row in conn.execute(
                """SELECT short_version || ' (' || build_number || ')' AS v,
                          COALESCE(judgment, '(none)') AS j, COUNT(*) AS n
                   FROM strokes
                   GROUP BY build_number, judgment
                   ORDER BY build_number, j"""
            ):
                print(f"  {row[0]:<12}  {row[1]:<11}  n={row[2]}")

            print()
            print("=== Cal baselines per session ===")
            for row in conn.execute(
                "SELECT session_id, n_cal, ROUND(cal_mean_deg, 2) FROM v_session_cal_baseline"
            ):
                print(f"  {row[0]}  n_cal={row[1]}  cal_mean_deg={row[2]}")


if __name__ == "__main__":
    main()
