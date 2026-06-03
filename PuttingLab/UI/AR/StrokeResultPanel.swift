import SwiftUI
import simd

/// Result card shown after the ball rolls to a stop. Stage 3
/// Slice 3.5 (B50). Slides up from the bottom of the AR view,
/// shows distance / face angle / Mario Kart bucket / outcome,
/// auto-dismisses after `autoDismissAfter` seconds.
///
/// The panel itself is purely presentational — it consumes a
/// `StrokeResultViewModel` and renders. Action callbacks (Putt
/// again, Reset all) are surfaced through closures the parent
/// View binds to its existing handlers.
struct StrokeResultPanel: View {
    let viewModel: StrokeResultViewModel
    let onPuttAgain: () -> Void
    let onResetAll: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — outcome verdict + Mario Kart bucket pill.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(viewModel.outcomeHeadline)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(viewModel.outcomeTint)
                Spacer()
                Text(viewModel.bucketLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(viewModel.bucketTint.opacity(0.85),
                                in: Capsule())
                    .foregroundStyle(.white)
            }

            // Metric grid — distance + face angle.
            HStack(alignment: .top, spacing: 16) {
                metric(title: "DISTANCE",
                       primary: viewModel.distancePrimary,
                       secondary: viewModel.distanceSecondary,
                       tint: viewModel.distanceTint)
                metric(title: "FACE",
                       primary: viewModel.faceAnglePrimary,
                       secondary: viewModel.faceAngleSecondary,
                       tint: viewModel.faceTint)
                metric(title: "PEAK VELOCITY",
                       primary: viewModel.peakVelocityPrimary,
                       secondary: viewModel.peakVelocitySecondary,
                       tint: .white)
            }

            // Cause line — why the bucket call. Quiet text below
            // the metrics so the user can ignore it on a clean
            // putt but read it on a miss.
            Text(viewModel.causeLine)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Action row.
            HStack(spacing: 10) {
                Button(action: onResetAll) {
                    Label("Reset all", systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.result.resetAll")

                Spacer()

                Button(action: onPuttAgain) {
                    Label("Putt again", systemImage: "figure.golf")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.green.opacity(0.95), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.result.puttAgain")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .accessibilityIdentifier("ar.result.panel")
        .task {
            // Auto-dismiss timer per Stage 3 spec clause #5 (6 s).
            try? await Task.sleep(nanoseconds: UInt64(viewModel.autoDismissAfter * 1_000_000_000))
            onDismiss()
        }
    }

    private func metric(title: String,
                         primary: String,
                         secondary: String?,
                         tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(primary)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            if let secondary {
                Text(secondary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Presentation model for `StrokeResultPanel`. Pure value type —
/// the View constructs one from the captured stroke chain
/// (impact, outcome, distances) and hands it to the panel.
struct StrokeResultViewModel: Equatable {
    let distanceMetres: Double
    let distanceFeet: Double
    let faceAngleDeg: Double
    let peakVelocityMps: Double
    let bucketLabel: String
    let bucketTint: Color
    let causeLine: String
    let outcomeHeadline: String
    let outcomeTint: Color
    let autoDismissAfter: Double

    var distancePrimary: String { String(format: "%.2f m", distanceMetres) }
    var distanceSecondary: String? { String(format: "%.1f ft · %@",
                                              distanceFeet,
                                              distanceBucketLabel) }
    var distanceTint: Color {
        switch distanceMetres {
        case ..<3.0:  return .green
        case ..<6.0:  return .orange
        default:      return .red
        }
    }
    var distanceBucketLabel: String {
        switch distanceMetres {
        case ..<3.0:  return "short"
        case ..<6.0:  return "lag"
        default:      return "long"
        }
    }

    var faceAnglePrimary: String {
        String(format: "%@%.1f°", faceAngleDeg >= 0 ? "+" : "", faceAngleDeg)
    }
    var faceAngleSecondary: String? {
        switch abs(faceAngleDeg) {
        case ..<6.0:   return "square"
        case ..<12.0:  return faceAngleDeg < 0 ? "slight pull" : "slight push"
        case ..<20.0:  return faceAngleDeg < 0 ? "pull" : "push"
        default:       return "miss"
        }
    }
    var faceTint: Color {
        switch abs(faceAngleDeg) {
        case ..<6.0:   return .green
        case ..<12.0:  return .yellow
        case ..<20.0:  return .orange
        default:       return .red
        }
    }

    var peakVelocityPrimary: String {
        String(format: "%.2f m/s", peakVelocityMps)
    }
    var peakVelocitySecondary: String? {
        String(format: "%.2f mph", peakVelocityMps * 2.23694)
    }
}
