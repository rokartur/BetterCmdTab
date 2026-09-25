import {
  animate,
  motion,
  AnimatePresence,
  type MotionValue,
  useMotionValue,
  useMotionValueEvent,
  useReducedMotion,
  useSpring,
  useTransform,
} from "motion/react";
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type MouseEvent,
  type ReactNode,
  type RefObject,
} from "react";

import { LiquidGlassLayer } from "./liquid-glass/LiquidGlassLayer";

// ─── V3 — single liquid-glass surface that morphs between pill and panel ─────
//
// One element, two states:
//
//   closed → [Download · Menu ▲]                  (rounded-full pill)
//
//   open   → [Pricing            →]
//            [License Manager    →]
//            [FAQ                →]
//            [Download · Menu ▼]                   (rounded-3xl panel)
//
// Why we animate width/height/borderRadius directly (no `layout` morph):
//
//   `motion.div layout` morphs size by applying a CSS scale transform to
//   the parent. Two ugly things follow:
//
//     1. CSS `border-radius` is interpolated against the FINAL layout box
//        (the panel size), so 9999 caps to half the panel height (~87px).
//        While the parent is being scaled non-uniformly mid-flight, those
//        87px corners visibly become an ellipse and the pill looks like a
//        "circle that snaps to a panel" instead of smoothly reshaping.
//        That was bug #1 the user reported.
//
//     2. Backdrop-filter rasterisation re-runs every frame because the
//        filtered region's geometry changes via the transform. Combined
//        with `LiquidGlassLayer`'s ResizeObserver firing on every animated
//        pixel and triggering an SVG displacement-map regeneration, the
//        morph chewed through frame budget. That was bug #2.
//
//   Animating the actual `width` / `height` props means the parent keeps a
//   real CSS box at every frame, so border-radius interpolates relative to
//   THAT box and never gets distorted (problem 1 dies). The map regen
//   problem (2) is killed inside LiquidGlassLayer itself: its
//   ResizeObserver flush is now debounced, so during the morph maps stay
//   put and only regenerate once when the size finally settles. The
//   existing maps stretch slightly over the intermediate sizes for the few
//   hundred ms of the transition — visually fine on a glass bezel.
//
// Sizing strategy:
//
//   We render two off-screen "phantom" copies of the closed and open
//   content, measure them with a useLayoutEffect (and re-measure when web
//   fonts finish loading + on viewport resize), and animate the real
//   surface's width / height to those measured numbers. No hard-coded
//   dimensions, no auto→number jumps.
//
// Reveal mechanic:
//
//   The morphing surface has `overflow: hidden` and a single content
//   stack pinned to its bottom (`position: absolute; bottom: 0`). The
//   always-visible Download / Menu row sits at the bottom; the menu
//   items stack ABOVE it. A short surface clips the items off the top —
//   so the surface growing IS the reveal. Items themselves only animate
//   opacity / a tiny lift via stagger; they never have to be translated
//   into place because they're already in their final layout position.
const REPO = "https://github.com/rokartur/BetterCmdTab";

const MENU_ITEMS: ReadonlyArray<{ label: string; href: string }> = [
  { label: "Features", href: "#features" },
  { label: "Compare", href: "#compare" },
  { label: "Config file", href: "#config" },
  { label: "GitHub", href: REPO },
  { label: "Releases", href: `${REPO}/releases` },
  { label: "BetterAudio", href: "https://betteraudio.pro/" },
];

const easeOut = [0.22, 1, 0.36, 1] as const;

