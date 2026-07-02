# plab — off-device replay & simulation harness

Iterate on PuttingLab's putting + placing mechanics **without a TestFlight
cycle**. The harness compiles the app's **own Swift source files, in place**
(see the `sources:` whitelist in the repo-root `Package.swift`) into a CLI
that replays recorded strokes and runs simulations on this Windows machine
via Docker + the official Swift Linux image. Zero-copy means drift between
the harness and the shipped app is structurally impossible — the exact
failure mode that bit `tools/simulate_historical_strokes.py` (mirrored
lateral misses) and `tools/parameter_search.py` (cooldown/warm-up drift),
both now deprecated.

## Quick start

```bash
harness/run.sh test                          # the app's portable test suite (327 tests, ~1s)
harness/run.sh parity data/raw/by-build      # field-split parity gate, 192 strokes
harness/run.sh replay data/raw/by-build/0.2.2-16
harness/run.sh calfit data/raw/by-build      # S2 speed-factor quantification + v4 objective cross-check
harness/run.sh h5                            # face-sampling-time error on synthetic ground truth
harness/run.sh sim --peak 0.15 --face -3 --cal 22.9 --cup 2.0
```

Docker Desktop must be running. Cold build ~20 s, incremental a few seconds.

`test` runs the real app suites (all Physics, Calibration, detectors,
Storage, fuzz/invariant integration) — everything except the
CoreMotion/ARKit/UIKit-bound files — via Swift Testing on Linux,
serially (`--no-parallel`): corelibs-foundation UserDefaults loses
writes under the parallel executor (known-deferred H7 isolation issue;
verified 2026-07-02: parallel = 1-2 flaky failures, serial = 327/327).

## What compiles off-device (verified 2026-07-02, HEAD a3c69a9)

- All of `PuttingLab/Physics/` except `BallRollAnimator` (RealityKit-bound)
- `Models/` (via two `#if canImport` guards: CoreMotion init in
  `MotionSample`, ARKit inits in `ARTrackingState` — no-ops on iOS)
- `Sensors/StillnessDetector`, `Sensors/StrokeDetector`
- `Calibration/CalibrationModel`
- `harness/Sources/simd/` is a shim module literally named `simd` so the
  production `import simd` lines resolve unchanged on Linux/Windows.
  **Never `swift build` this package on macOS** — the shim would shadow
  Apple's simd module. An `#error` guard in the shim enforces this. The
  iOS app is untouched: it builds via XcodeGen/project.yml as always.

## Parity gate (why some fields are gated and others aren't)

`git log` proves `ImpactDetector.swift` last changed at Build 7 — **before**
all 192 on-disk replays were recorded — so stored
`result.{timestamp, peakVelocity, snappedToSquare, snapReason, confidence}`
are valid goldens against HEAD-compiled code. `FaceAngleComputer` was
rewritten at B78 and B80 **after** all of them, so stored `faceAngleRaw`
is compass-era data, NOT a valid golden; recomputed values on v1 replays
use the first-sample-attitude fallback and are a third, incomparable
quantity. The parity subcommand hard-gates the first five fields and
reports faceAngleRaw as a diagnostic only.

**Status 2026-07-02: PARITY GREEN 192/192, max |delta| = 0.0 on every
gated field** (bit-identical, glibc vs Darwin).

## Known limits (what still needs the phone)

- **No v2+ replays exist yet.** All 192 replays are schemaVersion 1
  (builds 7–16); none carry `lock.attitudeAtPress`, so the current v3
  press-attitude face-angle pipeline has never been validated against
  real recorded data. One practice-mode session on the installed build
  produces the first v2 replays — no new TestFlight build needed
  (PracticeSessionView is the app's root view and saves replays).
- **H5 (impact timing) is data-blocked.** ARKit pose tracks are not
  serialized in any artifact. Requires the one B81 ship: wire
  `StrokeReplayStore.save` into ARPlacementView's stroke completion +
  schemaVersion 3 with the pose track (AR mode currently saves NO replays
  at all — `strokeReplaysIncluded: 0`).
- **Real-world roll distance** has no truth anchor in any artifact —
  needs tape-measure putts (see the device-session spec in the project
  memory / final report).
- Rendering (`BallRollAnimator`, RealityKit meshes) stays on-device;
  its pure math (localPos/worldPos, ~20 lines) is a candidate for
  extraction in a later phase.

## peakVelocity unit convention — do not "fix"

`peakVelocity` integrates CoreMotion `userAcceleration` in g-units treated
as m/s² (~9.81× under-scaled but self-consistent; calibration absorbs the
scale). The harness preserves this verbatim. Any unilateral unit fix
silently invalidates every calibration factor and stored golden.

## Layout

```
Package.swift                 # repo root — zero-copy manifest (NOT part of iOS build)
harness/Sources/simd/         # cross-platform simd shim (module named `simd`)
harness/Sources/plab/         # CLI: replay | parity | calfit | sim
harness/run.sh                # Docker wrapper
data/raw/by-build/            # 192 v1 replays (builds 7-16)
data/raw/ar-bundles/b79/      # only B78+ session artifact (events + real cal factor 14.183)
```
