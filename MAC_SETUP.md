# Mac setup — one-time, ~10 minutes

The project source lives in this folder. Xcode generates its own `.xcodeproj`, so you create the project on the Mac and drag the source folders into it.

## Prerequisites

- macOS 14.5+ with **Xcode 16+** installed (Swift 6 + iOS 17 SDK)
- Your iPhone (any model from iPhone 12 onward — research-confirmed target)
- Apple ID signed in to Xcode (free 7-day signing fine for personal install; paid Developer account needed later for TestFlight)

## Steps

### 1. Create the Xcode project (3 min)

1. Xcode → **File → New → Project…**
2. iOS → **App** → Next.
3. Fill in:
   - **Product Name:** `PuttingLab`
   - **Team:** your Apple ID
   - **Organization Identifier:** `com.puttinglab` (or whatever you want)
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Storage:** None
   - **Include Tests:** YES (check this box)
4. Save the project at **the same folder as this file** (`projects/PuttingLab/`) — Xcode will create `PuttingLab.xcodeproj` here. **When prompted to overwrite the existing `PuttingLab/` folder, choose "Replace"** — Xcode will preserve the contents we wrote.

### 2. Set deployment target

1. Click the project root (top-left blue icon) → PuttingLab target → **General** tab.
2. **Minimum Deployments → iOS:** set to **17.0**.

### 3. Use the Info.plist we wrote

1. In the target's **Info** tab, replace the default with the contents from `PuttingLab/Info.plist` (or use **Build Settings → Packaging → Info.plist File** = `PuttingLab/Info.plist`).
2. Confirm `NSMotionUsageDescription` and `NSCameraUsageDescription` are present.

### 4. Drag source folders into Xcode (2 min)

In Finder, drag each of these folders from `projects/PuttingLab/PuttingLab/` into the Xcode project navigator (left sidebar), choosing **"Create groups"** (NOT "Create folder references") and adding to the **PuttingLab** target:

- `App/`
- `Models/`
- `Sensors/`
- `UI/`

(Other folders — `Physics/`, `Calibration/`, `Storage/`, `Resources/` — are empty for now; they'll fill on later days.)

### 5. Drag test folders in (1 min)

From `projects/PuttingLab/PuttingLabTests/`, drag these into the test target:

- `Models/`
- `Sensors/`

Make sure each is added to the **PuttingLabTests** target only (not the main app target).

### 6. Confirm Swift Testing is on

Test target → **Build Settings** → search "Testing System" → ensure **`SWIFT_VERSION` ≥ 6.0**. Swift Testing ships with Xcode 16; no extra dependency.

### 7. Run the tests

`Cmd-U` to run all tests. **Expected: 17 tests passing** (StrokeBuffer × 7, MotionManager × 7, MotionSample × 3 — see Day 1 deliverables).

If anything fails, paste the failure output back to me here.

### 8. Run on your iPhone

1. Plug the phone in. In Xcode toolbar, select your phone as the destination.
2. First-time signing: Xcode → Settings → Accounts → confirm Apple ID. The target's **Signing & Capabilities** → tick **Automatically manage signing**.
3. `Cmd-R` to build and run.
4. iOS will prompt to trust the developer profile (Settings → General → VPN & Device Management). Tap trust.
5. The **Sensor Debug** screen should appear, showing live `rotation / accel / gravity` vectors, a sample count climbing fast, and **Hz settling near 100**.

### 9. Day 1 device test checklist

In the **Sensor Debug** view on your iPhone:

- [ ] Sample count increases continuously when the app is foreground.
- [ ] Measured Hz reads **95–105** when phone is still on a table.
- [ ] Rotating the phone changes the `rotation` row in real time.
- [ ] Moving the phone (gently) changes the `accel` row.
- [ ] Holding the phone vertically shows `gravity` close to `[0, -1, 0]` and `vertical: yes`.
- [ ] Holding the phone flat shows `vertical: no`.
- [ ] Background the app, foreground again — stream resumes within 1s.

If all 7 pass, **Day 1 is green**. Report back with anything failing.

---

## Subsequent days

Days 2-14 each ship more source files into the existing project. You only need to repeat steps 4-5 (drag new folders/files in) when new source appears. The test runner + device deploy flow stays the same.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No such module 'CoreMotion'" | You're building for macOS — change destination to iOS Simulator or your iPhone. |
| Tests time out | Re-check Swift Testing is active (`SWIFT_VERSION 6.0+`). |
| Provisioning profile error | Xcode → Settings → Accounts → re-sign in. |
| Sensor Hz stays at 0 on device | `NSMotionUsageDescription` missing from Info.plist. |
| Sample count stuck | App may be backgrounded — iOS pauses sensor streams in background by design. |
