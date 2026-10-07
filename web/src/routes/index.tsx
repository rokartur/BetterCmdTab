import { createFileRoute } from "@tanstack/react-router";
import { LayoutGroup, MotionConfig, motion, type Variants } from "motion/react";
import { type CSSProperties, useState } from "react";

import { Compare } from "../sections/Compare";
import { Docs } from "../sections/Docs";
import {
  BrewCmd,
  DownloadCta,
  formatVersion,
  RollingText,
  useReleases,
} from "../sections/Download";
import { BetterAudioCard, Footer } from "../sections/Footer";
import { Highlights } from "../sections/Highlights";
import {
  Chord,
  CHORD_INTRO,
  Kbd,
  PlayingChord,
  SoundToggle,
  SwitcherHeadline,
  useKeySounds,
} from "../sections/Keys";
import { Showcase } from "../sections/Showcase";
import { EASE } from "../sections/tokens";
import { DownloadButton, StickyCTA } from "../StickyCTA";

export const Route = createFileRoute("/")({ component: Home });

// The entrance cascade is the `enter`/`rise` classes in globals.css, and it stays
// CSS: a keyframe on the prerendered HTML runs at the first paint, while anything
// Motion-driven can't start until ~800 KB of JS hydrates, which means content
// sits visibly parked and then hops. Same reason there is no scroll reveal —
// everything below the fold ships in its final position. Motion here is only for
// what a click or a hover asks for.

const downloadFmt = new Intl.NumberFormat("en-US");

const layoutShift = { layout: { duration: 0.22, ease: EASE } };

const rise: Variants = {
  hidden: { y: 18, opacity: 0 },
  show: { y: 0, opacity: 1, transition: { duration: 0.6, ease: EASE } },
};

function Home() {
  const { stable, beta, totalDownloads } = useReleases();
  const [channel, setChannel] = useState<"stable" | "beta">("stable");
  const sel = channel === "beta" && beta ? beta : stable;
  const { dmgUrl } = sel;
  const keySound = useKeySounds();
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
                  <DownloadCta href={dmgUrl} channel={channel} onChange={setChannel} beta={beta} />
                </div>
                <div className="enter [animation-delay:1510ms]">
                  <BrewCmd beta={channel === "beta"} />
                </div>
                <p className="enter m-0 text-[13px] text-muted [animation-delay:1570ms]">
                  {totalDownloads > 0 && `${downloadFmt.format(totalDownloads)} downloads · `}
                  macOS 13+
                  {sel.version && (
                    <>
                      {" · "}
                      <RollingText className="tabular-nums" text={formatVersion(sel.version)} />
                    </>
                  )}
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
            <PlayingChord className="text-[72px]" sound={keySound.play} />
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
              macOS 13+
              {sel.version && (
                <>
                  {" · "}
                  <RollingText className="tabular-nums" text={formatVersion(sel.version)} />
                </>
              )}
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
      <BetterAudioCard />
      <SoundToggle on={keySound.on} onToggle={keySound.toggle} />
    </MotionConfig>
  );
}
