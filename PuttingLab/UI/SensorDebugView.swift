import SwiftUI

@MainActor
@Observable
final class SensorDebugViewModel {
    var latestSample: MotionSample?
    var sampleCount: Int = 0
    var measuredHz: Double = 0
    var errorText: String?

    private let motion: MotionStreaming
    private var startedAt: TimeInterval?
    private var firstSampleAt: TimeInterval?
    private var lastReportAt: TimeInterval?
    private var samplesSinceLastReport: Int = 0

    init(motion: MotionStreaming = MotionManager()) {
        self.motion = motion
    }

    func start() {
        sampleCount = 0
        measuredHz = 0
        errorText = nil
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
    }

    func stop() {
        motion.stop()
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
}
