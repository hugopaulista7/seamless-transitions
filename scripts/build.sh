#!/bin/zsh
# Usage: scripts/build.sh [build|test|run]   (default: build)
set -euo pipefail
cd "$(dirname "$0")/.."
ACTION="${1:-build}"
command -v xcodegen >/dev/null && xcodegen generate --quiet
XCB=(xcodebuild -project SeamlessTransitions.xcodeproj -scheme SeamlessTransitions -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64')
case "$ACTION" in
  build) "${XCB[@]}" build -quiet ;;
  test)  "${XCB[@]}" test 2>&1 | grep -E "error:|warning:|✘|Test run with|TEST (SUCCEEDED|FAILED)" ;;
  run)   "${XCB[@]}" build -quiet && open build/Build/Products/Debug/SeamlessTransitions.app ;;
  *) echo "unknown action $ACTION"; exit 1 ;;
esac
