import SwiftUI
import UIKit

/// Root view of the 100-stroke guided session.
///
/// Switches between six sub-views by `PracticeSessionViewModel.Phase`:
///   - .instructions     → InstructionsPhaseView (read the batch + tap Ready)
///   - .ready            → ReadyPhaseView (waiting for touch-down)
///   - .recording        → RecordingPhaseView (touch held, red background)
///   - .showing          → ResultPhaseView (display impact result + "Done")
///   - .batchTransition  → BatchTransitionView ("Batch X complete, next: Y")
///   - .breakPoint       → BreakView (between Block 1 and Block 2)
///   - .sessionComplete  → CompleteView (export instructions)
///
/// Touch is captured via a single full-screen `DragGesture(minimumDistance: 0)`
/// — any finger anywhere starts/ends recording.
struct PracticeSessionView: View {
    @State private var viewModel = PracticeSessionViewModel()
    @State private var showDebug = false
    @State private var showHistory = false
    @State private var showRestartConfirm = false
    @State private var isPressing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundColor)
                .ignoresSafeArea(.container, edges: .bottom)

            // Debug button (top-right corner, semi-transparent so it doesn't
            // distract during the session but always reachable for sensor
            // inspection).
            debugButton
                .padding(.top, 8)
                .padding(.trailing, 12)
        }
        .gesture(touchGesture)
        .onAppear { viewModel.startSession() }
        .onDisappear { viewModel.stopSession() }
        .onChange(of: scenePhase) { _, newPhase in
            // Match the existing SensorDebugView behaviour: pause on background
            // only (not .inactive, which fires on notification pull-downs).
            switch newPhase {
            case .active:
                viewModel.startSession()
                // Defensive: if the touch gesture was interrupted by app
                // backgrounding, onEnded may not have fired and isPressing
                // would remain true, blocking the next touchDown. Reset.
                isPressing = false
            case .background:
                viewModel.stopSession()
                isPressing = false
            default:
                break
            }
        }
        .sheet(isPresented: $showDebug) {
            SensorDebugView()
        }
        .sheet(isPresented: $showHistory) {
            ReplayHistoryView()
        }
        .alert("Restart session?", isPresented: $showRestartConfirm) {
            Button("Restart", role: .destructive) { viewModel.restartSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes the current 100-stroke session counter and starts over from calibration. Saved stroke JSONs in Files are NOT deleted.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .instructions:
            InstructionsPhaseView(viewModel: viewModel)
        case .ready:
            ReadyPhaseView(viewModel: viewModel)
        case .recording:
            RecordingPhaseView(samplesCount: viewModel.samplesInCurrentRecording)
        case .showing:
            ResultPhaseView(
                viewModel: viewModel,
                result: viewModel.lastImpactResult
            )
        case .batchTransition:
            BatchTransitionView(viewModel: viewModel)
        case .breakPoint:
            BreakView(viewModel: viewModel)
        case .sessionComplete:
            CompleteView(
                viewModel: viewModel,
                onOpenHistory: { showHistory = true },
                onRestart: { showRestartConfirm = true }
            )
        }
    }

    private var backgroundColor: Color {
        switch viewModel.phase {
        case .recording: return .red
        case .sessionComplete: return Color(.systemGreen).opacity(0.08)
        default: return Color(.systemBackground)
        }
    }

    private var debugButton: some View {
        Menu {
            Button { showDebug = true } label: {
                Label("Sensor Debug", systemImage: "waveform.path.ecg")
            }
            Button { showHistory = true } label: {
                Label("Stroke history", systemImage: "list.bullet.rectangle")
            }
            Button(role: .destructive) {
                showRestartConfirm = true
            } label: {
                Label("Restart session", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.thinMaterial, in: Circle())
        }
        .accessibilityLabel("Options menu")
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressing && viewModel.phase == .ready {
                    isPressing = true
                    viewModel.touchDown()
                }
            }
            .onEnded { _ in
                if isPressing {
                    isPressing = false
                    viewModel.touchUp()
                }
            }
    }
}

// MARK: - Phase sub-views

// MARK: - Page 1: Instructions

private struct InstructionsPhaseView: View {
    let viewModel: PracticeSessionViewModel

