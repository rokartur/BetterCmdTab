#!/usr/bin/env bash
#
# update-packages.sh — bump every Swift Package dependency to the newest
# version allowed by the project's version rules (e.g. upToNextMajor), then
# re-resolve.
#
# Why clear the pins: `xcodebuild` has no "update" verb — updating to the
# latest versions is only exposed in Xcode's
# File ▸ Packages ▸ Update to Latest Package Versions. Deleting the pinned
# Package.resolved and re-resolving reproduces that from the CLI.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/../BetterCmdTab.xcodeproj"
SCHEME="BetterCmdTab Debug"
RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

echo "==> Updating Swift packages for $(basename "$PROJECT")"

if [[ -f "$RESOLVED" ]]; then
  echo "    current pins:"
  grep -E '"identity"|"version"' "$RESOLVED" | sed 's/^/      /'
  rm "$RESOLVED"
  echo "    cleared pins"
fi

xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME"

echo ""
echo "==> Resolved versions:"
grep -E '"identity"|"version"' "$RESOLVED" | sed 's/^/  /'
echo ""
echo "Review the diff and commit:"
echo "  $RESOLVED"
