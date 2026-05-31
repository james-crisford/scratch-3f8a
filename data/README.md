# PuttingLab — Stroke Database

Local SQLite analytical store + raw stroke JSON archive.

## Layout

```
data/
├── README.md             (this file)
├── strokes.db            (SQLite index — queryable analytical store)
└── raw/
    └── by-build/
        ├── 0.1.3-7/      (Build 7 strokes — pre-judgment-buttons)
        ├── 0.1.8-12/     (Build 12 — first session with light/heavy haptics)
        ├── 0.1.9-13/     (Build 13 — fast-fire + haptic distinction)
        └── ...           (each new build gets a folder)
```

The Drive folder `G:\Shared drives\3D Printing Express\Yell\New Swings\` remains the durable backup — uploads land there as zips, then `tools/ingest_strokes.py` unpacks them into the appropriate `by-build/<version>/` folder before populating the DB.

## Workflow

After every TestFlight session export:

1. Drop the new zip from the iPhone into `Yell/New Swings/` on Drive.
2. Locally, extract it into `data/raw/by-build/<short-version>-<build-no>/` (e.g. `0.2.0-15/`).
3. Run `python tools/ingest_strokes.py --summary`. The script is idempotent — already-ingested files are skipped via the `file_path` primary key.
4. Query whatever you want via `python tools/query_strokes.py <command>` or raw SQL.

## Schema (one row per stroke)

| Column | Notes |
|---|---|
| `file_path` (PK) | `data/raw/by-build/.../stroke-XXX.json` — canonical local path |
| `captured_at` | ISO8601 from the iPhone clock |
| `captured_date` | YYYY-MM-DD (for grouping into sessions) |
| `app_version` | `"0.1.9 (13)"` |
| `build_number` | Parsed from app_version |
| `short_version` | `"0.1.9"` |
| `device_model` | e.g. `iPhone14,3` |
| `session_id` | `date::device::build` — for cal-baseline scoping |
| `stroke_class` | `'putting'` / `'full_length'` / `'chip'` / `'pitch'` — **always 'putting'** today since the iPhone-only PuttingLab app only emits putts. The schema is ready for future full-swing data without migration. |
| `batch_id` | `'cal'`, `'A'`, `'B'`, …, `'H'` (from TestBatch) |
| `batch_stroke_idx` | 1-indexed within batch |
| `batch_type` | Human label, e.g. `'Deliberate PULL stroke'` |
| `judgment` | `'just_right'` / `'early'` / `'late'` / `NULL` |
| `snapped` | 0/1 (algorithm fell back to Square) |
| `snap_reason` | `'strokeTooShort'`, `'peakSpeedTooLow'`, ... |
| `peak_velocity` | m/s — algorithm's peak forward hand velocity |
| `face_angle_raw_rad` / `_deg` | Raw face angle out of the algorithm |
| `confidence` | 0-1 |
| `n_samples`, `duration_ms` | Stroke window size |
| `rotation_max`, `accel_max` | Peaks over the stroke window |
| `impact_t_ms` | Algorithm's chosen impact moment, ms from window start |
| `window_start_ts`, `window_end_ts` | CoreMotion-uptime timestamps |
| `ingested_at` | When this row was added |

### Views

`v_session_cal_baseline` — per-session cal-batch mean face angle (the calibration baseline).

`v_strokes` — every stroke joined to its session's cal mean, with a derived `face_angle_cal_deg` column = `face_angle_raw_deg − session_cal_mean`. Falls back to raw if the session has no cal batch yet.

**Use `v_strokes` for face-angle analysis**, not the raw `face_angle_raw_deg`, otherwise James's natural −6.6° grip bias contaminates every result.

## Common queries

```bash
# Per-batch summary for build 13 with both raw + calibrated face angle
python tools/query_strokes.py face --build 13

# Judgment distribution across all builds
python tools/query_strokes.py judgments

# Sessions + their cal baselines
python tools/query_strokes.py sessions

# Raw SQL passthrough
python tools/query_strokes.py raw "SELECT batch_id, AVG(face_angle_cal_deg) FROM v_strokes WHERE build_number = 13 GROUP BY batch_id"
```

## Backup

- The `data/strokes.db` file is small (~MB scale even at 10k strokes) and lives in git.
- Raw JSONs in `data/raw/by-build/` are also git-tracked — durable + diff-able across builds.
- Drive folder `Yell/New Swings/` is the long-term archive; even if the local repo is lost the DB can be rebuilt from those zips by re-running `ingest_strokes.py`.

## Future

- `stroke_class` column is ready for full-swing data when the app gains driver/iron support.
- A second analytical column could record the LiveImpactDetector output (live-haptic fire times) — currently those aren't in the JSON because the detector runs on the iPhone in real time and doesn't save its decisions. Adding it requires a small app change.
- A `cal_offset_deg` column on `strokes` could persist the calibration subtraction so we don't recompute it via view-join on every query. Not needed yet at this scale.
