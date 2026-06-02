# B42 Verification Report

**Build:** PuttingLab **0.4.8 (42)** — commit `7161bc9`, CI run `26825371153` (build green, signed IPA uploaded to TestFlight).
**Target device:** iPhone 13 Pro Max (LiDAR confirmed).
**Methodology:** TestFlight install → AR Slice 2 → walk a 1–2 m loop for 30–60 s (LiDAR mesh populates) → place ball + hole → exercise Move ball / Move hole → pan to test anchoring → Send.
**Gemini script:** `c:\tmp\gemini_b42_direct.py` (port of CAC00F script). Prompt updated for B42 expectations.
**Pre-Gemini validator:** `py -3.12 tools/verify_b42_json.py <session.json>` — confirms all required events present, payloads well-formed, no schema drift.

---

## ⏳ Status: PENDING FRESH RECORDING

This report is the durable artifact for B42 sign-off. Two gates:

1. **JSON validator** (`tools/verify_b42_json.py`) must exit 0 (or 2 with only acceptable warnings)
2. **Gemini floor-overlay score ≥ 8/10** AND **hole-render regression ≥ 6/10**

Until both pass, B42 is shipped-but-unverified. Either iterate to B43 or accept.

---

## 1. JSON pre-flight validation

*Run `py -3.12 tools/verify_b42_json.py <path-to-session.json>` and paste output here.*

```
(pending)
```

Required:
- [ ] `sessionStart`, `deviceInfo`, `trackingState`, `materialApplied` present
- [ ] `deviceInfo.lidar_mesh_supported: true`
- [ ] `meshAdded`, `meshUpdated`, `meshStats` present (LiDAR firing)
- [ ] `meshStats.floor_area_m2 > 0` AND `lidar_active: true`
- [ ] `recordingStateChanged` events × ≥2 (replaces the twin `.note` pairs from B41)
- [ ] `lightEstimate` events × ≥1 (B42 instrumentation)
- [ ] `materialApplied` for both `entity: "ball"` AND `entity: "hole"` (B40 regression check)

---

## 2. Floor Overlay (LiDAR mesh) ← GOAL-GATING SCORE

**Score:** *(pending Gemini pass)* / 10
**B39 baseline:** 4/10 (jitter, lag, snap, jagged unnatural lines, flickering)
**B42 target:** ≥ 8/10

Expected B42 visual improvements vs B41:
- No double-overlay (rectangular plane overlay disabled on LiDAR devices)
- No z-fight shimmer (mesh sits 2 mm above floor)
- Half the triangle count (back-face emission dropped)

Gemini observations to be inserted here.

---

## 3. Hole Render Regression Check

**Score:** *(pending)* / 10
**B40 baseline:** 2/10 in B39 → expected ≥ 6/10 in B40
**B42 must not regress** — hole/ball code locked at B40 spec.

---

## 4. Ball Render Regression Check

**Score:** *(pending)* / 10
**B40 baseline:** 4/10 → expected ≥ 6/10 in B40

---

## 5. Persistence Check

**Score:** *(pending)* / 10
**B39 baseline:** 9/10 — must hold.

---

## 6. Move ball / Move hole UX

Did the user exercise the new UX?

- [ ] Move ball tapped → ball cleared, hole + flag stayed put
- [ ] Re-place button visible, crosshair active
- [ ] Place at new spot → ball drops, aim line refreshes
- [ ] Same flow for Move hole

JSON signature to look for: a `holePlaced` event with `payload.source = "replace"` whose `ball_x/y/z` match the preceding `ballPlaced` event's coords (proving the preserved ball stayed in world space).

---

## 7. Auto-compact HUD

- [ ] `.onAppear` log shows `auto-compact HUD on (recording active)` within first second of `sessionStart`
- [ ] Gemini reports clean camera frames without HUD chrome blocking

---

## 8. Distance HUD colour + word

- [ ] Distance row reads `1.49 m · short` in green
- [ ] (At >3 m) reads `3.5 m · lag` in orange
- [ ] (At >6 m) reads `7.2 m · long` in red

---

## 9. GT marker pulse

- [ ] Tap a GT marker → button background pulses green for ~0.4 s then fades back
- [ ] No JSON signal — purely visual

---

## 10. Crosshair adaptive opacity

- [ ] Crosshair is 56 pt + 0.95 opacity when no raycast hit (e.g. aimed at wall)
- [ ] Shrinks to 32 pt + ~0.45 opacity when raycast hits surface

---

## 11. Haptic feedback

- [ ] Medium impact felt on successful Place button press
- [ ] Warning haptic felt on Place button press with no raycast hit (no toast needed)
- [ ] No JSON signal — purely physical

---

## 12. Phase B visual overhaul

- [ ] Top bar all 38 pt capsules, version stamp `v0.4.8` visible
- [ ] HUD toggle glyph: `rectangle.dashed` / `rectangle` (NOT eye / eye.slash)
- [ ] Recording dot pulses at 1 Hz in compact mode
- [ ] State transitions spring-animated (HUD slides rather than snaps)

---

## 13. Final Verdict

*Gemini's overall ship/iterate recommendation goes here.*

- Floor overlay: **(pending) / 10**
- Hole render: **(pending) / 10**
- Ball render: **(pending) / 10**
- Persistence: **(pending) / 10**

Ship-ready? **(pending)**

---

## Appendix — what shipped in B42

Code changes summary (commit `7161bc9`):
- `PuttingLab/Sensors/ARMeshManager.swift` — Float→Double area, drop back-face emission, awaiting-classification helper
- `PuttingLab/UI/AR/ARPlacementView.swift` — bulk of Phase A + B work
- `project.yml` — version bump

Reference: full plan at `C:\Users\james\.claude\plans\enchanted-splashing-beaver.md`.
