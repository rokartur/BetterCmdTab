import { createFileRoute } from "@tanstack/react-router";
import { AnimatePresence, LayoutGroup, MotionConfig, motion, useReducedMotion } from "motion/react";
import { type CSSProperties, type ReactNode, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

import snapshot from "../../releases.json";
import {
  channels,
  FETCH_TIMEOUT,
  freshest,
  type GhRelease,
  isFresh,
  readCache,
  RELEASES_URL,
  type Releases,
  writeCache,
} from "../releases";

export const Route = createFileRoute("/")({ component: Home });

const REPO = "https://github.com/rokartur/BetterCmdTab";

const BREW = "brew install --cask bettercmdtab";

const EASE = [0.22, 1, 0.36, 1] as const;

// The entrance cascade is the `enter`/`rise` classes in globals.css, and it stays
// CSS: a keyframe on the prerendered HTML runs at the first paint, while anything
// Motion-driven can't start until ~800 KB of JS hydrates, which means content
// sits visibly parked and then hops. Same reason there is no scroll reveal —
// everything below the fold ships in its final position. Motion here is only for
// what a click or a hover asks for.

// Shared utility strings — the recurring "components" of the page.
const SECTION = "flex flex-col gap-4";

// Section headings carry a hairline rule out to the edge — at 960px wide a bare
// 13px label is too quiet to separate anything.
const H2 =
  "m-0 flex items-center gap-3 text-[13px] font-normal tracking-[0.04em] text-muted after:h-px after:flex-1 after:bg-line after:content-['']";

// Shared tab-strip look for the layout showcase and the config presets.
const TAB =
  "relative cursor-pointer rounded-[6px] border-0 bg-transparent px-2.5 py-[3px] font-mono text-[13px] leading-normal transition-colors duration-200";

// The first entry is what layout.tsx preloads, so the LCP image is already in
// flight before this mounts — keep the two in sync.
const layouts = [
  {
    id: "previews",
    label: "previews",
    src: "/screenshots/preview.jpg",
    caption: "Live previews of every window on screen",
  },
  {
    id: "grid",
    label: "grid",
    src: "/screenshots/grid.jpg",
    caption: "A grid of app icons, window titles underneath",
  },
  {
    id: "list",
    label: "list",
    src: "/screenshots/list.jpg",
    caption: "The classic vertical list, one row per window",
  },
];

const featureGroups: Array<{ label: string; rows: Array<[string, string]> }> = [
  {
    label: "switching",
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
    label: "layouts",
    rows: [
      ["Three layouts", "classic list, grid of icons, or live window previews"],
      ["Window titles", "show each window's title under its icon in Grid and Previews"],
      [
        "Preview titles",
        "choose how window titles align in previews and whether the selected name is bold",
      ],
      [
        "Theming",
        "panel opacity, corner radius, and background material — the highlight follows your macOS accent color",
      ],
      ["Multi-monitor", "opens on the display you're actively working on"],
    ],
  },
  {
    label: "tabs",
    rows: [
      ["Tab drill-in", "press \\ to pick a tab from Safari, Chrome, Arc, Finder, Terminal, …"],
      [
        "Tabs as rows",
        "surface each native or browser tab as its own row, with a most-recently-used order and a hint when Safari/Chrome need automation permission",
      ],
    ],
  },
  {
    label: "windows",
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
    label: "filters",
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
    label: "spaces",
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
    label: "system",
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
      ["Export & import", "back up and move your whole setup as a plain JSON file"],
      [
        "Config file",
        "optionally keep settings in ~/.config/bettercmdtab/config.json — file edits apply live, app changes write back",
      ],
      ["Configurable", "custom hotkey, size, scale, layout, grid columns, and reveal delay"],
    ],
  },
];

