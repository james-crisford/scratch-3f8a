# TestFlight handoff — what your mate needs to do

## Status

Algorithmic core: **311+ tests green, 5 cycles of break-fix-break done.** Ready for first device contact.

Infrastructure: **1 showstopper + 1 sign-step left** before App Store Connect accepts the IPA. Most of the prep is now done.

## Already done (committed)

- ✅ **App icon stub** at `PuttingLab/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (placeholder green/PL — replace with real art when ready)
- ✅ `Assets.xcassets` wired into `project.yml` with `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`
- ✅ `Info.plist` has `ITSAppUsesNonExemptEncryption=false`
- ✅ `PuttingLab/Resources/PrivacyInfo.xcprivacy` present (Apple requires since May 2024)
- ✅ Camera + motion usage descriptions in Info.plist
- ✅ scenePhase lifecycle: sensors pause on background, resume on foreground
- ✅ ARSession interruption delegate handles backgrounding/lock screen cleanly
- ✅ Camera-permission-denied banner with "Open Settings" deep-link
- ✅ First-launch onboarding overlay so testers don't see raw vectors immediately
- ✅ Version + reset-onboarding footer for easy tester feedback
- ✅ CI workflow now produces an unsigned `.xcarchive` artifact on every push to main (run-wise sanity check; signing still needed for actual upload)

## Remaining for your mate

### 1. Code signing (REQUIRED)
- In `project.yml`, the PuttingLab target has `CODE_SIGNING_ALLOWED: NO` — REMOVE that line for the app target (keep on PuttingLabTests).
- Your mate's Apple Developer Team ID goes in `DEVELOPMENT_TEAM`.
- Bundle ID `com.puttinglab.app` may already be taken — pick something like `com.<mate>.puttinglab` and register in his developer portal.

### 2. Archive + upload from his Mac
- Pull the repo on his Mac.
- `xcodegen generate`
- Open in Xcode 16.
- Product → Archive → Distribute App → App Store Connect → Upload.
- Wait ~10 min for TestFlight to process.
- Add you as Internal Tester via App Store Connect → TestFlight → People.

### Optional (replace placeholder icon)
- The committed icon is a green square with "PL" — fine for TestFlight, ugly for App Store.
- Replace `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` with real art before App Store submission.

## Already done (committed to repo)

- **`Info.plist`** has `ITSAppUsesNonExemptEncryption=false` so you don't get prompted on every upload
- **`PuttingLab/Resources/PrivacyInfo.xcprivacy`** ships with minimal declarations (no tracking, no data collection, declares UserDefaults usage)
- **`Info.plist`** has correct camera + motion usage descriptions (Apple shows these as the permission prompts)
- **Bundle structure** is set up for portrait-only iPhone

## What you'll see on first launch

The current build's root view is `SensorDebugView` — raw sensor numbers, ARKit state, stillness/stroke detection badges. NOT the game UI yet (that's Day 11+ of the original spec).

**Brief your mate that this is intentional**: "Sensor harness, not the game. We're verifying the algorithmic plumbing on real device before building the polished UI."

## What to verify on iPhone 13 (algorithmic)

Once installed via TestFlight:

1. **Camera permission prompt** — grant it. Tap Allow.
2. **ARKit reaches `.normal`** — within 2-3 seconds in a textured room. Watch the "state:" line in the debug view.
3. **Hold phone vertically as if gripping a putter, stay still ~1 sec** → "Aimed ✓" badge appears, medium haptic fires.
4. **Make a deliberate putting motion through the air** → "stroke: ARMED → STROKE → DONE" cycle.
5. **Repeat 10 strokes** — note in TestFlight Feedback:
   - Does "Aimed ✓" lock reliably with your natural grip? (If not → known issue KI-5, stillness tolerance)
   - Do strokes consistently make it through STROKE → DONE? (If not → known issue KI-6, calibration brittleness)
   - Does the displayed face angle "feel right" relative to pull/push intent? (KI-1 — sign convention; you'll be the first to verify this)

## Known issues (algorithmic — won't fix until device data)

`docs/known-issues.md` has the full list. The 5 that need YOUR feedback first:

- KI-1: pull/push sign convention (industry vs internal — you decide which way feels right)
- KI-2: velocity[0]=0 assumption (does peak velocity look chronically low?)
- KI-4: compass corruption near steel-shafted putters (only matters if you grip a real putter)
- KI-5: 25° stillness tolerance (might still be too tight or already loose enough)
- KI-6: 5/5 stroke calibration brittleness (was partly addressed with a stalled-hint after 3 rejections)

After 1 day of iPhone use, you should have a clear answer on all 5. Then come back and we tune.

## CI workflow status

`.github/workflows/test.yml` builds + tests for iOS Simulator on `macos-15` runner. Does NOT yet produce an IPA — that step needs to be added once your mate has the signing identity wired. For now, every push tests the simulator and your mate manually archives from Xcode for TestFlight.

If you want the full CI → TestFlight pipeline later, add `fastlane match` + `xcodebuild archive` + `altool upload` steps. ~half-day setup.

## TL;DR for your mate

1. Pull repo on Mac
2. Add an app icon (any 1024×1024 PNG in Assets.xcassets/AppIcon.appiconset)
3. Edit `project.yml`: remove `CODE_SIGNING_ALLOWED: NO` from the PuttingLab target
4. Pick a unique bundle ID
5. `xcodegen generate`, open in Xcode, Archive, upload
6. Add James as Internal Tester via App Store Connect
