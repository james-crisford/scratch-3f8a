import SwiftUI
import UIKit
import AVFoundation

@MainActor
@Observable
final class SensorDebugViewModel {
    var latestSample: MotionSample?
    var sampleCount: Int = 0
    var measuredHz: Double = 0
    var errorText: String?
    var arkitYaw: Double?
    var arkitState: ARTrackingState = .notAvailable
    var arkitErrorText: String?
    var stillnessLocked: Bool = false
    var lastLock: StillnessLock?
    var strokePhase: StrokeDetectorPhase = .idle
    var lastStrokeSampleCount: Int = 0
    var lastImpactResult: ImpactResult?
    var lastSnapReason: SnapReason?
    var coordinatorPhase: PhaseState = .arm

    private let motion: MotionStreaming
    private let arkit: ARTracking
    private let stillness: StillnessDetector
    private let stroke: StrokeDetector
    private let coordinator: SessionCoordinator
    private let onLockHaptic: @MainActor () -> Void
    private var startedAt: TimeInterval?
    private var firstSampleAt: TimeInterval?
    private var lastReportAt: TimeInterval?
    private var samplesSinceLastReport: Int = 0
    private var arkitPollTask: Task<Void, Never>?
    private var motionConsumerTask: Task<Void, Never>?

    init(
        motion: MotionStreaming = MotionManager(),
        arkit: ARTracking = ARTrackingManager(),
        stillness: StillnessDetector = StillnessDetector(),
        stroke: StrokeDetector = StrokeDetector(),
        onLockHaptic: @escaping @MainActor () -> Void = SensorDebugViewModel.defaultHaptic
    ) {
        self.motion = motion
        self.arkit = arkit
        self.stillness = stillness
        self.stroke = stroke
        self.onLockHaptic = onLockHaptic
        // SessionCoordinator runs in parallel using the same arkit instance so the on-device
        // view can show real impact results, phase, and snap reasons — not just sensor-debug
        // numbers. Uses NoopMotion because the view model manages the motion stream itself
        // and forwards samples to coordinator.handle() in handle(_:).
        self.coordinator = SessionCoordinator(
            motion: SensorDebugViewModel.NoopMotion(),
            arkit: arkit,
            onLockHaptic: onLockHaptic
        )
    }

    fileprivate final class NoopMotion: MotionStreaming, @unchecked Sendable {
        var isRunning: Bool = false
        var latestSample: MotionSample?
        func start() throws -> AsyncStream<MotionSample> {
            isRunning = true
            return AsyncStream<MotionSample> { $0.finish() }
        }
        func stop() { isRunning = false }
    }

