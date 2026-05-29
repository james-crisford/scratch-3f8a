# Testing Plan — Tomorrow (Day Apple Dev Approval Lands)

*Written: 2026-05-29 evening | Status: ready to execute*

This is the full minute-by-minute plan from "Apple Dev approval email lands" → "data
flowing back from your iPhone 13 for me to analyse in the next session."

---

## TL;DR

| Block | Time | What happens |
|---|---|---|
| **A** | 5 min | Sanity-check the build (CI screenshot + run tests) |
| **B** | 15 min | Wire 8 GitHub secrets, push to TestFlight |
| **C** | 10 min | Apple TestFlight processing (you wait) |
| **D** | 30-45 min | 5-stroke calibration + 20-stroke test session on iPhone 13 |
| **E** | 5 min | Export every stroke JSON to Google Drive |
| **F** | next session | I read the JSONs from Drive, analyse, report |

**Total active time:** ~70 minutes. Plus 10 minutes of waiting for Apple.

---

## A. Sanity check the build BEFORE you spend Apple-approval time on it

Run this once tomorrow morning before doing anything else — confirms the
build is healthy and shows you exactly what the app looks like in the
iPhone 16 simulator. Costs ~5 minutes of CI time (uses your £5 budget).

**Steps:**

1. Open `https://github.com/james-crisford/PuttingLab/actions`
2. Click **"Test"** workflow on the left
3. Click **"Run workflow"** dropdown (top right)
4. Leave `release` unchecked → click green **"Run workflow"**
5. Wait ~5 min for it to go green
6. Open the run → scroll to **Artifacts** at the bottom → download **Screenshots**
7. Unzip — you'll see `launch.png` and `launch-clean.png` (status bar fixed at 9:41)

If those screenshots look like a sensor debug view ("Aim: ✓ / Phase: idle / Confidence: -"),
you're good. If they're blank or crash → stop, message me, do NOT proceed to TestFlight.

---

## B. Wire 8 GitHub secrets, trigger TestFlight upload (15 min)

This is the gate. Once these 8 secrets are saved, every future TestFlight push
is one click.

### B.1 — Create signing artefacts in App Store Connect (8 min)

Follow `docs/testflight-secrets-setup.md` end to end. Quick summary of what
that doc walks you through:

| Secret | Where it comes from |
|---|---|
| `SIGNING_CERT_P12_BASE64` | Developer portal → Certificates → iOS Distribution → export as .p12 → `base64 -i cert.p12 \| pbcopy` |
| `SIGNING_CERT_PASSWORD` | The password you set when exporting the .p12 |
| `PROVISIONING_PROFILE_B64` | Developer portal → Profiles → App Store → create, download, base64 |
| `APP_STORE_CONNECT_API_KEY` | App Store Connect → Users & Access → Keys → Generate API Key → download .p8 → base64 |
| `APP_STORE_CONNECT_KEY_ID` | The 10-char ID shown after key creation |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID shown at top of the Keys page |
| `APPLE_TEAM_ID` | Membership page → 10-char Team ID |
| `APP_BUNDLE_ID` | Whatever you pick — I suggest `com.puttinglab.app` (matches project.yml default) |

