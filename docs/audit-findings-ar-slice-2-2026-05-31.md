# AR Slice 1 + 2 Deep Audit — 2026-05-31

**Source:** Multi-agent workflow `ar-slice-deep-audit` (`wf_2fcd1ca6-e88`) — 55 agents, 41 raw findings, 31 confirmed after adversarial verification, 6 scenario simulations, 3 Gemini independent reviews.

**Scope:** Files reviewed
- `PuttingLab/UI/AR/ARPlacementView.swift` (Slice 2 — tap-to-place ball + hole)
- `PuttingLab/UI/AR/ARScanningView.swift` (Slice 1 — scanning verification)
- `PuttingLab/UI/AR/ARSessionLogger.swift` (shared event logger)
- `PuttingLab/UI/PracticeSessionView.swift` (DEBUG entry points)
- `PuttingLab/Sensors/ARTrackingManager.swift` (long-running session)

**Synthesis verdict:** `fix_first_then_ship`.

**Local HEAD:** `c2e6a1b` (AR Slice 2 commit). Not pushed.

---

## Status legend
- ✅ Fixed in this pass
- ⏳ In progress
- ⏭️ Deferred (with reason)

---

## CRITICAL — must fix before any build / push

### C1 — Swift 6 strict-concurrency build-blocker on Coordinator delegate conformance ✅
- **File:** `ARPlacementView.swift:485-541`, `ARScanningView.swift:267-308`
- **Issue:** `@MainActor final class Coordinator: NSObject, ARSessionDelegate` declares delegate methods without `nonisolated` bridging. Under `SWIFT_STRICT_CONCURRENCY=complete` (project.yml line 14), Swift 6 rejects @MainActor-isolated methods satisfying nonisolated @objc protocol requirements.
- **Smoking gun:** the previous commit `8ad68ce` (B17) used the opposite pattern (no `@MainActor` on Coordinator + `Task { @MainActor in ... }` hops) — that passed CI. The Slice 2 commit `c2e6a1b` reverted it without rebuilding.
- **Fix:** mark each delegate method `nonisolated` and wrap body in `MainActor.assumeIsolated { ... }`. Apply to all 6 ARSessionDelegate methods on BOTH Coordinator classes, plus `@objc handleTap` in Slice 2.
- **Verified by adversarial agent:** real, medium-high confidence (compiler not yet run but Swift language rule + Build-17 precedent are unambiguous).

### C2 — "Aim at the floor" rejected-tap toast is invisible ✅
- **File:** `ARPlacementView.swift:728-738` interacts with `:530-541`
- **Issue:** `handleTap` raycast-miss path writes `"Aim at the floor"` to `trackingState`, waits 1.5s, then restores. But `session(_:didUpdate:frame:)` fires at 10Hz throttled to 100ms and **unconditionally** writes the live tracking string to the same binding. Within ~100ms the toast is overwritten. The `if binding.wrappedValue == "Aim at the floor"` guard then fails and the previous state is never restored. Net: the only feedback users get that an off-plane tap was rejected never reaches them.
- **Fix:** add separate `@State transientHint: String?` on the parent view rendered as its own overlay; don't hijack `trackingState`.

---

## HIGH — visible to user, fix before next TestFlight

### H3 — `ARPlaneExtent.rotationOnYAxis` ignored — overlay misaligns ✅
- **File:** `ARPlacementView.swift:618-650` + `ARScanningView.swift:395-419`
- **Issue:** `addOrUpdatePlaneOverlay` reads only `.width` and `.height` from `ARPlaneExtent`. ARKit (iOS 16+) sets `.rotationOnYAxis` to non-zero once it refines a non-axis-aligned plane (common). The translucent green rectangle then visibly rotates away from the underlying detected mesh.
- **Fix:** `model.transform = Transform(scale: .one, rotation: simd_quatf(angle: plane.planeExtent.rotationOnYAxis, axis: SIMD3<Float>(0,1,0)), translation: SIMD3<Float>(plane.center.x, 0, plane.center.z))`. Apply in both slices.

### H4 — ARTrackingManager left dead after Slice 1/2 cover dismiss ✅
- **File:** `PracticeSessionView.swift` (entry points)
- **Issue:** Both `fullScreenCover` presentations have no `onDismiss`. The cover's second ARSession wins the camera; on dismiss only that session is paused — `ARTrackingManager.session` doesn't auto-resume. Practice-screen AR-pose channel goes silent until the next background/foreground cycle. Face-angle baseline from `arkit.attitudeYaw()` returns nil and degrades silently. Gemini flagged this CRITICAL on both file reviews; Claude calibrated to HIGH given the DEBUG-only entry point.
- **Fix:** add `onDismiss` to both `fullScreenCover` calls that pauses + restarts `ARTrackingManager`. Don't wait for Slice 3.

