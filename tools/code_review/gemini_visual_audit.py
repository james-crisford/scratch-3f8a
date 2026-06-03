"""gemini_visual_audit.py — score XCUITest screenshots with Gemini Pro.

Scans a folder of PNG screenshots, sends each to Gemini Pro with a
structured prompt, and produces a markdown report scoring the UI for
correctness, clarity, and known-issue regression.

Designed as the visual counterpart to gemini_review.py (which scores
code diffs). Where gemini_review.py catches "is the code right",
gemini_visual_audit catches "does the rendered UI look right".

Usage
-----
1. Extract screenshots from the XCUITest .xcresult bundle (CI does
   this automatically; locally run xcrun xcresulttool):

   xcrun xcresulttool get attachments \\
     --path /path/to/TestResults.xcresult \\
     --output-dir tools/output/screenshots/

2. Run the audit:

   py -3.12 tools/code_review/gemini_visual_audit.py \\
     tools/output/screenshots/ \\
     --out tools/output/visual-audit-bNN.md

The audit prompt is tuned for PuttingLab's AR view — it specifically
checks: HUD copy correctness at each placement state, button presence
+ overlap, debug-overlay Z-index issues, foot marker visibility, mesh
overlay clarity, and the result chip / putt-again button rendering at
.rolled state.

To audit a different app's screenshots, override --prompt-file with
your own prompt template.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).parent.parent.parent
DEFAULT_PROMPT = """You are reviewing iOS app UI screenshots from
PuttingLab's AR placement view. Each screenshot represents one state
in the user's interaction flow. Score each on:

1. **HUD copy correctness** — does the bottom prompt match the expected
   state? (Expected: 'Tap to place ball' / 'Tap to place hole' /
   'Press anywhere to putt' / 'Now swing' / etc.)

2. **Button presence** — which buttons are visible? Do they match the
   state? (Expected at .complete: Reset / Move ball / Move hole)

3. **Overlapping or blocked UI** — does any overlay sit on top of
   another that it shouldn't? (Particularly: debug overlay over result
   chip, press-gesture overlay blocking action buttons.)

4. **Foot markers** (when at .complete after both placements) — are
   the yellow stance markers visible behind the ball?

5. **Mesh overlay** (LiDAR floor scan) — does it read clearly as
   "scanned area"? Is the blue colour vivid enough at the current
   opacity?

6. **Hole render** (when visible) — does the cup read as a recessed
   3D feature or as a flat decal?

7. **Result chip + Putt again button** (at .rolled state) — both
   visible? Top-anchored chip + bottom-right button? Are they obscured
   by other chrome?

Return a JSON object with the structure:
{
  "screenshot_name": "<filename>",
  "state_inferred": "<best guess at placement state>",
  "checks": {
    "hud_copy": {"pass": bool, "found": "...", "expected": "..."},
    "buttons": {"pass": bool, "visible": [...], "missing": [...]},
    "no_overlap": {"pass": bool, "issues": [...]},
    "foot_markers_visible": {"pass": bool, "notes": "..."},
    "mesh_overlay_clear": {"pass": bool, "notes": "..."},
    "hole_3d": {"pass": bool, "notes": "..."},
    "result_ui": {"pass": bool, "notes": "..."}
  },
  "verdict": "PASS|NEEDS_WORK|FAIL",
  "headline": "<one-sentence summary>"
}

