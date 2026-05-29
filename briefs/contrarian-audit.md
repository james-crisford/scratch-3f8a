# Brief — Contrarian Audit of PuttingLab

You are the council of skeptics. Your job is to **try to kill PuttingLab as a product/project**, not to validate it. The author has been in execution mode for ~12 hours and has built strong sunk-cost reasoning. Bring fresh, brutal, externally-grounded skepticism.

## Premise being challenged

PuttingLab is a planned iPhone-only app:
- User holds iPhone vertically like a putter grip
- Swings through air (no physical ball)
- App reads CoreMotion + ARKit to estimate stroke
- Displays "Mario Kart-style" face angle bucket + distance
- £4.99/mo subscription + £29/yr + £19 Founders one-off

Built by James Crisford (3DPE co-founder, product-design degree, plays golf) over ~10 days. 311 tests green. About to pay £79 for Apple Developer + ship to TestFlight.

## What's been done and what's on disk

- `docs/spec-putting-lab-v1-FINAL.md` — full spec
- `docs/break-fix-break-final.md` — 5 audit cycles done
- `docs/known-issues.md` — 15 deferred items
- `research_archive/golfgo-app-competitive-teardown-2026-05-28.md` — the competitor analysis that motivated the build
- `research_archive/golfgo-research-2-golfer-jtbd-2026-05-28.md` — golfer jobs-to-be-done
- `research_archive/golfgo-research-3-competitor-matrix-2026-05-28.md` — competitive matrix
- `research_archive/puttinglab-competitor-intel-2026-05-29.md` — overnight competitor sweep
- `research_archive/puttinglab-monetisation-playbook-2026-05-29.md` — pricing research
- `research_archive/puttinglab-putt-roll-physics-2026-05-29.md` — physics research

Read every research report relevant to your dimension before writing.

## Council protocol — 5 contrarian voices, parallel agents

Spawn 5 `Agent` tool calls in parallel, each playing a hostile role. Each gets 700 words. All must START with their dimension's hardest "kill this project" argument.

### 1. Product killer
Hunt: is the product actually wanted? Read `golfer-jtbd` + `competitor-intel`. Find:
- Whose problem does this solve? Name the persona, frequency of use, willingness to pay.
- Why hasn't GolfGo / SwingTracker / GolfBuddy / Phigolf already won this with a real device?
- What's the demo failure rate? First-time user opens app, makes a putt — does it actually feel right? What's the % chance they uninstall in 30s?
- Compare to physical alternatives (Wellputt mat at £80, Pelz tutor, real putting green at £5/visit).
- Is "no physical ball" a feature or a fatal limitation? Does Wii Golf precedent generalise?

### 2. Technical killer
Hunt: is the fundamental tech actually capable of delivering ±2° face angle and believable distance on iPhone hardware, or is this premise broken?

Read: `docs/known-issues.md`, `research_archive/puttinglab-high-speed-imu-bounds-2026-05-29.md`, `research_archive/puttinglab-putter-stroke-tempo-face-2026-05-29.md`, `research_archive/golfgo-research-1-imu-swing-physics-2026-05-28.md`, `research_archive/golfgo-research-4-arkit-realitykit-feasibility-2026-05-28.md`, `research_archive/golfgo-research-5-multisensor-swing-detection-2026-05-29.md`.

Then attack on five fronts:

A. **Is the sensor stack adequate?**
- iPhone CMDeviceMotion caps at 100 Hz; Marquardt SAM PuttLab samples at 1000 Hz. Forward swing is ~317 ms. At 100 Hz you get ~32 samples to capture impact — is that enough for ±2° face angle resolution given sin/cos quantization?
- ARKit fast-motion drops to `.limited(.excessiveMotion)` at wrist rotations >30°/s. Putt rotations <90°/s, but indoor lighting + steel furniture + featureless walls all degrade tracking. Cite the research's ARKit drift envelope.
- Magnetometer-based attitude reference (`xMagneticNorthZVertical`) is corrupted by steel putter shafts and any metal indoors. Switching to `xArbitraryZVertical` removes the absolute reference. Is the resulting baseline stability good enough for ±2°?

B. **Does the Wii Sports analogy hold?**
- Wii Remote had an IR sensor bar (absolute pointing reference), an accelerometer, AND the user wasn't trying to extract ±2° angular precision — they were estimating buckets.
- iPhone has no IR sensor bar. ARKit replaces it but only with line-of-sight to visual features. What's the failure rate vs Wii's IR-bar architecture?
- Wii Golf measured swing tempo + raw direction; PuttingLab claims face angle PLUS distance PLUS confidence. Is the precision claim 3× harder than what Wii actually delivered?

