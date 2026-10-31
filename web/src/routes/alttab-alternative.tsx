import { createFileRoute } from "@tanstack/react-router";

import { Article, articleHead } from "../sections/Article";
import { BREW } from "../sections/Download";

export const Route = createFileRoute("/alttab-alternative")({
  head: () =>
    articleHead({
      path: "/alttab-alternative/",
      title: "Free AltTab Alternative for Mac · BetterCmdTab",
      description:
        "BetterCmdTab is a free, open-source AltTab alternative for macOS: search, every layout and extra shortcuts without a Pro license, plus app launching.",
    }),
  component: AltTabAlternative,
});

// Feature, then BetterCmdTab, AltTab free, AltTab Pro.
const rows = [
  ["Switch windows with live previews", "Yes", "Yes", "Yes"],
  ["Type to search", "Yes", "No", "Yes"],
  ["App icon grid and title list layouts", "Yes", "No", "Yes"],
  ["More than one shortcut", "Yes", "No", "Yes, up to 9"],
  ["Cycle the front app's windows", "Yes, ⌘`", "No", "Yes"],
  ["Launch any installed app", "Yes", "No", "No"],
  ["Pick a single browser tab", "Yes", "No", "No"],
  ["Window tiling, move to another display", "Yes", "No", "No"],
  ["Force quit, reopen recently closed apps", "Yes", "No", "No"],
  ["Price", "Free", "Free", "$9.99 or $24.99"],
];

function AltTabAlternative() {
  return (
    <Article
      title="A free AltTab alternative for macOS"
      lead="AltTab brought Windows-style window switching to the Mac, and it is still a good app. BetterCmdTab covers the same ground and includes the features AltTab sells as Pro, at no cost."
    >
      <h2>What you get without paying</h2>
      <p>
        AltTab is free and open source, but search, the icon and title layouts, auto-sizing and more
        than one shortcut need AltTab Pro: $9.99 one-time for the current major version, or $24.99
        for Pro Lifetime. In BetterCmdTab every feature is free, with no trial, license key or
        account.
      </p>
      <table>
        <thead>
          <tr>
            <th scope="col">Feature</th>
            <th scope="col">BetterCmdTab</th>
            <th scope="col">AltTab free</th>
            <th scope="col">AltTab Pro</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(([feature, ...cells]) => (
            <tr key={feature}>
              <td>{feature}</td>
              {cells.map((cell, i) => (
                <td key={i}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <p>
        Checked October 2026 against <a href="https://alt-tab.app/pricing">alt-tab.app/pricing</a>.
        The <a href="/#compare">full comparison</a> also covers the built-in ⌘Tab.
      </p>

      <h2>Switching from AltTab</h2>
      <ol>
        <li>
          Install BetterCmdTab with <code>{BREW}</code>, or download the .dmg and drag it into
          Applications.
        </li>
        <li>
          Open it and enable it under System Settings, Privacy &amp; Security, Accessibility. Live
          previews also ask for Screen Recording, the same permission AltTab uses for thumbnails.
        </li>
        <li>
          Press ⌘Tab. AltTab listens on ⌥Tab by default, so both can run side by side while you
          compare them.
        </li>
        <li>
          When you are done, quit AltTab and remove it from System Settings, General, Login Items.
        </li>
      </ol>
      <p>
        Settings live in a JSON file as well as in the app, so a setup can be versioned and moved
        between Macs; only the recorded shortcut keys and a custom sound stay out. The{" "}
        <a href="/docs/config-reference/">config reference</a> lists every option.
      </p>

      <h2>When AltTab is the better pick</h2>
      <ul>
        <li>
          You want the app in your language. AltTab is translated into far more languages;
          BetterCmdTab ships in English, German, Spanish, French, Japanese, Polish, Russian and
          Simplified Chinese.
        </li>
        <li>
          You value a long track record. AltTab has around 16,000 GitHub stars and millions of
          downloads; BetterCmdTab is younger.
        </li>
      </ul>
    </Article>
  );
}
