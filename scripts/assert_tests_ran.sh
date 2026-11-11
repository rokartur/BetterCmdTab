#!/usr/bin/env bash
# Usage: assert_tests_ran.sh <result-bundle.xcresult> <minimum-test-count>
# xcodebuild reports success when a selector matches no test; this turns that into a failure.
set -euo pipefail

bundle="$1"
minimum="$2"
ran=$(xcrun xcresulttool get test-results summary --path "$bundle" | jq -r '.totalTestCount')

if [[ ! "$ran" =~ ^[0-9]+$ ]] || (( ran < minimum )); then
  echo "[assert-tests-ran] $bundle ran '$ran' tests, expected at least $minimum" >&2
  exit 1
fi
echo "[assert-tests-ran] $ran tests ran (minimum $minimum)"
