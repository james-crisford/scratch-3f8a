# Brief — Break-Fix-Break audit loop

You are auditing the PuttingLab iOS app for bugs and fixing them in cycles until either:
- All 5 dimensional auditors return zero critical/showstopper findings
- Token budget drops below 20% remaining (preserve work, stop gracefully)
- 5 full cycles complete (diminishing returns; document remaining issues)
- CI fails 3 times on the same fix (escalate)

## State at start

- **Repo:** `c:\Users\james\Desktop\Claude Agent\projects\PuttingLab\`
- **CI:** GitHub Actions on macos-15, Xcode 16.x, iOS Simulator OS=18.5 iPhone 16
- **Git remote:** authed via Git Credential Manager (silent pushes work)
- **gh CLI token:** retrieve via `git credential fill < <(printf "protocol=https\nhost=github.com\n\n")` then `gh.exe` with `$env:GH_TOKEN`
- **Status:** 281 tests green on commit `954ff66`
- **Spec is locked** at `docs/spec-putting-lab-v1-FINAL.md` — do NOT edit it
- **Skills auto-load** when reading files: ios-coremotion-arkit-sensors, golf-swing-game-design, swift-modern-architecture, ios-dev-guidelines, swift-development

## Cycle protocol

### Phase 1: BREAK — spawn 5 parallel auditors

In a single message, fire 5 `Agent` tool calls (subagent_type=general-purpose) for these dimensions. Each prompt must say "ADVERSARIAL — find bugs, don't validate. Be ruthless." Cap each at 600 words.

1. **Algorithm correctness** — read all files in `PuttingLab/Physics/` and `PuttingLab/Sensors/`. Hunt for: off-by-one, FP precision at large timestamps, sign-convention inconsistencies, NaN/Inf propagation, divide-by-zero, PCA degeneracy, drift correction that worsens things, confidence outside [0,1], unreachable state transitions, mismatch vs spec.

2. **Concurrency + Sendable** — read `SessionCoordinator.swift`, `MotionManager.swift`, `ARTrackingManager.swift`, both detectors, both stores, `SensorDebugView.swift`, `CalibrationCoordinator.swift`. Hunt for: NSLock holes, `@unchecked Sendable` masking real races, closures captured non-Sendable, detectors shared across actors, reentrant locks, `Task { @MainActor }` reorder bugs, `@Observable` mutations from non-MainActor, UserDefaults RMW races.

3. **Test quality** — read all `PuttingLabTests/**/*.swift`. Hunt for: tests with no assertions, tautological assertions, fixture math that calls the same production code being tested (circularity), absurdly wide tolerance bands on noise-free input, back-computed expected values, missing rejection-path coverage, missing negative-sign boundary tests, race-prone timing assertions.

4. **Spec compliance** — read `docs/spec-putting-lab-v1-FINAL.md` then audit every implementation file against it. Hunt for: missing spec requirements, numeric thresholds that drift from spec, field-name drift (snake_case vs camelCase), Wii Sports rules violations, locked-decisions violations, over-engineering beyond spec, under-delivery of spec items.

5. **Real-world gaps** — read research at `research_archive/puttinglab-putter-stroke-tempo-face-2026-05-29.md`, `puttinglab-putt-roll-physics-2026-05-29.md`, `puttinglab-high-speed-imu-bounds-2026-05-29.md`. Hunt for: places where synthetic IMU model deviates from iPhone reality (magnetometer corruption, ARKit feature loss, sample jitter, grip tilt, slow amateur strokes, no-feedback deceleration patterns).

Wait for all 5. Merge findings into a single ranked table. Dedupe duplicates (same bug found by multiple auditors gets +severity).

### Phase 2: FIX — highest severity first, test-first

For every finding at **critical or showstopper** severity:

1. **Write a regression test first** that reproduces the bug. The test MUST fail against current code.
2. Push the test alone to CI (or run locally if possible). Confirm it fails for the reason described.
3. Fix the production code with the minimum change.
4. Verify the test passes (push, CI green).
5. Commit with `Fix [area]: [one-line description] (audit finding C#N)`.

For "important" findings — log to `docs/known-issues.md` with severity, file:line, brief, and "deferred — reason". Do NOT fix in this cycle unless trivial.

For "cosmetic" — log only, no action.

### Phase 3: VERIFY — CI must be green at end of every cycle

Push all fixes. Wait + watch via `gh run watch <id> --exit-status`. If red, fix immediately. Max 3 fix attempts per cycle. If 3rd attempt still red, revert, log the issue, move on.

### Phase 4: WRITE CYCLE REPORT

Append a section to `docs/audit-cycles.md`:

```markdown
## Cycle N — <date>
### Auditors run: 5
### Findings:
- N critical (list with file:line)
- M important (deferred to known-issues.md)
- K cosmetic (logged only)
### Fixed this cycle:
- Bug C1: [description] — fix commit <sha>
- ...
### CI: green on commit <sha>, M tests total
### Time: <wall time of cycle>
```

### Phase 5: BREAK AGAIN

Spawn fresh auditors. Vary the angle by cycle:
- Cycle 1: original 5 dimensions
- Cycle 2: focus on the modules touched by fixes + cross-module integration
- Cycle 3: focus on subtle bugs prior rounds missed (recent edits)
- Cycles 4-5: regression sweep + edge-case fishing + stress tests with new fuzz seeds

## Known bugs from initial audit — START HERE

Fix these BEFORE re-auditing. They are confirmed showstoppers.

### Critical (definitely wrong on real device)

1. **`PuttingLab/Physics/MarioKartAssist.swift:54`** — pull/push sign inverted. `isPull = faceAngleDeg < 0` but ARKit yaw is right-handed, so pull (face closed for righty) = positive yaw. Verify the actual sign convention against `ARTrackingManager.yaw(from:)` output, then correct + add a test that asserts "ARKit yaw +5° on a right-handed putter = pull/closed face".

2. **`PuttingLab/Physics/ImpactDetector.swift:147` (principalAxis sign-flip)** — aligns axis to `mean(accelerations)`. Mean accel ≈ 0 for a complete stroke (back-swing cancels forward), so sign is essentially random noise. Replace with: align to direction of `samples.last.userAcceleration` or to the cumulative integral over the second half of the stroke (which is positively biased toward the impact direction).

3. **`PuttingLab/SessionCoordinator.swift:112`** (handleArm) — `arkitBaselineYaw = arkit.attitudeYaw()` captured immediately at lock, but ARKit needs 1-3s to reach `.normal`. If tracking state isn't `.normal`, baseline is from initializing state. Gate baseline capture on `arkit.trackingState == .normal`. Hold in `.arm` if not yet normal. Surface this state.

4. **`PuttingLab/Sensors/StillnessDetector.swift:7`** — `minGravityDot: 0.96` = 16° cone, but per spec §3 should be `0.966` = 15°. Real grips often tilt 10-15° from vertical, so 0.96 is right at the edge. Investigate empirical data; if needed relax to 0.93 (21°). Pick a number, document it, add a test that locks at the chosen edge angle.

5. **`PuttingLab/SessionCoordinator.swift`** — no haptic fires on stillness lock (only in `SensorDebugView`). The spec calls for `UIImpactFeedbackGenerator(.medium).impactOccurred()` at the moment of lock. Wire it via an injected `@MainActor () -> Void` haptic closure (matches the pattern used in SensorDebugViewModel).

6. **`PuttingLab/Physics/ImpactDetector.swift:38`** — `velocity[0] = 0` assumes phone is at rest at sample 0. But StrokeDetector begins buffering on the *first* above-threshold sample, by which time the phone is rotating >30°/s. Initial velocity is non-zero. Either estimate v₀ from the gradient or integrate from earlier baseline samples that StillnessDetector captured.

7. **`PuttingLab/SessionCoordinator.swift`** + **`PuttingLab/UI/SensorDebugView.swift:43-46`** — `Task { @MainActor in self?.handle(sample) }` per sample does NOT preserve enqueue order. At 100 Hz on a busy main actor, samples can reorder. Replace with a single `AsyncStream<MotionSample>` continuation written from the CoreMotion queue and a single consumer `Task` on @MainActor.

### Important (UX or quality, deferred-but-track)

8. 30°/s stroke threshold too high for slow tap-ins (research: amateur peak can be 50°/s). Lower to 20°/s OR OR-with `|accel| > 0.4 m/s²` for slow-but-accelerating strokes.
9. Calibration needs 5/5 valid; widen thresholds during calibration mode OR accept 3/5.
10. `ConfidenceFlags` exists in MarioKartAssist but `ImpactDetector` throws errors instead of populating it. Wire the bridge so a "too short" or "no clear peak" stroke still produces a result with `snappedToSquare = true`.
11. ARKit-lost detection uses `allSatisfy { isNormal }` (any one bad → fallback). Spec wants ">50% of window". Change predicate.
12. Distance jitter constant 0.05 in code, spec §2.6 says 0.10.
13. Calibration `meanTempoSeconds` is mean stroke duration. Spec wants `backswing/forward ratio`. Need backswing peak detection in ImpactDetector first (separate TempoComputer is in spec §9).

### Test quality (track + fix opportunistically)

14. `PuttingLabTests/Fixtures/Generator.swift:59` — `expectedFaceAngleRad = ImpactDetector.wrapAngle(...)` uses production code in the fixture. Replace with hand-computed expected values via a `wrapAngleReference` helper in tests (NOT calling production).
15. `PuttingLabTests/Integration/NoiseRobustnessTests.swift:27-32` (`heavyNoise`) — calls `detect()` and discards result. Add an assertion (e.g., peakVelocity > 0).
16. ±2° tolerance on noise-free inputs lets silent ±1° regressions through. Tighten to ±0.1° on noise-free fixtures.
17. 1000-stroke fuzz tolerance `<10°` is too wide (a detector returning 0° passes 40% of inputs). Tighten to `<3°` for inputs in `[-25, +25]`.
18. No negative-sign boundary tests in MarioKartAssist (only +6, +12, +20 tested). Add -6, -12, -20 tests.

## Rules

- **Test-first for every fix** — failing test before the production change.
- **One commit per fix** with a clear message.
- **After each cycle write `docs/audit-cycles.md`** — append, don't overwrite.
- **Never deviate from locked decisions** (CLAUDE.md §3, spec §1).
- **Never edit `docs/spec-putting-lab-v1-FINAL.md`.**
- **Polling CI:** `Start-Sleep -Seconds 30; gh.exe run watch <id> --exit-status` in PowerShell or `sleep 30 && gh run watch ... --exit-status` in bash.
- **If James seems to wake up and respond mid-run:** defer to his next instruction. Stop and ask.
- **If a fix touches >2 files:** propose the change before applying. Never silently refactor.
- **Memory updates:** if you discover a load-bearing fact (e.g., empirically-determined optimal threshold), save to canonical memory store per CLAUDE.md §8.

## Stop conditions (in order of preference)

1. All 5 auditors return zero critical/showstopper findings → success. Write `docs/break-fix-break-final.md` summarising.
2. Token budget < 20% remaining → write final summary, commit, push, stop.
3. 5 full cycles complete → write final summary even with open issues, stop.
4. CI fails 3× on same fix → revert, log to known-issues.md, move to next finding.
5. Spec ambiguity discovered → write to known-issues.md, defer.
6. James responds → stop, await instruction.

## Final wrap

Write `docs/break-fix-break-final.md` containing:
- Cycles completed
- Critical bugs fixed (count + list)
- Important bugs deferred (with reasons)
- Cosmetic bugs logged
- Final test count + CI status
- TestFlight readiness verdict ("ship" / "another round needed" / "fundamental redesign")
- Any algorithmic changes that should be documented in CLAUDE.md or spec

Commit all docs. Push. Update `project_puttinglab_build` memory in the canonical store with current state.

Goal is met when: all 5 auditors clean AND final doc written AND CI green AND memory updated.
