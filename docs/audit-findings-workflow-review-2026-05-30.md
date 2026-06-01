# Pre-TestFlight Review Sweep — 2026-05-30

**Method:** Multi-agent dynamic workflow (`puttinglab-pre-testflight-review`). 4 review agents (physics, sensors/concurrency, state/storage, UI/accessibility) each read the real Swift source; every finding was then handed to an independent adversarial skeptic that re-read the cited code and tried to refute it.

**Result:** 32 agents · 28 raw findings · **17 rejected** by verification · **11 confirmed**.

> StoreKit/purchase dimension was skipped — no purchase code exists in the repo yet (monetisation is spec-only).

Severity legend: 🔴 fix before manual testing · 🟡 fix before TestFlight ships to others · ⚪ latent / cleanup.

---

## 🔴 Fix before testing — affects the test session itself

### 1. History store can brick itself and block all future saves `high`
**File:** `PuttingLab/Storage/StrokeHistoryStore.swift:28-43`
`loadLocked()` does a bare `try JSONDecoder().decode([StrokeRecord].self, from: data)` with no error swallowing. `ProfileStore` deliberately catches `is DecodingError` and returns nil to survive schema changes (`ProfileStore.swift:37-39`); this store does not.
- On any app update that changes `StrokeRecord`'s shape, every existing user's stored blob fails to decode and `load()` throws forever.
- `append()` calls `loadLocked()` first (line 37), so a single un-decodable blob means **no new stroke can ever be saved** — every append throws on the read before it can write. No self-heal path.

**Fix:** mirror ProfileStore — `catch is DecodingError { return [] }` (reset to empty and continue).

### 2. No upper clamp on putt distance — sensor spike → physically-impossible number `medium`
**File:** `PuttingLab/Physics/DistanceModel.swift:53-58`
`compute()` clamps only the lower bound (`max(0, peakSpeedMps)`) then squares it. No upper bound on speed, fps, or feet. The `userAcceleration` double-integration in `ImpactDetector.detect()` (velocity-Verlet sum, lines 39-48) can produce an arbitrarily large peak from a transient/drift; because distance scales with speed², a 2× velocity error → 4× distance error. `ImpactDetector` rejects peaks *below* `minPeakVelocityMps` (0.3) but nothing rejects an absurdly high peak (a 50 m/s glitch → ~13,000 ft "putt").

**Fix:** cap `displayedFeet` to a sane green envelope, or trigger snap/low-confidence on out-of-range peaks.

### 3. Replay history hard-crashes on a malformed file `low` (but a hard crash)
**File:** `PuttingLab/Models/StrokeReplay.swift:163-182`
`toStrokeWindow()` force-indexes decoded fixed-length arrays. `SerializedSample` is protected — its custom `init(from:)` (lines 81-116) rejects wrong-length arrays at decode. But `SerializedLock` (lines 30-34) uses the default synthesized decoder with no count validation, and `toStrokeWindow()` then force-indexes `lock.gravity[0..2]` (line 180). A replay JSON with a truncated `lock.gravity` decodes successfully but traps index-out-of-range — crashing the offline-replay/History path instead of skipping the bad record.

**Fix:** guard the count, or give `SerializedLock` a validating `init(from:)` like `SerializedSample` has.

---

## 🟡 Fix before TestFlight ships to others (App Store gate)

### 4. Debug view ships and is reachable in Release builds `medium`
**File:** `PuttingLab/UI/PracticeSessionView.swift:106` (sheet at 106-109, 58-60)
The options Menu unconditionally offers "Sensor Debug" → `SensorDebugView`, a raw harness showing rotation/accel/gravity SIMD vectors, measured Hz, ARKit yaw in radians, internal phase-machine badges, **and a destructive "Reset onboarding" button** (`SensorDebugView.swift:295`). No `#if DEBUG` guard. A TestFlight/App Store build exposes internal telemetry and a destructive control to end users.

**Fix:** wrap the menu item (and ideally the view) in `#if DEBUG`, or hide behind a hidden gesture.

### 5. No Dynamic Type support anywhere `medium`
**File:** `PuttingLab/UI/PracticeSessionView.swift:172` (+ 264, 268, 296, 416, 468)
All major headings/banners use hardcoded `.font(.system(size: N, ...))` — stroke heading 24, RECORDING 38, RECORDED 32, BREAK TIME 36, SESSION COMPLETE 30, record icon 90. Fixed-size fonts don't scale with Dynamic Type / Larger Text. Grep confirms zero uses of `dynamicTypeSize`, `ScaledMetric`, or any scaling. Inconsistent too: instruction bullets use semantic styles (`.callout`/`.subheadline`) and *do* scale — so the prompts a low-vision user most needs ("RECORDING", "TAP & HOLD", result numbers) are exactly the ones frozen.

