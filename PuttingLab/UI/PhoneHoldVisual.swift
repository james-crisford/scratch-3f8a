import SwiftUI

/// SF Symbol-based illustration of how to hold the phone at the address pose.
/// Shown for the first 2 strokes of each new batch, then hidden.
///
/// Renders three labelled arrows around a vertical-orientation iPhone:
///   - "Screen toward you" — green, exits the front of the device
///   - "Back of phone toward your target" — orange, exits the back
///   - "Hold phone vertical" — grey, runs alongside the device
struct PhoneHoldVisual: View {
    var body: some View {
        HStack(spacing: 28) {
            // Left labels (screen-side)
            VStack(alignment: .trailing, spacing: 6) {
                Spacer()
                Label {
                    Text("Screen toward you")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                } icon: {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.green)
                }
                .labelStyle(.titleAndIcon)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            // Centre: vertical phone
            ZStack {
                Image(systemName: "iphone.gen3")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 160)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                // Tiny vertical indicator
                VStack(spacing: 0) {
                    Image(systemName: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 160)
                .padding(.trailing, 60)
            }
            .frame(maxWidth: .infinity)

            // Right labels (back-side)
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Label {
                    Text("Back of phone toward target")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "arrow.left")
                        .foregroundStyle(.orange)
                }
                .labelStyle(.titleAndIcon)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.thinMaterial)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Hold the phone vertical, screen toward you, back of phone toward your target."
        )
    }
}

