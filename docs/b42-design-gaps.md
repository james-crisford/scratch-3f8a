# PuttingLab B42 — Honest Design Gap List

What's currently in the app at B42 (0.4.8) is **a placement + AR-tracking testbed**, not a finished putting game. Plenty of gaps. I'm not going to pretend otherwise. This document lists every gap I can see, ranked by impact.

Mockups for reference: [b42-design-review.html](b42-design-review.html) / [.png](b42-design-review.png) and [hole-iterator.html](hole-iterator.html) / [.png](hole-iterator.png).

---

## 🟥 Tier A — system-level gaps (the big ones)

These are the gaps that mean "this isn't yet a putting game". Visual polish doesn't fix any of them.

### A1. No actual gameplay
You place a ball + hole, that's it. No stroke detection in Slice 2, no result visualisation, no putt-roll, no scoring. The spec for stroke detection + Mario-Kart assist + distance modelling lives in `Sensors/` + `Physics/` but is not wired into the AR placement view. **The user can't actually putt.**

### A2. No "stand here" anchor
You set the ball position. You set the hole position. But the user has no idea where to physically stand. A real putter addresses the ball; in our app the ball is anywhere, you're anywhere. Missing: an address-stance marker on the floor showing "put your feet about here".

### A3. No address-pose calibration shown in AR
The calibration coordinator exists (`Calibration/CalibrationCoordinator.swift`) but doesn't render anything visible to the user during placement. You don't know if your hands are gripped right, if the phone is held vertically, if the address pose is captured.

### A4. No predicted putt-line / break visualisation
Aim line is a straight yellow box. Real putting greens have break. Without a curve overlay we're telling the user "putt straight" which is wrong for any non-trivial putt. Need to render a curved predicted line based on slope.

### A5. No green-slope detection
The app treats the floor as perfectly flat. Real putting greens slope 1-4°, which dominates the read. ARKit can detect slope from the plane normal — we throw it away.

### A6. No green-speed (stimpmeter) calibration
Every floor reads the same in physics terms. A 6 stimp (slow) green and a 12 stimp (fast) green are wildly different putts; we have no UI to capture or model that.

---

## 🟧 Tier B — visual fidelity gaps (Gemini's job to score)

These will reduce realism scores even if Gemini likes the underlying geometry.

### B1. Ball has no dimples
Currently a featureless smooth UnlitMaterial sphere. Real golf balls have ~336 dimples. Fix: procedural normal map. ~30 min of work, would boost ball realism from 4/10 → 7-8/10.

### B2. No specular highlight on the ball
UnlitMaterial pins the ball at flat white. Real balls under indoor light have a bright spot from each light source. We have NO highlight, making the ball look CG / cartoony. Fix: switch to `PhysicallyBasedMaterial` with high baseColor + low roughness + explicit clearcoat — but this re-introduces the lighting-darkening risk that we just escaped with UnlitMaterial. Trade-off.

### B3. Flagstick is a single uniform white pole
Real flagsticks have either red/white stripes (USGA marker tape) OR a contrasting ferrule near the cup. Ours is one solid white. Reads correctly as "flagstick" but lacks course-realism cues.

### B4. Flag has no fabric texture or wave animation
Static red triangle. Real flags flutter. Vertex shader for gentle wave + fabric normal map = quick win.

### B5. Cup wall gradient is decorative, not lighting-driven
The white-to-dark gradient on the cup interior is a static texture, not a real lighting effect. In Three.js (and in the real app via UnlitMaterial) it's baked. Adding real-time lighting would mean MeshStandardMaterial which re-introduces the darkening bug we fixed in B40.

### B6. Aim line is a solid yellow box
12mm-square yellow box from ball to hole. No animation, no fade, no distance markers. Could be:
- dashed (clearer at distance)
- pulsing toward the hole (motion cue)
- gradient (yellow → fade near the cup to not obscure)
- distance ticks every metre

### B7. No grass / green texture
Floor is whatever the user's actual floor is. If you're testing on hardwood, it doesn't look like a green. Could add an optional "virtual green" overlay around the hole area.

### B8. No "you holed it" effect
When ball roll physics ships, dropping the ball in the cup is going to be the satisfying climax of the game. Currently no animation, no sound, no haptic — just a ball that stops moving.

