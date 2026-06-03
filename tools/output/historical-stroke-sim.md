# Historical stroke simulation — B55 BallPhysics replay

**Replayed 284 strokes** from `data/raw/by-build/` + `.tmp/b1[23]-strokes/` through `BallPhysics.simulatePutt` with the v0.2.2-era defaults (stimpFeet=10, cupPosition=(2,0), speedCalibration=1.0).

## Outcomes

- **stopped**: 277 (97.5%)
- **lipOut**: 4 (1.4%)
- **captured**: 3 (1.1%)

## Distance distribution

- <0.5m: 5 (1.8%)
- 0.5-1.0m: 5 (1.8%)
- 1.0-2.0m: 61 (21.5%)
- 2.0-3.0m: 81 (28.5%)
- 3.0-5.0m: 88 (31.0%)
- 5.0m+: 44 (15.5%)

## Statistics

- Peak velocity (m/s): n=284, min=0.000, p10=0.104, median=0.147, mean=0.151, p90=0.204, max=0.339
- Face angle (deg): n=284, min=-34.828, p10=-19.608, median=-6.695, mean=-6.588, p90=5.699, max=33.780
- Computed distance (m): n=284, min=0.000, p10=1.439, median=2.795, mean=3.290, p90=5.520, max=15.243

## Face-angle bucket x outcome (push/pull strokes should miss)

| Bucket | n | captured | lipOut | stopped | median lat. offset |
|---|---|---|---|---|---|
| Square | 89 | 3 | 4 | 82 | +0.161m |
| Slight pull | 127 | 0 | 0 | 127 | +0.363m |
| Slight push | 11 | 0 | 0 | 11 | -0.360m |
| Pull | 13 | 0 | 0 | 13 | +1.537m |
| Push | 11 | 0 | 0 | 11 | -0.738m |
| Miss | 33 | 0 | 0 | 33 | +1.270m |

**Cup radius = 0.054m. Captures should only come from |face| < ~2deg (at 2m cup distance, lateral offset = 2 * sin(face_angle)). Bucket 'Square' covers up to 6deg so most Squares should miss too.**

## Per-build distance stats

| Build | n | min | p10 | median | p90 | max |
|---|---|---|---|---|---|---|
| b12-strokes | 12 | 2.06 | 3.27 | 5.43 | 8.13 | 10.42 |
| b13-strokes | 80 | 0.00 | 1.43 | 2.96 | 5.98 | 15.24 |
| by-build | 192 | 0.00 | 1.51 | 2.70 | 5.15 | 15.24 |