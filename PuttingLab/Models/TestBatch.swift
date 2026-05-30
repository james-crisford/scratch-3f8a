import Foundation

/// One of the 10 phases (9 stroke-bearing batches + 1 break) in the 100-stroke
/// verification session. The session walks the user from calibration through
/// 9 test batches, with a recommended 10-minute break between Block 1 and Block 2.
///
/// Stroke totals: 5 cal + 20 A + 15 B + 15 C + 5 D + 10 E + 10 F + 10 G + 10 H = 100.
struct TestBatch: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let strokeTypeLabel: String
    let intentSummary: String
    let instructions: [String]
    let targetCount: Int
    let phase: SessionPhase

    enum SessionPhase: String, Sendable, Equatable {
        case calibration
        case block1
        case breakPoint
        case block2
    }

    static let allBatches: [TestBatch] = [
        TestBatch(
            id: "cal",
            displayName: "Calibration",
            strokeTypeLabel: "Natural putting stroke",
            intentSummary: "Learning your stroke style",
            instructions: [
                "Pick a consistent TARGET (doorway, wall mark) and stand facing it",
                "Address pose: hold phone VERTICAL, screen TOWARD YOU — wait for the 'Aimed' badge",
                "Press + hold the screen at takeaway",
                "Make your natural putting motion — the phone WILL tilt forward, that is fine",
                "Release the screen at the end of your follow-through",
                "Keep the SAME grip + stance between strokes — consistency is everything",
            ],
            targetCount: 5,
            phase: .calibration
        ),
        TestBatch(
            id: "A",
            displayName: "Batch A — Clean baseline",
            strokeTypeLabel: "Clean baseline stroke",
            intentSummary: "Natural variance — verifies KI-6 (calibration brittleness)",
            instructions: [
                "Make smooth, natural strokes",
                "No deliberate face manipulation — just normal putting",
                "This establishes your baseline stroke-to-stroke scatter",
            ],
            targetCount: 20,
            phase: .block1
        ),
        TestBatch(
            id: "B",
            displayName: "Batch B — Pull strokes",
            strokeTypeLabel: "Deliberate PULL stroke",
            intentSummary: "Sign convention test — verifies KI-1",
            instructions: [
                "Deliberately CLOSE the face at impact",
                "Rotate phone slightly LEFT at peak forward velocity",
                "Make the manipulation OBVIOUS — at least 5° of rotation",
            ],
            targetCount: 15,
            phase: .block1
        ),
        TestBatch(
            id: "C",
            displayName: "Batch C — Push strokes",
            strokeTypeLabel: "Deliberate PUSH stroke",
            intentSummary: "Sign convention cross-check — verifies KI-1",
            instructions: [
                "Deliberately OPEN the face at impact",
                "Rotate phone slightly RIGHT at peak forward velocity",
                "Same magnitude as Batch B (5°+ rotation)",
            ],
            targetCount: 15,
            phase: .block1
        ),
        TestBatch(
            id: "D",
            displayName: "Batch D — Post-fatigue clean",
            strokeTypeLabel: "Post-fatigue clean stroke",
            intentSummary: "Profile drift check after 50 strokes",
            instructions: [
                "Same as Batch A — clean, natural strokes",
                "Checking if your profile drifted across the session",
            ],
            targetCount: 5,
            phase: .block1
        ),
        TestBatch(
            id: "break",
            displayName: "Break",
            strokeTypeLabel: "",
            intentSummary: "10-minute rest — water, stretch, let the phone cool",
            instructions: [
                "Put the phone down",
                "Drink water, stretch",
                "60 of 100 strokes done — over half way",
                "Tap below when you're ready to resume",
            ],
            targetCount: 0,
            phase: .breakPoint
        ),
        TestBatch(
            id: "E",
            displayName: "Batch E — Steel-adjacent",
            strokeTypeLabel: "Magnetometer paired stroke",
            intentSummary: "Magnetometer corruption — verifies KI-4 (PAIRED)",
            instructions: [
                "FIRST 5 strokes: stand next to a metal radiator or steel cabinet (within ~30 cm)",
                "LAST 5 strokes: stand 2+ metres from any steel object",
                "Same posture, same phone hold for both halves",
            ],
            targetCount: 10,
            phase: .block2
        ),
        TestBatch(
            id: "F",
            displayName: "Batch F — Stillness paired",
            strokeTypeLabel: "Stillness paired stroke",
            intentSummary: "Stillness tolerance — verifies KI-5 (PAIRED)",
            instructions: [
                "FIRST 5 strokes: military-RIGID body posture before each stroke",
                "LAST 5 strokes: natural body sway while \"holding still\"",
                "Tests if our 25° stillness tolerance is right",
            ],
            targetCount: 10,
            phase: .block2
        ),
        TestBatch(
            id: "G",
            displayName: "Batch G — Edge cases",
            strokeTypeLabel: "Robustness stroke",
            intentSummary: "Background + tilt + terrible stroke recovery",
            instructions: [
                "Stroke 1: after backgrounding the app 30 sec",
                "Stroke 2: after backgrounding 2 min (ARKit will lose tracking)",
                "Stroke 3: with phone tilted 20° forward at address",
                "Stroke 4: deliberately TERRIBLE stroke (huge wobble) — expect Square snap",
                "Strokes 5-10: normal strokes to confirm everything still works",
            ],
            targetCount: 10,
            phase: .block2
        ),
        TestBatch(
            id: "H",
            displayName: "Batch H — Cool-down clean",
            strokeTypeLabel: "Cool-down clean stroke",
            intentSummary: "Final fatigue baseline",
            instructions: [
                "Pure baseline strokes again",
                "Compare scatter to Batch A and Batch D",
                "Wider scatter = real-world fatigue noise (informs natural variance bounds)",
            ],
            targetCount: 10,
            phase: .block2
        ),
    ]

    static var totalTargetStrokes: Int {
        allBatches.filter { $0.phase != .breakPoint }.reduce(0) { $0 + $1.targetCount }
    }
}
