import { createFileRoute } from "@tanstack/react-router";
import { AnimatePresence, LayoutGroup, MotionConfig, motion, useReducedMotion } from "motion/react";
import { type CSSProperties, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

export const Route = createFileRoute("/")({
  component: Home,
});

const REPO = "https://github.com/rokartur/BetterCmdTab";

const BREW = "brew install --cask bettercmdtab";

const EASE = [0.22, 1, 0.36, 1] as const;

const reveal = {
  hidden: { opacity: 0, y: 16 },
  show: { opacity: 1, y: 0, transition: { duration: 0.5, ease: EASE } },
};

const stagger = {
  hidden: {},
  show: { transition: { staggerChildren: 0.05, delayChildren: 0.04 } },
};

const inView = {
  variants: stagger,
  initial: "hidden",
  whileInView: "show",
  viewport: { once: true, margin: "-60px" },
} as const;

// Shared utility strings — the recurring "components" of the page.
const SECTION = "flex flex-col gap-3.5";

const H2 = "m-0 text-[13px] font-normal tracking-[0.04em] text-muted";

const ROW_LI = "group grid grid-cols-[168px_1fr] gap-4 max-[560px]:grid-cols-1";

const shots: Array<[string, string]> = [
  ["/screenshots/preview.jpg", "Live window previews"],
  ["/screenshots/grid.jpg", "Grid of app icons"],
  ["/screenshots/list.jpg", "Classic vertical list"],
];

const featureGroups: Array<{ label: string; rows: Array<[string, string]> }> = [
  {
    label: "Switch & launch",
    rows: [
      ["Letter-prefix jump", "type a name to jump to it"],
      ["Search & launch", "press / to fuzzy-find, or launch any installed app"],
      ["Window switching", "Cmd+` cycles windows of the front app"],
      [
        "Scoped shortcuts",
        "add as many hotkeys as you like, each opening the switcher pre-filtered (all windows, this Space, Visible Spaces, the current app, or minimized) with its own layout, sorting, filters, and colors",
      ],
      ["Tap or hold", "tap to switch instantly, hold to open the switcher"],
      [
        "Stay open",
        "optionally keep the switcher open after you release Cmd: confirm with Return or a click, dismiss with Esc",
      ],
      ["Reverse step", "hold Shift to keep stepping backwards, or turn the tap-Shift reverse off"],
      ["Scroll to switch", "spin the mouse wheel to move through apps"],
      ["Keyboard only", "optionally turn off selecting with mouse hover and mouse click"],
      ["App hotkeys", "assign a global shortcut to focus or launch a chosen app (9 slots)"],
    ],
  },
  {
    label: "Layouts & looks",
    rows: [
      ["Three layouts", "classic list, grid of icons, or live window previews"],
      ["Window titles", "show each window's title under its icon in Grid and Previews"],
      [
        "Preview titles",
        "choose how window titles align in previews and whether the selected name is bold",
      ],
      ["Liquid Glass", "system material on macOS 26"],
      [
        "Theming",
        "panel opacity, corner radius, and background material — the highlight follows your macOS accent color",
      ],
      ["Multi-monitor", "opens on the display you're actively working on"],
    ],
  },
  {
    label: "Tabs",
    rows: [
      ["Tab drill-in", "press \\ to pick a tab from Safari, Chrome, Arc, Finder, Terminal, …"],
      [
        "Tabs as rows",
        "surface each native or browser tab as its own row, with an experimental most-recently-used order and a hint when Safari/Chrome need automation permission",
      ],
    ],
  },
  {
    label: "Window actions",
    rows: [
      ["Quick actions", "quit, close, minimize, maximize, hide inline"],
      [
        "Hover actions",
        "quick-action buttons appear on hover: close, minimize, zoom, hide, quit, force-quit",
      ],
      ["Force quit", "Cmd+Option+Q SIGKILLs hung apps when graceful Quit hangs"],
      [
        "Window management",
        "tile to halves or corners, maximize, or center with Ctrl+Cmd arrows; cycle ½ → ⅔ → ⅓ widths",
      ],
      ["Move windows", "send the highlighted window to the next display"],
      ["Recently closed", "reopen an app you just quit"],
    ],
  },
  {
    label: "Filter & organize",
    rows: [
      [
        "Sort order",
        "order apps by recents, alphabetically, launch order, or most-recent windows across every app",
      ],
      ["Minimized & hidden", "include minimized windows, hidden and windowless apps"],
      ["Pin & filter", "keep favorites up top, hide the rest"],
      ["Per-app rules", "hide an app, or have it ignore Cmd+Tab always or only when fullscreen"],
    ],
  },
  {
    label: "Spaces & indicators",
    rows: [
      ["Instant Spaces", "switch Spaces with no animation"],
      [
        "Show windows from",
        "All Spaces, the current Space, or Visible Spaces — made for multiple monitors, showing what's on screen across all displays",
      ],
      ["Unread badges", "Dock badge counts, in the switcher"],
      ["Audio indicator", "flags apps playing sound"],
    ],
  },
  {
    label: "System & input",
    rows: [
      [
        "Secure-input survivor",
        "Cmd+Tab keeps working even while a password field holds Secure Event Input",
      ],
      [
        "Trackpad & haptics",
        "three-finger swipe to open the switcher or switch Spaces, with optional haptic and click feedback",
      ],
      [
        "Hide from screen sharing",
        "keep the switcher out of screen recordings and shared screens. Needs macOS 14.6+",
      ],
      ["Export & import", "back up and move your whole setup as a versioned .cmdtab file"],
      ["Configurable", "custom hotkey, size, scale, layout, grid columns, and reveal delay"],
    ],
  },
];

// Answer strings are kept byte-for-byte identical to the FAQPage JSON-LD in
// index.html — Google only grants the FAQ rich result when the on-page text
// matches the structured data, so edit both sides together.
const faqs: Array<[string, string]> = [
  [
    "Is BetterCmdTab free?",
    "Yes. BetterCmdTab is free forever and open-source under GPL v3, with zero telemetry and no subscription.",
  ],
  [
    "Which macOS versions and Macs does it support?",
    "macOS 13.0 or later, on both Apple Silicon and Intel. The Liquid Glass material lights up on macOS 26.",
  ],
  [
    "How is it different from AltTab or the built-in Cmd+Tab?",
    "All three switch what you have open; the real difference is what costs money. The built-in Cmd+Tab only cycles apps — no windows, search, or previews. AltTab is free at its core but now locks search, extra layouts, and multiple shortcuts behind a paid Pro tier. BetterCmdTab is a native AppKit menu-bar app that stays free forever and open-source with no paywall and no telemetry: list, grid, and live-preview layouts, fuzzy search that also launches any installed app, window cycling, browser-tab drill-in, and window tiling the stock switcher cannot do.",
  ],
  [
    "Does Cmd+Tab still work in password fields?",
    "Yes. A Carbon survivor trigger keeps the switcher working even while a password field holds Secure Event Input.",
  ],
  [
    "Does it collect any data?",
    "No. There is no telemetry, analytics, or background network. The only network call is an opt-in check for updates on GitHub Releases.",
  ],
];

interface GhAsset {
  name: string;
  browser_download_url: string;
  download_count: number;
}

interface GhRelease {
  tag_name: string;
  prerelease: boolean;
  assets: GhAsset[];
}

interface Channel {
  version: string | null;
  dmgUrl: string;
}

interface Releases {
  // Latest stable download (the default).
  stable: Channel;
  // Latest prerelease, only present when it is newer than `stable` — otherwise
  // null and the beta toggle stays hidden.
  beta: Channel | null;
  totalDownloads: number | null;
  ready: boolean;
}

const dmgOf = (r: GhRelease | undefined): Channel => ({
  version: r?.tag_name ?? null,
  dmgUrl:
    r?.assets.find((a) => a.name.endsWith(".dmg"))?.browser_download_url ??
    `${REPO}/releases/latest`,
});

const DOWNLOADS_KEY = "BetterCmdTab.totalDownloads";

function storedDownloads(): number | null {
  if (typeof localStorage === "undefined") return null;
  try {
    const stored = localStorage.getItem(DOWNLOADS_KEY);
    if (stored === null) return null;
    const count = Number(stored);
    return Number.isSafeInteger(count) && count >= 0 ? count : null;
  } catch {
    return null;
  }
}

function storeDownloads(count: number) {
  try {
    localStorage.setItem(DOWNLOADS_KEY, String(count));
  } catch {
    return;
  }
}

function useReleases(): Releases {
  const [rel, setRel] = useState<Releases>(() => ({
    // Keep the last known channels visible when GitHub's anonymous API limit is exhausted.
    stable: {
      version: "v26.6.1",
      dmgUrl:
        "https://github.com/rokartur/BetterCmdTab/releases/download/v26.6.1/BetterCmdTab-26.6.1-20260703123053.dmg",
    },
    beta: {
      version: "26.7-beta.2",
      dmgUrl:
        "https://github.com/rokartur/BetterCmdTab/releases/download/26.7-beta.2/BetterCmdTab-26.7-beta.2-20260718190227.dmg",
    },
    totalDownloads: storedDownloads(),
    ready: false,
  }));

  useEffect(() => {
    const ctrl = new AbortController();
    // One call to the list endpoint covers the latest stable release (default
    // download), the newest prerelease (opt-in beta channel), and the
    // cumulative download count across every release — saves round-trips.
    fetch("https://api.github.com/repos/rokartur/BetterCmdTab/releases?per_page=100", {
      headers: { Accept: "application/vnd.github+json" },
      signal: ctrl.signal,
    })
      .then((r) => (r.ok ? (r.json() as Promise<GhRelease[]>) : Promise.reject(r.status)))
      .then((releases) => {
        if (releases.length === 0) {
          setRel((p) => ({ ...p, ready: true }));
          return;
        }
        // Releases come newest-first. A beta is only worth offering when the
        // very newest release is a prerelease (i.e. ahead of stable); once
        // stable catches up, releases[0] is stable and the toggle disappears.
        const total = releases.reduce(
          (sum, r) => sum + r.assets.reduce((s, a) => s + a.download_count, 0),
          0,
        );
        storeDownloads(total);
        setRel({
          stable: dmgOf(releases.find((r) => !r.prerelease) ?? releases[0]),
          beta: releases[0].prerelease ? dmgOf(releases[0]) : null,
          totalDownloads: total,
          ready: true,
        });
      })
      .catch(() => {
        if (!ctrl.signal.aborted) setRel((p) => ({ ...p, ready: true }));
      });
    return () => ctrl.abort();
  }, []);

  return rel;
}

const ExternalLink = "a";

function Shots() {
  const [open, setOpen] = useState<number | null>(null);
  // The lightbox portals into document.body, which doesn't exist during the
  // build-time prerender. Gate it on mount so SSR stays document-free.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  useEffect(() => {
    if (open === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(null);
    };
    window.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [open]);

  const active = open === null ? null : shots[open];

  return (
    <>
      <motion.section className="grid grid-cols-2 gap-4 max-[560px]:grid-cols-1" {...inView}>
        {shots.map(([src, caption], i) => (
          <motion.figure
            key={src}
            // The featured first shot spans both columns so an odd count (3)
            // fills the row instead of leaving a dead cell.
            className={`m-0 flex flex-col gap-2${i === 0 ? " col-span-full" : ""}`}
            variants={reveal}
          >
            <motion.img
              src={src}
              alt={caption}
              className="block aspect-[16/10] w-full cursor-zoom-in rounded-lg border border-line bg-[#111111] object-cover"
              loading={i === 0 ? "eager" : "lazy"}
              fetchPriority={i === 0 ? "high" : "auto"}
              decoding="async"
              role="button"
              tabIndex={0}
              aria-label={`Enlarge: ${caption}`}
              onClick={() => setOpen(i)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  setOpen(i);
                }
              }}
              whileHover={{ scale: 1.02 }}
              transition={{ duration: 0.3, ease: EASE }}
            />
            <figcaption className="text-[13px] text-muted">{caption}</figcaption>
          </motion.figure>
        ))}
      </motion.section>

      {mounted &&
        createPortal(
          <AnimatePresence>
            {active && (
              <motion.div
                className="fixed inset-0 z-50 flex cursor-zoom-out items-center justify-center bg-[rgba(0,0,0,0.82)] p-6 backdrop-blur-[6px]"
                onClick={() => setOpen(null)}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.2, ease: EASE }}
              >
                <motion.img
                  src={active[0]}
                  alt={active[1]}
                  className="max-h-[86vh] w-auto max-w-[min(1100px,92vw)] rounded-[10px] border border-line object-contain"
                  initial={{ opacity: 0, scale: 0.94 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={{ opacity: 0, scale: 0.96 }}
                  transition={{ duration: 0.26, ease: EASE }}
                />
                <span className="fixed inset-x-0 bottom-5 text-center text-xs text-muted">
                  Esc · click to close
                </span>
              </motion.div>
            )}
          </AnimatePresence>,
          document.body,
        )}
    </>
  );
}

