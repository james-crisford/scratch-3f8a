# Stance renders — DEPRECATED 2026-06-03

The illustration attempts in this folder did not land:

- `index.html` (Three.js) — rendered blank canvases; root cause not pinned down (likely importmap/CDN under headless screenshot). Pivoted to SVG.
- `putting-pose-diagram.html` + `putting-pose-diagram.png` (SVG, 4 views) — rendered fine but James reviewed them and said the diagrams don't help — crude stick figures + flat 2D phone rectangles don't communicate the 3D orientation clearly enough.

**Single source of truth for the pose:** `docs/putting-stance-reference.md` § "Phone axis → world direction table".

**Better paths if a visual is needed later:**
1. A real photo of James in the putting pose (kills all ambiguity instantly)
2. A short video clip of the swing motion
3. A proper iso 3D render from a real iPhone model + an articulated human rig (out of scope for a Three.js / SVG one-shot)

Keeping the files for archaeology — do not link to them from current docs.
