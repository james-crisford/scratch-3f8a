import SwiftUI

/// Reminder card shown for the first 2 strokes of each new batch.
///
/// Intentionally describes the TWO-POSE FLOW without prescribing a specific
/// phone orientation — the user holds the phone in their own natural putting
/// grip, whatever that is for them. The algorithm calibrates "0° face" from
/// whatever orientation the phone is in at touch-down.
struct PhoneHoldVisual: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Two-pose flow")
                    .font(.subheadline.weight(.bold))
            }
            VStack(alignment: .leading, spacing: 8) {
                poseRow(
                    icon: "iphone.gen3",
                    title: "Reading pose",
                    detail: "Hold the phone however you'd normally look at it."
                )
                poseRow(
                    icon: "figure.golf",
                    title: "Putting pose",
                    detail: "Your natural putting grip — however you'd actually hold a putter handle."
                )
                poseRow(
                    icon: "hand.tap.fill",
                    title: "Press in putting pose",
                    detail: "The moment you press = your address. Don't change grip after that."
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.thinMaterial)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Two-pose flow: hold the phone naturally to read, transition to your putting grip when ready, then press the screen at takeaway."
        )
    }

    private func poseRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
