// swift-tools-version:5.9
//
// Off-device harness manifest — NOT part of the iOS build (which uses
// XcodeGen/project.yml). This package compiles the app's OWN mechanics
// sources, in place and unmodified, into (a) a `PuttingLab` library,
// (b) the `plab` CLI, and (c) a test target running the portable subset
// of the app's real Swift Testing suite — so putting + placing mechanics
// can be replayed/simulated/tested on Linux (Docker) or Windows without
// a TestFlight cycle. Zero-copy = zero drift.
//
// NEVER `swift build` this on macOS: the shim target is literally named
// `simd` and would shadow Apple's module (the shim source carries an
// #error guard enforcing this). Run via harness/run.sh (Docker) instead.
// See harness/README.md.

import PackageDescription

let mechanicsSources = [
    // Physics — everything except BallRollAnimator (RealityKit-bound)
    "PuttingLab/Physics/BallPhysics.swift",
    "PuttingLab/Physics/DistanceModel.swift",
    "PuttingLab/Physics/FaceAngleComputer.swift",
    "PuttingLab/Physics/GreenFrame.swift",
    "PuttingLab/Physics/ImpactDetector.swift",
    "PuttingLab/Physics/LiveImpactDetector.swift",
    "PuttingLab/Physics/MarioKartAssist.swift",
    "PuttingLab/Physics/StanceGeometry.swift",
    // Models — pure or canImport-guarded
    "PuttingLab/Models/AddressPose.swift",
    "PuttingLab/Models/ARPose.swift",
    "PuttingLab/Models/ARTrackingState.swift",
    "PuttingLab/Models/CalibrationProfile.swift",
    "PuttingLab/Models/ImpactResult.swift",
    "PuttingLab/Models/MotionSample.swift",
    "PuttingLab/Models/PhaseState.swift",
    "PuttingLab/Models/StillnessLock.swift",
    "PuttingLab/Models/StrokeBuffer.swift",
    "PuttingLab/Models/StrokeRecord.swift",
    "PuttingLab/Models/StrokeReplay.swift",
    "PuttingLab/Models/StrokeWindow.swift",
    "PuttingLab/Models/TestBatch.swift",
    "PuttingLab/Models/TestSessionState.swift",
    "PuttingLab/Models/UserProfile.swift",
    // Sensors — the pure detectors (SensorClock is mach_*-bound,
    // ARTrackingManager/MotionManager are ARKit/CoreMotion-bound)
    "PuttingLab/Sensors/StillnessDetector.swift",
    "PuttingLab/Sensors/StrokeDetector.swift",
    // Calibration (CalibrationCoordinator is Foundation-only)
    "PuttingLab/Calibration/CalibrationCoordinator.swift",
    "PuttingLab/Calibration/CalibrationModel.swift",
    // Storage — Foundation-only
    "PuttingLab/Storage/ProfileStore.swift",
    "PuttingLab/Storage/StatsAggregator.swift",
    "PuttingLab/Storage/StrokeHistoryStore.swift",
    // Harness glue (ARTrackingManager.yaw mirror for non-ARKit platforms)
    "harness/Sources/compat/CompatStubs.swift",
]

// Test files that depend on Apple-bound production types excluded above.
let applBoundTests = [
    "Sensors/MotionManagerTests.swift",       // CoreMotion
    "Sensors/ARTrackingManagerTests.swift",   // ARTrackingManager (ARKit)
    "Sensors/Fakes/FakeARTrackingManager.swift",
    "UI/PracticeSessionViewModelTests.swift", // UIKit
    "Integration/SessionCoordinatorTests.swift",   // SessionCoordinator (UIKit)
    "Integration/MultiStrokeSessionTests.swift",   // SessionCoordinator (UIKit)
]

let package = Package(
    name: "plab",
    targets: [
        .target(name: "simd", path: "harness/Sources/simd"),
        .target(
            name: "PuttingLab",
            dependencies: ["simd"],
            path: ".",
            exclude: [
                "references",
                "PuttingLab/Resources",
                "PuttingLab/UI",
                "PuttingLab/App",
                "PuttingLabTests",
                "PuttingLabUITests",
                "harness/Sources/simd",
                "harness/Sources/plab",
                "harness/README.md",
                "harness/run.sh",
                "docs",
                "data",
                "tools",
                "briefs",
                "goals",
                "scripts",
                "ci_scripts",
            ],
            sources: mechanicsSources
        ),
        .executableTarget(
            name: "plab",
            dependencies: ["PuttingLab", "simd"],
            path: "harness/Sources/plab"
        ),
        .testTarget(
            name: "PuttingLabPortableTests",
            dependencies: ["PuttingLab", "simd"],
            path: "PuttingLabTests",
            exclude: applBoundTests
        ),
    ]
)
