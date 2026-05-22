#!/usr/bin/env bash
#
# build_release.sh — Build, sign, notarize, and zip BetterCmdTab for distribution.
#
# Usage:
#   scripts/build_release.sh               # stable release (default)
#   scripts/build_release.sh --beta        # beta / pre-release build
#   scripts/build_release.sh --skip-notarization  # skip notarize+staple (dev builds)
#
# Output:
#   build/release/BetterCmdTab-<version>-<build>.dmg
#   build/release/BetterCmdTab-<version>-<build>.zip
#
# Requirements:
#   - Xcode with "Developer ID Application" certificate installed
#   - App-specific password stored in Keychain for notarytool:
#       xcrun notarytool store-credentials "BetterCmdTabNotarization" \
#         --apple-id "your@email.com" \
#         --team-id "N529W98U62" \
#         --password "xxxx-xxxx-xxxx-xxxx"
#
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

TEAM_ID="N529W98U62"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Artur Rok (${TEAM_ID})}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-BetterCmdTabNotarization}"
SCHEME="BetterCmdTab Release"
BUNDLE_ID="pro.bettercmdtab.BetterCmdTab"
APP_NAME="BetterCmdTab"
RELEASE_REPO="rokartur/BetterCmdTab"

# ─── Parse arguments ────────────────────────────────────────────────────────

is_beta=0
skip_notarization=0
clean_build=0
auto_release=0
skip_build_bump=0
release_notes=""

usage() {
  cat <<'EOF'
Usage: scripts/build_release.sh [OPTIONS]

Options:
  --beta                Build as beta (pre-release). Auto-detects next beta.N from GitHub tags,
                        auto-bumps build number (timestamp), auto-cleans UpdaterDownloads cache.
  --stable              Build as stable release (default).
  --auto-release        After build+notarize, auto-create GitHub release on
                        rokartur/BetterCmdTab with DMG+ZIP attached.
                        Stable → "Latest release". Beta → pre-release.
  --notes TEXT          Release notes for --auto-release. Supports literal newlines
                        when passed as one quoted argument.
                        When omitted on an interactive terminal, the script
                        prompts per category (Highlights, Added, Changed, Fixed,
                        Security, Removed, Known issues). Empty sections are
                        skipped.
  --skip-build-bump     Skip build number timestamp bump.
                        Use when re-running after a notarization failure where the
                        bump was already committed.
  --skip-notarization   Skip notarization & stapling (for local testing).
  --clean               Wipe build/release/ (DMGs, ZIPs, archive, logs)
                        and run xcodebuild clean on DerivedData.
  -h, --help            Show this help message.

Environment:
  SIGNING_IDENTITY      Override the code signing identity.
  NOTARYTOOL_PROFILE    Override the notarytool keychain profile name.

Output:
  build/release/BetterCmdTab-<version>-<build>.dmg
  build/release/BetterCmdTab-<version>-<build>.zip
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --beta)           is_beta=1 ;;
    --stable)         is_beta=0 ;;
    --auto-release)   auto_release=1 ;;
    --notes)
      shift
      if [[ $# -eq 0 ]]; then
        echo "❌ --notes requires release notes text" >&2
        usage
        exit 64
      fi
      release_notes="$1"
      ;;
    --skip-build-bump) skip_build_bump=1 ;;
    --skip-notarization) skip_notarization=1 ;;
    --clean)          clean_build=1 ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo "❌ Unknown option: $1" >&2
      usage
      exit 64
      ;;
  esac
  shift
done

# ─── Paths ───────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/${APP_NAME}.xcodeproj"
BUILD_DIR="${REPO_ROOT}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"

# ─── Helpers ─────────────────────────────────────────────────────────────────

step() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Extract bullets (lines starting with "- ") under a given Markdown heading
# until the next heading or EOF. Accepts known synonym headings per section
# so legacy notes carry over.
extract_bullets_under_heading() {
  local heading="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0

  local prefix="${heading% *}"
  local section="${heading##* }"
  local aliases=("$section")
  case "$section" in
    Added)   aliases+=("New" "Enhancements") ;;
    Changed) aliases+=("Changes" "Improvements") ;;
    Fixed)   aliases+=("Fixes" "Bug fixes") ;;
    Removed) aliases+=("Deprecated") ;;
  esac

  local joined
  joined=$(IFS='|'; echo "${aliases[*]}")

  awk -v prefix="$prefix" -v joined="$joined" '
    BEGIN {
      n = split(joined, arr, "|")
      for (i = 1; i <= n; i++) targets[prefix " " arr[i]] = 1
    }
    $0 in targets       { in_section = 1; next }
    /^#/                { in_section = 0 }
    in_section && /^- / { print }
  ' "$file"
}

extract_highlight_line() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^## Highlights/ { in_section = 1; next }
    /^#/             { in_section = 0 }
    in_section && NF { print; exit }
  ' "$file"
}

prompt_section_oneline() {
  local section="$1"
  local heading="${2:-##}"
  local prior_text="${3:-}"
  echo "" >&2
  echo "── ${section} ──" >&2
  if [[ -n "$prior_text" ]]; then
    echo "  Carried over: ${prior_text}" >&2
    echo "  Enter replacement, or leave empty to keep carried-over." >&2
  else
    echo "  Enter one sentence. Empty input skips this section." >&2
  fi
  printf "  > " >&2
  local line
  IFS= read -r line || line=""
  if [[ -z "$line" ]]; then
    [[ -z "$prior_text" ]] && return 0
    line="$prior_text"
  fi
  printf "%s %s\n%s\n\n" "$heading" "$section" "$line"
}