function Rows({ rows }: { rows: Array<[string, string]> }) {
  return (
    <motion.ul className="m-0 grid list-none gap-2 p-0" variants={stagger}>
      {rows.map(([key, desc]) => (
        <motion.li
          key={key}
          className={`${ROW_LI} items-baseline max-[560px]:gap-0.5`}
          variants={reveal}
          whileHover={{ x: 4 }}
        >
          <span className="text-text transition-colors duration-150 group-hover:text-accent">
            {key}
          </span>
          <span className="text-muted transition-colors duration-150 group-hover:text-text">
            {desc}
          </span>
        </motion.li>
      ))}
    </motion.ul>
  );
}

// Controlled accordion: the answer stays mounted (height-clipped when closed)
// so its text ships in the prerendered HTML and keeps matching the FAQPage
// JSON-LD — AnimatePresence would unmount it and break the rich result.
function FaqItem({ q, a }: { q: string; a: string }) {
  const [open, setOpen] = useState(false);
  return (
    <motion.div className="border-b border-line" variants={reveal}>
      <button
        type="button"
        className="flex w-full cursor-pointer items-baseline gap-2.5 border-0 bg-transparent py-2 text-left text-text transition-colors duration-150 hover:text-accent"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <motion.span
          className={`inline-block flex-none transition-colors duration-150 [font-variant-ligatures:none] ${
            open ? "text-accent" : "text-muted"
          }`}
          aria-hidden
          animate={{ rotate: open ? 45 : 0 }}
          transition={{ duration: 0.25, ease: EASE }}
        >
          +
        </motion.span>
        <span>{q}</span>
      </button>
      <motion.div
        className="overflow-hidden"
        initial={false}
        animate={{ height: open ? "auto" : 0, opacity: open ? 1 : 0 }}
        transition={{ duration: 0.3, ease: EASE }}
      >
        <p className="mb-3 ml-5 text-muted">{a}</p>
      </motion.div>
    </motion.div>
  );
}

