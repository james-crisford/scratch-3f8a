# PuttingLab Pre-Test Audit — code, UX, instrumentation

**Build under audit:** PuttingLab 0.4.7 (41) — commit `8f8cb75` (B41 + hotfix).
**Files reviewed:** `ARPlacementView.swift` (2030 lines), `ARMeshManager.swift`, `ARSessionLogger.swift`, `ARLogShareSheet.swift`, `ARScreenRecorder.swift`. Manual deep-read — no Gemini, no recording.
**Date:** 2026-06-02.

This is the work I could do without a fresh B41 recording on your iPhone 13 Pro Max — review the code that's about to be exercised, find bugs/regressions/gaps before you spend your time installing + testing, and rank what to fix in B42.

---

## Tier 0 — defects that will SHOW UP in your B41 recording

These are real issues you'll see when you open B41, not theoretical concerns. Fix before next test.

### 1. Double overlay on LiDAR devices — RECTANGLE plane overlay AND triangle mesh overlay both render ⚠️

In `Coordinator.session(didAdd:)`, when an `ARPlaneAnchor` lands we still call `addOrUpdatePlaneOverlay(plane)` regardless of whether LiDAR is active. The B40 plane filter (area ≥ 1m² + classification = floor) doesn't know about LiDAR. So on your iPhone 13 Pro Max:

- The big rectangular green plane overlay you saw in CAC00F will still appear (filtered to floors only)
- ON TOP of it, the new B41 triangle-mesh overlay also renders

**Visible defect:** two greens stacked, the rectangle "underneath" peeking out at the edges where the mesh hasn't populated yet. Will probably confuse Gemini's read.

**Fix:** in `addOrUpdatePlaneOverlay`, early-return if `lidarActive` (the Coordinator already has the flag) — the LiDAR mesh is strictly better, no need for the fallback rectangle. Keep the planes as raw `ARPlaneAnchor` entries (for raycast targets) but don't draw them. ~5 lines.

### 2. Z-fighting between the mesh overlay and the actual floor texture

`rebuildMeshOverlay` puts the green triangle mesh at `AnchorEntity(world: .zero)` and the floor triangles are already at the world-Y of the LiDAR-scanned floor. **Same Y as the floor surface** → the green triangles z-fight with the camera-feed pixels (visible as flickering / patchy green / weird shimmer along triangle edges as the camera moves).

**Fix:** lift the overlay 1–3 mm above the LiDAR-detected floor. Either in `ARMeshManager.makeSnapshot` add a constant Y-offset to each floor vertex, or in `rebuildMeshOverlay` set the entity transform with `y = +0.002`. ~2 lines.

### 3. Back-face triangles double the GPU cost without visible benefit

`buildFloorMesh()` emits both winding orders (front + back) per triangle. The floor never gets viewed from below — that's literally impossible. We're submitting 2× geometry for no win.

**Fix:** drop the back-face indices in the inner loop of `buildFloorMesh`. ~3 lines, also resolves a subtle blending artifact at near-grazing angles.

### 4. `recorder.stop` completion handler is not main-actor-safe

Lines 503–510 (`stopRecordingAsync`), 519–530 (`toggleRecording`): the closure passed to `recorder.stop { url in … }` is `@Sendable`. Inside it we mutate `isRecording` (main-actor) and call `logger.log` (main-actor) directly. Swift 6 emits a warning; Apple's ReplayKit completion semantics don't guarantee main-queue dispatch, so this is a real race.

**Fix:** wrap the body in `Task { @MainActor in ... }`. Already a known pattern in this file (`showTransientHint` at line 291 does it correctly). ~4 lines.

### 5. `ARRaycastQuery.Target.existingMeshGeometry` is not a real iOS API — already fixed but worth flagging in goal docs

I removed it from the raycast chain in the hotfix (commit `8f8cb75`). The `/goal` text still references it as a deliverable. Documentation drift — the goal is satisfiable as I implemented it (plane + estimated fallback), but the wording was wrong. Worth correcting in any future LiDAR goal you write.

---

## Tier 1 — should fix before B42 ships

### 6. `floorAreaM2` accumulates Float — precision loss in large rooms

`ARMeshManager.floorAreaM2` sums `Float` triangle areas. With ~1000 sub-cm² triangles per m² in a real LiDAR scan of a 20 m² room, sum-of-tiny-floats hits the 24-bit mantissa limit. The reported number drifts by 5–10% at the high end.

**Fix:** accumulate as `Double` in `makeSnapshot` + the `floorAreaM2` accessor, cast to Float only at the JSON-emission boundary. ~6 lines.

### 7. Mesh classification buffer may be nil for the first 1–3 seconds — overlay is invisible until first didUpdate

In `ARMeshManager.makeSnapshot` we early-return an empty snapshot if `geometry.classification` is nil. This is correct behaviour, but the user sees NO green overlay during that window — and there's no log event explaining the wait.