**Fix:** use relative styles (`.largeTitle`/`.title` with `.weight()`) or `@ScaledMetric` for numeric sizes.

### 6. Icon-only buttons in history have no accessibility labels `medium`
**File:** `PuttingLab/UI/ReplayHistoryView.swift:109` (+ toolbar menu line 37)
Per-row share button is an icon-only `Image(systemName: "square.and.arrow.up")` in a Button with no `.accessibilityLabel` — VoiceOver announces "square and arrow up". Toolbar overflow `Image(systemName: "ellipsis.circle")` → "ellipsis circle". Empty-state/error glyphs unlabelled too.

**Fix:** `.accessibilityLabel("Share stroke")`, `.accessibilityLabel("More options")`, etc.

### 7. Pulsing record icon has no Reduce Motion fallback `low`
**File:** `PuttingLab/UI/PracticeSessionView.swift:266`
The RECORDING screen drives a continuous `.symbolEffect(.pulse)`. Grep confirms zero uses of `accessibilityReduceMotion`/`reduceMotion` in the project. Users with Reduce Motion enabled still get the perpetual animation — an App Store accessibility expectation.

**Fix:** read `@Environment(\.accessibilityReduceMotion)` and apply `.symbolEffect` only when false (else static).

### 8. Result rows read as two disjoint VoiceOver elements `low`
**File:** `PuttingLab/UI/PracticeSessionView.swift:345` (+ `ReplayHistoryView.row` 95-107)
`resultRow` renders label Text and value Text in an HStack with a Spacer, no `.accessibilityElement(children: .combine)`. VoiceOver swipes through "face" and "+1.2°" as unrelated nodes. `PhoneHoldVisual` already does this correctly (line 43) — the result panels should follow the same pattern.

**Fix:** copy the `.accessibilityElement(children: .combine)` pattern from `PhoneHoldVisual`.

### 9. Progress counter has no accessibility value/label `low`
**File:** `PuttingLab/UI/PracticeSessionView.swift:554`
`ProgressHeader` shows a `ProgressView` plus "Stroke X of Y" / "A of B" as independent caption Texts — no combine, no `.accessibilityValue`. The bare `ProgressView(value:total:)` is announced as a percentage with no label. For a 100-stroke session, progress is core UX.

**Fix:** `.accessibilityLabel("Session progress")` + `.accessibilityValue("X of Y strokes")`.

---

## ⚪ Latent / cleanup — note, don't block

### 10. `movingAverage` off-by-one on even windows `low` (latent)
**File:** `PuttingLab/Physics/ImpactDetector.swift:206-216`
`half = window/2`; inner loop sums `(i-half)...(i+half)` = `2*half+1` terms = `window+1` for an even window, but divides by `Double(window)`. Over-weights the average by `(window+1)/window`. Latent today — the only caller passes `smoothingWindow = 5` (odd), where `2*half+1 == window`. A future even window would silently bias every smoothed velocity high, shifting the detected peak and thus distance.

**Fix:** divide by the actual term count, or assert an odd window.

### 11. UserDefaults isn't crash-atomic — recent writes lost on hard kill `low`
**File:** `PuttingLab/Storage/StrokeHistoryStore.swift:50-53` (also `TestSessionState.save()`, `ProfileStore.save()`)
All write through `defaults.set(...)`, which persists lazily (periodic + on suspend) with no synchronous flush. `StrokeReplayStore` correctly uses `data.write(to:url, options:.atomic)` (`StrokeReplay.swift:234`). A stroke appended in the last seconds before iOS terminates the app can be silently dropped even when the code "saved". For a 100-stroke session this means lost strokes near a background/kill boundary.

**Fix:** consider an atomic file-backed store for stroke history, or an explicit synchronize at session boundaries.

---

## Notable rejected findings (verifier earned its keep)

- **"App overclaims a face-angle the research says to suppress"** — *rejected.* The skeptic checked the locked spec (`spec-putting-lab-v1-FINAL.md` §1 decision #3, §2.1, §5 line 309) and found James explicitly chose Mode B "honest face-direction read"; the research note was a recommendation explicitly marked "Decision needed", superseded by the spec (the contract). Code already snaps-to-square on low confidence (`PracticeSessionView.swift:304-305`). Not a defect.
- **"End-velocity detrend divides by zero"** — *rejected.* The `n-1` divisor sits inside an `if velocity.count > 1` guard, and `samples.count >= 3` is hard-guarded with a throw; division by zero is unreachable.
- Plus 15 other speculative/hypothetical findings dropped after the skeptic read the actual code (sensor lifecycle teardown already exists via scenePhase/onDisappear; timestamp-based AR-pose matching, not index pairing; `.unbounded` buffer is a documented correctness requirement; etc.).

---

*Generated by the `puttinglab-pre-testflight-review` workflow. Run ID `wf_0aefac81-a81`.*
