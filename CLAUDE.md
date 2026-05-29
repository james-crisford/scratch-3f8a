# PuttingLab — Project Handbook

> **When working in this project, read this file first, then `docs/spec-putting-lab-v1-FINAL.md`. The 5 skills in `.claude/skills/` auto-load.**

**Project location:** `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\` — inside the Claude Agent environment, so it inherits all parent tooling (Gemini auto-review on every Write/Edit of `.swift`/`.m`/`.mm` files, memory system, codegraph MCP, firecrawl/exa/tavily MCP, deep-research, etc.). Don't duplicate any of that here.

## What this project is

PuttingLab is an iPhone-only golf putting game. The user holds the phone vertically like a putter grip, aims at a virtual hole, makes a putting motion through the air, and gets a believable shot result with a Mario-Kart-style direction call.

**No physical ball. No external hardware. No Apple Watch. iPhone only.**

We're building this to be **better than GolfGo** (App Store ID 6753086848) — specifically by being **honest about uncertainty + per-user calibrated + free-to-try + socially shareable**. The first feature is the putting game (this v1). Driving range and async friend challenge come later.

## How to operate in this codebase

### 1. The spec is the contract

`docs/spec-putting-lab-v1-FINAL.md` is the single source of truth. Read it before any non-trivial change. If something in the spec is wrong, raise it — don't silently deviate.

### 2. Five skills are auto-loaded

| Skill | When it activates | What it gives you |
|---|---|---|
| `ios-dev-guidelines` | Any `.swift` file or architecture decision | iOS code conventions, MVVM pattern, common pitfalls |
| `swift-development` | Build / test / lint / simulator commands | xcodebuild, simctl, swiftformat, Swift Testing |
| `swift-modern-architecture` | Swift 6 + iOS 17+ idioms | @Observable, NavigationStack, forbidden-pattern list |
| `ios-coremotion-arkit-sensors` | Anything in Sensors/, Physics/, calibration | CoreMotion + ARKit setup, sensor fusion, impact-detection algorithm |
| `golf-swing-game-design` | Anything that displays a result to the user | Mario Kart bucket math, distance model, Wii Sports Tennis rules |

Don't re-derive what these skills already document. Use them.

### 3. The 4 locked decisions (do not re-litigate)

1. **iPhone-only**, **no Apple Watch**, **no accessory**, **iOS 17.0 minimum**.
2. **Phone orientation**: vertical in lead hand, screen facing user, back camera facing direction of swing. Phone Y = shaft, Phone X = face normal.
3. **No physical ball**. Impact = peak forward hand velocity (Wii Golf style).
4. **Mario Kart-style assist**: snap to square when confidence is low. Never confidently wrong.

### 4. The Wii Sports Tennis three rules (non-negotiable)

1. Err toward "Square" when uncertain.
2. Surface the cause, not just the result.
3. Never invent direction the user clearly didn't produce.

### 5. Code style

- Swift 6, iOS 17.0 minimum.
- SwiftUI with `@Observable` (NOT `ObservableObject`).
- `@MainActor` on view models.
- Swift Testing framework for new tests (not XCTest).
- 4-space indentation.
- No comments unless explicitly requested (self-documenting code).
- No hardcoded user-facing strings (use a `Strings` enum).

### 6. Project structure

```
PuttingLab/                    <-- Xcode project (creates the .xcodeproj here)
├── App/                       PuttingLabApp.swift
├── Models/                    StrokeBuffer, CalibrationProfile, StrokeResult, PhaseState
├── Sensors/                   MotionManager, ARTrackingManager, StillnessDetector, StrokeDetector
├── Physics/                   ImpactDetector, FaceAngleComputer, DistanceModel, MarioKartAssist
├── Calibration/               CalibrationCoordinator, CalibrationModel
├── UI/                        PracticeView, ResultPanelView, RollAnimationView, ProgressRingView, ...
├── Storage/                   ProfileStore
└── Resources/                 Assets.xcassets
PuttingLabTests/               Swift Testing suites
docs/
├── spec-putting-lab-v1-FINAL.md    <-- THE SPEC
└── research/                       Background reports (cite as needed, don't re-read every turn)
.claude/
├── skills/                         (5 skills above)
└── CLAUDE.md                       <-- this file
```

### 7. Testing on real devices is required

The iOS simulator does NOT have working motion sensors or magnetometer. Any sensor pipeline change must be tested on a real iPhone before being called "done".

UI-only changes: simulator is fine.

### 8. Definition of done for v1

(from `spec-putting-lab-v1-FINAL.md` §14)

1. Fresh install → calibration → first practice works end-to-end without crashing.
2. 10 sequential strokes produce 10 plausible (distance, face, tempo) results.
3. A golfer testing it says "feels about right" 4 of 5 strokes.
4. Address auto-lock works silently and reliably.
5. Roll animation reads as believable golf.
6. App handles edge cases gracefully.
7. Runs on iPhone 12 through iPhone 17.
8. TestFlight build shared with ≥2 testers beyond James.

### 9. When to escalate to James

- Any change to the spec (`docs/spec-putting-lab-v1-FINAL.md`).
- Any deviation from the 4 locked decisions or the 3 Wii Sports rules.
- Any new external dependency.
- Anything to do with App Store submission, code signing, or pricing.

### 10. Background context

If you need motivation for a design choice, the source research lives in `docs/research/`. Highest-value reads:
- `synthesis-cross-cut.md` — single best overview of the whole project.
- `research-1-imu-swing-physics.md` — why the physics envelope is what it is.
- `research-5-multisensor-swing-detection.md` — why we use ARKit + magnetometer + the Wii Sports rules.

Don't read these every turn. Read the relevant skill instead — they distill the key takeaways.

---

*Last updated: 2026-05-29. Project status: pre-build. v1 spec locked, skills installed, awaiting goal-prompt assembly + day-1 kickoff.*