prompt_section_bullets() {
  local section="$1"
  local heading="${2:-###}"
  local prior_file="${3:-}"

  local prior_bullets=()
  if [[ -n "$prior_file" && -s "$prior_file" ]]; then
    local _b
    while IFS= read -r _b; do
      [[ -n "$_b" ]] && prior_bullets+=("$_b")
    done < <(extract_bullets_under_heading "${heading} ${section}" "$prior_file")
  fi

  echo "" >&2
  echo "── ${section} ──" >&2
  if [[ ${#prior_bullets[@]} -gt 0 ]]; then
    echo "  Carried over from prior beta:" >&2
    printf "    %s\n" "${prior_bullets[@]}" >&2
    echo "  Add more bullets (blank line finishes, empty input keeps only carried-over):" >&2
  else
    echo "  Enter bullets, one per line. Blank line finishes. Leave empty to skip." >&2
  fi

  local new_bullets=()
  local line
  while :; do
    printf "  > " >&2
    IFS= read -r line || break
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^[[:space:]]*- ]] || line="- ${line}"
    new_bullets+=("$line")
  done

  local total=$(( ${#prior_bullets[@]} + ${#new_bullets[@]} ))
  [[ $total -eq 0 ]] && return 0

  printf "%s %s\n" "$heading" "$section"
  [[ ${#prior_bullets[@]} -gt 0 ]] && printf "%s\n" "${prior_bullets[@]}"
  [[ ${#new_bullets[@]}   -gt 0 ]] && printf "%s\n" "${new_bullets[@]}"
  printf "\n"
}

compose_release_notes_interactively() {
  local out_file="$1"
  local prior_file="${2:-}"
  : > "$out_file"
  echo "" >&2
  echo "📝 Compose release notes." >&2
  if [[ -n "$prior_file" && -s "$prior_file" ]]; then
    echo "   Prior notes loaded: existing bullets carry over per section." >&2
  fi

  local prior_highlight=""
  [[ -n "$prior_file" ]] && prior_highlight=$(extract_highlight_line "$prior_file")

  prompt_section_oneline "Highlights"   "##"  "$prior_highlight" >> "$out_file"
  prompt_section_bullets "Added"        "###" "$prior_file"      >> "$out_file"
  prompt_section_bullets "Changed"      "###" "$prior_file"      >> "$out_file"
  prompt_section_bullets "Fixed"        "###" "$prior_file"      >> "$out_file"
  prompt_section_bullets "Security"     "###" "$prior_file"      >> "$out_file"
  prompt_section_bullets "Removed"      "###" "$prior_file"      >> "$out_file"
  prompt_section_bullets "Known issues" "###" "$prior_file"      >> "$out_file"
}

# ─── Pre-flight checks ──────────────────────────────────────────────────────

step "Pre-flight checks"

if ! security find-identity -v -p codesigning | grep -q "${TEAM_ID}"; then
  echo "❌ Signing identity not found for team ${TEAM_ID}."
  echo "   Install a 'Developer ID Application' certificate from the Apple Developer portal."
  exit 1
fi
echo "✅ Signing identity found"

if [[ $skip_notarization -eq 0 ]]; then
  notary_check_output=$(xcrun notarytool info "00000000-0000-0000-0000-000000000000" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" 2>&1) || true

  if echo "$notary_check_output" | grep -qi "credentials\|authentication\|could not find credentials\|profile not found"; then
    echo "❌ Notarization credentials not found. Set them up with:"
    echo "   xcrun notarytool store-credentials \"${NOTARYTOOL_PROFILE}\" \\"
    echo "     --apple-id \"your@email.com\" \\"
    echo "     --team-id \"${TEAM_ID}\" \\"
    echo "     --password \"xxxx-xxxx-xxxx-xxxx\""
    exit 1
  fi
  echo "✅ Notarization credentials found"
fi

if [[ $auto_release -eq 1 ]]; then
  if ! command -v gh &>/dev/null; then
    echo "❌ gh CLI not installed. Install with: brew install gh"
    exit 1
  fi
  if ! gh auth status --hostname github.com &>/dev/null; then
    echo "❌ gh CLI not authenticated. Run: gh auth login"
    exit 1
  fi
  echo "✅ gh CLI authenticated"
fi

# ─── Step -1: Wipe build artifacts (--clean only) ───────────────────────────

if [[ $clean_build -eq 1 ]]; then
  step "Step -1: Wipe build folder"
  if [[ -d "${BUILD_DIR}" ]]; then
    echo "🧹 Removing ${BUILD_DIR}..."
    rm -rf "${BUILD_DIR:?}"
  fi
  mkdir -p "$BUILD_DIR"
  echo "✅ Build folder wiped"
fi

# ─── Step 0: Compile sanity check ───────────────────────────────────────────
#
# Compile in Release configuration with code signing disabled. Catches
# regressions before we burn an archive + notarization slot on a known-bad build.

step "Step 0: Release compile check"

mkdir -p "$BUILD_DIR"
RELEASE_LOG="${BUILD_DIR}/release_compile.log"

if command -v xcbeautify &>/dev/null; then
  xcodebuild build \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$RELEASE_LOG" | xcbeautify
  build_status=${PIPESTATUS[0]}
else
  xcodebuild build \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    > "$RELEASE_LOG" 2>&1
  build_status=$?
fi

if [[ $build_status -ne 0 ]]; then
  echo "❌ Release compile check failed. Full log: $RELEASE_LOG"
  exit 1
fi

echo "✅ Release compile check passed"

step "Step 1: Configure build type"

if [[ $is_beta -eq 1 ]]; then
  echo "🔶 Building BETA (pre-release)"
else
  echo "🟢 Building STABLE release"
fi

VERSION=$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | grep 'MARKETING_VERSION' | head -1 | awk '{print $NF}')

if [[ -z "$VERSION" ]]; then
  echo "❌ Could not determine MARKETING_VERSION from project"
  exit 1
fi

BUILD_NUMBER=$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | grep 'CURRENT_PROJECT_VERSION' | head -1 | awk '{print $NF}')

echo "   Version: ${VERSION} (build ${BUILD_NUMBER})"

# Auto-detect next beta.N from GitHub tags.
BETA_N=""
BETA_TAG=""
if [[ $is_beta -eq 1 ]]; then
  if ! command -v gh &>/dev/null; then
    echo "❌ gh CLI required for beta builds (need to query existing tags). Install: brew install gh"
    exit 1
  fi

  _beta_tags=$(gh api "repos/${RELEASE_REPO}/tags?per_page=100" \
    --jq "[.[].name | select(startswith(\"${VERSION}-beta.\"))] | join(\"\n\")" 2>/dev/null || true)
  _last_beta=$(echo "$_beta_tags" | sort -V | tail -1)

  if [[ -z "$_last_beta" ]]; then
    BETA_N=1
  else
    BETA_N=$(( ${_last_beta##*beta.} + 1 ))
  fi
  BETA_TAG="${VERSION}-beta.${BETA_N}"
  echo "   Beta tag: ${BETA_TAG} (previous: ${_last_beta:-none})"
fi

if [[ $is_beta -eq 1 ]]; then
  _artifact_version="${VERSION}-beta.${BETA_N}"
else
  _artifact_version="${VERSION}"
fi

# ─── Step 1b: Set build number (timestamp) ──────────────────────────────────
#
# Every build (beta and stable) gets a fresh timestamp-based CURRENT_PROJECT_VERSION
# so the in-app updater can detect newer builds of the same version.

_commit_ref="${BETA_TAG:-${VERSION}}"

if [[ $skip_build_bump -eq 0 ]]; then
  step "Step 1b: Set build number (timestamp)"

  NEW_BUILD_NUMBER=$(date +%Y%m%d%H%M%S)
  echo "   Build number: ${BUILD_NUMBER} → ${NEW_BUILD_NUMBER}"

  sed -i '' \
    "s/CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};/CURRENT_PROJECT_VERSION = ${NEW_BUILD_NUMBER};/g" \
    "${PROJECT_PATH}/project.pbxproj"

  _actual=$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | grep 'CURRENT_PROJECT_VERSION' | head -1 | awk '{print $NF}')
  if [[ "$_actual" != "$NEW_BUILD_NUMBER" ]]; then
    echo "❌ Build number increment verification failed (got ${_actual}, expected ${NEW_BUILD_NUMBER})"
    exit 1
  fi

  echo "✅ project.pbxproj updated"

  # Commit and push the bump before any archive work begins.
  git -C "$REPO_ROOT" add "${APP_NAME}.xcodeproj/project.pbxproj"
  git -C "$REPO_ROOT" commit -m "chore: bump build number to ${NEW_BUILD_NUMBER} for ${_commit_ref}"
  git -C "$REPO_ROOT" push origin HEAD

  echo "✅ Build number ${NEW_BUILD_NUMBER} committed and pushed"

  BUILD_NUMBER="$NEW_BUILD_NUMBER"
else
  echo "⏭️  Skipping build number bump (--skip-build-bump). Reusing ${BUILD_NUMBER}."
fi

# Artifact names include build number so the updater can detect same-version newer builds.
DMG_NAME="${APP_NAME}-${_artifact_version}-${BUILD_NUMBER}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
DMG_VOLNAME="${APP_NAME} ${_artifact_version}"
DMG_STAGE_DIR="${BUILD_DIR}/dmg-stage"
ZIP_NAME="${APP_NAME}-${_artifact_version}-${BUILD_NUMBER}.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"

# Transient zip used to ship the .app to notarytool for the first notarization round.
NOTARIZE_ZIP_NAME="${APP_NAME}-${_artifact_version}-app-notarize.zip"
NOTARIZE_ZIP_PATH="${BUILD_DIR}/${NOTARIZE_ZIP_NAME}"

# ─── Step 1c: Clean UpdaterDownloads cache (beta only) ──────────────────────

if [[ $is_beta -eq 1 ]]; then
  UPDATER_DOWNLOADS="${HOME}/Library/Application Support/${APP_NAME}/UpdaterDownloads"
  if [[ -d "$UPDATER_DOWNLOADS" ]]; then
    _stale_count=$(find "$UPDATER_DOWNLOADS" -maxdepth 1 -name "*.dmg" | wc -l | tr -d ' ')
    if [[ "$_stale_count" -gt 0 ]]; then
      echo "🧹 Removing ${_stale_count} stale DMG(s) from UpdaterDownloads..."
      find "$UPDATER_DOWNLOADS" -maxdepth 1 -name "*.dmg" -delete
      echo "✅ UpdaterDownloads cleaned"
    fi
  fi
fi

# ─── Step 2: Clean (optional) & Archive ──────────────────────────────────────

step "Step 2: Archive"

mkdir -p "$BUILD_DIR"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
rm -f "$ZIP_PATH"

build_cmd=(
  xcodebuild archive
  -allowProvisioningUpdates
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration Release
  -destination "platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM="$TEAM_ID"
  OTHER_CODE_SIGN_FLAGS="--timestamp"
)

if [[ $clean_build -eq 1 ]]; then
  echo "🧹 Cleaning build folder..."
  xcodebuild clean -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration Release -quiet
fi

echo "📦 Archiving..."
if command -v xcbeautify &>/dev/null; then
  "${build_cmd[@]}" 2>&1 | xcbeautify
else
  "${build_cmd[@]}"
fi

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "❌ Archive failed — .xcarchive not found"
  exit 1
fi

ARCHIVE_INFO_PLIST="${ARCHIVE_PATH}/Info.plist"
ARCHIVED_APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"

if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
  echo "❌ Archive failed — ${APP_NAME}.app not found in archive products"
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Print :ApplicationProperties:ApplicationPath" "$ARCHIVE_INFO_PLIST" >/dev/null 2>&1; then
  echo "❌ Archive is missing ApplicationProperties in ${ARCHIVE_INFO_PLIST}"
  echo "   Xcode will refuse exportArchive when the archive is not recognized as a proper macOS app archive."
  exit 1
fi

echo "✅ Archive created: ${ARCHIVE_PATH}"

# ─── Step 3: Export archive ──────────────────────────────────────────────────

step "Step 3: Export"

EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "📤 Exporting archive..."
if command -v xcbeautify &>/dev/null; then
  xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    2>&1 | xcbeautify
else
  xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
fi

APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Export failed — ${APP_NAME}.app not found in ${EXPORT_PATH}"
  exit 1
fi

echo "✅ Exported: ${APP_PATH}"

# ─── Step 4: Verify code signature ──────────────────────────────────────────

step "Step 4: Verify code signature"

echo "🔍 Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1
echo ""

echo "🔍 Checking hardened runtime..."
codesign -d --verbose "$APP_PATH" 2>&1 | grep -i "runtime"
echo ""

echo "🔍 Checking signing authority..."
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"
echo ""

codesign_info=$(codesign -dvv "$APP_PATH" 2>&1) || true
if ! echo "$codesign_info" | grep -q "TeamIdentifier=${TEAM_ID}"; then
  echo "❌ App is NOT signed by team ${TEAM_ID}"
  exit 1
fi

echo "✅ Code signature valid"

# ─── Step 5: Notarize the .app ──────────────────────────────────────────────

if [[ $skip_notarization -eq 0 ]]; then
  step "Step 5: Notarize the .app"

  rm -f "$NOTARIZE_ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP_PATH"

  echo "📡 Submitting .app for notarization..."
  echo "   This may take a few minutes..."

  xcrun notarytool submit "$NOTARIZE_ZIP_PATH" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" \
    --wait \
    2>&1 | tee "${BUILD_DIR}/notarization-app.log"

  if ! grep -q "status: Accepted" "${BUILD_DIR}/notarization-app.log"; then
    echo ""
    echo "❌ App notarization failed. Check the log above."
    echo "   For detailed info, get the submission ID from the log and run:"
    echo "   xcrun notarytool log <submission-id> --keychain-profile ${NOTARYTOOL_PROFILE}"
    exit 1
  fi

  echo "✅ App notarization accepted"

  # ─── Step 6: Staple the .app ─────────────────────────────────────────────

  step "Step 6: Staple notarization ticket to .app"

  echo "📎 Stapling ticket to app..."
  xcrun stapler staple "$APP_PATH"

  echo "🔍 Verifying staple..."
  xcrun stapler validate "$APP_PATH"

  echo "✅ App ticket stapled"
else
  echo ""
  echo "⏭️  Skipping app notarization (--skip-notarization)"
fi

# ─── Step 7: Build ZIP ──────────────────────────────────────────────────────

step "Step 7: Build ZIP"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
echo "✅ Created: ${ZIP_PATH} (${ZIP_SIZE})"

# ─── Step 8: Build DMG ──────────────────────────────────────────────────────

step "Step 8: Build DMG"

rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"

ditto "$APP_PATH" "${DMG_STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE_DIR}/Applications"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$DMG_VOLNAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH" >/dev/null

DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo "✅ Created: ${DMG_PATH} (${DMG_SIZE})"

# ─── Step 9: Sign DMG ───────────────────────────────────────────────────────

step "Step 9: Sign DMG"

codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "✅ DMG signed"

# ─── Step 10: Notarize DMG ─────────────────────────────────────────────────

if [[ $skip_notarization -eq 0 ]]; then
  step "Step 10: Notarize DMG"

  echo "📡 Submitting DMG for notarization..."
  echo "   This may take a few minutes..."

  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" \
    --wait \
    2>&1 | tee "${BUILD_DIR}/notarization-dmg.log"

  if ! grep -q "status: Accepted" "${BUILD_DIR}/notarization-dmg.log"; then
    echo ""
    echo "❌ DMG notarization failed. Check the log above."
    exit 1
  fi

  echo "✅ DMG notarization accepted"

  step "Step 11: Staple notarization ticket to DMG"

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "✅ DMG ticket stapled"
else
  echo ""
  echo "⏭️  Skipping DMG notarization (--skip-notarization)"
fi

# ─── Step 12: Create GitHub release (--auto-release only) ──────────────────

if [[ $auto_release -eq 1 ]]; then
  step "Step 12: Create GitHub release"

  if [[ $skip_notarization -eq 1 ]]; then
    echo "⚠️  Refusing to publish a release built with --skip-notarization."
    exit 1
  fi

  if [[ $is_beta -eq 1 ]]; then
    RELEASE_TAG="${BETA_TAG}"
    RELEASE_TITLE="${APP_NAME} ${VERSION}-beta.${BETA_N}"
  else
    RELEASE_TAG="v${VERSION}"
    RELEASE_TITLE="${APP_NAME} ${VERSION}"
  fi

  echo "📡 Publishing ${RELEASE_TAG} on ${RELEASE_REPO}..."

  RELEASE_NOTES_FILE="${BUILD_DIR}/release-notes-${RELEASE_TAG}.md"

  # Carry-over rule: if the newest GitHub release is a pre-release, treat it
  # as an in-progress notes draft and prefill from it.
  PRIOR_NOTES_FILE=""
  _newest_release_json=$(gh release list --repo "${RELEASE_REPO}" --limit 1 \
    --json tagName,isPrerelease 2>/dev/null || echo "[]")
  _newest_tag=$(echo "$_newest_release_json" | jq -r '.[0].tagName // empty')
  _newest_pre=$(echo "$_newest_release_json" | jq -r '.[0].isPrerelease // false')

  if [[ -z "$_newest_tag" ]]; then
    echo "ℹ️  No prior releases found — starting from clean notes."
  elif [[ "$_newest_pre" == "true" ]]; then
    _candidate="${BUILD_DIR}/prior-notes-${_newest_tag}.md"
    if gh release view "$_newest_tag" --repo "${RELEASE_REPO}" --json body --jq '.body' 2>/dev/null \
        | tr -d '\r' > "$_candidate" && [[ -s "$_candidate" ]]; then
      PRIOR_NOTES_FILE="$_candidate"
      echo "📥 Loaded notes from prior pre-release: ${_newest_tag}"
    else
      rm -f "$_candidate"
    fi
  else
    echo "ℹ️  Latest release (${_newest_tag}) is stable — starting from clean notes."
  fi

  if [[ -n "$release_notes" ]]; then
    printf "%s\n" "$release_notes" > "$RELEASE_NOTES_FILE"
  elif [[ -t 0 ]]; then
    compose_release_notes_interactively "$RELEASE_NOTES_FILE" "$PRIOR_NOTES_FILE"
    if [[ ! -s "$RELEASE_NOTES_FILE" ]]; then
      echo "" >&2
      echo "⚠️  No sections filled in. Falling back to default notes." >&2
      if [[ $is_beta -eq 1 ]]; then
        printf "Beta %s of %s %s.\n" "$BETA_N" "$APP_NAME" "$VERSION" > "$RELEASE_NOTES_FILE"
      else
        printf "%s %s.\n" "$APP_NAME" "$VERSION" > "$RELEASE_NOTES_FILE"
      fi
    fi
    echo ""
    echo "──── Final release notes ────"
    cat "$RELEASE_NOTES_FILE"
    echo "──────────────────────────────"
    printf "Publish with these notes? [y/N] " >&2
    read -r _confirm
    if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then
      echo "❌ Aborted by user. Notes saved to: ${RELEASE_NOTES_FILE}" >&2
      echo "   Re-run with --notes \"\$(cat ${RELEASE_NOTES_FILE})\" to publish without prompts." >&2
      exit 1
    fi
  else
    if [[ $is_beta -eq 1 ]]; then
      printf "Beta %s of %s %s.\n" "$BETA_N" "$APP_NAME" "$VERSION" > "$RELEASE_NOTES_FILE"
    else
      printf "%s %s.\n" "$APP_NAME" "$VERSION" > "$RELEASE_NOTES_FILE"
    fi
  fi

  release_args=(
    "${RELEASE_TAG}"
    --repo "${RELEASE_REPO}"
    --title "${RELEASE_TITLE}"
    --notes-file "$RELEASE_NOTES_FILE"
  )
  if [[ $is_beta -eq 1 ]]; then
    release_args+=(--prerelease --latest=false)
  else
    release_args+=(--latest)
  fi
  release_args+=("${DMG_PATH}#${DMG_NAME}" "${ZIP_PATH}#${ZIP_NAME}")

  gh release create "${release_args[@]}"

  echo "✅ Release published: https://github.com/${RELEASE_REPO}/releases/tag/${RELEASE_TAG}"
  echo "   Notes archived at: ${RELEASE_NOTES_FILE}"
fi

# Cleanup transient artifacts.
rm -rf "$DMG_STAGE_DIR"
rm -f "$NOTARIZE_ZIP_PATH"

# ─── Final verification ─────────────────────────────────────────────────────

step "Final verification"

echo "🔍 Gatekeeper assessment of .app..."
spctl --assess --type execute --verbose "$APP_PATH" 2>&1 || true

echo ""
echo "🔍 Gatekeeper assessment of DMG..."
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" 2>&1 || true

echo ""
echo "🔍 Notarization check..."
spctl --assess --verbose=4 --type execute "$APP_PATH" 2>&1 || true

# ─── Done ────────────────────────────────────────────────────────────────────

step "✅ Build complete!"

build_type="STABLE"
[[ $is_beta -eq 1 ]] && build_type="BETA"

echo ""
echo "  Type:     ${build_type}"
echo "  Version:  ${VERSION} (${BUILD_NUMBER})"
echo "  DMG:      ${DMG_PATH} (${DMG_SIZE})"
echo "  ZIP:      ${ZIP_PATH} (${ZIP_SIZE})"
echo ""
echo "  Next steps:"
if [[ $auto_release -eq 1 ]]; then
  echo "  ✅ Release ${RELEASE_TAG} already published."
  echo "     https://github.com/${RELEASE_REPO}/releases/tag/${RELEASE_TAG}"
else
  if [[ $is_beta -eq 1 ]]; then
    _tag="${BETA_TAG}"
    _title="${APP_NAME} ${VERSION}-beta.${BETA_N}"
    _notes="Beta ${BETA_N} of ${APP_NAME} ${VERSION}."
    _flags="--prerelease --latest=false"
  else
    _tag="v${VERSION}"
    _title="${APP_NAME} ${VERSION}"
    _notes="${APP_NAME} ${VERSION}."
    _flags="--latest"
  fi
  echo "  Run this to publish the release:"
  echo ""
  echo "    gh release create ${_tag} \\"
  echo "      --repo ${RELEASE_REPO} \\"
  echo "      --title \"${_title}\" \\"
  echo "      --notes \"${_notes}\" \\"
  echo "      ${_flags} \\"
  echo "      \"${DMG_PATH}#${DMG_NAME}\" \\"
  echo "      \"${ZIP_PATH}#${ZIP_NAME}\""
  echo ""
  echo "  Or re-run with --auto-release next time."
fi
echo ""
