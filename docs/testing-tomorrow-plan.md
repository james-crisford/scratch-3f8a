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
| **D** | 90-100 min (2 blocks + break) | 5-stroke calibration + 95-stroke structured test session on iPhone 13 — **the app now walks you through every batch and every stroke** via the new PracticeSessionView |
| **E** | 5 min | Export every stroke JSON to Google Drive |
| **F** | next session | I read the JSONs from Drive, analyse, report |

**Total active time:** ~2 hours. Plus 10 minutes of waiting for Apple.

**Update 2026-05-30 — bumped from 75 → 100** to tighten confidence on every
KI per James's call. Split (locked in `TestBatch.allBatches`):
5 cal + 20 A + 15 B + 15 C + 5 D (Block 1 = 60) + break + 10 E + 10 F + 10 G + 10 H (Block 2 = 40).
The app now contains a guided session view with touch-controlled stroke
recording — see §D for the touch protocol. The plan below pre-dates that
view and still describes self-managed batches; the app does the same work,
just with on-screen guidance.

**Stroke count rationale** (originally bumped from 25 → 75 → 100): each Known Issue needs
roughly 10 paired observations to verify with confidence — single 1-in-5
misses are noise. The structured 70-test-stroke design gives us:
KI-1 sign convention (20 strokes), KI-4 magnetometer (10 paired), KI-5
stillness (10 paired), KI-6 calibration (35 clean across two blocks).

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

## D. The 90-100 minute test session (the actual work)

**Total: 100 strokes** (5 calibration + 95 test). Structured so each Known Issue
gets enough reps that one misclassified stroke is noise, not signal.

### Touch protocol (locked in PracticeSessionView)

Every stroke follows the same cycle:

1. **Setup pose** — phone vertical, screen toward you, back of phone toward
   your chosen target (doorway / wall mark / imaginary hole). App displays
   the current batch + stroke type ("BATCH B · PULL · 3 of 15").
2. **Aim** — hold still until the address-pose lock is captured.
3. **Press + hold the screen** at takeaway. Screen flips RED with "RECORDING".
4. **Make your stroke** — natural putting motion. Phone will tilt forward
   through the swing — that's expected. Don't release until follow-through.
5. **Release** at the END of follow-through. Result panel shows face angle,
   peak velocity, confidence. Counter ticks +1.
6. **Tap "DONE — NEXT STROKE"** to advance. App returns to setup pose for
   the next stroke.

Between batches: app shows "BATCH X COMPLETE — Next: Batch Y" transition.
Between Block 1 and Block 2: app shows "BREAK TIME — 10 min recommended"
with an "I'M READY TO RESUME" button.
At 100 strokes: app shows session-complete screen with export instructions.

Split it ~50/25 across two 35-min blocks with a 10-min break (water, stretch,
let the phone cool). Putting 75 times in one go in front of a screen WILL
fatigue your stroke — and stroke variance from fatigue is noise we don't
want polluting the diagnostic data.

Have Claude on a laptop next to you so you can paste questions if anything
behaves weirdly.

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
- Does "Aim ✓" badge appear within 1-2 sec of holding still? (KI-5)
- If it never appears: you've found KI-5 (stillness tolerance too tight)
- If it appears too easily (even when moving): tolerance too loose

---

### D.2 — Block 1: baseline + sign convention (40 strokes, ~35 min)

**Batch A — natural variance baseline (15 strokes):**
- Stand still, hold still, swing smoothly, NO deliberate face manipulation
- Goal: characterise your natural stroke-to-stroke variance
- Expected: face angle scattered around 0° within ±~3°
- **If >50% snap to "Square"**: KI-6 verified (calibration brittleness — trust your profile less)
- **If mean face angle drifts >2° from zero across the 15**: calibration profile may be biased

**Batch B — deliberate pull strokes (10 strokes):**
- Deliberately close the face at impact (rotate phone slightly left at peak)
- Make the manipulation OBVIOUS — at least 5° of rotation
- Expected: result shows "Pull" / negative face angle, ≥8 of 10 strokes
- **If sign is flipped (shows "Push" when you pulled)**: KI-1 verified bug → I fix the convention
- **If ≥4 snap to Square**: confidence threshold too tight → I relax it

