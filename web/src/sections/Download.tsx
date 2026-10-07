import { AnimatePresence, motion } from "motion/react";
import { useEffect, useRef, useState } from "react";

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
import { DownloadButton } from "../StickyCTA";
import { EASE } from "./tokens";

const BREW = "brew install --cask bettercmdtab";

// Every color in the channel toggle crossfades on this one clock, or the inverted text dips under its background.
const CHANNEL_SWAP = "duration-300 ease-[cubic-bezier(0.22,1,0.36,1)]";

// Baked at build time (scripts/fetch-releases.ts, run by the Docker build) so
// the page — including the statically rendered HTML — is correct as of the
// last deploy even when GitHub's API limit is exhausted, which it routinely is.
const baked = channels(snapshot);

export function useReleases(): Releases {
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

export function DownloadCta({
  href,
  channel,
  onChange,
  beta,
}: {
  href: string;
  channel: "stable" | "beta";
  onChange: (channel: "stable" | "beta") => void;
  beta: Channel | null;
}) {
  const isBeta = channel === "beta";
  return (
    <div className="flex">
      {/* Channel colors crossfade opaque layers: Chrome paints a finished background-color transition's start color for one frame. */}
      <div
        className={`group/cta relative inline-flex h-12 rounded-2xl bg-text transition-colors has-[a:hover]:bg-[#3a3833] ${CHANNEL_SWAP}`}
      >
        <span
          aria-hidden
          className={`pointer-events-none beta-blueprint absolute inset-0 rounded-2xl bg-surface transition-[opacity,background-color] group-has-[a:hover]/cta:bg-[color-mix(in_oklab,var(--color-pro)_5%,var(--color-surface))] ${CHANNEL_SWAP} ${
            isBeta ? "opacity-100" : "opacity-0"
          }`}
        />
        {/* Label snaps once the background passes its midpoint (~40ms into CHANNEL_SWAP); tweened, the two colors meet and the label vanishes. */}
        <DownloadButton
          href={href}
          size="lg"
          className={`bg-transparent delay-40 duration-0 max-[420px]:px-4 max-[360px]:px-3 max-[360px]:text-[15px] ${isBeta ? "text-text hover:text-text" : "text-bg hover:text-bg"}`}
        />
        {beta && (
          <div
            role="group"
            aria-label="Release channel"
            className="relative m-[5px] grid grid-cols-2 rounded-[11px] bg-white/12 p-[3px]"
          >
            <span
              aria-hidden
              className={`absolute inset-0 rounded-[inherit] bg-[color-mix(in_oklab,var(--color-pro)_10%,var(--color-surface))] transition-opacity ${CHANNEL_SWAP} ${
                isBeta ? "opacity-100" : "opacity-0"
              }`}
            />
            <span
              aria-hidden
              className={`absolute inset-y-[3px] left-[3px] w-[calc(50%-3px)] rounded-lg bg-bg shadow-[0_1px_2px_rgba(0,0,0,0.15)] transition-[translate] motion-reduce:transition-none ${CHANNEL_SWAP} ${
                isBeta ? "translate-x-full" : ""
              }`}
            >
              <span
                className={`absolute inset-0 rounded-[inherit] bg-text transition-opacity ${CHANNEL_SWAP} ${
                  isBeta ? "opacity-100" : "opacity-0"
                }`}
              />
            </span>
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
    </div>
  );
}

// Chars keyed by index+char, so only the ones that differ roll when the channel flips.
export function RollingText({ text, className }: { text: string; className: string }) {
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

export function formatVersion(version: string) {
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

export function BrewCmd({ beta }: { beta: boolean }) {
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