**Fix:** emit a `note: "LiDAR mesh detected, awaiting classification"` event the first time we see a mesh anchor without a classification buffer. Quick way to distinguish "LiDAR broken" from "LiDAR warming up" when reading a JSON later.

### 8. Stillness hint counter never explicitly checked — relying on `.onChange(of: planeCount)` to clear

`firstStillAt` is set in `.onAppear` and `showStillnessHint = true` happens in the 0.5 s timer if `planeCount == 0` for >2 s. But on LiDAR devices, the LiDAR mesh can populate without any planes being detected — so the hint says "Try slowly panning the phone" even though the mesh is already working fine.

**Fix:** the silent-wait check should look at `meshManager.anchorCount > 0 || planeCount > 0`. ~3 lines.

### 9. No teardown of `meshOverlayEntity.model?.mesh` between rebuilds — memory growth

`rebuildMeshOverlay` reuses the entity but reassigns `entity.model?.mesh = resource`. Each `MeshResource.generate` allocates a fresh MTLBuffer for vertices. Until the previous one falls out of ARC scope (next ARKit frame typically) we're holding 2× geometry. For a 5,000-triangle floor that's ~120 KB; for a long scan with many rebuilds it can spike.

**Fix:** lower-priority — Apple's MetalBuffer pool handles this in practice. Worth profiling with Instruments before fix.

### 10. `materialApplied` event payload values are Strings but contain Double-formatted numbers — analyser has to parse them

`materialApplied` events from B40 use payload values like `"radius_m": "0.0214"`. Any analyser has to `Double($0)?` parse them. The JSON spec says payload is `[String: String]` so this is correct schema-wise, but it makes downstream tooling awkward.

**Fix:** change the JSON schema to allow `[String: AnyCodable]` so numbers are real numbers. Bigger refactor; consider for a future major version bump.

---

## Tier 2 — UX / UI polish

### 11. Compact-HUD default is OFF — every user hits two taps before getting clean Gemini frames

The user has to: open AR → tap eye icon to collapse HUD → record. Three actions for the canonical workflow.

**Suggestion:** default `hudCompact = true` for sessions where `isRecording = true at .onAppear` (every session now since B25 auto-recording). The HUD's only purpose is debugging — if we're recording for review, we want clean frames.

### 12. No "LiDAR ready" indicator in the HUD

A user testing B41 has no idea whether LiDAR has populated until they see the green mesh appear (or not). Add a row to the HUD: `LiDAR: 5.2 m² · 3 anchors · floor: 412 tris`. Reads at a glance, surfaces what `meshStats` already captures. ~10 lines of HUD code.

### 13. No haptic feedback on placement

`placeAtCenter()` fires immediately. A `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` after a successful raycast hit would make placement feel SOLID. One line at the success branch.

### 14. Crosshair is 56 pt diameter — blocks the cup on close-up shots

On iPhone 13 Pro Max (390 pt wide) at 1 m placement distance, a 10.8 cm cup projects to ~30 pt. Crosshair (56 pt) is 1.9× the cup — when aiming straight at it you literally can't see what you're aiming at.