    var body: some View {
        let batch = viewModel.session.currentBatch
        VStack(spacing: 0) {
            // PROMINENT counter + stroke type at top
            BigStrokeHeader(
                strokeNumber: viewModel.session.totalStrokesCompleted + 1,
                totalTarget: viewModel.session.totalTargetStrokes,
                batchLabel: batch.displayName.uppercased(),
                strokeTypeLabel: batch.strokeTypeLabel.uppercased(),
                inBatchDone: viewModel.session.strokesInCurrentBatch,
                inBatchTarget: batch.targetCount
            )

            // Scroll: intent + instructions + sensor warnings
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(batch.intentSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Phone-hold flow card for the FIRST stroke of any new batch.
                    if viewModel.session.strokesInCurrentBatch == 0 {
                        PhoneHoldVisual()
                    }

                    // Instructions
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(batch.instructions.enumerated()), id: \.offset) { idx, line in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(idx + 1).")
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 22, alignment: .leading)
                                Text(line)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let motionErr = viewModel.motionErrorText {
                        Text("Motion sensor: \(motionErr)")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let arkitErr = viewModel.arkitErrorText {
                        Text("ARKit: \(arkitErr)")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            // Big READY button at bottom
            Button {
                viewModel.tapReadyForStrokes()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title2)
                    Text("READY TO STROKE")
                        .font(.title3.weight(.heavy))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(.blue, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - Page 2: Ready to stroke (touch area)

private struct ReadyPhaseView: View {
    let viewModel: PracticeSessionViewModel

    var body: some View {
        let batch = viewModel.session.currentBatch
        VStack(spacing: 0) {
            // PROMINENT counter + stroke type at top, plus a Back button.
            BigStrokeHeader(
                strokeNumber: viewModel.session.totalStrokesCompleted + 1,
                totalTarget: viewModel.session.totalTargetStrokes,
                batchLabel: batch.displayName.uppercased(),
                strokeTypeLabel: batch.strokeTypeLabel.uppercased(),
                inBatchDone: viewModel.session.strokesInCurrentBatch,
                inBatchTarget: batch.targetCount
            )

            Spacer()

            // Big touch prompt — the whole screen below the header is the touch area
            VStack(spacing: 14) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)
                Text("TAP & HOLD\nANYWHERE")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Press at takeaway · keep holding through the stroke · release at end of follow-through")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }

            if let err = viewModel.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.footnote.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }

            Spacer()

            Button {
                viewModel.tapBackToInstructions()
            } label: {
                Label("Re-read instructions", systemImage: "arrow.uturn.backward")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Big header shared by Instructions + Ready pages

private struct BigStrokeHeader: View {
    let strokeNumber: Int
    let totalTarget: Int
    let batchLabel: String
    let strokeTypeLabel: String
    let inBatchDone: Int
    let inBatchTarget: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Big stroke counter
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("STROKE")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(strokeNumber)")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                Text("of \(totalTarget)")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(inBatchDone) of \(inBatchTarget)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.gray.opacity(0.15), in: Capsule())
            }
            // Batch label as accent
            Text(batchLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            // PROMINENT stroke type
            Text(strokeTypeLabel)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            // Session progress bar
            ProgressView(value: Double(strokeNumber - 1), total: Double(max(totalTarget, 1)))
                .tint(.blue)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(Color(.systemBackground))
    }
}

private struct RecordingPhaseView: View {
    let samplesCount: Int

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "record.circle")
                .font(.system(size: 90))
                .foregroundStyle(.white)
                .symbolEffect(.pulse)
            Text("RECORDING")
                .font(.system(size: 38, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("Release at end of follow-through")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Text("\(samplesCount) samples captured")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResultPhaseView: View {
    let viewModel: PracticeSessionViewModel
    let result: ImpactResult?

    /// DEBUG-only AR Slice 1 entry point. Set when the small "AR Test"
    /// link below the Done button is tapped; presents `ARScanningView`
    /// as a fullScreenCover so the live camera + plane detection have
    /// the whole screen. Doesn't change any stroke state.
    @State private var showARScanningTest: Bool = false
    /// DEBUG-only AR Slice 2 entry point. Presents `ARPlacementView`
    /// which adds tap-to-place ball + hole on top of Slice 1's
    /// scanning. Also doesn't touch any stroke state.
    @State private var showARPlacementTest: Bool = false

    var body: some View {
        let strokeNumber = viewModel.session.totalStrokesCompleted + 1
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("Stroke \(strokeNumber)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("RECORDED")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 40)

            if let r = result {
                VStack(spacing: 14) {
                    // B14: show calibrated face angle once the cal-batch
                    // baseline has stabilised (≥3 cal strokes). Until then
                    // we show the raw value — calibration hasn't been
                    // established yet, so subtracting an unstable mean
                    // would mislead. Also label the row so users know which
                    // they're looking at.
                    let calBaselineDeg: Double? = {
                        guard let r = viewModel.session.calibrationFaceBaselineRad else { return nil }
                        return r * 180.0 / .pi
                    }()
                    let displayedFaceDeg: Double = {
                        if r.snappedToSquare { return 0 }
                        let raw = r.faceAngleDegrees
                        if let base = calBaselineDeg { return raw - base }
                        return raw
                    }()
                    resultRow(calBaselineDeg == nil ? "face (raw)" : "face (cal)",
                              value: r.snappedToSquare
                                ? "Square (snapped)"
                                : String(format: "%+.1f°", displayedFaceDeg),
                              tint: r.snappedToSquare ? .orange : .primary)
                    if let reason = r.snapReason, r.snappedToSquare {
                        resultRow("reason", value: String(describing: reason), tint: .secondary)
                    }
                    resultRow("peak velocity",
                              value: String(format: "%.2f m/s", r.peakVelocity))
                    resultRow("confidence",
                              value: String(format: "%.2f", r.confidence))
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            } else {
                Text("Stroke saved — no impact data computed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }

            // Per-stroke accuracy feedback. Stored as userImpactJudgment in
            // StrokeReplay JSON for offline cross-check vs computed impact time.
            VStack(spacing: 8) {
                Text("HOW DID THIS FEEL?")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                let n = viewModel.liveHapticFireCount
                Text(n == 0
                    ? "No impact haptic during this stroke — judge from feel."
                    : (n == 1
                        ? "Felt the impact thwack. Did it land at the moment of contact?"
                        : "Felt \(n) impact thwacks — judge the LAST one."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    judgmentButton(label: "Just right", systemImage: "checkmark.circle.fill",
                                   tint: .green, judgment: .justRight)
                    judgmentButton(label: "Felt early", systemImage: "backward.fill",
                                   tint: .orange, judgment: .early)
                    judgmentButton(label: "Felt late", systemImage: "forward.fill",
                                   tint: .purple, judgment: .late)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Spacer(minLength: 8)

            Button {
                viewModel.tapDone()
            } label: {
                Text("DONE — NEXT STROKE")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.green, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)

            // DEBUG: Slice 1 AR entry point — verification only (no ball,
            // no hole, no stroke integration). Will move to a proper
            // result-panel button once Slice 4 lands.
            VStack(spacing: 2) {
                Button {
                    showARScanningTest = true
                } label: {
                    Text("DEBUG · AR scanning test (Slice 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .fullScreenCover(isPresented: $showARScanningTest) {
                    ARScanningView()
                }
                Button {
                    showARPlacementTest = true
                } label: {
                    Text("DEBUG · AR placement test (Slice 2)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .fullScreenCover(isPresented: $showARPlacementTest) {
                    ARPlacementView()
                }
            }
            .padding(.bottom, 16)
            .accessibilityLabel("Done. Continue to next stroke.")
        }
    }

    @ViewBuilder
    private func judgmentButton(
        label: String,
        systemImage: String,
        tint: Color,
        judgment: PracticeSessionViewModel.ImpactJudgment
    ) -> some View {
        let isSelected = viewModel.pendingImpactJudgment == judgment.rawValue
        Button {
            viewModel.setImpactJudgment(judgment)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? tint.opacity(0.22) : Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? tint : .clear, lineWidth: 2)
            )
            .foregroundStyle(isSelected ? tint : .primary)
        }
    }

    private func resultRow(_ label: String, value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline.monospaced())
                .foregroundStyle(tint)
        }
    }
}

private struct BatchTransitionView: View {
    let viewModel: PracticeSessionViewModel

    var body: some View {
        let completed = viewModel.justCompletedBatch
        let next = viewModel.session.currentBatch
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 70))
                .foregroundStyle(.green)
            if let c = completed {
                Text("\(c.displayName.uppercased()) COMPLETE")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("\(c.targetCount) of \(c.targetCount) strokes recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 8)
            VStack(spacing: 6) {
                Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(next.displayName.uppercased())
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(next.intentSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button {
                viewModel.tapContinueFromBatchTransition()
            } label: {
                Text("CONTINUE TO \(next.displayName.uppercased())")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
    }
}

private struct BreakView: View {
    let viewModel: PracticeSessionViewModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
            Text("BREAK TIME")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
            Text("10 minutes recommended")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(viewModel.session.totalStrokesCompleted) of \(viewModel.session.totalTargetStrokes) strokes done")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Put the phone down")
                bullet("Drink water, stretch")
                bullet("Let the phone cool")
            }
            .padding(.top, 16)
            Spacer()
            Button {
                viewModel.tapReadyAfterBreak()
            } label: {
                Text("I'M READY TO RESUME")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
            Text(text).font(.callout)
        }
    }
}

private struct CompleteView: View {
    let viewModel: PracticeSessionViewModel
    let onOpenHistory: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "trophy.fill")
                .font(.system(size: 86))
                .foregroundStyle(.green)
            Text("SESSION COMPLETE")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            Text("\(viewModel.session.totalStrokesCompleted) of \(viewModel.session.totalTargetStrokes) strokes recorded")
                .font(.headline)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("EXPORT YOUR DATA")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                exportStep(1, "Open the Files app on this iPhone")
                exportStep(2, "Go to On My iPhone -> PuttingLab -> StrokeReplays")
                exportStep(3, "Long-press a file -> Select All -> Share -> Save to Drive")
                if viewModel.replaySaveFailureCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(viewModel.replaySaveFailureCount) replay(s) failed to save and will not be in the folder.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)

            Spacer()

            HStack(spacing: 12) {
                Button(action: onOpenHistory) {
                    Text("VIEW HISTORY")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                Button(action: onRestart) {
                    Text("RESTART")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.red, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func exportStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n).")
                .font(.callout.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(.callout)
        }
    }
}

