# Contrarian Verdict — PuttingLab

**Recommendation:** PIVOT (ship free, defer paywall, cap further spend at £79 Apple fee + 3 days)

**Strongest case against:** The opportunity cost is asymmetric and structural — 10 dev-days against a 3DPE backlog where one closed ICP B client (£500-£5k AOV, verified pipeline, "3d printing service" 5,400/mo UK volume already in `keyword_volumes`) returns 10-50x PuttingLab's plausible Y1 ceiling at one-tenth the technical risk, while PuttingLab's £14.5k UK paying-user ceiling (Voice 4's funnel: 700k × 0.30 × 0.30 × 0.31 × 0.03) cannot service even the £8-15 golf-vertical UAC needed to fill it (Voice 3's LTV/CAC = 0.04).

**Why it survives / how to mitigate:** Voice 2's technical kill is repairable — `break-fix-break-final.md` shows 24 critical bugs fixed across 5 cycles, 307 tests green, KI-1/2/4/5/6 are explicitly device-verification items not unknown unknowns, and the AsyncStream refactor (C4) closed the concurrency footguns. The face-angle ±2° concern is mitigated by the snap-to-square contract (KI-7 closed, spec §5.2) — the product never shows a face number it can't defend. Voice 1's "55-70% uninstall" is speculative (no primary data). Voice 4's "persona invented" is true but cheaply fixable with 12 Prolific interviews (£100). What does NOT mitigate is Voice 5: even a perfectly-built PuttingLab competes for James's hours against a 3DPE lane with verified demand, verified pricing, verified customers, and tooling James already owns. The spec defines "done" but has no kill criteria — that alone justifies a pivot to a capped, free-shipped experiment rather than a paid product build.

**Three specific tests the project must pass on iPhone 13 before James spends another hour:**
1. **Sign-convention + magnetometer reality check (KI-1 + KI-4):** 20 deliberate pull strokes + 20 push strokes on real iPhone 13 holding a steel-shafted putter near the phone; `ImpactResult.faceAngleRaw` sign must agree with intended direction ≥18/20 per side. If <18/20, the core read is broken and snap-to-square will fire on >50% of strokes — kill the paid claim.
2. **Thermal + ARKit-lost rate over 20 minutes continuous use:** if iPhone 13 throttles or ARKit drops to `.limited` for >30% of stroke windows during a realistic 15-minute session, the "hallway anywhere" use case is dead and the product collapses to "outdoor practice green only" — at which point Wellputt mat (£80 one-time) wins on fidelity.
3. **Cold-eye user test, no coaching (Voice 5's change-mind test):** sideload via AltStore to 3 unaffiliated golfers, watch 5 minutes each silently; ≥2/3 must say "I'd pay" unprompted AND average <3 strokes-to-frustration. This is the only test that touches the unfalsifiable layer (does anyone want this).

**One question James should ask 3 golfers before TestFlight upload:** "If I gave you this app free today, would you actually open it again next week without me asking — and if yes, where would you use it?"

If answer is "on the practice green," the phone-only premise is dead (they have a real ball there); only "in the hallway / hotel room / lunch break" answers validate the wedge.