**Batch C — deliberate push strokes (10 strokes):**
- Deliberately open the face at impact (rotate slightly right)
- Same magnitude as Batch B
- Expected: "Push" / positive face angle, ≥8 of 10 strokes
- Sign must be OPPOSITE of Batch B — that's the cross-check

**Batch D — clean strokes immediately after (5 strokes):**
- Same as Batch A — purely to check whether 35 prior strokes have biased the calibration profile
- If face angle wanders from Batch A baseline by >3°: profile is drifting

**☕ BREAK — 10 minutes.** Put the phone down. Drink water. Don't think about it.

---

### D.3 — Block 2: edge cases + sensor robustness (30 strokes, ~30 min)

**Batch E — magnetometer corruption test (10 strokes, PAIRED):**
- 5 strokes standing next to a metal radiator, steel filing cabinet, or any
  large iron/steel object (within ~30 cm)
- 5 strokes in the SAME room, same posture, but 2+ metres from any steel
- Goal: see if the yaw baseline drifts more in the steel-adjacent strokes
- **If steel-adjacent yaw drifts >5° more than control**: KI-4 verified → I add magnetometer rejection logic

**Batch F — stillness tolerance test (10 strokes, PAIRED):**
- 5 strokes with deliberately RIGID body posture (military-stiff before each)
- 5 strokes with natural body sway / subtle weight shift while "holding still"
- Goal: does the stillness detector reject the natural-sway strokes?
- **If natural-sway strokes refuse to auto-lock**: KI-5 verified → I relax the 25° tolerance

**Batch G — calibration robustness (5 strokes):**
- 1 stroke immediately after backgrounding the app for 30 sec
- 1 stroke immediately after backgrounding for 2 min (ARKit will lose tracking)
- 1 stroke with the phone tilted 20° forward at address (not vertical)
- 1 deliberately terrible stroke (huge wobble, slow, ugly) — expect Square snap
- 1 normal stroke to confirm everything's fine

**Batch H — final cool-down clean (5 strokes):**
- Pure baseline strokes again — these are the "you're tired now" reference
- Compare face-angle scatter to Batch A
- Wider scatter = real-world fatigue noise → informs natural variance bounds

---

### D.4 — In-app check (~3 min)

- Open the **History** view (top-right menu in SensorDebugView)
- You should see exactly **75 strokes** listed (5 calibration + 70 test)
- If the count is off, note which batches went missing (any stroke that crashed
  the app won't have a JSON — that's diagnostic too)
- Tap a few strokes to inspect the result panel (face angle, peak velocity, confidence)

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

When you return with 75 JSONs in Drive, I will:

1. Read every JSON, batch-tag by filename + creation time matching the plan blocks
2. Build a per-batch diagnostic table:
   - Batch A: face-angle scatter (mean, std, % snapped) → calibration health
   - Batch B vs C: pull/push sign cross-check → KI-1 verdict (>= 8/10 each direction = green)
   - Batch D vs A: did the profile drift across 35 strokes?
   - Batch E paired: yaw drift steel vs control → KI-4 verdict
   - Batch F paired: stillness rejection rate rigid vs natural-sway → KI-5 verdict
   - Batch G: edge-case behaviour (backgrounding, tilt, terrible stroke)
   - Batch H vs A: fatigue scatter difference → natural variance bounds
3. KI-2 + KI-6: pure data analysis on Batches A/D/H (no special batch needed)
4. Write `docs/device-verification-day-1.md` with a verdict for each KI: VERIFIED / REFUTED / INCONCLUSIVE
5. Patch the algorithm issues we find as a new audit cycle (cycle 6)
6. Push, rerun CI, ship a second TestFlight build with the fixes
7. Plan a smaller re-test session (~25 strokes targeted at whatever changed)

**Expected outcome:** with 75 strokes I should be able to give VERIFIED or
REFUTED for 5 of the 6 KIs (KI-2 might stay INCONCLUSIVE depending on noise
profile). The audit cycles found 24 bugs WITHOUT real sensor data; with real
sensor data we'll find more — that's the point of doing this.

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
