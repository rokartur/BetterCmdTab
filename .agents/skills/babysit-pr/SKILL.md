---
name: babysit-pr
description: Babysit a BetterCmdTab pull request through rokartur-review and CI until it is ready to merge. Use when the user asks to babysit, watch, or monitor a PR.
---

# Babysit PR

`rokartur-review` is the house review bot (`~/developer/review-bot`). It reviews only on request: a review request from `rokartur` starts one run on Opus, billed to Artur's subscription, capped at 30 minutes. The bot then posts one GitHub review (`APPROVED` or `CHANGES_REQUESTED`, numbered findings inline) and drops its own request. Its next run reads the PR's conversation comments, not replies inside review threads.

Asking for babysitting authorizes commits and pushes to this PR's branch, `--force-with-lease` after a rebase. Merging and closing stay with the user.

## Loop

1. **CI.** `gh pr checks <pr> --watch`. App CI runs only when app paths change; "no checks reported" is a pass. Fix a red repo failure. Rerun a runner flake once with `gh run rerun <id> --failed`.
2. **Request.** Once CI is green on the head commit, request a review: `gh pr edit <pr> --add-reviewer rokartur-review`.
3. **Wait.** Run `.agents/skills/babysit-pr/wait-review.sh <pr>` in a background terminal (`load_tools terminals`) and poll its output. It prints the verdict on the head commit, or exits 1 when the bot's run failed: report that and stop. Put status notes in the same message as the next tool call: a message without one ends the turn and the babysitting stops.
4. **Findings.** Read the review: `gh api repos/rokartur/BetterCmdTab/pulls/<pr>/reviews` for the summary, `.../pulls/<pr>/comments` for the inline findings. Check every finding against the source. Fix the real ones in one round. Answer the rejected ones in a single PR comment, one line per finding number with the reason, so the next run sees it.
5. **Repeat** from 1 after pushing the fixes. Request the next review only after every finding of the last one is fixed or answered.

Stop when the bot's latest review is `APPROVED` on the head commit and CI is green, then report that the PR is ready.

## Rules

- Keep the PR to its original goal. Findings that ask for more go to the user as follow-ups.
- When `main` moves, rebase and rerun from 1. If an overlapping PR makes this one obsolete, stop and report it.
- Post only when something changed, and sign every comment:

  ```md
  [MODEL-SLUG] RESPONDING ON BEHALF OF ARTUR
  -----
  [actual reply]
  ```
