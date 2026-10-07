import {
  motion,
  useAnimationControls,
  useInView,
  useReducedMotion,
  type Variants,
} from "motion/react";
import { type ReactNode, useEffect, useRef } from "react";

import { EASE } from "./tokens";

const FRAME_OUTLINE =
  "M7.8 3h8.4C19.2 3 21 5.1 21 8v8c0 2.9-1.8 5-4.8 5H7.8C4.8 21 3 18.9 3 16V8c0-2.9 1.8-5 4.8-5Z";

export function Highlights() {
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
