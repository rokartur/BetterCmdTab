#!/usr/bin/env bash
# Usage: assert_tests_ran.sh <result-bundle.xcresult> [minimum-test-count]
# xcodebuild reports success when a selector matches no test; this turns that into a failure.
set -euo pipefail

usage="usage: assert_tests_ran.sh <result-bundle.xcresult> [minimum-test-count]"
bundle="${1:?$usage}"
# The full-suite floor, kept below the suite size.
minimum="${2:-300}"
# A non-numeric minimum would evaluate as 0 in (( )) and pass any run.
[[ "$minimum" =~ ^[0-9]+$ ]] || { echo "[assert-tests-ran] minimum '$minimum' is not a number" >&2; exit 64; }
ran=$(xcrun xcresulttool get test-results summary --path "$bundle" | jq -r '.passedTests')

if [[ ! "$ran" =~ ^[0-9]+$ ]] || (( ran < minimum )); then
  echo "[assert-tests-ran] $bundle passed '$ran' tests, expected at least $minimum" >&2
  exit 1
fi
echo "[assert-tests-ran] $ran tests passed (minimum $minimum)"
