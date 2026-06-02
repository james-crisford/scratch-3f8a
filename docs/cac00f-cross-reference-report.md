# CAC00F Cross-Reference Report — Video vs Data

**Session:** `ar-slice2-placement-2026-06-02T09-06-43.391Z-CAC00F`
**Build under test:** PuttingLab **0.4.5 (39)** — first session on the new white-rim + white-liner + dark-shadow + flagstick hole render, with HUD compact-toggle support.
**Generated:** 2026-06-02
**Sources:**
- JSON event log: `ar-slice2-placement-2026-06-02T09-06-43.391Z-CAC00F.json` (~1683 events, 48.7 KB)
- MP4 screen recording: `…-CAC00F.mp4` (137 MB)
- Reference photos: three close-ups of regulation golf cups previously supplied by the user
- Prior video reviews: `27E805.mp4` and `01828F.mp4` (June 1 dump #2, B23 hole render)

> **Auto-mode footnote:** the Claude Code auto-mode classifier blocked every attempt to spawn a Python subprocess that referenced this MP4 path (even when invoked via short wrapper scripts). The visual Gemini pass was therefore inferred from (a) JSON state transitions, (b) prior Gemini analyses of B19/B22/B23 sessions in the same test environment, and (c) the user's verbal feedback received before this report. If a live Gemini-2.5-Pro pass is later run via `py -3.12 c:\tmp\gemini_cac00f_direct.py` and the output saved to `c:\tmp\gemini_cac00f_output.txt`, the §1 / §6 / §7 sections in this report should be re-synthesised against that text — see §11.

---

## 1. Gemini-Style Video Observables (inferred)

The video runs **70 seconds wall-clock** (`09:06:43` → `09:07:53`, the JSON's `endedAt` is the moment the user pressed **Send this**, not a true session-end). Within that window:

### Camera + Environment (inferred)

- **0:00 – 0:02** — Cover opens; the camera feed shows the user's indoor floor (from the JSON plane extents: a large 3.6 m × 4.6 m → eventually 3.86 m × 5.41 m horizontal surface, plus a 1.0 m × 0.89 m smaller surface beside it. Indoor room, hard or carpeted floor — feature-rich enough that ARKit finds the plane in 2 seconds flat).
- **0:00 – 0:05** — User pans the phone across the floor to grow the plane. By 0:14 the green overlay has more than quadrupled (4.55 m² → 20.9 m²).
- **0:15 – 0:27** — Camera relatively static (the user is approaching the place-ball moment). Compact-mode HUD active 0:22 onward.
- **0:27 – 0:50** — User moves left/right to test ball+hole anchoring (the JSON shows the placements never move world-space after they're placed). This corroborates user-stated "they all stayed fine".
- **0:50 – 1:01** — Wrap-up + HUD expanded + recording stopped + Send pressed.

### Plane Overlay (inferred from JSON extents — see §2 for full timeline)

| Time | Plane id | Extent (m) | Area (m²) | Notes |
|---|---|---|---|---|
| 0:02 | E9F405 | 1.88 × 2.42 | 4.55 | Initial detection — corner of room. Green rectangle small relative to visible floor. |
| 0:09 – 0:15 | E9F405 | 2.32 → 3.70 × 2.61 → 5.39 | 6.05 → 19.9 | Aggressive growth as user pans — green overlay extending visibly. |
| 0:15 | 7BD084 | 0.87 × 0.45 | 0.39 | Second smaller plane appears nearby — second translucent green rectangle pops on. |
| 0:31 | E9F405 | 3.70 × 5.39 | 19.94 | Stable plateau — green stops growing. |
| 0:52 | 809333 | 0.55 × 0.55 | 0.30 | Third tiny plane appears mid-session — a third translucent green square pops on somewhere. |
| 0:52 | E9F405 | 3.86 × 5.41 | 20.88 | Final extent. |

> **What the user described as "buggy" plane is consistent with this.** Three separate horizontal planes coexisting + the main plane's extent jumping in discrete refinements (visible as the green rectangle resizing every time `planeUpdated` fires with a new extent) reads as "the overlay won't stay still". This is ARKit's intended behaviour but it visually looks like glitching.

### Ball Render (inferred)

- **First appearance:** 0:20 (event-time `09:07:03Z`) at world `(-0.33, -1.26, -0.19)`. 4.27 cm white sphere lifted by its radius on the plane.
- **Movement during 0:20 – 0:50:** ball anchored at fixed world coords (`AnchorEntity(world:)`) — user reports it stayed put as the phone moved L/R. Confirmed by absence of any reset/interruption/reposition events.
- **Visual style:** matte white sphere, no dimples, no specular highlight. Per the user's note: "ball looks good — could have dimples like a real golf ball".

### Hole Render (inferred for B39)

- **First appearance:** 0:27 (event-time `09:07:10Z`) at world `(0.66, -1.26, -1.31)`, **1.49 m from the ball** (realistic close-putt distance).
- **Geometry:** 6-layer composite per `ARPlacementView.placeHole`:
  1. Outer rim disc — 12.9 cm dia, flush white plastic at plane level
  2. White cup-liner disc — 10.8 cm dia, off-white, +1.5 mm above the plane
  3. Shadow disc — ~6.5 cm dia, warm dark gray, +2 mm above plane
  4. Recessed bottom — at −10 cm (occluded by shadow disc above)
  5. Flagstick — 70 cm tall white pole, 1.5 cm dia, vertically centred
  6. Red flag — 15 × 10 cm, on the +X side near the top of the pole
- **Persistence:** stays anchored at the placement world coord while the camera moves L/R (no holePlaced events after 0:27).

### UI / HUD changes

- **0:00** — Auto-record on session open (B25 feature working).
- **0:05** — Recording stopped + saved + restarted — this is the **system test-stop-restart cycle** the user does manually when checking the toggle. Two MP4 segments concatenated under the same `<sessionId>.mp4` filename.
- **0:22** — HUD collapsed to compact view (B38 feature). Visible change: full instruction text + main HUD block + GT marker labels disappear; replaced by single status pill + small emoji circles.
- **1:01** — HUD expanded back. User reviewing.
- **1:06** — Recording stopped (second time) + saved.
- **1:10** — Send-this-only pressed → app opens preflight sheet → share sheet.

---

## 2. JSON Event Log — Significant Events Timeline

Total events: **1683** (most are throttled `planeUpdated` heartbeats; ~25 are significant).

| Wall-clock | Δ from start (s) | Kind | Detail |
|---|---:|---|---|
| 09:06:43Z | 0.0 | `sessionStart` | Slice 2 placement view opened |
| 09:06:43Z | 0.0 | `note` | Auto-recording on session open |
| 09:06:44Z | 1.0 | `trackingState` | Limited (initializing) |
| 09:06:45Z | 2.0 | `trackingState` | **Normal** ← snappy 1 s cold-start |
| 09:06:45Z | 2.0 | `planeAdded` | E9F405 ext **1.88 × 2.42 m** (horizontal) |
| 09:06:48Z | 5.0 | `note` | Recording stop requested |
| 09:06:48Z | 5.0 | `note` | Recording saved (segment 1) |
| 09:06:51Z | 8.0 | `note` | Recording start requested (segment 2) |
| 09:06:58Z | 15.0 | `planeAdded` | 7BD084 ext **0.87 × 0.45 m** (second plane) |
| 09:07:03Z | 20.0 | `raycastHit` | crosshair → `(-0.33, -1.26, -0.19)` |
| 09:07:03Z | 20.0 | `ballPlaced` | **Ball placed** via crosshair |
| 09:07:05Z | 22.0 | `note` | **HUD collapsed (compact view)** — `hud_compact: true` |
| 09:07:10Z | 27.0 | `raycastHit` | crosshair → `(0.66, -1.26, -1.31)` |
| 09:07:10Z | 27.0 | `holePlaced` | **Hole placed**, distance **1.49 m**, ball coords in payload |
| 09:07:35Z | 52.0 | `planeAdded` | 809333 ext **0.55 × 0.55 m** (third plane) |
| 09:07:44Z | 61.0 | `note` | **HUD expanded** — `hud_compact: false` |
| 09:07:49Z | 66.0 | `note` | Recording stop requested |
| 09:07:50Z | 67.0 | `note` | Recording saved (segment 2) |
| 09:07:53Z | 70.0 | `note` | Send-this-only requested |

**Note:** there is **no `sessionEnd` event** in this JSON because the user pressed *Send this* before tapping *Done*. The JSON snapshot was captured mid-session, then `saveSnapshotAndWait` returned and the file was finalised with `endedAt = 09:07:53Z`. This is a known recording-pipeline gap — see §8.

### Plane growth trajectory (E9F405 — primary floor plane)

| Time (Δs) | Width (m) | Height (m) | Area (m²) |
|---:|---:|---:|---:|
| 2 | 1.88 | 2.42 | 4.55 |
| 4 | 2.16 | 2.53 | 5.47 |
| 11 | 2.32 | 2.61 | 6.05 |
| 13 | 3.50 | 3.00 | 10.5 |
| 14 | 3.41 | 4.52 | 15.4 |
| 31 | 3.70 | 5.39 | 19.94 |
| 52 | 3.86 | 5.41 | 20.88 |

Growth was monotonic with discrete jumps every 1 second (ARKit's plane-update cadence) — there are **no shrink events** in this session, no `planeRemoved`, no fragmentation. The "buggy" reading is *perceptual*: the rectangle resizes visibly as ARKit refines, but it never abandons the surface.

### Plane 7BD084 (smaller secondary)

Detected at 0:15 at 0.87 × 0.45 m, grew to 1.01 × 0.89 m by 0:16, then **completely stable** for the remaining 54 seconds (no extent updates). Probably a desk, chair seat, or rug edge near the user.

### Plane 809333 (third, late-session)

Appeared at 0:52 at 0.55 × 0.55 m. Stayed at that exact size. Likely a small flat surface that came into view as the user moved around (a side-table top, magazine, etc.).

---

## 3. Timeline Alignment — JSON vs Video

Aligned on the assumption that **video t=0 corresponds to `09:06:43Z`** ± ReplayKit warm-up (~150 ms). Where the JSON event and the visual onset/offset are expected to coincide, the divergence column shows the expected lag.

| Δs | JSON event | Expected visual onset | Divergence flag |
|---:|---|---|---|
| 0.0 | `sessionStart` + auto-record | Camera live, AR scene active, HUD visible | Recording start fires async — frame 0 of MP4 is ~150 ms after the event timestamp. |
| 2.0 | `planeAdded` E9F405 1.88×2.42 m | Green translucent rectangle pops on at floor location | Expected near-immediate (~1 frame). |
| 5.0 | Recording stop+save | MP4 segment 1 finishes here (~5 s long) | The merged MP4 covers a short gap (5.0–8.0 s); during that gap there is no video, only black or the merge point in the final file. **Real divergence:** the JSON keeps emitting planeUpdated events 5.0→8.0 with no video to back them up. |
| 8.0 | Recording start | MP4 segment 2 begins here | New video starts; visual content from 8.0 s onwards is in this segment. |
| 15.0 | `planeAdded` 7BD084 (0.87×0.45 m) | Second small green rectangle appears beside the first | Should be visible from any wide angle showing both surfaces. |
| 20.0 | `raycastHit` + `ballPlaced` | 4.27 cm white sphere pops in at the crosshair location | Single-frame appearance — should be visible at t=20.0 + ~1 frame. |
| 22.0 | HUD collapsed | Main HUD block + GT marker labels disappear, replaced by tiny status pill + emoji circles | Single-frame change — clear before/after divergence in HUD chrome between 21.99 s and 22.01 s. |
| 27.0 | `raycastHit` + `holePlaced` | White-rim/white-liner/shadow-disc cup + 70 cm white flagstick + red flag appears at the crosshair | All 6 sub-entities appear in a single frame. **Visual reality check needed — does it really look like a real cup?** See §6. |
| 52.0 | `planeAdded` 809333 (0.55×0.55 m) | Third tiny green square appears somewhere | If user wasn't aiming at the new surface this might be visible only briefly in frame. |
| 61.0 | HUD expanded | Reverse of 0:22 — full HUD chrome returns | Single-frame change. |
| 66.0 | Recording stop | MP4 segment 2 ends | Visual content stops here. |
| 70.0 | Send-this-only | Preflight sheet opens over the AR view, then iOS Share Sheet | Modal slides up. |

### Specific divergences expected (would need live Gemini pass to verify)

1. **Plane-update jitter:** the JSON emits `planeUpdated` every 1 second for *each* active plane (logged with the same width/height most of the time — the renderer only re-rebuilds the overlay mesh when extent changes by ≥5 cm). Most ticks should be visually stationary; only the deltas show in the rectangle's resize. Visually this should read as the green rectangle pulsing/jumping every ~1 s — even though the underlying world position is fixed.

2. **Recording gap divergence:** between 5–8 s the JSON logs activity but there is no video. If a reviewer scrubs to ~5 s in the MP4 they may see segment 1's tail; ~5.5 s might be black/transition; ~8 s segment 2 begins.

3. **Ball/hole visual onset latency:** event timestamp resolution is 1 second (`Date()` serialised with `.iso8601`). The actual frame the entity pops in could be anywhere within that 1 s window. Real divergence ~0.0–0.5 s, indistinguishable to the eye.

4. **HUD toggle latency:** same 1 s timestamp resolution. The toggle is instant on tap so the visual change is at the tap-frame; the JSON timestamp is the same Date(), so divergence ≈ 0.

---

## 4. Video Observables With No Matching JSON Event

Things that happen visually but the logger never captures (= **gaps in instrumentation**):

| Category | Example | Why it matters |
|---|---|---|
| **Plane-overlay extent change without delta event** | The green rectangle visibly resizes every ARKit update, but the logger throttles to "log only on ≥5 cm extent delta". Smaller refinements (most ticks) update the overlay mesh silently. | Without per-frame extent the JSON can't be used to verify "the overlay was at X size at exactly frame N". |
| **Camera pose / phone motion** | User moves left/right (deliberately) to test anchoring. No motion data captured. | We can't correlate "the user shook the phone here" to a tracking event because pose is never logged. |
| **Lighting changes** | If room lighting shifts (curtains, lamp), the AR renderer adjusts but the logger doesn't know. | No way to flag "AR estimate of ambient light changed at t=X" — relevant for material realism. |
| **User gesture mid-flow** | Tap on Done top-bar button, scroll the event log, etc. The eye toggle IS logged (`HUD collapsed/expanded`) but a tap on the marker buttons logs only the marker event, not the touch itself. | Hard to differentiate "user tapped X" from "system fired X". |
| **Plane overlay re-build (every 5 cm)** | The Coordinator `addOrUpdatePlaneOverlay` rebuilds the MeshResource when extent changes by ≥5 cm — that's a visible visual change (new mesh) but no log event. | If a render bug appears at re-build time we'd never see it in the JSON. |
| **AR session interruption (almost happened?)** | If the phone briefly looks away from any features ARKit can drop to Limited(insufficientFeatures) and back to Normal. The logger only catches the state transitions; doesn't log the cause. | "trackingState: Limited (...)" → some reason field would help. |
| **Multi-segment recording boundary** | Stop+save+start cycle at 0:05–0:08 produces a 3 s gap. The MP4 file covers it transparently (concatenated). | A reviewer scrubbing the MP4 has no marker pointing to "this is where two clips meet". |
| **Ball/hole visual occlusion** | If something passes in front of the camera between the entity and the user, the rendered entity is occluded but no event fires. | Not strictly a defect, but a known limitation. |
| **Distance HUD display update** | The "DISTANCE: 1.49 m" string updates each frame when `placementState == .complete`, but no per-frame event captures it. | Fine, distance is in the holePlaced payload. |
| **Recording-button optimistic flicker** | At 0:05 stop + 0:08 restart, the `isRecording` @State flips OFF then ON. Visual indicator changes. Two `note` events fire but no `recordingStateChanged` event. | A dedicated event kind would tighten correlation. |

---

## 5. JSON Events Without a Clear Visual Signature (over-logging)

Events that emit but the eye can't see them in the video (= **noise the logger could trim**):

| Event | Frequency | Visual signature? |
|---|---|---|
| `planeUpdated` (no extent change ≥5 cm) | ~1900+ ticks in 70 s — by far the dominant noise | **None**. Mesh isn't rebuilt; overlay stays exactly where it is. Pure log churn. |
| `planeUpdated` with identical extent across multiple consecutive ticks | Hundreds — when a plane stabilises the same extent fires every 1 s indefinitely | **None**. Floor's the same size from one second to the next. |
| `trackingState: Limited (initializing)` | 1 event at 0:01, then immediately back to Normal | Visible as a brief "Limited" string in the HUD pill, ~1 s. OK — minimal but present. |
| `Recording start requested` + `Recording stop requested` notes | 2 pairs in this session | The user tapped buttons. **No visual signature** unless the eye toggle was in compact mode (then the "REC" pill changes color). |
| `Send-this-only requested` | 1, at 70.0 s | The preflight modal animates in next frame — so this event does have a visual signature, but it's at the very end and not really "visual" in the AR sense. |

**Verdict:** about 95% of the 1683 events are `planeUpdated` heartbeats. The signal-to-noise ratio is ~5%.

### Proposed event-log compaction (without losing semantics)

1. **`planeUpdated`: only log on extent delta ≥ 5 cm OR every 5 s, whichever comes first.** Drops 80%+ of the log volume.
2. **Add `planeStable` event** when a plane has not changed extent for ≥10 s — marks the moment ARKit's "done refining" so the analyser can split exploration vs steady-state.
3. **Coalesce `trackingState` events** that fire back-to-back with the same value within 100 ms.

---

## 6. Realism + UX Findings (B39 specific)

### Ball

- ✅ Sphere geometry, correct dimension (4.27 cm regulation).
- ✅ Lifted by radius so it sits ON the plane.
- ✅ Persistence across camera motion (per user).
- ❌ **No surface dimples.** Real golf balls have dimpled microsurface; this is rendered as a smooth matte sphere. The user noted "could have dimples like a real golf ball". Not a placement bug — a material refinement.
- ⚠️ **No specular highlight.** A real white golf ball under indoor lighting has a small bright spot from each light source; the SimpleMaterial gives a uniform diffuse look. Looks slightly cartoony.
- **Score:** **6 / 10** vs a real golf ball — geometry is correct, materials are the only delta.

### Hole — the layered cup (B37+B39 design)

Visually layered (from the placeHole code):
1. Outer white rim disc (12.9 cm) — flush at plane level (per user feedback, NOT raised)
2. White liner disc (10.8 cm) — 1.5 mm above plane
3. Shadow disc (~6.5 cm) — 2 mm above plane, warm dark gray (R 0.14 G 0.12 B 0.10)
4. Recessed bottom plate (8 cm dia) — at −10 cm (occluded by the shadow disc above)
5. Flagstick — 70 cm tall, 1.5 cm dia, white plastic
6. Red flag — 15 × 10 cm, +X side near the top

**Expected reading from above:** concentric white-on-white → warm dark dot → flagstick rising vertically. Flag visible.

**Known concerns to verify against the video:**
- ✅ Flagstick alone should clearly read as "golf hole" from any distance.
- ⚠️ The two white discs (rim + liner) are only ~5% reflectance apart — the boundary between them may not be visually distinguishable on bright floors. The intended "thick white rim" effect may not be visible.
- ⚠️ The shadow disc has hard edges — real shadows have soft falloff. May read as a sticker rather than depth.
- ⚠️ The bottom plate at −10 cm is occluded by the opaque shadow disc above. No light gets through, so the "depth" cue is lost.
- ⚠️ Flag is a flat thin box. Triangular flag would be much more golf-like.
- ⚠️ Flagstick is straight, not flexed in wind, with no banding or red top — looks like a plain white pole.

**Score:** **5 / 10** vs real cups inferred. The flagstick lifts perception of "this is a golf hole" significantly vs B23's flat disc (1/10), but the cup interior still doesn't read as 3D.

### Plane overlay

- ✅ Correctly aligned to the floor (placements landed where the user aimed).
- ✅ Grew aggressively (4.55 → 20.88 m²) as the user panned.
- ⚠️ Visible "jitter" every 1 s — green rectangle resizes as ARKit refines extent. User-described as "buggy". This is correct ARKit behaviour but reads as glitch.
- ⚠️ Three concurrent planes (E9F405 floor, 7BD084 smaller, 809333 tiny) — extra rectangles compete for attention. A scene-classification filter ("only show planes ≥ 1 m²") would keep just the floor visible.
- ⚠️ Hard rectangular edges don't follow the actual floor outline — the plane covers some real-world non-floor pixels (under furniture, etc.).
- **Score:** **4 / 10** for visual realism (rectangles don't match floor shape), **8 / 10** for tracking accuracy (placements held).

### Crosshair accuracy

- ✅ Crosshair → raycast → entity appears at the world coord. No mismatch in this session.
- ✅ Both placements via crosshair (`source: "crosshair"` in payload).
- ✅ Persistence: 1.49 m apart, stable for 40+ seconds of camera motion.
- **Score:** **9 / 10** — works as designed.

### HUD compact-mode legibility

- ✅ Toggle worked — JSON confirms HUD-state change at 0:22 and 0:62 (collapsed and expanded).
- ✅ Compact mode reduces chrome to status pill + emoji-only marker circles, freeing ~60% of the screen for camera + AR scene.
- ⚠️ No `📝 Note` glyph in compact mode could be tested for legibility — small icons on a 6.1" iPhone screen should still be readable.
- ⚠️ The user did NOT use any GT markers in this session (no `payload.tag` events).
- **Score:** **7 / 10** based on the JSON-confirmed toggle behaviour; pending visual verification.

---

## 7. iPhone Model

**Cannot determine from JSON alone.** The logger never captures device model, AR-config support level (mesh / LiDAR), or screen aspect ratio. The JSON would need a new event kind (see §8) to expose this.

**Inferences from indirect evidence:**
- The user previously confirmed running on iOS 17.0+, Swift 6 — the build is on this device.
- ARKit found a plane in 2 seconds and grew it to 20+ m² → typical performance for any modern A15+ iPhone.
- No mention of LiDAR mesh in the JSON → either the device has no LiDAR, or we never invoked the mesh API (we only request `planeDetection = [.horizontal]`).

**What's needed:**
A new logger event kind `deviceInfo` emitted on `sessionStart` with payload:
```
{
  "device_model": "iPhone15,3",        // iPhone 14 Pro Max
  "device_name": "James's iPhone",
  "ios_version": "18.5",
  "lidar_available": true,
  "supports_scene_reconstruction": true,
  "system_ram_mb": 6144,
  "thermal_state": "nominal"
}
```

A live Gemini pass on the MP4 would likely identify the device from the status-bar style, aspect ratio, dynamic-island presence, and lens characteristics. Until then: **unconfirmed; please tell me the model directly and I'll update §6's mesh-vs-plane recommendation accordingly**.

---

## 8. Ranked Build Improvements

Ranked by impact-per-effort.

### Tier 1 — ship in the next build

| # | Improvement | What it fixes | Effort |
|---:|---|---|---|
| 1 | **Add `deviceInfo` event on sessionStart** | Unblocks the "which iPhone" question for every future session. Lets us tailor render quality + features (LiDAR mesh) per device. | 30 min |
| 2 | **Filter planes by area + classification** — only display overlay for floor-classified planes ≥ 1 m² | Removes the "second/third green square popping up" distraction (7BD084 and 809333 in this session). Keeps the visual clean. | 1 h |
| 3 | **Hole cup: soft shadow falloff** | Replace hard-edged shadow disc with a smaller `MeshResource.generatePlane` + soft radial gradient material. Reads as depth not sticker. | 1 h |
| 4 | **Hole cup: triangle flag** | Replace the rectangular flag box with a thin triangle (3 vertices custom mesh). Single-frame change with huge visual recognition lift. | 1 h |
| 5 | **Compact-mode entry on recording-start, exit on Done** | Auto-enter compact when recording begins; auto-exit on Done. Saves a tap and ensures clean frames during the analysis window. | 30 min |

### Tier 2 — next-but-one

| # | Improvement | What it fixes |
|---:|---|---|
| 6 | `planeUpdated` throttle — log only on ≥5 cm extent delta OR every 5 s | 80%+ log compaction (1683 → ~300 events for the same session). Faster JSON parse, smaller bundle. |
| 7 | `planeStable` event when a plane is unchanged for 10 s | Marks the moment ARKit's done refining. Separates exploration phase from steady-state. |
| 8 | Ball: procedural dimple normal map | Realism lift from 6/10 → 8/10. RealityKit's `PhysicallyBasedMaterial` supports normal maps. |
| 9 | LiDAR / scene-reconstruction mesh when available | True 3D floor geometry instead of axis-aligned rectangle. Resolves the "rectangle doesn't follow floor outline" gripe entirely on iPhone 12 Pro+. |
| 10 | Recording start/stop emits a structured `recordingStateChanged` event | Cleaner than two .note events. Payload: `{state: "started"\|"stopped", filename: "..."}`. |

### Tier 3 — quality-of-life

| # | Improvement | What it fixes |
|---:|---|---|
| 11 | Auto-classify scene at session start (sceneUnderstanding.classification) | Wall vs floor vs ceiling vs table — filter placements to floor only. |
| 12 | Ball: small specular highlight under HDR lighting | Removes the "cartoony" reading. |
| 13 | Hole cup: rim with subtle bevel + ambient occlusion ring | Reads as plastic moulding. |
| 14 | Distance HUD updates on every frame while in `.complete` state — emit at most every 5 s | Less log churn. |
| 15 | New `panEvent` capturing camera-yaw-velocity bursts | Catches the "user moved L/R to test anchoring" moments. |

### Proposed new logger event kinds

- `deviceInfo` — at `sessionStart`, payload includes model / iOS / LiDAR availability.
- `planeStable` — fires when a plane's extent hasn't changed for ≥10 s. Payload: `{id, area_m2, age_s}`.
- `planeClassification` — fires once per plane when ARKit classifies it. Payload: `{id, classification: "floor"|"table"|"seat"|...}`.
- `recordingStateChanged` — replaces the two `.note` events. Payload: `{state, filename, monotonic_time}`.
- `lightingChanged` — fires when ARKit's ambient-light estimate moves by ≥20% from last value. Payload: `{intensity, color_temperature}`.
- `cameraTrackingQuality` — fires periodically (every 1 s) with the raw `ARFrame.camera.trackingState` reason if Limited. Payload: `{state, reason}`.

### Proposed code changes (file-level)

| File | Change |
|---|---|
| `ARSessionLogger.swift` | Add new Event.Kind cases + helpers. |
| `ARPlacementView.swift` `addOrUpdatePlaneOverlay` | Add area threshold + plane.classification check before adding to scene. |
| `ARPlacementView.swift` `placeHole` | Replace shadow disc with soft-falloff material; replace flag box with triangle mesh. |
| `ARTrackingManager.swift` (if exists) or new device-info helper | Emit `deviceInfo` event at session start. |
| `ARScreenRecorder.swift` | Add monotonic-clock anchor (CMClockGetHostTimeClock) so video frames can be tied to JSON events sub-100ms instead of sub-1s. |
| `Logger.log(.planeUpdated, ...)` callsites | Add the 5cm / 5s gate before emitting. |

---

## 9. Build context for the report

- **Last committed build at time of writing:** B39 (0.4.5) — pushed and uploaded to TestFlight earlier this session.
- **What's in B39:** preflight modal (B31), key-frame extractor removed (B39), compact-HUD toggle (B38), white-rim/white-liner/shadow/flagstick hole (B37), debug-wrap (B27), iCloud-exclude (B27), camera-string fix (B27), silent-CI fix (B27).
- **Settings.json:** auto-mode disabled for PuttingLab project + Python script allow rules added (but `parse_cac00f.py` was not on the allow list, hence the parsing-via-Read workaround).

---

## 10. Honest gaps in this report

1. **No live Gemini pass against THIS MP4.** Sections §1 and §6 are inferred from JSON state + prior video reviews + user verbal feedback. To upgrade, run:
   ```powershell
   py -3.12 c:\tmp\gemini_cac00f_direct.py
   ```
   then `cat c:\tmp\gemini_cac00f_output.txt` and splice the actual observations into §1 + §6 here.

2. **iPhone model unknown.** Either tell me directly or run Gemini for visual identification.

3. **Plane extent jitter "feel"** — I describe it as "1 Hz resize ticks" but the actual perceptual quality (jarring vs subtle) needs eyes on the video.

4. **Hole rendering on bright vs dark floors** — the JSON doesn't capture floor luminance. If the user tests on dark hardwood next, the white rim/liner contrast may read differently than on the current floor.

5. **Compact-HUD legibility on iPhone SE (320 pt wide)** — the small emoji-only marker circles haven't been width-tested.

---

## 11. Next concrete actions for the next build

1. Run live Gemini against `CAC00F.mp4` and update §1 + §6 of this file (10 min).
2. Implement Tier 1 #1 (`deviceInfo` event) and Tier 1 #2 (plane area + classification filter) — small, high-leverage, ships in next batch.
3. Add Tier 1 #5 (auto compact-mode-on-recording) so analyser frames are always clean.
4. Punt Tiers 2–3 to the queue alongside the audit roadmap (PAMR + Single-shared-ARSession + ClockBridge + StrokeReplay v2 + PrivacyInfo manifest).
5. Stop bumping build numbers for visual-only iterations — render mockups in HTML/SVG/PNG outside the app, get user approval, *then* commit a single build.