C. **Compare to what professional putting trackers actually use.**
- SAM PuttLab: ultrasonic positioning + 1000 Hz IMU mounted on a real putter. £3,000. ±0.1° face angle.
- Phigolf: real putter sensor + Bluetooth to phone. £200. ±2° claimed but published reviews say worse.
- HackMotion (HACKMOTION wrist sensor): IMU on the wrist, claims ±1° on club face proxy.
- These all use HARDWARE attached to the user or club. PuttingLab claims phone-only ±2°. What's the assumption that lets it match dedicated hardware?

D. **First-time-user failure mode.**
- User opens app, points camera at carpet (no features), grips phone in lead hand, makes a stroke. ARKit never reaches `.normal` → no ARKit baseline → compass-only path → magnetometer-corrupted result. The "Aimed ✓" lock never fires because their natural grip tilts the phone 20° from vertical (KI-5). They make 3 strokes, get 3 snap-to-square "Couldn't read" results. Probability of uninstall = ?
- The deferred KI-1 (pull/push sign convention) — what if it's not just a sign flip but a coordinate frame error that requires re-deriving the whole math?

E. **Thermal + battery reality.**
- 100 Hz CoreMotion + ARKit world tracking + SwiftUI rendering = how many minutes before iPhone 13 thermal-throttles to 60 Hz? At 60 Hz, integration accuracy degrades. Does the algorithm need a "you're too hot, take a break" UI?
- 30 min of continuous practice — battery cost?

For each front, end with a "what would change my mind" — specifically: what empirical evidence (which iPhone test, which measurement) would falsify the kill argument. The author cannot proceed without those tests passing.

### 3. Business killer
Hunt: does the unit economics work?
- Read the monetisation playbook. What's the realistic conversion at £4.99/mo for a free-trial app in the casual sports category?
- 7-day free trial, then £4.99/mo → typical conversion 2-5%. App needs ~20,000 free trials to fund 1000 paid users = 1000 × £60/yr = £60k/yr. After Apple's 30% (year 1) = £42k. Marketing cost to acquire 20,000 trials in golf vertical = ?
- LTV / CAC ratio at realistic numbers — is this a hobby project that costs £79/yr or a business?
- What's the cliff if Apple changes app review policy or if a free competitor launches?

### 4. User research killer
Hunt: who actually wants this and have they been asked?
- Has James talked to ANY golfer who isn't himself? What did they say?
- The 4-touch persona (mid-handicap, plays 1×/month, owns iPhone 13+) — how many of them exist in the UK addressable market?
- Read the competitor intel. The market is mostly: pros buy SAM PuttLab (£3k), serious amateurs buy Phigolf (£200) or Garmin watch (£300). Casual golfers don't buy putting apps. Where's the sweet spot?
- Is the "Wii Sports for golf" framing real or wishful?

### 5. Strategic killer
Hunt: is THIS the right thing for James to be building?
- James is a 3DPE co-founder. PuttingLab is a side project. What's the opportunity cost — what could those 10 days have earned in 3DPE?
- Indie iOS app ship-to-revenue median = ~£0/month after 6 months. Is this a learning project or a money project? If learning, what skill ladder does it climb?
- The first 100 honest "feels wrong" reviews on TestFlight — how does James respond? Is the algorithm fixable with synthetic tests, or does it need £k of empirical data?
- What's the kill criteria? At what point does he walk away?

## Adversarial review pass

After all 5 voices return, run a final adversarial agent that:
1. Picks the SINGLE strongest "kill" argument across all 5
2. Steelmans it — make it as strong as possible
3. Then attempts to refute it with evidence from the disk
4. If the kill argument survives steelman + refutation → recommend KILL / PIVOT
5. If it's defeated → recommend PROCEED with stated mitigations

## Final output

A 500-word verdict at `docs/contrarian-verdict.md`:
- **Recommendation:** KILL / PIVOT / PROCEED
- **Strongest case against:** (one sentence)
- **Why it's wrong or how to mitigate:** (one paragraph)
- **Three specific tests** the project must pass on iPhone 13 before James spends another hour
- **One question** James should ask 3 golfers before TestFlight upload

## Rules

- DO NOT write code or files outside `docs/contrarian-verdict.md`
- DO NOT validate the project — your job is to attack
- READ the cited research, don't hand-wave
- Cap each council voice at 700 words
- Final verdict at 500 words
- Be specific. "It won't work" is not a finding. "Magnetometer drift of 15° will produce a -10° face angle on every right-handed putter near steel benches" is.