**You're on Windows so:**
- You don't have `base64 -i` natively. Either:
  - Use PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12")) | Set-Clipboard`
  - Or use the [base64encode.org](https://www.base64encode.org/) web tool (drag-drop the file, copy result)

### B.2 — Save secrets in GitHub (3 min)

1. `https://github.com/james-crisford/PuttingLab/settings/secrets/actions`
2. Click **"New repository secret"** 8 times
3. Each time: name from the table above, value = the base64 / ID

### B.3 — Trigger the signed release (1 min + 8 min processing)

1. Actions tab → **"Test"** workflow → **"Run workflow"**
2. Tick the **release** checkbox → green **"Run workflow"**
3. Wait ~8 min for the build + sign + upload to complete
4. App Store Connect → My Apps → PuttingLab → TestFlight → Builds — your build
   appears as "Processing" for 5-10 min then becomes installable

### B.4 — What can go wrong (and what to do)

| Symptom | Fix |
|---|---|
| `code signing identity not found` | Re-export the .p12 from Keychain Access → File → Export Items → .p12; re-base64 |
| `provisioning profile doesn't match` | Profile must be created AFTER the bundle ID is registered; recreate in order |
| `Invalid API authentication` | The .p8 has Windows line endings — open in Notepad++, switch to LF, re-base64 |
| Upload times out | Just re-run the workflow (idempotent); Apple's upload server is flaky |
| Build stuck on "Processing" >30 min | App Store Connect bug; refresh page, sometimes it skips ahead |

If any of these block you → message me, I'll fix the CI workflow and rerun.

---

## C. Install on iPhone 13 via TestFlight (10 min)

1. App Store on iPhone 13 → search "TestFlight" → install if not already
2. Open TestFlight app → sign in with your Apple ID
3. App Store Connect (web) → TestFlight → Internal Testing → "App Store Connect Users"
   group → invite **your own Apple ID email**
4. Email lands → tap "View in TestFlight" → install PuttingLab
5. **Important:** the first time you open the app, iOS will prompt for Motion &
   Fitness permission AND Camera permission. **Accept both** — denying breaks the
   sensor pipeline.

If iOS says "Untrusted Developer" → Settings → General → VPN & Device Management
→ trust your Apple Developer profile.

---

## D. The 30-45 minute test session (the actual work)

Below is the exact script. Have me / Claude on a laptop next to you so you
can copy-paste questions if something behaves weirdly.

### D.1 — Calibration (5 strokes, ~5 min)

1. Open PuttingLab
2. Onboarding overlay appears → tap "Got it"
3. Tap **"Start Calibration"** (or whatever the entry button says)
4. **For each of 5 calibration strokes:**
   - Stand normally, phone in your dominant hand
   - Phone vertical, screen facing you, back camera facing your target
   - Hold still 1 second for auto-lock ("Aim ✓" badge + haptic)
   - Make a natural putting motion through the air
   - The app records and prompts for the next stroke
5. After stroke 5: profile saves to UserDefaults

**What to watch for:**
- Does "Aim ✓" badge appear within 1-2 sec of holding still? (KI-5 verification)
- If it never appears: you've found KI-5 (stillness tolerance too tight)
- If it appears too easily (even when moving): tolerance too loose, log it

### D.2 — 20 test strokes (~20 min)

Do 20 strokes in 4 batches of 5:

**Batch 1 — clean strokes (5 strokes):**
- Stand still, hold still, swing smoothly
- Expected: every result shows a face angle + peak velocity, no "Square" snap
- **If every stroke snaps to Square**: KI-6 brittleness, the model isn't trusting
  your calibrated profile

**Batch 2 — pull strokes (5 strokes):**
- Deliberately close the face on impact (rotate phone slightly left at peak)
- Expected: result panel shows "Pull" / negative face angle
- **If sign is flipped (shows "Push" when you pulled)**: KI-1 verified bug
- **If it always snaps to Square**: confidence too tight

**Batch 3 — push strokes (5 strokes):**
- Deliberately open the face on impact (rotate slightly right)
- Expected: "Push" / positive face angle
- Cross-check with Batch 2 — sign should be opposite

**Batch 4 — edge cases (5 strokes):**
- 1 stroke standing next to a metal radiator/steel filing cabinet
  → tests KI-4 (compass corruption by steel)
- 1 stroke moving slightly while "still" (subtle weight shift)
  → tests KI-5 again
- 1 stroke that is genuinely terrible (huge wobble, slow)
  → expected: snaps to Square with low confidence
- 2 strokes after the app has been backgrounded for 30 sec then reopened
  → tests scenePhase handler

### D.3 — Stress test (5 min)

- Try the **History** button (top-right menu in SensorDebugView)
- You should see all 25 strokes listed (5 calibration + 20 test)
- Tap **share** icon on a few → AirDrop is not relevant for your case;
  pick **"Save to Files"** → save to a folder you'll find later

---

## E. Get the data back to me (5 min)

The cleanest path on iPhone:

1. **From inside PuttingLab → History view:**
   - Tap menu (top-right) → **"Clear all"** is destructive, don't tap it
   - Tap share icon next to each stroke → **"Save to Files"** → **Google Drive**
     (you already have it installed for hello@3dprintingexpress.co.uk)
   - Pick a folder like `Drive → My Drive → PuttingLab Test Data → 2026-05-30/`
2. **OR** (faster bulk export): use Files app
   - Files app → On My iPhone → PuttingLab → StrokeReplays
   - Long-press → Select All → Share → Save to Drive
3. Save to the same Drive folder regardless of method

Once they're in Drive, the next time you start a Claude session **just say**:

> "Read the PuttingLab test JSONs I saved to Drive in `PuttingLab Test Data/2026-05-30/`"

I have Google Drive MCP — I'll read them directly, parse the StrokeReplay JSON
schema (defined in `PuttingLab/Models/StrokeReplay.swift`), and produce an
analysis report covering:

- KI-1: Does pull stroke produce negative face angle? (sign check)
- KI-2: Is velocity[0] = 0 a valid baseline? (drift analysis)
- KI-4: How much yaw drift on the radiator stroke vs others?
- KI-5: Were any "still" strokes actually moving?
- KI-6: How many of your clean batches snapped to Square?

---

## F. What I'll do with the data (next session)

When you return with the JSONs in Drive, I will:

1. Read the JSONs into memory
2. Build a per-stroke diagnostic table (timestamp, expected vs measured, confidence, snap reason)
3. Cross-check each KI assumption against the real-world numbers
4. Write `docs/device-verification-day-1.md` with the verdict for each KI
5. Patch any algorithm issues we find as a new audit cycle
6. Push, rerun CI, ship a second TestFlight build with the fixes for re-test

**Expected outcome:** at least 2-3 of the 5 known-issue assumptions will turn
out to need adjusting (this is normal — the audit cycles found 24 bugs without
real sensor data; with real sensor data we'll find more).

---

## Backup plan: if Apple takes >24 hours

If for any reason approval is delayed:

1. **Appetize.io** — upload the simulator .app to their free tier (100 min/mo)
   - Browser-based iPhone simulator
   - Caveat: simulator has NO real motion sensors — you can see the UI but can't
     actually test strokes
   - Use only for showing the app to a friend or to me
2. **Run more CI screenshots** — manual trigger captures the launch view; we
   can extend the workflow to capture multiple views if needed
3. **Just wait** — every Apple Developer approval I've seen completes within
   48 hours; 99% within 24

---

## Skills/repos now installed (helps me help you)

After this session, the project has **15 skills** in `.claude/skills/`:

**Custom (built for PuttingLab):**
- `golf-swing-game-design` — Mario Kart bucket math, Wii Sports rules
- `ios-coremotion-arkit-sensors` — original PuttingLab sensor pipeline

**Existing marketplace:**
- `ios-dev-guidelines`, `swift-development`, `swift-modern-architecture`

**Just added from dpearson2699/swift-ios-skills (10 new):**
- `core-motion` — iOS 26-target CoreMotion reference (newer than ours)
- `swift-concurrency` — Swift 6 strict concurrency, our 5×-bitten footgun
- `swift-testing` — TDD framework reference
- `swiftui-gestures` — touch input handling for aim/calibrate
- `swiftui-animation` — for the roll-animation in v1.1
- `permissionkit` — camera + motion permission UX
- `swift-codable` — JSON serialization (our StrokeReplay path)
- `ios-accessibility` — App Store submission requirement
- `app-store-review` — guidelines + common rejection reasons
- `storekit` — IAP for the Founders Edition £49.99 tier

And 5 reference repos cloned into `references/` (gitignored, just for code
crib'ing):

- `swift-ios-skills` — full 80-skill bundle (we took 10, others available)
- `ARKit-Sampler` — canonical ARKit code reference (for v2 AR putting green)
- `CoreLocationMotion-Data-Logger` — production IMU+GPS logger
- `CoreMotion-Data-Logger` — IMU logger with Python viz scripts
- `SwingMonitorApp` — Apple Watch golf swing IMU (closest neighbour)

---

## Open questions you should answer before testing

1. **Bundle ID:** is `com.puttinglab.app` ok, or do you want
   `uk.crisford.puttinglab` or similar? (Affects secret #8.)
2. **Apple ID for TestFlight:** which Apple ID will be the tester? If it's
   `jamescrisford2002@gmail.com`, that's the one to invite.
3. **Indoor vs outdoor for the test session:** indoor is easier (no glare)
   but the magnetometer near steel-framed buildings is worse. I'd suggest
   start indoors away from radiators, then 1 outdoor stroke for comparison.
4. **Recording video while testing?** Optional but useful — gives me ground
   truth for the stroke direction independent of the IMU. If you have a
   second device that can film you, do it.

---

*If anything in this plan is unclear, message me before starting the
session — I'd rather we sort it out beforehand than mid-test.*
