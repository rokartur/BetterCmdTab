#!/usr/bin/env bash
#
# release_quality_gate.sh — Pre-archive gate run by build_release.sh (Step 0).
#
# Compiles the app in Release configuration with code signing disabled and
# fails on high-risk concurrency / Sendable / UnsafeMutableRawPointer warnings
# so a known-bad build never burns an archive + notarization slot. Stable
# builds also run the localization audit (LocalizationCatalogTests pins
# catalog coverage, format-specifier parity, and shape for every locale);
# beta builds skip it with --skip-i18n.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release_quality_gate.sh [--clean] [--fail-on-high-risk-warnings] [--skip-i18n] [--log-path <path>]

Options:
  --clean                         Run clean build before build.
  --fail-on-high-risk-warnings    Exit with non-zero status when high-risk warnings are found.
  --skip-i18n                     Skip the localization audit (beta builds with incomplete translations).
  --log-path <path>               Path for raw xcodebuild log output.
EOF
}

clean_build=0
fail_on_high_risk=0
skip_i18n=0
log_path="${TMPDIR:-/tmp}/bettercmdtab_release_quality_gate.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      clean_build=1
      ;;
    --fail-on-high-risk-warnings)
      fail_on_high_risk=1
      ;;
    --skip-i18n)
      skip_i18n=1
      ;;
    --log-path)
      shift
      if [[ $# -eq 0 ]]; then
        echo "[release-quality-gate] Missing value for --log-path" >&2
        usage
        exit 64
      fi
      log_path="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-quality-gate] Unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$repo_root/BetterCmdTab.xcodeproj"

build_cmd=(
  xcodebuild
  -project "$project_path"
  -scheme "BetterCmdTab"
  -configuration Release
  -destination "platform=macOS"
  CODE_SIGNING_ALLOWED=NO
)

if [[ "$clean_build" -eq 1 ]]; then
  build_cmd+=(clean)
fi
build_cmd+=(build)

echo "[release-quality-gate] Running: ${build_cmd[*]}"
if ! "${build_cmd[@]}" >"$log_path" 2>&1; then
  echo "[release-quality-gate] Build failed. Log: $log_path" >&2
  tail -n 60 "$log_path" >&2 || true
  exit 1
fi

if [[ $skip_i18n -eq 1 ]]; then
  echo "[release-quality-gate] Skipping localization audit (--skip-i18n)"
else
  echo "[release-quality-gate] Running localization audit (LocalizationCatalogTests)"
  i18n_log="${log_path%.log}-i18n.log"
  if ! xcodebuild \
    -project "$project_path" \
    -scheme "BetterCmdTab Debug" \
    -destination "platform=macOS" \
    test -only-testing:BetterCmdTabTests/LocalizationCatalogTests \
    >"$i18n_log" 2>&1; then
    echo "[release-quality-gate] Localization audit failed. Log: $i18n_log" >&2
    tail -n 40 "$i18n_log" >&2 || true
    exit 1
  fi
fi

total_warnings="$( (grep -c "warning:" "$log_path" || true) | tr -d ' ')"
high_risk_pattern='warning:.*(main actor-isolated|Sendable|concurrently-executing|UnsafeMutableRawPointer)'
high_risk_lines="$(grep -En "$high_risk_pattern" "$log_path" || true)"

if [[ -n "$high_risk_lines" ]]; then
  high_risk_count="$(printf '%s\n' "$high_risk_lines" | wc -l | tr -d ' ')"
else
  high_risk_count=0
fi

echo "[release-quality-gate] Log: $log_path"
echo "[release-quality-gate] Total warnings: $total_warnings"
echo "[release-quality-gate] High-risk warnings: $high_risk_count"

echo "[release-quality-gate] High-risk summary by category:"
if [[ "$high_risk_count" -gt 0 ]]; then
  printf '%s\n' "$high_risk_lines" | awk '
    {
      msg = $0
      if (msg ~ /main actor-isolated/) {
        cat = "MainActor"
      } else if (msg ~ /concurrently-executing/) {
        cat = "ConcurrentExecution"
      } else if (msg ~ /UnsafeMutableRawPointer/) {
        cat = "UnsafeMutableRawPointer"
      } else if (msg ~ /Sendable/) {
        cat = "Sendable"
      } else {
        cat = "Other"
      }
      counts[cat]++
    }
    END {
      for (cat in counts) {
        printf("%d\t%s\n", counts[cat], cat)
      }
    }
  ' | sort -nr
else
  echo "0"
fi

echo "[release-quality-gate] High-risk summary by file:"
if [[ "$high_risk_count" -gt 0 ]]; then
  printf '%s\n' "$high_risk_lines" | awk '
    {
      file = $0
      sub(/^[0-9]+:/, "", file)
      sub(/:[0-9]+:[0-9]+: warning:.*/, "", file)
      if (file != "") {
        counts[file]++
      }
    }
    END {
      for (file in counts) {
        printf("%d\t%s\n", counts[file], file)
      }
    }
  ' | sort -nr
else
  echo "0"
fi

if [[ "$fail_on_high_risk" -eq 1 && "$high_risk_count" -gt 0 ]]; then
  echo "[release-quality-gate] Failing because high-risk warnings were found." >&2
  exit 2
fi

echo "[release-quality-gate] Passed."
