import SwiftUI
import UIKit

/// Root view of the 100-stroke guided session.
///
/// Switches between six sub-views by `PracticeSessionViewModel.Phase`:
///   - .setup            → SetupPhaseView (waiting for touch-down)
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
            case .background:
                viewModel.stopSession()
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
        case .setup:
            SetupPhaseView(viewModel: viewModel)
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
                if !isPressing && viewModel.phase == .setup {
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

private struct SetupPhaseView: View {
    let viewModel: PracticeSessionViewModel

    var body: some View {
        let batch = viewModel.session.currentBatch
        VStack(spacing: 0) {
            // Top progress is always visible
            ProgressHeader(
                totalDone: viewModel.session.totalStrokesCompleted,
                totalTarget: viewModel.session.totalTargetStrokes,
                currentBatchLabel: batch.displayName.uppercased(),
                inBatchDone: viewModel.session.strokesInCurrentBatch,
                inBatchTarget: batch.targetCount
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Scroll the middle: stroke type + visual + instructions + errors
            // so long instruction lists never get clipped on any iPhone size.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Stroke type
                    VStack(alignment: .leading, spacing: 4) {
                        Text(batch.strokeTypeLabel.uppercased())
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(batch.intentSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Phone-hold visual: shown for first 2 strokes of every new batch.
                    if viewModel.session.strokesInCurrentBatch < 2 {
                        PhoneHoldVisual()
                    }

                    // Instructions
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(batch.instructions.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                Text(line)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Error toast
                    if let err = viewModel.lastError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    // Sensor warnings (small, at the bottom of scroll content)
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

                    // Bottom padding so last instruction line isn't flush
                    // against the bottom prompt.
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 20)
            }

            // Bottom prompt — always visible, never scrolls off
            VStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                Text("TAP & HOLD ANYWHERE")
                    .font(.headline.weight(.bold))
                Text("Press at takeaway · release at end of follow-through")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(Color(.systemBackground))
        }
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
                    resultRow("face",
                              value: r.snappedToSquare
                                ? "Square (snapped)"
                                : String(format: "%+.1f°", r.faceAngleDegrees),
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

            Spacer()

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
            .padding(.bottom, 24)
            .accessibilityLabel("Done. Continue to next stroke.")
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

private struct ProgressHeader: View {
    let totalDone: Int
    let totalTarget: Int
    let currentBatchLabel: String
    let inBatchDone: Int
    let inBatchTarget: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(currentBatchLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(inBatchDone) of \(inBatchTarget)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(totalDone), total: Double(max(totalTarget, 1)))
                .tint(.blue)
            HStack {
                Text("Stroke \(totalDone) of \(totalTarget)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}