---

## 🟨 Tier C — UX gaps

### C1. No way to nudge ball or hole position by small amounts
Currently Move ball / Move hole = "completely re-place". For a 1cm tweak the user has to crosshair-aim from across the room again. Should add: directional nudge buttons (N/S/E/W ±1cm) on the placed entity when at .complete state.

### C2. No "save this configuration" affordance
Each session is fresh. If James wants to test the same 2m putt 50 times in a row to validate consistency, every session he has to re-place everything.

### C3. No distance presets
No "set up a 1m putt" / "set up a 3m putt" buttons. User crosshairs everything by hand each time.

### C4. No undo on placement
Place the ball in slightly the wrong spot → has to Reset and re-do both, OR use Move ball + cross room + re-place. A single undo button at .complete would be huge.

### C5. No alternate flag colours
Always red. Real courses use red/yellow/blue depending on pin position (front/middle/back).

### C6. No "Show ARKit raw data" power-user toggle
For debugging in the field, would be useful to flip a switch and see the underlying plane meshes / mesh anchors / classification labels directly.

### C7. No accessibility considerations
Voice-Over labels aren't set on the AR view itself (it's a camera feed). Dynamic Type support unverified. Reduce-motion respected for state transitions ONLY, not for the SF Symbol pulse on the recording dot.

---

## 🟩 Tier D — instrumentation gaps

### D1. No FPS counter
Useful during testing — would let us spot regressions when LiDAR + render + ARKit all run together.

### D2. No memory-pressure log
ARKit can OOM on long sessions. We don't surface it.

### D3. No thermal-state log
Phone gets hot during scan-heavy sessions. `ProcessInfo.thermalState` transitions are worth capturing.

### D4. No camera intrinsics captured
For any later 3D reconstruction work, `frame.camera.intrinsics` would be valuable. One-time emit alongside `deviceInfo` would be cheap.

### D5. No `placementError` event for crosshair-raycast miss
We log `raycastMiss` for tap path but the crosshair Place button silently fires a haptic + toast on miss with no JSON marker.

### D6. No A/B-test scaffolding
Once we have actual gameplay, we'll want to A/B test things (line styles, haptic patterns, ball visual fidelity). Zero infrastructure for that today.

---

## 🟦 Tier E — what's already good (don't break)

For completeness, these are the bits that ARE working well and shouldn't be touched:

- **AR anchoring.** Gemini scored persistence 9/10 on CAC00F. Locked.
- **LiDAR mesh detection** (post-B42). The triangle overlay following the actual floor outline is a major win.
- **Crosshair raycast placement.** Precise, predictable, accuracy 9/10.
- **HUD compact mode.** Clean review frames by default in B42.
- **Distance read.** Colour-coded + word label adds meaning.
- **Move ball / Move hole.** New in B42, addresses real user need.
- **Send-this preflight modal.** Shows the user exactly what's about to go in the share sheet.
- **Auto-recording.** Every session is captured, no remembering required.

---

## Recommended next-build priorities

If B42 Gemini scores hit the ≥8/10 floor + ≥6/10 hole bars:

**B43 (next ship):**
- A1 → wire actual stroke detection from `Sensors/StrokeDetector.swift` into the AR view
- A2 → render an address-stance marker on the floor at session start
- B1 → ball dimples via procedural normal map
- B4 → flag flutter animation (vertex shader)
- C4 → undo button on placement
- D3 → thermal-state logging

**B44+:**
- A4 → predicted putt-line (curved) based on slope
- A5 → green-slope detection from plane normals
- A6 → green-speed picker UI
- B2 → ball specular highlight (carefully — re-introduces lighting risk)

**Long tail:**
- A3 calibration AR overlay
- C1-C7 UX polish bundle
- D1-D6 instrumentation suite
- E1-E8 visual fidelity polish

---

## The honest summary

For a v0.4 testing build, what you'll see in B42 is **good enough to validate the AR pipeline works**. It is NOT good enough to be called a putting game. The Tier A gaps are the work between "demo" and "ship".

If you want me to ship Tier A items into B43 *while we wait for Gemini's B42 verdict*, I can stack that work on top — the AR placement code is stable enough that adding the stroke wiring + address marker won't regress it. Your call.
