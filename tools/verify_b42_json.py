"""B42 JSON pre-flight validator.

Run BEFORE handing a recording's JSON off to Gemini — catches:
  - missing required B42 events (would mean a code path didn't fire)
  - malformed payloads (would mean schema drift)
  - regression in B40 events (materialApplied, hole/ball logging)

Usage:
    py -3.12 tools/verify_b42_json.py <path-to-session-json>

Exit codes:
    0 = JSON looks good, ready for Gemini
    1 = critical defect — DO NOT trust this recording's data
    2 = warnings only (e.g. lightEstimate missing — non-LiDAR phone)
"""
import json
import sys
from collections import Counter
from pathlib import Path


REQUIRED_KINDS = {
    "sessionStart",        # always first event
    "deviceInfo",          # B40 — device fingerprint
    "trackingState",       # ARKit firing
    "materialApplied",     # B40 — hole/ball materials logged
}

# Conditionally required on LiDAR-capable devices (iPhone Pro models).
LIDAR_REQUIRED_KINDS = {
    "meshAdded",
    "meshUpdated",
    "meshStats",
}

# B42-specific new events.
B42_REQUIRED_KINDS = {
    "recordingStateChanged",  # B42 — replaces twin .note pairs
}

# B42 conditional — fires only when LiDAR detects light (every 5 s on iPhone Pro).
B42_LIDAR_REQUIRED = {
    "lightEstimate",
}


def fail(msg: str) -> None:
    print(f"\033[91mFAIL\033[0m {msg}")


def warn(msg: str) -> None:
    print(f"\033[93mWARN\033[0m {msg}")


def ok(msg: str) -> None:
    print(f"\033[92m OK \033[0m {msg}")


def validate(json_path: Path) -> int:
    if not json_path.exists():
        fail(f"JSON not found: {json_path}")
        return 1

    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail(f"JSON parse error: {e}")
        return 1

    events = data.get("events", [])
    if not events:
        fail("Zero events in session — recording is broken")
        return 1

    kind_counts = Counter(e.get("kind", "?") for e in events)
    print(f"\nSession: {data.get('sessionId', '?')}")
    print(f"Started: {data.get('startedAt', '?')}  Ended: {data.get('endedAt', '?')}")
    print(f"Total events: {len(events)}")
    print(f"Kind breakdown: {dict(kind_counts.most_common())}\n")

    failures = 0
    warnings = 0

    # --- Required events ---
    for kind in REQUIRED_KINDS:
        if kind_counts.get(kind, 0) == 0:
            fail(f"MISSING required event kind: {kind}")
            failures += 1
        else:
            ok(f"{kind} × {kind_counts[kind]}")

    # --- Detect LiDAR via deviceInfo payload ---
    device_info_events = [e for e in events if e.get("kind") == "deviceInfo"]
    lidar = False
    if device_info_events:
        payload = device_info_events[0].get("payload", {})
        lidar_str = str(payload.get("lidar_mesh_supported", "false")).lower()
        lidar = lidar_str == "true"
        print(f"\nDevice: {payload.get('device_model', '?')} (iOS {payload.get('ios_version', '?')})")
        print(f"LiDAR mesh supported: {lidar}")

    # --- LiDAR-conditional checks ---
    if lidar:
        for kind in LIDAR_REQUIRED_KINDS:
            if kind_counts.get(kind, 0) == 0:
                fail(f"LiDAR device missing required event: {kind}")
                failures += 1
            else:
                ok(f"{kind} × {kind_counts[kind]}")

        # meshStats payload shape
        mesh_stats_events = [e for e in events if e.get("kind") == "meshStats"]
        if mesh_stats_events:
            ms = mesh_stats_events[-1]
            p = ms.get("payload", {})
            try:
                floor_area = float(p.get("floor_area_m2", "0"))
                tri_count = int(p.get("triangle_count_floor", "0"))
                lidar_active = str(p.get("lidar_active", "false")).lower() == "true"

                if not lidar_active:
                    fail("meshStats has lidar_active=false on a LiDAR device")
                    failures += 1
                elif floor_area <= 0:
                    fail(f"meshStats has floor_area_m2={floor_area} on a LiDAR device")
                    failures += 1
                elif tri_count <= 0:
                    fail(f"meshStats has triangle_count_floor={tri_count}")
                    failures += 1
                else:
                    ok(f"meshStats final: floor={floor_area:.2f}m² tris={tri_count} lidar_active=true")
            except (ValueError, TypeError) as e:
                fail(f"meshStats payload parse error: {e}")
                failures += 1
    else:
        warn("Non-LiDAR device — skipping LiDAR-conditional checks")
        warnings += 1

    # --- B42-specific events ---
    for kind in B42_REQUIRED_KINDS:
        if kind_counts.get(kind, 0) == 0:
            fail(f"B42 MISSING: {kind} (state machine + logger wiring regression?)")
            failures += 1
        else:
            ok(f"{kind} × {kind_counts[kind]} (B42 instrumentation)")

    if lidar:
        for kind in B42_LIDAR_REQUIRED:
            if kind_counts.get(kind, 0) == 0:
                warn(f"B42: {kind} expected on LiDAR device but missing (may be a non-throttled <5s session)")
                warnings += 1
            else:
                ok(f"{kind} × {kind_counts[kind]} (B42 instrumentation)")

    # --- materialApplied payload regression check ---
    mat_events = [e for e in events if e.get("kind") == "materialApplied"]
    if mat_events:
        entities = set(e.get("payload", {}).get("entity", "?") for e in mat_events)
        if "ball" in entities and "hole" in entities:
            ok("materialApplied: both ball + hole logged (B40 regression check)")
        elif "ball" in entities:
            warn("materialApplied: ball only — user did not place hole?")
            warnings += 1
        elif "hole" in entities:
            warn("materialApplied: hole only — user did not place ball?")
            warnings += 1
        else:
            fail(f"materialApplied has unexpected entities: {entities}")
            failures += 1

    # --- B42 Move ball / Move hole check (informational) ---
    replace_events = [
        e for e in events
        if e.get("kind") in ("ballPlaced", "holePlaced")
        and str(e.get("payload", {}).get("source", "")).startswith("replace")
    ]
    if replace_events:
        ok(f"B42 Move ball/hole exercised: {len(replace_events)} replace event(s)")
    else:
        warn("B42 Move ball/hole not exercised in this session (informational)")
        warnings += 1

    # --- Final verdict ---
    print()
    if failures:
        print(f"\033[91m{failures} failures, {warnings} warnings\033[0m")
        print("DO NOT trust this recording. Investigate before Gemini.")
        return 1
    if warnings:
        print(f"\033[93m{warnings} warnings\033[0m")
        print("Clean enough for Gemini, but read the warnings.")
        return 2
    print("\033[92mAll checks passed.\033[0m Ready for Gemini.")
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    return validate(Path(sys.argv[1]))


if __name__ == "__main__":
    sys.exit(main())
