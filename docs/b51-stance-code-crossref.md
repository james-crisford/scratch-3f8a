# B51 — Stance doc vs current code: what needs stripping

> Generated 2026-06-03 from cross-referencing `docs/putting-stance-reference.md`
> against the current Swift in `PuttingLab/UI/AR/ARPlacementView.swift`
> and `PuttingLab/Sensors/AddressPoseCapture.swift`.

The B47/B48 design ("Set address" button → calibrate → "Ready" button → press to swing) is **wrong** per James's 2026-06-03 confirmation. The correct flow is **one press-and-unpress gesture** anywhere on the AR view at `.complete` state — no buttons, no hologram, no address calibration phase.

## Files to modify

| File | Lines (current) | Action |
|---|---|---|
| `PuttingLab/UI/AR/ARPlacementView.swift` | ~30 sites | Strip 4 PlacementState cases, "Set address" + "Ready" + "Re-calibrate" + "Cancel" buttons, address hologram render, hologram anchor |
| `PuttingLab/Sensors/AddressPoseCapture.swift` | whole file | Delete — replaced by press-time orientation snapshot |
| `PuttingLab/Models/AddressPose.swift` | keep struct | The data shape (yaw lock, target vector at press time) is still needed — just captured at press, not via a 1.5 s stillness loop |
| `PuttingLab/Sensors/StrokeCapture.swift` | TBD | Confirm it triggers on press, not on a `.readyForStroke` state transition |

## PlacementState cases to remove

- `.calibratingAddress(ball, hole)` — L51
- `.addressReady(ball, hole, pose)` — L55
- `.readyForStroke(ball, hole, pose)` — L61
- `.strokeInProgress(ball, hole, pose)` — L67

**Keep:** `.waitingForPlane`, `.readyToPlaceBall`, `.readyToPlaceHole`, `.complete(ball, hole)`, `.rolling`, `.rolled`.

**Press gesture state:** the press is transient — owned by a new `@State private var pressActive: Bool` + a `pressStart: Date?`. **NOT** a PlacementState case. We stay in `.complete` throughout the press; the swing is detected by `StrokeCapture` reading MotionManager directly between press and unpress.

## SwiftUI elements to remove

| Element | Line | Why |
|---|---|---|
| "Set address" Label / button | 1404, 1409 | Press IS the readiness signal |
| `case .calibratingAddress:` block (status text) | 1417 | Calibration phase doesn't exist |
| `case .addressReady:` block with "Ready" / "Re-calibrate" pair | 1434, 1462 | No buttons during address |
| `case .readyForStroke, .strokeInProgress:` Cancel button | 1470 | No cancel — releasing finger ends stroke |
| `case .calibratingAddress: "Hold still…"` etc. | 1634-1638 | Status copy for dead states |
| Crosshair opacity special cases | 1128, 1250, 3655 | Collapse to `.complete` only |

## Scene helpers to remove

- `placeAddressHologram(at:)` — L2725
- `clearAddressHologram()` — L2758
- `addressHologramAnchor` property — L2042
- The hologram clear call in `clearPlacedEntities()` — L2611 (leave a no-op or remove with the helper)

## Scene helpers to add

- `pressGestureOverlay()` modifier on the AR view body — `DragGesture(minimumDistance: 0)` with `onChanged` (first event = press) and `onEnded` (= unpress)
- On press: snapshot the device attitude → build an `AddressPose` immediately → fire haptic → call `strokeCapture.armForStroke(pose:)`
- On unpress: call `strokeCapture.endStrokeWindow()` → run ImpactDetector across the window → transition `.complete` → `.rolling`

## `AddressPoseCapture` deletion plan

Currently a 1.5 s stillness-detector loop that waits for ±25° verticality + low rotation. Per James, the press IS the address-lock — no stillness window needed. The user is by definition still at the moment of the press (it's a deliberate gesture).

Delete the class. Replace with a single inline snapshot:

```swift
func snapshotAddressPose() -> AddressPose? {
    guard let attitude = motionManager.latestAttitude,
          let target = scene.currentTargetVector() else { return nil }
    return AddressPose(
        timestamp: motionManager.latestTimestamp,
        deviceAttitude: attitude,
        targetVectorWorld: target,
        confidence: 1.0  // press = deliberate, treat as max-confidence
    )
}
```

## Foot markers (B46) — keep as advisory

The yellow foot markers placed behind the ball during `.complete` should:
- Stay rendered
- Stay clearly labelled "stand here (optional)" via the existing `transientHint`
- NOT be a precondition — user can press from anywhere

No code change to the marker placement logic. Just verify the hint copy doesn't imply "must stand on these".

## Stale-design watch — followups

These 3 docs still describe the WRONG (B47-era) flow. Flag for James:

1. `CLAUDE.md` §3 decision #2 — "vertical / screen toward you / back camera toward target" (was wrong even before B47, see B4 commit `f06ee52`)
2. `docs/spec-putting-lab-v1-FINAL.md` §1 row 7 — same stale prescription
3. `docs/spec-putting-lab-v1-FINAL.md` §3 phase 2 — "phone within ±15° of vertical" (the whole "vertical" framing is wrong)

Not editing without James's sign-off — spec edits are gated per CLAUDE.md §4.

## Tier 0 bugs to fold into B51

Per James's B50 feedback:
1. **Hole still renders flat on device** — environment probe / PBR materials still not lighting correctly. Re-investigate `AREnvironmentProbeAnchor` placement + check `environmentTexturing` is `.automatic` (B45 supposedly fixed this; needs verification on real device)
2. **Ball lag on placement** — 1024×1024 procedural normal map regenerated on every `placeBall()` call. Cache as a static `MaterialParameters.Texture` at app launch
3. **Button text unreadable at `.complete`** — most of those buttons are going away anyway (this fix is free as a side-effect)

## Estimated diff size

- Remove: ~280 lines (4 state cases, 6 switch arms, 3 button blocks, hologram helpers, AddressPoseCapture class)
- Add: ~60 lines (press gesture overlay, snapshot helper, B51 verification doc)
- Net: -220 lines

## Order of edits for green CI throughout

1. Add press gesture infrastructure (overlay + snapshot helper + StrokeCapture arm/end) — independent, compiles
2. Add gesture to AR view at `.complete` — both flows coexist briefly
3. Switch the trigger from "Set address" button to gesture — gesture path active, buttons still present
4. Remove the 4 PlacementState cases + every `switch` arm in one atomic edit — Swift exhaustiveness check enforces completeness
5. Remove button SwiftUI blocks + scene hologram helpers
6. Delete `AddressPoseCapture.swift`
7. Bump version → 0.5.6 / build 51
8. Push, dispatch CI, verify TestFlight build

---

*Cross-reference complete. James to OK the plan before any code edits in B51.*