// Mirrored by the FAQPage JSON-LD in app/layout.tsx, which is what machine
// readers get. Edit both sides together so they keep saying the same thing.
const faqs: Array<[string, string]> = [
  [
    "Is BetterCmdTab free?",
    "Yes. BetterCmdTab is free forever and open-source under GPL v3, with zero telemetry and no subscription.",
  ],
  [
    "Which macOS versions and Macs does it support?",
    "macOS 13.0 or later, on both Apple Silicon and Intel.",
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

// Baked at build time (scripts/fetch-releases.ts, run by the Docker build) so
// the page — including the statically rendered HTML — is correct as of the
// last deploy even when GitHub's API limit is exhausted, which it routinely is.
const baked = channels(snapshot);

function useReleases(): Releases {
  const [rel, setRel] = useState<Releases>(baked);

  useEffect(() => {
    // localStorage is read after mount, never during render: the server and the
    // client's first render must agree or hydration throws the markup away.
    const cache = readCache();
    const best = freshest(baked, cache?.rel);
    if (best !== baked) setRel(best);
    if (cache && isFresh(cache)) return;

    let unmounted = false;
    const ctrl = new AbortController();
    // Without this a hung connection never settles, so the failure path below
    // never runs and every reload retries from scratch.
    const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT);
    fetch(RELEASES_URL, {
      headers: { Accept: "application/vnd.github+json" },
      signal: ctrl.signal,
    })
      .then((r) => (r.ok ? (r.json() as Promise<GhRelease[]>) : Promise.reject(r.status)))
      .then((releases) => {
        if (releases.length === 0) return;
        const fresh = channels(releases);
        writeCache(fresh);
        setRel(fresh);
      })
      .catch(() => {
        // Rate-limited, timed out or offline. Stamp what we already show so a
        // reload inside the window doesn't fire the same doomed request again;
        // an unmount is not a failure, so it must not write anything.
        if (!unmounted) writeCache(best);
      })
      .finally(() => clearTimeout(timer));

    return () => {
      unmounted = true;
      clearTimeout(timer);
      ctrl.abort();
    };
  }, []);

  return rel;
}

const ExternalLink = "a";

// APG tab pattern: Left/Right (and Home/End) move between tabs and take focus
// with them, and only the selected tab is in the tab order. A bare row of
// role="tab" buttons without that leaves the others unreachable by keyboard, so
// the behaviour lives here once and both tab strips use it.
function Tabs({
  label,
  tabs,
  active,
  onChange,
  idPrefix,
  panelId,
}: {
  label: string;
  tabs: ReadonlyArray<{ id: string; label: string }>;
  active: number;
  onChange: (i: number) => void;
  idPrefix: string;
  panelId: string;
}) {
  const refs = useRef<Array<HTMLButtonElement | null>>([]);

  const onTabKey = (e: React.KeyboardEvent) => {
    const last = tabs.length - 1;
    let next: number | null = null;
    if (e.key === "ArrowRight") next = active === last ? 0 : active + 1;
    else if (e.key === "ArrowLeft") next = active === 0 ? last : active - 1;
    else if (e.key === "Home") next = 0;
    else if (e.key === "End") next = last;
    if (next === null) return;
    e.preventDefault();
    onChange(next);
    refs.current[next]?.focus();
  };

  return (
    // No LayoutGroup here: `idPrefix` already makes the pill's layoutId unique
    // per strip, and an extra group would only nest inside the caller's.
    <div className="flex flex-wrap items-center gap-1" role="tablist" aria-label={label}>
      {tabs.map((t, i) => (
        <button
          key={t.id}
          ref={(el) => {
            refs.current[i] = el;
          }}
          type="button"
          role="tab"
          id={`${idPrefix}-tab-${t.id}`}
          aria-selected={i === active}
          // Only the visible panel exists, so pointing at it from an inactive
          // tab would dangle.
          aria-controls={i === active ? panelId : undefined}
          tabIndex={i === active ? 0 : -1}
          onKeyDown={onTabKey}
          className={`${TAB} ${i === active ? "text-accent" : "text-muted hover:text-text"}`}
          onClick={() => onChange(i)}
        >
          {i === active && (
            <motion.span
              layoutId={`${idPrefix}-pill`}
              className="absolute inset-0 -z-10 rounded-[6px] border border-accent/40 bg-accent/[0.08]"
              transition={{ duration: 0.28, ease: EASE }}
            />
          )}
          {t.label}
        </button>
      ))}
    </div>
  );
}

// The product, front and centre: one large screenshot with the three switcher
// layouts as tabs over it.
function Showcase() {
  const [active, setActive] = useState(0);
  // Each screenshot is ~250 KB. Only a tab you actually opened is allowed to
  // fetch, so the page costs one image instead of three; once opened it stays
  // mounted and every later switch is instant.
  const [opened, setOpened] = useState<number[]>([0]);
  // A tab only swaps once its bitmap has actually decoded. Promoting it on
  // click is what made the switch flash the empty box on first open.
  const [ready, setReady] = useState<number[]>([0]);
  // Two layers, not a cross-fade: the incoming image fades in *over* the
  // outgoing one, which holds at full opacity underneath. Fading both at once
  // dips through a half-transparent middle, which on this background reads as
  // a flicker.
  const [view, setView] = useState({ prev: 0, shown: 0 });
  const [zoomed, setZoomed] = useState(false);
  // The lightbox portals into document.body, which doesn't exist during the
  // build-time static render. Gate it on mount so SSR stays document-free.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const select = (i: number) => {
    setActive(i);
    setOpened((o) => (o.includes(i) ? o : [...o, i]));
  };

  // The pill moves on click for immediate feedback; the picture and its caption
  // follow together as soon as the picture can be shown.
  useEffect(() => {
    if (!ready.includes(active)) return;
    setView((v) => (v.shown === active ? v : { prev: v.shown, shown: active }));
  }, [active, ready]);

  useEffect(() => {
    if (!zoomed) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setZoomed(false);
    };
    window.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [zoomed]);

  const { prev, shown } = view;
  const shot = layouts[shown];

  return (
    // Drifts up under the hero cascade with no delay of its own, so the big
    // picture is already settling while the text above it arrives.
    <section className="rise flex flex-col gap-3">
      <div className="flex items-center justify-between gap-4 max-[560px]:flex-col max-[560px]:items-start max-[560px]:gap-1.5">
        <Tabs
          label="Switcher layouts"
          tabs={layouts}
          active={active}
          onChange={select}
          idPrefix="layout"
          panelId="layout-panel"
        />
        <AnimatePresence mode="wait" initial={false}>
          <motion.p
            key={shot.id}
            className="m-0 text-[13px] text-muted"
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -4 }}
            transition={{ duration: 0.18, ease: EASE }}
          >
            {shot.caption}
          </motion.p>
        </AnimatePresence>
      </div>

      {/* Holds the LCP image, which layout.tsx preloads at fetchpriority=high —
          nothing here may hide or defer it. */}
      <div id="layout-panel" role="tabpanel" aria-labelledby={`layout-tab-${shot.id}`}>
        <button
          type="button"
          onClick={() => setZoomed(true)}
          aria-label={`Enlarge: ${shot.caption}`}
          // The intrinsic 2000×1043 ratio, so the whole screenshot shows
          // instead of being cropped, and the box reserves its height before
          // the image lands.
          className="relative block aspect-[2000/1043] w-full cursor-zoom-in overflow-hidden rounded-[10px] border border-line bg-[#111111]"
        >
          {layouts.map((l, i) =>
            opened.includes(i) ? (
              <motion.img
                key={l.id}
                src={l.src}
                alt={l.caption}
                aria-hidden={i !== shown}
                className="absolute inset-0 block h-full w-full object-cover"
                loading={i === 0 ? "eager" : "lazy"}
                fetchPriority={i === 0 ? "high" : "auto"}
                decoding="async"
                // An image that never loads would otherwise pin the switcher on
                // the old picture forever.
                onLoad={() => setReady((r) => (r.includes(i) ? r : [...r, i]))}
                onError={() => setReady((r) => (r.includes(i) ? r : [...r, i]))}
                style={{ zIndex: i === shown ? 2 : i === prev ? 1 : 0 }}
                // The LCP image must paint at full opacity on the first frame
                // rather than fade in.
                initial={i === 0 ? false : { opacity: 0 }}
                animate={{ opacity: i === shown || i === prev ? 1 : 0 }}
                // Only the incoming layer animates; the one underneath is
                // already covered, so moving it is wasted work.
                transition={{ duration: i === shown ? 0.45 : 0, ease: EASE }}
                // Once the incoming layer has fully covered the outgoing one,
                // retire it. Otherwise it stays at opacity 1 underneath and
                // coming back to it later snaps instead of fading.
                onAnimationComplete={() => {
                  if (i === shown && prev !== shown) setView({ prev: shown, shown });
                }}
              />
            ) : null,
          )}
        </button>
      </div>

      {mounted &&
        createPortal(
          <AnimatePresence>
            {zoomed && (
              <motion.div
                className="fixed inset-0 z-50 flex cursor-zoom-out items-center justify-center bg-[rgba(0,0,0,0.82)] p-6 backdrop-blur-[6px]"
                onClick={() => setZoomed(false)}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.2, ease: EASE }}
              >
                <motion.img
                  src={shot.src}
                  alt={shot.caption}
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
    </section>
  );
}

