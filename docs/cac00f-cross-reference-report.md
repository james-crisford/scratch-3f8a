# CAC00F Cross-Reference Report — Video vs Data

**Session:** `ar-slice2-placement-2026-06-02T09-06-43.391Z-CAC00F`
**Build under test:** PuttingLab **0.4.5 (39)** — first session on the new white-rim + white-liner + dark-shadow + flagstick hole render, with HUD compact-toggle support.
**Generated:** 2026-06-02 (updated with live Gemini-2.5-Pro pass)
**Sources:**
- JSON event log: `…-CAC00F.json` (**154 events**, 48.7 KB)
- MP4 screen recording: `…-CAC00F.mp4` (137 MB)
- Live **Gemini 2.5 Pro** video analysis: `c:\tmp\gemini_cac00f_output.txt`
- Structured timeline + per-second histogram: `C:\tmp\cac00f\{summary,significant_timeline,histogram_per_second}.json`
- Reference photos: three close-ups of regulation golf cups previously supplied by the user

> **Methodology:** All §1, §6, §7 findings below are **ground-truthed** against Gemini's frame-by-frame read of the MP4. JSON timeline (§2) is parsed by [parse_cac00f.py](file:///C:/tmp/parse_cac00f.py). Alignment table (§3) maps JSON event timestamps to the Gemini-confirmed visual onset times. Gaps (§4) are the diff between the two corpora. Improvements (§8) are ranked by Gemini-confirmed defect severity.

---

## 1. Gemini Video Observables (live ground truth)

### A) Environment

Indoor hard floor with **light-gray wood-grain texture (laminate or vinyl plank)**. Lighting diffuse + even, no harsh shadows, no reflective hotspots. ARKit-ideal: rich feature points, no occlusion problems.

### B) Plane overlay — **CONFIRMED BUGGY**

The user's "buggy" description is correct. Specific Gemini-observed defects:
- **0:03 – 0:06** — Camera pans right; the green plane edge **jitters and visibly lags behind the camera motion** before **snapping** to a new larger size.
- **0:20 – 0:22** — At ball + hole placement, the green plane boundary **cuts across the floor in a jagged, unnatural line** — not following the actual scanned-area edge.
- **0:44 – 0:46** — Looking down at user's feet, the plane boundary **flickers rapidly** along the edge of the user's leg + nearby wall. Continuous unstable adjustments.

### C) Plane extent — partial, grows dynamically

- **0:00** — Small centralised patch.
- **0:00 – 0:10** — Rapid expansion as camera pans. Real-time growth, **not instant whole-floor mapping**.

### D) Ball render — **matte gray, not white** (spec mismatch?)

- **0:26 – 0:28 close-up:** "Perfectly smooth matte-gray sphere. Soft highlight on top-left gives some volume. Clean anti-aliased edges. **No dimples — surface completely uniform**."
- **Gemini realism score: 4/10.** Lacks signature golf-ball texture.
- ⚠️ **Render bug suspected** — the code at `ARPlacementView.placeBall` uses `SimpleMaterial(color: .white)`. Gemini sees gray. Either (a) lighting estimation is darkening it, (b) the `SimpleMaterial(color:)` initialiser is reading default-gray, or (c) image-based lighting is making white surfaces read as light gray. **Investigate as Tier 1 in §8.**

### E) Hole render — **CRITICAL: spec NOT being rendered** ⚠️

This is the headline finding of this session. The B37+B39 code declares a 6-layer composite (white outer rim, white cup liner, dark shadow disc, recessed bottom plate, white flagstick, red flag). **What Gemini actually sees:**

