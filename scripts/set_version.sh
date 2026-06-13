#!/usr/bin/env bash
#
# set_version.sh — Set the app's marketing version (CFBundleShortVersionString).
#
# Updates MARKETING_VERSION for the BetterCmdTab app target in project.pbxproj.
# The test target keeps its own version untouched.
#
# Usage:
#   scripts/set_version.sh 26.1               # set marketing version to 26.1
#   scripts/set_version.sh 26.1 --bump-build  # also stamp a fresh build number
#   scripts/set_version.sh 26.1 --no-commit   # update but don't commit
#   scripts/set_version.sh --show             # print current version & build
#
# On success the version/build change to project.pbxproj is committed
# automatically (chore: bump …). Pass --no-commit to leave it staged for review.
#
# Note: the release build number (CURRENT_PROJECT_VERSION) is normally stamped
# automatically by build_release.sh on every build. Use --bump-build only when
# you want a fresh timestamp without running a release build.
#
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

APP_NAME="BetterCmdTab"
SCHEME="BetterCmdTab"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/${APP_NAME}.xcodeproj"
PBXPROJ="${PROJECT_PATH}/project.pbxproj"

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: scripts/set_version.sh <version> [--bump-build]
       scripts/set_version.sh --show

Arguments:
  <version>       New marketing version, e.g. 26.1 or 27.0.2

Options:
  --bump-build    Also set CURRENT_PROJECT_VERSION to a fresh timestamp.
  --no-commit     Don't commit the change; leave it for manual review.
  --show          Print the current version and build number, then exit.
  -h, --help      Show this help message.
EOF
}

current_setting() {
  # Resolve a build setting for the app scheme (config-independent here).
  xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | grep " $1 = " | head -1 | awk '{print $NF}'
}

# ─── Parse arguments ──────────────────────────────────────────────────────────

bump_build=0
do_commit=1
new_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump-build) bump_build=1 ;;
    --no-commit) do_commit=0 ;;
    --show)
      echo "Version: $(current_setting MARKETING_VERSION) (build $(current_setting CURRENT_PROJECT_VERSION))"
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "❌ Unknown option: $1" >&2
      usage
      exit 64
      ;;
    *)
      if [[ -n "$new_version" ]]; then
        echo "❌ Unexpected extra argument: $1" >&2
        usage
        exit 64
      fi
      new_version="$1"
      ;;
  esac
  shift
done

if [[ -z "$new_version" ]]; then
  echo "❌ Missing <version> argument" >&2
  usage
  exit 64
fi

# Accept dotted numeric versions only (e.g. 26, 26.1, 27.0.2).
if [[ ! "$new_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "❌ Invalid version '${new_version}'. Use a dotted numeric version like 26.1" >&2
  exit 64
fi

# ─── Update marketing version ─────────────────────────────────────────────────

version_changed=0
build_changed=0

current_version="$(current_setting MARKETING_VERSION)"
if [[ -z "$current_version" ]]; then
  echo "❌ Could not determine current MARKETING_VERSION from project" >&2
  exit 1
fi

if [[ "$current_version" == "$new_version" ]]; then
  echo "ℹ️  MARKETING_VERSION is already ${new_version}; nothing to change."
else
  echo "   Version: ${current_version} → ${new_version}"

  # Only the app target carries this value; the test target uses its own version,
  # so replacing the exact current value touches just the app's Debug+Release configs.
  count="$(grep -c "MARKETING_VERSION = ${current_version};" "$PBXPROJ" || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "❌ No 'MARKETING_VERSION = ${current_version};' lines found in project.pbxproj" >&2
    exit 1
  fi

  sed -i '' \
    "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${new_version};/g" \
    "$PBXPROJ"

  actual="$(current_setting MARKETING_VERSION)"
  if [[ "$actual" != "$new_version" ]]; then
    echo "❌ Version update verification failed (got ${actual}, expected ${new_version})" >&2
    exit 1
  fi
  echo "✅ MARKETING_VERSION set to ${new_version} (${count} entr$([[ $count -eq 1 ]] && echo y || echo ies))"
  version_changed=1
fi

# ─── Optionally stamp a fresh build number ─────────────────────────────────────

if [[ $bump_build -eq 1 ]]; then
  old_build="$(current_setting CURRENT_PROJECT_VERSION)"
  new_build="$(date +%Y%m%d%H%M%S)"
  echo "   Build number: ${old_build} → ${new_build}"

  # Scope the rewrite to the app target's build configurations: the test
  # target seeds the same value, and a global sed would stamp it too
  # (the contract is that the test target keeps its own version).
  app_config_ids="$(sed -n "/Build configuration list for PBXNativeTarget \"${APP_NAME}\" \*\/ = {$/,/);/p" \
    "$PBXPROJ" | grep -E '\*/,$' | grep -oE '[A-F0-9]{24}')"
  if [[ -z "$app_config_ids" ]]; then
    echo "❌ Could not locate the ${APP_NAME} target's build configurations in project.pbxproj" >&2
    exit 1
  fi
  for cfg_id in $app_config_ids; do
    sed -i '' \
      "/${cfg_id} .*= {$/,/};/ s/CURRENT_PROJECT_VERSION = ${old_build};/CURRENT_PROJECT_VERSION = ${new_build};/" \
      "$PBXPROJ"
  done

  actual_build="$(current_setting CURRENT_PROJECT_VERSION)"
  if [[ "$actual_build" != "$new_build" ]]; then
    echo "❌ Build number update verification failed (got ${actual_build}, expected ${new_build})" >&2
    exit 1
  fi
  echo "✅ CURRENT_PROJECT_VERSION set to ${new_build}"
  build_changed=1
fi

# ─── Commit the bump ───────────────────────────────────────────────────────────

if [[ $version_changed -eq 0 && $build_changed -eq 0 ]]; then
  echo ""
  echo "Nothing changed; nothing to commit."
  exit 0
fi

# Build a message describing exactly what moved.
if [[ $version_changed -eq 1 && $build_changed -eq 1 ]]; then
  commit_msg="chore: bump version to ${new_version} (build ${new_build})"
elif [[ $version_changed -eq 1 ]]; then
  commit_msg="chore: bump version to ${new_version}"
else
  commit_msg="chore: bump build number to ${new_build}"
fi

echo ""
if [[ $do_commit -eq 0 ]]; then
  echo "Done. Review the change with:  git diff ${APP_NAME}.xcodeproj/project.pbxproj"
elif ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ℹ️  Not a git repository (or git unavailable); skipping commit."
  echo "   Review the change with:  git diff ${APP_NAME}.xcodeproj/project.pbxproj"
elif git -C "$REPO_ROOT" diff --quiet HEAD -- "$PBXPROJ"; then
  # Values were rewritten to what's already committed (e.g. same-second build
  # timestamp); there's genuinely nothing to record.
  echo "ℹ️  project.pbxproj matches HEAD; nothing to commit."
else
  # Commit only project.pbxproj so an unrelated staged change isn't swept in.
  git -C "$REPO_ROOT" commit -q -m "$commit_msg" -- "$PBXPROJ"
  echo "✅ Committed: ${commit_msg}"
fi
