import SwiftUI

@main
struct PuttingLabApp: App {
    var body: some Scene {
        WindowGroup {
            // PracticeSessionView is the guided 100-stroke session.
            // SensorDebugView is reachable via the options menu in the top-right
            // corner (sheet presentation) for raw sensor inspection.
            PracticeSessionView()
        }
    }
}