If a check is not applicable to this screenshot (e.g. hole render
when no hole is placed), mark pass=true with notes="N/A".
"""


def load_api_key():
    if os.environ.get("GEMINI_API_KEY"):
        return os.environ["GEMINI_API_KEY"]
    for p in [Path(r"C:\Users\james\Desktop\Claude Agent\.env")]:
        if not p.exists():
            continue
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith(("GEMINI_API_KEY=", "GOOGLE_AI_API_KEY=")):
                return line.split("=", 1)[1].strip().strip("'\"")
    return None


def discover_screenshots(folder: Path):
    """Return sorted list of PNG screenshots in a folder. Sorted by
    filename so the visual audit reads top-to-bottom in the order the
    XCUITest captured them (XCUITest attachments get unique suffixes
    but the test sets descriptive names like 01-ready-to-place-ball)."""
    if not folder.exists():
        sys.exit(f"ERROR: screenshot folder does not exist: {folder}")
    pngs = sorted(folder.rglob("*.png"))
    if not pngs:
        sys.exit(f"ERROR: no PNG files found under {folder}")
    return pngs


def review_screenshot(model, png_path: Path, prompt: str, retries: int = 3):
    """Send one screenshot to Gemini with retries on quota failures."""
    import google.generativeai as genai
    last_err = None
    for attempt in range(retries):
        try:
            f = genai.upload_file(path=str(png_path))
            while True:
                f = genai.get_file(f.name)
                state = getattr(f.state, "name", str(f.state))
                if state == "ACTIVE":
                    break
                if state == "FAILED":
                    raise RuntimeError("upload FAILED")
                time.sleep(1)
            resp = model.generate_content([f, prompt],
                                            request_options={"timeout": 90})
            text = getattr(resp, "text", None) or ""
            try:
                genai.delete_file(f.name)
            except Exception:
                pass
            return text
        except Exception as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(10 * (attempt + 1))
                continue
    return f"ERROR: {last_err}"


def parse_verdict(raw: str) -> dict:
    """Extract the JSON object from Gemini's response. Falls back to
    a wrapper dict if Gemini returned prose instead of JSON."""
    if raw.startswith("ERROR:"):
        return {"verdict": "ERROR", "headline": raw, "checks": {}}
    s = raw.find("{")
    e = raw.rfind("}") + 1
    if s < 0 or e <= s:
        return {"verdict": "UNPARSEABLE", "headline": raw[:200], "checks": {}}
    try:
        return json.loads(raw[s:e])
    except json.JSONDecodeError:
        return {"verdict": "UNPARSEABLE", "headline": raw[:200], "checks": {}}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("folder", type=Path,
                    help="Folder containing PNG screenshots")
    p.add_argument("--prompt-file", type=Path, default=None,
                    help="Override the default prompt with a file")
    p.add_argument("--out", type=Path, default=None,
                    help="Output markdown path (default: stdout)")
    p.add_argument("--limit", type=int, default=None,
                    help="Only review the first N screenshots (testing)")
    args = p.parse_args()

    key = load_api_key()
    if not key:
        sys.exit("ERROR: GEMINI_API_KEY missing — set env or add to .env")
    import google.generativeai as genai
    genai.configure(api_key=key)
    model = genai.GenerativeModel("gemini-2.5-pro")

    prompt = (args.prompt_file.read_text(encoding="utf-8")
              if args.prompt_file else DEFAULT_PROMPT)

    screenshots = discover_screenshots(args.folder)
    if args.limit:
        screenshots = screenshots[: args.limit]

    print(f"Reviewing {len(screenshots)} screenshots from {args.folder}",
          file=sys.stderr)

    findings = []
    for i, png in enumerate(screenshots, 1):
        print(f"  [{i}/{len(screenshots)}] {png.name}", file=sys.stderr)
        raw = review_screenshot(model, png, prompt)
        verdict = parse_verdict(raw)
        verdict["screenshot"] = png.name
        verdict["raw"] = raw
        findings.append(verdict)

    # Summary stats.
    n = len(findings)
    pass_count = sum(1 for f in findings if f.get("verdict") == "PASS")
    needs_count = sum(1 for f in findings if f.get("verdict") == "NEEDS_WORK")
    fail_count = sum(1 for f in findings if f.get("verdict") == "FAIL")
    err_count = sum(1 for f in findings if f.get("verdict") in ("ERROR", "UNPARSEABLE"))

    lines = []
    lines.append(f"# Visual audit report\n")
    lines.append(f"**{n} screenshots reviewed** from `{args.folder}`\n")
    lines.append(f"- PASS: {pass_count}")
    lines.append(f"- NEEDS_WORK: {needs_count}")
    lines.append(f"- FAIL: {fail_count}")
    lines.append(f"- ERROR/UNPARSEABLE: {err_count}\n")
    lines.append(f"## Per-screenshot findings\n")
    for f in findings:
        emoji = {"PASS": "✅", "NEEDS_WORK": "⚠", "FAIL": "🚨"}.get(
            f.get("verdict", ""), "❓")
        lines.append(f"### {emoji} {f['screenshot']} — {f.get('verdict', '?')}")
        lines.append(f"**{f.get('headline', '(no headline)')}**\n")
        if f.get("state_inferred"):
            lines.append(f"- State: `{f['state_inferred']}`")
        checks = f.get("checks", {})
        for name, body in checks.items():
            if isinstance(body, dict):
                ok = "✅" if body.get("pass") else "❌"
                notes = body.get("notes") or body.get("found") or ""
                lines.append(f"- {ok} **{name}**: {notes}")
        lines.append("")
    md = "\n".join(lines)
    if args.out:
        args.out.write_text(md, encoding="utf-8")
        print(f"Report saved to {args.out}", file=sys.stderr)
    else:
        print(md)


if __name__ == "__main__":
    main()
