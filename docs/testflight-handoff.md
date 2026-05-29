# TestFlight handoff — what your mate needs to do

## Status

Algorithmic core: **300+ tests green, 5 cycles of break-fix-break done.** Ready for first device contact.

Infrastructure: **3 showstoppers before App Store Connect upload will accept the IPA.** Your mate handles these from his Mac.

## Showstoppers (must do before first upload)

### 1. App icon (Apple rejects builds without one)
- Create `PuttingLab/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` + a 1024×1024 PNG
- Add `Assets.xcassets` to `project.yml` `sources` for the PuttingLab target
- Add `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` to target build settings
- A placeholder icon is fine — solid color + "PL" works for TestFlight

### 2. Code signing
- In `project.yml`, the PuttingLab target has `CODE_SIGNING_ALLOWED: NO` — REMOVE that line for the app target (keep on PuttingLabTests)
- Your mate's Apple Developer Team ID goes in `DEVELOPMENT_TEAM`
- Bundle ID `com.puttinglab.app` may already be taken — pick something like `com.YOURMATE.puttinglab` and register in his developer portal

### 3. Archive + upload from his Mac
- Pull the repo on his Mac
- `xcodegen generate`
- Open in Xcode 16
- Product → Archive → Distribute App → App Store Connect → Upload
- Wait ~10 min for TestFlight to process
- Add you as Internal Tester via App Store Connect → TestFlight → People

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
