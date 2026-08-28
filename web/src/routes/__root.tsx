import { createRootRoute, HeadContent, Scripts } from "@tanstack/react-router";
import type { ReactNode } from "react";

import appCss from "../styles.css?url";

const SITE = "https://bettercmdtab.app";
// Title Case after the dash on purpose: Google strips a leading brand that
// duplicates the site name, so the tail has to read as a title on its own.
const TITLE = "BetterCmdTab — A Better Cmd+Tab Window Switcher for macOS";
// The <meta name="description"> variant carries the OS floor; the social cards
// drop it to stay inside the ~200-char preview budget.
const DESCRIPTION =
  "A fast, native Cmd+Tab replacement for macOS: grid & list app switcher, fuzzy search & launch, and window cycling. Free, open-source, zero telemetry. macOS 13+.";
const SOCIAL_DESCRIPTION =
  "A fast, native Cmd+Tab replacement for macOS: grid & list app switcher, fuzzy search & launch, and window cycling. Free, open-source, zero telemetry.";
const IMAGE_ALT = "BetterCmdTab — A Native Window Switcher and App Launcher for macOS";

// The homepage is the only route, so every tag below is a constant. Router
// `head()` emits raw tags, so URLs that Next used to absolutise against
// `metadataBase` (canonical, og:url, og:image) are spelled out against SITE.
const meta = [
  { charSet: "utf-8" },
  { name: "viewport", content: "width=device-width, initial-scale=1" },
  { title: TITLE },
  { name: "description", content: DESCRIPTION },
  { name: "application-name", content: "BetterCmdTab" },
  { name: "author", content: "rokartur" },
  {
    name: "keywords",
    content: [
      "macOS window switcher",
      "Cmd+Tab replacement",
      "app switcher macOS",
      "alt-tab for mac",
      "macOS app launcher",
      "AltTab alternative",
      "BetterCmdTab",
    ].join(", "),
  },
  {
    name: "robots",
    content: "index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1",
  },
  { name: "format-detection", content: "telephone=no" },
  { name: "color-scheme", content: "dark" },
  { name: "theme-color", content: "#0a0a0a" },
  { name: "mobile-web-app-capable", content: "yes" },
  // The modern spelling above is what browsers read; keep the legacy Apple
  // one for older iOS Safari.
  { name: "apple-mobile-web-app-capable", content: "yes" },
  { name: "apple-mobile-web-app-title", content: "BetterCmdTab" },
  { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" },
  { property: "og:type", content: "website" },
  { property: "og:site_name", content: "BetterCmdTab" },
  { property: "og:title", content: TITLE },
  { property: "og:description", content: SOCIAL_DESCRIPTION },
  { property: "og:url", content: `${SITE}/` },
  { property: "og:locale", content: "en_US" },
  { property: "og:image", content: `${SITE}/og.jpeg` },
  { property: "og:image:secure_url", content: `${SITE}/og.jpeg` },
  { property: "og:image:type", content: "image/jpeg" },
  { property: "og:image:width", content: "1200" },
  { property: "og:image:height", content: "630" },
  { property: "og:image:alt", content: IMAGE_ALT },
  { name: "twitter:card", content: "summary_large_image" },
  { name: "twitter:title", content: TITLE },
  { name: "twitter:description", content: SOCIAL_DESCRIPTION },
  { name: "twitter:image", content: `${SITE}/og.jpeg` },
  { name: "twitter:image:alt", content: IMAGE_ALT },
];

const links = [
  { rel: "stylesheet", href: appCss },
  { rel: "canonical", href: `${SITE}/` },
  { rel: "alternate", hrefLang: "en", href: `${SITE}/` },
  { rel: "alternate", hrefLang: "x-default", href: `${SITE}/` },
  { rel: "icon", href: "/favicon-32.png", type: "image/png", sizes: "32x32" },
  { rel: "icon", href: "/favicon-16.png", type: "image/png", sizes: "16x16" },
  { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
  { rel: "manifest", href: "/site.webmanifest" },
];

// Kept in sync with the on-page FAQ in app/page.tsx. Google restricted FAQ
// rich results to authoritative government and health sites in 2023, so this
// no longer buys a search result — it stays because it is the machine-readable
// form of the page for LLM and non-Google consumers. Matching the visible text
// is the honest thing to do, not a byte-for-byte contract worth bleeding over.
const jsonLd = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE}/#app`,
      name: "BetterCmdTab",
      alternateName: "Better Cmd Tab",
      description:
        "A fast, native Cmd+Tab replacement for macOS: a window switcher and app launcher with grid & list layouts, fuzzy search, window cycling, and zero telemetry.",
      // Trailing slash, matching the canonical Next emits under
      // `trailingSlash: true` and the sitemap entry — one spelling of the
      // homepage across every surface.
      url: `${SITE}/`,
      applicationCategory: "UtilitiesApplication",
      applicationSubCategory: "Window Manager",
      operatingSystem: "macOS 13.0 or later (Apple Silicon & Intel)",
      softwareRequirements: "macOS 13.0+",
      keywords:
        "macOS window switcher, Cmd+Tab replacement, app switcher, alt-tab for mac, app launcher, window manager, AltTab alternative",
      downloadUrl: "https://github.com/rokartur/BetterCmdTab/releases/latest",
      installUrl: "https://github.com/rokartur/BetterCmdTab/releases/latest",
      softwareHelp: "https://github.com/rokartur/BetterCmdTab",
      license: "https://github.com/rokartur/BetterCmdTab/blob/main/LICENSE",
      image: `${SITE}/og.jpeg`,
      screenshot: [`${SITE}/screenshots/list.jpg`, `${SITE}/screenshots/grid.jpg`],
      featureList: [
        "List, grid-of-icons, and live window-preview layouts",
        "Window titles under each icon in grid and preview",
        "Letter-prefix jump to any app",
        "Fuzzy search and launch any installed app",
        "Cycle windows of the front app with Cmd+`",
        "Scoped shortcuts — all windows, this Space, current app, or minimized",
        "Tap to switch instantly or hold to open the switcher",
        "Scroll the mouse wheel to move through apps",
        "Per-app global hotkeys to focus or launch",
        "Tab drill-in for Safari, Chrome, Arc, Finder, and Terminal",
        "Surface native and browser tabs as their own rows",
        "Window tiling to halves and corners, maximize, and center",
        "Move the highlighted window to the next display",
        "Inline quit, close, minimize, maximize, hide, and force-quit",
        "Reopen recently closed apps",
        "Pin favorites, filter the rest, and per-app Cmd+Tab rules",
        "Sort by recents, alphabetically, or launch order",
        "Unread Dock badge counts in the switcher",
        "Audio-playing app indicator",
        "Instant Spaces switching and current-Space-only filtering",
        "Cmd+Tab survives Secure Event Input in password fields",
        "Hide the switcher from screen sharing and recordings",
        "Panel theming with opacity, corner radius, and accent color",
        "Multi-monitor aware — opens under the cursor",
        "Three-finger trackpad gestures with haptics",
        "Export and import your whole setup as a .cmdtab file",
        "Menu-bar agent — no Dock icon, no Electron, zero telemetry",
      ],
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
        availability: "https://schema.org/InStock",
      },
      author: { "@id": `${SITE}/#author` },
      publisher: { "@id": `${SITE}/#author` },
      isAccessibleForFree: true,
    },
    {
      "@type": "Person",
      "@id": `${SITE}/#author`,
      name: "rokartur",
      url: "https://github.com/rokartur",
    },
    {
      "@type": "WebSite",
      "@id": `${SITE}/#website`,
      name: "BetterCmdTab",
      url: `${SITE}/`,
      inLanguage: "en",
      description: "A fast, native Cmd+Tab window switcher and app launcher for macOS.",
      publisher: { "@id": `${SITE}/#author` },
    },
    {
      "@type": "FAQPage",
      "@id": `${SITE}/#faq`,
      isPartOf: { "@id": `${SITE}/#website` },
      mainEntity: [
        {
          "@type": "Question",
          name: "Is BetterCmdTab free?",
          acceptedAnswer: {
            "@type": "Answer",
            text: "Yes. BetterCmdTab is free forever and open-source under GPL v3, with zero telemetry and no subscription.",
          },
        },
        {
          "@type": "Question",
          name: "Which macOS versions and Macs does it support?",
          acceptedAnswer: {
            "@type": "Answer",
            text: "macOS 13.0 or later, on both Apple Silicon and Intel.",
          },
        },
        {
          "@type": "Question",
          name: "How is it different from AltTab or the built-in Cmd+Tab?",
          acceptedAnswer: {
            "@type": "Answer",
            text: "All three switch what you have open; the real difference is what costs money. The built-in Cmd+Tab only cycles apps — no windows, search, or previews. AltTab is free at its core but now locks search, extra layouts, and multiple shortcuts behind a paid Pro tier. BetterCmdTab is a native AppKit menu-bar app that stays free forever and open-source with no paywall and no telemetry: list, grid, and live-preview layouts, fuzzy search that also launches any installed app, window cycling, browser-tab drill-in, and window tiling the stock switcher cannot do.",
          },
        },
        {
          "@type": "Question",
          name: "Does Cmd+Tab still work in password fields?",
          acceptedAnswer: {
            "@type": "Answer",
            text: "Yes. A Carbon survivor trigger keeps the switcher working even while a password field holds Secure Event Input.",
          },
        },
        {
          "@type": "Question",
          name: "Does it collect any data?",
          acceptedAnswer: {
            "@type": "Answer",
            text: "No. There is no telemetry, analytics, or background network. The only network call is an opt-in check for updates on GitHub Releases.",
          },
        },
      ],
    },
  ],
};