// Name and description side by side, hairline between rows — a spec sheet.
// Every description is always readable: the previous build hid them in a
// hover panel, which is text you can't reach on touch and can't scan anywhere.
function Rows({ rows }: { rows: Array<[string, string]> }) {
  return (
    <ul className="m-0 flex list-none flex-col p-0">
      {rows.map(([term, desc]) => (
        <li
          key={term}
          className="grid grid-cols-[minmax(0,14rem)_minmax(0,1fr)] items-baseline gap-x-8 border-t border-line py-2.5 max-[640px]:grid-cols-1 max-[640px]:gap-y-0.5"
        >
          <span className="text-text">{term}</span>
          <span className="text-[13px] leading-[1.55] text-muted">{desc}</span>
        </li>
      ))}
    </ul>
  );
}

const FEATURE_COUNT = featureGroups.reduce((n, g) => n + g.rows.length, 0);

// Built once: Tabs wants {id,label}, the groups are keyed by their label.
const featureTabs = featureGroups.map((g) => ({ id: g.label, label: g.label }));

// Thirty-eight features is a wall, so they work the way the app does: one
// group at a time from the same tab strip the showcase uses. Every group stays
// in the DOM (`hidden`, not unmounted) so the full list still ships in the
// static HTML.
function Features() {
  const [active, setActive] = useState(0);
  const panels = useRef<Array<HTMLDivElement | null>>([]);
  const [height, setHeight] = useState<number>();
  // The group that is still fading out. It keeps the outgoing rows on screen
  // for the length of the swap, so the box never flashes empty mid-transition.
  const [leaving, setLeaving] = useState<number | null>(null);
  const reduce = useReducedMotion();

  const select = (i: number) => {
    if (i === active) return;
    setLeaving(active);
    setActive(i);
  };

  // Groups run from two to ten rows, so the box glides to the new one instead
  // of the page lurching. Measured rather than animated by layout projection:
  // the panel holds wrapping text, and scaling that squashes every row.
  useEffect(() => {
    const measure = () => setHeight(panels.current[active]?.offsetHeight);
    measure();
    // The box clips its panel, so a stale height after a rewrap would cut text.
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [active]);

  return (
    <section className={SECTION}>
      <div className="flex flex-wrap items-center gap-3">
        <h2 className="m-0 shrink-0 text-[13px] font-normal tracking-[0.04em] text-muted">
          Features
        </h2>
        <span className="h-px flex-1 bg-line max-[560px]:hidden" aria-hidden />
        <span className="shrink-0 text-[13px] text-dim tabular-nums">{FEATURE_COUNT}</span>
      </div>

      <Tabs
        label="Feature groups"
        tabs={featureTabs}
        active={active}
        onChange={select}
        idPrefix="feature"
        panelId="feature-panel"
      />
      <motion.div
        className="relative overflow-hidden"
        initial={false}
        animate={{ height: height ?? "auto" }}
        transition={{ duration: reduce ? 0 : 0.36, ease: EASE }}
      >
        {featureGroups.map((group, i) => (
          <motion.div
            key={group.label}
            ref={(el) => {
              panels.current[i] = el;
            }}
            // The one on its way out leaves the flow, so the incoming
            // panel alone sets the height the box is gliding to.
            className={i === leaving ? "absolute inset-x-0 top-0" : undefined}
            // Only the visible panel is referenced by its tab, so only it
            // carries the id Tabs points at.
            id={i === active ? "feature-panel" : undefined}
            role="tabpanel"
            aria-labelledby={`feature-tab-${group.label}`}
            // Nothing inside a panel is focusable, so the panel itself has
            // to be, or the rows are unreachable from the tab strip.
            tabIndex={i === active ? 0 : undefined}
            aria-hidden={i === leaving || undefined}
            // Hidden, not unmounted: the rows stay in the static HTML,
            // and each panel keeps the parked state it animates back from
            // the next time it is picked.
            hidden={i !== active && i !== leaving}
            initial={false}
            // Panels park on the side they sit on in the strip, so a group
            // picked to the right comes in from the right and the one it
            // replaces leaves to the left. No direction to track: the
            // index against the new selection already says which way.
            animate={i === active ? { opacity: 1, x: 0 } : { opacity: 0, x: i < active ? -16 : 16 }}
            transition={
              i === active
                ? { duration: 0.3, delay: 0.05, ease: EASE }
                : // Parked panels are display:none, so their reset is free
                  // and only the two panels in the swap spend frames.
                  { duration: i === leaving ? 0.22 : 0, ease: EASE }
            }
            onAnimationComplete={() => {
              if (i === leaving) setLeaving(null);
            }}
          >
            <Rows rows={group.rows} />
          </motion.div>
        ))}
      </motion.div>
    </section>
  );
}

// Controlled accordion: the answer stays mounted (height-clipped when closed)
// so its text ships in the statically rendered HTML and keeps matching the
// FAQPage JSON-LD — AnimatePresence would unmount it and break the rich result.
function FaqItem({ q, a }: { q: string; a: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="border-b border-line">
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
    </div>
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
    <div className="inline-flex max-w-full items-stretch overflow-hidden rounded-[9px] border border-line bg-[#111111] transition-colors duration-150 has-[a:focus-visible]:border-accent has-[a:hover]:border-accent">
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
        <div className="flex flex-none items-center gap-0.5 border-l border-line bg-white/[0.03] px-1.5 text-[13px] leading-normal">
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
        </div>
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

// Copy-to-clipboard with a self-resetting "copied" flag. clipboard access
// lives inside the returned callback, so this stays SSR-safe during the
// static render (no top-level navigator/window reference).
function useCopy(): [boolean, (text: string) => void] {
  const [copied, setCopied] = useState(false);
  const timer = useRef<number | undefined>(undefined);

  useEffect(
    () => () => {
      if (timer.current !== undefined) window.clearTimeout(timer.current);
    },
    [],
  );

  const copy = (text: string) => {
    navigator.clipboard
      ?.writeText(text)
      .then(() => {
        setCopied(true);
        if (timer.current !== undefined) window.clearTimeout(timer.current);
        timer.current = window.setTimeout(() => setCopied(false), 1600);
      })
      // Denied permission or an unfocused document rejects here; swallowing it
      // keeps the button honest (it just never says "Copied") instead of
      // raising an unhandled rejection.
      .catch(() => {});
  };

  return [copied, copy];
}

// Copyable Homebrew one-liner.
function BrewCmd({ beta }: { beta: boolean }) {
  const [copied, copy] = useCopy();

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
      <code className="block overflow-x-auto px-3.5 py-[7px] font-mono leading-normal whitespace-nowrap text-dim before:text-muted before:content-['$_']">
        {BREW}
        {/* Only the suffix moves, so the command reads as one stable string:
            it slides its own width open instead of the whole box jumping. */}
        <AnimatePresence initial={false}>
          {beta && (
            <motion.span
              className="inline-block overflow-hidden align-bottom text-accent"
              initial={{ width: 0, opacity: 0 }}
              animate={{ width: "auto", opacity: 1 }}
              exit={{ width: 0, opacity: 0 }}
              transition={{ duration: 0.28, ease: EASE }}
            >
              @beta
            </motion.span>
          )}
        </AnimatePresence>
      </code>
      <motion.button
        type="button"
        // fixed width so the Copy → Copied swap doesn't reflow the box
        className="inline-flex min-w-[98px] flex-none cursor-pointer items-center justify-center border-l border-line bg-white/[0.03] px-3.5 py-[7px] font-mono leading-normal text-muted transition-colors duration-200 hover:bg-accent/[0.08] hover:text-accent focus-visible:bg-accent/[0.08] focus-visible:text-accent"
        onClick={() => copy(beta ? `${BREW}@beta` : BREW)}
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

// Same origin, served by the docs app rather than this static export — plain
// anchors so the browser does a real navigation instead of the router
// swallowing it.
const DOCS = "/docs";

// Real keys straight out of the config schema — each preset is a file you
// could paste into ~/.config/bettercmdtab/config.json as-is.
const configPresets: Array<{ id: string; label: string; blurb: string; json: string }> = [
  {
    id: "minimal",
    label: "minimal",
    blurb: "A quiet list, sorted A→Z.",
    json: `{
  "layoutMode": "list",
  "sortOrder": "alphabetical",
  "panelScalePercent": 100,
  "showWindowTitleLabel": false
}`,
  },
  {
    id: "power",
    label: "power user",
    blurb: "Previews of every window on screen, browser tabs included.",
    json: `{
  "layoutMode": "windowPreview",
  "spaceScope": "visibleSpaces",
  "sortOrder": "mruWindows",
  "stayOpenOnRelease": true,
  "expandBrowserTabsAsWindows": true,
  "searchIncludesLaunchableApps": true
}`,
  },
  {
    id: "rules",
    label: "per-app rules",
    blurb: "Let a game keep Cmd+Tab; hide the apps you never switch to.",
    json: `{
  "pinnedBundleIDs": ["com.apple.Safari"],
  "appExceptions": [
    {
      "bundleID": "com.valvesoftware.steam",
      "ignore": "whenFullscreen"
    },
    {
      "bundleID": "com.apple.ActivityMonitor",
      "hide": "whenNoWindows"
    }
  ]
}`,
  },
];

// Paths are relative to DOCS; the quick start is the docs landing page, hence
// the bare slash. Every one ends in a slash to match the docs' canonical URLs
// — the bare form is a 301 on both deploy targets, and an internal link should
// not spend a redirect.
const docsLinks: Array<[string, string, string]> = [
  ["quick start", "Install, permissions, your first switch", "/"],
  ["config file", "How the live two-way sync works", "/configuration/"],
  ["config reference", "Every key, with types and defaults", "/config-reference/"],
  ["per-shortcut overrides", "A different switcher on every hotkey", "/overrides/"],
];

// Key / string / literal / number, in that order. Anything unmatched (braces,
// commas, whitespace) falls through as plain punctuation.
const JSON_TOKEN =
  /("(?:\\.|[^"\\])*")(\s*:)|("(?:\\.|[^"\\])*")|\b(true|false|null)\b|(-?\d+(?:\.\d+)?)/g;

function highlight(line: string) {
  const out: Array<ReactNode> = [];
  let last = 0;
  let m: RegExpExecArray | null;
  JSON_TOKEN.lastIndex = 0;
  while ((m = JSON_TOKEN.exec(line)) !== null) {
    if (m.index > last) out.push(line.slice(last, m.index));
    const [, key, colon, str, lit, num] = m;
    const cls = key ? "text-text" : str ? "text-accent" : "text-dim";
    out.push(
      <span key={m.index} className={cls}>
        {key ?? str ?? lit ?? num}
      </span>,
    );
    if (colon) out.push(colon);
    last = m.index + m[0].length;
  }
  if (last < line.length) out.push(line.slice(last));
  return out;
}

// Tabbed config.json preview. The panel keeps a single `layout` wrapper so
// swapping presets glides the height instead of snapping it.
function ConfigPreview() {
  const [active, setActive] = useState(0);
  const [copied, copy] = useCopy();
  const preset = configPresets[active];
  const lines = preset.json.split("\n");

  // Animate the *real* height. `layout` only compensates visually: the DOM box
  // resizes in one frame, so the panel glided while everything below the Docs
  // section snapped. Driving the height itself keeps the page flow in step,
  // which is the whole point. Line wrapping is off (whitespace-pre), so a
  // preset's height doesn't depend on the panel's width and one measurement
  // per preset holds.
  const body = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState<number | "auto">("auto");
  useEffect(() => {
    if (body.current) setHeight(body.current.offsetHeight);
  }, [active]);

  return (
    <div className="flex flex-col gap-2.5">
      <Tabs
        label="Configuration examples"
        tabs={configPresets}
        active={active}
        onChange={setActive}
        idPrefix="cfg"
        panelId="cfg-panel"
      />

      <div className="overflow-hidden rounded-[9px] border border-line bg-[#111111]">
        <div className="flex items-center justify-between gap-3 border-b border-line px-3.5 py-[7px]">
          <span className="truncate text-[13px] leading-normal text-muted">
            ~/.config/bettercmdtab/config.json
          </span>
          <motion.button
            type="button"
            className="inline-flex flex-none cursor-pointer items-center gap-1.5 rounded-[6px] border-0 bg-transparent p-0 font-mono text-[13px] leading-normal text-muted transition-colors duration-200 hover:text-accent focus-visible:text-accent"
            onClick={() => copy(preset.json)}
            aria-label={copied ? "Copied to clipboard" : "Copy this configuration"}
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
        </div>

        <motion.div
          className="overflow-hidden"
          initial={false}
          animate={{ height }}
          transition={{ duration: 0.3, ease: EASE }}
        >
          {/* Measured while the wrapper above still holds the previous height,
              so the new preset is laid out but not yet shown at full size.
              `relative` because popLayout takes the outgoing preset out of flow
              — which also keeps it out of this measurement. */}
          <div ref={body} className="relative">
            {/* popLayout, not wait: `wait` unmounts the old preset before the new
                one mounts, so the panel briefly holds nothing and collapses. */}
            <AnimatePresence mode="popLayout" initial={false}>
              <motion.pre
                key={preset.id}
                id="cfg-panel"
                role="tabpanel"
                aria-labelledby={`cfg-tab-${preset.id}`}
                // Scrollable region with no focusable children, so it needs to be
                // focusable itself or a long line can't be scrolled by keyboard.
                tabIndex={0}
                className="m-0 w-full overflow-x-auto px-3.5 py-3 font-mono leading-normal"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.16, ease: EASE }}
              >
                <code>
                  {lines.map((line, i) => (
                    // Lines cascade in so switching presets reads as the file
                    // being retyped rather than swapped.
                    <motion.span
                      key={i}
                      className="block whitespace-pre text-muted"
                      initial={{ opacity: 0, x: -6 }}
                      animate={{ opacity: 1, x: 0 }}
                      transition={{ duration: 0.2, delay: i * 0.025, ease: EASE }}
                    >
                      {highlight(line)}
                    </motion.span>
                  ))}
                </code>
              </motion.pre>
            </AnimatePresence>
          </div>
        </motion.div>
      </div>

      {/* No `layout` here: the panel above now changes real height, so the
          blurb is carried by normal flow. */}
      <div className="relative">
        <AnimatePresence mode="popLayout" initial={false}>
          <motion.p
            key={preset.id}
            className="m-0 text-[13px] text-muted"
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -4 }}
            transition={{ duration: 0.18, ease: EASE }}
          >
            {preset.blurb}
          </motion.p>
        </AnimatePresence>
      </div>
    </div>
  );
}

