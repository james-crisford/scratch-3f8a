import Testing
import Foundation
import simd
@testable import PuttingLab

// B78 — this suite previously tested the ARKit-vs-compass dispatch logic and
// the per-origin tag emitted by the pre-B78 pipeline. The press-attitude
// pipeline replaces all of that: there is no ARKit/compass dispatch, no
// magnetometer baseline subtraction, and no `.arkit` / `.compass` /
// `.fallbackArkitLost` / `.fallbackNoBaseline` origin tags emitted in
// production. Every v2+ stroke reports `.pressAttitude`.
//
// The new pipeline is covered end-to-end by
// `FaceAngleComputerPressAttitudeTests.swift` (identity, ±yaw, wrap edges,
// gimbal lock, pure pitch, pure roll, multi-axis, sign convention, both-
// rotated delta, large-delta wrap, determinism). The smoke test below just
// pins origin tagging to catch a regression to legacy origins.

@Suite("FaceAngleComputer — origin tagging smoke test")
struct FaceAngleComputerOriginTests {

    @Test("v2 pipeline always reports .pressAttitude origin")
    func alwaysPressAttitude() {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let computer = FaceAngleComputer()
        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let result = computer.compute(
            window: fixture.window,
            attitudeAtImpact: attitude,
            impactTime: fixture.expectedImpactTime
        )
        #expect(result.origin == .pressAttitude)
    }

    @Test("FaceAngleSource.degrees conversion")
    func degreesConversion() {
        let source = FaceAngleSource(radians: .pi / 4, origin: .pressAttitude)
        #expect(abs(source.degrees - 45.0) < 0.001)
    }
}
