# Quick Cmd-Tab Space Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make quick Cmd-Tab select from the same Space-scoped app candidates as the held switcher overlay.

**Architecture:** Keep key-down app priming unchanged. When rows have been filtered for the active Space scope, derive eligible app process IDs from those rows and remap the accumulated Cmd-Tab step count onto that eligible app sequence. Use the same remapping for overlay highlighting and quick-release activation.

**Tech Stack:** Swift 5, AppKit, Swift Testing (no new test requested), Xcode 26.2.

## Global Constraints

- Keep work off the Cmd-Tab key-down hot path.
- Preserve all-Spaces behavior.
- Keep the change limited to `SwitcherController`.
- Do not add an automated regression test, at the user's request.
- Build locally with `CODE_SIGNING_ALLOWED=NO`.

---

### Task 1: Reconcile primed app selection with filtered window rows

**Files:**
- Modify: `BetterCmdTab/Switcher/SwitcherController.swift`

**Interfaces:**
- Consumes: `primedApps`, `primedStepDelta`, `effective.sortOrder`, and the already scope-filtered `SwitcherRow` list.
- Produces: one selected app PID only when that app has an eligible scoped row.

- [x] **Step 1: Add a focused selection helper**

Add a private helper that receives filtered rows, extracts their process IDs,
filters `primedApps` to those IDs, and calculates the selected app using the
existing `primedStartIndex(count:step:anchor:)` logic. For non-default sort
orders, find the frontmost app again within the filtered sequence before
supplying the anchor.

- [x] **Step 2: Use the helper to seed held-mode selection**

After `reveal()` constructs `cachedRows`, use the helper's selected PID rather
than the pre-filtered `primedApps[primedIndex]` PID when choosing `index`.
The visible overlay must highlight an app that exists in `rows`.

- [x] **Step 3: Use the helper for quick-release activation**

In `commit()`'s app-switching primed branch, create the existing filtered row
snapshot once, resolve the selected eligible app, and activate that app's
representative filtered window. If no eligible app exists under a narrowed
Space scope, do not call `Activator.activateApp` for an out-of-scope app.

- [x] **Step 4: Build unsigned**

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -scheme 'BetterCmdTab Debug' -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manually verify both modes**

Run the Debug app with the release app quit. Put one recently used app window
on Space A and several windows on Space B, set Show windows from to Current
Space, and then test from Space B:

1. Tap Cmd-Tab: it must not activate the app that has windows only on Space A.
2. Hold Cmd-Tab: the overlay must exclude that app and initially highlight the
   same eligible app as quick mode.
3. Switch Show windows from to All Spaces: quick Cmd-Tab must retain its prior
   cross-Space MRU behavior.

- [x] **Step 6: Commit the implementation**

```sh
git add BetterCmdTab/Switcher/SwitcherController.swift \
  docs/superpowers/specs/2026-07-15-quick-cmdtab-space-scope-design.md \
  docs/superpowers/plans/2026-07-15-quick-cmdtab-space-scope.md
git commit -m 'fix: scope quick Cmd-Tab to eligible windows'
```
