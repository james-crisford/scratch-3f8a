import SwiftUI
import UIKit

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

    private let motion: MotionStreaming
    private let arkit: ARTracking
    private let stillness: StillnessDetector
    private let stroke: StrokeDetector
    private let onLockHaptic: @MainActor () -> Void
    private var startedAt: TimeInterval?
    private var firstSampleAt: TimeInterval?
    private var lastReportAt: TimeInterval?
    private var samplesSinceLastReport: Int = 0
    private var arkitPollTask: Task<Void, Never>?

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
    }

    @MainActor
    static func defaultHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }

    func start() {
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

        do {
            try motion.start { [weak self] sample in
                Task { @MainActor in
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
    }
}

struct SensorDebugView: View {
    @State private var viewModel = SensorDebugViewModel()

    var body: some View {
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
        }
        .padding()
        .font(.system(.body, design: .monospaced))
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
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