function Docs() {
  return (
    <section className={SECTION}>
      <h2 className={H2}>Docs</h2>

      {/* The pitch sits beside the artifact it is describing instead of above
          it. Stacked, this section was the tallest on the page while half the
          width next to the code panel stayed empty. */}
      <div className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)] items-start gap-x-10 gap-y-7 max-[860px]:grid-cols-1">
        <div className="flex flex-col gap-4">
          <p className="m-0 text-muted">
            Every setting also lives in a plain JSON file you can diff, version and drop into your
            dotfiles. Edits apply live, changes made in the app are written back, and a generated
            schema keeps your editor autocompleting.
          </p>

          <ul className="m-0 flex list-none flex-col p-0">
            {docsLinks.map(([title, desc, path]) => (
              <li key={title}>
                <a className="group/doc flex flex-col gap-0.5 py-2.5" href={`${DOCS}${path}`}>
                  <span className="flex items-center gap-1.5 text-text transition-colors duration-150 group-hover/doc:text-accent">
                    {title}
                    <span
                      className="text-muted transition-transform duration-200 group-hover/doc:translate-x-1 motion-reduce:transition-none"
                      aria-hidden
                    >
                      →
                    </span>
                  </span>
                  <span className="text-[13px] leading-[1.55] text-muted">{desc}</span>
                </a>
              </li>
            ))}
          </ul>

          <a
            className="inline-flex w-fit items-center gap-2 rounded-[9px] border border-line bg-[#111111] px-3.5 py-[7px] leading-normal text-text transition-colors duration-150 hover:border-accent hover:bg-accent/[0.08] hover:text-accent focus-visible:border-accent"
            href={`${DOCS}/`}
          >
            Read the docs
            <span aria-hidden>→</span>
          </a>
        </div>

        <ConfigPreview />
      </div>
    </section>
  );
}