    @MainActor
    static func defaultHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }

    func start() {
        // H4 guard: `.task { start() }` + scenePhase `.active → start()` can race on
        // first appear, double-starting motion which throws `alreadyRunning` and stashes
        // a spurious red error banner. Skip if already running.
        if motion.isRunning { return }

        sampleCount = 0
        measuredHz = 0
        errorText = nil
        arkitErrorText = nil
        arkitYaw = nil
        arkitState = .notAvailable
        stillnessLocked = false
        lastLock = nil
        stillness.reset()
        stroke.reset()
        strokePhase = .idle
        lastStrokeSampleCount = 0
        startedAt = SensorClock.now()
        firstSampleAt = nil
        lastReportAt = nil
        samplesSinceLastReport = 0

        // Cancel any consumer task left over from a previous start() — view re-appearance
        // via .task modifier can re-invoke start() without an intervening stop().
        motionConsumerTask?.cancel()
        motionConsumerTask = nil
        do {
            let stream = try motion.start()
            motionConsumerTask = Task { @MainActor [weak self] in
                for await sample in stream {
                    self?.handle(sample)
                }
            }
        } catch {
            errorText = String(describing: error)
        }

        do {
            try arkit.start()
            startARKitPolling()
        } catch {
            arkitErrorText = String(describing: error)
        }
    }

    func stop() {
        motion.stop()
        arkit.stop()
        arkitPollTask?.cancel()
        arkitPollTask = nil
        motionConsumerTask?.cancel()
        motionConsumerTask = nil
    }

    private func startARKitPolling() {
        arkitPollTask?.cancel()
        let tracker = arkit
        arkitPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.arkitYaw = tracker.attitudeYaw()
                self?.arkitState = tracker.trackingState
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func handle(_ sample: MotionSample) {
        latestSample = sample
        sampleCount += 1
        if firstSampleAt == nil { firstSampleAt = SensorClock.now() }

        samplesSinceLastReport += 1
        let now = SensorClock.now()
        if let last = lastReportAt {
            let elapsed = now - last
            if elapsed >= 1.0 {
                measuredHz = Double(samplesSinceLastReport) / elapsed
                samplesSinceLastReport = 0
                lastReportAt = now
            }
        } else {
            lastReportAt = now
        }

        if let lock = stillness.consume(sample) {
            stillnessLocked = true
            lastLock = lock
            onLockHaptic()
            try? stroke.arm(with: lock)
        } else if !stillness.isAccumulating && stillnessLocked {
            stillnessLocked = false
        }

        let window = stroke.consume(sample)
        strokePhase = stroke.phase
        if let w = window {
            lastStrokeSampleCount = w.samples.count
        }

        // Forward the same sample to the SessionCoordinator so the on-device view shows
        // the full algorithm output (impact result, snap reason, phase machine).
        coordinator.handle(sample)
        lastImpactResult = coordinator.lastImpactResult
        lastSnapReason = coordinator.lastSnapReason
        coordinatorPhase = coordinator.phase
    }
}

