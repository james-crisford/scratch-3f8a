#!/bin/sh
# Xcode Cloud post-clone hook.
# Runs after Xcode Cloud clones the repo and BEFORE it tries to open a .xcodeproj.
# Because we use XcodeGen (project.yml is the source of truth, .xcodeproj is generated),
# we install XcodeGen here and produce the project so Xcode Cloud has something to build.
#
# Activate: in App Store Connect → Xcode Cloud → create workflow pointing at this repo;
# Apple's CI will find ci_scripts/ci_post_clone.sh automatically.

set -e

echo "=== ci_post_clone: installing XcodeGen ==="
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

echo "=== ci_post_clone: generating PuttingLab.xcodeproj ==="
cd "$CI_WORKSPACE"
xcodegen generate --spec project.yml
ls -la PuttingLab.xcodeproj

echo "=== ci_post_clone: done ==="
