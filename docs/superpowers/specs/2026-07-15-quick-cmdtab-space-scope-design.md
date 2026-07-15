# Quick Cmd-Tab Space Scope Design

## Goal

Make quick Cmd-Tab honor the same "Show windows from" scope as the held
switcher overlay.

## Current behavior

Quick Cmd-Tab selects from a most-recently-used app list. That list has no
window or Space membership, so an app used on another Space can be selected.
The held overlay instead derives its rows from the scope-filtered window list.

## Design

Keep the key-down path unchanged. At selection time, derive the eligible app
IDs from the existing scope-filtered catalog rows, then map the MRU app
sequence and step count onto only those eligible apps.

Use the same mapping when the held overlay determines its initial selection.
Consequently quick and held Cmd-Tab use the same app candidates for all window
scope settings. Windowless rows remain eligible because the existing scope
filter intentionally retains them; a quick switch activates the same row as
the held overlay (and can open a new window), rather than silently diverging.

## Constraints

- Do not add Space-resolution work to the Cmd-Tab key-down path.
- Preserve the current all-Spaces behavior.
- Do not activate an app that has no eligible scoped row under the selected scope.
- Keep the change limited to the switcher selection flow.

## Verification

Per request, do not add an automated regression test. Build the Debug scheme
unsigned and manually verify quick and held Cmd-Tab against windows on two
Spaces.