const SCRAMBLE_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/<>_-$";

function useScramble(text: string, active: boolean, enabled: boolean): string {
  const [out, setOut] = useState(text);
  const idRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    if (idRef.current !== undefined) window.clearInterval(idRef.current);

    if (!enabled || !active) {
      setOut(text);
      return;
    }

    let i = 0;
    idRef.current = window.setInterval(() => {
      setOut(
        text
          .split("")
          .map((ch, idx) => {
            if (ch === " " || ch === ".") return ch;
            if (idx < Math.floor(i)) return text[idx];
            return SCRAMBLE_CHARS[Math.floor(Math.random() * SCRAMBLE_CHARS.length)];
          })
          .join(""),
      );
      i += 0.5;
      if (i >= text.length) {
        if (idRef.current !== undefined) window.clearInterval(idRef.current);
        setOut(text);
      }
    }, 28);

    return () => {
      if (idRef.current !== undefined) window.clearInterval(idRef.current);
    };
  }, [text, active, enabled]);

  return out;
}

// The download control — flat and quiet like the rest of the page, one capsule
// mirroring BrewCmd's [command | Copy] split: the download link on the left
// and, when a beta exists, an attached Latest/Beta channel segment on the
// right. Hover brightens the border and text, scrambles the label in, and
// drops the arrow into its tray; a tap gives a small spring scale as feedback.
function DownloadCta({
  href,
  beta,
  channel,
  onChange,
}: {
  href: string;
  beta: boolean;
  channel: "stable" | "beta";
  onChange: (c: "stable" | "beta") => void;
}) {
  const reduce = useReducedMotion();
  const [active, setActive] = useState(false);
  const label = useScramble("Download.dmg", active, !reduce);

  return (
    <div className="inline-flex max-w-full items-stretch overflow-hidden rounded-[9px] border border-line bg-[#111111] transition-colors duration-150 has-[a:hover]:border-accent has-[a:focus-visible]:border-accent">
      <motion.a
        className="inline-flex cursor-pointer items-center gap-2 px-4 py-[7px] leading-normal text-text transition-[color,background-color] duration-150 hover:bg-accent/[0.08] hover:text-accent focus-visible:bg-accent/[0.08] focus-visible:text-accent"
        href={href}
        download
        whileTap={{ scale: 0.98 }}
        transition={{ type: "spring", stiffness: 500, damping: 25 }}
        onHoverStart={() => setActive(true)}
        onHoverEnd={() => setActive(false)}
        onFocus={() => setActive(true)}
        onBlur={() => setActive(false)}
      >
        <svg
          className="block flex-none"
          width="14"
          height="15"
          viewBox="0 0 14 15"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden
        >
          <motion.g
            animate={active && !reduce ? { y: [0, 4, 4, 0] } : { y: 0 }}
            transition={
              active && !reduce
                ? {
                    duration: 1,
                    times: [0, 0.32, 0.46, 1],
                    ease: ["easeIn", "linear", "easeOut"],
                    repeat: Infinity,
                    repeatDelay: 0.1,
                  }
                : { duration: 0.25 }
            }
          >
            <path d="M7 2 V9" />
            <path d="M4 6 L7 9 L10 6" />
          </motion.g>
          <motion.path
            className="origin-center [transform-box:fill-box]"
            d="M2.5 13 H11.5"
            animate={
              active && !reduce
                ? { scaleX: [1, 1, 1.25, 1], opacity: [0.6, 0.6, 1, 0.85] }
                : { scaleX: 1, opacity: 0.85 }
            }
            transition={
              active && !reduce
                ? { duration: 1, times: [0, 0.34, 0.46, 1], repeat: Infinity, repeatDelay: 0.1 }
                : { duration: 0.25 }
            }
          />
        </svg>
        <span className="[font-variant-ligatures:none]">{label}</span>
      </motion.a>
      {beta && (
        <motion.div
          className="flex flex-none items-center gap-0.5 border-l border-line bg-white/[0.03] px-1.5 text-[13px] leading-normal"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 0.25, ease: EASE }}
        >
          {(["stable", "beta"] as const).map((c) => {
            const on = channel === c;
            return (
              <button
                key={c}
                type="button"
                onClick={() => onChange(c)}
                aria-pressed={on}
                className="relative cursor-pointer rounded-[6px] px-2 py-[3px]"
              >
                {on && (
                  <motion.span
                    layoutId="channel-pill"
                    className="absolute inset-0 rounded-[6px] bg-accent/[0.12]"
                    transition={{ type: "spring", stiffness: 500, damping: 34 }}
                  />
                )}
                <span
                  className={`relative z-10 transition-colors duration-150 ${
                    on ? "text-accent" : "text-dim hover:text-text"
                  }`}
                >
                  {c === "stable" ? "Latest" : "Beta"}
                </span>
              </button>
            );
          })}
        </motion.div>
      )}
    </div>
  );
}

