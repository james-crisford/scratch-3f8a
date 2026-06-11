import SwiftUI

/// B78 — collects the user-declared inputs that drive stance geometry.
/// Height (cm) and handedness are the only fields for v1. The sheet is
/// presented from the AR view's gear button. On save it returns the updated
/// `UserProfile` to the caller, which is responsible for persisting + re-
/// rendering anything that depends on it (currently just the foot markers).
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var heightCm: Double
    @State private var handedness: UserProfile.Handedness

    let onSave: (UserProfile) -> Void

    init(profile: UserProfile, onSave: @escaping (UserProfile) -> Void) {
        _heightCm = State(initialValue: profile.heightCm)
        _handedness = State(initialValue: profile.handedness)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Height")
                        Spacer()
                        Text("\(Int(heightCm.rounded())) cm")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $heightCm, in: 140...210, step: 1) {
                        Text("Height")
                    } minimumValueLabel: {
                        Text("140")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("210")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("settings.heightSlider")
                } header: {
                    Text("Height")
                } footer: {
                    Text("Used to size the address foot markers to your shoulder width. Stays on this device.")
                }

                Section {
                    Picker("Handedness", selection: $handedness) {
                        Text("Right").tag(UserProfile.Handedness.right)
                        Text("Left").tag(UserProfile.Handedness.left)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.handednessPicker")
                } header: {
                    Text("Putting hand")
                } footer: {
                    // B80 — handedness now drives which side of the line
                    // the foot markers go (mirrored for lefties). Stay
                    // honest about what it does NOT yet drive: the
                    // pull/push wording is right-handed golf language
                    // (a left-hander's pull goes right of the line), and
                    // the left-handed stance mirror hasn't been validated
                    // on-device by a left-handed tester yet.
                    Text("Places the foot markers on your side of the line. Pull/push wording is still described right-handed.")
                }

                Section {
                    let preview = StanceGeometry.compute(
                        profile: UserProfile(heightCm: heightCm, handedness: handedness)
                    )
                    HStack {
                        Text("Shoulder width")
                        Spacer()
                        Text(String(format: "%.1f cm", preview.shoulderWidthMetres * 100.0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Foot spread (each side)")
                        Spacer()
                        Text(String(format: "%.1f cm", preview.footHalfSpreadMetres * 100.0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Stance setback from line")
                        Spacer()
                        Text(String(format: "%.1f cm", preview.setbackMetres * 100.0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Bideltoid (outer-shoulder-to-outer-shoulder) ≈ 0.245 × height (ANSUR II adult median). Setback = putter-lie hand offset + eyes-over-ball posture.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("settings.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(UserProfile(heightCm: heightCm, handedness: handedness))
                        dismiss()
                    }
                    .bold()
                    .accessibilityIdentifier("settings.saveButton")
                }
            }
        }
    }
}
