---
name: release-changelog
description: Changelog generation for BetterCmdTab from a version or tag through HEAD. Use when the user requests release notes with verified GitHub issue references.
---

# Release changelog

Create end-user release notes from a base version through the latest commit.
Return Markdown unless the user names an output file.

## 1. Fix the range and format

Read `compose_release_notes_interactively` in `scripts/build_release.sh`. Its
section names, heading levels, and order are canonical. Read the
release/changelog rules in `AGENTS.md` for the audience and compare footer.

Use the requested base ref. For a stable version without a matching ref, try
its `v`-prefixed tag. If no base was given, use
`git describe --tags --abbrev=0 HEAD` and state that choice. The target is
`HEAD` unless the user supplied another commit. Resolve both endpoints with
`git rev-parse` and verify the range with `git merge-base --is-ancestor`.

**Complete when:** the exact `BASE..TARGET` range is valid and the canonical
output structure is known from the current repository files.

## 2. Build an evidence ledger

Inspect every commit with
`git log --reverse --format=fuller "$BASE..$TARGET"` and every net changed
file with `git diff --name-status "$BASE..$TARGET"`. Read patches whenever a subject
does not prove the user-visible outcome. Classify every commit as either:

- one observable user change, possibly grouped with related commits; or
- excluded because it is only `chore`, `refactor`, `build`, `test`, `ci`, or
  documentation.

Collect issue numbers from commit messages and associated pull requests. Query
pull requests with `gh pr view ... --json body,closingIssuesReferences` and
confirm candidates with `gh issue view`. A printed number must identify a
relevant issue, not merely the pull request containing the change. Append
verified issues to the matching bullet as `(#123, #456)`. Leave the suffix off
when no issue is verified.

**Complete when:** every commit and changed file is accounted for, every
included claim is supported by a diff, and every printed issue number is
verified and relevant.

## 3. Write outcome-first notes

Start directly with the canonical Highlights heading. Put its one- or
two-sentence summary on one physical line so `extract_highlight_line` can
consume it.

Emit only non-empty canonical sections, in the script's order and at its exact
heading depth. Each section item is one physical line in the form
`- User-visible outcome` so `extract_bullets_under_heading` can consume it.
Describe what users can now do, what changed for them, or what no longer
breaks. Use product language rather than commit subjects, implementation
symbols, or contributor workflow.

Use the Security section only for user-relevant security changes. Use Known
issues only for confirmed unresolved behavior in the target. Combine duplicate
outcomes and keep issue suffixes at the end of their bullets.

After a blank line, end with:

```text
**Full changelog:** https://github.com/rokartur/BetterCmdTab/compare/<BASE>...<TARGET-REF>
```

Use the intended release tag as `TARGET-REF` when the user supplied it;
otherwise use the resolved target commit SHA.

**Complete when:** the first line is the canonical Highlights heading, all
headings exactly match `build_release.sh`, empty sections are absent, every
bullet is user-facing, and the footer represents the inspected range.
