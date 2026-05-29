# Pre-TestFlight Audit — Consolidated Findings (2026-05-29 evening)

Sourced from 9 parallel skill-vs-code subagent audits + 1 reference-repo crib study.
Sorted by severity. Pre-fix for tomorrow's TestFlight push.

---

## SHIP-BLOCKERS (must fix tonight)

### B1 — CoreMotion reference frame: no fallback chain
**File:** `PuttingLab/Sensors/MotionManager.swift:75`

`startDeviceMotionUpdates(using: .xMagneticNorthZVertical, ...)` hardcoded. If
the magnetometer is uncalibrated or interfered with (steel rebar, AirPods case,
MagSafe, fluorescent lights), `motion=nil` is delivered forever — silent sensor
failure. Real-device TestFlight venue almost certainly hits this.

**Fix pattern (from core-motion skill §Setup):**
```swift
let frames = CMMotionManager.availableAttitudeReferenceFrames()
let chosen: CMAttitudeReferenceFrame
if frames.contains(.xMagneticNorthZVertical) {
    chosen = .xMagneticNorthZVertical
} else if frames.contains(.xArbitraryCorrectedZVertical) {
    chosen = .xArbitraryCorrectedZVertical
} else {
    chosen = .xArbitraryZVertical
}
manager.startDeviceMotionUpdates(using: chosen, to: queue) { ... }
```

### B2 — Motion permission denied = invisible failure
**File:** `PuttingLab/Sensors/MotionManager.swift:55-58`

`isDeviceMotionAvailable` returns `true` even when motion permission is denied.
`startDeviceMotionUpdates` then silently produces 0 samples. UI shows "Samples: 0"
with no explanation.

**Fix:** Add `CMMotionManager.authorizationStatus()` check before start; surface
denied state as a banner with "Open Settings" link (parallel to existing camera banner).

### B3 — Vague NSMotionUsageDescription (Apple 5.1.1 rejection)
**File:** `PuttingLab/Info.plist:40-41`

Current: "PuttingLab reads motion data from your iPhone's sensors to detect your swing."
Apple flags vague strings.

**Fix:** "PuttingLab reads your iPhone's gyroscope and accelerometer to measure
your putting stroke tempo, face angle, and impact. All data stays on your device."

### B4 — NSCameraUsageDescription doesn't match what camera does
**File:** `PuttingLab/Info.plist:38-39`

Says "for AR tracking to anchor your putting line" but there's no AR camera preview.
Reviewer will look for AR overlay, find none, flag mismatch.

**Fix:** "PuttingLab uses the rear camera to track which direction your phone is
aimed (via ARKit world tracking) so it can measure your putter face angle. Camera
images are processed on-device and never recorded, saved, or uploaded."

### B5 — Missing FileTimestamp privacy manifest declaration
**File:** `PuttingLab/Resources/PrivacyInfo.xcprivacy`

`StrokeReplay.swift:166` uses `contentsOfDirectory(at:, includingPropertiesForKeys: [.creationDateKey], ...)`
which triggers Apple's File Timestamp required-reason API. Missing declaration =
ITMS warning + privacy-manifest rejection at upload.

**Fix:** Add entry:
```xml
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPIReasons</key>
    <array><string>C617.1</string></array>
</dict>
```

### B6 — StrokeReplay: no schemaVersion field
**File:** `PuttingLab/Models/StrokeReplay.swift:7`

Tomorrow's tester JSONs are unversioned. Once v1.1 adds any field, decode will
fail with missing-key crash unless we retrofit. Future-incompatibility lock-in.

**Fix:** Add `let schemaVersion: Int = 1` to `StrokeReplay`, decode via
`decodeIfPresent ?? 1` so v1 files still load forever.

### B7 — StrokeReplay: no bounds-checking on serialized arrays
**File:** `PuttingLab/Models/StrokeReplay.swift:89-97`

`s.rotationRate[0]`, `s.attitude[3]` in `toStrokeWindow()` — index out of range crash
if a tester edits a JSON or a future version emits shorter arrays.

**Fix:** Validate `count == 3` (or 4) in `init(from:)` and throw
`DecodingError.dataCorrupted`, or fall back to zero vector.

### B8 — StrokeReplay: no NaN/Inf encoder strategy
**File:** `PuttingLab/Models/StrokeReplay.swift:142-145`

CoreMotion legitimately emits NaN during bad sensor fixes. `JSONEncoder` throws
`EncodingError.invalidValue` on NaN → save crashes → tester loses the stroke
they just captured.

**Fix:**
```swift
encoder.nonConformingFloatEncodingStrategy =
    .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
// matching strategy on the decoder at line 153
```

---

## HIGH-RISK (fix tonight if budget allows)

### H1 — scenePhase `.inactive` kills sensors mid-stroke
**File:** `PuttingLab/UI/SensorDebugView.swift:308-321`

Every Control Center pull / incoming-call banner / app-switcher peek fires
`.inactive` which stops sensors. Re-start on `.active` causes 100ms-200ms gap +
stillness reset + lost stroke. **Fix:** gate stop on `.background` only.

### H2 — Synchronous JSONEncoder + write on MainActor per stroke
**Files:** `SensorDebugView.swift:173`, `StrokeReplay.swift:save()`

