import { createFileRoute } from "@tanstack/react-router";
import { AnimatePresence, MotionConfig, motion, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

export const Route = createFileRoute("/")({
  component: Home,
});

const REPO = "https://github.com/rokartur/BetterCmdTab";

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

const shots: Array<[string, string]> = [
  ["/screenshots/preview.jpg", "Live window previews"],
  ["/screenshots/grid.jpg", "Grid of app icons"],
  ["/screenshots/list.jpg", "Classic vertical list"],
];

const features: Array<[string, string]> = [
  ["Three layouts", "classic list, grid of icons, or live window previews"],
  ["Window titles", "show each window's title under its icon in Grid and Previews"],
  ["Letter-prefix jump", "type a name to jump to it"],
  ["Search & launch", "press / to fuzzy-find, or launch any installed app"],
  ["Window switching", "Cmd+` cycles windows of the front app"],
  ["Tap or hold", "tap to switch instantly, hold to open the switcher"],
  ["Scroll to switch", "spin the mouse wheel to move through apps"],
  ["Recently closed", "reopen an app you just quit"],
  ["Minimized & hidden", "include minimized windows, hidden and windowless apps"],
  ["Pin & filter", "keep favorites up top, hide the rest"],
  ["Quick actions", "quit, close, minimize, maximize, hide inline"],
  ["Force quit", "Cmd+Option+Q SIGKILLs hung apps when graceful Quit hangs"],
  ["Tab drill-in", "press \\ to pick a tab from Safari, Chrome, Arc, Finder, Terminal, …"],
  ["Move windows", "send the highlighted window to the next display"],
  ["App hotkeys", "assign a shortcut to focus or launch a chosen app"],
  ["Unread badges", "Dock badge counts, in the switcher"],
  ["Audio indicator", "flags apps playing sound"],
  ["Instant Spaces", "switch Spaces with no animation"],
  ["Current Space only", "show just the windows on the Space you're on"],
  ["Liquid Glass", "system material on macOS 26"],
  ["Theming", "panel opacity, corner radius, and a custom accent color"],
  ["Multi-monitor", "opens on the screen under the cursor"],
  ["Trackpad & haptics", "three-finger swipe to open the switcher or switch Spaces, optional feedback"],
  ["Hide from screen sharing", "keep the switcher out of screen recordings and shared screens. Needs macOS 14.6+"],
  ["Configurable", "custom hotkey, size, scale, layout"],
];

const shortcuts: Array<[string, string]> = [
  ["Cmd Tab", "Next app"],
  ["Cmd Tab + Shift", "Previous app"],
  ["Cmd `", "Next window of current app"],
  ["Cmd Shift `", "Previous window of current app"],
  ["Cmd letters", "Jump to app starting with that letter"],
  ["Cmd /", "Toggle search — filter or launch any app"],
  ["Cmd Q", "Quit the highlighted app"],
  ["Cmd Option Q", "Force-quit the highlighted app (SIGKILL — for hung apps)"],
  ["Cmd W", "Close the highlighted window"],
  ["Cmd M", "Minimize the highlighted window"],
  ["Cmd H", "Hide / unhide the highlighted app"],
  ["Cmd \\", "Drill into the highlighted row's tab group (browsers, Finder, Terminal)"],
  ["Cmd Option arrows", "Move the highlighted window to the adjacent display"],
  ["Cmd Esc", "Cancel without activating"],
  ["Release Cmd", "Activate the highlighted row"],
];

interface GhAsset {
  name: string;
  browser_download_url: string;
  download_count: number;
}

interface GhRelease {
  tag_name: string;
  assets: GhAsset[];
}

interface Release {
  version: string | null;
  dmgUrl: string;
  totalDownloads: number | null;
  ready: boolean;
}

function useLatestRelease(): Release {
  const [rel, setRel] = useState<Release>({
    version: null,
    dmgUrl: `${REPO}/releases/latest`,
    totalDownloads: null,
    ready: false,
  });

  useEffect(() => {
    const ctrl = new AbortController();
    // One call to the list endpoint covers both the latest release (for the
    // download URL/version) and the cumulative download count across every
    // release's assets — saves a second round-trip.
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
        const latest = releases[0];
        const dmg = latest.assets.find((a) => a.name.endsWith(".dmg"));
        const total = releases.reduce(
          (sum, r) => sum + r.assets.reduce((s, a) => s + a.download_count, 0),
          0,
        );
        setRel({
          version: latest.tag_name,
          dmgUrl: dmg?.browser_download_url ?? `${REPO}/releases/latest`,
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
      <motion.section className="shots" {...inView}>
        {shots.map(([src, caption], i) => (
          <motion.figure key={src} className="shot" variants={reveal}>
            <motion.img
              src={src}
              alt={caption}
              loading="lazy"
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
            <figcaption>{caption}</figcaption>
          </motion.figure>
        ))}
      </motion.section>

      {mounted &&
        createPortal(
          <AnimatePresence>
            {active && (
              <motion.div
                className="lightbox"
                onClick={() => setOpen(null)}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.2, ease: EASE }}
              >
                <motion.img
                  src={active[0]}
                  alt={active[1]}
                  className="lightbox-img"
                  initial={{ opacity: 0, scale: 0.94 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={{ opacity: 0, scale: 0.96 }}
                  transition={{ duration: 0.26, ease: EASE }}
                />
                <span className="lightbox-hint">Esc · click to close</span>
              </motion.div>
            )}
          </AnimatePresence>,
          document.body,
        )}
    </>
  );
}

function Keys({ combo }: { combo: string }) {
  return (
    <span className="keys">
      {combo.split(" ").map((token, i) =>
        token === "+" ? (
          <span key={`sep-${i}`} className="key-sep">
            +
          </span>
        ) : (
          <kbd key={`${token}-${i}`} className="kbd">
            {token}
          </kbd>
        ),
      )}
    </span>
  );
}

function Rows({ rows, combo }: { rows: Array<[string, string]>; combo?: boolean }) {
  return (
    <motion.ul className={combo ? "grid keys-grid" : "grid"} variants={stagger}>
      {rows.map(([key, desc]) => (
        <motion.li key={key} variants={reveal} whileHover={{ x: 4 }}>
          {combo ? <Keys combo={key} /> : <span className="key">{key}</span>}
          <span className="desc">{desc}</span>
        </motion.li>
      ))}
    </motion.ul>
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

function DownloadCta({ href }: { href: string }) {
  const reduce = useReducedMotion();
  const [active, setActive] = useState(false);
  const label = useScramble("Download.dmg", active, !reduce);

  return (
    <motion.a
      className="cta"
      href={href}
      download
      onHoverStart={() => setActive(true)}
      onHoverEnd={() => setActive(false)}
      onFocus={() => setActive(true)}
      onBlur={() => setActive(false)}
      whileTap={{ scale: 0.98 }}
    >
      <svg
        className="cta-icon"
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
          className="cta-tray"
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
      <span className="cta-label">{label}</span>
    </motion.a>
  );
}

const downloadFmt = new Intl.NumberFormat("en-US");

export function Home() {
  const { version, dmgUrl, totalDownloads } = useLatestRelease();

  return (
    <MotionConfig reducedMotion="user">
      <main className="page">
        <motion.header className="intro" variants={stagger} initial="hidden" animate="show">
          <motion.h1 className="brand" variants={reveal}>
            <motion.img
              className="brand-icon"
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
          <motion.p className="tagline" variants={reveal}>
            The Cmd+Tab macOS deserves.
            <span className="caret" aria-hidden />
          </motion.p>
          <motion.p className="lede" variants={reveal}>
            A fast, native window switcher and app launcher for macOS.
            <br />
            Free forever, zero telemetry, no subscription.
          </motion.p>
        </motion.header>

        <Shots />

        <motion.hr
          initial={{ scaleX: 0, opacity: 0 }}
          whileInView={{ scaleX: 1, opacity: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.6, ease: EASE }}
          style={{ transformOrigin: "left" }}
        />

        <motion.section {...inView}>
          <motion.h2 variants={reveal}>Download</motion.h2>
          <motion.p className="row" variants={reveal}>
            <DownloadCta href={dmgUrl} />
            <span className="muted">
              {version ? `${version} · ` : ""}
              {totalDownloads !== null ? `${downloadFmt.format(totalDownloads)} downloads · ` : ""}
              macOS 13.0+ · Apple Silicon &amp; Intel
            </span>
          </motion.p>
        </motion.section>

        <motion.section {...inView}>
          <motion.h2 variants={reveal}>Features</motion.h2>
          <Rows rows={features} />
        </motion.section>

        <motion.section {...inView}>
          <motion.h2 variants={reveal}>Shortcuts</motion.h2>
          <Rows rows={shortcuts} combo />
          <motion.p className="muted note" variants={reveal}>
            Hold Cmd, tap to step through, release to activate.
          </motion.p>
        </motion.section>

        <motion.section {...inView}>
          <motion.h2 variants={reveal}>Connect</motion.h2>
          <motion.p className="links" variants={reveal}>
            <a href={REPO}>GitHub</a>
            <span className="sep">·</span>
            <a href={`${REPO}/releases`}>Releases</a>
            <span className="sep">·</span>
            <a href={`${REPO}/blob/main/LICENSE`}>License</a>
          </motion.p>
        </motion.section>

        <motion.footer
          initial={{ opacity: 0 }}
          whileInView={{ opacity: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5 }}
        >
          Built by <a href="https://github.com/rokartur">@rokartur</a> · GPL v3
        </motion.footer>
      </main>
    </MotionConfig>
  );
}
