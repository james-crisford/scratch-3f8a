# B59 — verification checklist (0.6.4/59)

> Test on TestFlight build 0.6.4 (59). Drop the recording at
> `G:\Shared drives\3D Printing Express\Yell\At <N>` when done.

## What B59 ships

### Bug fixes (top priority)

1. **Hole render winding** — B55's hollow tube cup wall had triangle
   winding order anti-parallel to its explicit normals. Result: cup
   wall was being culled or rendering with backwards lighting; user
   saw it as a flat decal through B55, B56, B57, B58. B59 reverses
   the winding so the INSIDE walls are visible from above.
2. **LiveImpactDetector defaults restored** — B57's retune to 1.0
   rad/s arm threshold was unjustified (historical-data analysis
   showed 97.9% of strokes peak above 1.7). B58 already reverted it.
3. **CalibrationProfile persistence** — B58 wired
   `CalibrationModel.compute() → ProfileStore.save()` in
   `PracticeSessionViewModel.tapDone()`. The previously defined-but-
   uncalled save path is now in production.

### Infra (no user-facing change)

4. **XCUITest visual-flow test** — `ARVisualFlowTests.swift` drives
   the AR view through every state + captures a screenshot at each.
5. **`-skipToARPlacement` launch arg** — boots straight into
   ARPlacementView from PuttingLabApp, bypassing the onboarding
   flow.

### Docs

6. **Stance reference clarification** — explicit note that James's
   grip has been CONSTANT throughout development; there was no
   "old pose → new pose" transition.

## On-device test order

1. **Open AR mode** (not PracticeSessionView).
2. **Place ball** — should be instant (B56 fixed the env-probe
   freeze).
3. **Place hole** — **look at it from ABOVE then from a 45° angle**.
   - **EXPECTED:** From above you see a 3D recessed cup interior;
     the gold rim is around it; the dark cup floor is visible.
   - **REGRESSION RISK:** If you still see a flat dark disc with a
     gold ring, the winding fix didn't work. Send the video — the
     mesh may need an additional fix (CustomMaterial fallback).
4. **Foot markers** — should be visible behind the ball, opaque
   yellow.
5. **HUD copy** — bottom should say "Press anywhere to putt".
6. **Press the AR view** — medium haptic + HUD changes to "Now swing".
7. **Take a real putt** — should feel impact thwack haptic DURING
   the swing (LiveImpactDetector at defaults).
8. **Release** — phone settles, "Look at the cup…" hint, then ball
   rolls. B57 reduced the wait to 100ms / 1s timeout.
9. **Ball roll** — distance should be **1-3 metres** depending on
   stroke force. B56's `speedCalibration = 14.4` is still active
   unless you've saved a per-user profile (see below).
10. **Result chip** appears at top, "Putt again" at bottom-right.

## To activate the per-user calibration loop

Required for the bias correction to actually subtract YOUR -9° bias
in AR mode:

1. **Switch to PracticeSessionView** (the non-AR practice mode).
2. **Run the 5-stroke calibration batch** at the start of the
   session — use your normal grip, putt to an imagined 10ft target.
3. **Tap Done** after each stroke until the cal batch completes.
   B58.2 will now `CalibrationModel.compute()` + `ProfileStore.save()`
   the resulting profile to UserDefaults.
4. **Return to AR mode** — the next stroke's `face_angle_deg` in
   the JSON should be the bias-corrected value;
   `bias_applied_deg` should show ~ -9° (your historical bias) being
   subtracted. The `calibrated` payload key will read "true".

## JSON checks (for diagnosis)

After taking ~5-10 putts on B59, the session JSON's `peakImpact`
events should show:

| Field | Expected | What's wrong if not |
|---|---|---|
| `face_angle_deg` | Near 0° if profile loaded; same as raw if not | Bias correction broken |
| `face_angle_raw_deg` | Same as B58 (no algorithm change) | (diagnostic only) |
| `bias_applied_deg` | -9° if calibrated; 0 if not | Profile loading broken |
| `calibrated` | "true" if profile saved; "false" if not | Profile persistence broken |
| `velocity_mps` | 0.10-0.35 m/s typical | Stroke detection broken |
| `live_haptic_fires` | 1-2 per stroke if Live detector arming | LiveImpactDetector mis-tuned |
| `samples` | 150-250 per stroke | Recording window too short |

## Risks I'm watching

- **Hole winding fix** — 99% confidence from workflow audit, but
  unverified on device. If it doesn't work, the next fallback is
  Option B from the audit (reverse the explicit normals instead) or
  Option D (switch wall to CustomMaterial which honours faceCulling).
- **LiveImpactDetector "slow and late" haptic** — the revert may
  not address what James actually felt. Could be a different
  latency issue we'll diagnose from the JSON `live_haptic_fires`
  counter on B59.

## Follow-ups for B60+

- Wire `gemini_visual_audit.py` into CI to score each TestFlight
  build's screenshots
- Add B59 regression XCUITest: "all export buttons reachable
  during recording"
- Remove the duplicate Save/Send/Record buttons in eventLog now
  that exportButtonRow has them at top (workflow audit recommended)
- Consolidate marker buttons (full + compact rows currently
  duplicated)