**Suggestion:** shrink crosshair to 32 pt diameter, OR fade it to 25% opacity when raycast is hitting a surface (i.e. you know you'll hit something — the crosshair has served its purpose). Either fix ~5 lines.

### 15. "Done" button has no recording-still-active warning

If user is mid-recording and taps Done, `.onDisappear` saves the file silently. Net result is fine (no data lost) but a brief confirmation toast — "Recording saved · X seconds" — would tell the user it worked.

### 16. GT-marker taps have no visual confirmation

After tapping "📐 Plane wrong" the event goes in the JSON but the button doesn't change. User has no idea if the tap registered.

**Suggestion:** brief 0.5 s green pulse on the button background after tap. Two lines per marker.

### 17. "Start over" wipes ball + hole; no "just re-place the hole" option

Once you're at `.readyToPlaceHole(ballWorld)` and want to nudge the ball, you have to Start over. Common case: ball is fine, hole was misplaced.

**Suggestion:** at `.complete` state, add "Move ball" + "Move hole" buttons that drop back to the appropriate sub-state without wiping the other entity.

### 18. Distance HUD shows the raw number — no context

`"Distance: 1.49 m (4.9 ft)"` is information without judgement. For a putting app, the user wants to know "is this a short / medium / long putt"?

**Suggestion:** colour-code:
- 0.5 – 3 m → green (within "drainable" zone)
- 3 – 6 m → amber (lag putt territory)
- 6 m+ → red (long / unusual)

Plus a one-word label after the number: `"Distance: 1.49 m · short"`. Five lines.

### 19. Eye/eye.slash semantic is "show/hide content" — but it toggles HUD chrome

iOS users read the eye icon as "make this content invisible". Here it's "hide the debug overlays". Mismatch.

**Suggestion:** swap to `rectangle.dashed` / `rectangle` or label-only "HUD: off / HUD: on". One line change.

### 20. No way to view current `meshStats` mid-session in the HUD

`meshStats` events fire every 5 s but they only show up in the event log briefly. A power user testing B41 wants to SEE "my floor is 5.2 m² scanned, 412 floor-classified triangles, 0 wall-classified". Currently invisible until you parse the JSON post-session.

**Suggestion:** the proposed HUD row from #12 covers this.

---

## Tier 3 — instrumentation gaps for B42

### 21. No frame-rate logging

ARKit can drop frames under thermal pressure. A periodic `frameRate` event (every 5 s, avg over window) would surface performance regressions.

### 22. No thermal-state logging

`ProcessInfo.processInfo.thermalState` changes during long sessions. Worth logging on transition.

### 23. No `lightEstimate` event despite B40 promising it

The `lightEstimate` Event.Kind was added but no callsite emits it. The B40 hole-render bug was probably caused by ARKit's ambient light estimate being too dim — having this in the JSON would let me correlate "render gray" with "low-light state" without guessing.

**Fix:** in `Coordinator.session(_:didUpdate frame:)`, every ~5 s, log `frame.lightEstimate?.ambientIntensity` + `ambientColorTemperature`. ~8 lines.

### 24. No `recordingStateChanged` structured event

Currently we use two `note` events ("Recording start requested" + "Recording saved: <name>"). A real Event.Kind with payload would tighten correlation.

**Fix:** the kind exists in the enum (`recordingStateChanged`), just no callsite uses it. Replace the two `.note` calls in `toggleRecording`. ~6 lines.

### 25. No camera intrinsics logged

For any later 3D reconstruction work, `frame.camera.intrinsics` at session start would be useful. One-time emit alongside `deviceInfo`.

### 26. No `placementError` events for the case where raycast misses

`logger.log(.raycastMiss, "no horizontal surface under tap")` exists, but the equivalent crosshair branch in `placeAtCenter` just shows a toast and returns. Same event semantics, different shape — should be unified.

### 27. Sessions never log `sessionEnd` when "Send" is used

User taps Send → `endedAt` is set in the JSON. But there's no `sessionEnd` event. So when reading the JSON we can't tell "did this session end via Done or via Send". Minor but useful.

---

## Tier 4 — Documentation / process

### 28. B41 verification report skeleton is correctly marked PENDING

`docs/b41-lidar-verification.md` (commit `f19f3cc`) is the right shape — methodology + all sections present + status: PENDING. When you record, dropping the Gemini output into §1 is a 2-minute exercise. No fix needed.

### 29. Multi-file Gemini prompts now live in `c:\tmp\` — not durable

`c:\tmp\gemini_b41_prompt.txt` is in volatile temp space. If the machine reboots between recording and analysis, the prompt is gone. Move to a tracked location: `tools/code_review/prompts/gemini_b41_prompt.txt`.

### 30. CAC00F report's event-count error stayed in the original commit history

The first commit of `docs/cac00f-cross-reference-report.md` (`ec8e4ef`) said 1683 events; the live one (`b0aaf22`) corrected to 154. Anyone reading git blame on the first revision will see the wrong number with no flag. Not worth re-writing history; just worth knowing the diff exists.

---

## Recommended fix order for B42

1. **Tier 0 #1 + #2 + #3** (15 lines total) — fixes the double-overlay + z-fighting + back-face waste. These are the only items that will affect what Gemini sees in your B41 recording. If you want a clean B41 read, ship these as **B41a / 0.4.7a** before the next recording.
2. Tier 0 #4 (concurrency) — silent now (warnings), but a Real Race Condition. 4 lines.
3. Tier 1 #6 (Float→Double area) — easy, prevents reporting-error confusion.
4. Tier 1 #8 (stillness-hint LiDAR awareness) — quick UX win.
5. Tier 2 #11 (auto-compact-HUD) + #13 (haptic) + #14 (crosshair) — three small UX wins, ~30 min total work.
6. Tier 3 #23 (`lightEstimate`) — sets us up to debug the next render bug fast.
7. Everything else as backlog.

**Total estimated effort to ship a "B42 LiDAR-clean":** ~2 hours of focused work, single commit, single TestFlight build. Want me to do these now (no recording needed) and stack on top of B41?

---

## What I CANNOT audit without your recording

- Whether LiDAR mesh actually populates on your specific iPhone 13 Pro Max in your specific room
- Whether the green mesh visually reads as "following the floor outline" (vs my code-review intuition that says it should)
- Whether the white hole rim now renders white (B40 material fix) — I have no way to verify without Gemini eyes on a real frame
- Real performance: FPS, mesh-update latency, time-to-first-visible-overlay
- Real placement accuracy with LiDAR-tightened planes

For those, the loop is install → record → upload → I-run-Gemini. There's no substitute.
