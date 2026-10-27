import { H2 } from "./tokens";

// Also the page's FAQPage JSON-LD (routes/index.tsx), so the two never disagree.
export const faq: Array<[question: string, answer: string]> = [
  [
    "Is BetterCmdTab really free?",
    "Yes. Every feature is free, with no Pro tier, trial, license key or account. The source code is GPL-3.0 on GitHub. The app has no telemetry, analytics or crash reporting, and its only network requests go to GitHub to check for updates.",
  ],
  [
    "Which permissions does it need, and why?",
    "Accessibility, to take over ⌘Tab and read the list of open windows; the switcher does not start without it. Live window previews also ask for Screen Recording, and without it the tiles show app icons. Listing browser tabs needs Automation access to each browser.",
  ],
  [
    "Is it safe to install?",
    "The app is signed and notarized, so Gatekeeper opens it without a warning, and every line of its code is public on GitHub. It collects nothing about you or your windows. Window titles and previews stay on your Mac and are never sent anywhere.",
  ],
  [
    "How is it different from AltTab?",
    "Both are open-source window switchers. AltTab keeps search, extra layouts and more shortcuts behind Pro, at $9.99 or $24.99 for lifetime updates. BetterCmdTab ships all of that for free, and adds app launching, browser tab drill-in, window tiling, per-app hotkeys and force quit.",
  ],
  [
    "How is it different from the built-in ⌘Tab?",
    "The macOS ⌘Tab switches apps, not windows: two Safari windows are one entry, and minimized windows need a mouse or ⌥ to come back. BetterCmdTab lists every window, including minimized ones and those on other Spaces, adds search and previews, and keeps the same ⌘Tab muscle memory.",
  ],
  [
    "How do I install it?",
    "Run brew install --cask bettercmdtab, or download the .dmg from the GitHub releases page and drag the app into Applications. Open it, enable BetterCmdTab under System Settings, Privacy & Security, Accessibility, and press ⌘Tab. Updates install from the app itself.",
  ],
  [
    "How do I get the native ⌘Tab back?",
    "Choose Quit BetterCmdTab from its menu-bar icon, and the native ⌘Tab works again at once. To uninstall, quit it first, then move it to the Trash or run brew uninstall --cask bettercmdtab. A force-killed app leaves ⌘Tab off until BetterCmdTab launches again.",
  ],
  [
    "Which Macs does it run on?",
    "Any Mac with macOS 13 Ventura or later, on Apple Silicon or Intel. On macOS 26 the panel uses Liquid Glass, and on macOS 13 to 15 it falls back to the standard blurred material. A few features need newer systems, such as hiding from screen sharing on 14.6.",
  ],
];

export function Faq() {
  return (
    <section id="faq">
      <h2 className={H2}>Questions.</h2>
      <div className="border-t border-line">
        {faq.map(([question, answer]) => (
          <details key={question} className="group border-b border-line">
            <summary className="flex cursor-pointer list-none items-center justify-between gap-6 py-5 text-[17px] font-medium [&::-webkit-details-marker]:hidden">
              {question}
              <span
                aria-hidden="true"
                className="text-[22px] leading-none font-normal text-muted transition-transform duration-200 group-open:rotate-45 motion-reduce:transition-none"
              >
                +
              </span>
            </summary>
            <p className="m-0 max-w-[68ch] pb-6 text-[15px] leading-[1.55] text-muted">{answer}</p>
          </details>
        ))}
      </div>
    </section>
  );
}
