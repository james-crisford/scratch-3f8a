import SwiftUI
import AVFoundation

@main
struct PuttingLabApp: App {
    init() {
        // B67 — configure the shared audio session for the putter-click
        // sound (B66) to be reliably AUDIBLE during AR sessions AND
        // captured by ReplayKit screen recordings. Pre-B67 the session
        // category was inherited as `.soloAmbient`, which:
        //   1. respects the hardware mute switch (most testers had it on),
        //   2. is killed by other apps' audio (Spotify → silent putter),
        //   3. ReplayKit captured nothing in the AR7 video despite B66
        //      explicitly calling player.play() on impact.
        //
        // `.playback` plays through speaker, ignores the mute switch (this
        // is game audio, intentional), and the `.mixWithOthers` +
        // `.duckOthers` options let backing music duck briefly instead of
        // being stopped. setActive(true) primes the session so the first
        // putter-click hits the speaker within ~5 ms instead of after the
        // first-use cold-start delay.
        //
        // Errors here are surfaced but non-fatal — even if the session
        // configuration fails, the rest of the app works; only the sound
        // is silenced. AVAudioSession activation can fail when another
        // app holds an exclusive audio session (rare; .duckOthers should
        // prevent it).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.mixWithOthers, .duckOthers])
            try session.setActive(true, options: [])
        } catch {
            NSLog("[B67] AVAudioSession setup failed: \(error.localizedDescription)")
        }
    }

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
