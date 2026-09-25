import { createFileRoute } from "@tanstack/react-router";
import {
  AnimatePresence,
  LayoutGroup,
  MotionConfig,
  motion,
  useAnimationControls,
  useInView,
  useReducedMotion,
  type Variants,
} from "motion/react";
import {
  type CSSProperties,
  Fragment,
  type ReactNode,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { createPortal } from "react-dom";

import snapshot from "../../releases.json";
import {
  type Channel,
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
import { DownloadButton, Icon, StickyCTA } from "../StickyCTA";

export const Route = createFileRoute("/")({ component: Home });

const REPO = "https://github.com/rokartur/BetterCmdTab";

const BREW = "brew install --cask bettercmdtab";

const EASE = [0.22, 1, 0.36, 1] as const;

// Every color in the channel toggle crossfades on this one clock, or the inverted text dips under its background.
const CHANNEL_SWAP = "duration-300 ease-[cubic-bezier(0.22,1,0.36,1)]";

// Split so each word blurs in on its own beat.
const headlineWords = ["The", "⌘Tab", "macOS", "deserves."];

// The entrance cascade is the `enter`/`rise` classes in globals.css, and it stays
// CSS: a keyframe on the prerendered HTML runs at the first paint, while anything
// Motion-driven can't start until ~800 KB of JS hydrates, which means content
// sits visibly parked and then hops. Same reason there is no scroll reveal —
// everything below the fold ships in its final position. Motion here is only for
// what a click or a hover asks for.

const H2 =
  "m-0 mb-7 max-w-[22ch] text-[clamp(26px,3.4vw,40px)] leading-[1.1] font-bold tracking-[-0.025em] text-balance";

// The first entry is what layout.tsx preloads, so the LCP image is already in
// flight before this mounts, so keep the two in sync.
const layouts = [
  {
    id: "previews",
    label: "Previews",
    src: "/screenshots/preview.webp",
    caption: "Live previews of every window on screen",
  },
  {
    id: "grid",
    label: "Grid",
    src: "/screenshots/grid.webp",
    caption: "A grid of app icons, window titles underneath",
  },
  {
    id: "list",
    label: "List",
    src: "/screenshots/list.webp",
    caption: "The classic vertical list, one row per window",
  },
];

// Baked at build time (scripts/fetch-releases.ts, run by the Docker build) so
// the page — including the statically rendered HTML — is correct as of the
// last deploy even when GitHub's API limit is exhausted, which it routinely is.
const baked = channels(snapshot);

// The server snapshot is false and the client's is true, so hydration reads false first.
const subscribeNever = () => () => {};

function useReleases(): Releases {
  const [rel, setRel] = useState<Releases>(baked);

  useEffect(() => {
    // localStorage is read after mount, never during render: the server and the
    // client's first render must agree or hydration throws the markup away.
    const cache = readCache();
    const best = freshest(baked, cache?.rel);
    // oxlint-disable-next-line react/set-state-in-effect -- post-hydration localStorage sync, see above
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

// The product, front and centre: an auto-advancing peek carousel of the three
// switcher layouts, neighbours dimmed at the edges.
function Showcase() {
  const [active, setActive] = useState(0);
  // Each screenshot is ~200 KB. A slide fetches only once it is active or next
  // in line, so landing costs the LCP shot plus the neighbour peeking beside it.
  const [reach, setReach] = useState(1);
  const [paused, setPaused] = useState(false);
  const [hovered, setHovered] = useState(false);
  const [onScreen, setOnScreen] = useState(true);
  const [zoomed, setZoomed] = useState(false);
  const reduced = useReducedMotion();
  // The lightbox portals into document.body, which doesn't exist during the
  // build-time static render. Gate it on mount so SSR stays document-free.
  // The dot fill waits for it too: the server can't know reduced motion.
  const mounted = useSyncExternalStore(
    subscribeNever,
    () => true,
    () => false,
  );

  const section = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = section.current;
    if (!el) return;
    const observer = new IntersectionObserver(([entry]) => setOnScreen(entry.isIntersecting));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

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

  const go = (i: number) => {
    setActive(i);
    setReach((r) => Math.max(r, i + 1));
  };

  const swipeStartX = useRef<number | null>(null);
  // A swipe ends in a click on the slide under the finger; this eats that click.
  const swiped = useRef(false);
  const endSwipe = (x: number) => {
    if (swipeStartX.current === null) return;
    const dx = x - swipeStartX.current;
    swipeStartX.current = null;
    if (Math.abs(dx) < 40) return;
    swiped.current = true;
    go(Math.min(Math.max(active + (dx < 0 ? 1 : -1), 0), layouts.length - 1));
  };

  const autoplay = mounted && !reduced;
  const playing = !paused && !hovered && !zoomed && onScreen;
  const shot = layouts[active];

  return (
    // Starts once the chord is on its way to its slot, under the headline.
    <section
      ref={section}
      className="rise flex flex-col gap-5 [animation-delay:1350ms]"
      aria-label="Switcher layouts"
      aria-roledescription="carousel"
      onPointerEnter={() => setHovered(true)}
      onPointerLeave={() => setHovered(false)}
    >
      {/* The fade spans the 8% peek, so the side slides dissolve instead of being sliced. */}
      <div
        className="touch-pan-y overflow-hidden mask-x-from-92% mask-x-to-100% select-none"
        onPointerDown={(e) => {
          swipeStartX.current = e.clientX;
          swiped.current = false;
        }}
        onPointerUp={(e) => endSwipe(e.clientX)}
        onPointerCancel={() => (swipeStartX.current = null)}
        onClickCapture={(e) => {
          if (!swiped.current) return;
          swiped.current = false;
          e.stopPropagation();
        }}
      >
        <div
          className="flex gap-5 transition-transform duration-1000 ease-[cubic-bezier(0.22,1,0.36,1)] motion-reduce:transition-none"
          // Percentages here are of the track, which is the viewport's width:
          // 8% centres an 84% slide, 84% + the gap steps one slide.
          style={{ transform: `translateX(calc(8% - ${active} * (84% + 1.25rem)))` }}
        >
          {layouts.map((l, i) => (
            <button
              key={l.id}
              type="button"
              tabIndex={i === active ? 0 : -1}
              onClick={() => (i === active ? setZoomed(true) : go(i))}
              aria-label={i === active ? `Enlarge: ${l.caption}` : `Show ${l.label}`}
              // The intrinsic 2000×1043 ratio reserves the height before the
              // image lands.
              className={`relative aspect-[2000/1043] w-[84%] shrink-0 overflow-hidden rounded-[14px] border border-line bg-line p-0 transition-[opacity,scale] duration-1000 ease-[cubic-bezier(0.22,1,0.36,1)] motion-reduce:transition-none ${
                i === active
                  ? "cursor-zoom-in"
                  : "scale-[0.96] cursor-pointer opacity-35 hover:opacity-60"
              }`}
            >
              {/* The first one is the LCP image layout.tsx preloads at
                  fetchpriority=high; nothing here may hide or defer it. */}
              {i <= reach && (
                <img
                  src={l.src}
                  alt={l.caption}
                  className="block h-full w-full object-cover"
                  loading={i === 0 ? "eager" : "lazy"}
                  fetchPriority={i === 0 ? "high" : "auto"}
                  decoding="async"
                  draggable={false}
                />
              )}
            </button>
          ))}
        </div>
      </div>

      <p className="m-0 text-center text-sm text-muted">{shot.caption}</p>

      <div className="flex items-center justify-center gap-3.5">
        <div className="flex gap-4 rounded-full bg-text/5 px-4 py-3">
          {layouts.map((l, i) => (
            <button
              key={l.id}
              type="button"
              aria-label={l.label}
              aria-current={i === active}
              onClick={() => go(i)}
              className={`relative h-2 cursor-pointer overflow-hidden rounded-full border-0 bg-text/20 p-0 transition-[width] duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${
                i === active ? "w-11" : "w-2 hover:bg-text/40"
              }`}
            >
              {i === active && autoplay && (
                <span
                  className="absolute inset-0 origin-left animate-[dot-fill_5s_linear_forwards] bg-text"
                  style={{ animationPlayState: playing ? "running" : "paused" }}
                  onAnimationEnd={() => go((active + 1) % layouts.length)}
                />
              )}
            </button>
          ))}
        </div>
        <button
          type="button"
          aria-label={paused ? "Play" : "Pause"}
          onClick={() => setPaused((p) => !p)}
          className={`grid size-9 cursor-pointer place-items-center rounded-full border-0 bg-text/5 p-0 text-text transition-colors duration-200 hover:bg-text/10 ${
            mounted && reduced ? "hidden" : ""
          }`}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            {paused ? (
              <path d="M3 1.5v9l7.5-4.5z" />
            ) : (
              <>
                <rect x="2" y="1" width="3" height="10" rx="1" />
                <rect x="7" y="1" width="3" height="10" rx="1" />
              </>
            )}
          </svg>
        </button>
      </div>

      {mounted &&
        createPortal(
          <AnimatePresence>
            {zoomed && (
              <motion.div
                className="fixed inset-0 z-50 flex cursor-zoom-out items-center justify-center bg-[rgba(250,249,246,0.88)] p-6 backdrop-blur-[6px]"
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

function DownloadCta({
  href,
  channel,
  onChange,
  stable,
  beta,
}: {
  href: string;
  channel: "stable" | "beta";
  onChange: (channel: "stable" | "beta") => void;
  stable: Channel;
  beta: Channel | null;
}) {
  const isBeta = channel === "beta";
  const version = isBeta && beta ? beta.version : stable.version;
  return (
    <div className="flex flex-wrap items-center gap-x-5 gap-y-3">
      <div
        className={`relative inline-flex h-12 rounded-2xl transition-colors ${CHANNEL_SWAP} ${
          isBeta ? "bg-surface has-[a:hover]:bg-pro/5" : "bg-text has-[a:hover]:bg-[#3a3833]"
        }`}
      >
        <span
          aria-hidden
          className={`pointer-events-none beta-blueprint absolute inset-0 rounded-2xl transition-opacity ${CHANNEL_SWAP} ${
            isBeta ? "opacity-100" : "opacity-0"
          }`}
        />
        <DownloadButton
          href={href}
          size="lg"
          className={`bg-transparent max-[420px]:px-4 max-[360px]:px-3 max-[360px]:text-[15px] ${CHANNEL_SWAP} ${isBeta ? "text-text hover:text-text" : "text-bg hover:text-bg"}`}
        />
        {beta && (
          <div
            role="group"
            aria-label="Release channel"
            className={`relative m-[5px] grid grid-cols-2 rounded-[11px] p-[3px] transition-colors ${CHANNEL_SWAP} ${
              isBeta
                ? "bg-[color-mix(in_oklab,var(--color-pro)_10%,var(--color-surface))]"
                : "bg-white/12"
            }`}
          >
            <span
              aria-hidden
              className={`absolute inset-y-[3px] left-[3px] w-[calc(50%-3px)] rounded-lg shadow-[0_1px_2px_rgba(0,0,0,0.15)] transition-[translate,background-color] motion-reduce:transition-colors ${CHANNEL_SWAP} ${
                isBeta ? "translate-x-full bg-text" : "bg-bg"
              }`}
            />
            <ChannelSegment
              label="Stable"
              active={!isBeta}
              onLight={isBeta}
              onSelect={() => onChange("stable")}
            />
            <ChannelSegment
              label="Beta"
              active={isBeta}
              onLight={isBeta}
              onSelect={() => onChange("beta")}
            />
          </div>
        )}
      </div>
      {version && (
        <RollingText
          className="text-[13px] text-muted tabular-nums"
          text={formatVersion(version)}
        />
      )}
    </div>
  );
}

// Chars keyed by index+char, so only the ones that differ roll when the channel flips.
function RollingText({ text, className }: { text: string; className: string }) {
  const chars = [...text];
  return (
    <span className={className}>
      <span className="sr-only">{text}</span>
      <span aria-hidden className="relative inline-flex overflow-hidden whitespace-pre">
        <AnimatePresence mode="popLayout" initial={false}>
          {chars.map((char, i) => (
            <motion.span
              key={`${i}:${char}`}
              initial={{ y: "100%", opacity: 0 }}
              animate={{ y: 0, opacity: 1 }}
              exit={{ y: "-100%", opacity: 0 }}
              transition={{ duration: 0.28, ease: EASE, delay: i * 0.02 }}
              className="inline-block"
            >
              {char}
            </motion.span>
          ))}
        </AnimatePresence>
      </span>
    </span>
  );
}

function formatVersion(version: string) {
  return version.replace(/^v/, "").replace("-beta.", " beta ");
}

function ChannelSegment({
  label,
  active,
  onLight,
  onSelect,
}: {
  label: string;
  active: boolean;
  onLight: boolean;
  onSelect: () => void;
}) {
  let text = active ? "text-text" : "text-bg/70 hover:text-bg";
  if (onLight) text = active ? "text-bg" : "text-muted hover:text-text";
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onSelect}
      className={`relative cursor-pointer rounded-lg border-0 bg-transparent px-3 text-[13px] font-semibold transition-colors max-[420px]:px-2.5 max-[360px]:px-1.5 ${CHANNEL_SWAP} ${text}`}
    >
      {label}
    </button>
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

// Copy-to-clipboard that remembers the copied text for 1.6 s. clipboard access
// lives inside the returned callback, so this stays SSR-safe during the
// static render (no top-level navigator/window reference).
function useCopy(): [string | null, (text: string) => void] {
  const [copied, setCopied] = useState<string | null>(null);
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
        setCopied(text);
        if (timer.current !== undefined) window.clearTimeout(timer.current);
        timer.current = window.setTimeout(() => setCopied(null), 1600);
      })
      // Denied permission or an unfocused document rejects here; swallowing it
      // keeps the button honest (it just never says "Copied") instead of
      // raising an unhandled rejection.
      .catch(() => {});
  };

  return [copied, copy];
}

function BrewCmd({ beta }: { beta: boolean }) {
  const [copiedText, copy] = useCopy();
  const command = beta ? `${BREW}@beta` : BREW;
  // Switching channel changes the command, so the stale "Copied" drops back to "Copy".
  const copied = copiedText === command;
  return (
    <p className="m-0 flex flex-wrap items-center gap-x-2.5 text-[14px] text-muted">
      or
      <code className="relative font-mono text-[13.5px] text-text [font-variant-ligatures:none]">
        {BREW}
        <AnimatePresence mode="popLayout" initial={false}>
          {beta && (
            <motion.span
              initial={{ opacity: 0, clipPath: "inset(0 100% 0 0)" }}
              animate={{ opacity: 1, clipPath: "inset(0 0% 0 0)" }}
              exit={{ opacity: 0, clipPath: "inset(0 100% 0 0)" }}
              transition={{ duration: 0.22, ease: EASE }}
              className="inline-block text-pro"
            >
              @beta
            </motion.span>
          )}
        </AnimatePresence>
      </code>
      {/* borderRadius in style so Motion's layout scale correction keeps the corners round. */}
      <motion.button
        layout
        type="button"
        onClick={() => copy(command)}
        whileTap={{ scale: 0.96 }}
        transition={{ duration: 0.22, ease: EASE }}
        style={{ borderRadius: 6 }}
        className="-ml-1 inline-flex cursor-pointer items-center gap-1.5 overflow-hidden border-0 bg-transparent px-2 py-1 text-[13px] text-muted transition-colors duration-150 hover:bg-text/5 hover:text-text"
      >
        <AnimatePresence mode="popLayout" initial={false}>
          <motion.span
            key={copied ? "copied" : "copy"}
            layout="position"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={{ duration: 0.18, ease: EASE }}
            className={`inline-flex items-center gap-1.5 ${copied ? "text-accent" : ""}`}
          >
            {copied ? <CheckGlyph /> : <CopyGlyph />}
            {copied ? "Copied" : "Copy"}
          </motion.span>
        </AnimatePresence>
        <span aria-live="polite" className="sr-only">
          {copied ? "Copied to clipboard" : ""}
        </span>
      </motion.button>
    </p>
  );
}

// Same origin, served by the docs app rather than this static export — plain
// anchors so the browser does a real navigation instead of the router
// swallowing it.
const DOCS = "/docs";

// Paths are relative to DOCS; the quick start is the docs landing page, hence
// the bare slash. Every one ends in a slash to match the docs' canonical URLs
// — the bare form is a 301 on both deploy targets, and an internal link should
// not spend a redirect.
const docsLinks: Array<[string, string, string]> = [
  ["Quick start", "Install, permissions, your first switch", "/"],
  ["Config file", "How the live two-way sync works", "/configuration/"],
  ["Config reference", "Every key, with types and defaults", "/config-reference/"],
  ["Per-shortcut overrides", "A different switcher on every hotkey", "/overrides/"],
];

// Real config keys and values (App/Preferences.swift). Clicking a value in the
// demo file steps to the next entry; the first entry is what the demo opens on.
const configChoices = {
  layoutMode: ["list", "iconDock", "windowPreview"],
  sortOrder: ["mru", "alphabetical", "launchOrder"],
  panelOpacity: [100, 80, 60, 40],
} as const;

type ConfigKey = keyof typeof configChoices;

const configKeys: Array<ConfigKey> = ["layoutMode", "sortOrder", "panelOpacity"];

// `icon` is the column in /demo/apps.webp and the N in /demo/win-N.webp.
const demoApps = [
  {
    name: "Helium",
    title: "BetterCmdTab: a better Cmd+Tab",
    icon: 1,
    launched: 3,
    badge: "",
    audio: false,
  },
  {
    name: "Ghostty",
    title: "~/Developer/BetterCmdTab",
    icon: 0,
    launched: 0,
    badge: "",
    audio: false,
  },
  {
    name: "Code",
    title: "GeneralSettingsViewController.swift",
    icon: 2,
    launched: 2,
    badge: "",
    audio: false,
  },
  { name: "Spotify", title: "Gibbs - Pył gwiazd", icon: 3, launched: 1, badge: "", audio: true },
  { name: "Mail", title: "All Inboxes, 1 unread", icon: 4, launched: 4, badge: "1", audio: false },
  { name: "Discord", title: "Friends", icon: 5, launched: 5, badge: "1", audio: false },
];

type DemoApp = (typeof demoApps)[number];

function sortDemoApps(order: string): Array<DemoApp> {
  const apps = [...demoApps];
  if (order === "alphabetical") apps.sort((a, b) => a.name.localeCompare(b.name));
  if (order === "launchOrder") apps.sort((a, b) => a.launched - b.launched);
  return apps;
}

// The screenshots' wallpaper in gradients: warm sand left, slate bottom, pale
// right, with the two bright fold edges as thin arcs.
const STAGE_BG = [
  "radial-gradient(120% 95% at -12% 118%, transparent 58%, rgba(255,246,230,0.6) 59.5%, transparent 62%)",
  "radial-gradient(105% 85% at 112% -22%, transparent 56%, rgba(255,250,240,0.55) 57.5%, transparent 60%)",
  "radial-gradient(60% 55% at 55% 108%, #43415a 0, #535365 35%, transparent 100%)",
  "radial-gradient(45% 70% at 104% 55%, #d8d7d0 0, transparent 100%)",
  "radial-gradient(55% 60% at 38% 0%, #e4d6c1 0, transparent 100%)",
  "radial-gradient(50% 70% at 0% 50%, #b08b57 0, transparent 100%)",
  "linear-gradient(160deg, #7a573b, #8a7462 45%, #6c6f86)",
].join(", ");

// config.json on the left, a switcher on the right that rebuilds from it the
// moment a value changes, which is the "edits apply live" claim, shown.
function LiveConfig() {
  const [picked, setPicked] = useState<Record<ConfigKey, number>>({
    layoutMode: 0,
    sortOrder: 0,
    panelOpacity: 0,
  });
  // `n` remounts the edited line, which restarts its flash.
  const [edit, setEdit] = useState<{ key: ConfigKey; n: number } | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!saving) return;
    const timer = setTimeout(() => setSaving(false), 400);
    return () => clearTimeout(timer);
  }, [saving, edit]);

  const valueOf = (key: ConfigKey) => configChoices[key][picked[key]];

  const change = (key: ConfigKey) => {
    setPicked((p) => ({ ...p, [key]: (p[key] + 1) % configChoices[key].length }));
    setEdit((e) => ({ key, n: (e?.n ?? 0) + 1 }));
    setSaving(true);
  };

  let status = "saved";
  if (saving) status = "saving";
  else if (edit) status = "saved, applied";

  return (
    <div className="grid grid-cols-[minmax(0,1.15fr)_74px_minmax(0,1fr)] max-[860px]:grid-cols-1">
      <div className="flex flex-col gap-3.5">
        <div className="overflow-hidden rounded-[14px] border border-line bg-surface">
          <div className="flex h-[38px] items-center gap-2 border-b border-line bg-bg px-3.5 text-[12.5px] text-muted">
            <span className="mr-2 flex gap-[7px]" aria-hidden>
              <i className="size-[11px] rounded-full bg-line" />
              <i className="size-[11px] rounded-full bg-line" />
              <i className="size-[11px] rounded-full bg-line" />
            </span>
            <span className="truncate font-mono">
              ~/.config/bettercmdtab/<b className="font-medium text-text">config.json</b>
            </span>
            <span
              aria-live="polite"
              className={`ml-auto flex flex-none items-center gap-1.5 text-[12px] transition-colors duration-200 ${
                saving ? "text-muted" : "text-text"
              }`}
            >
              <i
                aria-hidden
                className={`size-1.5 rounded-full transition-colors duration-200 ${
                  saving ? "bg-muted" : "bg-[#16a34a]"
                }`}
              />
              {status}
            </span>
          </div>

          <div className="py-3.5 font-mono text-[13px] leading-[1.8]">
            <CodeLine n={1}>
              <span className="text-muted">{"{"}</span>
            </CodeLine>
            {configKeys.map((key, i) => {
              const value = valueOf(key);
              const flashing = edit?.key === key;
              return (
                <CodeLine
                  key={flashing ? `${key}-${edit.n}` : key}
                  n={i + 2}
                  className={flashing ? "animate-[line-flash_0.9s_ease-out]" : ""}
                >
                  {"  "}
                  <span className="text-text">"{key}"</span>
                  <span className="text-muted">: </span>
                  <button
                    type="button"
                    onClick={() => change(key)}
                    aria-label={`${key} is ${value}, change it`}
                    className="-mx-[3px] cursor-pointer rounded-[5px] border-0 bg-transparent px-[3px] py-px font-mono shadow-[inset_0_-1px_0_rgba(37,99,235,0.55)] transition-colors duration-150 hover:bg-accent/20 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
                  >
                    {typeof value === "string" ? (
                      <span className="text-accent">"{value}"</span>
                    ) : (
                      <span className="text-dim">{value}</span>
                    )}
                  </button>
                  {i < configKeys.length - 1 && <span className="text-muted">,</span>}
                </CodeLine>
              );
            })}
            <CodeLine n={configKeys.length + 2}>
              <span className="text-muted">{"}"}</span>
            </CodeLine>
          </div>
        </div>
        <p className="m-0 text-[13px] text-muted">
          Click any{" "}
          <span className="text-text shadow-[inset_0_-1px_0_rgba(37,99,235,0.7)]">
            underlined value
          </span>{" "}
          to change it.
        </p>
      </div>

      <div
        aria-hidden
        className="relative grid place-items-center before:absolute before:inset-x-0 before:top-1/2 before:h-px before:bg-[linear-gradient(90deg,var(--color-line),var(--color-accent),var(--color-line))] max-[860px]:h-14 max-[860px]:before:inset-x-auto max-[860px]:before:inset-y-0 max-[860px]:before:left-1/2 max-[860px]:before:h-auto max-[860px]:before:w-px"
      >
        <span
          className={`relative rounded-[6px] border bg-bg px-[7px] py-0.5 font-mono text-[11px] transition-colors duration-200 ${
            saving ? "border-accent text-text" : "border-line text-muted"
          }`}
        >
          live
        </span>
      </div>

      <div
        className="grid min-h-[340px] place-items-center overflow-hidden rounded-[14px] p-4"
        style={{ background: STAGE_BG }}
      >
        <MiniSwitcher
          layout={configChoices.layoutMode[picked.layoutMode]}
          apps={sortDemoApps(configChoices.sortOrder[picked.sortOrder])}
          opacity={configChoices.panelOpacity[picked.panelOpacity]}
        />
      </div>
    </div>
  );
}

function CodeLine({
  n,
  className = "",
  children,
}: {
  n: number;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={`grid grid-cols-[44px_1fr] whitespace-pre ${className}`}>
      <span aria-hidden className="pr-3 text-right text-muted/60 select-none">
        {n}
      </span>
      <span>{children}</span>
    </div>
  );
}

function MiniSwitcher({
  layout,
  apps,
  opacity,
}: {
  layout: string;
  apps: Array<DemoApp>;
  opacity: number;
}) {
  return (
    <div
      role="img"
      aria-label={`Switcher preview, ${layout} layout, ${apps.map((a) => a.name).join(", ")}`}
      className="rounded-[20px] border border-white/20 p-2.5 text-white shadow-[0_30px_70px_-24px_rgba(20,12,4,0.6),inset_0_1px_0_rgba(255,255,255,0.18)] backdrop-blur-[30px] backdrop-saturate-[1.4] transition-[background-color] duration-300"
      style={{ backgroundColor: `rgba(34, 30, 27, ${(0.42 * opacity) / 100 + 0.04})` }}
    >
      {layout === "list" &&
        apps.map((app, i) => (
          <div
            key={app.name}
            className={`grid h-[30px] w-[340px] grid-cols-[60px_17px_1fr_auto] items-center gap-2.5 rounded-[8px] px-2.5 text-[13px] max-[520px]:w-[270px] max-[360px]:w-[226px] ${
              i === 1 ? "bg-[#3b7ef4]" : ""
            }`}
          >
            <span className="truncate text-right">{app.name}</span>
            <AppIcon icon={app.icon} className="size-[17px]" />
            <span className="truncate">{app.title}</span>
            <Indicators app={app} selected={i === 1} />
          </div>
        ))}
      {layout === "iconDock" && (
        <div className="flex gap-1.5">
          {apps.map((app, i) => (
            <div
              key={app.name}
              className={`w-[60px] text-center text-[10.5px] leading-tight max-[520px]:w-[42px] ${
                i === 1 ? "font-semibold text-white" : "text-white/70"
              }`}
            >
              <span
                className={`mx-auto mb-1.5 flex size-[52px] rounded-[13px] p-[5px] max-[520px]:size-9 max-[520px]:p-1 ${
                  i === 1 ? "bg-[#3b7ef4]/35 shadow-[inset_0_0_0_1.5px_rgba(99,150,255,0.8)]" : ""
                }`}
              >
                <AppIcon icon={app.icon} className="size-full" />
              </span>
              <span className="block truncate">{app.name}</span>
              <span className="mt-px block truncate text-[9px] font-normal text-white/60">
                {app.title}
              </span>
            </div>
          ))}
        </div>
      )}
      {layout === "windowPreview" && (
        <div className="grid grid-cols-[repeat(3,100px)] gap-x-2 gap-y-2.5 max-[520px]:grid-cols-[repeat(3,80px)]">
          {apps.map((app, i) => (
            <div key={app.name} className="text-[9.5px]">
              <img
                src={`/demo/win-${app.icon}.webp`}
                alt=""
                width={100}
                height={62}
                loading="lazy"
                className={`block h-[62px] w-full rounded-[6px] object-cover max-[520px]:h-12 ${
                  i === 1 ? "ring-2 ring-white/85" : ""
                }`}
              />
              <span
                className={`mt-1.5 flex items-center justify-center gap-1 overflow-hidden whitespace-nowrap ${
                  i === 1 ? "text-white" : "text-white/70"
                }`}
              >
                <AppIcon icon={app.icon} className="size-3" />
                <span className="truncate">
                  {app.name} – {app.title}
                </span>
                {app.badge && <Badge text={app.badge} />}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// SwitcherIndicators.swift: audio is systemGreen, except on the opaque list selection.
function Indicators({ app, selected }: { app: DemoApp; selected: boolean }) {
  return (
    <span className="flex items-center gap-1.5">
      {app.audio && (
        <svg
          aria-hidden="true"
          viewBox="0 0 16 16"
          className={`size-3.5 ${selected ? "text-white/90" : "text-[#30d158]"}`}
        >
          <path d="M1.5 6h2.6L7.5 3v10L4.1 10H1.5z" fill="currentColor" />
          <path
            d="M10 5.8a3 3 0 0 1 0 4.4M12.2 3.8a6 6 0 0 1 0 8.4"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.4"
            strokeLinecap="round"
          />
        </svg>
      )}
      {app.badge && <Badge text={app.badge} />}
    </span>
  );
}

function Badge({ text }: { text: string }) {
  return (
    <span className="grid h-4 min-w-4 flex-none place-items-center rounded-full bg-[#ff3b30] px-[5px] text-[10px] font-semibold text-white">
      {text}
    </span>
  );
}

function Docs() {
  return (
    <section
      id="config"
      className="dark -mx-6 rounded-[28px] px-14 py-16 max-[860px]:rounded-none max-[860px]:px-6 max-[860px]:py-14"
    >
      <h2 className={H2}>Configure it in a file.</h2>
      <p className="m-0 -mt-3 mb-11 max-w-[54ch] text-[17px] text-muted">
        Every setting lives in a plain JSON file you can diff, version and keep in your dotfiles.
        Save it and the switcher changes, no restart. Change a setting in the app and the file is
        written back.
      </p>

      <LiveConfig />

      <nav
        aria-label="Configuration docs"
        className="mt-11 grid grid-cols-4 border-t border-line max-[860px]:grid-cols-2 max-[860px]:gap-y-4"
      >
        {docsLinks.map(([title, desc, path], i) => (
          <div
            key={title}
            className={
              i > 0 ? "border-l border-line pl-5 max-[860px]:border-l-0 max-[860px]:pl-0" : ""
            }
          >
            <a className="group/doc block border-0 pt-[18px] pr-5" href={`${DOCS}${path}`}>
              <span className="block font-medium text-text transition-colors duration-150 group-hover/doc:text-accent">
                {title}
                <span
                  aria-hidden
                  className="ml-1.5 inline-block text-muted transition-transform duration-200 group-hover/doc:translate-x-1 motion-reduce:transition-none"
                >
                  →
                </span>
              </span>
              <span className="mt-0.5 block text-[13px] text-muted">{desc}</span>
            </a>
          </div>
        ))}
      </nav>
    </section>
  );
}

type Mark = "yes" | "no" | "pro";
type Cell = Mark | [mark: Mark, label: ReactNode];

const markLabel: Record<Mark, string> = { yes: "Yes", no: "No", pro: "Pro" };

const products: Array<{ name: string; proPrice?: string }> = [
  { name: "BetterCmdTab" },
  { name: "Built-in" },
  { name: "AltTab", proPrice: "$9.99" },
];

type Row = [feature: ReactNode, cells: [ours: Cell, builtIn: Cell, altTab: Cell]];

// AltTab cells follow alt-tab.app (Free vs Pro table, /features) and lwouis/alt-tab-macos@56891e0
// (Pro gates in src/pro/ProFeature.swift, settings in src/preferences/Preferences.swift).
const comparisonGroups: Array<{ label: string; rows: Array<Row> }> = [
  {
    label: "switching",
    rows: [
      ["Switch windows, not just apps", ["yes", ["no", "Current app only"], "yes"]],
      ["Tap to switch, hold to open", ["yes", "yes", "yes"]],
      [
        <>
          Stay open after releasing <Kbd>⌘</Kbd>
        </>,
        ["yes", "no", "yes"],
      ],
      [
        "Cycle the front app's windows",
        ["yes", ["yes", <Kbd key="cmd-backtick">⌘`</Kbd>], ["pro", "Pro, extra shortcut"]],
      ],
      ["Type to search", ["yes", "no", "pro"]],
      ["Launch any installed app", ["yes", "no", "no"]],
      ["Multiple shortcuts", ["yes", "no", ["pro", "Pro, up to 9"]]],
      ["Hotkey per app", ["yes", "no", "no"]],
      ["Trackpad swipe to open", ["yes", "no", "yes"]],
    ],
  },
  {
    label: "layouts",
    rows: [
      ["Live window previews", ["yes", "no", "yes"]],
      ["App icon grid", ["yes", "yes", "pro"]],
      ["Window title list", ["yes", "no", "pro"]],
    ],
  },
  {
    label: "tabs",
    rows: [
      ["Browser tab drill-in", ["yes", "no", "no"]],
      ["Tabs as separate rows", ["yes", "no", ["yes", "Native tabs only"]]],
    ],
  },
  {
    label: "windows",
    rows: [
      ["Close, minimize, hide, quit", ["yes", ["no", "Quit and hide only"], "yes"]],
      ["Action buttons on hover", ["yes", "no", "yes"]],
      ["Force quit hung apps", ["yes", "no", "no"]],
      ["Window tiling", ["yes", ["yes", "macOS 15+"], "no"]],
      ["Move window to another display", ["yes", "no", "no"]],
      ["Reopen recently closed apps", ["yes", "no", "no"]],
    ],
  },
  {
    label: "filters",
    rows: [
      ["Minimized and hidden windows", ["yes", "no", "yes"]],
      ["Windows from all Spaces", ["yes", "no", "yes"]],
      ["Sort order options", ["yes", "no", "yes"]],
      ["Pin favorites", ["yes", "no", "no"]],
      ["Per-app hide and ignore rules", ["yes", "no", "yes"]],
    ],
  },
  {
    label: "status",
    rows: [
      ["Dock badge counts", ["yes", "yes", "yes"]],
      ["Playing audio indicator", ["yes", "no", "no"]],
    ],
  },
  {
    label: "system",
    rows: [
      ["Hidden from screen sharing", [["yes", "macOS 14.6+"], "no", "no"]],
      ["Export and import settings", ["yes", "no", "yes"]],
      ["Live JSON config file", ["yes", "no", "no"]],
      ["Open source", ["yes", "no", "yes"]],
    ],
  },
];

const comparison = comparisonGroups.flatMap((group) => group.rows);

function splitCell(cell: Cell): [Mark, ReactNode] {
  return typeof cell === "string" ? [cell, markLabel[cell]] : cell;
}

const labelClass: Record<Mark, string> = { yes: "text-text", no: "text-muted", pro: "text-pro" };

function fillClass(mark: Mark, ours: boolean) {
  if (mark === "pro") return "bg-pro";
  if (mark === "no") return "bg-line";
  return ours ? "bg-accent" : "bg-text";
}

function Compare() {
  const total = comparison.length;
  // Phones show BetterCmdTab against one rival; three columns do not fit.
  const [rival, setRival] = useState(2);
  const phoneHidden = (column: number) =>
    column === 0 || column === rival ? "" : "max-[640px]:hidden";
  return (
    <section id="compare">
      <h2 className={H2}>Compared.</h2>
      <div
        role="group"
        aria-label="Compare with"
        className="mb-5 hidden grid-cols-2 rounded-[10px] bg-line/70 p-[3px] max-[640px]:grid"
      >
        {[2, 1].map((column) => (
          <button
            key={column}
            type="button"
            aria-pressed={rival === column}
            onClick={() => setRival(column)}
            className={`cursor-pointer rounded-lg border-0 py-2 text-[13px] font-medium transition-colors ${
              rival === column
                ? "bg-surface text-text shadow-[0_1px_2px_rgba(0,0,0,0.15)]"
                : "bg-transparent text-dim"
            }`}
          >
            vs {products[column].name}
          </button>
        ))}
      </div>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[620px] table-fixed border-collapse text-[14px] max-[640px]:block max-[640px]:min-w-0">
          <colgroup>
            <col className="w-[34%]" />
            <col />
            <col />
            <col />
          </colgroup>
          <thead className="max-[640px]:block">
            <tr className="border-b border-line max-[640px]:grid max-[640px]:grid-cols-2 max-[640px]:gap-x-4">
              <th
                scope="col"
                className="pb-5 text-left align-bottom font-mono text-[12px] font-normal text-muted max-[640px]:hidden"
              >
                {total} features
              </th>
              {products.map((product, column) => {
                const ours = column === 0;
                const marks = comparison.map(([, cells]) => splitCell(cells[column])[0]);
                const yes = marks.filter((mark) => mark === "yes").length;
                const pro = marks.filter((mark) => mark === "pro").length;
                return (
                  <th
                    key={product.name}
                    scope="col"
                    className={`px-4 pb-5 text-left align-bottom font-normal max-[640px]:px-0 ${phoneHidden(column)}`}
                  >
                    <div className={`text-[15px] font-semibold ${ours ? "text-accent" : ""}`}>
                      {product.name}
                    </div>
                    <div className="mt-2.5 text-[34px] leading-[1.1] font-bold tracking-[-0.03em] tabular-nums">
                      {yes}
                      <span className="text-[15px] font-medium tracking-normal text-muted">
                        {" "}
                        / {total}
                      </span>
                    </div>
                    <div aria-hidden="true" className="mt-2.5 flex h-1 gap-0.5">
                      <i
                        className={`rounded-[1px] ${fillClass("yes", ours)}`}
                        style={{ flexGrow: yes }}
                      />
                      {pro > 0 && <i className="rounded-[1px] bg-pro" style={{ flexGrow: pro }} />}
                      <i
                        className="rounded-[1px] bg-line"
                        style={{ flexGrow: total - yes - pro }}
                      />
                    </div>
                    <div className="mt-2 text-[12px] text-muted">
                      {pro > 0 ? `+${pro} with Pro, ${product.proPrice}` : "Free"}
                    </div>
                  </th>
                );
              })}
            </tr>
          </thead>
          {comparisonGroups.map((group) => (
            <tbody key={group.label} className="max-[640px]:block">
              <tr className="max-[640px]:block">
                <th
                  scope="rowgroup"
                  colSpan={4}
                  className="pt-8 pb-2.5 text-left font-mono text-[12px] font-normal text-muted max-[640px]:block"
                >
                  {group.label}
                </th>
              </tr>
              {group.rows.map(([feature, cells], row) => (
                <tr
                  key={row}
                  className="border-b border-line/60 max-[640px]:grid max-[640px]:grid-cols-2 max-[640px]:gap-x-4 max-[640px]:gap-y-1 max-[640px]:py-2.5"
                >
                  <th
                    scope="row"
                    className="py-[11px] pr-4 text-left font-normal text-dim max-[640px]:col-span-2 max-[640px]:p-0"
                  >
                    {feature}
                  </th>
                  {cells.map((cell, column) => {
                    const [mark, label] = splitCell(cell);
                    return (
                      <td
                        key={products[column].name}
                        className={`px-4 py-[11px] max-[640px]:p-0 max-[640px]:text-[13px] ${phoneHidden(column)}`}
                      >
                        <span
                          aria-hidden="true"
                          className={`mr-2.5 inline-block size-2 rounded-full align-[1px] ${
                            mark === "no"
                              ? "shadow-[inset_0_0_0_1.5px_#cfcac0]"
                              : fillClass(mark, column === 0)
                          }`}
                        />
                        <span className={labelClass[mark]}>{label}</span>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          ))}
        </table>
      </div>
    </section>
  );
}

const downloadFmt = new Intl.NumberFormat("en-US");

function useHeldKeys() {
  const [held, setHeld] = useState(NO_KEYS);
  useEffect(() => {
    const set = (key: string, down: boolean) => {
      if (key === "Meta") setHeld((h) => (h.meta === down ? h : { ...h, meta: down }));
      if (key === "Tab") setHeld((h) => (h.tab === down ? h : { ...h, tab: down }));
    };
    const onDown = (e: KeyboardEvent) => set(e.key, true);
    const onUp = (e: KeyboardEvent) => set(e.key, false);
    // Cmd+Tab away from the page never delivers the keyup.
    const onBlur = () => setHeld(NO_KEYS);
    window.addEventListener("keydown", onDown);
    window.addEventListener("keyup", onUp);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onDown);
      window.removeEventListener("keyup", onUp);
      window.removeEventListener("blur", onBlur);
    };
  }, []);
  return held;
}

const HOME_WORD = headlineWords.indexOf("⌘Tab");

// The headline cycles like the switcher: tab moves the selection, a pause activates it.
// Its own component so a tab press re-renders four words, not Home.
function SwitcherHeadline() {
  const [selected, setSelected] = useState(HOME_WORD);
  const [activated, setActivated] = useState(false);

  useEffect(() => {
    let settle = 0;
    let back = 0;
    const reset = () => {
      clearTimeout(settle);
      clearTimeout(back);
      setActivated(false);
    };
    const onDown = (e: KeyboardEvent) => {
      if (e.key !== "Tab" || e.repeat) return;
      reset();
      const step = e.shiftKey ? -1 : 1;
      setSelected((i) => (i + step + headlineWords.length) % headlineWords.length);
      settle = window.setTimeout(() => {
        setActivated(true);
        back = window.setTimeout(() => {
          setActivated(false);
          setSelected(HOME_WORD);
        }, 220);
      }, 1100);
    };
    const onBlur = () => {
      reset();
      setSelected(HOME_WORD);
    };
    window.addEventListener("keydown", onDown);
    window.addEventListener("blur", onBlur);
    return () => {
      reset();
      window.removeEventListener("keydown", onDown);
      window.removeEventListener("blur", onBlur);
    };
  }, []);

  return (
    <h1 className="isolate m-0 text-[clamp(40px,7vw,88px)] leading-[1.02] font-bold tracking-[-0.04em]">
      {headlineWords.map((word, i) => (
        <Fragment key={word}>
          {i === 2 ? <br /> : i > 0 && " "}
          <span className="enter inline-block" style={{ animationDelay: `${1250 + i * 60}ms` }}>
            <span
              className={`relative inline-block transition-[color,scale] duration-150 motion-reduce:transition-none ${
                i === selected ? "text-accent" : ""
              } ${i === selected && activated ? "scale-[1.06]" : ""}`}
            >
              {i === selected && (
                <motion.span
                  layoutId="headline-selection"
                  transition={{ duration: 0.18, ease: EASE }}
                  className="absolute -inset-x-[0.08em] inset-y-0 -z-10 rounded-[0.14em] bg-accent/13"
                />
              )}
              {word}
            </span>
          </span>
        </Fragment>
      ))}
    </h1>
  );
}

// Static twin of Keycap for shortcuts shown inline in text.
function Kbd({ children }: { children: ReactNode }) {
  return (
    <kbd className="inline-flex h-[22px] min-w-[22px] items-center justify-center rounded-[6px] border border-b-2 border-[#d6d1c7] bg-[linear-gradient(#ffffff,#f1eee8)] px-1.5 align-[1px] font-sans text-[12px] leading-none font-medium tracking-[0.04em] text-text shadow-[inset_0_1px_0_rgba(255,255,255,0.9)]">
      {children}
    </kbd>
  );
}

type HeldKeys = { meta: boolean; tab: boolean };
const NO_KEYS: HeldKeys = { meta: false, tab: false };

// Hold command, tap tab twice, let go: the gesture the page is selling.
const CHORD_TAPS: Array<[number, HeldKeys]> = [
  [0, { meta: true, tab: false }],
  [260, { meta: true, tab: true }],
  [420, { meta: true, tab: false }],
  [620, { meta: true, tab: true }],
  [780, { meta: true, tab: false }],
  [1100, NO_KEYS],
];

// Plays CHORD_TAPS once in view and again on hover; real key presses still show.
function PlayingChord({ className }: { className: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, amount: 0.8 });
  const reduceMotion = useReducedMotion();
  const [run, setRun] = useState(0);
  const [keys, setKeys] = useState(NO_KEYS);

  useEffect(() => {
    if (!inView || reduceMotion) return;
    const timers = CHORD_TAPS.map(([at, next]) => setTimeout(() => setKeys(next), at + 350));
    return () => {
      timers.forEach(clearTimeout);
      setKeys(NO_KEYS);
    };
  }, [inView, reduceMotion, run]);

  return (
    <div ref={ref} onPointerEnter={() => setRun((r) => r + 1)}>
      <Chord className={className} pressed={keys} />
    </div>
  );
}

// Inline in the prerendered HTML so it starts at first paint, not after hydration:
// the keys pop in one by one at the viewport centre, play ⌘ held + tab tapped, then the
// chord arcs into its slot.
// The glide splits x (`translate`, leads) from y (`transform`, lags) so the
// path curves under, not over; opacity and filter are pinned so the chord's CSS `enter` stays overridden.
const CHORD_INTRO = `(() => {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const chord = document.currentScript.previousElementSibling;
  const r = chord.getBoundingClientRect();
  const x = innerWidth / 2 - r.left - r.width / 2;
  const y = innerHeight / 2 - r.top - r.height / 2;
  const hold = 1150 / 1900;
  chord.animate([
    { opacity: 1, filter: "none", transform: \`translateY(\${y}px)\`, scale: 1 },
    { offset: hold, transform: \`translateY(\${y}px)\`, scale: 1, easing: "cubic-bezier(0.55, 0, 0.25, 1)" },
    { offset: 0.78, scale: 1.03, easing: "ease-in-out" },
    { opacity: 1, filter: "none", transform: "translateY(0)", scale: 1 },
  ], 1900);
  chord.animate([
    { translate: \`\${x}px 0\` },
    { offset: hold, translate: \`\${x}px 0\`, easing: "cubic-bezier(0.4, 0, 0.1, 1)" },
    { translate: "0 0" },
  ], 1900);
  const [cmd, tab] = chord.children;
  [cmd, tab].forEach((key, i) => key.animate([
    { opacity: 0, filter: "blur(6px)", transform: \`scale(0.5) rotate(\${i ? 8 : -8}deg)\` },
    { opacity: 1, filter: "blur(0)", transform: "none" },
  ], { duration: 550, delay: i * 140, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)", fill: "backwards" }));
  const down = { translate: "0 0.03em", borderBottomWidth: "0.015em", borderColor: "var(--color-accent)" };
  const press = (key, at, held) => key.animate([
    { ...down, offset: 40 / (held + 100) },
    { ...down, offset: held / (held + 100) },
  ], { duration: held + 100, delay: at });
  press(cmd, 750, 350);
  press(tab, 900, 100);
})()`;

// Sized in em, so the parent's font-size sets the whole chord.
function Chord({ className, pressed = NO_KEYS }: { className: string; pressed?: HeldKeys }) {
  const held = useHeldKeys();
  return (
    <div aria-hidden="true" className={`flex items-end gap-[0.08em] leading-none ${className}`}>
      <Keycap down={held.meta || pressed.meta} glyph="⌘" label="command" className="w-[0.92em]" />
      <Keycap down={held.tab || pressed.tab} label="tab" className="w-[1.3em]" />
    </div>
  );
}

function Keycap({
  down,
  glyph,
  label,
  className,
}: {
  down: boolean;
  glyph?: string;
  label: string;
  className: string;
}) {
  return (
    <kbd
      className={`relative block h-[0.84em] rounded-[0.14em] border bg-[linear-gradient(#ffffff,#f1eee8)] font-sans shadow-[inset_0_1px_0_rgba(255,255,255,0.9)] transition-[translate,border-color,border-bottom-width] duration-75 in-[.dark]:bg-[linear-gradient(#171717,#0a0a0a)] in-[.dark]:shadow-[inset_0_1px_0_rgba(255,255,255,0.07)] ${
        down
          ? "translate-y-[0.03em] border-b-[0.015em] border-accent"
          : "border-b-[0.045em] border-[#d6d1c7] in-[.dark]:border-[#2e2e2e]"
      } ${className}`}
    >
      {glyph && (
        <span className="absolute top-[0.5em] right-[0.55em] text-[0.26em] text-text">{glyph}</span>
      )}
      <span className="absolute bottom-[0.9em] left-[1em] text-[0.15em] text-dim">{label}</span>
    </kbd>
  );
}

// Real macOS app icons, one 128px column each: Ghostty, Helium, Code, Spotify,
// Mail, Discord, Xcode.
function AppIcon({ icon, className }: { icon: number; className: string }) {
  return (
    <i
      aria-hidden="true"
      className={`inline-block flex-none bg-[url(/demo/apps.webp)] bg-[length:700%_100%] ${className}`}
      style={{ backgroundPosition: `${(icon * 100) / 6}% 0` }}
    />
  );
}

const FRAME_OUTLINE =
  "M7.8 3h8.4C19.2 3 21 5.1 21 8v8c0 2.9-1.8 5-4.8 5H7.8C4.8 21 3 18.9 3 16V8c0-2.9 1.8-5 4.8-5Z";

function Highlights() {
  return (
    <section id="features">
      <h2 className="sr-only">Features</h2>
      <div className="grid grid-cols-4 gap-x-7 gap-y-16 text-center max-[860px]:grid-cols-2">
        <Highlight title="Windows," rest="not just apps">
          <motion.rect variants={slideIn} x="8" y="3" width="13" height="12.5" rx="3" />
          <motion.g variants={squash(0.05)}>
            <rect x="3" y="8" width="14" height="13" rx="3" className="fill-text" />
            <motion.path variants={draw(0.35, 0.4)} d="M3 12h14" />
          </motion.g>
        </Highlight>
        <Highlight title="Search and" rest="launch anything">
          <motion.g variants={wiggle}>
            <motion.path variants={draw(0, 0.6)} d="M11 3a8 8 0 1 1 0 16a8 8 0 1 1 0-16" />
            <motion.path variants={draw(0.35, 0.3)} d="M16.8 16.8 21 21" />
            <motion.path variants={spinIn} d="M11 8v6M8 11h6" />
          </motion.g>
        </Highlight>
        <Highlight title="Browser tab" rest="drill-in">
          <path d={FRAME_OUTLINE} />
          <path d="M3 8.5h18M9 3v5.5M15 3v5.5" />
          <motion.path variants={tabWalk} d="M17.7 6h0.6" strokeWidth="2" />
          <motion.path variants={draw(0.7, 0.35)} d="M7 13h10" />
          <motion.path variants={draw(0.8, 0.35)} d="M7 16.5h6" />
        </Highlight>
        <Highlight title="List, grid" rest="or previews">
          <motion.g variants={quarterTurn(0.35)}>
            {[
              [3, 3],
              [13.5, 3],
              [13.5, 13.5],
              [3, 13.5],
            ].map(([x, y], i) => (
              <motion.rect
                key={i}
                variants={pop(i * 0.08)}
                x={x}
                y={y}
                width="7.5"
                height="7.5"
                rx="2.2"
              />
            ))}
          </motion.g>
        </Highlight>
        <Highlight title="Badges and" rest="playing audio">
          <motion.g variants={squash(0)}>
            <path d="M13.5 5h-6A4.5 4.5 0 0 0 3 9.5v7A4.5 4.5 0 0 0 7.5 21h7a4.5 4.5 0 0 0 4.5-4.5v-6" />
            <motion.path variants={bar(0.3)} style={{ originY: 1 }} d="M7.5 17v-3" />
            <motion.path variants={bar(0.4)} style={{ originY: 1 }} d="M11 17v-6" />
            <motion.path variants={bar(0.5)} style={{ originY: 1 }} d="M14.5 17v-4" />
          </motion.g>
          <motion.circle variants={badge} cx="18.5" cy="5.5" r="2.5" />
        </Highlight>
        <Highlight title="Every Space," rest="every display">
          <clipPath id="hl-screen-clip">
            <rect x="3.5" y="4.5" width="17" height="11" rx="2" />
          </clipPath>
          <motion.rect variants={squash(0.4)} x="2.5" y="3.5" width="19" height="13" rx="3" />
          <path d="M12 16.5V21M8.5 21h7" />
          <g clipPath="url(#hl-screen-clip)">
            <motion.rect variants={spaceHop} x="6" y="7" width="7" height="5.5" rx="1.4" />
          </g>
        </Highlight>
        <Highlight title="Tiling and" rest="window moves">
          <path d={FRAME_OUTLINE} />
          <motion.path variants={tileSplit} d={TILE_SPLIT} />
        </Highlight>
        <Highlight title="Native and" rest="instant">
          <motion.path
            variants={commandKey}
            d="M6.72 8.84A2.12 2.12 0 1 1 8.84 6.72V17.28A2.12 2.12 0 1 1 6.72 15.16H17.28A2.12 2.12 0 1 1 15.16 17.28V6.72A2.12 2.12 0 1 1 17.28 8.84Z"
          />
        </Highlight>
      </div>
    </section>
  );
}

// Plays "show" once on scroll-in, then "hover" per mouse entry. Every "hover" starts and
// ends at the "show" end state, and a new one waits for the last, so nothing ever jumps.
function Highlight({
  title,
  rest,
  children,
}: {
  title: string;
  rest: string;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, amount: 0.6 });
  const reduceMotion = useReducedMotion();
  const controls = useAnimationControls();
  const busy = useRef(true);

  useEffect(() => {
    if (!inView) return;
    void controls.start("show", reduceMotion ? { duration: 0 } : undefined).then(() => {
      busy.current = Boolean(reduceMotion);
    });
  }, [inView, reduceMotion, controls]);

  function replay() {
    if (busy.current) return;
    busy.current = true;
    void controls.start("hover").then(() => {
      busy.current = false;
    });
  }

  return (
    <motion.div ref={ref} whileHover="lift" onHoverStart={replay}>
      <motion.div
        variants={{ lift: { scale: 1.05, rotate: -3 } }}
        transition={{ type: "spring", bounce: 0.4, duration: 0.5 }}
        className="mx-auto grid size-[92px] place-items-center rounded-[26px] bg-text"
      >
        <motion.svg
          aria-hidden="true"
          viewBox="0 0 24 24"
          initial="hidden"
          animate={controls}
          className="size-12 overflow-visible fill-none stroke-bg stroke-[1.5] [stroke-linecap:round] [stroke-linejoin:round]"
        >
          {children}
        </motion.svg>
      </motion.div>
      <h3 className="m-0 mt-5 text-[24px] leading-[1.18] font-semibold tracking-[-0.02em] max-[520px]:text-[19px]">
        {title}
        <br />
        {rest}
      </h3>
    </motion.div>
  );
}

const spring = { type: "spring", bounce: 0.5, duration: 0.6 } as const;
const wobble = { duration: 0.7, ease: "easeInOut" } as const;

function draw(delay: number, duration: number): Variants {
  return {
    hidden: { pathLength: 0, opacity: 0 },
    show: {
      pathLength: 1,
      opacity: 1,
      transition: { delay, duration, ease: EASE, opacity: { delay, duration: 0.01 } },
    },
    hover: {
      pathLength: [1, 0, 1],
      transition: { delay, duration: duration * 1.6, ease: "easeInOut" },
    },
  };
}

function pop(delay: number): Variants {
  return {
    hidden: { scale: 0, opacity: 0 },
    show: { scale: 1, opacity: 1, transition: { ...spring, delay } },
    hover: { scale: [1, 0.6, 1], transition: { ...wobble, duration: 0.5, delay } },
  };
}

function squash(delay: number): Variants {
  return {
    hidden: { scale: 0.6, opacity: 0 },
    show: { scale: 1, opacity: 1, transition: { ...spring, delay } },
    hover: {
      scaleX: [1, 1.1, 0.95, 1],
      scaleY: [1, 0.9, 1.05, 1],
      transition: { ...wobble, delay },
    },
  };
}

function quarterTurn(delay: number): Variants {
  return {
    hidden: { rotate: -90 },
    show: { rotate: 0, transition: { ...spring, delay } },
    // Four-fold symmetric glyphs, so ending on 90deg looks identical to 0deg.
    hover: { rotate: [0, 90], transition: spring },
  };
}

function bar(delay: number): Variants {
  return {
    hidden: { scaleY: 0.2 },
    show: { scaleY: 1, transition: { ...spring, bounce: 0.6, delay } },
    hover: {
      scaleY: [1, 0.3, 1.35, 1],
      transition: { ...wobble, duration: 0.8, delay: delay - 0.3 },
    },
  };
}

const layoutShift = { layout: { duration: 0.22, ease: EASE } };

const rise: Variants = {
  hidden: { y: 18, opacity: 0 },
  show: { y: 0, opacity: 1, transition: { duration: 0.6, ease: EASE } },
};

const slideIn: Variants = {
  hidden: { x: -4, y: 4, opacity: 0 },
  show: { x: 0, y: 0, opacity: 1, transition: spring },
  hover: { x: [0, -2.5, 0], y: [0, 2.5, 0], transition: wobble },
};

const wiggle: Variants = {
  hidden: { rotate: -20 },
  show: { rotate: 0, transition: { ...spring, delay: 0.3 } },
  hover: { rotate: [0, -14, 8, 0], transition: { ...wobble, duration: 0.8 } },
};

const spinIn: Variants = {
  hidden: { scale: 0, rotate: -90, opacity: 0 },
  show: { scale: 1, rotate: 0, opacity: 1, transition: { ...spring, delay: 0.6 } },
  hover: { rotate: [0, 90], transition: { ...spring, delay: 0.2 } },
};

const tabWalk: Variants = {
  hidden: { x: -12 },
  show: { x: [-12, -6, 0], transition: { duration: 0.9, ease: ["backOut", "backOut"] } },
  hover: {
    x: [0, -12, -6, 0],
    transition: { duration: 1, times: [0, 0.3, 0.65, 1], ease: "backOut" },
  },
};

const badge: Variants = {
  hidden: { scale: 0, rotate: -90 },
  show: { scale: 1, rotate: 0, transition: { ...spring, delay: 0.2 } },
  hover: { scale: [1, 1.4, 1], transition: { ...wobble, duration: 0.5, delay: 0.1 } },
};

const spaceHop: Variants = {
  hidden: { x: -12, opacity: 0 },
  show: { x: 0, opacity: 1, transition: { ...spring, delay: 0.15 } },
  hover: {
    x: [0, 12, -12, 0],
    opacity: [1, 0, 0, 1],
    transition: { duration: 1, times: [0, 0.35, 0.36, 1], ease: "easeInOut" },
  },
};

// Divider and the split it anchors morph as one path, so the split never detaches.
const TILE_SPLIT = "M14 3v18M14 12h7";
const tileSplit: Variants = {
  hidden: { pathLength: 0, opacity: 0 },
  show: {
    pathLength: 1,
    opacity: 1,
    transition: { duration: 0.7, ease: EASE, opacity: { duration: 0.01 } },
  },
  hover: {
    d: [TILE_SPLIT, "M9 3v18M9 12h12", "M16 3v18M16 12h5", TILE_SPLIT],
    transition: { duration: 1.1, times: [0, 0.35, 0.7, 1], ease: "easeInOut" },
  },
};

const commandKey: Variants = {
  hidden: { pathLength: 0, opacity: 0, scale: 0.7 },
  show: {
    pathLength: 1,
    opacity: 1,
    scale: 1,
    transition: { duration: 0.8, ease: EASE, opacity: { duration: 0.01 }, scale: spring },
  },
  hover: {
    rotate: [0, 90],
    scale: [1, 0.85, 1],
    transition: {
      rotate: { type: "spring", bounce: 0.2, duration: 0.6 },
      scale: { ...wobble, duration: 0.5 },
    },
  },
};

function Home() {
  const { stable, beta, totalDownloads } = useReleases();
  const [channel, setChannel] = useState<"stable" | "beta">("stable");
  const sel = channel === "beta" && beta ? beta : stable;
  const { dmgUrl } = sel;
  // On the beta channel, recolor the whole page amber by overriding the single
  // Tailwind accent var; every `*-accent` utility follows it.
  const accentStyle =
    channel === "beta"
      ? ({ "--color-accent": "#9a6700", "--accent-on-dark": "#d29922" } as CSSProperties)
      : undefined;

  return (
    <MotionConfig reducedMotion="user">
      <main
        className="mx-auto flex max-w-[1120px] flex-col gap-28 px-6 pt-8 pb-28"
        style={accentStyle}
      >
        <div className="flex flex-col gap-14">
          <header className="grid grid-cols-[1fr_auto] items-center gap-x-10 gap-y-6 pt-12 max-[960px]:grid-cols-1 max-[640px]:pt-4">
            <div className="flex flex-col gap-6">
              <SwitcherHeadline />

              <div className="flex flex-col gap-3">
                <div className="enter [animation-delay:1450ms]">
                  <DownloadCta
                    href={dmgUrl}
                    channel={channel}
                    onChange={setChannel}
                    stable={stable}
                    beta={beta}
                  />
                </div>
                <div className="enter [animation-delay:1510ms]">
                  <BrewCmd beta={channel === "beta"} />
                </div>
                <p className="enter m-0 text-[13px] text-muted [animation-delay:1570ms]">
                  {totalDownloads > 0 && `${downloadFmt.format(totalDownloads)} downloads · `}
                  macOS 13+ · Apple Silicon and Intel
                </p>
              </div>
            </div>

            <div className="flex flex-col items-center gap-4 max-[960px]:order-first max-[960px]:items-start">
              <Chord className="enter text-[clamp(110px,12vw,150px)] max-[960px]:text-[72px]" />
              <script dangerouslySetInnerHTML={{ __html: CHORD_INTRO }} />
              <p className="enter m-0 text-[13px] text-muted [animation-delay:1800ms] max-[960px]:hidden">
                Go on, press <Kbd>⌘</Kbd> or <Kbd>tab</Kbd>
              </p>
            </div>
          </header>

          <Showcase />
        </div>

        <Highlights />

        <Compare />

        <Docs />

        <motion.section
          id="download"
          initial="hidden"
          whileInView="show"
          viewport={{ once: true, amount: 0.5 }}
          transition={{ staggerChildren: 0.08 }}
          className="flex flex-col items-center gap-6 text-center"
        >
          <motion.div variants={rise}>
            <PlayingChord className="text-[72px]" />
          </motion.div>
          <motion.h2
            variants={rise}
            className="m-0 text-[clamp(34px,4.4vw,52px)] leading-[1.05] font-bold tracking-[-0.04em]"
          >
            Stop hunting for windows.
          </motion.h2>
          {/* Centered row: "@beta" and "Copied" resize it, so every piece slides together. */}
          <LayoutGroup>
            <motion.div
              variants={rise}
              className="flex flex-wrap items-center justify-center gap-x-5 gap-y-3"
            >
              <motion.div layout="position" transition={layoutShift}>
                <DownloadButton
                  href={dmgUrl}
                  size="lg"
                  className="bg-text text-bg hover:bg-[#3a3833] hover:text-bg"
                />
              </motion.div>
              {/* The command is wider than a phone; the hero's copy covers mobile. */}
              <motion.div layout="position" transition={layoutShift} className="max-[640px]:hidden">
                <BrewCmd beta={channel === "beta"} />
              </motion.div>
            </motion.div>
            <motion.p
              layout="position"
              variants={rise}
              transition={layoutShift}
              className="m-0 text-[13px] text-muted"
            >
              {sel.version && `${formatVersion(sel.version)} · `}
              macOS 13+ · Apple Silicon and Intel
              {beta && (
                <>
                  <span className="max-[640px]:hidden"> · </span>
                  <button
                    type="button"
                    onClick={() => setChannel(channel === "beta" ? "stable" : "beta")}
                    className="cursor-pointer border-0 bg-transparent p-0 text-text underline decoration-line underline-offset-[3px] hover:decoration-text max-[640px]:mx-auto max-[640px]:mt-1 max-[640px]:block"
                  >
                    {channel === "beta" ? "Back to stable" : "Try the beta"}
                  </button>
                </>
              )}
            </motion.p>
          </LayoutGroup>
        </motion.section>
      </main>

      <Footer dmgUrl={dmgUrl} style={accentStyle} />
      <StickyCTA downloadUrl={dmgUrl} />
    </MotionConfig>
  );
}

const footerLinks: Array<[string, string]> = [
  ["Changelog", `${REPO}/releases`],
  ["Documentation", `${DOCS}/`],
  ["Config reference", `${DOCS}/config-reference/`],
  ["Report an issue", `${REPO}/issues`],
  ["License", `${REPO}/blob/main/LICENSE`],
];

const FOOTER_HEADING = "m-0 mb-5 text-[12px] font-semibold tracking-[0.12em] text-muted uppercase";
const DARK_BUTTON =
  "inline-flex items-center gap-2.5 rounded-xl border border-line bg-surface font-medium text-text transition-colors duration-150 hover:bg-[#1f1e1b]";

function Footer({ dmgUrl, style }: { dmgUrl: string; style: CSSProperties | undefined }) {
  return (
    <footer
      className="dark bg-[radial-gradient(50%_160px_at_50%_0,rgba(255,255,255,0.05),transparent)]"
      style={style}
    >
      <div className="mx-auto max-w-[1120px] px-6 pt-24">
        <div className="grid grid-cols-[1fr_minmax(0,420px)] gap-16 max-[860px]:grid-cols-1">
          <div className="flex flex-col items-start gap-6">
            <a className="flex items-center gap-3 border-0 text-[17px] font-semibold" href="/">
              <img
                className="block h-9 w-9"
                src="/icon-56.png"
                alt=""
                width={36}
                height={36}
                loading="lazy"
                decoding="async"
              />
              BetterCmdTab
            </a>
            <p className="m-0 text-[clamp(26px,3vw,34px)] leading-[1.1] font-bold tracking-[-0.03em]">
              The ⌘Tab macOS deserves.
            </p>
            <div className="mt-10 flex flex-wrap gap-3 max-[860px]:mt-2">
              <DownloadButton
                href={dmgUrl}
                size="lg"
                className="bg-text text-bg hover:bg-white hover:text-bg"
              />
              <ExternalLink className={`${DARK_BUTTON} h-12 px-5 text-[16px]`} href={REPO}>
                <Icon.GitHub className="h-[18px] w-[18px]" />
                Star on GitHub
              </ExternalLink>
            </div>
          </div>

          <div>
            <h2 className={FOOTER_HEADING}>Resources</h2>
            <ul className="m-0 flex list-none flex-col gap-3 p-0 text-[15px]">
              {footerLinks.map(([label, href]) => (
                <li key={label}>
                  <a className="border-0 text-dim hover:text-text" href={href}>
                    {label}
                  </a>
                </li>
              ))}
            </ul>

            <h2 className={`${FOOTER_HEADING} mt-10 border-t border-line pt-10`}>
              Also by Artur Rok
            </h2>
            <ExternalLink
              className={`${DARK_BUTTON} mb-3 max-w-[360px] gap-3.5 px-4 py-3`}
              href="https://betteraudio.pro/"
            >
              <img
                className="block h-9 w-9 shrink-0 rounded-[8px]"
                src="/betteraudio.png"
                alt=""
                width={36}
                height={36}
                loading="lazy"
                decoding="async"
              />
              <span className="flex flex-col">
                <span className="text-[15px]">BetterAudio</span>
                <span className="text-[13px] font-normal text-dim">
                  Per-app volume and audio routing for macOS
                </span>
              </span>
            </ExternalLink>
            <div className="flex flex-wrap gap-3 text-[14px]">
              <ExternalLink
                className={`${DARK_BUTTON} h-10 px-4`}
                href="https://github.com/rokartur"
              >
                <Icon.GitHub className="h-4 w-4" />
                @rokartur
              </ExternalLink>
            </div>
          </div>
        </div>

        <div className="mt-20 flex flex-wrap justify-between gap-x-6 gap-y-2 border-t border-line pt-7 text-[13px] text-muted">
          <span>© Artur Rok. Open source under GPL v3.</span>
          <span>Not affiliated with Apple Inc.</span>
        </div>

        <div
          aria-hidden="true"
          className="mt-12 h-[0.6em] overflow-hidden [mask-image:linear-gradient(black,transparent_90%)] text-[min(19vw,380px)] opacity-50"
        >
          <Chord className="justify-center" />
        </div>
      </div>
    </footer>
  );
}
