import SwiftUI

@main
struct PuttingLabApp: App {
    var body: some Scene {
        WindowGroup {
            // B55 — `-skipToARPlacement` launch argument jumps straight
            // to ARPlacementView without traversing the practice /
            // onboarding flow. Used by XCUITest visual-flow runs so
            // screenshots can be captured at each AR state without
            // needing to drive the full onboarding gauntlet.
            if CommandLine.arguments.contains("-skipToARPlacement") {
                ARPlacementView()
            } else {
                // PracticeSessionView is the guided 100-stroke session.
                // SensorDebugView is reachable via the options menu in the top-right
                // corner (sheet presentation) for raw sensor inspection.
                PracticeSessionView()
            }
        }
    }
}
