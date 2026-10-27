import { createFileRoute } from "@tanstack/react-router";

import { Article, articleHead } from "../sections/Article";
import { BREW } from "../sections/Download";

export const Route = createFileRoute("/cmd-tab-mac")({
  head: () =>
    articleHead({
      path: "/cmd-tab-mac/",
      title: "How Cmd+Tab Works on Mac · BetterCmdTab",
      description:
        "The built-in Command-Tab shortcuts on macOS, where the app switcher falls short, and how to switch between windows instead of apps.",
    }),
  component: CmdTabMac,
});

const shortcuts = [
  ["⌘Tab", "Switch to the app you used last. Keep ⌘ held and press Tab again to go further."],
  ["⌘⇧Tab", "Move backward through the open switcher."],
  ["⌘`", "Switch between the windows of the front app. Add ⇧ to go backward."],
  ["⌘Q or ⌘H in the switcher", "Quit or hide the highlighted app without leaving the switcher."],
  [
    "↑ or ↓ in the switcher",
    "Show every window of the highlighted app, then pick one with the arrows.",
  ],
  ["⌃↑", "Mission Control: all windows of all apps on the current Space."],
  ["⌃↓", "App Exposé: all windows of the front app."],
];

function CmdTabMac() {
  return (
    <Article
      title="How ⌘Tab works on a Mac, and how to switch windows"
      lead="Command-Tab is the fastest way to move between apps on macOS. It switches apps, not windows, and a few extra keys close most of that gap."
    >
      <h2>The built-in shortcuts</h2>
      <table>
        <thead>
          <tr>
            <th scope="col">Keys</th>
            <th scope="col">What it does</th>
          </tr>
        </thead>
        <tbody>
          {shortcuts.map(([keys, action]) => (
            <tr key={keys}>
              <td>{keys}</td>
              <td>{action}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2>Where the built-in ⌘Tab falls short</h2>
      <ul>
        <li>
          It lists apps, not windows. Two Safari windows are one entry, and you reach the second
          with ⌘` after you switch.
        </li>
        <li>
          Minimized windows stay in the Dock. Switching to their app restores none of them unless
          you press ⌥ before you release ⌘.
        </li>
        <li>There is no search: with twenty apps open you press Tab until you get there.</li>
        <li>It shows only icons, with no window titles or previews to tell windows apart.</li>
      </ul>

      <h2>Switch windows instead of apps</h2>
      <p>
        A window switcher replaces ⌘Tab with a list of every open window. BetterCmdTab is a free,
        open-source one: the same ⌘Tab, but each window is its own entry, minimized windows and
        other Spaces included, with live previews, search and browser tabs. A quick tap still
        switches to the last app at once, so the habit you have keeps working.
      </p>
      <ol>
        <li>
          Install it with <code>{BREW}</code>, or download the .dmg and drag it into Applications.
        </li>
        <li>Enable it under System Settings, Privacy &amp; Security, Accessibility.</li>
        <li>Hold ⌘ and press Tab.</li>
      </ol>
      <p>
        To go back to the native switcher, choose Quit BetterCmdTab from its menu-bar icon. If you
        used AltTab before, see the <a href="/alttab-alternative/">AltTab comparison</a>.
      </p>
    </Article>
  );
}