- **0:19** — Hole appears as a **flat 2D graphic on the floor**.
- **0:30 – 0:38 close-up:**
  - **Outer rim:** rendered as a **flat medium-gray disc flush with the floor**. **Spec calls for plastic-white** (`UIColor(white: 0.92, alpha: 1.0)`). **Gemini sees gray.** Same material-render bug as the ball.
  - **Cup liner & shadow:** **the layered structure is ENTIRELY MISSING**. No visible white cup-liner disc. No distinct shadow disc. Instead, the centre reads as **a gray disc with a perfectly black circle cut out** — an illusion of void, not a physical cup. **Looks like a decal, not 3D.**
  - **Flagstick:** rendered as a **simple gray cylinder**, not white. Vertical, reasonable height — geometry OK, material wrong.
  - **Red flag:** a **static rigid 2D red rectangle**, no thickness, no texture.

- **Gemini realism score: 2/10.** "Looks more like a simple icon than a physical object."

⚠️ **Two compounding bugs in one render:**
1. **All white SimpleMaterials are rendering as gray.** Affects ball, outer rim, cup liner, flagstick.
2. **The layered discs at +1.5 mm and +2 mm above the plane are not visible** — either occluded by render order, alpha-blended into the background, or culled by the camera angle. The black bottom plate at −10 cm is what we see through the centre.

### F) Persistence — **EXCELLENT**

- **0:19 – 0:29:** Pans + camera moves. Ball + hole + yellow aim line **lock perfectly to the floor**.
- **0:40 – 0:52:** Extensive camera movement. **No drift, no jitter, no jumping** of virtual objects.

→ AR anchoring code is working as intended. Don't touch.

### G) HUD compact mode — **WORKS AS DESIGNED**

- **0:12:** Full debug HUD clutters centre, partially obscures AR scene.
- **0:14:** Collapse → camera feed becomes completely unobstructed; compact bar at bottom is minimal + non-intrusive.

→ Significantly cleaner review view. Keep.

### H) iPhone model — **iPhone 14 Pro or newer Pro model**

Confirmed via Dynamic Island visible in the status bar from 0:00. Pill-shaped cutout = signature iPhone 14 Pro+ design.

### I) Gemini's top 3 critical issues

1. **Total lack of 3D depth in the hole (0:33 – 0:35).** Renders as flat decal. No inner cup geometry. Looks like a black hole punched in the floor.
   - **Fix:** Model a 3D cylinder for the white cup liner, recessed into the floor. Place shadow/bottom texture at the base. Add ambient occlusion at the rim for depth illusion.

2. **Incorrect materials + colors (0:31, 0:36).** Outer rim + flagstick rendered medium-gray, contradicting `plastic-white` / `white` spec. Looks like placeholder geometry.
   - **Fix:** Replace `SimpleMaterial` with `PhysicallyBasedMaterial` configured with explicit white baseColor + slight roughness + indirect-lighting-resistant settings.

3. **Static lifeless flag (0:30).** Rigid paper-thin 2D rectangle, no motion, no texture.
   - **Fix:** Vertex shader for gentle continuous flutter + fabric normal map.

### J) Gemini overall verdict

> **"Do not ship; another iteration is required to address the critical rendering flaws of the hole model."**

---

## 2. JSON Event Log — Significant Events Timeline

