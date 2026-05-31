# AR Replay — Adversarial Design Critique

*Red-team pass on `research-synthesis.md`, `codebase-audit.md`, and
`architecture.md`. 2026-05-31. Friendly but skeptical. Intended for
James to read first thing in the morning before any code lands.*

Nothing below is a blocker on its own — but several of these will eat
a day each if we hit them blind. Roughly ordered by "how surprised
will we be when this bites us."

---

## 1. Physics: the numbers that probably won't survive the carpet

### 1.1 `μ_r(S) = 0.611 / S` was never calibrated indoors

The synthesis leans hard on the Stimpmeter relation as if it were a
ground truth. It's a ground truth **for mown bentgrass with a USGA-
shaped Stimpmeter ramp**. The derivation `μ_r = v_stimp² / (2gS)` is
clean physics, but `v_stimp = 1.91 m/s` only applies if the ball
*launched* from a Stimpmeter on the same surface — and "carpet doesn't
launch a ball the same way grass does" is exactly the kind of detail
that breaks the model.

A typical living-room cut-pile carpet stims somewhere in the
**3–6 ft** range (USGA never published it, but the consultant
literature for indoor putting greens converges on this — see Big Moss /
Birdieball product specs). Plugging Stimp 4 into the formula gives
**μ_r ≈ 0.15** and `a = (5/7)·0.15·g ≈ 1.05 m/s²`. That's an order of
magnitude slower than the Stimp-10 default in `BallPhysicsConstants`.
If James tests on his lounge carpet with the v1.1 default, the ball
will roll about **2.5× too far** and he'll think the integrator is
broken when actually the constant is wrong.

The fix is one line: surface a `stimp` dev override on the AR cover's
HUD (long-press the corner during placement), seeded to 4 in DEBUG
builds. Synthesis §2.1 punts this to v1.1 UX, but for **internal
testing on carpet** it has to be present from day one or we'll waste a
night chasing a phantom regression.

### 1.2 The "pure-roll after 20 %" assumption is violated by carpet pile

Kolkowitz / Wadden's 5–20 % skid path was measured on grass. On
**high-pile carpet** the ball grips immediately — there's effectively
no skid phase at all. On **low-pile / short-cut indoor putting mats
(Wellputt etc.)** the skid extends because the mat is firmer than the
ball expects. Either way, a fixed 5 % energy penalty (`e_skid = 0.95`)
isn't right for the actual test surface.

