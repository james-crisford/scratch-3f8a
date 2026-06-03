import XCTest

/// B55 — visual-flow XCUITest that drives the AR placement view
/// through every state and captures a screenshot at each. The
/// screenshots are attached to the test result and uploaded as a
/// CI artifact; a follow-up `gemini_visual_audit.py` pass reads the
/// folder and asks Gemini to score the UI/HUD/button structure.
///
/// **Simulator caveat:** the iOS simulator doesn't have a real ARKit
/// camera feed. The AR view will show a black background where the
/// camera feed normally is, but the SwiftUI HUD + buttons + chip +
/// overlays render exactly as on device. That covers:
/// - Button identifier presence at each state
/// - HUD copy correctness ("Press anywhere to putt" → "Now swing")
/// - Chip + Putt-again button rendering at .rolled
/// - Result panel layout when expanded
/// - Debug overlay positioning + the B55 P2.2 force-collapse rule
///
/// For actual AR scene checks (hole / ball / flagstick PBR) we still
/// need device captures + Gemini-on-video.
///
/// Launch arguments:
/// - `-skipToARPlacement` — boots straight into ARPlacementView (added
///   in B55, replaces the missing `-skipOnboarding` hook the old
///   `ARButtonPresenceTests` was blocked on)
/// - `-uiTestMode` — forces ARPlacementView's placementState into
///   `.readyToPlaceBall` immediately so tests don't need a plane
@MainActor
final class ARVisualFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Drive the AR view through every state the simulator CAN reach
    /// and screenshot at each. The iOS Simulator has no real ARKit
    /// camera/LiDAR, so any state transition that depends on a raycast
    /// hit (tapping ar.placeBallButton / ar.placeHoleButton) won't
    /// complete — those would-be-tappers just sit on the screen and
    /// do nothing. We screenshot the initial -uiTestMode state and
    /// gracefully skip the rest if the placement loop doesn't advance.
    ///
    /// B60 — this rewrite avoids the B59 CI hang (1st version waited
    /// 5min for `Tap to place hole` after ar.placeBallButton.tap(),
    /// which never appeared because the sim has no plane to raycast
    /// against, triggering an 8-minute GitHub Actions timeout).
    func testCaptureScreenshotsAtReachableStates() throws {
        // B61 — hard-skip at the top when running on iOS Simulator.
        // The simulator has no real ARKit camera/LiDAR, and CI runs
        // a per-test 60s execution-time allowance. My B60 attempt to
        // skip gracefully after taps still spent 3+ minutes evaluating
        // each `waitForExistence(timeout:)` call before hitting the
        // XCTSkip, which exceeded the allowance + caused an outer
        // 8-min action-level timeout in GitHub Actions.
        //
        // Until a `-fakePlane` launch arg lands (TODO B62), the only
        // way this test makes sense is on a real device — gated on
        // `targetEnvironment(simulator)` compile-time check.
        #if targetEnvironment(simulator)
        throw XCTSkip("Visual flow test requires a real ARKit camera/LiDAR. Run on a physical device or wait for -fakePlane (TODO B62).")
        #endif
        let app = XCUIApplication()
        app.launchArguments += ["-skipToARPlacement", "-uiTestMode", "1"]
        app.launch()

        // State 1: .readyToPlaceBall (uiTestMode forces this on appear).
        // HUD should show: "Tap to place ball" / "Tap where you'll address the ball".
        try captureScreenshot(name: "01-ready-to-place-ball")
        XCTAssertTrue(app.staticTexts["Tap to place ball"].waitForExistence(timeout: 5),
                       "HUD must say 'Tap to place ball' at .readyToPlaceBall.")

        // The big bottom place-ball button should be present.
        let placeBallButton = app.buttons["ar.placeBallButton"]
        XCTAssertTrue(placeBallButton.waitForExistence(timeout: 3),
                       "ar.placeBallButton must exist at .readyToPlaceBall.")

        // Verify the always-visible export buttons exist regardless
        // of HUD compact state (B57.2 fix).
        XCTAssertTrue(app.buttons["ar.recordButtonAlwaysVisible"].exists,
                       "ar.recordButtonAlwaysVisible must be reachable.")
        XCTAssertTrue(app.buttons["ar.saveButtonAlwaysVisible"].exists,
                       "ar.saveButtonAlwaysVisible must be reachable.")
        XCTAssertTrue(app.buttons["ar.sendThisButtonAlwaysVisible"].exists,
                       "ar.sendThisButtonAlwaysVisible must be reachable.")
        XCTAssertTrue(app.buttons["ar.sendAllButtonAlwaysVisible"].exists,
                       "ar.sendAllButtonAlwaysVisible must be reachable.")

        // Now attempt the placement loop — the simulator has no real
        // AR plane so the raycast-driven state transitions may not
        // happen. We give it a short shot then gracefully skip the
        // rest rather than hanging the runner.
        placeBallButton.tap()
        let advancedToHole = app.staticTexts["Tap to place hole"]
            .waitForExistence(timeout: 2)
        guard advancedToHole else {
            // Sim can't raycast — capture what we have + finish cleanly.
            try captureScreenshot(name: "02-stuck-on-ready-to-place-ball")
            throw XCTSkip("Simulator can't satisfy the raycast — full placement flow needs a real device or a fake-plane launch arg (TODO B61).")
        }
        try captureScreenshot(name: "02-ready-to-place-hole")

        // If we got here, we have a fake plane somehow (e.g. Xcode 27+
        // simulator improvements or someone added a -fakePlane arg).
        // Capture the rest of the states.
        let placeHoleButton = app.buttons["ar.placeHoleButton"]
        if placeHoleButton.waitForExistence(timeout: 2) {
            placeHoleButton.tap()
            if app.staticTexts["Press anywhere to putt"].waitForExistence(timeout: 3) {
                try captureScreenshot(name: "03-complete-pre-press")
                XCTAssertTrue(app.buttons["ar.resetButton"].exists,
                               "Reset button must be visible at .complete (pressActive=false).")
                XCTAssertTrue(app.buttons["ar.moveBallButton"].exists,
                               "Move ball button must be visible at .complete (pressActive=false).")
                XCTAssertTrue(app.buttons["ar.moveHoleButton"].exists,
                               "Move hole button must be visible at .complete (pressActive=false).")
            }
        }
    }

    /// Verify the result-state UI: chip + putt-again button. This test
    /// can't actually GENERATE a rolled state from the sim because
    /// stroke detection requires real IMU data. Skipped until a launch
    /// arg `-fakeRolledState` lands (TODO B56) that forces
    /// `placementState = .rolled(...)` so we can screenshot the chip,
    /// the panel, and the debug-overlay force-collapse.
    func testCaptureScreenshotsAtRolledState() throws {
        try XCTSkipIf(true,
                       "Needs -fakeRolledState launch hook to inject .rolled state without real IMU input. TODO B56.")
    }

    // MARK: - Helpers

    /// Capture a screenshot and attach it to the test with a stable name.
    /// XCTest writes the attachment to xcresult bundles; CI then uploads
    /// the bundle as an artifact. The Gemini visual-audit Python tool
    /// reads the bundle's screenshots from there.
    private func captureScreenshot(name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