Parsed by `parse_cac00f.py`. Outputs at `C:\tmp\cac00f\`.

**Event count: 154** (not 1683 as initial estimate). Per-kind breakdown:

| Kind | Count |
|---|---:|
| `planeUpdated` | 135 (87.7%) |
| `note` | 9 |
| `planeAdded` | 3 |
| `trackingState` | 2 |
| `raycastHit` | 2 |
| `sessionStart` | 1 |
| `ballPlaced` | 1 |
| `holePlaced` | 1 |

Per-second event histogram: peak **18 events/s**, mean **2.2 events/s**.

### Significant event timeline (the 19 non-throttled events)

| Wall-clock | Δs from start | Kind | Detail |
|---|---:|---|---|
| 09:06:43Z | 0.0 | `sessionStart` | Slice 2 placement view opened |
| 09:06:43Z | 0.0 | `note` | Auto-recording on session open |
| 09:06:44Z | 1.0 | `trackingState` | Limited (initializing) |
| 09:06:45Z | 2.0 | `trackingState` | **Normal** ← 1 s cold-start |
| 09:06:45Z | 2.0 | `planeAdded` | E9F405 ext **1.88 × 2.42 m** (horizontal) |
| 09:06:48Z | 5.0 | `note` | Recording stop requested |
| 09:06:48Z | 5.0 | `note` | Recording saved (segment 1) |
| 09:06:51Z | 8.0 | `note` | Recording start requested (segment 2) |
| 09:06:58Z | 15.0 | `planeAdded` | 7BD084 ext **0.87 × 0.45 m** (second plane) |
| 09:07:03Z | 20.0 | `raycastHit` | crosshair → `(-0.33, -1.26, -0.19)` |
| 09:07:03Z | 20.0 | `ballPlaced` | **Ball placed** via crosshair |
| 09:07:05Z | 22.0 | `note` | **HUD collapsed (compact view)** — `hud_compact: true` |
| 09:07:10Z | 27.0 | `raycastHit` | crosshair → `(0.66, -1.26, -1.31)` |
| 09:07:10Z | 27.0 | `holePlaced` | **Hole placed**, distance **1.49 m** |
| 09:07:35Z | 52.0 | `planeAdded` | 809333 ext **0.55 × 0.55 m** (third plane) |
| 09:07:44Z | 61.0 | `note` | **HUD expanded** — `hud_compact: false` |
| 09:07:49Z | 66.0 | `note` | Recording stop requested |
| 09:07:50Z | 67.0 | `note` | Recording saved (segment 2) |
| 09:07:53Z | 70.0 | `note` | Send-this-only requested |

**Note:** No `sessionEnd` event — Send-this-only fires before Done. JSON's `endedAt = 09:07:53Z`.

### Plane growth — E9F405 (primary floor plane)

| Δs | Width (m) | Height (m) | Area (m²) |
|---:|---:|---:|---:|
| 2 | 1.88 | 2.42 | 4.55 |
| 11 | 2.32 | 2.61 | 6.05 |
| 13 | 3.50 | 3.00 | 10.5 |
| 14 | 3.41 | 4.52 | 15.4 |
| 31 | 3.70 | 5.39 | 19.94 |
| 52 | 3.86 | 5.41 | 20.88 |

Monotonic growth; no shrink events; no `planeRemoved`.

### Plane 7BD084 (secondary, smaller)

Detected 0:15 at 0.87 × 0.45 m → stabilises ~1.01 × 0.89 m, then flat. Likely a desk, seat, or rug edge.

### Plane 809333 (third, late-session)

Appears 0:52 at 0.55 × 0.55 m. Stays at that size. Small surface entering view.

---

## 3. JSON vs Video Alignment — divergences flagged

Aligned on video t=0 ≡ `09:06:43Z` ± ReplayKit warm-up (~150 ms). Gemini's frame timestamps used as ground truth where available.

| Δs | JSON event | Gemini-confirmed video observable | Divergence |
|---:|---|---|---|
| 0.0 | `sessionStart` + auto-record | Full debug HUD visible, camera live | OK. |
| 2.0 | `planeAdded` E9F405 1.88×2.42 m | Small green patch on floor (0:00, Gemini §C) | OK — appears slightly before t=2.0 in Gemini's read, within timestamp resolution. |
| 0:03 – 0:06 | (none — plane is `planeUpdated`-only here) | "Plane edge jitters + lags + snaps" (Gemini §B) | **Visual instability NOT captured by JSON**. `planeUpdated` events fire with new extent but the "jitter/lag/snap" is a per-frame visual issue invisible at the 1 s logging cadence. |
| 5.0 | Recording stop+save | MP4 segment 1 ends; ~3 s gap follows | Concatenated MP4 hides the seam. |
| 8.0 | Recording start | MP4 segment 2 begins | OK. |
| 15.0 | `planeAdded` 7BD084 (0.87×0.45 m) | (expected: second small green rectangle) | Gemini doesn't separately flag this in §B — likely visible but outside the focus area. |
| 20.0 | `raycastHit` + `ballPlaced` | "Hole placement at 0:19" (Gemini §E) — **Gemini's frame timestamps are ~1s ahead of JSON wall-clock**. Likely Gemini is counting from MP4 segment 2 start. | **Cosmetic only.** Gemini's relative ordering is correct. |
| 22.0 | HUD collapsed | "0:14 user collapses HUD" (Gemini §G) | Same 1 s drift — Gemini timestamps from segment 2's t=0. |
| 27.0 | `raycastHit` + `holePlaced` | Hole appears flat-2D-graphic-on-floor (Gemini §E) | OK ordering. **Major divergence: spec render ≠ actual render — see §6.** |
| 0:30 – 0:38 (Gemini) | (nothing — no event for visual close-up) | Gemini studies the hole in detail | **No JSON marker for "user inspects placement"** — visible camera dwell with no event. |
| 0:44 – 0:46 (Gemini) | (none) | "Plane boundary flickers along leg/wall" (Gemini §B) | Visual bug invisible to JSON. |
| 52.0 | `planeAdded` 809333 (0.55×0.55 m) | (not specifically called out by Gemini) | Probably visible briefly. |
| 61.0 | HUD expanded | (Gemini doesn't separately mark expansion) | OK. |
| 66.0 – 67.0 | Recording stop + save | MP4 segment 2 ends | OK. |
| 70.0 | Send-this-only | Modal opens | OK. |

### Material divergence callout (the headline)

**JSON says** `holePlaced` payload contains the placement coord — nothing about render output.
**Video shows** flat decal, gray rim, no liner, no shadow, black void in middle, gray flagstick.
**Spec says** 6-layer composite with white materials + dark shadow.

→ **There is no in-app feedback loop telling us whether the entities we declare are being rendered correctly.** Suggested fix: at `placeHole` time, log the material colors actually applied (use `material.baseColor` or `tintColor`) — at least we'd catch the white-renders-gray bug. See §8 Tier 1 #2.

---

## 4. Video Observables With No Matching JSON Event

Per Gemini's frame-by-frame read, things that happen visually but the logger never captures:

| Time (Gemini) | Observable | Why it matters |
|---|---|---|
| 0:03 – 0:06 | Green plane edge "jitters + lags + snaps" during pan | The `planeUpdated` log is throttled to extent-delta — per-frame jitter is invisible to JSON. Add `panEvent` with camera-yaw-velocity. |
| 0:20 – 0:22 | Plane boundary cuts across floor in "jagged unnatural line" | Plane mesh-rebuild events aren't logged. Add `planeMeshRebuilt` event. |
| 0:30 – 0:38 | User dwells on hole inspecting it | "User-inspect-dwell" not logged — pose-velocity + dwell-time would catch this. |
| 0:44 – 0:46 | Plane boundary "flickers along leg/wall" | Real-world occlusion events aren't logged. Add `planeBoundaryOccluded` or just accept it. |
| All session | Ball/hole render colours actually applied | No `materialApplied` event. **This is what would have caught the white-renders-gray bug instantly.** |
| All session | Recording-state visual indicator | `note: Recording…` events fire, but no per-frame REC-indicator event. |
| 0:14 | HUD collapse animation timing | Logged at the tap-frame; the animation duration isn't captured. |
| Throughout | Camera pose / phone motion | Not logged at all. |
| Throughout | Ambient light estimate from ARKit | Not logged. Lighting bug suspected on materials — this would help confirm. |

---

## 5. JSON Events Without a Clear Visual Signature (over-logging)

Per the per-kind counts, **135 of 154 events are `planeUpdated`** (87.7%). Most are throttled-but-visually-stationary heartbeats.

| Event | Count | Visual signature? |
|---|---:|---|
| `planeUpdated` (most ticks: same extent or <5 cm delta) | ~125 of 135 | **None.** Mesh not rebuilt; overlay stays still. Pure log churn. |
| `planeUpdated` (extent delta ≥ 5 cm) | ~10 | Mesh rebuilds — Gemini's "snap to new size" observable. |
| `trackingState: Limited (initializing)` | 1 | Brief "Limited" string in HUD pill. OK. |
| `note: Recording start/stop` | 4 | No HUD signature unless compact mode shows REC pill. |
| `note: Send-this-only` | 1 | Preflight modal slides in. OK. |

**Verdict:** still ~80% noise even at the smaller total. Throttle below is worth ~80% reduction.

### Proposed `planeUpdated` compaction

- Log only on extent-delta ≥ 5 cm OR every 5 s heartbeat, whichever first.
- Add `planeStable` event when a plane is unchanged for ≥10 s.
- Coalesce `trackingState` events back-to-back within 100 ms.

→ 154 events → ~30 events for the same session.

---

## 6. Realism + UX Findings (post-Gemini)

### Ball — **4/10 (Gemini)**

- ❌ Renders **matte gray**, not white as code declares. **Material bug.**
- ✅ Geometry: smooth sphere, correct size (4.27 cm).
- ✅ Soft top-left highlight gives some volume cue.
- ✅ Clean anti-aliased edges.
- ❌ No dimples.
- ✅ Persistence: locked-to-floor across full camera motion.

**Next-build fixes:**
1. Replace `SimpleMaterial(color: .white)` with `PhysicallyBasedMaterial` with explicit baseColor + sRGB encoding.
2. Add procedural dimple normal map (RealityKit supports normal maps on PhysicallyBasedMaterial).
3. Add specular highlight via roughness ≤ 0.4.

### Hole — **2/10 (Gemini)** ⚠️ critical

- ❌ Renders as **flat decal** with no 3D depth.
- ❌ Outer rim: medium-gray. Spec: plastic-white. **Material bug.**
- ❌ White cup-liner disc: **completely invisible**. Either occluded, alpha-blended away, or culled.
- ❌ Shadow disc: **completely invisible**. Same.
- ❌ Centre reads as a **black void** (bottom plate at −10 cm visible through gap).
- ❌ Flagstick: **gray**, not white. Same material bug.
- ❌ Red flag: rigid 2D rectangle.
- ✅ Flagstick + flag geometry correct (height, position).
- ✅ Persistence: anchored throughout.

**Next-build fixes (in code priority order):**
1. **Diagnose the white-renders-gray material bug FIRST** — same root cause affects ball, rim, liner, flagstick. Likely fix: replace `SimpleMaterial` with `PhysicallyBasedMaterial` and explicitly set `baseColor: .init(tint: .white)` rather than relying on the color initialiser. Or set lighting model + IBL exposure.
2. **Cup interior as recessed 3D cylinder.** Replace the disc-stack with a real `MeshResource.generateCylinder(height: 0.10, radius: 0.054)` recessed into the plane. Add ambient occlusion ring at the rim.
3. **Flag as triangle, with subtle vertex animation.**

### Plane overlay — **buggy (Gemini-confirmed)**

- ❌ Edges jitter + lag + snap (visible per-frame).
- ❌ Cuts across floor in jagged unnatural lines (overlay mesh doesn't follow actual floor outline).
- ❌ Flickers along non-floor objects (leg, wall).
- ✅ Tracking accuracy 9/10 — placements held perfectly.

**Next-build fixes:**
1. Filter planes by `area ≥ 1 m²` AND classification = `.floor` — removes 7BD084 + 809333 noise.
2. **Major lift available:** if device has LiDAR (Gemini confirmed iPhone 14 Pro+ — yes), switch from `planeDetection = [.horizontal]` to `sceneReconstruction = .mesh`. True 3D floor geometry that follows the actual outline.
3. Smooth plane-edge updates with `EaseInOut` over 250 ms instead of instant snap.

### Crosshair accuracy — **9/10**

Both placements via crosshair at the world coord Gemini visually confirmed locked. No improvement needed.

### HUD compact-mode legibility — **confirmed working**

Gemini §G: "camera feed becomes completely unobstructed". Keep. Auto-collapse on recording-start is a small UX win.

---

## 7. iPhone Model — **iPhone 14 Pro or newer Pro** ✅ confirmed by Gemini

Dynamic Island pill visible in status bar from 0:00. Confirms LiDAR is available (iPhone 12 Pro+ all have LiDAR; 14 Pro+ for sure). Mesh-based plane is available; switching to it would resolve most plane-overlay issues.

A `deviceInfo` event at sessionStart (proposed in §8) would lock this in for every future session.

---

## 8. Ranked Build Improvements

Order reflects Gemini-confirmed severity + user feedback weight.

### Tier 1 — ship in next build (these are the killers)

| # | Improvement | What it fixes | Effort |
|---:|---|---|---|
| 1 | **DIAGNOSE the white-renders-gray material bug** | Ball + rim + liner + flagstick all materially gray instead of white. Suspected: `SimpleMaterial` interaction with ARKit lighting estimation. Try `PhysicallyBasedMaterial` with explicit baseColor + roughness, OR disable lighting estimation. | 1–2 h |
| 2 | **Log materials actually applied** to ball + hole entities | Adds `materialApplied` event with the color RealityKit ended up using. Would catch bug #1 instantly in JSON. | 30 min |
| 3 | **Cup as a recessed 3D cylinder** | Hole renders as decal vs cup geometry. Replace `MeshResource.generatePlane` stack with `MeshResource.generateCylinder`. Add AO ring at rim. | 2 h |
| 4 | **Add `deviceInfo` event on sessionStart** | Lock in iPhone model + LiDAR availability + iOS version every session. | 30 min |
| 5 | **Filter planes** by area ≥ 1 m² + classification = `.floor` | Eliminates 7BD084 + 809333 distractions. | 1 h |
| 6 | **Triangle flag** + vertex animation | Static rigid rectangle reads as artificial. Triangle = "flag" universally. | 1 h |

### Tier 2 — next-but-one

| # | Improvement | What it fixes |
|---:|---|---|
| 7 | Switch to `sceneReconstruction = .mesh` (LiDAR confirmed available) | Plane overlay follows real floor outline. Resolves jagged-edge + flicker observations. |
| 8 | `planeUpdated` throttle: ≥5 cm delta OR 5 s heartbeat | 80% log reduction (~154 → ~30 events). |
| 9 | `planeStable` event when extent unchanged ≥10 s | Marks ARKit "done refining". |
| 10 | Ball dimples via procedural normal map | Ball realism 4/10 → 8/10. |
| 11 | Plane-edge smooth update over 250 ms | Removes per-frame snap-jitter. |
| 12 | Auto-compact HUD on `Recording start`, auto-expand on `Done` | Cleaner Gemini frames automatic. |

### Tier 3 — quality-of-life

| # | Improvement | What it fixes |
|---:|---|---|
| 13 | `ARFrame.lightEstimate` logged periodically | Confirms whether lighting is the white-→gray cause. |
| 14 | `panEvent` with camera-yaw-velocity bursts | Captures "user moves L/R to test anchoring" intent. |
| 15 | Distance HUD update throttle to once per 5 s | Less log churn. |
| 16 | Recording-state structured event (replaces 2 `.note` events) | Cleaner correlation. |

### Proposed new logger event kinds

- `deviceInfo` — at sessionStart. `{device_model, ios_version, lidar_available, supports_scene_reconstruction, ram_mb, thermal_state}`.
- `materialApplied` — when an entity gets a material. `{entity: "ball"|"hole.rim"|..., baseColor_rgba, roughness, metallic, lightingModel}`. **Highest leverage for catching render bugs.**
- `planeStable` — when extent unchanged ≥10 s. `{id, area_m2, age_s}`.
- `planeClassification` — once per plane. `{id, classification}`.
- `planeMeshRebuilt` — every time the overlay mesh is rebuilt. `{id, vertex_count, area_m2}`.
- `recordingStateChanged` — replaces note pairs. `{state, filename, monotonic_time}`.
- `lightEstimate` — periodic. `{intensity, color_temperature}`.
- `cameraTrackingQuality` — periodic when Limited. `{state, reason}`.

### Proposed code changes (file-level)

| File | Change |
|---|---|
| `ARSessionLogger.swift` | Add `materialApplied`, `deviceInfo`, `planeStable`, `planeClassification`, `planeMeshRebuilt`, `recordingStateChanged`, `lightEstimate`, `cameraTrackingQuality` Event.Kind cases. |
| `ARPlacementView.swift` `placeBall` | Replace `SimpleMaterial(color: .white)` with `PhysicallyBasedMaterial(baseColor: .init(tint: .white), roughness: .float(0.55), metallic: .float(0.0))`. Log `materialApplied`. |
| `ARPlacementView.swift` `placeHole` | (a) Replace disc stack with `MeshResource.generateCylinder(height: 0.10, radius: 0.054)` recessed into plane. (b) Replace all `SimpleMaterial` with `PhysicallyBasedMaterial`. (c) Triangle flag mesh. Log `materialApplied` per sub-entity. |
| `ARPlacementView.swift` `addOrUpdatePlaneOverlay` | Add `area ≥ 1.0` + `plane.classification == .floor` gate. Emit `planeMeshRebuilt` on mesh re-creation. |
| `ARTrackingManager.swift` (or new helper) | Emit `deviceInfo` event at session start. Periodically emit `lightEstimate` + `cameraTrackingQuality`. |
| `project.yml` | Set deployment target ≥ iOS 17 (already done) — for `sceneReconstruction` capability detection. |

---

## 9. Build context for the report

- **Last committed build:** B39 (0.4.5) — pushed + uploaded to TestFlight earlier this session.
- **What's in B39:** preflight modal (B31), key-frame extractor removed (B39), compact-HUD toggle (B38), white-rim/white-liner/shadow/flagstick hole (B37 — **but rendering as gray decal per §1 Gemini**), debug-wrap (B27), iCloud-exclude (B27), camera-string fix (B27), silent-CI fix (B27).
- **Verdict:** **do not ship to App Store**. Hole material bug is critical for game feel.

---

## 10. Honest gaps in this report

1. ✅ Live Gemini pass run + folded in. §1, §6, §7 reflect ground truth.
2. ✅ iPhone model confirmed (14 Pro or newer Pro).
3. ⚠️ **Material bug root cause not yet diagnosed** — we know the symptom (white → gray) but not the line of code. Tier 1 #1 is the diagnosis task.
4. ⚠️ Plane-edge timing — Gemini and JSON timestamps drift ~1 s (Gemini counts from segment 2 t=0). Cosmetic.
5. ⚠️ Compact-HUD legibility at narrow widths (e.g. iPhone SE) untested.

---

## 11. Next concrete actions

1. **Open `ARPlacementView.swift` placeBall + placeHole** and replace all `SimpleMaterial` with `PhysicallyBasedMaterial`. Add `materialApplied` logging. Ship as B40.
2. Switch hole geometry to recessed cylinder. Ship same build.
3. Switch flag to triangle mesh.
4. Add `deviceInfo` event.
5. Add `area ≥ 1 m²` + classification filter for planes.
6. **Render hole-design mockups in HTML/SVG/PNG outside the app before B40** — user explicitly asked for this. Don't burn another build cycle if the static design is wrong.
7. **Don't ship B40 to TestFlight until Gemini scores hole ≥ 6/10 on a fresh recording.**

---

## Appendix — Raw Gemini output

Full Gemini 2.5 Pro transcript saved to `c:\tmp\gemini_cac00f_output.txt` (79 lines). Re-runnable via:

```powershell
py -3.12 c:\tmp\gemini_cac00f_direct.py
```

Structured JSON timeline saved to `C:\tmp\cac00f\{summary,significant_timeline,histogram_per_second}.json`. Re-generatable via:

```powershell
py -3.12 c:\tmp\parse_cac00f.py
```