export const Icon = {
  Arrow: ({ className }: { className: string }) => (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <path d="M5 12h14" />
      <path d="M13 6l6 6-6 6" />
    </svg>
  ),
  Apple: ({ className }: { className: string }) => (
    <svg viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden="true">
      <path d="M19.37 7.648c-.114.088-2.11 1.213-2.11 3.715 0 2.894 2.54 3.918 2.616 3.944-.011.062-.403 1.402-1.34 2.767-.834 1.201-1.706 2.4-3.032 2.4s-1.667-.77-3.198-.77c-1.492 0-2.022.796-3.235.796-1.214 0-2.06-1.112-3.033-2.477C4.911 16.42 4 13.93 4 11.566c0-3.791 2.465-5.802 4.891-5.802 1.29 0 2.364.847 3.173.847.77 0 1.972-.897 3.438-.897.556 0 2.553.05 3.867 1.934Zm-4.564-3.54c.607-.719 1.036-1.718 1.036-2.716 0-.138-.012-.279-.037-.392-.987.037-2.161.657-2.87 1.478-.555.632-1.074 1.63-1.074 2.643 0 .152.026.304.037.353.063.011.164.025.266.025.885 0 1.998-.593 2.642-1.39Z" />
    </svg>
  ),
  GitHub: ({ className }: { className: string }) => (
    <svg viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden="true">
      <path d="M12 .3a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2c-3.3.7-4-1.6-4-1.6-.6-1.4-1.4-1.8-1.4-1.8-1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.8 1.3 3.5 1 0-.8.4-1.3.7-1.6-2.7-.3-5.5-1.3-5.5-5.9 0-1.3.5-2.4 1.2-3.2 0-.3-.5-1.5.2-3.2 0 0 1-.3 3.3 1.2a11.5 11.5 0 0 1 6 0C17.3 4.7 18.3 5 18.3 5c.7 1.7.2 2.9.1 3.2.8.8 1.2 1.9 1.2 3.2 0 4.6-2.8 5.6-5.5 5.9.5.4.9 1.1.9 2.2v3.3c0 .3.2.7.8.6A12 12 0 0 0 12 .3" />
    </svg>
  ),
};

const downloadSizes = {
  lg: {
    className: "h-12 rounded-2xl px-6 text-[16px]",
    content: "gap-2.5",
    icon: "h-[18px] w-[18px]",
    label: "Download for Mac",
  },
  sm: {
    className: "h-9 rounded-full px-3.5 text-[12.5px] sm:h-10 sm:px-4 sm:text-[13.5px]",
    content: "gap-1.5",
    icon: "h-3.5 w-3.5 sm:h-4 sm:w-4",
    label: "Download",
  },
};

const swapTransition = { duration: 0.22, ease: easeOut };

// Hover slides "Apple + label" out left and "label + arrow" in from the right.
export function DownloadButton({
  href,
  size,
  className,
}: {
  href: string;
  size: keyof typeof downloadSizes;
  className: string;
}) {
  const [hovered, setHovered] = useState(false);
  const s = downloadSizes[size];

  return (
    <motion.a
      href={href}
      onHoverStart={() => setHovered(true)}
      onHoverEnd={() => setHovered(false)}
      whileHover={{ scale: 1.02 }}
      whileTap={{ scale: 0.98 }}
      className={`relative inline-flex items-center justify-center overflow-hidden border-0 font-semibold whitespace-nowrap no-underline transition-colors duration-150 focus-visible:ring-2 focus-visible:ring-accent/60 focus-visible:outline-none ${s.className} ${className}`}
    >
      <motion.span
        initial={false}
        animate={{
          opacity: hovered ? 0 : 1,
          x: hovered ? -16 : 0,
          filter: hovered ? "blur(6px)" : "blur(0px)",
        }}
        transition={swapTransition}
        className={`flex items-center ${s.content}`}
      >
        <Icon.Apple className={s.icon} />
        {s.label}
      </motion.span>
      <motion.span
        aria-hidden="true"
        initial={false}
        animate={{
          opacity: hovered ? 1 : 0,
          x: hovered ? 0 : 16,
          filter: hovered ? "blur(0px)" : "blur(6px)",
        }}
        transition={swapTransition}
        className={`absolute flex items-center ${s.content}`}
      >
        {s.label}
        <Icon.Arrow className={s.icon} />
      </motion.span>
    </motion.a>
  );
}

