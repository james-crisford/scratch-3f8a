// swift-tools-version:5.9
//
// Off-device harness manifest — NOT part of the iOS build (which uses
// XcodeGen/project.yml). This package compiles the app's OWN mechanics
// sources, in place and unmodified, into the `plab` CLI so putting +
// placing mechanics can be replayed/simulated on Linux (Docker) or
// Windows without a TestFlight cycle. Zero-copy = zero drift.
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
    "PuttingLab/Models/UserProfile.swift",
    // Sensors — the pure detectors (SensorClock is mach_*-bound, excluded)
    "PuttingLab/Sensors/StillnessDetector.swift",
    "PuttingLab/Sensors/StrokeDetector.swift",
    // Calibration
    "PuttingLab/Calibration/CalibrationModel.swift",
    // Harness glue
    "harness/Sources/plab/main.swift",
    "harness/Sources/plab/CompatStubs.swift",
]

let package = Package(
    name: "plab",
    targets: [
        .target(name: "simd", path: "harness/Sources/simd"),
        .executableTarget(
            name: "plab",
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
    ]
)