### H5 — Interruption (incoming call) corrupts anchor positions with no recovery prompt ✅
- **File:** `ARPlacementView.swift` (interruption delegates + scene anchors)
- **Issue:** Ball/hole are `AnchorEntity(world: position)` not `AnchorEntity(anchor: planeAnchor)` — fixed world coords, not plane-tracked. On `sessionInterruptionEnded` after a long call, ARKit relocalization may fail (very common) — the cached `ballWorldPosition` now points at a meaningless location. User sees ball floating mid-air; if they then tap to place the hole, a confident-but-wrong distance reading appears. No banner, no toast, no forced reset.
- **Fix:** on `sessionInterruptionEnded`, if `placementState` is `.readyToPlaceHole` or `.complete`, force `.waitingForPlane`, `scene.clearPlacedEntities()`, show transient hint "Tracking recovered — place again". (Long-term, switch to `AnchorEntity(anchor:)` — bundled with the Slice 3 architecture review.)

### H6 — Rapid double-tap places ball + hole instantly in same spot ✅
- **File:** `ARPlacementView.swift:701-783`
- **Issue:** `defer { isProcessingTap = false }` is dead code for sequential `UITapGestureRecognizer` dispatches because `handleTap` is synchronous on MainActor — defer fires before the next tap dispatches. Tap 1 places ball + writes `.readyToPlaceHole`. Tap 2 (50ms later) reads the new state via Binding and places the hole. State jumps to `.complete` in ~100ms with both entities essentially overlapping; aim-line gated by `length > 0.001` may not render. Common iOS double-tap habit triggers this every time.
- **Fix:** add real timestamp-based debounce. Store `lastPlacementAt: Date?` on Coordinator. Early-return if `Date().timeIntervalSince(lastPlacementAt) < 0.3`.

---

## MEDIUM

### M7 — `MeshResource + ModelEntity` rebuilt at 10Hz per plane ✅
- **File:** `ARPlacementView.swift:618-650` + `ARScanningView.swift:395-419`
- **Issue:** Every `session(_:didUpdate anchors:)` tick allocates fresh mesh + material + entity. Across 3-5 detected planes that's 30-50 allocations/sec. iPhone 12 frame-time spikes.
- **Fix:** cache one `ModelEntity` per plane, regenerate mesh only when extent changes by ≥5cm.

### M8 — ARTrackingManager silent state corruption window during Slice 2 ✅
- **File:** `ARPlacementView.swift:417-453` (covered by H4 fix)
- Same root cause as H4; addressed by the `onDismiss` restart.

### M9 — Backgrounding + `Timer.publish` makes Slice 1 Elapsed counter jump on resume ✅
- **File:** `ARScanningView.swift:33,59-61`
- **Issue:** `sessionStartedAt = Date()` is set at @State init (before view appears). `Timer.publish` doesn't fire while backgrounded but `Date().timeIntervalSince(...)` includes the suspend interval — elapsed jumps forward on resume.
- **Fix:** move `sessionStartedAt = Date()` into `.onAppear`; track suspended duration via scenePhase.

### M10 — `@State var logger = ARSessionLogger(slice:)` is reference-type held as @State, lacks `nonisolated init` ✅
- **File:** `ARSessionLogger.swift:25` (and the asymmetry vs `ARPlacementScene` line 296)
- **Issue:** `ARPlacementScene` has `nonisolated init() {}` (explicitly hardened for @State construction from nonisolated context). `ARSessionLogger.init(slice:)` does not. Blocks `#Preview { ARPlacementView() }` and any nonisolated test harness under Swift 6 strict mode.
- **Fix:** add `nonisolated` to `ARSessionLogger.init(slice:)`. Body only touches String + Date, sound.

### M11 — Camera-denied error shown only as small red HUD text — no Settings deep-link ✅
- **File:** `ARScanningView.swift:286-298` + `ARPlacementView.swift:556-571`
- **Issue:** `didFailWithError` with `cameraUnauthorized` writes a tiny red string to `trackingState`. For DEBUG it's acceptable; for any user-facing flow it needs a modal + `UIApplication.openSettingsURLString` button.
- **Fix:** acceptable for DEBUG-only entry; add a TODO marker referencing Slice 3 user-facing-AR work. ⏭️ Deferred to Slice 3.