// Visual radius the OPEN panel uses on its corners. The CLOSED pill uses
// half its measured height (= the natural "fully rounded" cap) so that
// when we animate borderRadius alongside width/height, the value stays
// below the CSS auto-cap of `min(w,h)/2` for the WHOLE morph and the
// visible roundness interpolates smoothly in lockstep with the size.
//
// Why we don't just use 9999 ("force fully rounded") for the closed state:
// CSS automatically caps any border-radius to `min(w,h)/2`. Animating
// 9999 → 24 means the value stays well above that cap until the very end,
// so the browser keeps clamping it to h/2 and the visible radius tracks
// h/2 of the growing box (≈ continuously "fully rounded") all the way
// through, then SNAPS to 24 only when the spring finally drops below the
// cap. That's why the radius felt like it didn't move with the morph.
// Going from h/2 → 24 directly gives a real, smooth, in-sync transition.
const RADIUS_PANEL = 24;

interface BoxSize {
  w: number;
  h: number;
}

interface MeasuredSizes {
  closed: BoxSize;
  open: BoxSize;
}

export function StickyCTA({ downloadUrl }: { downloadUrl: string }) {
  const reduced = useReducedMotion();
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const closedMeasureRef = useRef<HTMLDivElement>(null);
  const openMeasureRef = useRef<HTMLDivElement>(null);
  const [sizes, setSizes] = useState<MeasuredSizes | null>(null);
  const pageY = useMotionValue(0);
  useMotionValueEvent(pageY, "change", (y) => window.scrollTo(0, y));

  // Measure the closed and open content trees off-screen. Re-measure when
  // fonts finish loading (text widths can jump 2–4px between fallback and
  // the real font, which would otherwise leak into a tiny pop on first
  // open) and on viewport resize.
  useLayoutEffect(() => {
    const update = () => {
      const c = closedMeasureRef.current;
      const o = openMeasureRef.current;
      if (!c || !o) return;
      const next: MeasuredSizes = {
        closed: { w: c.offsetWidth, h: c.offsetHeight },
        open: { w: o.offsetWidth, h: o.offsetHeight },
      };
      setSizes((prev) => {
        if (
          prev &&
          prev.closed.w === next.closed.w &&
          prev.closed.h === next.closed.h &&
          prev.open.w === next.open.w &&
          prev.open.h === next.open.h
        ) {
          return prev;
        }
        return next;
      });
    };
    update();
    if (typeof document !== "undefined" && "fonts" in document) {
      document.fonts.ready.then(update).catch(() => undefined);
    }
    window.addEventListener("resize", update, { passive: true });
    return () => window.removeEventListener("resize", update);
  }, []);

  // Outside-click + Escape close. Listeners only attached while open so we
  // don't pay the global cost the rest of the time.
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: PointerEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // Closed-pill radius derived from the measured pill height — this equals
  // the natural CSS-auto-cap of `min(w,h)/2`, so visually it's a fully
  // rounded pill, AND when we interpolate from this value to RADIUS_PANEL
  // (24) the spring stays below `currentHeight/2` at every intermediate
  // frame. The browser therefore never has to cap the radius and the
  // visible roundness moves in real time with the size morph instead of
  // snapping at the very end.
  const closedRadius = sizes ? sizes.closed.h / 2 : 0;

  return (
    <>
      <PhantomMeasurers
        closedRef={closedMeasureRef}
        openRef={openMeasureRef}
        downloadUrl={downloadUrl}
      />
      <AnimatePresence>
        {sizes ? (
          <motion.div
            key="sticky-v3"
            initial={reduced ? { opacity: 0 } : { opacity: 0, y: 18, scale: 0.97 }}
            animate={reduced ? { opacity: 1 } : { opacity: 1, y: 0, scale: 1 }}
            exit={reduced ? { opacity: 0 } : { opacity: 0, y: 18, scale: 0.97 }}
            transition={{ duration: 0.32, ease: easeOut }}
            className="pointer-events-none fixed inset-x-0 bottom-5 z-40 flex justify-center px-4 sm:bottom-7"
          >
            <div ref={containerRef} className="pointer-events-auto">
              <MorphSurface
                size={open ? sizes.open : sizes.closed}
                radius={open ? RADIUS_PANEL : closedRadius}
                reduced={!!reduced}
              >
                {/* Liquid-glass background. `[border-radius:inherit]`
                    ties the layer's clip to the parent's animated radius
                    so the bezel + 1px outset always meet the visible
                    edge. The numeric `radius` prop drives map generation:
                    it switches between "full pill" (default, h/2) and
                    `RADIUS_PANEL` (24) on state change. The maps would
                    otherwise regenerate every animation frame because of
                    the parent's continuously-changing size; the layer's
                    own ResizeObserver flush is debounced so the regen
                    only runs once the morph settles. */}
                <LiquidGlassLayer
                  className="[border-radius:inherit]"
                  radius={open ? RADIUS_PANEL : undefined}
                />

                {/* Bottom-anchored content stack. The pill row sits at
                    the bottom; menu items stack above it in their
                    natural slot. With `overflow-hidden` on the parent, a
                    smaller surface clips the items off the top — so the
                    surface growing IS the reveal. Items don't have to
                    translate into place because they're already in their
                    final layout position. */}
                <div className="absolute inset-x-0 bottom-0">
                  <AnimatePresence initial={false}>
                    {open ? (
                      <motion.ul
                        key="sticky-v3-items"
                        role="menu"
                        aria-label="More destinations"
                        className="flex flex-col gap-0.5 p-1.5 pb-0"
                        initial="hidden"
                        animate="visible"
                        exit="hidden"
                        variants={{
                          hidden: {
                            transition: {
                              staggerChildren: 0.02,
                              staggerDirection: -1,
                            },
                          },
                          visible: {
                            transition: {
                              staggerChildren: 0.04,
                              delayChildren: 0.06,
                            },
                          },
                        }}
                      >
                        {MENU_ITEMS.map((item) => (
                          <MenuItem
                            key={item.label}
                            item={item}
                            reduced={!!reduced}
                            onSelect={(event) => {
                              setOpen(false);
                              if (reduced || !item.href.startsWith("#")) return;
                              event.preventDefault();
                              glideTo(pageY, item.href);
                            }}
                          />
                        ))}
                      </motion.ul>
                    ) : null}
                  </AnimatePresence>
                  <PillRow
                    downloadUrl={downloadUrl}
                    open={open}
                    reduced={!!reduced}
                    onMenuToggle={() => setOpen((v) => !v)}
                  />
                </div>
              </MorphSurface>
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </>
  );
}

// ─── V3 building blocks ──────────────────────────────────────────────────────

// Critically damped: 2·√(240·1.1) ≈ 32.5; upstream's 28 (ζ 0.86) undershot
// the pill by ~1px.
const MORPH_SPRING = { stiffness: 240, damping: 33, mass: 1.1 };

// Animates the real CSS box (no `layout` scale transform, which distorted the
// corners). Height is rounded to device pixels: the spring's sub-pixel tail
// otherwise re-antialiases the specular ring on every frame for ~300ms.
function MorphSurface({
  size,
  radius,
  reduced,
  children,
}: {
  size: BoxSize;
  radius: number;
  reduced: boolean;
  children: ReactNode;
}) {
  const height = useSpring(size.h, MORPH_SPRING);
  const pixelHeight = useTransform(
    height,
    (h) => Math.round(h * window.devicePixelRatio) / window.devicePixelRatio,
  );

  useEffect(() => {
    if (reduced) height.jump(size.h);
    else height.set(size.h);
  }, [height, size.h, reduced]);

  return (
    <motion.div
      initial={false}
      animate={{ width: size.w, borderRadius: radius }}
      transition={reduced ? { duration: 0 } : { type: "spring", ...MORPH_SPRING }}
      style={{ height: pixelHeight }}
      className="relative overflow-hidden text-stone-100"
    >
      {children}
    </motion.div>
  );
}

// Always-visible pill row. Extracted so the same markup feeds the real
// component AND the off-screen measurement phantoms — guarantees the
// measured size matches what eventually gets rendered.
function PillRow({
  downloadUrl,
  open,
  reduced,
  onMenuToggle,
}: {
  downloadUrl: string;
  open: boolean;
  reduced: boolean;
  onMenuToggle: () => void;
}) {
  return (
    <div className="flex items-center justify-center gap-0.5 p-1 sm:p-1.5">
      <DownloadButton
        href={downloadUrl}
        size="sm"
        className="bg-stone-100 text-stone-900 hover:bg-white"
      />

      <PillDivider />

      <a
        href="/docs/"
        className="inline-flex h-9 items-center justify-center rounded-full border-0 px-3 text-[12.5px] font-medium text-stone-200 no-underline transition-[transform,background-color,color] duration-200 ease-[cubic-bezier(0.32,0.72,0,1)] hover:bg-white/8 hover:text-white focus-visible:bg-white/10 focus-visible:text-white focus-visible:outline-none active:scale-[0.96] sm:h-10 sm:px-3.5 sm:text-[13.5px]"
      >
        Docs
      </a>

      <PillDivider />

      <button
        type="button"
        onClick={onMenuToggle}
        aria-expanded={open}
        aria-haspopup="menu"
        aria-label={open ? "Close menu" : "Open menu"}
        className="inline-flex h-9 items-center justify-center gap-1.5 rounded-full px-3 text-[12.5px] font-medium text-stone-200 transition-[transform,background-color,color] duration-200 ease-[cubic-bezier(0.32,0.72,0,1)] hover:bg-white/8 hover:text-white focus-visible:bg-white/10 focus-visible:text-white focus-visible:outline-none active:scale-[0.96] sm:h-10 sm:px-3.5 sm:text-[13.5px]"
      >
        <span>Menu</span>
        <motion.span
          aria-hidden
          className="inline-flex"
          animate={reduced ? undefined : { rotate: open ? 180 : 0 }}
          transition={{ duration: 0.32, ease: easeOut }}
        >
          <ChevronUp className="h-3.5 w-3.5 sm:h-4 sm:w-4" />
        </motion.span>
      </button>
    </div>
  );
}

// One link in the upward-expanding menu. Wrapped in `motion.li` so the
// parent <motion.ul> stagger variants drive its entry / exit. No `layout`
// here on purpose — the surrounding surface morphs via direct width /
// height animation, not transform projection, so items don't need a
// counter-projection.
function MenuItem({
  item,
  reduced,
  onSelect,
}: {
  item: { label: string; href: string };
  reduced: boolean;
  onSelect: (event: MouseEvent<HTMLAnchorElement>) => void;
}) {
  return (
    <motion.li
      role="none"
      variants={{
        hidden: reduced
          ? { opacity: 0 }
          : { opacity: 0, y: 6, transition: { duration: 0.18, ease: easeOut } },
        visible: reduced
          ? { opacity: 1 }
          : { opacity: 1, y: 0, transition: { duration: 0.26, ease: easeOut } },
      }}
    >
      <a
        role="menuitem"
        href={item.href}
        onClick={onSelect}
        className="group/menuitem flex h-10 items-center justify-between rounded-2xl border-0 px-3.5 text-[13px] font-medium text-stone-200 no-underline transition-[transform,background-color,color] duration-200 ease-[cubic-bezier(0.32,0.72,0,1)] hover:bg-white/8 hover:text-white focus-visible:bg-white/10 focus-visible:text-white focus-visible:outline-none active:scale-[0.97] sm:h-11 sm:px-4 sm:text-[14px]"
      >
        <span>{item.label}</span>
        <Icon.Arrow className="h-3.5 w-3.5 text-stone-400 transition-colors group-hover/menuitem:text-white sm:h-4 sm:w-4" />
      </a>
    </motion.li>
  );
}

// A native hash jump is instant and `scroll-behavior: smooth` has no curve or interrupt.
// Springing one MotionValue keeps velocity when a second link retargets mid-flight.
function glideTo(pageY: MotionValue<number>, hash: string) {
  const target = document.querySelector(hash);
  if (!target) return;
  const root = document.documentElement;
  const padding = parseFloat(getComputedStyle(root).scrollPaddingTop);
  const maxY = root.scrollHeight - window.innerHeight;
  const from = window.scrollY;
  const to = Math.round(
    Math.max(0, Math.min(maxY, from + target.getBoundingClientRect().top - padding)),
  );
  if (!pageY.isAnimating()) pageY.jump(from);

  const interrupt = () => pageY.stop();
  const inputs = ["wheel", "touchstart", "keydown"] as const;
  for (const type of inputs) window.addEventListener(type, interrupt, { passive: true });
  const release = () => {
    for (const type of inputs) window.removeEventListener(type, interrupt);
  };

  animate(pageY, to, {
    type: "spring",
    bounce: 0,
    visualDuration: Math.min(1.1, 0.5 + Math.abs(to - from) / 4000),
    onStop: release,
    onComplete: () => {
      release();
      // Lands exactly where the native jump would, so this only records history and focus origin.
      location.hash = hash;
    },
  });
}

// Two off-screen phantom copies of the closed and open content trees,
// rendered purely so we can read their natural box sizes via offsetWidth
// / offsetHeight. They share the SAME PillRow / menu-item markup as the
// real surface so the measurements always match what ends up on screen.
//
// `invisible` keeps them out of the visual / a11y layer; `pointer-events-
// none` keeps them out of hit testing; positioning at left -99999px keeps
// them from contributing to viewport scroll size. They still participate
// in layout (so they have a real measurable box) but in a region nothing
// can scroll into.
function PhantomMeasurers({
  closedRef,
  openRef,
  downloadUrl,
}: {
  closedRef: RefObject<HTMLDivElement | null>;
  openRef: RefObject<HTMLDivElement | null>;
  downloadUrl: string;
}) {
  const noop = () => undefined;
  return (
    <div
      aria-hidden
      className="pointer-events-none invisible fixed top-0 left-[-99999px] flex flex-col"
    >
      <div ref={closedRef}>
        <PillRow downloadUrl={downloadUrl} open={false} reduced onMenuToggle={noop} />
      </div>
      <div ref={openRef}>
        <ul className="flex flex-col gap-0.5 p-1.5 pb-0">
          {MENU_ITEMS.map((item) => (
            <li key={item.label} role="none">
              <span className="flex h-10 items-center justify-between rounded-2xl px-3.5 text-[13px] font-medium text-stone-200 sm:h-11 sm:px-4 sm:text-[14px]">
                <span>{item.label}</span>
                <Icon.Arrow className="h-3.5 w-3.5 text-stone-400" />
              </span>
            </li>
          ))}
        </ul>
        <PillRow downloadUrl={downloadUrl} open reduced onMenuToggle={noop} />
      </div>
    </div>
  );
}

// Tiny chevron-up. Local component so we don't need to amend the shared icon
// set just for one glyph.
function ChevronUp({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <path d="M6 15l6-6 6 6" />
    </svg>
  );
}

// Subtle vertical hair between pill items (1px, low alpha).
function PillDivider() {
  return <span aria-hidden className="hidden h-4 w-px bg-white/10 sm:inline-block" />;
}
