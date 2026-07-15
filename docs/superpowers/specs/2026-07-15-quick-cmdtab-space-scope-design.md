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
IDs from the existing scope-filtered window rows, then map the MRU app sequence
and step count onto only those eligible apps.

Use the same mapping when the held overlay determines its initial selection.
Consequently quick and held Cmd-Tab use the same app candidates for all window
scope settings.

## Constraints

- Do not add Space-resolution work to the Cmd-Tab key-down path.
- Preserve the current all-Spaces behavior.
- Do not activate an app that has no eligible window under the selected scope.
- Keep the change limited to the switcher selection flow.

## Tests

Add pure-logic tests for:

- Current-Space filtering skips an app used only on another Space.
- The selected app wraps across the eligible sequence.
- All-Spaces behavior retains the existing MRU sequence.