### M12 — Silent-wait failure mode on cold start: phone held still, HUD freezes with no "move me" hint ✅
- **File:** `ARScanningView.swift` + `ARPlacementView.swift` HUD
- **Issue:** ARKit needs parallax to bootstrap. Holding the phone still gives `Tracking=Limited`, `Planes=0`. The empty-events caption is hidden once `sessionStart` fires. User reads "broken".
- **Fix:** show timed hint "Try panning the phone — ARKit needs motion to detect surfaces" after 2s of `planeCount==0`.

### M13 — `sessionStart` event evicted from 500-cap ring buffer in long sessions ✅
- **File:** `ARSessionLogger.swift:33-38`
- **Issue:** Once `events.count > 500` `removeFirst` drops `sessionStart`. JSON snapshot loses its header context (`startedAt` envelope is preserved separately, but the initial trackingState transitions and first planeAdded events go).
- **Fix:** retain `sessionStart` event in the ring buffer (`events = [sessionStart] + events.suffix(maxEvents-1)`).

### M14 — Double `saveSnapshot` per dismiss ✅
- **File:** `ARPlacementView.swift:87-89,470` + `ARScanningView.swift:69-72,256`
- **Issue:** Both `onDisappear` and `dismantleUIView` call `saveSnapshot()`. Two full JSON encode+write per session dismiss; second wins. If dismantle runs first (rare with interactive transitions), JSON #1 has no `sessionEnd`.
- **Fix:** drop `saveSnapshot` from `dismantleUIView` (it's already on `onDisappear`), keep the `clearAllPlaneOverlays` cleanup.

### M15 — Anti-parallel aim-line rotation branch suggests geometry misunderstanding ✅
- **File:** `ARPlacementView.swift:373-381` (Gemini-only finding)
- **Issue:** `direction` is between two points on a horizontal plane — should never be anti-parallel to +Y. The defensive `simd_quatf(angle: .pi, axis: SIMD3<Float>(1,0,0))` either dead-codes or masks a real bug (vertical plane misidentified as horizontal would trigger it).
- **Fix:** document the branch as defensive-only with a comment explaining it can't fire under horizontal-plane assumption; assert it doesn't fire in DEBUG.

---

## LOW

### L16 — Save button order: log AFTER save means JSON lacks the marker ✅
- **File:** `ARPlacementView.swift:150-152` + `ARScanningView.swift:131-133`
- **Fix:** swap the two lines. Log `.note` first, then `saveSnapshot()`.

### L17 — `@MainActor` on enum `ARLogFmt` is unjustified isolation noise ✅
- **File:** `ARSessionLogger.swift:115`
- **Fix:** remove `@MainActor`. Stateless formatter.

### L18 — `nonisolated static let maxEvents = 500` ✅
- **File:** `ARSessionLogger.swift:23`
- **Fix:** add `nonisolated`.

### L19 — `updateUIView` does `coordinator.placementState = placementState` — structural no-op self-write ✅
- **File:** `ARPlacementView.swift:455-457`
- **Fix:** delete the line. The Binding already shares source of truth.

### L20 — Leftover `let binding = _trackingState; Task { @MainActor in ... }` patterns ✅
- **File:** `ARPlacementView.swift:729-738,752-775`
- **Fix:** drop redundant `@MainActor in` (Task inherits from enclosing main-actor method); drop redundant local Binding extractions where used synchronously.

### L21 — `isProcessingTap` guard doc-comment misdescribes what it defends ✅
- **File:** `ARPlacementView.swift:496-501`
- **Fix:** rewrite comment honestly OR replace with the real timestamp debounce (H6 fix covers this).

### L22 — Scene's placed entities not torn down in `dismantleUIView` ✅
- **File:** `ARPlacementView.swift:459-471`
- **Fix:** add `coordinator.scene?.clearPlacedEntities()` next to the overlay cleanup.

### L23 — Snapshot filename collision risk ✅
- **File:** `ARSessionLogger.swift:25-31`
- **Fix:** append `UUID().uuidString.prefix(6)` to `sessionId`.

### L24 — Unstructured Task in raycast-miss path never cancelled on dismantle ⏭️
- **File:** `ARPlacementView.swift:730-738`
- Becomes moot once the transient-hint refactor (C2) moves the toast off the trackingState binding. Resolved by C2.

### L25 — NSTemporaryDirectory fallback in `saveSnapshot` is invisible to UIFileSharingEnabled export ✅
- **File:** `ARSessionLogger.swift:55-58`
- **Fix:** if Documents is unavailable, mark a `lastSaveError` on the @Observable logger and surface in the HUD. (Tiny — defensive code that hides failure today.)

### L26 — `MeshResource.generatePlane` crash window on sub-epsilon / negative extents ✅
- **File:** `ARPlacementView.swift:622-624` + `ARScanningView.swift` mirror
- **Fix:** tighten guard to `width.isFinite, depth.isFinite, width > 0, depth > 0`.

### L27 — `DateFormatter` re-instantiated per `timeShort` call in eventLog rendering ✅
- **File:** `ARPlacementView.swift:188-192` + `ARScanningView.swift:163-167`
- **Fix:** `static let shortTimeFormatter`.

### L28 — `Tracking=Starting…` shown in red because `trackingTint` only matches `Normal`/`Limited` prefixes ✅
- **File:** `ARPlacementView.swift:237-241` + `ARScanningView.swift:172-176`
- **Fix:** add `Starting` to the yellow branch.

### L29 — No reset path from `.waitingForPlane` or `.readyToPlaceBall` ⏭️
- **Issue:** Only escape is Done (exits view entirely). Fine for DEBUG; worth a re-scan chip when slice goes user-facing in Slice 3+.
- **Deferred to Slice 3 user-facing AR work.**

---

## NOTE

### N30 — `Date()`-based throttles regress on backward wall-clock jump ⏭️
- **File:** `ARPlacementView.swift:505-510` + `ARScanningView.swift` mirror
- **Issue:** NTP correction or timezone switch backward could silently freeze the HUD throttle.
- **Fix planned for Slice 3 hardening pass:** switch throttle clocks to `CACurrentMediaTime()` (monotonic); keep `Date()` for event timestamps.

### N31 — `@State` initializers re-run on every parent body re-render ⏭️
- **Issue:** SwiftUI persists only first instance; per-render allocs are minor. Canonical fix `@State var logger: ARSessionLogger? = nil; assign in .onAppear`.
- **Cosmetic, deferred.**

---

## Scenario simulations (6/6 hit smells)

1. **Cold-start, hold-still 3s** — silent-wait failure (M12) — MEDIUM
2. **Incoming call mid-placement** — anchor corruption (H5) — HIGH
3. **Rapid double-tap** — ball+hole same spot (H6) — MEDIUM
4. **Camera denied** — small red HUD message, no Settings button (M11) — MEDIUM
5. **Plane removed mid-placement** — HUD says "Tap to place hole" while Planes=0 (covered by H5 recovery + auto-rollback) — MEDIUM
6. **30-min idle session** — ring buffer evicts sessionStart (M13) — MEDIUM

---

## Gemini vs Claude

Strong agreement on architectural defects; calibration disagreement on severity (Gemini called concurrent-ARSession CRITICAL on both files; Claude calibrated to HIGH/MEDIUM given DEBUG-only entry point).

**Gemini independently surfaced 2 findings Claude missed:**
- Anti-parallel aim-line quat branch (M15) — geometry-misunderstanding flag
- DateFormatter re-instantiation per row (L27) — trivial static-let fix

**Gemini missed:**
- Swift 6 strict-concurrency protocol-bridge (C1) — the build blocker
- `ARPlaneExtent.rotationOnYAxis` ignored (H3)
- "Aim at the floor" toast invisibility race (C2)
- Rapid double-tap race (H6)
- ARTrackingManager-dead-after-dismiss specific fix path (H4)

---

## Fix sequence

1. ✅ C1 — Swift 6 strict-concurrency bridges (build-blocker)
2. ✅ C2 — `transientHint` separate overlay
3. ✅ H3 — `rotationOnYAxis` plane overlay
4. ✅ H4 — `onDismiss` restart of ARTrackingManager
5. ✅ H5 — interruption recovery
6. ✅ H6 — real tap debounce
7. ✅ M/L cleanup pass (one file at a time)
8. ⏭️ Slice 3 deferred items (L24 resolved by C2; L29, N30, N31 → Slice 3)

---

## Pending: Gemini architecture review

Separately running a Gemini *architecture* check (not bug review) on whether the multi-ARSession approach + `AnchorEntity(world:)` + manual plane-overlay tracking is the right structural direction for Slice 3. Output captured in `docs/audit-findings-ar-slice-2-2026-05-31-gemini-architecture.md` after completion.
