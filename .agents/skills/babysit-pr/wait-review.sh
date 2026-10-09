#!/usr/bin/env bash
# Usage: wait-review.sh <pr>. Prints rokartur-review's verdict on the PR's head commit.
# Exits 1 when the bot drops the review request without reviewing that commit (its run failed).
set -euo pipefail

pr=$1
while true; do
	# One call: the bot submits its review, then removes its own request.
	verdict=$(gh pr view "$pr" --json headRefOid,reviews,reviewRequests --jq '
		.headRefOid as $head
		| ([.reviews[] | select(.author.login == "rokartur-review" and .commit.oid == $head)] | last | .state) as $state
		| if $state then "\($state) \($head)"
		elif any(.reviewRequests[]; .login == "rokartur-review") then ""
		else "FAILED \($head)" end')
	case $verdict in
	"") sleep 60 ;;
	FAILED*) echo "rokartur-review dropped the request without reviewing ${verdict#FAILED }" >&2; exit 1 ;;
	*) echo "$verdict"; exit 0 ;;
	esac
done
