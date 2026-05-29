# Goal: Pre-TestFlight hardening (autonomous run)

**Triggered:** 2026-05-29 evening, James out for ~3 hours.
**Budget cap:** £1.00 GitHub Actions spend MAX (we have £2.50 remaining; reserve £1.50 for tomorrow's signed upload + re-test).
**Deadline:** James returns in 3h. Stop and document if blocked.

## What to do

1. **Read** `docs/audit-findings-pre-testflight-2026-05-29.md` end-to-end. That doc is
   the authoritative list of 36 findings from the 9-audit sweep + reference-repo crib study.

2. **Fix the 8 SHIP-BLOCKERs (B1-B8)** in priority order. Each one has a specific
   file:line and a concrete fix pattern in the findings doc.

3. **Fix the 9 HIGH-RISKs (H1-H9)** if you can do it without exceeding 2 commits
   total. If only some fit, prioritise H1 (scenePhase), H2 (jank), H5 (camera fallback),
   H4 (start race).

4. **Skip everything in MEDIUM/LOW and NOT-A-BUG sections.** Do not touch them.

5. **Write the Python replay viz** (`tools/puttinglab/replay_viz.py`) — cribbed from
   `references/CoreMotion-Data-Logger/Visualization/exampleVisualizer.py`. Skeleton
   that loads a `StrokeReplay` JSON and plots 3 stacked timelines (rotation magnitude,
   userAccel magnitude, yaw drift). ~50 lines. Use matplotlib. We'll use this tomorrow
   to look at James's real device data.

6. **Document every fix** in `docs/pre-testflight-hardening-progress-2026-05-29.md`
   as you go (append-only). For each fix, log:
   - Finding ID (B1, H3, etc.)
   - File:line touched
   - One-line summary of what changed
   - Confidence (HIGH/MEDIUM/LOW that this works without device verification)
   - Tests added/touched

7. **Run nothing.** This is Windows — no Xcode, no simulator. Trust the existing 315
   tests + your edits. Push when ready; CI on macOS-15 runs the tests.

8. **Commit budget: 2 commits max tonight.**
   - Commit 1: all SHIP-BLOCKER fixes + best HIGH-RISK fixes
   - Commit 2 (only if Commit 1 CI is RED): fix the breakage
   - Push and watch CI via the GitHub Actions tab URL — alert James in summary if it
     goes red and stop.

9. **Update memory** at end of run via Edit on
   `C:\Users\james\.claude\projects\c--Users-james-Desktop-Claude-Agent\memory\project_puttinglab_build.md`
   with: latest commit, what was hardened, CI status, what's left for James to verify.

## Hard guardrails

- **Do NOT** modify any file in `.claude/skills/` (skill annotations land via PR
  review, not autonomous runs).
- **Do NOT** modify `docs/spec-putting-lab-v1-FINAL.md` (the contract).
- **Do NOT** rename "Sensor Debug" yet — internal TestFlight tomorrow is fine; rename
  before external TestFlight or App Store submission (out of scope tonight).
- **Do NOT** add new external dependencies (no Swift Package additions).
- **Do NOT** push more than 2 commits.
- **Do NOT** force-push, rebase, or delete branches.
- **Do NOT** start the work without first reading the findings doc.
- **If a fix touches >5 files** OR **breaks an existing test**, stop and document
  in the progress log; do not push.

## Definition of done

Required:
- All 8 SHIP-BLOCKERs marked done or explicitly explained-not-done in progress log
- Progress log written to `docs/pre-testflight-hardening-progress-2026-05-29.md`
- 1-2 commits pushed
- CI green on final commit (verify via Actions tab — if you can't auth gh CLI, link
  the run URL in the progress log for James to check)
- Memory updated

Stretch:
- HIGH-RISK fixes shipped (some or all of H1-H9)
- `tools/puttinglab/replay_viz.py` written and committed

## How to pick which HIGH-RISKs to ship

Use this priority order if you only have budget for some:

1. **H1 scenePhase .inactive** — every notification breaks a tester stroke. Essential.
2. **H4 start() race guard** — simple 1-line guard, no risk.
3. **H2 detached JSON save** — easy, big UX win.
4. **H6 .timeLimit traits on perf tests** — prevents CI flake.
5. **H3 banner re-check on scenePhase active** — small, no risk.
6. **H9 explicit date strategy in stores** — small, prevents silent bugs.
7. **H7 UserDefaults isolation** — bigger refactor of tests, ship if time.
8. **H8 .arkitLost withKnownIssue** — small annotation.
9. **H5 compass-only fallback** — biggest scope, defer if any uncertainty.

## If something goes wrong

- **Tests break locally** (can't run them but Gemini auto-review or eyeball): revert
  the offending change and continue with others. Document in progress log.
- **CI goes red after push:** read the failure log, write a 1-paragraph diagnosis in
  progress log, do ONE more commit to fix. If 2nd commit also red, leave it for
  James to look at — don't burn more budget.
- **Budget hit £1.00:** stop pushing immediately. Document what's local-only-not-pushed.
- **Confused about a fix:** skip it, mark as DEFERRED in the progress log with the
  reason. Honesty > heroics.

## Output

When you return control to James, give him a single concise summary:

```
Pre-TestFlight hardening complete. Commits: <sha1>, <sha2>.
SHIP-BLOCKERs fixed: B1, B2, ...
HIGH-RISKs fixed: H1, H4, ...
Deferred: H5 (scope), ms10-12 (medium tier).
CI: <green/red, URL>.
Tests: <N> green / <M> changed.
Budget used: ~£<X> of £1.00 cap.
Outstanding for James: <list>.
Full progress log: docs/pre-testflight-hardening-progress-2026-05-29.md.
```

That's it. Direct, no fluff.

---

*Filed under: PuttingLab v1, pre-TestFlight, autonomous run protocol.*