function CopyGlyph() {
  return (
    <svg
      className="block flex-none"
      width="13"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <rect x="4.75" y="4.75" width="7.25" height="7.25" rx="1.5" />
      <path d="M9.25 4.75 V3 A1.5 1.5 0 0 0 7.75 1.5 H3 A1.5 1.5 0 0 0 1.5 3 v4.75 A1.5 1.5 0 0 0 3 9.25 h1.75" />
    </svg>
  );
}

function CheckGlyph() {
  return (
    <svg
      className="block flex-none"
      width="13"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <motion.path
        d="M2.75 7.5 L5.75 10.5 L11.25 4"
        initial={{ pathLength: 0 }}
        animate={{ pathLength: 1 }}
        transition={{ duration: 0.32, ease: EASE }}
      />
    </svg>
  );
}

// Copyable Homebrew one-liner. clipboard access lives inside the click
// handler, so this stays SSR-safe during the prerender (no top-level
// navigator/window reference).
function BrewCmd() {
  const [copied, setCopied] = useState(false);
  const timer = useRef<number | undefined>(undefined);

  const copy = () => {
    navigator.clipboard?.writeText(BREW).then(() => {
      setCopied(true);
      if (timer.current !== undefined) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setCopied(false), 1600);
    });
  };

  useEffect(
    () => () => {
      if (timer.current !== undefined) window.clearTimeout(timer.current);
    },
    [],
  );

  return (
    // Flat, matching the download button; a successful copy flashes the
    // border white.
    <motion.div
      layout
      className="inline-flex max-w-full items-stretch overflow-hidden rounded-[9px] border bg-[#111111]"
      initial={false}
      animate={{ borderColor: copied ? "var(--color-accent)" : "#222222" }}
      transition={{ duration: 0.3, ease: EASE }}
    >
      <code className="block overflow-x-auto whitespace-nowrap px-3.5 py-[7px] font-mono leading-normal text-dim before:text-muted before:content-['$_']">
        {BREW}
      </code>
      <motion.button
        type="button"
        // fixed width so the Copy → Copied swap doesn't reflow the box
        className="inline-flex min-w-[98px] flex-none cursor-pointer items-center justify-center border-l border-line bg-white/[0.03] px-3.5 py-[7px] font-mono leading-normal text-muted transition-colors duration-200 hover:bg-accent/[0.08] hover:text-accent focus-visible:bg-accent/[0.08] focus-visible:text-accent"
        onClick={copy}
        aria-label={copied ? "Copied to clipboard" : "Copy Homebrew command"}
        whileTap={{ scale: 0.96 }}
      >
        <AnimatePresence mode="wait" initial={false}>
          <motion.span
            key={copied ? "done" : "idle"}
            className="inline-flex items-center gap-1.5"
            initial={{ opacity: 0, y: 9 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -9 }}
            transition={{ duration: 0.18, ease: EASE }}
          >
            {copied ? <CheckGlyph /> : <CopyGlyph />}
            {copied ? "Copied" : "Copy"}
          </motion.span>
        </AnimatePresence>
      </motion.button>
    </motion.div>
  );
}

