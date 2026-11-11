#!/usr/bin/env bash
#
# release_quality_gate.sh — Pre-archive gate run by build_release.sh (Step 0).
#
# Compiles the app in Release configuration with code signing disabled and
# fails on high-risk concurrency / Sendable / UnsafeMutableRawPointer warnings
# so a known-bad build never burns an archive + notarization slot. Then runs
# the unit suite. Stable builds include the localization audit
# (LocalizationCatalogTests pins catalog coverage, format-specifier parity,
# and shape for every locale); beta builds skip it with --skip-i18n.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release_quality_gate.sh [--clean] [--fail-on-high-risk-warnings] [--skip-i18n] [--log-path <path>]

Options:
  --clean                         Run clean build before build.
  --fail-on-high-risk-warnings    Exit with non-zero status when high-risk warnings are found.
  --skip-i18n                     Run the unit suite without the localization audit (beta builds with incomplete translations).
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

tests_log="${log_path%.log}-tests.log"
tests_bundle="${log_path%.log}-tests.xcresult"
test_cmd=(xcodebuild -project "$project_path" -scheme "BetterCmdTab Debug"
  -destination "platform=macOS" -resultBundlePath "$tests_bundle" test)
# Floors sit below the suite size; .github/workflows/ci-app.yml holds the other copy of 300.
minimum_tests=300
if [[ $skip_i18n -eq 1 ]]; then
  echo "[release-quality-gate] Running unit tests without the localization audit (--skip-i18n)"
  test_cmd+=(-skip-testing:BetterCmdTabTests/LocalizationCatalogTests)
  minimum_tests=250
else
  echo "[release-quality-gate] Running unit tests"
fi
# xcodebuild refuses an existing result bundle path.
rm -rf -- "$tests_bundle"
if ! "${test_cmd[@]}" >"$tests_log" 2>&1; then
  echo "[release-quality-gate] Unit tests failed. Log: $tests_log" >&2
  tail -n 40 "$tests_log" >&2 || true
  exit 1
fi
"$repo_root/scripts/assert_tests_ran.sh" "$tests_bundle" "$minimum_tests"

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

# Tally the high-risk warnings, most frequent first. Both summaries are the same
# count-and-sort over a different key: "category" buckets by what the warning is
# about, "file" by where it fired.
summarize_high_risk() {
  if [[ "$high_risk_count" -eq 0 ]]; then
    echo "0"
    return
  fi
  printf '%s\n' "$high_risk_lines" | awk -v mode="$1" '
    {
      if (mode == "category") {
        if ($0 ~ /main actor-isolated/) {
          key = "MainActor"
        } else if ($0 ~ /concurrently-executing/) {
          key = "ConcurrentExecution"
        } else if ($0 ~ /UnsafeMutableRawPointer/) {
          key = "UnsafeMutableRawPointer"
        } else if ($0 ~ /Sendable/) {
          key = "Sendable"
        } else {
          key = "Other"
        }
      } else {
        key = $0
        sub(/^[0-9]+:/, "", key)
        sub(/:[0-9]+:[0-9]+: warning:.*/, "", key)
      }
      if (key != "") {
        counts[key]++
      }
    }
    END {
      for (key in counts) {
        printf("%d\t%s\n", counts[key], key)
      }
    }
  ' | sort -nr
}

echo "[release-quality-gate] High-risk summary by category:"
summarize_high_risk category

echo "[release-quality-gate] High-risk summary by file:"
summarize_high_risk file

if [[ "$fail_on_high_risk" -eq 1 && "$high_risk_count" -gt 0 ]]; then
  echo "[release-quality-gate] Failing because high-risk warnings were found." >&2
  exit 2
fi

echo "[release-quality-gate] Passed."