Janks UI ~5-15ms per stroke on iPhone 12. **Fix:** detach the save:
`Task.detached(priority: .utility) { try? store.save(replay) }`. Drop
`.prettyPrinted` to halve the time.

### H3 — Camera permission banner doesn't re-check on return-from-Settings
**File:** `PuttingLab/UI/SensorDebugView.swift:393-435`

Tester grants in Settings → returns to app → banner stays red until app killed.
**Fix:** re-query in `scenePhase == .active`.

### H4 — viewModel.start() called twice = errorText overwrite
**File:** `PuttingLab/UI/SensorDebugView.swift:308-321`

`.task` runs once + `.active → start()` races. Second `motion.start()` throws
`.alreadyRunning` and stashes an error banner spuriously. **Fix:** guard at
top of start(): `if motion.isRunning { return }`.

### H5 — No compass+IMU fallback when camera denied
**File:** various

Spec says: app must function read-only-of-motion if user denies camera. Currently
it just shows a red "open Settings" banner. **Fix:** allow stroke capture via
compass yaw alone when AR not available (degraded mode).

### H6 — Performance tests use wall-clock Date()
**Files:** `PuttingLabTests/Sensors/*`, `Physics/ImpactDetectorTests.swift:296`

CI under load = flake. **Fix:** replace with `@Test(.timeLimit(.seconds(1)))` trait.

### H7 — UserDefaults shared across parallel test runs
**Files:** `PuttingLabTests/Storage/StorageTests.swift`, `Calibration/CalibrationTests.swift`

UUID-keyed so collision unlikely, but pollutes real plist. **Fix:**
`UserDefaults(suiteName: UUID().uuidString)` per test.

### H8 — `.arkitLost` test case silently returns early
**File:** `PuttingLabTests/Integration/InvariantTests.swift:42-67`

Hides a real coverage gap. **Fix:** wrap with `withKnownIssue` + TODO comment.

### H9 — Decoders missing date strategy in StrokeHistoryStore + ProfileStore
**Files:** `Storage/StrokeHistoryStore.swift:29-31`, `Storage/ProfileStore.swift:26,36`

Cross-store JSON not compatible. **Fix:** set `.iso8601` explicitly on both
encoder + decoder in all 3 stores.

---

## MEDIUM / LOW (defer to post-TestFlight or v1.1)

- ms1: `MotionSample.isVertical` dead computed property using wrong threshold (trap for future devs)
- ms2: No haptic at impact-detection moment (only at stillness lock)
- ms3: Stillness + phase badge transitions instant (no animation)
- ms4: Apple Watch ring-buffer pattern (not needed — our 2s cutoff already bounds buffer)
- ms5: snapReason encoded as String, not Codable enum (lossy round-trip)
- ms6: `StrokeReplayStore.list()` requests `.creationDateKey` resource key but never uses it (dead code)
- ms7: 2 accessibility labels missing on icon-only buttons in ReplayHistoryView (App Store v1.0 rejection risk)
- ms8: Some hard-coded `font(.system(size:))` ignoring Dynamic Type
- ms9: No `.tags()` on tests (debugging filter ergonomics)
- ms10: ARKit-Sampler crib — gate `StrokeDetector.arm()` on `ARTrackingState == .normal` + "relocating" toast
- ms11: PyojinKim crib — `UIApplication.shared.isIdleTimerDisabled = true` while session active
- ms12: hyb crib — write `tools/puttinglab/replay_viz.py` for offline JSON analysis tomorrow

---

## NOT-A-BUG (false-flags, no action needed)

These were flagged in the audits but are already correct or intentional:
- NSLock + `*Locked` private helper pattern (Cycle 6 fix correctly applied)
- AsyncStream `.unbounded` buffering (intentional, Cycle 5)
- `@unchecked Sendable` on lock-protected store classes (correct given internal lock)
- SwiftUI `@State / @AppStorage / @Observable` patterns (textbook)
- App icon 1024×1024 RGB no-alpha (Apple-compliant)
- iPhone-only `TARGETED_DEVICE_FAMILY: "1"` (no iPad screenshot req)
- ITSAppUsesNonExemptEncryption=false (correct declaration)

---

## "Sensor Debug" naming concern — context-dependent

Multiple audits flagged the literal "Sensor Debug" title + "Reset onboarding" button
as Apple Guideline 2.1 (App Completeness) rejection risks.

**Tomorrow's plan: INTERNAL TestFlight only (you + Apple ID).** Internal TestFlight
skips Apple review entirely. The naming concerns ONLY apply to:
- External TestFlight (≥1 external tester) — triggers Beta App Review
- Any App Store submission

For tomorrow's signed upload: **NO ACTION NEEDED.** For first external TestFlight
push: rename "Sensor Debug" → "PuttingLab", hide "Reset onboarding" behind
`#if DEBUG`, polish the result panel.

---

## Counts

| Severity | Count | Budget impact |
|---|---|---|
| SHIP-BLOCKER (B1-B8) | 8 | Must fix tonight |
| HIGH-RISK (H1-H9) | 9 | Fix tonight if commit budget allows |
| MEDIUM/LOW | 12 | Defer |
| NOT-A-BUG | 7 | No action |

Total findings: 36. Fixable in 1 focused commit if scoped tightly.