const downloadFmt = new Intl.NumberFormat("en-US");

export function Home() {
  const { stable, beta, totalDownloads } = useReleases();
  const [channel, setChannel] = useState<"stable" | "beta">("stable");
  const sel = channel === "beta" && beta ? beta : stable;
  const { version, dmgUrl } = sel;
  // On the beta channel, recolor the whole page amber by overriding the single
  // Tailwind accent var — every `*-accent` utility follows it.
  const accentStyle =
    channel === "beta" ? ({ "--color-accent": "#D29922" } as CSSProperties) : undefined;

  return (
    <MotionConfig reducedMotion="user">
      <main
        className="mx-auto flex max-w-[680px] flex-col gap-11 px-6 pt-[12vh] pb-[14vh]"
        style={accentStyle}
      >
        <motion.header
          className="flex flex-col gap-2.5"
          variants={stagger}
          initial="hidden"
          animate="show"
        >
          <motion.h1
            className="m-0 flex items-center gap-2.5 text-[15px] font-semibold tracking-[0.02em]"
            variants={reveal}
          >
            <motion.img
              className="block h-6.5 w-6.5 rounded-md"
              src="/icon.png"
              alt=""
              width={26}
              height={26}
              whileHover={{ rotate: -8, scale: 1.1 }}
              whileTap={{ scale: 0.94 }}
              transition={{ type: "spring", stiffness: 500, damping: 16 }}
            />
            BetterCmdTab
          </motion.h1>
          <motion.p className="m-0 text-dim" variants={reveal}>
            The <span className="text-accent">Cmd+Tab</span> macOS deserves.
            <span
              className="ml-[5px] inline-block h-[1.05em] w-[7px] animate-caret rounded-[1px] bg-accent align-[-0.15em] motion-reduce:animate-none"
              aria-hidden
            />
          </motion.p>
          <motion.p className="mt-3.5 text-muted" variants={reveal}>
            A fast, native window switcher and app launcher for macOS.
            <br />
            Free forever, zero telemetry, no subscription.
          </motion.p>
        </motion.header>

        <motion.section className={SECTION} {...inView}>
          <motion.div className="flex max-w-full flex-wrap items-center gap-2.5" variants={reveal}>
            <DownloadCta href={dmgUrl} beta={!!beta} channel={channel} onChange={setChannel} />
            <BrewCmd />
          </motion.div>
          {/* Meta as quiet chips, echoing the capsules above. Mirrors the
              BetterAudio price animation: LayoutGroup + eased layout on every
              chip so width changes glide, per-char roll inside the version. */}
          <LayoutGroup>
            <motion.div
              layout
              className="flex flex-wrap items-center gap-2 text-[13px] leading-normal text-dim"
              variants={reveal}
              transition={{ duration: 0.32, ease: EASE }}
            >
              {version && (
                <motion.span
                  layout
                  className={`inline-flex items-center overflow-hidden rounded-[6px] border px-2 py-[3px] tabular-nums transition-colors duration-300 ${
                    channel === "beta" ? "border-accent/40 text-accent" : "border-line text-text"
                  }`}
                  transition={{ duration: 0.32, ease: EASE }}
                >
                  {/* Per-character roll: chars keyed by index+char so only the
                      ones that actually change roll over, cascading with blur. */}
                  {version.split("").map((char, i) => (
                    <motion.span
                      key={i}
                      layout
                      className="relative inline-block overflow-hidden"
                      transition={{ duration: 0.32, ease: EASE }}
                    >
                      <AnimatePresence mode="popLayout" initial={false}>
                        <motion.span
                          key={`${i}-${char}`}
                          className="inline-block"
                          initial={{ y: "-100%", opacity: 0, filter: "blur(4px)" }}
                          animate={{ y: "0%", opacity: 1, filter: "blur(0px)" }}
                          exit={{ y: "100%", opacity: 0, filter: "blur(2px)" }}
                          transition={{ duration: 0.22, delay: i * 0.02, ease: EASE }}
                        >
                          {char}
                        </motion.span>
                      </AnimatePresence>
                    </motion.span>
                  ))}
                </motion.span>
              )}
              {totalDownloads !== null && (
                <motion.span
                  layout="position"
                  className="inline-flex items-center rounded-[6px] border border-line px-2 py-[3px] tabular-nums"
                  transition={{ duration: 0.32, ease: EASE }}
                >
                  {downloadFmt.format(totalDownloads)} downloads
                </motion.span>
              )}
              <motion.span
                layout="position"
                className="inline-flex items-center rounded-[6px] border border-line px-2 py-[3px]"
                transition={{ duration: 0.32, ease: EASE }}
              >
                macOS 13.0+
              </motion.span>
              <motion.span
                layout="position"
                className="inline-flex items-center rounded-[6px] border border-line px-2 py-[3px]"
                transition={{ duration: 0.32, ease: EASE }}
              >
                Apple Silicon &amp; Intel
              </motion.span>
            </motion.div>
          </LayoutGroup>
        </motion.section>

        <Shots />

        <motion.section className={SECTION} {...inView}>
          <motion.h2 className={H2} variants={reveal}>
            Features
          </motion.h2>
          <motion.div className="flex flex-col gap-7" variants={stagger}>
            {featureGroups.map((group) => (
              <motion.div key={group.label} className="flex flex-col gap-3" variants={reveal}>
                <h3 className="m-0 flex items-center gap-3 text-xs font-normal lowercase tracking-[0.04em] text-dim after:h-px after:flex-1 after:bg-line after:content-['']">
                  {group.label}
                </h3>
                <Rows rows={group.rows} />
              </motion.div>
            ))}
          </motion.div>
        </motion.section>

        <motion.section className={SECTION} {...inView}>
          <motion.h2 className={H2} variants={reveal}>
            FAQ
          </motion.h2>
          <motion.div className="flex flex-col gap-2" variants={stagger}>
            {faqs.map(([q, a]) => (
              <FaqItem key={q} q={q} a={a} />
            ))}
          </motion.div>
        </motion.section>

        <motion.section className={SECTION} {...inView}>
          <motion.h2 className={H2} variants={reveal}>
            Connect
          </motion.h2>
          <motion.p className="m-0 flex items-center gap-3" variants={reveal}>
            <ExternalLink href={REPO}>GitHub</ExternalLink>
            <span className="text-line">·</span>
            <ExternalLink href={`${REPO}/releases`}>Releases</ExternalLink>
            <span className="text-line">·</span>
            <ExternalLink href={`${REPO}/blob/main/LICENSE`}>License</ExternalLink>
          </motion.p>
        </motion.section>

        <motion.footer
          className="text-[13px] text-muted"
          initial={{ opacity: 0 }}
          whileInView={{ opacity: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5 }}
        >
          Built by <ExternalLink href="https://github.com/rokartur">@rokartur</ExternalLink> · GPL
          v3
        </motion.footer>
      </main>
    </MotionConfig>
  );
}