struct SensorDebugView: View {
    @State private var viewModel = SensorDebugViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var showHistory: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            sensorBody
            CameraPermissionBanner()
            if !hasSeenOnboarding {
                OnboardingOverlay { hasSeenOnboarding = true }
            }
        }
    }

    private var sensorBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.debugTitle)
                .font(.title2.bold())

            if let err = viewModel.errorText {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                metric(Strings.metricSamples, value: "\(viewModel.sampleCount)")
                metric(Strings.metricHz, value: String(format: "%.1f", viewModel.measuredHz))
            }

            if let s = viewModel.latestSample {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.sectionLatestSample).font(.headline)
                    rowVector(Strings.rowRotation, vec: s.rotationRate)
                    rowVector(Strings.rowAccel, vec: s.userAcceleration)
                    rowVector(Strings.rowGravity, vec: s.gravity)
                    row(Strings.rowVertical, value: s.isVertical ? "yes" : "no")
                }
            }

            HStack {
                Text(viewModel.stillnessLocked ? Strings.aimedYes : Strings.aimedNo)
                    .font(.headline)
                    .foregroundStyle(viewModel.stillnessLocked ? .green : .secondary)
                Spacer()
                if let lock = viewModel.lastLock {
                    Text(String(format: "yaw₀ %+.3f", lock.yawTargetCompass))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(strokeBadgeLabel(viewModel.strokePhase))
                    .font(.headline)
                    .foregroundStyle(strokeBadgeColor(viewModel.strokePhase))
                Spacer()
                if viewModel.lastStrokeSampleCount > 0 {
                    Text("\(viewModel.lastStrokeSampleCount) samples")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let r = viewModel.lastImpactResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Impact result")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    if r.snappedToSquare {
                        row("face", value: "Square (snapped)")
                        if let reason = r.snapReason {
                            row("reason", value: String(describing: reason))
                        }
                    } else {
                        row("face", value: String(format: "%+.2f°", r.faceAngleDegrees))
                    }
                    row("peak vel", value: String(format: "%.2f m/s", r.peakVelocity))
                    row("confidence", value: String(format: "%.2f", r.confidence))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.sectionARKit).font(.headline)
                row(Strings.rowARKitState, value: arkitStateLabel(viewModel.arkitState))
                row(
                    Strings.rowARKitYaw,
                    value: viewModel.arkitYaw.map { String(format: "%+.3f rad", $0) } ?? "—"
                )
                if let err = viewModel.arkitErrorText {
                    Text(err)
                        .foregroundStyle(.orange)
                        .font(.system(.caption, design: .monospaced))
                }
            }

            Spacer()

            HStack {
                Text(versionString())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("History") {
                    showHistory = true
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Button("Reset onboarding") {
                    hasSeenOnboarding = false
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .font(.system(.body, design: .monospaced))
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .sheet(isPresented: $showHistory) {
            ReplayHistoryView()
        }
        .onChange(of: scenePhase) { _, phase in
            // KI-12 / C5 finding: pause sensors when backgrounded; resume on return.
            // H1: gate stop on `.background` ONLY — `.inactive` fires on transient events
            // (Control Center pull-down, incoming-call banner, app switcher peek). Stopping
            // on `.inactive` killed sensors mid-stroke during testing because every
            // notification reset the stillness window. The OS pauses the app's run loop on
            // `.background` anyway, so the lost-coverage window is unchanged.
            switch phase {
            case .active:
                viewModel.start()
            case .background:
                viewModel.stop()
            case .inactive:
                break  // transient — let sensors keep running
            @unknown default:
                break
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowVector(_ label: String, vec: SIMD3<Double>) -> some View {
        row(
            label,
            value: String(
                format: "[%+.3f, %+.3f, %+.3f]",
                vec.x, vec.y, vec.z
            )
        )
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func strokeBadgeLabel(_ phase: StrokeDetectorPhase) -> String {
        switch phase {
        case .idle: return "stroke: idle"
        case .armed: return "stroke: ARMED"
        case .starting: return "stroke: starting…"
        case .recording: return "stroke: STROKE"
        case .ended: return "stroke: DONE"
        }
    }

    private func strokeBadgeColor(_ phase: StrokeDetectorPhase) -> Color {
        switch phase {
        case .idle: return .secondary
        case .armed: return .blue
        case .starting: return .orange
        case .recording: return .red
        case .ended: return .green
        }
    }

    private func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private func arkitStateLabel(_ state: ARTrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "n/a"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited:init"
            case .excessiveMotion: return "limited:motion"
            case .insufficientFeatures: return "limited:features"
            case .relocalizing: return "limited:reloc"
            case .unknown: return "limited:?"
            }
        }
    }
}

private struct CameraPermissionBanner: View {
    @State private var status: AVAuthorizationStatus = .notDetermined

    var body: some View {
        Group {
            if status == .denied || status == .restricted {
                VStack(spacing: 8) {
                    Text("Camera access required")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("PuttingLab needs the camera for AR tracking. Open Settings to grant access.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red)
                .cornerRadius(12)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .task {
            status = AVCaptureDevice.authorizationStatus(for: .video)
            // Trigger initial permission prompt if undetermined.
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

private struct OnboardingOverlay: View {
    let onDismiss: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("PuttingLab")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                Text("Sensor harness build — TestFlight preview")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 14) {
                    bullet("1. Grant camera permission (needed for AR yaw)")
                    bullet("2. Hold the phone in your natural putting grip — both hands, like a putter")
                    bullet("3. Stay still ~1s → \"Aimed ✓\" + a haptic tap")
                    bullet("4. Make a putting motion → STROKE → DONE")
                    bullet("5. Watch sensor numbers tick at ~100 Hz")
                }
                .foregroundStyle(.white)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 24)
                Text("Not the final game. Sensor + algorithm verification only.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Button(action: onDismiss) {
                    Text("Got it — start putting")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
            }
            .padding(32)
        }
    }
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(.body, design: .rounded))
        }
    }
}

private enum Strings {
    static let debugTitle = "Sensor Debug"
    static let metricSamples = "Samples"
    static let metricHz = "Hz (1s)"
    static let sectionLatestSample = "Latest"
    static let rowRotation = "rotation"
    static let rowAccel = "accel"
    static let rowGravity = "gravity"
    static let rowVertical = "vertical"
    static let sectionARKit = "ARKit"
    static let rowARKitState = "state"
    static let rowARKitYaw = "yaw"
    static let aimedYes = "Aimed ✓"
    static let aimedNo = "Aim — hold still"
}
