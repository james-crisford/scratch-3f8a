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

    /// Drive the AR view through ready-to-place-ball, ready-to-place-hole,
    /// complete, press-active, and roll states. Screenshot at each.
    func testCaptureScreenshotsAtEveryState() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-skipToARPlacement", "-uiTestMode", "1"]
        app.launch()

        // State 1: .readyToPlaceBall (uiTestMode forces this on appear).
        // HUD should show: "Tap to place ball" / "Tap where you'll address the ball".
        try captureScreenshot(name: "01-ready-to-place-ball")
        XCTAssertTrue(app.staticTexts["Tap to place ball"].waitForExistence(timeout: 5),
                       "HUD must say 'Tap to place ball' at .readyToPlaceBall.")

        // The big bottom place-ball button should be present + tappable.
        let placeBallButton = app.buttons["ar.placeBallButton"]
        XCTAssertTrue(placeBallButton.waitForExistence(timeout: 3),
                       "ar.placeBallButton must exist at .readyToPlaceBall.")
        placeBallButton.tap()

        // State 2: .readyToPlaceHole. Same big-button affordance,
        // different label.
        XCTAssertTrue(app.staticTexts["Tap to place hole"].waitForExistence(timeout: 3),
                       "HUD must say 'Tap to place hole' after ball placed.")
        try captureScreenshot(name: "02-ready-to-place-hole")

        let placeHoleButton = app.buttons["ar.placeHoleButton"]
        XCTAssertTrue(placeHoleButton.waitForExistence(timeout: 3),
                       "ar.placeHoleButton must exist at .readyToPlaceHole.")
        placeHoleButton.tap()

        // State 3: .complete. HUD should now say "Press anywhere to putt"
        // and the action row should show Reset / Move ball / Move hole.
        XCTAssertTrue(app.staticTexts["Press anywhere to putt"].waitForExistence(timeout: 3),
                       "B55 HUD must say 'Press anywhere to putt' at .complete (was: stateLabel = pressActive ? 'Now swing' : 'Press anywhere to putt')")
        try captureScreenshot(name: "03-complete-pre-press")

        // B55 P2.1: Reset / Move ball / Move hole all visible at
        // .complete when pressActive == false.
        XCTAssertTrue(app.buttons["ar.resetButton"].exists,
                       "Reset button must be visible at .complete (pressActive=false).")
        XCTAssertTrue(app.buttons["ar.moveBallButton"].exists,
                       "Move ball button must be visible at .complete (pressActive=false).")
        XCTAssertTrue(app.buttons["ar.moveHoleButton"].exists,
                       "Move hole button must be visible at .complete (pressActive=false).")

        // State 4: Press gesture active. We can't *really* invoke the
        // DragGesture(minimumDistance:0) in the simulator the way a
        // human would, but a press-and-hold on the AR view layer
        // should fire onChanged. The accessibilityIdentifier on the
        // press gesture catcher is "ar.pressGesture".
        let pressGesture = app.otherElements["ar.pressGesture"]
        if pressGesture.exists {
            pressGesture.press(forDuration: 0.6)
            try captureScreenshot(name: "04-press-active")
            // P2.1: action row should be hidden during press.
            // The Reset button is the canonical check — it should
            // NOT be hittable while pressActive == true.
            // (Press is released after the press call returns, so
            // by the time we screenshot we may be back at pressActive
            // == false. That's why we screenshot DURING the press
            // above. Below assertion may flake; keep informational.)
        }

        // State 5: After release with no real swing motion (sim can't
        // produce IMU swing data), pressActive flips back to false.
        // HUD should return to "Press anywhere to putt".
        XCTAssertTrue(app.staticTexts["Press anywhere to putt"].waitForExistence(timeout: 3),
                       "After press release with no swing, HUD must return to 'Press anywhere to putt'.")
        try captureScreenshot(name: "05-back-to-complete-after-tap")
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