const downloadFmt = new Intl.NumberFormat("en-US");

function Home() {
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
        className="mx-auto flex max-w-[960px] flex-col gap-14 px-6 pt-[10vh] pb-[14vh]"
        style={accentStyle}
      >
        {/* Left-aligned like everything below it: a centred hero over a
            left-aligned page is two axes fighting, and centred logo-over-
            headline is the most default shape a landing page has. */}
        <header className="flex flex-col gap-5">
          {/* Brand mark, not a heading — the h1 is the promise. */}
          <div className="enter flex items-center gap-2.5">
            <motion.img
              className="block h-7 w-7 rounded-[7px]"
              // 56px source for a 28px box — 2x for retina and nothing more.
              // The 256px icon.png is 56 KB and React preloads whatever the
              // first <img> points at, so it was competing with the LCP
              // screenshot for bandwidth to paint a logo the size of a favicon.
              src="/icon-56.png"
              alt=""
              width={28}
              height={28}
              whileHover={{ rotate: -8, scale: 1.1 }}
              whileTap={{ scale: 0.94 }}
              transition={{ type: "spring", stiffness: 500, damping: 16 }}
            />
            <span className="text-[13px] tracking-[0.02em] text-muted">BetterCmdTab</span>
          </div>

          {/* No width cap: 27 mono characters at 34px is ~565px, so the line
             holds together on one line and the step down lands exactly where
             it stops fitting. Phones still wrap — one line there would mean a
             19px headline, which is barely louder than the paragraph. */}
          <h1 className="enter m-0 text-[34px] leading-[1.18] font-semibold tracking-[-0.02em] [animation-delay:70ms] max-[640px]:text-[24px]">
            The <span className="text-accent">Cmd+Tab</span> macOS deserves.
            <span
              className="ml-1.5 inline-block h-[0.9em] w-[9px] animate-caret rounded-[1px] bg-accent align-[-0.06em] motion-reduce:animate-none"
              aria-hidden
            />
          </h1>

          <p className="enter m-0 max-w-[56ch] text-muted [animation-delay:140ms]">
            A fast, native window switcher and app launcher. Free forever, zero telemetry, no
            subscription.
          </p>
        </header>

        <section className="enter flex flex-col gap-4 [animation-delay:210ms]">
          <div className="flex max-w-full flex-wrap items-center gap-2.5">
            <DownloadCta href={dmgUrl} beta={!!beta} channel={channel} onChange={setChannel} />
            <BrewCmd beta={channel === "beta"} />
          </div>
          {/* Meta as quiet chips, echoing the capsules above. Mirrors the
              BetterAudio price animation: LayoutGroup + eased layout on every
              chip so width changes glide, per-char roll inside the version. */}
          <LayoutGroup>
            <motion.div
              layout
              className="flex flex-wrap items-center gap-2 text-[13px] leading-normal text-dim"
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
              {totalDownloads > 0 && (
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
        </section>

        <Showcase />

        <Features />

        <Docs />

        <section className={SECTION}>
          <h2 className={H2}>FAQ</h2>
          <div className="flex flex-col gap-2">
            {faqs.map(([q, a]) => (
              <FaqItem key={q} q={q} a={a} />
            ))}
          </div>
        </section>

        <section className={SECTION}>
          <h2 className={H2}>Connect</h2>
          <p className="m-0 flex items-center gap-3">
            <ExternalLink href={REPO}>GitHub</ExternalLink>
            <span className="text-line">·</span>
            <ExternalLink href={`${REPO}/releases`}>Releases</ExternalLink>
            <span className="text-line">·</span>
            <ExternalLink href={`${REPO}/blob/main/LICENSE`}>License</ExternalLink>
          </p>
        </section>

        <footer className="text-[13px] text-muted">
          Built by <ExternalLink href="https://github.com/rokartur">@rokartur</ExternalLink> · GPL
          v3
        </footer>
      </main>
    </MotionConfig>
  );
}
