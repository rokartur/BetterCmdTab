import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";

import { EASE } from "./tokens";

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

// The server snapshot is false and the client's is true, so hydration reads false first.
const subscribeNever = () => () => {};

// The product, front and centre: an auto-advancing peek carousel of the three
// switcher layouts, neighbours dimmed at the edges.
export function Showcase() {
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
