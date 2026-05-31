# Gemini AR Architecture Review — 2026-05-31

**Question asked:** Is the multi-ARSession + AnchorEntity(world:) + manual plane-overlay tracking the right structural direction for Slice 3, or is it Slice-3 debt we'll have to pay later?

**Source:** `gemini-2.5-pro` via `tools/code_review/gemini_review.py` over `ARPlacementView.swift`, `ARScanningView.swift`, `ARSessionLogger.swift`, `ARTrackingManager.swift`.

## Headline verdict

> **Multiple conflicting ARSession instances is a critical architectural flaw, not just technical debt. Refactor to a single shared ARSession before Slice 3.**

## Verbatim recommendation

> The application architecture creates multiple `ARSession` objects, which is not supported and leads to major conflicts.
>
> - `ARTrackingManager` creates and manages one `ARSession` for background pose tracking.
> - `ARScanningView` and `ARPlacementView` each create a *new, separate* `ARSession` when they are presented.
>
> When a new `ARSession` is started by one of the views, it will take over system resources (camera, motion sensors), effectively pausing or terminating the session running in `ARTrackingManager`. This leads to:
> - Loss of tracking in other parts of the app.
> - Unpredictable behavior when switching between views.
> - Increased battery and CPU usage from tearing down and setting up AR sessions repeatedly.
> - A fragile dependency where one component (`ARTrackingManager`) must be manually restarted after another is used, as noted in the comments.
>
> **Refactor to use a single, shared `ARSession`.** Managed by a singleton or passed via environment. Views like `ARScanningView` should NOT create a new session but should get access to the shared one. They can then configure it (e.g., enable plane detection) when they appear and pause it or reset the configuration when they disappear.

## Other architectural calls

### 1. Code duplication between Slice 1 and Slice 2 Coordinator classes
> Create a common base class for the Coordinator or extract shared functionality into a helper object. Reduces duplication and prevents the "fix applied in one place but not the other" bug.

**Today's reality:** the just-shipped audit already found this — `addOrUpdatePlaneOverlay`, throttle logic, tracking-state formatter, delegate scaffolding all duplicated between Slice 1 and Slice 2. The fix is to lift them into a shared `ARSceneController` (or similar) once Slice 3 collapses the two debug views into one production AR layer.

### 2. ARTrackingManager interruption handling is destructive
> `sessionInterruptionEnded` immediately resets tracking with `.resetTracking, .removeExistingAnchors`. This discards the world map. If the user just switched apps for a second, the default behavior (no `session.run` call) would attempt relocalization, which might be preferable. Evaluate against desired UX.

**Today's reality:** for stroke-detection pose-only use, discarding the world map costs only ~5s of relocalisation time — acceptable for B17/B18. Once Slice 3 places ball/hole in the AR scene, relocalisation becomes mandatory (otherwise placed entities float). The CLAUDE.md plan for Slice 3 should swap `.resetTracking + .removeExistingAnchors` for plain relocalisation.

### 3. Rapid-tap race acknowledged but not flagged as fix-blocker
> The `isProcessingTap` flag is a "good defense" — Gemini doesn't push this further. (The Claude audit + simulation independently identified the same defect and proposed a proper timestamp-based debounce; Gemini's bar was lower here.)

## Acknowledged good practices

> - Proper use of `@MainActor`, `Sendable`, and `@unchecked Sendable` with manual locking — strong understanding of modern Swift concurrency.
> - The `ARSessionLogger` is excellent — detailed, real-time feedback + persistent snapshots for debugging.
> - Defensive handling of camera permission, session interruptions, rapid user input.
> - Translucent plane overlays + transient HUD messages — thoughtful UX in an AR context.

## False positive flagged

> Gemini reported "Corrupted Property Wrappers" claiming `@Environment(\.dismiss)` and `@State` are malformed with paths like `@.claude\skill-sources\...` and `@data\estate_offsite_backup.log`. **This is a Gemini-2.5 hallucination** (documented in user memory `feedback_gemini_hallucinated_decorator`). The actual files use canonical `@Environment(\.dismiss) private var dismiss` and `@State private var placementState: PlacementState = .waitingForPlane`. Ignored.

## What this changes for Slice 3 planning

**Decision required:**

1. **Single shared ARSession** — register `ARTrackingManager` (or a renamed `ARSessionService`) as the sole owner. Slice 1 / Slice 2 / Slice 3 views all read from it.
   - Plane detection is reconfigured on present (`config.planeDetection = [.horizontal]`) and reverted on dismiss.
   - Avoids the dual-session zombie problem entirely; the H4 onDismiss-restart fix becomes redundant.
   - Cost: requires injecting the shared session into the SwiftUI environment + threading through `ARView(automaticallyConfigureSession: false)` with the existing session attached.

2. **Or — accept the current 3-session pattern but harden it** with explicit pause/resume around presentations (matches the existing CLAUDE.md plan).
   - Cheaper to ship near-term.
   - Keeps Slice 1 / Slice 2 verification as standalone harnesses.
   - Carries the multi-session risk Gemini called CRITICAL into production.

**Recommendation (from this audit, James to decide):** option (1) — single shared session — before Slice 3 wires stroke trajectories into the AR scene. Otherwise the H5 "interruption corrupts anchor positions" bug compounds across every session swap.

## Open questions for James

- Should `ARTrackingManager` be renamed to `ARSessionService` and made the source of truth for the camera + IMU session? Or keep its current pose-only responsibility and add a separate `ARSceneCoordinator` for scene-graph concerns?
- Switch `AnchorEntity(world:)` → `AnchorEntity(anchor:)` for ball/hole so they track the plane through ARKit refinement? (Would fix H5 properly rather than the cheap-reset workaround.)
- Replace the manually-maintained `planeOverlays: [UUID: AnchorEntity]` dictionary with `AnchorEntity(plane: .horizontal, classification: .floor)` which auto-tracks any detected plane? (Loses per-plane overlay control but matches RealityKit idiom.)