This isn't a bug — it's a calibration knob that James will quietly
absorb into `speedToDistanceFactor` during the 3-putt mini-game. But
it does mean **the `k_launch · √e_skid ≈ 0.877` constant is
double-counting with the existing calibration factor**. The synthesis
notices this in §4.8 ("mathematically equivalent to a single
`k_launch · speedCal` term in v1") and waves it off — but if the v1.1
result-panel distance and the AR end-position disagree by 20 %, this
is the first place to look. We should add a unit test that asserts
`abs(BallPhysics.endDistance − DistanceModel.compute(...).displayedFeet)
< 10 %` *for the same input* and let it fail loudly on day one.

### 1.3 `v_capture = 1.626 m/s` is a **regulation-cup, flat-green** number

Hogan & Antali's derivation assumes a cup of regulation 4.25" diameter
**cut into turf**. If James's hole in AR is rendered as a flat disc on
the floor with no rim physics, the capture criterion is technically
meaningless — the ball can't "enter" a 2D disc. The architecture
sweeps this under a segment-circle intersection at synthesis §1.7, but
the *velocity-cap* part of the rule (`v_entry ≤ 1.63`) is doing all
the work and that velocity ceiling was derived from a 1 cm lip
inducing the spin-out. Without the lip, **either every ball drops or
none do** — there's no physical basis for the 1.63 cut-off.

This is fine for v1.1 game feel, but it should be documented as
"engineering rule, not physics" in code, not cited as `[fact, two
sources]`.

### 1.4 The 5/7 / no-5/7 friction trap is one typo away

Synthesis §1.3 and §2.4 both explicitly warn "don't apply 5/7 twice."
That's because it's the **easiest mistake in the codebase**, and the
architecture doc proposes a `rollInertiaFactor: 5.0 / 7.0` constant
that **is not used by the friction term**. The constant exists in
`BallPhysicsConstants` purely for the v1.2 slope code. A junior fix-up
in three months that "tidies up" the integrator to use the constant
will silently make Stimp-10 play like Stimp-14.

Mitigation: rename the constant to `slopeGravityFactor` so the
intent is unambiguous, and add a comment block in the friction line
that explicitly says "no 5/7 here — already absorbed into μ_r via
Stimpmeter calibration; see synthesis §2.4."

---

## 2. Architecture: assumptions that haven't been validated

### 2.1 "ARKit world tracking survives the stroke pose" — citation needed

The architecture's whole premise is that the ARKit session stays alive
and the world frame stays consistent from address → swing → AR cover
present → ball placement. **Has anyone actually verified this on a
real iPhone?** The codebase audit (§1.1) confirms `ARTrackingManager`
runs headless with all features disabled — fine. But during the
stroke the phone is whipped from waist-height vertical → tilted grip →
back to vertical at ~5+ rad/s of rotation rate. Apple's own ARKit
docs explicitly warn that **rapid rotation degrades VIO** and the
existing `ImpactDetector` already has an `arkitLost` confidence
multiplier (audit §2.1, ×0.4) precisely because we know this happens.

So: when AR replay opens after a stroke where `arkitLost == true`,
the world frame we'll plane-detect against may or may not have
anything to do with the world frame the stroke was computed in. The
architecture punts to `.failed(.trackingLost)` on `.notAvailable`,
but **partial drift without full loss is the worst case** — tracking
state stays `.normal` but the yaw frame has rotated 15°. Nobody
notices, the ball anchors in the wrong place, and the user blames the
face-angle algorithm.

Concrete unknown: when `setHorizontalPlaneDetectionEnabled(true)` runs
without `[.resetTracking]`, does ARKit **re-localise** off the new
plane detection and snap the world transform? Audit §4.4 says "ARKit
supports config changes without a tracking reset" but provides no
citation. Apple's docs are deliberately vague on this. We should
verify before step 6 of the build order, not after.

**Recovery story is also missing.** What happens mid-tween when
tracking goes `.limited(.excessiveMotion)`? The state machine has no
`.tracking-degraded-but-recoverable` state — it either runs the
animation or jumps to `.failed`. Real-world AR usually wants a
"freeze the entity, fade overlay, resume when tracking returns"
pathway. v1.1 can skip this if we accept ugly tween glitches, but it
should be a known sin not an unknown sin.

### 2.2 `setPlaneDetectionEnabled(_:)` quietly changes light estimation too

Architecture §5 says the config swap also flips
`isLightEstimationEnabled = true`. That's a config change to a
**running session**. ARKit *will* honour it, but light-estimation
ramp-up takes 200–500 ms during which `ARFrame.lightEstimate` returns
the previous value. If the ball entity uses PBR with environmental
lighting (which the architecture implies — "PBR ball entity"
comment), the first half-second of the ball reveal will look wrong.
Minor, but exactly the kind of thing James will notice on demo day.

### 2.3 ARKit pose timestamps and CoreMotion timestamps

Audit §2.2 / §6.2 both assert "same clock domain" but the actual
guarantee is weaker than that. `ARFrame.timestamp` is a
**system-uptime seconds double** from `mach_absolute_time`-derived
host time; `CMDeviceMotion.timestamp` is *also* host-time-derived but
through a different pipeline (CoreMotion's sampling thread). They're
the same domain in the sense of "both monotonic since boot," but
**the offset between them can be 1–5 ms** depending on thermal /
CPU pressure. For face-angle interpolation we slerp between
bracketing AR poses by the impact timestamp — a 5 ms mis-clock at
hand peak velocity (~3 m/s typical) translates to **~1.5 cm of
positional drift** before the launch direction is even computed.

That's inside the existing 4.25" cup radius, so probably fine for
v1.1. But it does mean **the world-space launch direction we feed
the simulator is at best ±1.5° at fast putts**, even before ARKit
drift. Add it to the "known unknowns" section of synthesis §4.

### 2.4 No discussion of session-time-to-first-plane

Architecture §3 specifies a 15 s timeout for `.scanningPlane → noPlaneFound`.
That's the **right number for an outdoor lawn**. Indoor on a uniform
carpet, plane detection can take 5–15 s **just to find any feature
points** because cut-pile carpet looks identical from every angle. On
a hardwood floor with strong wood grain, it's <2 s. On a glossy
laminate it can fail entirely.

For James's testing context (lounge carpet), **15 s is the median, not
the timeout** — we'll hit it routinely and bounce out with "Try
again." Two mitigations: (a) bump the timeout to 30 s, accept the UX
cost; (b) prompt the user to wave the phone around during scan,
which actively improves feature density. Worth thinking through
before James tests it for the first time and decides AR doesn't work.

---

## 3. Spec deviations

### 3.1 Decision #6 is deviated, just additively

Architecture is honest about this — opens with the disclaimer. But
note the framing: "decision #6 is the one we evolve, additively."
That's a soft spec change without a formal version bump. The spec
file itself (`spec-putting-lab-v1-FINAL.md`) is unchanged and still
reads "no AR ground plane in v1." Two paths:

- Add a `Section 1 amendment` to the spec marking #6 as
  "v1 = 2D top-down only; v1.1 = AR opt-in second view." Signed,
  dated, and the architecture doc links to it.
- Or treat the architecture doc as the v1.1 spec and say so on
  line 1.

Either is fine; what isn't fine is letting both docs claim to be
authoritative.

### 3.2 The `+y = left` frame contradicts ARKit's right-hand rule

Synthesis §1.1 declares "+y = left of the target line." ARKit world
frame is `+x = right, +y = up, −z = forward`. The synthesis maps
physics `+y` (left) → 90° CCW around world `+y` (up), which is
correct. But the `BallPhysics.simulatePutt` API exposes
`SIMD2<Float>` positions with `+y = left` semantics — and **any
caller who thinks of these as standard right-handed 2D coordinates
will draw the trajectory mirrored**. RealityKit entity transforms
are right-handed, so the mapping is non-trivial.

The architecture doc handles this in `ARSceneCoordinator`, fine. But
the public API exposes the trap. Recommendation: rename
`SIMD2<Float>` to a typedef'd `GreenFramePoint` or document the
frame conversion in the doc-comment **above the type itself**, not
only in the function. A future engineer reading the type signature
in isolation will guess wrong.

### 3.3 `BallPhysics.Constants.captureVelocity = 1.626` not `1.63`

Synthesis §1.1 uses 1.63 m/s, §1.7 uses 1.63, §2.3 uses 1.626
(verbatim from Hogan & Antali). Architecture §4 imports 1.626. Both
are defensible — 1.626 is the cited value, 1.63 is the rounded
engineering value. But two different numbers will appear in different
parts of the codebase and at some point a unit test will assert one
and the constant will be the other. Pick one and grep for the other
before merge.

---

## 4. Build 14 fragility

### 4.1 The "read-only accessor" on `PracticeSessionViewModel` is not as safe as it looks

Architecture §2 lists
`PuttingLab/UI/PracticeSessionViewModel+ARReplayAccessors.swift` as a
new file containing read-only computed properties. This is the right
shape, but **adding a Swift extension to an `@Observable` class
changes its synthesised conformance graph**. If the new properties
read `posesDuringRecording` (private) you can't access them from an
extension at all — you'd need to either (a) bump the access level on
the storage, or (b) add a stored property that mirrors the data.

Both options touch `PracticeSessionViewModel.swift`. Option (a) is a
one-character change but it modifies the file. Option (b) requires a
new write inside `touchUp()`'s success path to populate the mirror,
which **does** touch the load-bearing `defer` block (audit §5.2).

Quietly, **the architecture proposes an accessor it can't add without
modifying a forbidden file.** The brief explicitly says "DO NOT
modify any file under … PracticeSessionViewModel.swift." This is the
single biggest spec / hard-constraint clash in the architecture doc.

Two real options:
1. **Wait** — defer AR replay until after Build 14's TestFlight cohort
   is done and the file can be safely edited. Realistic timeline:
   2–3 weeks not 1 week.
2. **Extend `StrokeReplay` schema v2** to serialise ARKit poses on
   save (audit §6.1). That's a `Models/` change, not a viewmodel
   change. Adds ~1.2× file size as noted. **This is the path that
   keeps Build 14 untouched.**

The architecture doc lists schema v2 in the v1.2 punt list (§6) but
under "deferred for cost reasons." It's actually the cheaper path
once you account for the hard constraint. **Recommend pulling schema
v2 into v1.1 scope and dropping the viewmodel extension entirely.**

### 4.2 `LiveImpactDetector` is touched indirectly via DragGesture

Audit §5.1 warns "don't call `consume` from a frame-rate render
loop." Architecture §3 says the AR cover is a `.fullScreenCover`,
which on iOS 17 **does** suspend the underlying view's gesture
recogniser, but **does not stop the live `MotionManager` updates**
that drive `liveImpactDetector.consume()`. Audit §6.4 flags scene-
phase, not gesture-phase, but the actual risk is:

While the cover is up, the user is rotating the phone to look at the
AR scene. CoreMotion is still streaming. `MotionManager` is still
calling `liveImpactDetector.consume()` because the viewmodel is still
in `.showing`. The 1 s `minFireDelayFromTouchDownSeconds` gate (audit
§5.1) protects against haptic firing if a "stroke" registers — but
the **forward-axis projection still runs**, allocates buffer space,
and could fire a `.medium` haptic mid-AR-replay if rotation crosses a
threshold.

**Fix:** pause `liveImpactDetector` when the cover presents, resume
on dismiss. That's a new method, not a modification of existing
methods. Architecture doesn't mention it. Add to §8 open questions
as #15.

### 4.3 `TestSessionState` and the 100-stroke counter

Audit §5.4 warns "adding new fields to `TestSessionState` is not
fine — they will round-trip into the persistence layer and break
mid-session resume." Architecture confirms this and uses
`ARReplay_v1.` prefix for new keys. Good. But the cover's
`@Observable ARSceneState` is **in-memory only** — what happens if
the user backgrounds the app during AR placement? Audit §6.4 says
scene-phase `.background` triggers `stopSession()` which dumps the
recording. **It also dumps `pendingWindow` and `pendingResult`** —
which means returning to the app puts the user in `.ready` with no
stroke to AR-replay. The cover, if it persisted, would try to read
a nil result and crash.

Cover dismiss on app background is mandatory and not in the
architecture. Add to §8 as #16.

---

## 5. Realistic timeline

The architecture proposes 10 steps in §7. James is a solo dev with
**no AR background** (confirmed by the CLAUDE.md context describing
the project + the fact that Build 14 itself was the first ARKit
integration he's shipped). The skill list doesn't include any AR
mentor.

### Honest hours, in a less optimistic light:

- Steps 1-3 (physics + tests): the 5.5 h estimate is **realistic** —
  this is pure Swift and James has done similar work. **Day 1 OK.**
- Step 4 (`ARSceneState`): the 1 h estimate **only covers the enum**.
  The actual `@Observable` integration with SwiftUI + state-machine
  unit tests is **3-4 h**. **Day 2 morning.**
- Step 5 (`ARTrackingManager+PlaneDetection`): 1 h is **optimistic**.
  First time doing a `session.run(config, options: [])` swap, James
  will discover at least one of: light estimation flicker (§2.2),
  feature-point loss (§2.4), or the tracking re-localise question
  (§2.1). Realistic: **4-6 h including verification on device.**
  **Day 2 afternoon + Day 3 morning.**
- Step 6 (`ARSceneCoordinator`): 4-6 h estimate. **First-time
  RealityKit scene root, entities, raycast, AND a tween driver.**
  Apple's RealityView APIs changed substantially in iOS 18 (the
  doc-comment in `UIKit` vs `RealityKit` for entity transforms
  alone is 2 h of reading). Realistic: **2 full days (16 h).**
  **Day 3 afternoon + Day 4 + Day 5 morning.**
- Step 7 (3 views + RealityView fallback for iOS 17): **2 full days**.
  iOS 17's `ARViewContainer` UIViewRepresentable wrapper is its own
  art form. **Days 5 afternoon + 6 + 7 morning.**
- Step 8 (button + view modifier overlay): 1 h estimate is fine.
  **Day 7.**
- Step 9 (viewmodel accessor): 30 min — but per §4.1 above this is
  actually **a schema v2 bump on `StrokeReplay`**, which is closer to
  **4 h** including migration code for existing TestFlight users'
  saved strokes. **Day 7-8.**
- Step 10 (TestFlight + on-device walk-through with James + iterate
  on §8's open questions): **2-3 days minimum** including build,
  TestFlight upload, James installs, finds 3-5 things wrong, fixes,
  re-uploads. **Days 8-10.**

**Realistic total: 8-10 working days, not 5-7.** "A week" is only
achievable if James abandons day-job duties entirely, which (per
CLAUDE.md context — 3DPE, NotebookLM scripts, BambuWatch all
in flight) is **not the situation.**

### Minimum-viable AR slice

If the goal is "ship something James can demo at the next golf
session," cut to:

1. `BallPhysics.swift` + tests (steps 1-3). **3-4 h.**
2. A **3D-on-top-of-2D** overlay that doesn't use ARKit plane
   detection at all — just renders the existing 2D roll animation
   inside a `RealityView` with the camera feed behind it, no anchors,
   no tap-to-place. Ball flies in screen coordinates over the live
   feed. **8 h.**
3. Skip the `ARSceneState` machine entirely. The cover has two states:
   "presenting" and "dismissed." **2 h.**

That's **~2 days of work** and produces a "Replay over your room"
visual that's 60 % of the demo value of the full architecture, at
20 % of the build risk. **Genuinely worth considering** as a stepping
stone — ship the cheap version to TestFlight first, gather telemetry
on whether anyone uses it, *then* invest the 8-10 days on the proper
anchored version.

---

## 6. Open questions the architecture dodged

The §8 "open questions for James" list is good but misses these:

1. **Has James actually verified the AR replay button doesn't fire
   `touchDown` on the underlying `ResultPhaseView`?** Audit §5.3 +
   architecture §8 Q8 raise it as a UX concern but don't propose a
   test. Should be a Playwright-equivalent UI test on real device.
2. **What is the unit test for "ARSession config swap preserves world
   frame"?** Step 5 of the build order names this as "real device
   required" but doesn't say *what to measure*. Suggested test:
   capture `arkit.attitudeYaw()` immediately before and 500 ms after
   the swap; assert delta < 1°.
3. **What's the policy when the user puts the phone down on the
   floor during AR placement?** `ARSession.delegate.session(_:
   didUpdate: ARFrame)` will keep firing, plane detection will find
   the wrong plane (the floor under the phone, not the floor in
   front), and the ball will anchor on top of the phone.
4. **Does `ARReplayView` need to call `motionManager.stop()` or not?**
   §4.2 implies one ARSession lifetime but doesn't say anything about
   CoreMotion. (Per §4.2 above: leaving it running is a fragility
   risk; stopping it loses any post-AR stroke detection.)
5. **What happens to `pendingArkitPoses` if the user opens AR replay
   twice on the same stroke (close cover, open again)?** First open
   consumed something? Or is it idempotent? Probably the latter, but
   worth confirming.
6. **Memory cost of the 300-sample path on a 60 fps render tween.**
   `SIMD2<Float>` × 300 = 2.4 kB. Fine in isolation. But if the user
   plays 100 strokes in a session and we don't release prior paths,
   that's 240 kB held by `ARSceneState`. Architecture doesn't specify
   path lifecycle. Likely fine; worth a code comment.

---

## TL;DR for James

- **Physics is fine for grass, wrong for carpet** — surface a Stimp
  override in DEBUG before testing, or you'll spend an evening
  thinking the integrator is broken.
- **The architecture proposes a viewmodel extension that violates the
  hard constraint** — drop it, do `StrokeReplay` schema v2 instead,
  no Build 14 file is touched.
- **ARKit world-frame continuity across the config swap is the
  single biggest unknown** — verify on device in 10 minutes
  *before* writing any UI code.
- **The 5-7 day timeline is 8-10 in reality** — or take the
  2-day MVP slice (RealityView with no anchors, ball over camera
  feed) and ship that first.
- **`LiveImpactDetector` will keep running during AR cover** —
  pause it explicitly or expect a stray haptic.

Sleep well. None of this is fatal — but all of it is cheaper to
notice tomorrow than next Friday.
