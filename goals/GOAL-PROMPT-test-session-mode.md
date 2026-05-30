# /goal prompt — In-app 100-stroke session mode

## Read first (in order)
1. `goals/in-app-test-session-mode.md` — full spec, file plan, audits, push process
2. `PuttingLab/Models/TestBatch.swift` — already created, contains the 100-stroke batch metadata
3. `docs/spec-putting-lab-v1-FINAL.md` — the v1 contract you must not violate
4. `.claude/skills/golf-swing-game-design/SKILL.md` — locked decisions + known unknowns
5. `docs/audit-findings-pre-testflight-2026-05-29.md` — yesterday's audit findings (for context on what NOT to regress)

## What to build
A new guided 100-stroke `PracticeSessionView` with **touch-controlled stroke recording**
that replaces SensorDebugView as the root view. Touch protocol:
press at takeaway → hold through stroke → release at end of follow-through.
StrokeReplay JSON schema STAYS v1. Algorithm code (Physics/, Sensors/, SessionCoordinator)
is UNCHANGED. Full file plan, phase-by-phase UX spec, and TestSessionState API are in
the goal file referenced above.

## Hard rules (non-negotiable)
- Budget ceiling: **$1.50** of remaining GitHub Actions credits
- Max **2 commits** (1 success + at most 1 fix)
- All 315 existing tests must continue to pass
- No changes to: `StrokeReplay.swift`, `Physics/*`, `Sensors/*`, `SessionCoordinator.swift`
- No emojis in code or button labels
- Commit must include `[skip ci]` to suppress auto-trigger
- Manual release via `gh workflow run test.yml -f release=true -f skip_tests=true`

## Run the 7 audits BEFORE commit
Listed in `goals/in-app-test-session-mode.md` §"Rigorous audits BEFORE push":
1. Spec conformance
2. Test count integrity (expected 334 = 315 + 19 new)
3. StrokeReplay schema unchanged
4. Algorithm files unchanged (`git diff --stat HEAD`)
5. Skip codegraph (Swift not indexed)
6. Gemini auto-review summary
7. Manual compile sanity (read every new file)

If ANY audit fails → revert offending change, don't commit.

## Then
1. Stage exact file set listed in goal file
2. Commit with `[skip ci]` in subject
3. `git push`
4. Verify no auto-fired run: `gh run list --workflow=test.yml --limit 1`
5. Trigger: `gh workflow run test.yml -f release=true -f skip_tests=true`
6. Poll: `gh run view <id>` until completion
7. On failure: ONE corrective commit max, then stop + document

## Definition of Done
All of these must be true:

✅ **Code shipped**
- 5 new Swift files in `PuttingLab/` (TestBatch already exists)
- 2 new test files in `PuttingLabTests/UI/`
- `PuttingLabApp.swift` modified to use PracticeSessionView as root
- `docs/testing-tomorrow-plan.md` updated for 100 strokes + touch protocol

✅ **CI green**
- Sign + Upload to TestFlight job: ✓
- Build uploaded to App Store Connect
- `gh run view <id>` shows green for the latest workflow_dispatch run

✅ **TestFlight processing**
- App Store Connect → PuttingLab → TestFlight shows new build with status
  "Processing" or "Ready to Test"
- Build number = previous + 1

✅ **Memory updated**
- `C:\Users\james\.claude\projects\c--Users-james-Desktop-Claude-Agent\memory\project_puttinglab_build.md`
- Includes: latest commit SHA, CI run ID, TestFlight build number, cost spent,
  any unresolved issues

✅ **Summary message ready** matching the format in goal file §"Output"

✅ **Budget under ceiling**
- Total spend this run: < $1.50
- Total spend on Actions: < $9.00 (leaves ≥ $1.00 for tomorrow's re-test)

✅ **No spec violations**
- Algorithm files truly unchanged
- StrokeReplay schema version still 1
- No emojis in code

## Failure path
If anything outside Definition of Done is missing:
1. Document the specific gap
2. Don't push more commits to compensate
3. Leave a clear "needs human" message for James

## Cost-saver reminder
`skip_tests=true` saves ~$0.30/run. Tests already passed on the previous commit
(`bca908c`), and this commit doesn't change Swift algorithm code — only UI.
Test job re-running here is wasteful. Use the input.
