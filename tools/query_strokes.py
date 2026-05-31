"""Common analytical queries against data/strokes.db.

Examples:
    python tools/query_strokes.py per-batch --build 13
    python tools/query_strokes.py judgments --build 13
    python tools/query_strokes.py timing --build 13
    python tools/query_strokes.py face --build 13          # calibrated face per batch
    python tools/query_strokes.py raw "SELECT short_version, COUNT(*) FROM strokes GROUP BY short_version"
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

DB = Path(__file__).resolve().parent.parent / "data" / "strokes.db"


def fmt_row(cols: list[str], row: tuple, widths: list[int]) -> str:
    return "  ".join(f"{str(v):>{w}}" if i > 0 else f"{str(v):<{w}}"
                     for i, (v, w) in enumerate(zip(row, widths)))


def print_table(cur: sqlite3.Cursor):
    rows = cur.fetchall()
    if not rows:
        print("(no rows)")
        return
    cols = [d[0] for d in cur.description]
    widths = [max(len(str(c)), max(len(str(r[i])) for r in rows)) for i, c in enumerate(cols)]
    print(fmt_row(cols, tuple(cols), widths))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        # Round floats for display
        r = tuple(round(v, 3) if isinstance(v, float) else v for v in r)
        print(fmt_row(cols, r, widths))


def q_per_batch(conn, build: int | None):
    where = f"WHERE build_number = {build}" if build else ""
    print_table(conn.execute(f"""
        SELECT batch_id, COUNT(*) AS n, SUM(snapped) AS snapped,
               ROUND(AVG(peak_velocity), 3) AS avg_peak,
               ROUND(AVG(face_angle_raw_deg), 2) AS avg_face_raw_deg,
               ROUND(AVG(face_angle_cal_deg), 2) AS avg_face_cal_deg,
               ROUND(AVG(duration_ms), 0) AS avg_dur_ms,
               ROUND(AVG(rotation_max), 2) AS avg_rot_max
        FROM v_strokes
        {where}
        GROUP BY batch_id
        ORDER BY CASE batch_id
            WHEN 'cal' THEN 0 WHEN 'A' THEN 1 WHEN 'B' THEN 2 WHEN 'C' THEN 3
            WHEN 'D' THEN 4 WHEN 'E' THEN 5 WHEN 'F' THEN 6
            WHEN 'G' THEN 7 WHEN 'H' THEN 8 ELSE 9 END
    """))


def q_judgments(conn, build: int | None):
    where = f"WHERE build_number = {build}" if build else ""
    print_table(conn.execute(f"""
        SELECT COALESCE(judgment, '(none)') AS judgment, COUNT(*) AS n,
               ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
        FROM strokes
        {where}
        GROUP BY judgment
        ORDER BY n DESC
    """))


def q_timing(conn, build: int | None):
    where = f"WHERE build_number = {build}" if build else ""
    print_table(conn.execute(f"""
        SELECT batch_id,
               COUNT(*) AS n,
               ROUND(AVG(impact_t_ms), 0) AS avg_impact_ms,
               ROUND(MIN(impact_t_ms), 0) AS min_ms,
               ROUND(MAX(impact_t_ms), 0) AS max_ms,
               ROUND(AVG(duration_ms), 0) AS avg_dur_ms,
               ROUND(AVG(rotation_max), 2) AS avg_rot_max
        FROM strokes
        {where}
        GROUP BY batch_id
        ORDER BY batch_id
    """))


def q_face(conn, build: int | None):
    where = f"WHERE build_number = {build}" if build else ""
    print_table(conn.execute(f"""
        SELECT batch_id, batch_type, COUNT(*) AS n,
               ROUND(AVG(face_angle_raw_deg), 2) AS face_raw_deg,
               ROUND(AVG(face_angle_cal_deg), 2) AS face_cal_deg,
               ROUND(MIN(face_angle_cal_deg), 2) AS min_cal,
               ROUND(MAX(face_angle_cal_deg), 2) AS max_cal
        FROM v_strokes
        {where}
        AND snapped = 0
        GROUP BY batch_id, batch_type
        ORDER BY batch_id
    """))


def q_sessions(conn):
    print_table(conn.execute("""
        SELECT s.session_id, COUNT(*) AS n_total,
               SUM(CASE WHEN batch_id = 'cal' THEN 1 ELSE 0 END) AS n_cal,
               b.cal_mean_deg,
               s.short_version,
               s.captured_date
        FROM strokes s
        LEFT JOIN v_session_cal_baseline b USING (session_id)
        GROUP BY s.session_id
        ORDER BY s.captured_date DESC
    """))


def q_raw(conn, sql: str):
    print_table(conn.execute(sql))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("per-batch", help="Per-batch stats")
    p.add_argument("--build", type=int)

    p = sub.add_parser("judgments", help="Judgment distribution")
    p.add_argument("--build", type=int)

    p = sub.add_parser("timing", help="Per-batch timing")
    p.add_argument("--build", type=int)

    p = sub.add_parser("face", help="Per-batch face angle (raw + calibrated)")
    p.add_argument("--build", type=int)

    sub.add_parser("sessions", help="Sessions with cal baseline")

    p = sub.add_parser("raw", help="Raw SQL")
    p.add_argument("sql")

    args = parser.parse_args()

    if not DB.exists():
        print(f"DB not found at {DB}. Run `python tools/ingest_strokes.py` first.", file=sys.stderr)
        sys.exit(1)

    with sqlite3.connect(DB) as conn:
        if args.cmd == "per-batch":
            q_per_batch(conn, args.build)
        elif args.cmd == "judgments":
            q_judgments(conn, args.build)
        elif args.cmd == "timing":
            q_timing(conn, args.build)
        elif args.cmd == "face":
            q_face(conn, args.build)
        elif args.cmd == "sessions":
            q_sessions(conn)
        elif args.cmd == "raw":
            q_raw(conn, args.sql)


if __name__ == "__main__":
    main()
