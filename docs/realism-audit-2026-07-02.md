<!-- Produced 2026-07-02 by the realism-audit agent (session 6f631e6d).
     All claims verified against code at 586d91c/43c13ee and web primary
     sources (WebSearch/WebFetch, 0 firecrawl). See harness/README.md for
     the offline verification tooling referenced throughout. -->

# PuttingLab Putting-Physics Realism Audit

**Scope note:** audit began at `586d91c`; the repo moved mid-audit to `43c13ee`
(S2 fix). Both states verified via `git show`/blob hashes. `43c13ee` changes
only the calibration objective, `CalibrationProfile` versioning, a
`DistanceModel` LEGACY banner, and the default-calibration constant reference;
`BallPhysics.swift`, `MarioKartAssist.swift`, `ImpactDetector.swift`,
`FaceAngleComputer.swift` are byte-identical across both commits. Caveat:
`raypenner.com/golf-putting.pdf` has an expired TLS cert and ResearchGate
403'd, so the Penner 1.31/1.63 figures rest on search-result excerpts of
Penner 2002 plus the PMC full text of Hogan & Antali 2025 (read in full).

---

## 1. VERIFIED TABLE

| # | Constant / law | Implemented (file:line) | Design-spec value | Literature value | Verdict |
|---|---|---|---|---|---|
| 1 | Rolling friction | `μ = 0.611/S`, decel `= μ·g` (`BallPhysics.swift:159-162, 251-252`) | synthesis §1.2 same; main spec §2.6 has no friction law | Implies Stimpmeter release speed `√(2·0.611·9.81·0.3048)` = **1.911 m/s**. USGA/Wikipedia: **6.00 ft/s = 1.83 m/s**; Penner 2002 uses 1.83 | **DIVERGES (small)**: code friction is (1.911/1.83)² = **+9.1%** vs USGA convention → rolls **8.4% shorter** for a given ball speed; "stimp 10" plays like **stimp 9.17**. Within literature spread. Fully absorbed by per-user calibration since stimp is hard-coded to 10 at both call sites (`ARPlacementView.swift:2799, 2892`) |
| 2 | 5/7 rolling-inertia handling | 5/7 NOT applied to friction; `pennerReferenceFriction 0.131` kept as doc only (`BallPhysics.swift:44, 89, 250-252`) | synthesis §2.4: 5/7 already absorbed in μ | Self-consistent: decel `μg = v_s²/(2S)` exactly reproduces "ball at v_s rolls S feet" | **MATCHES** |
| 3 | Displayed-distance law | `raw = fps²·stimp/19.7` (`DistanceModel.swift:70` @586d91c) | Spec §2.6: `speed^1.6 / friction_constant`; skill: `pow(fps,1.6)/1.7` | Constant-decel physics gives `d = fps²·S/39.3` (0.611 convention) or `/36.0` (1.83 convention). 19.7 = the *deceleration* in ft/s² — the law **omits the factor 2** in `d = v²/2a`, over-predicting ~**2×** | **DIVERGES (2×) + NOT-PER-SPEC** (v² replaced spec's v^1.6 in `954ff66`). At HEAD marked LEGACY, no production consumers |
| 4 | Launch chain | `v0 = peak·cal·0.90·√0.95` (`BallPhysics.swift:56, 62, 217-221`) | synthesis §1.4 identical | `k_launch 0.90` traced only to Quintic/Wadden vendor claims; not independently web-verified | **MATCHES synthesis / NOT-IN-MAIN-SPEC**; absorbed by calibration (v4 bisection wraps it) |
| 5 | Skid model | Single one-shot `√0.95` speed multiplier (`BallPhysics.swift:62, 220`) | synthesis §1.4: same | Real putts skid **14–20% of total distance** before pure roll (Quintic Ball Roll) | **DIVERGES (structurally, tiny in effect)** — Gap #7 |
| 6 | Cup radius | 0.054 m (`BallPhysics.swift:50`) | synthesis §1.1 | 4.25 in dia / 2 = 0.05398 m, Rules of Golf | **MATCHES** |
| 7 | Capture speed | 1.626 m/s, tested at **closest approach to cup centre**, uniformly for **any** entry within the 0.054 m disc (`BallPhysics.swift:51, 312-330, 394-418`) | synthesis §1.7 v1: same fit; b_crit shrink deferred to v1.1 | Holmes 1991 / Hogan & Antali 2025: **1.626 m/s at the rim for a centre-line hit only**. Penner 2002: 1.31 free-fall-only vs 1.63 all-mechanisms. Off-centre entries have **lower** critical speed; effective capture width shrinks with speed | Centre-line value **MATCHES** Holmes; off-centre handling **DIVERGES (over-generous)**. Rim-vs-closest-approach difference ≤1.2% at stimp 10 — negligible |
| 8 | Lip-out | Radial outward kick at `0.6·v_entry`, snapped to rim+1 cm; dead-centre hit kicks **straight back along inbound axis** (`BallPhysics.swift:331-360`) | synthesis §1.7: engineering fit, phase-plane deferred | H&A 2025: exit deviation can exceed 180° but depends on entry geometry/spin; **no universal 0.6 exit-speed ratio in the paper** | **Engineering fit**; qualitative divergence for centre hits — Gap #3 |
| 9 | Stop velocity | 0.05 m/s (`BallPhysics.swift:70`) | synthesis §1.3 | Engineering threshold | **MATCHES** |
| 10 | Integration | Semi-implicit Euler, dt = 1/60 s, overshoot-snap, segment cup check (`BallPhysics.swift:67, 274-306, 312`) | synthesis recommends dt = 1 ms | Constant-friction decay is linear — near-exact; segment check prevents tunnelling | **MATCHES (adequate)** |
| 11 | Launch direction | `ψ0 = −faceAngleRaw`, **100% of face angle** (`BallPhysics.swift:243`) | Spec §2.1 explicitly collapses face+path | Real putting: start line ≈ **83% face / 17% path** (SAM PuttLab/Marquardt/Pelz) | **MATCHES spec, DIVERGES from reality by documented decision** — Gap #5 |
| 12 | MarioKart bucket thresholds | 6°/12°/20° (`MarioKartAssist.swift:39-41`) | Spec §5.1 identical | n/a | **MATCHES** |
| 13 | Bucket display angles | `displayDegrees = faceAngleDeg` raw, **uncapped** (`MarioKartAssist.swift:101, 111, 126`) | Spec §5.1: display 4–8°/12–18°/20–30° capped at 30 | n/a | **SPEC DRIFT** (§4.4) |
| 14 | Snap-to-square conditions | <200 ms ✓; no clear peak ✓; peak < **0.05** m/s; ARKit>50% flag vestigial (call sites pass `.none`) | Spec §5.2: same but 0.3 m/s | n/a | **PARTIAL** — 0.05 is a documented putting-specific retune; ARKit condition vestigial post-B78 |
| 15 | Calibration objective @586d91c | Inverts legacy DistanceModel law (`CalibrationModel.swift:23-25`) | Spec §6.2 | n/a | **INTERNALLY INCONSISTENT** with the live roll law — Gap #1 |
| 16 | Calibration objective @HEAD | Bisection over `BallPhysics.simulatePutt` itself; pre-v4 profiles reset to default on load | — | n/a | **FIXED** — exact by construction |
| 17 | Distance band / jitter | Exist only in dead `DistanceModel`; AR panel shows neither (`StrokeResultPanel.swift:143-146`) | Spec §2.6: jitter ±10%, band ±15% **always displayed** | n/a | **SPEC DRIFT** (§4.2) |

---

## 2. REALISM GAPS — ranked by user-perceivable impact

**#1 — Calibrated putts rolled ~38% of the promised distance (fixed at 43c13ee).**
Three laws shared one constant: calibration solved the factor against
`fps²·S/19.7` (missing ×2), then BallPhysics launched under the correct
`d = v²/2μg`. Net: sim distance = (1/√2 · 0.8775)² = **0.385×** the calibrated
target. Confirmed by the b79 device data (10 ft target → 3.8 ft rolls). Every
calibrated stroke read "Short" — and calibration made it *worse* than the
hand-tuned default. FIXED: pipeline v4 bisects the calibration factor over the
live simulator; pre-v4 factors reset + forced recalibration.

**#2 — No upper clamp on peak velocity in the live sim path (fixed at a5107c4).**
`DistanceModel.maxPlausiblePeakSpeedMps = 5.0` suppression became dead code
when the AR path stopped consuming DistanceModel; an IMU double-integration
spike × cal 14.4 × 0.8775 produced a multi-km "putt" bounded only by 160 s of
sim. FIXED: gate restored at the BallPhysics boundary (`.rejected`).

**#3 — Lip-out kicks radially outward; dead-centre over-speed entries bounce
straight back at the player.** A centre-line entry at 1.65 m/s reverses 180°
at ~1 m/s, every time, deterministically (`BallPhysics.swift:344-346`). The
canonical fast centre hit in reality hops the far rim and continues forward.
The most visibly arcade behaviour in an otherwise literature-grounded
simulator. Calibration cannot absorb it. Fix: medium — bias exit direction to
forward-tangential from entry impact parameter (synthesis §1.7 v1.1
phase-plane approximation). NEEDS JAMES SIGN-OFF (feel change).

**#4 — Over-generous off-centre capture.** One capture speed across the full
10.8 cm disc; literature: critical speed falls with impact parameter,
effective hole width → 0 as speed → 1.63 m/s. In-game a grazing edge putt at
1.5 m/s drops; in reality it always lips out. Fix: small — the
already-documented v1.1 `b_crit(v)` lerp (~6 lines in `segmentCupEntrySpeed`).
NEEDS JAMES SIGN-OFF (feel change; makes the game harder).

**#5 — 100%-face launch direction.** Real start line ≈ 83% face. For a 5° face
at 3 m: game 26.2 cm lateral vs realistic 21.8 cm — overstates directional
punishment ~17%. BUT path is not measurable from a phone IMU, and scaling face
by 0.83 would fabricate a path the user never produced (Wii rule #3). Verdict:
correct engineering call — document, don't fix.

**#6 — Friction convention −8.4%** (release speed 1.911 vs USGA 1.83 m/s).
Invisible today (stimp fixed at 10; v4 calibration bisects through the same
law). Becomes real only if a stimp slider ships. Document or change one
constant (0.560 vs 0.611) + recalibrate.

**#7 — Skid collapsed to a one-shot √0.95.** Total-distance effect absorbed by
calibration; residual is a slightly-too-gentle early deceleration in the
animation. Below perception threshold. Leave.

**#8 — Honesty features (band/jitter) missing from the result panel.** The
spec's signature "18 ft (est. 15–21 ft)" uncertainty display — the anti-GolfGo
differentiator — doesn't exist in the AR path. Not physics, but it is the
spec's stated realism-credibility mechanism.

---

## 3. REDESIGN CANDIDATES (architecture vs realism)

1. **Two distance laws, one calibration constant** — root cause of Gap #1;
   resolved the right way at 43c13ee (single source of truth = the simulator).
   Remaining debt: `DistanceModel` still owned the only absurd-input
   suppression (now ported, a5107c4) and the band/jitter semantics (Gap #8) —
   those behaviours belong in the live path; the class should shrink to a
   decode shim or be deleted.
2. **The MarioKart assist layer is now decorative.** The roll animation and
   `displayDegrees` consume `faceAngleRaw` directly — the bucket contributes
   only a label + cause string. The spec's core game-feel mechanic (generous
   bucketed display + roll direction) is architecturally bypassed. Either
   re-wire sim/display to bucketed angles, or amend the spec to "roll the
   honest raw angle, bucket only the label". Current half-state satisfies
   neither contract.
3. **Face-at-peak-velocity + press-declared square** replaced the spec's
   address-locked world reference. Well-argued fix for real drift pathology,
   but it changes the meaning of "face angle": rotation since *press*, not
   orientation vs *target line*. A user who presses with a 4° open stance
   putts "square" by definition. Deliberate realism-for-robustness trade the
   spec never ratified. (H5 timing error quantified separately: `plab h5` —
   peak-velocity sampling fires 15–98 ms after true ball passage by stroke
   shape; face error up to −5.9° at 60°/s sweep; re-approach candidate
   recovers ground truth on the same samples.)
4. **Vestigial confidence machinery.** `ImpactResult.confidence` computed but
   never consumed by bucketing; `arkitLostMoreThanHalf` can never fire from
   production call sites; "confidence < 0.4 → desaturated trace" unimplemented.
5. **Tempo was never built.** Spec defines tempo = backswing/forward ratio
   with a "your norm" display; implementation stores mean stroke duration; no
   TempoComputer exists; no panel shows tempo. A whole spec pillar silently
   absent.

---

## 4. SPEC DRIFT (vs spec-putting-lab-v1-FINAL.md / golf-swing-game-design skill)

1. Distance law: spec §2.6 `speed^1.6/friction` → `v²·S/19.7` (`954ff66`) →
   de-facto BallPhysics `v²/2μg`. Spec never updated.
2. ±15% band + ±10% jitter "always displayed" (spec §2.6, §8): absent from
   `StrokeResultPanel`; jitter amplitude also drifted 0.10 → 0.05.
3. "NEVER show raw face angle in degrees" (skill:267-269): AR panel shows
   `+7.3°` raw (`StrokeResultPanel.swift:162-163`).
4. Bucket display compression/cap (spec §5.1): code displays raw, uncapped.
   Combined with #3, "generous when uncertain" survives only in labels.
5. Roll animation start direction = `face_angle_displayed` (spec Phase 6):
   sim rolls `faceAngleRaw`.
6. Face-angle reference frame (spec §2.4-2.5): ARKit-primary + compass
   fallback replaced wholesale by press-attitude delta.
7. Snap threshold 0.3 m/s (spec §5.2): now 0.05 — documented, deliberate,
   unratified.
8. `user_face_bias` subtraction (spec §6.2): computed and stored but
   deliberately no longer applied; skill text stale.
9. `arkit_baseline_stability` (spec §6.2): implemented as a face-angle-scatter
   proxy — nothing to do with ARKit (`CalibrationModel.swift`).
10. Tempo ratio (spec §2.6, §6.2): not implemented anywhere.
11. Skill errata stale: "multiplicative confidence formula in MarioKartAssist"
    — current MarioKartAssist has no numeric confidence; skill distance-model
    snippet matches neither shipped law.
12. Doc-internal: synthesis §8 "3-putt mini-game" vs code's 5 strokes at 8 ft
    (`CalibrationCoordinator.swift:26`).

**What genuinely matches spec/literature:** capture speed 1.626 (Holmes/H&A,
correctly cited in code), cup radius, μ(S) form and the no-double-5/7
discipline, friction-opposes-velocity vector form (slope-ready), semi-implicit
Euler with overshoot snap and segment cup detection, the B80 sign-convention
chain (traced end-to-end, coherent), and the 6/12/20 bucket thresholds.

**Sources:** Stimpmeter — Wikipedia · USGA Stimpmeter Instruction Booklet ·
Penner 2002, The physics of putting (raypenner.com — cert-expired, verified
via excerpts; ResearchGate 237196126) · Hogan & Antali 2025, Mechanics of the
golf lip out — PMC12585879 / RSOS 10.1098/rsos.250907 · SAM PuttLab /
Science&Motion Fundamentals of Putting Ep.2 · GolfWorks — Putter Face Angle vs
Path · Quintic Ball Roll tutorial (skid 14–20%).
