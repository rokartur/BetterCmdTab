import { motion, useInView, useReducedMotion } from "motion/react";
import { Fragment, type ReactNode, type RefObject, useEffect, useRef, useState } from "react";

import { EASE } from "./tokens";

// Split so each word blurs in on its own beat.
const headlineWords = ["The", "⌘Tab", "macOS", "deserves."];

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

type KeySound = "cmd" | "tab" | "up";
type PlayKeySound = (sound: KeySound) => Promise<void>;

const SOUND_KEY = "BetterCmdTab.sound";

// The files prefetch at mount so the first press isn't late. Called once, unlike useHeldKeys, so each press clicks once.
export function useKeySounds() {
  const play = useRef<PlayKeySound>(async () => {});
  const enabled = useRef(false);
  const [on, setOn] = useState(false);

  useEffect(() => {
    enabled.current = localStorage.getItem(SOUND_KEY) === "on";
    // oxlint-disable-next-line react/set-state-in-effect -- post-hydration localStorage sync, as in useReleases
    setOn(enabled.current);
    const load = async (url: string) => (await fetch(url)).arrayBuffer();
    const files = Promise.all([
      load("/sounds/cmd-down.wav"),
      load("/sounds/tab-down.wav"),
      load("/sounds/key-up.wav"),
    ]);
    const decode = (audio: AudioContext) =>
      files.then((buffers) => Promise.all(buffers.map((b) => audio.decodeAudioData(b))));
    let ctx: AudioContext | undefined;
    let sounds: Promise<AudioBuffer[]> | undefined;

    play.current = async (sound) => {
      // Chrome grants no activation for modifier keys, so a lone ⌘ can't unlock audio; a click
      // or Tab can. Clicks started on a locked context would queue up and burst on unlock.
      if (!enabled.current || !navigator.userActivation.hasBeenActive) return;
      const audio = (ctx ??= new AudioContext());
      if (audio.state !== "running") await audio.resume();
      const [cmd, tab, up] = await (sounds ??= decode(audio));
      let buffer = up;
      if (sound === "cmd") buffer = cmd;
      if (sound === "tab") buffer = tab;
      const source = audio.createBufferSource();
      source.buffer = buffer;
      // A few percent of pitch drift so repeated taps don't sound like one sample.
      source.playbackRate.value = 0.96 + Math.random() * 0.08;
      source.connect(audio.destination);
      source.start();
    };
    const onKey = (e: KeyboardEvent, down: boolean) => {
      if (e.repeat || (e.key !== "Meta" && e.key !== "Tab")) return;
      let sound: KeySound = "up";
      if (down) sound = e.key === "Meta" ? "cmd" : "tab";
      void play.current(sound);
    };
    const onDown = (e: KeyboardEvent) => onKey(e, true);
    const onUp = (e: KeyboardEvent) => onKey(e, false);
    window.addEventListener("keydown", onDown);
    window.addEventListener("keyup", onUp);
    return () => {
      window.removeEventListener("keydown", onDown);
      window.removeEventListener("keyup", onUp);
      void ctx?.close();
    };
  }, []);

  const toggle = () => {
    enabled.current = !enabled.current;
    setOn(enabled.current);
    localStorage.setItem(SOUND_KEY, enabled.current ? "on" : "off");
    // The click is the user gesture that unlocks audio, and the tap confirms it's on.
    if (enabled.current) void play.current("cmd");
  };
  return { play, on, toggle };
}

export function SoundToggle({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  return (
    <button
      type="button"
      aria-label="Key sounds"
      aria-pressed={on}
      onClick={onToggle}
      className="enter fixed bottom-7 left-7 z-40 hidden h-11 w-11 cursor-pointer items-center justify-center rounded-2xl border border-line bg-surface text-dim shadow-[0_6px_24px_rgb(0_0_0/0.08)] [animation-delay:1900ms] hover:text-text lg:flex"
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.6}
        strokeLinecap="round"
        strokeLinejoin="round"
        className="h-5 w-5"
        aria-hidden="true"
      >
        <path d="M11 5 6 9H3v6h3l5 4V5Z" />
        {on ? (
          <path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13" />
        ) : (
          <path d="m16 9 6 6m0-6-6 6" />
        )}
      </svg>
    </button>
  );
}

const HOME_WORD = headlineWords.indexOf("⌘Tab");

// The headline cycles like the switcher: tab moves the selection, a pause activates it.
// Its own component so a tab press re-renders four words, not Home.
export function SwitcherHeadline() {
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
export function Kbd({ children }: { children: ReactNode }) {
  return (
    <kbd className="inline-flex h-[22px] min-w-[22px] items-center justify-center rounded-[6px] border border-b-2 border-[#d6d1c7] bg-[linear-gradient(#ffffff,#f1eee8)] px-1.5 align-[1px] font-sans text-[12px] leading-none font-medium tracking-[0.04em] text-text shadow-[inset_0_1px_0_rgba(255,255,255,0.9)]">
      {children}
    </kbd>
  );
}

type HeldKeys = { meta: boolean; tab: boolean };
const NO_KEYS: HeldKeys = { meta: false, tab: false };

// Hold command, tap tab twice, let go: the gesture the page is selling.
const CHORD_TAPS: Array<[number, HeldKeys, KeySound]> = [
  [0, { meta: true, tab: false }, "cmd"],
  [260, { meta: true, tab: true }, "tab"],
  [420, { meta: true, tab: false }, "up"],
  [620, { meta: true, tab: true }, "tab"],
  [780, { meta: true, tab: false }, "up"],
  [1100, NO_KEYS, "up"],
];

// Plays CHORD_TAPS once in view and again on hover; real key presses still show.
export function PlayingChord({
  className,
  sound,
}: {
  className: string;
  sound: RefObject<PlayKeySound>;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, amount: 0.8 });
  const reduceMotion = useReducedMotion();
  const [run, setRun] = useState(0);
  const [keys, setKeys] = useState(NO_KEYS);

  useEffect(() => {
    if (!inView || reduceMotion) return;
    const timers = CHORD_TAPS.map(([at, next, click]) =>
      setTimeout(() => {
        setKeys(next);
        void sound.current(click);
      }, at + 350),
    );
    return () => {
      timers.forEach(clearTimeout);
      setKeys(NO_KEYS);
    };
  }, [inView, reduceMotion, run, sound]);

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
export const CHORD_INTRO = `(() => {
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
  // Audio is locked until the user interacts; Chrome carries that over same-origin links, not reloads.
  if (!navigator.userActivation.hasBeenActive || localStorage.getItem("BetterCmdTab.sound") !== "on") return;
  const audio = new AudioContext();
  const start = performance.now();
  const load = async (name) => audio.decodeAudioData(await (await fetch(\`/sounds/\${name}.wav\`)).arrayBuffer());
  Promise.all([load("cmd-down"), load("tab-down"), load("key-up")]).then(([down, tabDown, up]) => {
    for (const [buffer, at] of [[down, 790], [tabDown, 940], [up, 1000], [up, 1100]]) {
      const source = audio.createBufferSource();
      source.buffer = buffer;
      source.connect(audio.destination);
      source.start(audio.currentTime + Math.max(0, start + at - performance.now()) / 1000);
    }
  });
})()`;

// Sized in em, so the parent's font-size sets the whole chord.
export function Chord({ className, pressed = NO_KEYS }: { className: string; pressed?: HeldKeys }) {
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
