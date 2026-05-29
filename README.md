# PuttingLab

iPhone-only golf putting game. Hold phone vertically like a putter grip, swing through air, get a believable result.

## Status

**Day 1 of 14-day v1 sprint.** Source files for the sensor foundation are written. Awaiting first build on Mac.

## Where things live

```
.
├── CLAUDE.md                              project handbook (read first)
├── GOAL.md                                drop-in goal prompt
├── MAC_SETUP.md                           one-time Xcode setup, ~10 min
├── PuttingLab/                            iOS app source
│   ├── App/                               PuttingLabApp.swift
│   ├── Models/                            MotionSample, StrokeBuffer
│   ├── Sensors/                           MotionManager, SensorClock
│   ├── UI/                                SensorDebugView
│   ├── Physics/                           (empty until Day 5)
│   ├── Calibration/                       (empty until Day 12)
│   ├── Storage/                           (empty until Day 12)
│   ├── Resources/                         (Assets.xcassets goes here later)
│   └── Info.plist
├── PuttingLabTests/
│   ├── Models/                            StrokeBufferTests
│   ├── Sensors/                           MotionManagerTests (+ MotionSampleTests)
│   └── Fixtures/                          (empty until Day 5)
├── docs/
│   ├── spec-putting-lab-v1-FINAL.md       the contract
│   ├── feedback/                          TestFlight feedback (empty)
│   └── research/                          background reports
└── .claude/skills/                        5 project skills (auto-load)
```

## Build environment

iOS development requires **macOS + Xcode 16+**. This project is currently scaffolded on Windows. See `MAC_SETUP.md` for the one-time Xcode setup.

## Day 1 deliverables

- `MotionSample` value type wrapping CMDeviceMotion
- `StrokeBuffer<Element>` thread-safe ring buffer (5s × 100Hz = 500-sample capacity)
- `SensorClock` mach_absolute_time helper
- `MotionManager` wrapping CMMotionManager with `.xMagneticNorthZVertical` reference frame at 100Hz
- `SensorDebugView` SwiftUI debug screen showing live rotation/accel/gravity + measured Hz
- 17 unit tests (StrokeBuffer × 7, MotionManager × 7, MotionSample × 3)

## Day 1 verification (run on Mac)

1. `Cmd-U` in Xcode → all 17 tests green.
2. `Cmd-R` on iPhone → SensorDebugView shows ~100Hz on still device.
3. Walk through the 7-item device checklist in MAC_SETUP.md §9.

Report results back to continue with Day 2.
