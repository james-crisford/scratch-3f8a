# PuttingLab — design (index)

Convention entry point (STANDARDS §2). PuttingLab is heavily documented already — this organises it. **Living**: update the relevant doc in the same change as the code; significant trade-offs go in `decisions/`.

## Canonical
- **Spec (source of truth):** [`../spec-putting-lab-v1-FINAL.md`](../spec-putting-lab-v1-FINAL.md)
- **Cited research** (physics, sensors, IMU, terrain, etc.): `../research/` (+ the workspace `research_archive/puttinglab-*` reports)
- **Stage plans/verification:** `../stage-3-goal.md`, `../stage-3-plan.md`, `../stage-3-verification.md`
- **Feature design + verification (build series):** the `b41…b66` docs (e.g. [`../b64-design-spec.md`](../b64-design-spec.md), `../b42-design-review.*`, `../b43-hole-options.*`), `../hole-options/`, `../ar-replay/`, `../stance-renders/`
- **References:** `../putting-stance-reference.md`, `../b51-stance-code-crossref.md`
- Code: `PuttingLab/` (App/Models/Sensors/Physics/Calibration/UI/Storage — Xcode feature-layered, the blessed `src/` exception); tests in `PuttingLabTests/`.

## Decisions
Significant trade-offs (e.g. "why xMagneticNorthZVertical", "why Wii-Sports snap rules") → one markdown each in `decisions/` (ADR style; supersede, don't edit).
