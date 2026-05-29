#!/bin/sh
# Re-installs the 10 third-party Swift/iOS skills from dpearson2699/swift-ios-skills.
# These are PolyForm Perimeter-licensed (source-available), so we don't redistribute
# them via this repo — install on a fresh clone with this script instead.
#
# Usage: scripts/install-third-party-skills.sh
# Idempotent — safe to re-run.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$PROJECT_ROOT/.claude/skills"
REF_DIR="$PROJECT_ROOT/references"
REPO_DIR="$REF_DIR/swift-ios-skills"
REPO_URL="https://github.com/dpearson2699/swift-ios-skills.git"

mkdir -p "$REF_DIR"

if [ ! -d "$REPO_DIR" ]; then
  echo "Cloning $REPO_URL..."
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
else
  echo "Refreshing $REPO_DIR..."
  (cd "$REPO_DIR" && git pull --depth 1 --no-rebase --ff-only)
fi

mkdir -p "$SKILLS_DIR"

SKILLS="core-motion swift-concurrency swift-testing swiftui-gestures swiftui-animation permissionkit swift-codable ios-accessibility app-store-review storekit"

for skill in $SKILLS; do
  src="$REPO_DIR/skills/$skill"
  dst="$SKILLS_DIR/$skill"
  if [ ! -d "$src" ]; then
    echo "  WARNING: $skill not found in upstream repo (skipping)"
    continue
  fi
  rm -rf "$dst"
  cp -r "$src" "$dst"
  echo "  Installed: $skill"
done

echo ""
echo "Done. Third-party skills installed at:"
echo "  $SKILLS_DIR"
echo ""
echo "License: PolyForm Perimeter 1.0.0 (source-available)."
echo "  See $REPO_DIR/LICENSE for the full text."