export const Route = createRootRoute({
  head: () => ({
    meta,
    links: [
      ...links,
      // LCP is the featured first screenshot, so preload it and let the <img>
      // mark itself fetchpriority=high; the rest warm up the release lookup
      // the page fires on mount.
      { rel: "preload", as: "image", href: "/screenshots/preview.jpg", fetchPriority: "high" },
      { rel: "preconnect", href: "https://api.github.com", crossOrigin: "" },
      { rel: "dns-prefetch", href: "https://api.github.com" },
      { rel: "dns-prefetch", href: "https://objects.githubusercontent.com" },
    ],
    scripts: [{ type: "application/ld+json", children: JSON.stringify(jsonLd) }],
  }),
  shellComponent: RootDocument,
  notFoundComponent: NotFound,
});

// Rendered two ways that have to agree: prerendered into out/client/404.html
// via the `/404` route (GitHub Pages serves that file for any unknown path),
// and again by the router once the SPA hydrates on that same unknown path.
export function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-[720px] flex-col justify-center gap-3 px-6">
      <p className="m-0 font-mono text-[13px] text-muted">404</p>
      <h1 className="m-0 text-[28px] leading-[1.18] font-semibold tracking-[-0.02em]">
        This page does not exist.
      </h1>
      <p className="m-0 text-[15px] text-muted">
        <a href="/">Back to BetterCmdTab</a> · <a href="/docs/">Documentation</a>
      </p>
    </main>
  );
}

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}
